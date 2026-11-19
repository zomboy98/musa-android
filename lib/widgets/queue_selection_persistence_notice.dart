import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';

String queueSelectionPersistenceMessage(BuildContext context) =>
    context.l10n.queueSelectionPersistenceFailed;

/// Keeps the recovery action available after an error message has disappeared.
class QueueSelectionPersistenceNotice extends ConsumerWidget {
  const QueueSelectionPersistenceNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(
      downloadQueueProvider.select(
        (state) => state.selectionPersistenceBlocked,
      ),
    );
    final nativeRecovery = ref.watch(
      downloadQueueProvider.select((state) => state.nativeRecoveryRequired),
    );
    if (!blocked && !nativeRecovery) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
      child: Material(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  blocked
                      ? queueSelectionPersistenceMessage(context)
                      : context.l10n.queueNativeRecoveryRequired,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () {
                  final queue = ref.read(downloadQueueProvider.notifier);
                  if (blocked) {
                    queue.retrySelectionPersistence();
                  } else {
                    queue.resumeQueue();
                  }
                },
                child: Text(context.l10n.dialogRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
