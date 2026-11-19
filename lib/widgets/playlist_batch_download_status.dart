import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';

/// Tracks the newest admitted batch for one playlist presentation.
mixin PlaylistDownloadFeedback<T extends StatefulWidget> on State<T> {
  int _submissionSequence = 0;
  int _trackedSubmission = 0;
  List<String> _downloadBatchIds = const [];

  void clearPlaylistDownloadFeedback() {
    _trackedSubmission = ++_submissionSequence;
    _downloadBatchIds = const [];
  }

  ValueChanged<List<String>> trackPlaylistDownloadBatch() {
    final submission = ++_submissionSequence;
    return (ids) {
      if (ids.isEmpty || !mounted || submission < _trackedSubmission) return;
      setState(() {
        _trackedSubmission = submission;
        _downloadBatchIds = ids;
      });
    };
  }

  Widget? get playlistDownloadFeedback {
    final ids = _downloadBatchIds;
    if (ids.isEmpty) return null;
    return _PlaylistDownloadStatus(
      ids: ids,
      onSettled: () {
        if (!mounted || !identical(_downloadBatchIds, ids)) return;
        setState(() => _downloadBatchIds = const []);
      },
    );
  }
}

class _PlaylistDownloadStatus extends ConsumerWidget {
  const _PlaylistDownloadStatus({required this.ids, required this.onSettled});

  final List<String> ids;
  final VoidCallback onSettled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = downloadQueueLookupProvider.select((queue) {
      var pending = 0;
      var verification = 0;
      var failed = 0;
      var skipped = 0;
      final causes = <FailureCause?>{};
      for (final id in ids) {
        final item = queue.byItemId[id];
        switch (item?.status) {
          case DownloadStatus.downloading
              when item?.errorType == DownloadErrorType.verificationRequired:
            verification++;
          case DownloadStatus.queued ||
              DownloadStatus.downloading ||
              DownloadStatus.finalizing:
            pending++;
          case DownloadStatus.failed:
            failed++;
            causes.add(failureCauseForDownload(item?.errorType));
          case DownloadStatus.skipped:
            skipped++;
          case DownloadStatus.completed || null:
            break;
        }
      }
      return (
        pending: pending,
        verification: verification,
        failed: failed,
        skipped: skipped,
        cause: causes.length == 1 ? causes.first : null,
      );
    });
    final (:pending, :verification, :failed, :skipped, :cause) = ref.watch(
      summary,
    );
    if (pending == 0 && verification == 0 && failed == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final current = ref.read(summary);
        if (current.pending == 0 &&
            current.verification == 0 &&
            current.failed == 0) {
          onSettled();
        }
      });
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16 + wideListInset(context)),
        child: DefaultTextStyle(
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            liveRegion: failed > 0 || verification > 0,
            label: [
              if (verification > 0) l10n.queueWaitingForVerification,
              if (failed > 0) l10n.updateDownloadFailed,
            ].join(' '),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l10n.libraryDownloads, style: theme.textTheme.labelMedium),
                if (pending > 0) Text(l10n.playlistDownloadsPending(pending)),
                if (verification > 0)
                  Text(l10n.playlistDownloadsVerification(verification)),
                if (failed > 0)
                  Text(
                    cause == null
                        ? l10n.playlistDownloadsFailed(failed)
                        : '${l10n.playlistDownloadsFailed(failed)}: ${failureMessage(l10n, cause)}',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (skipped > 0) Text(l10n.playlistDownloadsSkipped(skipped)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
