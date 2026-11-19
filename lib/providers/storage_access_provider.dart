import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('StorageAccess');

enum AllFilesAccessResult { granted, denied, permanentlyDenied }

/// Access to the "All files access" permission (MANAGE_EXTERNAL_STORAGE),
/// replaceable in tests.
abstract class AllFilesAccessGateway {
  bool get supported;
  Future<bool> isGranted();
  Future<AllFilesAccessResult> request();
}

class PermissionAllFilesAccessGateway implements AllFilesAccessGateway {
  const PermissionAllFilesAccessGateway();

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<bool> isGranted() => Permission.manageExternalStorage.isGranted;

  @override
  Future<AllFilesAccessResult> request() async {
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return AllFilesAccessResult.granted;
    return status.isPermanentlyDenied
        ? AllFilesAccessResult.permanentlyDenied
        : AllFilesAccessResult.denied;
  }
}

final allFilesAccessGatewayProvider = Provider<AllFilesAccessGateway>(
  (ref) => const PermissionAllFilesAccessGateway(),
);

@immutable
class StorageAccessState {
  const StorageAccessState({
    this.supported = false,
    this.loaded = true,
    this.granted = true,
    this.answered = true,
    this.promptRequested = false,
    this.usingPrivateFallback = false,
  });

  /// False where no such permission exists; nothing is ever asked there.
  final bool supported;
  final bool loaded;
  final bool granted;

  /// The user has already been asked, whatever the answer was.
  final bool answered;
  final bool promptRequested;

  /// Downloads currently go to private app storage as a temporary stand-in.
  final bool usingPrivateFallback;

  StorageAccessState copyWith({
    bool? loaded,
    bool? granted,
    bool? answered,
    bool? promptRequested,
    bool? usingPrivateFallback,
  }) => StorageAccessState(
    supported: supported,
    loaded: loaded ?? this.loaded,
    granted: granted ?? this.granted,
    answered: answered ?? this.answered,
    promptRequested: promptRequested ?? this.promptRequested,
    usingPrivateFallback: usingPrivateFallback ?? this.usingPrivateFallback,
  );
}

class StorageAccessNotifier extends Notifier<StorageAccessState>
    with WidgetsBindingObserver {
  static const askedKey = 'all_files_access_asked_v1';

  late AllFilesAccessGateway _gateway;
  Future<void>? _loading;

  @override
  StorageAccessState build() {
    _gateway = ref.watch(allFilesAccessGatewayProvider);
    if (!_gateway.supported) return const StorageAccessState();
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    _loading = _load();
    return const StorageAccessState(
      supported: true,
      loaded: false,
      granted: false,
      answered: false,
    );
  }

  Future<void> _load() async {
    var asked = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      asked = prefs.getBool(askedKey) ?? false;
    } catch (e) {
      _log.w('Could not read the access prompt flag: $e');
    }
    final granted = await _readGranted();
    if (!ref.mounted) return;
    state = state.copyWith(loaded: true, answered: asked || granted);
    await _apply(granted);
  }

  Future<void> ensureLoaded() => _loading ?? Future<void>.value();

  Future<bool> _readGranted() async {
    try {
      return await _gateway.isGranted();
    } catch (e) {
      _log.w('Could not read the all files access state: $e');
      return state.granted;
    }
  }

  Future<void> _apply(bool granted) async {
    if (!ref.mounted) return;
    final changed = granted != state.granted;
    state = state.copyWith(granted: granted);
    if (!changed || !granted) return;
    try {
      final settings = ref.read(settingsProvider.notifier);
      await settings.ensureLoaded();
      if (ref.mounted) settings.setUseAllFilesAccess(true);
    } catch (e) {
      _log.w('Could not record the granted access: $e');
    }
  }

  /// Reads the permission again, e.g. after returning from system settings.
  Future<bool> refresh() async {
    if (!_gateway.supported) return true;
    await ensureLoaded();
    final granted = await _readGranted();
    await _apply(granted);
    return granted;
  }

  Future<void> _markAnswered() async {
    if (!ref.mounted) return;
    state = state.copyWith(answered: true, promptRequested: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(askedKey, true);
    } catch (e) {
      _log.w('Could not save the access prompt flag: $e');
    }
  }

  /// Opens the system permission screen and records that the user was asked.
  Future<AllFilesAccessResult> request() async {
    await ensureLoaded();
    final result = await _gateway.request();
    await _markAnswered();
    await refresh();
    return result;
  }

  /// "Not now": the user was asked and chose to keep private storage for now.
  Future<void> decline() async {
    await ensureLoaded();
    await _markAnswered();
  }

  void requestPrompt() {
    if (!state.supported || state.granted || state.promptRequested) return;
    state = state.copyWith(promptRequested: true);
  }

  void clearPrompt() {
    if (state.promptRequested) {
      state = state.copyWith(promptRequested: false);
    }
  }

  /// Asks once when downloads would otherwise land in private storage.
  Future<void> promptIfNeeded() async {
    if (!_gateway.supported) return;
    await ensureLoaded();
    final granted = await refresh();
    if (!granted && !state.answered) requestPrompt();
  }

  void setUsingPrivateFallback(bool value) {
    if (state.usingPrivateFallback == value) return;
    state = state.copyWith(usingPrivateFallback: value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }
  }
}

final storageAccessProvider =
    NotifierProvider<StorageAccessNotifier, StorageAccessState>(
      StorageAccessNotifier.new,
    );
