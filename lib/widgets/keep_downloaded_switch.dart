import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/keep_downloaded_provider.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

/// Fila discreta "Mantener descarga activa" de la biblioteca general o de una
/// playlist ([scope]). Apagarla pide confirmacion antes de borrar descargas.
class KeepDownloadedSwitch extends ConsumerStatefulWidget {
  const KeepDownloadedSwitch({
    super.key,
    required this.scope,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final String scope;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<KeepDownloadedSwitch> createState() =>
      _KeepDownloadedSwitchState();
}

enum _Stage { saving, deleting }

class _KeepDownloadedSwitchState extends ConsumerState<KeepDownloadedSwitch> {
  bool _busy = false;
  bool _confirming = false;

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _change(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.read(keepDownloadedControllerProvider);
    final l10n = context.l10n;
    var stage = _Stage.saving;
    try {
      if (value) {
        final queued = await controller.activate(widget.scope);
        if (queued < 0) {
          _say(l10n.keepDownloadedSaveFailed);
        } else {
          if (queued > 0) _say(l10n.keepDownloadedQueued(queued));
          final failures = controller.lastEnqueueFailures;
          if (failures > 0) _say(l10n.keepDownloadedQueueFailed(failures));
        }
      } else {
        final preview = await controller.previewDeactivation(widget.scope);
        if (!mounted) return;
        setState(() => _confirming = true);
        final confirmed = await _confirm(preview);
        if (mounted) setState(() => _confirming = false);
        // Cancelar deja el interruptor encendido: no se toco nada.
        if (confirmed != true) return;
        stage = _Stage.deleting;
        final deleted = await controller.deactivate(preview);
        if (deleted < 0) {
          _say(l10n.keepDownloadedSaveFailed);
        } else {
          final missing = preview.deletePaths.length - deleted;
          if (missing > 0) {
            _say(l10n.keepDownloadedDeletePartial(missing));
          } else if (deleted > 0) {
            _say(l10n.keepDownloadedDeleted(deleted));
          }
        }
      }
    } catch (_) {
      _say(
        stage == _Stage.deleting
            ? l10n.keepDownloadedDeleteFailed
            : l10n.keepDownloadedError,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(KeepDownloadedPreview preview) {
    final l10n = context.l10n;
    final deletes = preview.deletableTracks > 0;
    return showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(
          deletes
              ? l10n.keepDownloadedDisableTitle(preview.deletableTracks)
              : l10n.keepDownloadedDisableNoFilesTitle,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deletes
                  ? l10n.keepDownloadedDisableBody
                  : l10n.keepDownloadedDisableNoFiles,
            ),
            if (preview.sharedDownloadedCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                l10n.keepDownloadedDisableShared(preview.sharedDownloadedCount),
                key: const ValueKey('keep-downloaded-shared-note'),
              ),
            ],
          ],
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDefault: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              deletes
                  ? l10n.keepDownloadedDisableConfirm
                  : l10n.keepDownloadedDisableConfirmSimple,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(keepDownloadedActiveProvider(widget.scope));
    final l10n = context.l10n;
    return Padding(
      padding: widget.padding,
      child: SwitchListTile(
        key: const ValueKey('keep-downloaded-switch'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        secondary: _busy && !_confirming
            ? const SizedBox(
                key: ValueKey('keep-downloaded-busy'),
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.download_done_outlined),
        title: Text(l10n.keepDownloadedTitle),
        subtitle: Text(
          active
              ? l10n.keepDownloadedOnSubtitle
              : l10n.keepDownloadedOffSubtitle,
        ),
        value: active,
        onChanged: _busy ? null : _change,
      ),
    );
  }
}
