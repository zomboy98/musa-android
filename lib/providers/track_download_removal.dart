import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/playlist_download_status.dart';

final _log = AppLogger('TrackDownloadRemoval');

/// Every file path that makes [track] count as downloaded: history rows,
/// the private inventory, scanned library rows and persistent catalog audio.
Future<Set<String>> localFilePathsForTrack(
  ProviderContainer container,
  Track track,
) async {
  final paths = <String>{};
  try {
    paths.addAll(
      (await DownloadFileInventory.candidatePathsBatch([track])).first,
    );
  } catch (error) {
    _log.w('Inventory lookup failed: $error');
  }
  try {
    final items = await container
        .read(downloadHistoryProvider.notifier)
        .findTrackCandidatesAsync(historyLookupForTrack(track));
    for (final item in items) {
      if (historyMatchesTrack(track, item)) paths.add(item.filePath);
    }
  } catch (error) {
    _log.w('History lookup failed: $error');
  }
  try {
    final library = await container
        .read(localLibraryProvider.notifier)
        .findTrackCandidatesBatch([
          LocalLibraryBatchLookupRequest(
            isrc: track.isrc,
            trackName: track.name,
            artistName: track.artistName,
          ),
        ]);
    for (final item in library.first) {
      if (matchesCatalogIdentity(
        track,
        isrc: item.isrc,
        title: item.trackName,
        artist: item.artistName,
        durationSeconds: item.duration,
      )) {
        paths.add(item.filePath);
      }
    }
  } catch (error) {
    _log.w('Library lookup failed: $error');
  }
  try {
    final store = await container.read(catalogAudioStoreProvider);
    final entry = await store.lookup(catalogPlayback.key(track));
    if (entry != null && entry.persistent) paths.add(entry.path);
  } catch (_) {
    // Catalog audio may be unavailable while the other sources are usable.
  }
  return {
    for (final path in paths)
      if (path.isNotEmpty && !path.startsWith('network://')) path,
  };
}

/// Deletes the local files of [track] and clears every row that pointed at
/// them, so no view keeps showing it as downloaded. Paths whose existence
/// cannot be determined (unplugged disk, revoked folder access) are left
/// untouched. Returns the number of files actually deleted.
Future<int> removeTrackDownloads(
  ProviderContainer container,
  Track track,
) async {
  final paths = await localFilePathsForTrack(container, track);
  if (paths.isEmpty) return 0;
  final existence = await fileExistenceByPath(paths.toList());
  final cleared = <String>[];
  var deleted = 0;
  for (final path in paths) {
    final present = existence[path];
    if (present == null) continue;
    if (present) {
      if (!await deleteFile(path)) continue;
      deleted++;
    }
    cleared.add(path);
  }
  await removeDeletedLibraryFileEntries(container, cleared);
  return deleted;
}
