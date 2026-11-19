import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/utils/saf_download_tree.dart';
import 'package:mornye/widgets/download_progress_icon.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/remove_track_download.dart';
import 'package:mornye/widgets/add_to_music_sheet.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

final _touchTarget = IconButton.styleFrom(
  minimumSize: const Size.square(44),
  tapTargetSize: MaterialTapTargetSize.padded,
);

/// Saves a catalog reference and optionally queues a newly saved song.
class SaveLibraryTrackButton extends ConsumerStatefulWidget {
  const SaveLibraryTrackButton({
    super.key,
    required this.track,
    this.onDownload,
    this.downloadEnabled = true,
    this.downloadFailed = false,
  });

  final Track track;
  final VoidCallback? onDownload;
  final bool downloadEnabled;
  final bool downloadFailed;

  @override
  ConsumerState<SaveLibraryTrackButton> createState() =>
      _SaveLibraryTrackButtonState();
}

class _SaveLibraryTrackButtonState
    extends ConsumerState<SaveLibraryTrackButton> {
  /// Set at the tap so the icon reacts before the queue (which first awaits
  /// its restore and file checks) registers the item.
  final ValueNotifier<bool> _tapped = ValueNotifier<bool>(false);
  Timer? _tappedTimer;

  void _markTapped() {
    _tappedTimer?.cancel();
    _tapped.value = true;
    // The queue item takes over; this only covers a request that never
    // registers (no provider, quality picker dismissed, already available).
    _tappedTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _tapped.value = false;
    });
  }

  bool _isInFlight() {
    final item = ref
        .read(downloadQueueLookupProvider)
        .byTrackId[widget.track.id];
    return item != null &&
        (item.status == DownloadStatus.queued ||
            item.status == DownloadStatus.downloading ||
            item.status == DownloadStatus.finalizing);
  }

  /// Android only: the failed item points at a lost download folder grant.
  bool _lostFolderAccess() {
    if (!Platform.isAndroid) return false;
    final item = ref
        .read(downloadQueueLookupProvider)
        .byTrackId[widget.track.id];
    return item != null &&
        item.status == DownloadStatus.failed &&
        (item.errorType == DownloadErrorType.permission ||
            item.error == safPermissionLostErrorMessage ||
            item.error == downloadFolderAccessLostErrorMessage);
  }

  bool _removing = false;

  /// One tap on the check removes the local file everywhere the song shows
  /// as downloaded; the song stays in its playlists as a streaming track.
  Future<void> _removeDownload() async {
    if (_removing) return;
    _removing = true;
    try {
      await removeTrackDownloadWithFeedback(context, widget.track);
    } finally {
      _removing = false;
    }
  }

  @override
  void dispose() {
    _tappedTimer?.cancel();
    _tapped.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trackKey = trackCollectionKey(widget.track);
    final contains = ref.watch(
      savedLibraryTrackKeysProvider.select((keys) => keys.contains(trackKey)),
    );
    final savedUnavailable = ref.watch(savedLibraryTracksUnavailableProvider);
    final downloaded =
        ref.watch(playlistRealDownloadProvider(widget.track)).value == true;
    final offline =
        ref.watch(playlistOfflineAudioProvider(widget.track)).value == true;
    final available = downloaded || offline;
    final canDownload = !downloaded && widget.downloadEnabled;
    final l10n = context.l10n;
    final failureCause = widget.downloadFailed
        ? failureCauseForDownload(
            ref.watch(
              downloadQueueLookupProvider.select(
                (queue) => queue.byTrackId[widget.track.id]?.errorType,
              ),
            ),
          )
        : null;
    final downloadAction = widget.downloadFailed
        ? failureCause == null
              ? l10n.dialogRetry
              : '${failureMessage(l10n, failureCause)} • ${l10n.dialogRetry}'
        : l10n.dialogDownload;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('save-library-track'),
          style: _touchTarget,
          tooltip: contains
              ? '${context.l10n.libraryInLibrary} • ${MaterialLocalizations.of(context).showMenuTooltip}'
              : context.l10n.saveCatalogTrack,
          icon: Icon(contains ? Icons.check_circle : Icons.add_circle_outline),
          onPressed: savedUnavailable
              ? null
              : () => showAddToMusicSheet(context, ref, widget.track),
        ),
        IconButton(
          key: const ValueKey('download-library-track'),
          style: _touchTarget,
          tooltip: available ? l10n.trackRemoveFromDevice : downloadAction,
          icon: TrackDownloadProgressIcon(
            track: widget.track,
            available: available,
            failed: widget.downloadFailed,
            pending: _tapped,
          ),
          onPressed: available
              ? _removeDownload
              : !canDownload
              ? null
              : () async {
                  // A second tap while the song is already waiting or
                  // transferring must not enqueue it again.
                  if (_tapped.value || _isInFlight()) return;
                  _markTapped();
                  // The last attempt failed for lack of folder access: pick
                  // the folder again before retrying.
                  if (_lostFolderAccess()) {
                    var picked = false;
                    try {
                      picked = await pickAndStoreSafDownloadTree(ref);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              l10n.snackbarFolderPickerFailed(
                                context.friendlyError(error),
                              ),
                            ),
                          ),
                        );
                      }
                    }
                    if (!mounted) return;
                    if (!picked) {
                      _tapped.value = false;
                      return;
                    }
                  }
                  final onDownload = widget.onDownload;
                  if (onDownload != null) {
                    onDownload();
                  } else {
                    downloadSingleTrack(context, ref, widget.track);
                  }
                },
        ),
      ],
    );
  }
}
