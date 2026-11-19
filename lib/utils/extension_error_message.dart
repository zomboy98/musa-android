import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/extension.dart';

String extensionErrorTitle(
  AppLocalizations l10n,
  ExtensionErrorOrigin? origin,
) => switch (origin) {
  ExtensionErrorOrigin.initialize => l10n.extensionsErrorInitialize,
  ExtensionErrorOrigin.load || null => l10n.extensionsErrorLoad,
  ExtensionErrorOrigin.install => l10n.extensionsErrorInstall,
  ExtensionErrorOrigin.upgrade => l10n.extensionsErrorUpgrade,
  ExtensionErrorOrigin.remove => l10n.extensionsErrorRemove,
  ExtensionErrorOrigin.enable => l10n.extensionsErrorEnable,
};

enum NoDownloadProviderCause {
  noneInstalled,
  allDisabled,
  withError,
  selectedMissing,
}

NoDownloadProviderCause noDownloadProviderCause(ExtensionState state) =>
    noDownloadProviderCauseFor(state.extensions);

NoDownloadProviderCause noDownloadProviderCauseFor(
  List<Extension> extensions,
) {
  final withProvider = extensions
      .where((ext) => ext.hasDownloadProvider)
      .toList();
  if (withProvider.isEmpty) return NoDownloadProviderCause.noneInstalled;
  final usable = withProvider.where(
    (ext) => ext.enabled && ext.status != 'error',
  );
  if (usable.isNotEmpty) return NoDownloadProviderCause.selectedMissing;
  if (withProvider.any((ext) => ext.enabled && ext.status == 'error')) {
    return NoDownloadProviderCause.withError;
  }
  return NoDownloadProviderCause.allDisabled;
}

String noDownloadProviderMessage(
  AppLocalizations l10n,
  NoDownloadProviderCause cause,
) => switch (cause) {
  NoDownloadProviderCause.noneInstalled => l10n.extensionsNoDownloadProvider,
  NoDownloadProviderCause.allDisabled => l10n.extensionsNoDownloadAllDisabled,
  NoDownloadProviderCause.withError => l10n.extensionsNoDownloadWithError,
  NoDownloadProviderCause.selectedMissing =>
    l10n.extensionsNoDownloadSelectedMissing,
};
