import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/spotify_canvas_lookup.dart';

const _id = '4uLU6hMCjMI75M1A2tKUQC';
const _other = '11dFghVXANMlKmJXsNCbNl';
const _absent =
    '{"canvas_state":"absent_confirmed","reason":"empty_canvas_list"}';
const _ambiguous =
    '{"canvas_state":"empty_ambiguous","reason":"no_canvas_list_anonymous"}';

Track _track({
  String id = 'local-1',
  String? source,
  String? isrc,
  int duration = 200,
}) => Track(
  id: id,
  name: 'Song Name',
  artistName: 'Main Artist',
  albumName: 'Album',
  isrc: isrc,
  duration: duration,
  source: source,
);

void main() {
  late Directory dir;
  late List<String> searches;
  late List<String> urls;
  late DateTime clock;
  late List<Map<String, dynamic>> results;
  late Map<String, dynamic>? urlResult;
  late List<String> logs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('canvas_lookup');
    searches = [];
    urls = [];
    clock = DateTime(2026, 1, 1);
    results = [];
    urlResult = {'header_video': 'https://canvaz.scdn.co/a.mp4'};
    logs = [];
  });
  tearDown(() => dir.delete(recursive: true));

  SpotifyCanvasLookup build({
    Future<Map<String, dynamic>?> Function(String url)? handler,
  }) => SpotifyCanvasLookup(
    directory: () async => dir,
    now: () => clock,
    log: logs.add,
    retryDelays: const [Duration.zero, Duration.zero],
    search: (query) async {
      searches.add(query);
      return results;
    },
    handleUrl:
        handler ??
        (url) async {
          urls.add(url);
          return urlResult;
        },
  );

  test('uses the Spotify id directly without searching', () async {
    final url = await build().lookup(_track(id: _id, source: 'spotify-web'));
    expect(url, 'https://canvaz.scdn.co/a.mp4');
    expect(searches, isEmpty);
    expect(urls, ['spotify:canvas:$_id']);
  });

  test('resolves by ISRC when the result carries the same code', () async {
    results = [
      {'id': _other, 'isrc': 'USAAA1111111', 'name': 'x'},
      {'id': _id, 'isrc': 'USAAA1234567', 'name': 'Song Name'},
    ];
    final url = await build().lookup(_track(isrc: 'usaaa1234567'));
    expect(url, isNotNull);
    expect(searches, ['isrc:USAAA1234567']);
    expect(urls, ['spotify:canvas:$_id']);
  });

  test('falls back to a strict title, artist and duration match', () async {
    results = [
      {
        'id': _other,
        'name': 'Song Name',
        'artists': 'Main Artist',
        'duration_ms': 215000,
      },
      {
        'id': _id,
        'name': 'Song name',
        'artists': 'Guest, Main Artist',
        'duration_ms': 202500,
      },
    ];
    final url = await build().lookup(_track(isrc: 'USAAA1234567'));
    expect(url, isNotNull);
    expect(searches, ['isrc:USAAA1234567', 'Song Name Main Artist']);
    expect(urls, ['spotify:canvas:$_id']);
  });

  test('remembers negative results for 24 hours, also on disk', () async {
    final lookup = build();
    final track = _track(id: _id, source: 'spotify-web');
    urlResult = {'header_video': _absent};
    expect(await lookup.lookup(track), isNull);
    expect(await lookup.lookup(track), isNull);
    expect(await build().lookup(track), isNull);
    expect(urls, hasLength(1));
    clock = clock.add(const Duration(hours: 25));
    urlResult = {'header_video': 'https://canvaz.scdn.co/b.mp4'};
    expect(await build().lookup(track), 'https://canvaz.scdn.co/b.mp4');
    expect(urls, hasLength(2));
  });

  test('a thrown error is a short miss and can be retried later', () async {
    final track = _track(id: _id, source: 'spotify-web');
    var calls = 0;
    final lookup = build(
      handler: (_) async {
        calls++;
        throw StateError('offline');
      },
    );
    expect(await lookup.lookup(track), isNull);
    expect(calls, 3);
    expect(logs, contains('miss recorded short'));
    expect(await lookup.lookup(track), isNull);
    expect(calls, 3);
    expect(await build().lookup(track), isNotNull);
  });

  test('a short miss expires and the lookup succeeds afterwards', () async {
    final track = _track(id: _id, source: 'spotify-web');
    var fail = true;
    final lookup = build(
      handler: (url) async {
        if (fail) throw StateError('plugin not ready');
        return {'header_video': 'https://canvaz.scdn.co/a.mp4'};
      },
    );
    expect(await lookup.lookup(track), isNull);
    fail = false;
    expect(await lookup.lookup(track), isNull);
    clock = clock.add(const Duration(minutes: 4));
    expect(await lookup.lookup(track), 'https://canvaz.scdn.co/a.mp4');
  });

  test('retries a transient failure before giving up', () async {
    final track = _track(id: _id, source: 'spotify-web');
    var calls = 0;
    final lookup = build(
      handler: (_) async {
        calls++;
        if (calls < 3) throw StateError('not ready');
        return {'header_video': 'https://canvaz.scdn.co/a.mp4'};
      },
    );
    expect(await lookup.lookup(track), 'https://canvaz.scdn.co/a.mp4');
    expect(calls, 3);
  });

  test('plugin failure payloads and null responses are transient', () async {
    final track = _track(id: _id, source: 'spotify-web');
    for (final payload in <Map<String, dynamic>?>[
      null,
      {'success': false, 'error': 'unauthorized'},
      {'error': 'http 401'},
    ]) {
      logs.clear();
      final lookup = build(handler: (_) async => payload);
      expect(await lookup.lookup(track), isNull);
      expect(logs, contains('miss recorded short'));
      expect(logs, isNot(contains('miss recorded long')));
    }
    expect(await build().lookup(track), isNotNull);
  });

  test('a timeout is a short miss', () async {
    final track = _track(id: _id, source: 'spotify-web');
    final lookup = SpotifyCanvasLookup(
      directory: () async => dir,
      now: () => clock,
      log: logs.add,
      timeout: const Duration(milliseconds: 20),
      handleUrl: (_) => Completer<Map<String, dynamic>?>().future,
    );
    expect(await lookup.lookup(track), isNull);
    expect(logs, contains('miss recorded short'));
    expect(await build().lookup(track), isNotNull);
  });

  test(
    'empty search results are transient, unmatched results are long',
    () async {
      final track = _track(isrc: 'USAAA1234567');
      results = [];
      expect(await build().lookup(track), isNull);
      expect(logs, contains('miss recorded short'));
      logs.clear();
      results = [
        {'id': _other, 'isrc': 'USZZZ0000000', 'name': 'Other'},
      ];
      expect(await build().lookup(track), isNull);
      expect(logs, contains('miss recorded long'));
      expect(await build().lookup(track), isNull);
      expect(logs.last, 'skipped, recent miss cached');
    },
  );

  test('a found url is cached in memory', () async {
    final lookup = build();
    final track = _track(id: _id, source: 'spotify-web');
    expect(await lookup.lookup(track), isNotNull);
    expect(await lookup.lookup(track), isNotNull);
    expect(urls, hasLength(1));
    expect(logs, contains('found'));
  });

  test('disabled setting makes no calls', () async {
    final lookup = build();
    expect(
      await lookup.lookup(
        _track(id: _id, source: 'spotify-web'),
        enabled: false,
      ),
      isNull,
    );
    expect(searches, isEmpty);
    expect(urls, isEmpty);
  });

  group('canvas states', () {
    final track = _track(id: _id, source: 'spotify-web');

    test('parses a url, status json and legacy empty answers', () {
      CanvasResult parse(Object? header, [Map<String, dynamic>? extra]) =>
          CanvasResult.parse({'header_video': header, ...?extra});
      expect(parse('https://canvaz.scdn.co/a.mp4').state, CanvasState.found);
      expect(parse('ftp://x/a.mp4').state, CanvasState.emptyAmbiguous);
      expect(parse(_absent).state, CanvasState.absentConfirmed);
      expect(parse(_absent).reason, 'empty_canvas_list');
      expect(parse(_ambiguous).state, CanvasState.emptyAmbiguous);
      expect(
        parse('{"canvas_state":"error","reason":"http_500"}').reason,
        'http_500',
      );
      final limited = parse('{"canvas_state":"rate_limited","retry_after":90}');
      expect(limited.state, CanvasState.rateLimited);
      expect(limited.retryAfter, const Duration(seconds: 90));
      expect(parse('{"canvas_state":"rate_limited"}').retryAfter, isNull);
      expect(
        parse('{"canvas_state":"found"}').state,
        CanvasState.emptyAmbiguous,
      );
      expect(parse('{broken').reason, 'bad_status');
      expect(parse('').reason, 'legacy_empty');
      expect(parse(null).state, CanvasState.emptyAmbiguous);
      expect(
        parse('', {'canvas_state': 'absent_confirmed'}).state,
        CanvasState.absentConfirmed,
      );
    });

    test('an ambiguous answer is not a 24 hour absence', () async {
      urlResult = {'header_video': _ambiguous};
      final lookup = build();
      expect(await lookup.lookup(track), isNull);
      expect(logs, contains('miss recorded ambiguous'));
      expect(logs, isNot(contains('miss recorded long')));
      expect(
        logs,
        contains(
          'state=empty_ambiguous reason=no_canvas_list_anonymous '
          'spotifyId=$_id via=source',
        ),
      );
      expect(await lookup.lookup(track), isNull);
      expect(urls, hasLength(1));
      expect(
        File('${dir.path}/spotify_canvas_misses_v3.json').existsSync(),
        isFalse,
      );
      expect(
        File('${dir.path}/spotify_canvas_ambiguous_v1.json').existsSync(),
        isTrue,
      );
      expect(await build().lookup(track), isNull);
      expect(urls, hasLength(1));
      clock = clock.add(const Duration(minutes: 31));
      urlResult = {'header_video': 'https://canvaz.scdn.co/a.mp4'};
      expect(await build().lookup(track), 'https://canvaz.scdn.co/a.mp4');
      expect(urls, hasLength(2));
    });

    test('an ambiguous answer is dropped when the add-on changes', () async {
      var version = '1';
      SpotifyCanvasLookup versioned() => SpotifyCanvasLookup(
        directory: () async => dir,
        now: () => clock,
        log: logs.add,
        retryDelays: const [Duration.zero],
        handleUrl: (url) async {
          urls.add(url);
          return urlResult;
        },
        pluginVersion: () => version,
      );
      urlResult = {'header_video': _ambiguous};
      expect(await versioned().lookup(track), isNull);
      expect(await versioned().lookup(track), isNull);
      expect(urls, hasLength(1));
      version = '2';
      expect(await versioned().lookup(track), isNull);
      expect(urls, hasLength(2));
    });

    test('a legacy empty answer is treated as ambiguous', () async {
      urlResult = {'header_video': ''};
      expect(await build().lookup(track), isNull);
      expect(logs, contains('miss recorded ambiguous'));
      expect(
        File('${dir.path}/spotify_canvas_misses_v3.json').existsSync(),
        isFalse,
      );
    });

    test('a confirmed absence lasts 24 hours and is saved', () async {
      urlResult = {'header_video': _absent};
      expect(await build().lookup(track), isNull);
      expect(
        File('${dir.path}/spotify_canvas_misses_v3.json').existsSync(),
        isTrue,
      );
      clock = clock.add(const Duration(hours: 23));
      expect(await build().lookup(track), isNull);
      expect(urls, hasLength(1));
      clock = clock.add(const Duration(hours: 2));
      urlResult = {'header_video': 'https://canvaz.scdn.co/a.mp4'};
      expect(await build().lookup(track), isNotNull);
    });

    test('an error answer is short and never saved', () async {
      urlResult = {
        'header_video': '{"canvas_state":"error","reason":"http_500"}',
      };
      final lookup = build();
      expect(await lookup.lookup(track), isNull);
      expect(logs, contains('miss recorded short'));
      expect(
        logs,
        contains('state=error reason=http_500 spotifyId=$_id via=source'),
      );
      expect(await lookup.lookup(track), isNull);
      expect(urls, hasLength(1));
      expect(dir.listSync(), isEmpty);
      clock = clock.add(const Duration(minutes: 4));
      urlResult = {'header_video': 'https://canvaz.scdn.co/a.mp4'};
      expect(await lookup.lookup(track), isNotNull);
    });

    test('rate limiting honours Retry-After between 5 min and 1 h', () async {
      Future<void> blockedFor(int seconds, Duration expected) async {
        urls.clear();
        urlResult = {
          'header_video':
              '{"canvas_state":"rate_limited","retry_after":$seconds}',
        };
        final lookup = build();
        final other = _track(id: _other, source: 'spotify-web');
        expect(await lookup.lookup(track), isNull);
        expect(urls, hasLength(1));
        clock = clock.add(expected - const Duration(seconds: 1));
        expect(await lookup.lookup(other), isNull);
        expect(urls, hasLength(1));
        clock = clock.add(const Duration(seconds: 2));
        urlResult = {'header_video': 'https://canvaz.scdn.co/a.mp4'};
        expect(await lookup.lookup(other), isNotNull);
        expect(urls, hasLength(2));
        expect(dir.listSync(), isEmpty);
      }

      await blockedFor(10, const Duration(minutes: 5));
      await blockedFor(600, const Duration(minutes: 10));
      await blockedFor(86400, const Duration(hours: 1));
    });

    test('rate limiting without a header waits 5 minutes', () async {
      urlResult = {'header_video': '{"canvas_state":"rate_limited"}'};
      final lookup = build();
      expect(await lookup.lookup(track), isNull);
      expect(logs, contains('miss recorded rate limit 300s'));
      expect(await build().lookup(track), isNull);
      expect(urls, hasLength(2));
    });
  });

  group('startup gate and plugin version', () {
    SpotifyCanvasLookup gated({
      required Future<void> Function() ready,
      required String Function() version,
      Duration readyTimeout = const Duration(seconds: 15),
    }) => SpotifyCanvasLookup(
      directory: () async => dir,
      now: () => clock,
      log: logs.add,
      retryDelays: const [Duration.zero],
      search: (query) async => results,
      handleUrl: (url) async {
        urls.add(url);
        return urlResult;
      },
      ready: ready,
      readyTimeout: readyTimeout,
      pluginVersion: version,
    );

    test('waits for the add-ons before calling them', () async {
      final gate = Completer<void>();
      final lookup = gated(ready: () => gate.future, version: () => '1');
      final pending = lookup.lookup(_track(id: _id, source: 'spotify-web'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(urls, isEmpty);
      gate.complete();
      expect(await pending, isNotNull);
      expect(urls, hasLength(1));
    });

    test('does not block longer than the timeout', () async {
      final lookup = gated(
        ready: () => Completer<void>().future,
        version: () => '1',
        readyTimeout: const Duration(milliseconds: 50),
      );
      final url = await lookup.lookup(_track(id: _id, source: 'spotify-web'));
      expect(url, isNotNull);
    });

    test('a miss from an older add-on version is discarded', () async {
      final track = _track(id: _id, source: 'spotify-web');
      var version = '1';
      urlResult = {'header_video': _absent};
      final first = gated(ready: () async {}, version: () => version);
      expect(await first.lookup(track), isNull);
      final same = gated(ready: () async {}, version: () => version);
      expect(await same.lookup(track), isNull);
      expect(urls, hasLength(1));
      version = '2';
      urlResult = {'header_video': 'https://canvaz.scdn.co/c.mp4'};
      final upgraded = gated(ready: () async {}, version: () => version);
      expect(await upgraded.lookup(track), 'https://canvaz.scdn.co/c.mp4');
      expect(urls, hasLength(2));
    });

    test('misses saved in the v2 file are ignored', () async {
      final old = File('${dir.path}/spotify_canvas_misses_v2.json');
      await old.writeAsString('{"$_id|": 1767225600000}');
      final lookup = gated(ready: () async {}, version: () => '1');
      final url = await lookup.lookup(_track(id: _id, source: 'spotify-web'));
      expect(url, isNotNull);
    });
  });
}
