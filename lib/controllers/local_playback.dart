import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/catalog_identity.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

/// The history's legacy spotifyId may contain an ID from any catalog, while
/// service describes the download service, not necessarily the ID's source.
bool historyMatchesTrack(Track track, DownloadHistoryItem item) =>
    matchesCatalogIdentity(
      track,
      isrc: item.isrc,
      title: item.trackName,
      artist: item.artistName,
      durationSeconds: item.duration,
    );

bool matchesCatalogIdentity(
  Track track, {
  required String? isrc,
  required String title,
  required String artist,
  int? durationSeconds,
}) => sameCatalogRecording(
  wantedIsrc: track.isrc,
  wantedTitle: track.name,
  wantedArtist: track.artistName,
  wantedDurationSeconds: track.duration,
  isrc: isrc,
  title: title,
  artist: artist,
  durationSeconds: durationSeconds,
);

/// Resolves history candidates without trusting the legacy, unscoped ID.
Future<DownloadHistoryItem?> findMatchingHistory(
  Track track, {
  required Future<DownloadHistoryItem?> Function(String) byId,
  required Future<DownloadHistoryItem?> Function(String) byIsrc,
  required Future<DownloadHistoryItem?> Function(String, String) byName,
  Future<bool> Function(DownloadHistoryItem)? isAvailable,
}) async {
  final isrc = track.isrc?.trim();
  final lookups = <Future<DownloadHistoryItem?> Function()>[
    () => byId(track.id),
    if (isrc != null && isrc.isNotEmpty) () => byIsrc(isrc),
    () => byName(track.name, track.artistName),
  ];
  final checked = <(String, String)>{};
  for (final lookup in lookups) {
    final candidate = await lookup();
    if (candidate == null || !historyMatchesTrack(track, candidate)) continue;
    if (!checked.add((candidate.id, candidate.filePath))) continue;
    if (isAvailable == null || await isAvailable(candidate)) {
      return candidate;
    }
  }
  return null;
}

/// Plays [track] from download history or the local library when a matching
/// file already exists on disk.
///
/// Returns true when playback started (or when an error was surfaced to the
/// user), so callers can skip enqueueing a download; returns false when no
/// local copy is available. Stale history entries whose file no longer exists
/// are pruned as a side effect.
Future<bool> playLocalIfAvailable(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final historyNotifier = ref.read(downloadHistoryProvider.notifier);

  try {
    final isrc = track.isrc?.trim();
    final candidates = await historyNotifier.findTrackCandidatesAsync(
      HistoryLookupRequest(
        spotifyId: track.id,
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
    );
    DownloadHistoryItem? historyItem;
    for (final candidate in candidates) {
      if (!historyMatchesTrack(track, candidate)) continue;
      // A remote library identity is not a locally saved audio file.
      // Keep its history intact and leave network playback explicit.
      if (candidate.filePath.startsWith('network://')) continue;
      if (isDesktopPlatform && isContentUri(candidate.filePath)) continue;
      if (await fileExists(candidate.filePath)) {
        historyItem = candidate;
        break;
      }
      final existence = await fileExistenceByPath([candidate.filePath]);
      if (existence[candidate.filePath] == false) {
        await historyNotifier.removeFromHistory(candidate.id);
      }
    }

    if (!context.mounted) return true;
    if (historyItem != null) {
      await ref
          .read(playbackProvider.notifier)
          .playLocalPath(
            path: historyItem.filePath,
            title: track.name,
            artist: track.artistName,
            album: track.albumName,
            coverUrl: track.coverUrl ?? '',
          );
      return true;
    }

    if (!ref.read(settingsProvider).localLibraryEnabled) return false;
    final localItem = await ref
        .read(localLibraryProvider.notifier)
        .findExistingAsync(
          isrc: isrc,
          trackName: track.name,
          artistName: track.artistName,
        );

    if (localItem != null &&
        matchesCatalogIdentity(
          track,
          isrc: localItem.isrc,
          title: localItem.trackName,
          artist: localItem.artistName,
        ) &&
        !localItem.filePath.startsWith('network://') &&
        await fileExists(localItem.filePath)) {
      if (!context.mounted) return true;
      await ref
          .read(playbackProvider.notifier)
          .playLocalPath(
            path: localItem.filePath,
            title: localItem.trackName,
            artist: localItem.artistName,
            album: localItem.albumName,
            coverUrl: localItem.coverPath ?? track.coverUrl ?? '',
          );
      return true;
    }
  } catch (e) {
    if (context.mounted) showCannotOpenFileSnackBar(context, e);
    return true;
  }

  return false;
}
