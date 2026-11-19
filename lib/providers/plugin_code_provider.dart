import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/plugin_code_api.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/plugin_code_service.dart';

class PluginCodeInstaller {
  const PluginCodeInstaller({
    required this.prepare,
    required this.installedVersions,
    required this.install,
    required this.upgrade,
    required this.finish,
  });

  final Future<void> Function() prepare;
  final Map<String, String> Function() installedVersions;
  final Future<bool> Function(String path) install;
  final Future<bool> Function(String path) upgrade;
  final void Function() finish;
}

final pluginCodeServiceProvider = Provider<PluginCodeService>((ref) {
  final service = PluginCodeService();
  ref.onDispose(service.close);
  return service;
});

final pluginCodeInstallerProvider = Provider<PluginCodeInstaller>((ref) {
  final notifier = ref.read(extensionProvider.notifier);
  return PluginCodeInstaller(
    prepare: notifier.ensureInitialized,
    installedVersions: () => {
      for (final extension in ref.read(extensionProvider).extensions)
        extension.id: extension.version,
    },
    install: notifier.installExtension,
    upgrade: notifier.upgradeExtension,
    finish: notifier.clearError,
  );
});

enum PluginCodePhase { idle, running, done, failed }

class PluginCodeRedeemState {
  const PluginCodeRedeemState({
    this.phase = PluginCodePhase.idle,
    this.input = '',
    this.total = 0,
    this.current = 0,
    this.currentName,
    this.results = const [],
    this.failure,
  });

  final PluginCodePhase phase;
  final String input;
  final int total;
  final int current;
  final String? currentName;
  final List<PluginCodeItemResult> results;
  final PluginCodeFailure? failure;

  bool get running => phase == PluginCodePhase.running;

  PluginCodeRedeemState copyWith({
    PluginCodePhase? phase,
    String? input,
    int? total,
    int? current,
    String? currentName,
    List<PluginCodeItemResult>? results,
    PluginCodeFailure? failure,
  }) => PluginCodeRedeemState(
    phase: phase ?? this.phase,
    input: input ?? this.input,
    total: total ?? this.total,
    current: current ?? this.current,
    currentName: currentName ?? this.currentName,
    results: results ?? this.results,
    failure: failure ?? this.failure,
  );
}

class PluginCodeRedeemNotifier extends Notifier<PluginCodeRedeemState> {
  Future<void>? _run;

  @override
  PluginCodeRedeemState build() => const PluginCodeRedeemState();

  void setInput(String value) {
    if (state.running || state.input == value) return;
    state = state.copyWith(input: value);
  }

  void dismiss() {
    if (state.running) return;
    state = PluginCodeRedeemState(input: state.input);
  }

  Future<void> redeem({Duration? itemTimeout}) {
    final active = _run;
    if (active != null) return active;
    final run = _redeem(itemTimeout).whenComplete(() => _run = null);
    _run = run;
    return run;
  }

  Future<void> _redeem(Duration? itemTimeout) async {
    final input = state.input;
    if (normalizePluginCode(input) == null) {
      state = PluginCodeRedeemState(
        phase: PluginCodePhase.failed,
        input: input,
        failure: PluginCodeFailure.invalidFormat,
      );
      return;
    }
    state = PluginCodeRedeemState(phase: PluginCodePhase.running, input: input);
    final installer = ref.read(pluginCodeInstallerProvider);
    final service = ref.read(pluginCodeServiceProvider);
    final results = <PluginCodeItemResult>[];
    try {
      await installer.prepare();
      final report = await service.redeem(
        input,
        installedVersions: installer.installedVersions(),
        install: installer.install,
        upgrade: installer.upgrade,
        itemTimeout: itemTimeout ?? pluginCodeItemTimeout,
        onBundle: (bundle) {
          if (!ref.mounted) return;
          state = state.copyWith(total: bundle.items.length);
        },
        onItemStart: (index, item) {
          if (!ref.mounted) return;
          state = state.copyWith(current: index + 1, currentName: item.name);
        },
        onItemResult: (index, result) {
          results.add(result);
          if (!ref.mounted) return;
          state = state.copyWith(results: List.unmodifiable(results));
        },
      );
      installer.finish();
      if (!ref.mounted) return;
      state = PluginCodeRedeemState(
        phase: PluginCodePhase.done,
        input: report.anyChanged ? '' : input,
        total: report.bundle.items.length,
        current: report.bundle.items.length,
        results: List.unmodifiable(report.results),
      );
    } on PluginCodeException catch (error) {
      if (!ref.mounted) return;
      state = PluginCodeRedeemState(
        phase: PluginCodePhase.failed,
        input: input,
        failure: error.failure,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = PluginCodeRedeemState(
        phase: PluginCodePhase.failed,
        input: input,
        failure: PluginCodeFailure.server,
      );
    }
  }
}

final pluginCodeRedeemProvider =
    NotifierProvider<PluginCodeRedeemNotifier, PluginCodeRedeemState>(
      PluginCodeRedeemNotifier.new,
    );
