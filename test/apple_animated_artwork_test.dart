import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/apple_animated_artwork.dart';

Map<String, dynamic> _video(String name) => {
  'video': 'https://video.example.test/$name.m3u8',
  'previewFrame': {
    'url': 'https://img.example.test/$name/{w}x{h}.jpg',
    'width': 100,
    'height': 100,
  },
};

Map<String, dynamic> _found(Map<String, dynamic> videos) => {
  'success': true,
  'type': 'animated_artwork',
  'id': '1001',
  'editorial_video': videos,
};

Track _track({String? source, String? id, String? albumId, String? isrc}) =>
    Track(
      id: id ?? 'local-1',
      name: 'Song Name',
      artistName: 'Main Artist',
      albumName: 'Album Name',
      albumId: albumId,
      isrc: isrc,
      duration: 200,
      source: source,
    );

void main() {
  group('selectAnimatedArtworkVariant', () {
    test('prefers a square loop over a tall one', () {
      final source = selectAnimatedArtworkVariant({
        'motionDetailTall': _video('tall'),
        'motionSquareVideo1x1': _video('square'),
      });
      expect(source?.variant, AnimatedArtworkVariant.square);
      expect(source?.url, 'https://video.example.test/square.m3u8');
      expect(source?.previewUrl, startsWith('https://img.example.test/'));
    });

    test('falls back to the tall 3:4 loop when it is the only one', () {
      final source = selectAnimatedArtworkVariant({
        'motionTallVideo3x4': _video('tall'),
      });
      expect(source?.variant, AnimatedArtworkVariant.tall);
    });

    test('skips entries without a usable video', () {
      expect(
        selectAnimatedArtworkVariant({
          'motionDetailSquare': {'previewFrame': <String, dynamic>{}},
          'motionSquareVideo1x1': {'video': 'ftp://video.example.test/a'},
          'motionDetailTall': _video('tall'),
        })?.variant,
        AnimatedArtworkVariant.tall,
      );
    });

    test('returns null for wide-only, empty or malformed data', () {
      expect(
        selectAnimatedArtworkVariant({'motionArtistWide16x9': _video('w')}),
        isNull,
      );
      expect(selectAnimatedArtworkVariant({}), isNull);
      expect(selectAnimatedArtworkVariant(null), isNull);
      expect(selectAnimatedArtworkVariant('text'), isNull);
    });
  });

  group('classifyAnimatedArtworkResponse', () {
    test('found carries the chosen source', () {
      final result = classifyAnimatedArtworkResponse(
        _found({'motionDetailSquare': _video('s')}),
      );
      expect(result.outcome, AnimatedArtworkOutcome.found);
      expect(result.source?.url, endsWith('s.m3u8'));
    });

    test('an album without loops is absent, no album is unmatched', () {
      expect(
        classifyAnimatedArtworkResponse({
          'success': true,
          'type': 'animated_artwork',
          'id': '1001',
        }).outcome,
        AnimatedArtworkOutcome.absent,
      );
      expect(
        classifyAnimatedArtworkResponse({
          'success': true,
          'type': 'animated_artwork',
          'id': '',
        }).outcome,
        AnimatedArtworkOutcome.unmatched,
      );
    });

    test('missing, failed or foreign responses are failures', () {
      for (final response in <Map<String, dynamic>?>[
        null,
        {'success': false, 'error': 'token'},
        {'error': 'x', 'type': 'animated_artwork'},
        {'type': 'album', 'id': '1'},
        <String, dynamic>{},
      ]) {
        expect(
          classifyAnimatedArtworkResponse(response).outcome,
          AnimatedArtworkOutcome.failed,
          reason: '$response',
        );
      }
    });

    test('failures are only cached for minutes, absence for hours', () {
      expect(
        animatedArtworkCacheTtl(AnimatedArtworkOutcome.failed),
        lessThanOrEqualTo(const Duration(minutes: 5)),
      );
      expect(
        animatedArtworkCacheTtl(AnimatedArtworkOutcome.absent),
        greaterThanOrEqualTo(const Duration(hours: 1)),
      );
    });
  });

  group('animatedArtworkLookupUrl', () {
    test('uses the Apple ids when the track comes from Apple Music', () {
      final url = Uri.parse(
        animatedArtworkLookupUrl(
          _track(source: 'apple-music', id: '555', albumId: '777'),
        ),
      );
      expect(url.scheme, 'apple-music');
      expect(url.path, 'animated-artwork');
      expect(url.queryParameters['album_id'], '777');
      expect(url.queryParameters['track_id'], '555');
      expect(url.queryParameters['title'], 'Song Name');
    });

    test('other sources only send ISRC and names', () {
      final url = Uri.parse(
        animatedArtworkLookupUrl(
          _track(source: 'local', albumId: '777', isrc: 'XX0000000001'),
        ),
      );
      expect(url.queryParameters.containsKey('album_id'), isFalse);
      expect(url.queryParameters['isrc'], 'XX0000000001');
      expect(url.queryParameters['duration_ms'], '200000');
    });

    test('tracks of one album share a cache key', () {
      final a = _track();
      const b = Track(
        id: 'other',
        name: 'Another',
        artistName: 'main artist',
        albumName: 'album  name!',
        duration: 1,
      );
      expect(animatedArtworkKey(a), animatedArtworkKey(b));
    });
  });

  group('AppleAnimatedArtworkLookup', () {
    late Directory dir;
    late DateTime clock;
    late List<String> calls;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('animated_artwork');
      clock = DateTime(2026, 1, 1);
      calls = [];
    });
    tearDown(() => dir.delete(recursive: true));

    AppleAnimatedArtworkLookup build(AnimatedArtworkHandler handler) =>
        AppleAnimatedArtworkLookup(
          handleUrl: (url) {
            calls.add(url);
            return handler(url);
          },
          directory: () async => dir,
          now: () => clock,
          log: (_) {},
          retryDelays: const [Duration.zero],
        );

    test('a network error is retried, reported and not kept', () async {
      var attempts = 0;
      final lookup = build((_) async {
        attempts++;
        if (attempts <= 2) throw TimeoutException('offline');
        return _found({'motionDetailSquare': _video('s')});
      });
      final failed = await lookup.lookup(_track());
      expect(failed.outcome, AnimatedArtworkOutcome.failed);
      expect(calls, hasLength(2));
      final again = await lookup.lookup(_track());
      expect(again.outcome, AnimatedArtworkOutcome.failed);
      expect(calls, hasLength(2), reason: 'the failure is held for a moment');
      clock = clock.add(const Duration(minutes: 4));
      final found = await lookup.lookup(_track());
      expect(found.outcome, AnimatedArtworkOutcome.found);
      expect(calls, hasLength(3));
      final file = File('${dir.path}/apple_animated_artwork_absent_v3.json');
      expect(await file.exists(), isFalse, reason: 'no failure is durable');
    });

    test('absence is remembered across instances until it expires', () async {
      Future<Map<String, dynamic>?> none(String _) async => {
        'success': true,
        'type': 'animated_artwork',
        'id': '1001',
      };
      final first = build(none);
      final result = await first.lookup(_track());
      expect(result.outcome, AnimatedArtworkOutcome.absent);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = build(none);
      calls.clear();
      final repeated = await second.lookup(_track());
      expect(repeated.outcome, AnimatedArtworkOutcome.absent);
      expect(calls, isEmpty);
      clock = clock.add(const Duration(hours: 25));
      await build(none).lookup(_track());
      expect(calls, hasLength(1));
    });

    test('concurrent lookups of one album share a single request', () async {
      final gate = Completer<Map<String, dynamic>?>();
      final lookup = build((_) => gate.future);
      final a = lookup.lookup(_track());
      final b = lookup.lookup(_track());
      gate.complete(_found({'motionDetailSquare': _video('s')}));
      expect((await a).outcome, AnimatedArtworkOutcome.found);
      expect((await b).outcome, AnimatedArtworkOutcome.found);
      expect(calls, hasLength(1));
    });

    test('a lookup error is logged with its readable message', () async {
      final lines = <String>[];
      final lookup = AppleAnimatedArtworkLookup(
        handleUrl: (_) async => throw PlatformException(
          code: 'extension_error',
          message: 'no extension found to handle URL',
        ),
        directory: () async => dir,
        now: () => clock,
        log: lines.add,
        retryDelays: const [Duration.zero],
      );
      await lookup.lookup(_track());
      final line = lines.firstWhere((l) => l.startsWith('lookup error'));
      expect(line, contains('phase=lookup'));
      expect(line, contains('code=extension_error'));
      expect(line, contains('no extension found to handle URL'));
      final long = describeLookupError(StateError('x' * 500));
      expect(long.length, lessThan(260));
      lookup.recordSaveFailure(_track());
      expect(lines.last, contains('phase=download'));
    });

    test('a failed save blocks new attempts for a few minutes', () {
      final lookup = build((_) async => null);
      expect(lookup.saveBlocked(_track()), isFalse);
      lookup.recordSaveFailure(_track());
      expect(lookup.saveBlocked(_track()), isTrue);
      clock = clock.add(const Duration(minutes: 6));
      expect(lookup.saveBlocked(_track()), isFalse);
    });

    group('startup gate and plugin version', () {
      Future<Map<String, dynamic>?> none(String _) async => {
        'success': true,
        'type': 'animated_artwork',
        'id': '1001',
      };

      AppleAnimatedArtworkLookup gated({
        required Future<void> Function() ready,
        required String Function() version,
        Duration readyTimeout = const Duration(seconds: 15),
        AnimatedArtworkHandler? handler,
      }) => AppleAnimatedArtworkLookup(
        handleUrl: (url) {
          calls.add(url);
          return (handler ?? none)(url);
        },
        directory: () async => dir,
        now: () => clock,
        log: (_) {},
        retryDelays: const [Duration.zero],
        ready: ready,
        readyTimeout: readyTimeout,
        pluginVersion: version,
      );

      test('the lookup waits for the add-ons before calling them', () async {
        final gate = Completer<void>();
        final lookup = gated(
          ready: () => gate.future,
          version: () => '1.4.18',
          handler: (_) async => _found({'motionDetailSquare': _video('s')}),
        );
        final pending = lookup.lookup(_track());
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(calls, isEmpty);
        gate.complete();
        expect((await pending).outcome, AnimatedArtworkOutcome.found);
        expect(calls, hasLength(1));
      });

      test('the gate never blocks longer than its timeout', () async {
        final lookup = gated(
          ready: () => Completer<void>().future,
          version: () => '1.4.17',
          readyTimeout: const Duration(milliseconds: 50),
        );
        final result = await lookup.lookup(_track());
        expect(result.outcome, AnimatedArtworkOutcome.absent);
        expect(calls, hasLength(1));
      });

      test('a failing gate lets the lookup go ahead', () async {
        final lookup = gated(
          ready: () async => throw StateError('boom'),
          version: () => '1.4.17',
        );
        final result = await lookup.lookup(_track());
        expect(result.outcome, AnimatedArtworkOutcome.absent);
      });

      test('an absence from an older add-on version is discarded', () async {
        var version = '1.4.17';
        final first = gated(ready: () async {}, version: () => version);
        final result = await first.lookup(_track());
        expect(result.outcome, AnimatedArtworkOutcome.absent);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        calls.clear();
        final same = gated(ready: () async {}, version: () => version);
        await same.lookup(_track());
        expect(calls, isEmpty, reason: 'same version keeps the absence');
        version = '1.4.18';
        final upgraded = gated(
          ready: () async {},
          version: () => version,
          handler: (_) async => _found({'motionDetailSquare': _video('s')}),
        );
        final again = await upgraded.lookup(_track());
        expect(again.outcome, AnimatedArtworkOutcome.found);
        expect(calls, hasLength(1));
      });

      test(
        'the in-memory absence is dropped when the version changes',
        () async {
          var version = '1.4.17';
          var found = false;
          final lookup = gated(
            ready: () async {},
            version: () => version,
            handler: (_) async =>
                found ? _found({'motionDetailSquare': _video('s')}) : none(''),
          );
          final first = await lookup.lookup(_track());
          expect(first.outcome, AnimatedArtworkOutcome.absent);
          found = true;
          version = '1.4.18';
          final second = await lookup.lookup(_track());
          expect(second.outcome, AnimatedArtworkOutcome.found);
        },
      );

      test('absences saved in the v2 file are ignored', () async {
        final old = File('${dir.path}/apple_animated_artwork_absent_v2.json');
        await old.writeAsString('{"a|mainartist|albumname": 1767225600000}');
        final lookup = gated(ready: () async {}, version: () => '1.4.18');
        await lookup.lookup(_track());
        expect(calls, hasLength(1));
      });
    });
  });
  group('art request parameters', () {
    Track audioTrack({String? isrc, String name = 'EL LOKERON (Explicit)'}) =>
        Track(
          id: 'deezer:2955547161',
          name: name,
          artistName: 'Tito Double P, Junior H',
          albumName: 'INCÓMODO',
          albumId: '632040491',
          isrc: isrc,
          duration: 145,
          source: 'deezer',
        );

    test('never passes ids of the audio provider', () {
      final params = animatedArtworkRequestParams(
        audioTrack(isrc: 'qm7-282-478047'),
        storefront: 'mx',
      );
      expect(params.containsKey('track_id'), isFalse);
      expect(params.containsKey('album_id'), isFalse);
      expect(params['isrc'], 'QM7282478047');
      expect(params['title'], 'EL LOKERON');
      expect(params['artist'], 'Tito Double P, Junior H');
      expect(params['album'], 'INCÓMODO');
      expect(params['duration_ms'], '145000');
      expect(params['storefront'], 'mx');
    });

    test('drops an ISRC that is not twelve letters and digits', () {
      expect(
        animatedArtworkRequestParams(audioTrack(isrc: 'ZZZ')),
        isNot(contains('isrc')),
      );
      expect(normalizedArtworkIsrc(' qm7282478047 '), 'QM7282478047');
    });

    test('the URL carries accents and spaces as the add-on parses them', () {
      final uri = Uri.parse(
        animatedArtworkLookupUrl(audioTrack(isrc: 'QM7282478047')),
      );
      expect(uri.scheme, 'apple-music');
      expect(uri.queryParameters['album'], 'INCÓMODO');
      expect(uri.queryParameters['artist'], 'Tito Double P, Junior H');
    });
  });

  group('editorial video packed in header_video', () {
    test('is read when editorial_video was dropped on the way', () {
      final packed = jsonEncode({
        'motionDetailSquare': _video('sq'),
        'motionDetailTall': _video('tall'),
      });
      final result = classifyAnimatedArtworkResponse({
        'success': true,
        'type': 'animated_artwork',
        'id': '1761411580',
        'name': 'INCÓMODO',
        'header_video': packed,
      });
      expect(result.outcome, AnimatedArtworkOutcome.found);
      expect(result.variants.square, isNotNull);
      expect(result.variants.tall, isNotNull);
    });

    test('describes the request and the resolved album without secrets', () {
      final text = describeAnimatedArtworkLookup(
        {'isrc': 'QM7282478047', 'storefront': 'us'},
        {
          'id': '1761411580',
          'name': 'INCÓMODO',
          'editorial_video': {'motionDetailSquare': _video('sq')},
          'attempts': 'us:1761411580:video',
        },
      );
      expect(text, contains('isrc=QM7282478047'));
      expect(text, contains('resolved album=1761411580'));
      expect(text, contains('editorialVideo=true keys=motionDetailSquare'));
    });
  });
}
