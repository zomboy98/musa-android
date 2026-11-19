import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/isrc_track_lookup.dart';
import 'package:mornye/utils/isrc_utils.dart';

Map<String, dynamic> _deezerHit() => {
  'success': true,
  'id': '363747251',
  'track_id': '363747251',
  'spotify_id': 'deezer:363747251',
  'name': 'Cut To The Feeling',
  'artists': 'Carly Rae Jepsen',
  'album_name': 'Cut To The Feeling',
  'duration_ms': 208000,
  'isrc': 'USUM71703861',
};

void main() {
  group('isrcFromSearchQuery', () {
    test('accepts compact, hyphenated, spaced and lowercase forms', () {
      for (final input in [
        'USUM71703861',
        'us-um7-17-03861',
        'US UM7 17 03861',
        '  usum71703861 ',
      ]) {
        expect(isrcFromSearchQuery(input), 'USUM71703861', reason: input);
      }
    });

    test('rejects ordinary text and malformed codes', () {
      for (final input in [
        '',
        'Cut To The Feeling',
        'USUM7170386',
        'USUM717038612',
        '1SUM71703861',
        'USUM7170386A',
        'https://example.com/USUM71703861',
      ]) {
        expect(isrcFromSearchQuery(input), isNull, reason: input);
      }
    });
  });

  group('lookupTrackByIsrc', () {
    test(
      'returns the track with its ISRC and queries the normalized code',
      () async {
        String? asked;
        final track = await lookupTrackByIsrc(
          'us-um7-17-03861',
          lookup: (isrc) async {
            asked = isrc;
            return _deezerHit();
          },
        );
        expect(asked, 'USUM71703861');
        expect(track?.name, 'Cut To The Feeling');
        expect(track?.isrc, 'USUM71703861');
        expect(track?.id, 'deezer:363747251');
      },
    );

    test('does not call the backend for non-ISRC text', () async {
      var calls = 0;
      final track = await lookupTrackByIsrc(
        'hello world',
        lookup: (_) async {
          calls++;
          return _deezerHit();
        },
      );
      expect(track, isNull);
      expect(calls, 0);
    });

    test('returns null on miss, error and timeout', () async {
      expect(
        await lookupTrackByIsrc(
          'USUM71703861',
          lookup: (_) async => {'success': false},
        ),
        isNull,
      );
      expect(
        await lookupTrackByIsrc(
          'USUM71703861',
          lookup: (_) async => throw Exception('network'),
        ),
        isNull,
      );
      expect(
        await lookupTrackByIsrc(
          'USUM71703861',
          timeout: const Duration(milliseconds: 20),
          lookup: (_) => Completer<Map<String, dynamic>>().future,
        ),
        isNull,
      );
    });
  });

  group('TrackNotifier.searchByIsrc', () {
    test('shows the resolved track as a normal result', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final handled = await container
          .read(trackProvider.notifier)
          .searchByIsrc('usum71703861', lookup: (_) async => _deezerHit());
      final state = container.read(trackProvider);
      expect(handled, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.tracks.single.isrc, 'USUM71703861');
    });

    test(
      'returns false so the text search runs when nothing resolves',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(trackProvider.notifier);
        expect(
          await notifier.searchByIsrc(
            'USUM71703861',
            lookup: (_) async => throw Exception('down'),
          ),
          isFalse,
        );
        expect(await notifier.searchByIsrc('not an isrc'), isFalse);
        expect(container.read(trackProvider).tracks, isEmpty);
      },
    );
  });
}
