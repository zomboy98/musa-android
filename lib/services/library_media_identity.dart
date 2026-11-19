import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/isrc_utils.dart';

/// The download or Library record of the file a media item plays: by its
/// source path, then by its media id when the path agrees (or is unavailable),
/// then by title and artist with the same path. Null when there is no match.
Future<UnifiedLibraryItem?> libraryItemForMedia({
  required String id,
  required String source,
  required String title,
  required String artist,
  required Future<DownloadHistoryItem?> Function(String path) historyByPath,
  required LibraryDatabase library,
}) async {
  if (source.isNotEmpty) {
    final history = await historyByPath(source);
    if (history != null) return UnifiedLibraryItem.fromDownloadHistory(history);
  }
  final row = await library.getById(id);
  if (row != null) {
    final local = LocalLibraryItem.fromJson(row);
    if (source.isEmpty || local.filePath == source) {
      return UnifiedLibraryItem.fromLocalLibrary(local);
    }
  }
  if (source.isNotEmpty) {
    final matches = await library.findByTrackAndArtist(title, artist);
    for (final row in matches) {
      final local = LocalLibraryItem.fromJson(row);
      if (local.filePath == source) {
        return UnifiedLibraryItem.fromLocalLibrary(local);
      }
    }
  }
  return null;
}

/// The collection track that loves [item]: its Library record's identity
/// when it has one ([match]), otherwise the media item's own fields, with
/// no cover when the item shows one that does not outlast this run.
///
/// A network song keeps the network cover it shows, or shows once fetched,
/// as its reference (`extras['artworkRef']`), which [covers] fetches again
/// after a trim, rather than the stored file.
Track collectionTrackForMedia(
  MediaItem item,
  UnifiedLibraryItem? match, {
  CoverStore? covers,
}) {
  if (match != null) {
    final track = match.toTrack();
    final carried = mediaItemIsrc(item);
    if (normalizeIsrc(track.isrc).isEmpty && carried.isNotEmpty) {
      return track.copyWith(isrc: carried);
    }
    return track;
  }
  final source = item.extras?['source'];
  if (source is String && source.startsWith('catalog:') && item.id == source) {
    final catalog = PlayableMedia(
      id: item.id,
      source: source,
      title: item.title,
      artist: item.artist ?? '',
    ).catalogTrack;
    if (catalog != null &&
        catalog.source?.trim().toLowerCase() != 'local' &&
        (catalog.id.trim().isNotEmpty ||
            (catalog.isrc?.trim().isNotEmpty ?? false))) {
      return catalog;
    }
  }
  return Track(
    id: item.id,
    name: item.title,
    artistName: item.artist ?? '',
    albumName: item.album ?? '',
    coverUrl: _collectionCover(item, covers ?? CoverStore.instance),
    isrc: mediaItemIsrc(item).isEmpty ? null : mediaItemIsrc(item),
    duration: item.duration?.inSeconds ?? 0,
    source: 'local',
  );
}

/// The ISRC a media item carries from the song it was built from.
String mediaItemIsrc(MediaItem item) {
  final extras = item.extras;
  final direct = normalizeIsrc(extras?['isrc']?.toString());
  if (direct.isNotEmpty) return direct;
  final display = extras?['displayMetadata'];
  return display is Map ? normalizeIsrc(display['isrc']?.toString()) : '';
}

/// Where the ISRC used for animated artwork came from: `catalog` for a
/// catalog song, `library` for a Library or download record, `fallback` when
/// only the media item carried it, and `none` when there is no ISRC.
String animatedArtworkIsrcSource(MediaItem item, Track track) {
  final isrc = normalizeIsrc(track.isrc);
  if (isrc.isEmpty) return 'none';
  final source = item.extras?['source'];
  if (source is String && source.startsWith('catalog:')) {
    final catalog = PlayableMedia(
      id: item.id,
      source: source,
      title: item.title,
      artist: item.artist ?? '',
    ).catalogTrack;
    if (normalizeIsrc(catalog?.isrc) == isrc) return 'catalog';
  }
  if (track.id == item.id && mediaItemIsrc(item) == isrc) return 'fallback';
  return 'library';
}

String? _lastIsrcLog;

void logAnimatedArtworkIsrc(MediaItem item, Track track) {
  final line =
      'animated artwork: isrc source=${animatedArtworkIsrcSource(item, track)}';
  final key = '${item.id}|$line';
  if (_lastIsrcLog == key) return;
  _lastIsrcLog = key;
  debugPrint(line);
}

String? _collectionCover(MediaItem item, CoverStore covers) {
  final reference = item.extras?['artworkRef']?.toString();
  final shown = item.artUri;
  if (CoverStore.refetches(reference)) {
    // Unless the item shows another cover, such as the one from its tags.
    final stored = covers.indexedFile(reference);
    if (shown == null || (stored != null && shown == Uri.file(stored))) {
      return reference;
    }
  }
  return durableCoverReference(shown?.toString());
}
