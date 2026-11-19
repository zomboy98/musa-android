import 'package:flutter/material.dart';
import 'package:mornye/utils/extension_error_message.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/logger.dart';

/// Adds a track using the configured download provider and quality.
Future<void> downloadSingleTrack(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  String? recommendedService,
  String? playlistName,
  int? playlistPosition,
  bool forceQualityPicker = false,
  String? qualityOverride,
}) async {
  final settings = ref.read(settingsProvider);

  final extensionState = ref.read(extensionProvider);
  final service = resolveConfiguredDownloadService(
    settings.defaultService,
    extensionState,
    autoFallback: settings.autoFallback,
  );
  if (service.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          noDownloadProviderMessage(
            context.l10n,
            noDownloadProviderCause(extensionState),
          ),
        ),
      ),
    );
    return;
  }
  await ref
      .read(downloadQueueProvider.notifier)
      .addSavedTrackToQueue(
        track,
        service,
        playlistName: playlistName,
        playlistPosition: playlistPosition,
        qualityOverride: qualityOverride,
      );
}

/// Shared "download all" confirmation dialog for detail screens
/// (album/playlist/library-folder).
void confirmDownloadAllDialog(
  BuildContext context,
  int trackCount,
  VoidCallback onConfirm,
) {
  if (trackCount == 0) return;
  showAppDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AppAlertDialog(
        title: Text(context.l10n.dialogDownloadAllTitle),
        content: Text(context.l10n.dialogDownloadAllMessage(trackCount)),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () {
              Navigator.pop(dialogContext);
              onConfirm();
            },
            child: Text(context.l10n.dialogDownload),
          ),
        ],
      );
    },
  );
}

Future<List<SavedDownloadPathStatus>> _batchDownloadStatuses(
  List<Track> tracks,
  LocalLibraryNotifier? localLibrary,
  bool Function() isCurrent,
  String downloadDirectory,
) async {
  final paths = await DownloadFileInventory.candidatePathsBatch(tracks);
  if (!isCurrent()) return const [];
  final history = await HistoryDatabase.instance.findTrackCandidatesBatch(
    tracks.map(historyLookupForTrack).toList(growable: false),
  );
  if (!isCurrent()) return const [];
  final local = await localLibrary?.findTrackCandidatesBatch([
    for (final track in tracks)
      LocalLibraryBatchLookupRequest(
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
  ]);
  final probes = <String, Future<SavedDownloadPathStatus>>{};
  Future<SavedDownloadPathStatus> check(int index) async {
    final track = tracks[index];
    var status = SavedDownloadPathStatus.missing;
    final matchingPaths = [
      ...paths[index],
      for (final item in history[index].map(DownloadHistoryItem.fromJson))
        if (historyMatchesTrack(track, item)) item.filePath,
      for (final item in local?[index] ?? const <LocalLibraryItem>[])
        if (matchesCatalogIdentity(
          track,
          isrc: item.isrc,
          title: item.trackName,
          artist: item.artistName,
          durationSeconds: item.duration,
        ))
          item.filePath,
    ];
    for (final path in matchingPaths) {
      if (!isCurrent()) return status;
      final candidate = await probes.putIfAbsent(
        path,
        () =>
            savedDownloadPathStatus(path, downloadDirectory: downloadDirectory),
      );
      if (candidate == SavedDownloadPathStatus.accessible) return candidate;
      if (candidate == SavedDownloadPathStatus.unavailable) status = candidate;
    }
    return status;
  }

  // Bound concurrent file and SAF opens, and reuse results for repeated paths.
  const chunkSize = 12;
  final result = <SavedDownloadPathStatus>[];
  for (var start = 0; start < tracks.length; start += chunkSize) {
    if (!isCurrent()) return const [];
    final end = (start + chunkSize).clamp(0, tracks.length);
    result.addAll(
      await Future.wait([
        for (var index = start; index < end; index++) check(index),
      ]),
    );
  }
  return result;
}

/// Queues tracks with no accessible copy. Unavailable storage is reported
/// separately so it cannot silently cause another download.
Future<void> queueTracksSkippingDownloaded(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  required String artistNameForPicker,
  String? recommendedService,
  String? playlistName,
  DownloadOrigin? origin,
  bool resolveDefaultService = true,
  bool forceQualityPicker = false,
  VoidCallback? onQueued,
  String? qualityOverride,
  ValueChanged<List<String>>? onAdmitted,
}) async {
  if (tracks.isEmpty) return;

  final settings = ref.read(settingsProvider);
  final skipExisting =
      settings.deduplicateDownloads && !settings.allowQualityVariants;
  final queue = ref.read(downloadQueueProvider.notifier);
  void publish(List<Track> tracksToQueue, {bool hasUnavailableTracks = false}) {
    String service;
    {
      final extensionState = ref.read(extensionProvider);
      service = resolveConfiguredDownloadService(
        settings.defaultService,
        extensionState,
        autoFallback: settings.autoFallback,
      );
      if (service.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              noDownloadProviderMessage(
                context.l10n,
                noDownloadProviderCause(extensionState),
              ),
            ),
          ),
        );
        return;
      }
    }
    final admitted = queue.addMultipleToQueue(
      tracksToQueue,
      service,
      playlistName: playlistName,
      origin: origin,
      allowQualityVariants: settings.allowQualityVariants,
      qualityOverride: qualityOverride,
    );
    if (admitted.isNotEmpty) onAdmitted?.call(admitted);
    if (!hasUnavailableTracks) onQueued?.call();
  }

  if (!skipExisting) {
    publish(tracks);
    return;
  }
  final localLibrary =
      settings.localLibraryEnabled && settings.localLibraryShowDuplicates
      ? ref.read(localLibraryProvider.notifier)
      : null;
  try {
    await queue.checkDownloadBatch(
      tracks,
      isMounted: () => context.mounted,
      check: (isCurrent) => _batchDownloadStatuses(
        tracks,
        localLibrary,
        isCurrent,
        settings.downloadDirectory,
      ),
      publish: (statuses) {
        final tracksToQueue = [
          for (var index = 0; index < tracks.length; index++)
            if (statuses[index] == SavedDownloadPathStatus.missing)
              tracks[index],
        ];
        final hasUnavailableTracks = statuses.contains(
          SavedDownloadPathStatus.unavailable,
        );
        final messenger = ScaffoldMessenger.of(context);
        if (hasUnavailableTracks) {
          messenger.showSnackBar(
            SnackBar(content: Text(context.l10n.trackFileUnavailable)),
          );
        } else if (tracksToQueue.isEmpty) {
          final skipped = statuses
              .where((status) => status == SavedDownloadPathStatus.accessible)
              .length;
          if (skipped > 0) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.discographySkippedDownloaded(0, skipped),
                ),
              ),
            );
          }
        }
        if (tracksToQueue.isNotEmpty) {
          publish(tracksToQueue, hasUnavailableTracks: hasUnavailableTracks);
        }
      },
    );
  } catch (error) {
    AppLogger('DownloadFlow').w('Could not check batch downloads: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.trackFileUnavailable)),
      );
    }
  }
}

/// "dd/MM/yyyy" or "MM/yyyy" formatting for a backend release date string.
String formatReleaseDate(String date) {
  if (date.length >= 10) {
    final parts = date.substring(0, 10).split('-');
    if (parts.length == 3) {
      return '${parts[2]}/${parts[1]}/${parts[0]}';
    }
  } else if (date.length >= 7) {
    final parts = date.split('-');
    if (parts.length >= 2) {
      return '${parts[1]}/${parts[0]}';
    }
  }
  return date;
}

/// Shared release-date/track-count/duration footer for album/playlist detail
/// screens. Set [excludeEpochReleaseDate] to hide a `1970-...` placeholder
/// release date (playlists can carry one; albums never do).
Widget buildTrackListFooter(
  BuildContext context,
  ColorScheme colorScheme,
  List<Track> tracks, {
  bool excludeEpochReleaseDate = false,
}) {
  if (tracks.isEmpty) {
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  final releaseDate = tracks.first.releaseDate;
  final totalSeconds = tracks.fold<int>(
    0,
    (sum, t) => sum + (t.duration > 0 ? t.duration : 0),
  );
  final totalMinutes = (totalSeconds / 60).round();

  final lines = <String>[];
  final hasReleaseDate =
      releaseDate != null &&
      releaseDate.isNotEmpty &&
      (!excludeEpochReleaseDate || !releaseDate.startsWith('1970'));
  if (hasReleaseDate) {
    lines.add(formatReleaseDate(releaseDate));
  }
  final countText = context.l10n.tracksCount(tracks.length);
  lines.add(totalMinutes > 0 ? '$countText • $totalMinutes min' : countText);

  // Lines up with the track list, which centers on tablets.
  final inset = wideListInset(context);
  return SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(20 + inset, 8, 20 + inset, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Shared "love all / unlove all" batch toggle for album/playlist detail
/// screens.
Future<void> loveAllTracks(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final result = await ref
      .read(libraryCollectionsProvider.notifier)
      .toggleLovedTracks(tracks);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.removed
              ? context.l10n.snackbarRemovedTracksFromLoved(result.count)
              : context.l10n.snackbarAddedTracksToLoved(result.count),
        ),
      ),
    );
  }
}
