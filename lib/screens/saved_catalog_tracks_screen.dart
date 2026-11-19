import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

/// Catalog references are separate from downloaded or scanned audio files.
class SavedCatalogTracksScreen extends ConsumerWidget {
  const SavedCatalogTracksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(savedLibraryTracksProvider);
    final queue = ref.watch(downloadQueueProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.savedCatalogTracks)),
      body: tracks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            Center(child: Text(context.l10n.savedCatalogTracksError)),
        data: (items) => items.isEmpty
            ? Center(child: Text(context.l10n.savedCatalogTracksEmpty))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final track = items[index];
                  final matches = queue.items.where(
                    (item) =>
                        item.track.id == track.id &&
                        item.track.source == track.source,
                  );
                  final item = matches.isEmpty ? null : matches.last;
                  final active =
                      item != null &&
                      (item.status == DownloadStatus.queued ||
                          item.status == DownloadStatus.downloading ||
                          item.status == DownloadStatus.finalizing);
                  final failed = item?.status == DownloadStatus.failed;
                  final status = switch (item?.status) {
                    DownloadStatus.queued =>
                      context.l10n.linkDownloadStatusQueued,
                    DownloadStatus.downloading =>
                      context.l10n.linkDownloadStatusDownloading,
                    DownloadStatus.finalizing =>
                      context.l10n.queueFinalizingDownload,
                    DownloadStatus.failed =>
                      context.l10n.linkDownloadStatusFailed,
                    _ => null,
                  };
                  return ListTile(
                    title: Text(track.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IgnorePointer(
                          child: ClickableArtistName(
                            artistName: track.artistName,
                            artistId: track.artistId,
                            extensionId: track.source,
                          ),
                        ),
                        if (status != null)
                          Consumer(
                            builder: (context, ref, _) {
                              final recovered =
                                  failed &&
                                  ref
                                          .watch(
                                            playlistRealDownloadProvider(track),
                                          )
                                          .value ==
                                      true;
                              final cause = failureCauseForDownload(
                                item?.errorType,
                              );
                              return recovered
                                  ? const SizedBox.shrink()
                                  : Text(
                                      cause == null
                                          ? status
                                          : '$status: ${failureMessage(context.l10n, cause)}',
                                    );
                            },
                          ),
                      ],
                    ),
                    onTap: () async {
                      try {
                        final playback = ref.read(playbackProvider.notifier);
                        if (await playback.openPlayerIfCurrent(track: track)) {
                          return;
                        }
                        await playback.playTrackList([track]);
                      } catch (error) {
                        if (context.mounted) {
                          showCannotOpenFileSnackBar(context, error);
                        }
                      }
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SaveLibraryTrackButton(
                          track: track,
                          downloadEnabled: !active,
                          downloadFailed: failed,
                        ),
                        TrackCollectionQuickActions(track: track),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
