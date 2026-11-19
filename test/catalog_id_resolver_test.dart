import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_id_resolver.dart';

const _isrc = 'USAT22607218';

Track _track({
  String id = 'deezer:4337604802',
  String? source = 'deezer',
  String? deezerId = '4337604802',
  String? isrc = _isrc,
  int duration = 112,
}) => Track(
  id: id,
  source: source,
  name: 'Suzuki (from GTAVI: The Album)',
  artistName: 'Fuerza Regida, Grand Theft Auto VI',
  albumName: 'GTAVI: The Album',
  isrc: isrc,
  duration: duration,
  deezerId: deezerId,
);

Map<String, dynamic> _row({
  String id = 'beatport:30982448',
  String name = 'Suzuki',
  String artists = 'Fuerza Regida',
  String? isrc = _isrc,
  num durationMs = 111655,
}) => {
  'id': id,
  'name': name,
  'artists': artists,
  'isrc': ?isrc,
  'duration_ms': durationMs,
  'item_type': 'track',
};

void main() {
  late Directory dir;
  late DateTime clock;
  late List<String> lines;
  late List<String> queries;
  late List<Map<String, dynamic>> options;
  late List<String> providers;
  late List<Map<String, dynamic>> rows;
  late Object? failure;
  late Duration delay;
  late List<String> deezerCalls;
  late Map<String, dynamic> deezerResult;
  var enabled = true;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_id_resolver');
    clock = DateTime(2026, 1, 1);
    lines = [];
    queries = [];
    options = [];
    providers = [];
    rows = [];
    failure = null;
    delay = Duration.zero;
    deezerCalls = [];
    deezerResult = {'success': false};
    enabled = true;
  });
  tearDown(() => dir.delete(recursive: true));

  CatalogIdResolver build() => CatalogIdResolver(
    directory: () async => dir,
    now: () => clock,
    enabled: () async => enabled,
    diagnostic: lines.add,
    search: (provider, query, opts) async {
      providers.add(provider);
      queries.add(query);
      options.add(opts);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final error = failure;
      if (error != null) throw error;
      return rows;
    },
    deezerByIsrc: (isrc) async {
      deezerCalls.add(isrc);
      return deezerResult;
    },
  );

  test('resolves by ISRC on Beatport with a clean query', () async {
    rows = [_row()];
    final result = await build().resolve(_track(), 'beatport');
    expect(result!.id, '30982448');
    expect(result.via, CatalogIdVia.isrc);
    expect(queries, ['Suzuki Fuerza Regida']);
    expect(options, [
      {'filter': 'track', 'limit': 10},
    ]);
    expect(lines.single, contains('result=hit'));
    expect(lines.single, contains('delivery=direct'));
  });

  test('resolves by ISRC on Tidal', () async {
    rows = [_row(id: 'tidal:568276392')];
    final result = await build().resolve(_track(), 'tidal-web');
    expect(result!.id, '568276392');
    expect(lines.single, contains('delivery=field'));
  });

  test('rejects a different ISRC with identical metadata', () async {
    rows = [_row(isrc: 'USAT22600001')];
    expect(await build().resolve(_track(), 'beatport'), isNull);
    expect(lines.single, contains('result=miss'));
  });

  test('rejects a different edition by duration without ISRC', () async {
    rows = [_row(id: '1234567890', isrc: null, durationMs: 125411)];
    expect(await build().resolve(_track(), 'soundcloud'), isNull);
  });

  test('accepts a strict title match without ISRC', () async {
    rows = [_row(isrc: null, durationMs: 112800)];
    final result = await build().resolve(_track(), 'beatport');
    expect(result!.id, '30982448');
    expect(result.via, CatalogIdVia.title);
  });

  test('rejects a version mismatch', () async {
    rows = [_row(name: 'Suzuki (Live)', isrc: null, durationMs: 112000)];
    expect(await build().resolve(_track(), 'beatport'), isNull);
  });

  test('rejects an equal ISRC far from the duration', () async {
    rows = [_row(durationMs: 40000)];
    expect(await build().resolve(_track(), 'beatport'), isNull);
  });

  test('network error is not cached and backs off', () async {
    failure = StateError('network');
    final resolver = build();
    expect(await resolver.resolve(_track(), 'beatport'), isNull);
    expect(lines.last, contains('result=error'));
    expect(queries, hasLength(1));
    expect(await resolver.resolve(_track(), 'beatport'), isNull);
    expect(lines.last, contains('reason=backoff'));
    expect(queries, hasLength(1));
    clock = clock.add(const Duration(seconds: 61));
    failure = null;
    rows = [_row()];
    expect((await resolver.resolve(_track(), 'beatport'))!.id, '30982448');
    expect(queries, hasLength(2));
  });

  test(
    'empty lists retry with the title and expire after 15 minutes',
    () async {
      final resolver = build();
      expect(await resolver.resolve(_track(), 'beatport'), isNull);
      expect(queries, ['Suzuki Fuerza Regida', 'Suzuki']);
      expect(lines.last, contains('result=empty'));
      expect(lines.last, contains('queries=2'));
      clock = clock.add(const Duration(minutes: 14));
      expect(await resolver.resolve(_track(), 'beatport'), isNull);
      expect(queries, hasLength(2));
      clock = clock.add(const Duration(minutes: 2));
      await resolver.resolve(_track(), 'beatport');
      expect(queries, hasLength(4));
    },
  );

  test('positive cache survives instances and expires after 30 days', () async {
    rows = [_row()];
    expect(await build().resolve(_track(), 'beatport'), isNotNull);
    final second = build();
    final cached = await second.resolve(_track(), 'beatport');
    expect(cached!.via, CatalogIdVia.cache);
    expect(queries, hasLength(1));
    expect(lines.last, contains('queries=0'));
    clock = clock.add(const Duration(days: 31));
    expect(
      (await second.resolve(_track(), 'beatport'))!.via,
      CatalogIdVia.isrc,
    );
    expect(queries, hasLength(2));
  });

  test('negative cache lasts 24 hours', () async {
    rows = [_row(isrc: 'USAT22600001')];
    final resolver = build();
    expect(await resolver.resolve(_track(), 'beatport'), isNull);
    expect(await resolver.resolve(_track(), 'beatport'), isNull);
    expect(lines.last, contains('result=miss_cached'));
    expect(queries, hasLength(1));
    clock = clock.add(const Duration(hours: 25));
    await resolver.resolve(_track(), 'beatport');
    expect(queries, hasLength(2));
  });

  test('a late lookup is cached after the deadline', () async {
    rows = [_row()];
    delay = const Duration(milliseconds: 200);
    final resolver = build();
    final result = await resolver.resolve(
      _track(),
      'beatport',
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, isNull);
    expect(lines.last, contains('result=timeout'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final next = await resolver.resolve(_track(), 'beatport');
    expect(next!.via, CatalogIdVia.cache);
    expect(next.id, '30982448');
  });

  test('limits lookups per track', () async {
    final resolver = build();
    for (final provider in const [
      'tidal-web',
      'qobuz-web',
      'beatport',
      'jiosaavn',
    ]) {
      await resolver.resolve(_track(), provider);
    }
    final before = queries.length;
    expect(await resolver.resolve(_track(), 'soundcloud'), isNull);
    expect(queries.length, before);
    expect(lines.last, contains('reason=budget'));
  });

  test('skips by policy, lookup, native source and switch', () async {
    final resolver = build();
    await resolver.resolve(
      _track(id: 'soundcloud:1', source: 'soundcloud', deezerId: null),
      'beatport',
    );
    expect(lines.last, contains('reason=source_policy'));
    await resolver.resolve(_track(), 'amazon');
    expect(lines.last, contains('reason=no_lookup'));
    await resolver.resolve(_track(), 'deezer');
    expect(lines.last, contains('reason=native'));
    enabled = false;
    await resolver.resolve(_track(), 'beatport');
    expect(lines.last, contains('reason=disabled'));
    expect(queries, isEmpty);
    expect(deezerCalls, isEmpty);
  });

  test('resolves Deezer by ISRC', () async {
    final track = _track(id: 'tidal:1', source: 'tidal-web', deezerId: null);
    deezerResult = {'success': true, 'track_id': 4337604802};
    expect((await build().resolve(track, 'deezer'))!.id, '4337604802');
    deezerResult = {'success': false};
    final other = build();
    expect(
      await other.resolve(
        _track(
          id: 'tidal:2',
          source: 'tidal-web',
          deezerId: null,
          isrc: 'USAT22600002',
        ),
        'deezer',
      ),
      isNull,
    );
  });

  test('invalidate removes the positive entry', () async {
    rows = [_row()];
    final resolver = build();
    await resolver.resolve(_track(), 'beatport');
    await resolver.invalidate(_track(), 'beatport');
    expect(lines.last, contains('result=invalidated'));
    final again = await resolver.resolve(_track(), 'beatport');
    expect(again!.via, CatalogIdVia.isrc);
    expect(queries, hasLength(2));
  });

  test('an unreadable cache file behaves as empty', () async {
    await File('${dir.path}/catalog_ids.json').writeAsString('xx');
    rows = [_row()];
    expect(await build().resolve(_track(), 'beatport'), isNotNull);
  });

  test('diagnostics never contain track data', () async {
    rows = [_row(), _row(id: 'tidal:568276392')];
    final resolver = build();
    await resolver.resolve(_track(), 'beatport');
    await resolver.resolve(_track(), 'tidal-web');
    await resolver.resolve(_track(), 'beatport');
    await resolver.invalidate(_track(), 'beatport');
    expect(lines, isNotEmpty);
    for (final line in lines) {
      for (final secret in const [
        'Suzuki',
        'Fuerza',
        _isrc,
        '30982448',
        '568276392',
      ]) {
        expect(line, isNot(contains(secret)));
      }
      expect(line, startsWith('provider='));
    }
  });

  test('cleanTitle removes only annotations without version words', () {
    expect(
      CatalogIdResolver.cleanTitle('Suzuki (from GTAVI: The Album)'),
      'Suzuki',
    );
    expect(
      CatalogIdResolver.cleanTitle('Song (feat. X) [Live from "Y"]'),
      'Song [Live from "Y"]',
    );
    expect(CatalogIdResolver.cleanTitle('Song (Remix)'), 'Song (Remix)');
  });
}
