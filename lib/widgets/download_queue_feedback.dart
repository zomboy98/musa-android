import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/queue_selection_persistence_notice.dart';

/// Presents live queue effects while the application shell is mounted.
class DownloadQueueFeedback extends ConsumerStatefulWidget {
  const DownloadQueueFeedback({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DownloadQueueFeedback> createState() =>
      _DownloadQueueFeedbackState();
}

class _DownloadQueueFeedbackState extends ConsumerState<DownloadQueueFeedback>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showRecoveryIfNeeded(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showRecoveryIfNeeded(),
    );
  }

  void _showRecoveryIfNeeded() {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final queue = ref.read(downloadQueueProvider);
    if (queue.selectionPersistenceBlocked) {
      _showSelectionFailure();
    } else if (queue.nativeRecoveryRequired) {
      _showNativeRecovery();
    }
  }

  void _showSelectionFailure() {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final queue = ref.read(downloadQueueProvider.notifier);
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(queueSelectionPersistenceMessage(context)),
          action: SnackBarAction(
            label: context.l10n.dialogRetry,
            onPressed: queue.retrySelectionPersistence,
          ),
        ),
      );
  }

  void _showNativeRecovery() {
    if (!mounted ||
        ref.read(downloadQueueProvider).selectionPersistenceBlocked ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final queue = ref.read(downloadQueueProvider.notifier);
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.l10n.queueNativeRecoveryRequired),
          action: SnackBarAction(
            label: context.l10n.dialogRetry,
            onPressed: queue.resumeQueue,
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      downloadQueueProvider.select(
        (queue) => queue.selectionPersistenceBlocked,
      ),
      (_, blocked) {
        if (!context.mounted ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        if (blocked) {
          _showSelectionFailure();
        } else if (ref.read(downloadQueueProvider).nativeRecoveryRequired) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                ref.read(downloadQueueProvider).nativeRecoveryRequired) {
              _showNativeRecovery();
            }
          });
        }
      },
    );
    ref.listen<bool>(
      downloadQueueProvider.select((queue) => queue.nativeRecoveryRequired),
      (_, required) {
        if (required) _showNativeRecovery();
      },
    );
    ref.listen(
      downloadQueueProvider.select((queue) => queue.manualRetryFailure),
      (_, failure) {
        if (failure == null ||
            ref.read(downloadQueueProvider).selectionPersistenceBlocked ||
            ref.read(downloadQueueProvider).nativeRecoveryRequired ||
            !context.mounted ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(context.l10n.queueRetryPreparationFailed)),
          );
      },
    );
    return widget.child;
  }
}
