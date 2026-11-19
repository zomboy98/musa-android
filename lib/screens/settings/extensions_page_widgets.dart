part of 'extensions_page.dart';

class _ExtensionItem extends StatelessWidget {
  final Extension extension;
  final ExtensionHealthStatus? healthStatus;
  final bool showDivider;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _ExtensionItem({
    required this.extension,
    this.healthStatus,
    required this.showDivider,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasError = extension.status == 'error';
    final serviceHealthStatus = extension.hasServiceHealth
        ? healthStatus?.status
        : null;
    final serviceHealthColor = serviceHealthStatus == null
        ? null
        : extensionHealthColor(context, serviceHealthStatus);

    return ExtensionRow(
      showDivider: showDivider,
      onTap: onTap,
      avatar: context.isMornye
          ? null
          : ExtensionAvatar(
              filePath: extension.iconPath,
              fallbackIcon: hasError ? Icons.error_outline : Icons.extension,
              background: hasError
                  ? colorScheme.errorContainer
                  : colorScheme.primaryContainer,
              foreground: hasError
                  ? colorScheme.error
                  : colorScheme.onPrimaryContainer,
            ),
      title: Text(extension.displayName),
      subtitle: Text.rich(
        hasError
            ? TextSpan(
                text: context.friendlyError(
                  extension.errorMessage,
                  fallback: context.l10n.extensionsErrorLoading,
                ),
              )
            : TextSpan(
                text: 'v${extension.version}',
                children: [
                  if (serviceHealthStatus != null) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: _extensionHealthLabel(context, serviceHealthStatus),
                      style: TextStyle(color: serviceHealthColor),
                    ),
                  ],
                ],
              ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: hasError ? colorScheme.error : colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: AppSwitch(
        value: extension.enabled,
        semanticLabel: extension.displayName,
        onChanged: hasError ? null : onToggle,
      ),
    );
  }
}

String _extensionHealthLabel(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthOnline;
    case 'degraded':
      return context.l10n.extensionHealthDegraded;
    case 'offline':
      return context.l10n.extensionHealthOffline;
    default:
      return context.l10n.extensionHealthUnknown;
  }
}
