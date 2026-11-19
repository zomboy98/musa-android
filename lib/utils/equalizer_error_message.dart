import 'package:mornye/l10n/app_localizations.dart';

enum EqualizerErrorCause {
  system,
  output,
  balance,
  compressor,
  balanceCompressor,
  readSettings,
  saveSettings,
  presetName,
  presetLimit,
  generic,
}

EqualizerErrorCause equalizerErrorCause(String raw) {
  final text = raw.toLowerCase();
  if (text.startsWith('equalizer is not available')) {
    return EqualizerErrorCause.system;
  }
  if (text.startsWith('equalizer is unavailable')) {
    return EqualizerErrorCause.output;
  }
  if (text.contains('not available in this system audio library')) {
    final balance = text.contains('balance');
    final compressor = text.contains('compressor');
    if (balance && compressor) return EqualizerErrorCause.balanceCompressor;
    if (balance) return EqualizerErrorCause.balance;
    if (compressor) return EqualizerErrorCause.compressor;
  }
  if (text.contains('could not read saved equalizer')) {
    return EqualizerErrorCause.readSettings;
  }
  if (text.contains('could not save equalizer')) {
    return EqualizerErrorCause.saveSettings;
  }
  if (text.startsWith('preset name')) return EqualizerErrorCause.presetName;
  if (text.startsWith('maximum 100 custom presets')) {
    return EqualizerErrorCause.presetLimit;
  }
  return EqualizerErrorCause.generic;
}

String equalizerErrorMessage(AppLocalizations l10n, String raw) =>
    switch (equalizerErrorCause(raw)) {
      EqualizerErrorCause.system => l10n.equalizerErrorSystem,
      EqualizerErrorCause.output => l10n.equalizerErrorOutput,
      EqualizerErrorCause.balance => l10n.equalizerErrorBalance,
      EqualizerErrorCause.compressor => l10n.equalizerErrorCompressor,
      EqualizerErrorCause.balanceCompressor =>
        l10n.equalizerErrorBalanceCompressor,
      EqualizerErrorCause.readSettings => l10n.equalizerErrorRead,
      EqualizerErrorCause.saveSettings => l10n.equalizerErrorSave,
      EqualizerErrorCause.presetName => l10n.equalizerPresetNameInvalid,
      EqualizerErrorCause.presetLimit => l10n.equalizerPresetLimit,
      EqualizerErrorCause.generic => l10n.equalizerErrorGeneric,
    };
