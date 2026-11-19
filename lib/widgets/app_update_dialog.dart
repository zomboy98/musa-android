import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';

enum _Phase {
  offer,
  needsPermission,
  downloading,
  verifying,
  installing,
  failed,
}

/// Announces a published build and walks through download, verification and
/// hand-off to the Android installer. Nothing is forced.
class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.service,
    required this.offer,
    this.onStage,
  });

  final AppUpdateService service;
  final AppUpdateOffer offer;

  /// Reports the phase to the shared update state; null progress when the
  /// phase has none. Called with [AppUpdateStage.available] when it closes.
  final void Function(AppUpdateStage stage, double? progress)? onStage;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.offer;
  int _received = 0;
  AppUpdateFailure? _failure;
  AppUpdateCancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel();
    final onStage = widget.onStage;
    if (onStage != null) {
      scheduleMicrotask(() => onStage(AppUpdateStage.available, null));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _phase == _Phase.needsPermission) {
      _start();
    }
  }

  void _postpone() => Navigator.of(context).pop();

  Future<void> _start() async {
    if (_phase == _Phase.downloading ||
        _phase == _Phase.verifying ||
        _phase == _Phase.installing) {
      return;
    }
    if (!await widget.service.canInstallPackages()) {
      if (mounted) setState(() => _phase = _Phase.needsPermission);
      return;
    }
    if (!mounted) return;
    final token = AppUpdateCancelToken();
    _cancel = token;
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _failure = null;
    });
    widget.onStage?.call(AppUpdateStage.downloading, 0);
    try {
      final File apk = await widget.service.download(
        widget.offer,
        cancel: token,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() => _received = received);
          widget.onStage?.call(
            AppUpdateStage.downloading,
            widget.offer.sizeBytes > 0
                ? received / widget.offer.sizeBytes
                : null,
          );
        },
      );
      if (!mounted) return;
      widget.onStage?.call(AppUpdateStage.readyToInstall, null);
      setState(() => _phase = _Phase.installing);
      widget.onStage?.call(AppUpdateStage.installing, null);
      await widget.service.install(apk);
      if (mounted) Navigator.of(context).pop();
    } on AppUpdateException catch (error) {
      if (!mounted) return;
      switch (error.failure) {
        case AppUpdateFailure.cancelled:
          setState(() => _phase = _Phase.offer);
        case AppUpdateFailure.permissionRequired:
          setState(() => _phase = _Phase.needsPermission);
        default:
          setState(() {
            _failure = error.failure;
            _phase = _Phase.failed;
          });
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _failure = AppUpdateFailure.generic;
        _phase = _Phase.failed;
      });
    }
  }

  String _errorText() {
    final l10n = context.l10n;
    return switch (_failure) {
      AppUpdateFailure.network => l10n.appUpdateErrorNetwork,
      AppUpdateFailure.hashMismatch => l10n.appUpdateErrorHash,
      AppUpdateFailure.insufficientSpace => l10n.appUpdateErrorSpace,
      AppUpdateFailure.incomplete => l10n.appUpdateErrorIncomplete,
      AppUpdateFailure.installerUnavailable => l10n.appUpdateErrorInstaller,
      _ => l10n.appUpdateErrorGeneric,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final offer = widget.offer;
    final total = offer.sizeBytes;
    final busy = _phase == _Phase.downloading || _phase == _Phase.installing;
    final verifying = _phase == _Phase.downloading && _received >= total;

    final Widget body;
    final List<Widget> actions;
    switch (_phase) {
      case _Phase.offer:
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (offer.notes.isNotEmpty) ...[
              Text(offer.notes),
              const SizedBox(height: 12),
            ],
            Text(
              '${l10n.appUpdateSize}: ${formatBytes(offer.sizeBytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        actions = [
          AppDialogAction(
            filled: true,
            onPressed: _start,
            child: Text(l10n.appUpdateInstall),
          ),
          AppDialogAction(
            onPressed: _postpone,
            child: Text(l10n.appUpdateNotNow),
          ),
        ];
      case _Phase.needsPermission:
        body = Text(l10n.appUpdatePermissionMessage);
        actions = [
          AppDialogAction(
            filled: true,
            onPressed: widget.service.openInstallPermissionSettings,
            child: Text(l10n.appUpdateOpenSettings),
          ),
          AppDialogAction(
            onPressed: () => setState(() => _phase = _Phase.offer),
            child: Text(l10n.appUpdateNotNow),
          ),
        ];
      case _Phase.downloading:
      case _Phase.verifying:
      case _Phase.installing:
        final status = _phase == _Phase.installing
            ? l10n.appUpdateInstalling
            : verifying
            ? l10n.appUpdateVerifying
            : '${formatBytes(_received)} / ${formatBytes(total)}';
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppProgressIndicator.linear(
              value: _phase == _Phase.downloading && !verifying && total > 0
                  ? (_received / total).clamp(0.0, 1.0)
                  : null,
              wavy: false,
            ),
            const SizedBox(height: 12),
            Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        actions = [
          if (_phase == _Phase.downloading)
            AppDialogAction(
              onPressed: () => _cancel?.cancel(),
              child: Text(l10n.appUpdateCancel),
            ),
        ];
      case _Phase.failed:
        body = Text(_errorText());
        actions = [
          AppDialogAction(
            filled: true,
            onPressed: _start,
            child: Text(l10n.appUpdateRetry),
          ),
          AppDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.appUpdateNotNow),
          ),
        ];
    }

    return PopScope(
      canPop: !busy,
      child: AppAlertDialog(
        icon: AppIcon(
          Icons.system_update_alt_rounded,
          size: 32,
          color: theme.colorScheme.primary,
        ),
        title: Text(l10n.appUpdateTitle(offer.label)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: body,
        ),
        actions: actions,
      ),
    );
  }
}

Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateService service,
  required AppUpdateOffer offer,
  void Function(AppUpdateStage stage, double? progress)? onStage,
}) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AppUpdateDialog(service: service, offer: offer, onStage: onStage),
  );
}
