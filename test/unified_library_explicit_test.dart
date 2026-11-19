import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  for (final explicit in [true, false]) {
    test('history explicit=$explicit survives conversion and playback', () {
      final history = DownloadHistoryItem(
        id: 'history', trackName: 'Song', artistName: 'Artist',
        albumName: 'Album', filePath: '/song.mp3', service: 'example',
        downloadedAt: DateTime.utc(2025), explicit: explicit,
      );
      final restored = DownloadHistoryItem.fromJson(history.toJson());
      final track = UnifiedLibraryItem.fromDownloadHistory(restored).toTrack();
      _check(track, explicit);
      expect(track.id, history.collectionTrackId);
      expect(track.source, history.collectionTrackSource);
    });

    test('local explicit=$explicit survives conversion and playback', () {
      final local = LocalLibraryItem(
        id: 'local', trackName: 'Song', artistName: 'Artist',
        albumName: 'Album', filePath: '/song.mp3',
        scannedAt: DateTime.utc(2025), explicit: explicit,
      );
      final restored = LocalLibraryItem.fromJson(local.toJson());
      final track = UnifiedLibraryItem.fromLocalLibrary(restored).toTrack();
      _check(track, explicit);
      expect(track.id, local.id);
      expect(track.source, 'local');
    });
  }

  test('legacy records without explicit use their existing false default', () {
    final history = DownloadHistoryItem(
      id: 'history', trackName: 'Song', artistName: 'Artist',
      albumName: 'Album', filePath: '/song.mp3', service: 'example',
      downloadedAt: DateTime.utc(2025),
    );
    final local = LocalLibraryItem(
      id: 'local', trackName: 'Song', artistName: 'Artist',
      albumName: 'Album', filePath: '/song.mp3', scannedAt: DateTime.utc(2025),
    );
    final historyJson = history.toJson()..remove('explicit');
    final localJson = local.toJson()..remove('explicit');
    _check(UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem.fromJson(historyJson),
    ).toTrack(), false);
    _check(UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem.fromJson(localJson),
    ).toTrack(), false);
  });

  test('missing source metadata remains unknown on fallback track', () {
    final item = UnifiedLibraryItem(
      id: 'fallback', trackName: 'Song', artistName: 'Artist',
      albumName: 'Album', filePath: '/song.mp3', addedAt: DateTime.utc(2025),
      source: LibraryItemSource.local,
    );
    final track = item.toTrack();
    expect(track.explicit, isNull);
    expect(Track.fromJson(track.toJson()).explicit, isNull);
    final playable = playableFromCatalogTrack(track);
    expect(playable.explicit, isFalse);
    expect(playable.toMediaItem(resolvedArtwork: '').extras?['explicit'], isNull);
  });
}

void _check(Track track, bool explicit) {
  expect(track.explicit, explicit);
  expect(Track.fromJson(track.toJson()).explicit, explicit);
  final playable = playableFromCatalogTrack(track);
  expect(playable.explicit, explicit);
  expect(PlayableMedia.fromJson(playable.toJson())?.explicit, explicit);
  expect(playable.toMediaItem(resolvedArtwork: '').extras?['explicit'], explicit ? true : null);
}
