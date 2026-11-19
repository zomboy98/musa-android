import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/constants/legal_links.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/foreground_session_renewal.dart';
import 'package:mornye/services/provider_session_preparer.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/services/bundled_extensions.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/download_provider_order.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/providers/settings_provider.dart';

export 'package:mornye/models/extension.dart';

part 'extension_provider_priority.dart';

final _log = AppLogger('ExtensionProvider');

const _metadataProviderPriorityKey = 'metadata_provider_priority';
const _providerPriorityKey = 'provider_priority';
const _providerPriorityAutoKey = 'provider_priority_auto';
const _metadataProviderPriorityAutoKey = 'metadata_provider_priority_auto';
const _sourcesUnifiedKey = 'sources_unified_v1';
const _providerPriorityQualityOrderKey =
    'provider_priority_quality_order_applied';
const foregroundSessionRenewalPreference = 'foreground_session_renewal_enabled';
const _storeRegistryUrlPrefKey = 'store_registry_url';

final foregroundSessionDiagnosticProvider =
    StateProvider<ForegroundSessionDiagnostic>(
      (ref) => const ForegroundSessionDiagnostic(),
    );

final extensionSettingsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, extensionId) {
      return PlatformBridge.getExtensionSettings(extensionId);
    });

/// Result of restoring extensions from a backup.
class ExtensionNotifier extends Notifier<ExtensionState> {
  /// Resolve against the currently enabled extension state before writing settings.
  bool selectPlaybackProvider(String id) =>
      _setDownloadProvider(id, confirmed: true);

  bool _setDownloadProvider(String id, {bool confirmed = false}) {
    final extension = state.extensions
        .where((ext) => ext.id == id && ext.enabled && ext.hasDownloadProvider)
        .firstOrNull;
    if (extension == null) {
      if (id.isEmpty && !confirmed) {
        ref.read(settingsProvider.notifier).setDefaultService('');
        return true;
      }
      return false;
    }
    return ref
        .read(settingsProvider.notifier)
        .setDefaultDownloadExtension(extension, confirmed: confirmed);
  }

  static const _extensionHealthDefaultCacheTtl = Duration(minutes: 10);
  static const _extensionHealthMinimumCacheTtl = Duration(minutes: 1);
  static const _extensionHealthUnknownCacheTtl = Duration(minutes: 2);
  AppLifecycleListener? _appLifecycleListener;
  bool _cleanupInFlight = false;
  StreamSubscription<ExtensionSessionGrantEvent>? _sessionGrantSubscription;
  late final ForegroundSessionRenewal
  _sessionRenewal = ForegroundSessionRenewal(
    (id) => PlatformBridge.renewExistingSession(id, enabled: true),
    onBegin: () {
      if (ref.mounted) {
        ref.read(foregroundSessionDiagnosticProvider.notifier).state =
            const ForegroundSessionDiagnostic(checking: true);
      }
    },
    onResult: (result) {
      if (!ref.mounted) return;
      final diagnostic = ref.read(foregroundSessionDiagnosticProvider.notifier);
      diagnostic.state = diagnostic.state.record(result, DateTime.now());
    },
    onEnd: () {
      if (!ref.mounted) return;
      final diagnostic = ref.read(foregroundSessionDiagnosticProvider.notifier);
      diagnostic.state = diagnostic.state.finished();
    },
    onStop: () {
      if (ref.mounted) {
        ref.read(foregroundSessionDiagnosticProvider.notifier).state =
            const ForegroundSessionDiagnostic();
      }
    },
  );

  void stopForegroundSessionChecks() {
    _sessionRenewal.stop();
    _sessionPreparer.stop();
    _sessionPassTimer?.cancel();
    _sessionPassTimer = null;
  }

  Timer? _sessionPassTimer;
  Timer? _sessionStartupTimer;

  /// Planificador de fondo: la verificación de sesiones solo ocurre aquí.
  late final ProviderSessionPreparer _sessionPreparer = ProviderSessionPreparer(
    renew: (id) => PlatformBridge.renewExistingSession(id, enabled: true),
    onPass: (event, n) => _sessionTrace('pass=$event providers=$n'),
    onStatus: (id, status, failed) => _sessionTrace(
      'provider=$id status=${failed ? 'renew_error' : status?.name ?? 'null'}',
    ),
    onOutcome: (id, outcome) =>
        _sessionTrace('provider=$id outcome=${outcome.name}'),
    canRun: () {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final runnable =
          ref.mounted &&
          state.isInitialized &&
          lifecycle == AppLifecycleState.resumed;
      if (!runnable) {
        _sessionTrace(
          'not_runnable mounted=${ref.mounted} '
          'initialized=${state.isInitialized} lifecycle=${lifecycle?.name}',
        );
      }
      return runnable;
    },
    verify: (id, cancelled) async {
      final result = await resolveExtensionVerification(
        id,
        browserMode: ref
            .read(settingsProvider)
            .extensionVerificationBrowserMode,
        quietUnavailable: true,
        cancellationSignal: cancelled,
        canLaunch: () =>
            ref.mounted &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
      final ProviderSessionOutcome outcome;
      final String label;
      if (result.successful) {
        outcome = ProviderSessionOutcome.granted;
        label = result.status == ExtensionVerificationStatus.authenticated
            ? 'authenticated'
            : 'granted';
      } else if (result.panelBusy) {
        outcome = ProviderSessionOutcome.busy;
        label = 'busy';
      } else {
        outcome = ProviderSessionOutcome.failed;
        label = result.interactionShown ? 'failed_after_interaction' : 'failed';
      }
      _sessionTrace('provider=$id verify=$label');
      return outcome;
    },
  );

  void _sessionTrace(String message) {
    if (kDebugMode) debugPrint('[session_pass] $message');
  }

  ProviderSessionPreparer get sessionPreparer => _sessionPreparer;

  /// Pasada de sesiones en segundo plano (arranque, regreso a primer plano o
  /// grant recibido): serial, sin bloquear la UI y sin mostrar nada.
  Future<void> runBackgroundSessionPass({bool force = false}) async {
    if (!Platform.isAndroid) {
      _sessionTrace('skipped reason=not_android');
      return;
    }
    if (!state.isInitialized) {
      _sessionTrace('skipped reason=not_initialized');
      return;
    }
    if (ref.read(settingsProvider).acceptedLegalVersion < legalPolicyVersion) {
      _sessionTrace('skipped reason=legal_not_accepted');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    if (!(prefs.getBool(foregroundSessionRenewalPreference) ?? true)) {
      _sessionTrace('skipped reason=preference_off');
      return;
    }
    final settings = ref.read(settingsProvider);
    final ids = orderedSessionProviders(
      defaultService: settings.defaultService,
      priority: state.providerPriority,
      searchProvider: settings.searchProvider,
      extensions: [
        for (final e in state.extensions)
          (
            id: e.id,
            enabled: e.enabled,
            loaded: e.status == 'loaded',
            download: e.hasDownloadProvider,
          ),
      ],
    );
    _sessionTrace('ordered=${ids.join(',')} force=$force');
    try {
      await _sessionPreparer.run(ids, force: force);
    } catch (error) {
      _log.w('Background session pass failed: $error');
    }
    if (!ref.mounted) return;
    // Renovar sin challenge solo antes de que expire: re-consulta al llegar el
    // umbral de renovación de la sesión más próxima a vencer.
    _sessionPassTimer?.cancel();
    final due = _sessionPreparer.nextDue();
    if (due != null) {
      final wait = due.difference(DateTime.now());
      final delay = wait.isNegative ? const Duration(minutes: 1) : wait;
      _sessionTrace('next_in_s=${delay.inSeconds}');
      _sessionPassTimer = Timer(
        delay,
        () => unawaited(runBackgroundSessionPass(force: true)),
      );
    }
  }

  /// Arranque: tras el primer frame y una pausa breve, sin bloquear la UI.
  void scheduleStartupSessionPass({
    Duration delay = const Duration(seconds: 3),
  }) {
    _sessionStartupTimer?.cancel();
    _sessionStartupTimer = Timer(
      delay,
      () => unawaited(runBackgroundSessionPass(force: true)),
    );
  }

  Future<void> checkForegroundSessions() async {
    if (!Platform.isAndroid || !state.isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    if (!state.isInitialized) return;
    await _sessionRenewal.run(
      enabled: prefs.getBool(foregroundSessionRenewalPreference) ?? true,
      canContinue: (id) =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          (prefs.getBool(foregroundSessionRenewalPreference) ?? true) &&
          state.isInitialized &&
          state.extensions.any(
            (e) => e.id == id && e.enabled && e.status == 'loaded',
          ),
      providerIds: state.extensions
          .where((e) => e.enabled && e.status == 'loaded')
          .map((e) => e.id),
    );
  }

  Completer<void>? _initializationCompleter;
  Future<void>? _ensureInitializationFuture;
  Future<void> _downloadDirectorySync = Future<void>.value();
  Future<void> _downloadPrioritySave = Future<void>.value();
  Future<void> _metadataPrioritySave = Future<void>.value();
  String? _bundledDataDir;
  bool _extensionInventoryIncomplete = false;

  bool isProviderMissingFromPartialInventory(String id) =>
      _extensionInventoryIncomplete &&
      !state.extensions.any((extension) => extension.id == id);
  Future<void>? _bundledInstallFuture;
  final Map<String, DateTime> _healthExpiresAt = {};
  final Map<String, Future<ExtensionHealthStatus?>> _healthInFlight = {};
  final Map<String, int> _healthRequestSerial = {};

  @override
  ExtensionState build() {
    ref.listen<AppSettings>(settingsProvider, (previous, next) {
      if (previous != null &&
          previous.acceptedLegalVersion < legalPolicyVersion &&
          next.acceptedLegalVersion >= legalPolicyVersion &&
          state.isInitialized &&
          Platform.isAndroid) {
        scheduleStartupSessionPass();
      }
      if (state.isInitialized &&
          (previous?.downloadDirectory != next.downloadDirectory ||
              previous?.downloadDirectoryBookmark !=
                  next.downloadDirectoryBookmark ||
              previous?.storageMode != next.storageMode)) {
        unawaited(_syncDownloadDirectory(next));
      }
    });
    _appLifecycleListener ??= AppLifecycleListener(
      onDetach: _scheduleLifecycleCleanup,
      onResume: () => unawaited(runBackgroundSessionPass()),
      onPause: stopForegroundSessionChecks,
    );
    _sessionGrantSubscription ??= PlatformBridge.extensionSessionGrantEvents()
        .listen((event) {
          if (event.success &&
              Platform.isAndroid &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed) {
            unawaited(runBackgroundSessionPass(force: true));
          }
        });
    ref.onDispose(() {
      unawaited(_sessionGrantSubscription?.cancel());
      _sessionGrantSubscription = null;
      _sessionRenewal.stop();
      _sessionPreparer.stop();
      _sessionPassTimer?.cancel();
      _sessionStartupTimer?.cancel();
      _appLifecycleListener?.dispose();
      _appLifecycleListener = null;
      _healthExpiresAt.clear();
      _healthInFlight.clear();
      _healthRequestSerial.clear();
    });
    return const ExtensionState();
  }

  Future<void> _syncDownloadDirectory(AppSettings settings) {
    _downloadDirectorySync = _downloadDirectorySync
        .then((_) async {
          if (!PlatformBridge.supportsCoreBackend) return;
          final candidate = settings.downloadDirectory.trim();
          final path =
              settings.storageMode == 'app' &&
                  settings.downloadDirectoryBookmark.isEmpty &&
                  candidate.startsWith('/') &&
                  await Directory(candidate).exists()
              ? candidate
              : '';
          try {
            await PlatformBridge.setDownloadDirectory(path);
          } catch (_) {
            // An invalid new selection must not leave the old permanent grant.
            await PlatformBridge.setDownloadDirectory('');
            rethrow;
          }
        })
        .catchError((Object error) {
          _log.w('Failed to sync output directory access: $error');
        });
    return _downloadDirectorySync;
  }

  void _scheduleLifecycleCleanup() {
    if (_cleanupInFlight) return;
    _cleanupInFlight = true;
    unawaited(_cleanupExtensions(reason: 'lifecycle detach'));
  }

  Future<void> _cleanupExtensions({required String reason}) async {
    try {
      // Android may detach/recreate its Activity while the cached engine and
      // browser verification remain alive. Keep the process-owned backend.
      await PlatformBridge.releaseNativeMemory();
      _log.d('Released idle extension resources ($reason)');
    } catch (e) {
      _log.w('Extension cleanup failed ($reason): $e');
    } finally {
      _cleanupInFlight = false;
    }
  }

  /// Completes when startup, including the install or upgrade of the bundled
  /// add-ons, has finished, whether or not it succeeded.
  Future<void> bundledExtensionsReady() async {
    if (state.isInitialized) return;
    try {
      await ensureInitialized();
    } catch (_) {}
  }

  /// Startup and install/update actions share initialization, including the
  /// private storage preparation that happens before the native call.
  Future<void> ensureInitialized() {
    if (state.isInitialized) {
      return PlatformBridge.supportsExtensionSystem
          ? synchronizeNativeDownloadPriority()
          : Future<void>.value();
    }
    return _ensureInitializationFuture ??= _initializeFromStorage()
        .whenComplete(() {
          _ensureInitializationFuture = null;
        });
  }

  Future<void> _initializeFromStorage() async {
    final pending = _initializationCompleter?.future;
    if (pending != null) {
      await pending;
    } else {
      try {
        await ref.read(settingsProvider.notifier).ensureLoaded();
        final storage = await ExtensionStorageService.prepare();
        await initialize(
          storage.extensionsDir,
          storage.dataDir,
          masterKey: storage.masterKey,
          bootstrapBundled: storage.isNewStorage,
        );
      } catch (error) {
        state = state.copyWith(
          isLoading: false,
          errorOrigin: ExtensionErrorOrigin.initialize,
          error: error.toString(),
        );
        rethrow;
      }
    }
    if (!state.isInitialized) {
      throw StateError(state.error ?? 'Extension system initialization failed');
    }
    if (PlatformBridge.supportsExtensionSystem) {
      await synchronizeNativeDownloadPriority();
    }
  }

  void _logBundled(String message) {
    debugPrint(message);
    _log.i(message);
  }

  Future<void> _installBundledPackage(String path, String id) async {
    await PlatformBridge.loadExtensionFromPath(path);
    final installed = await PlatformBridge.getInstalledExtensions();
    final entry = installed.where((e) => e['id'] == id).firstOrNull;
    if (entry == null || entry['status'] == 'error') {
      throw StateError(
        'Native installer did not load $id: ${entry?['error_message'] ?? entry?['status'] ?? 'not registered'}',
      );
    }
  }

  Future<void> initialize(
    String extensionsDir,
    String dataDir, {
    required String masterKey,
    bool bootstrapBundled = false,
  }) async {
    if (state.isInitialized) return;
    if (_initializationCompleter != null) {
      await _initializationCompleter!.future;
      return;
    }

    final completer = Completer<void>();
    _initializationCompleter = completer;

    state = state.copyWith(isLoading: true, error: null);

    if (!PlatformBridge.supportsExtensionSystem) {
      state = state.copyWith(
        isInitialized: true,
        isLoading: false,
        extensions: const [],
        error: null,
      );
      _log.i('Extension system disabled on this platform');
      completer.complete();
      _initializationCompleter = null;
      return;
    }

    try {
      final settings = ref.read(settingsProvider.notifier);
      await settings.ensureLoaded();
      final snapshot = ref.read(settingsProvider);
      final outputDirectory = snapshot.downloadDirectory.trim();
      final allowedDirectories = <String>[];
      // External scopes are acquired by the file/download operation. Missing
      // output folders are resolved by the queue and must not prevent startup.
      if (snapshot.storageMode == 'app' &&
          snapshot.downloadDirectoryBookmark.isEmpty &&
          outputDirectory.startsWith('/')) {
        final directory = Directory(outputDirectory);
        if (await directory.exists()) {
          allowedDirectories.add(directory.path);
        }
      }
      if (Platform.isAndroid) {
        try {
          await PlatformBridge.prepareRuntimeState(dataDir);
        } catch (e) {
          _log.w('Runtime state restore unavailable: $e');
        }
      }
      await PlatformBridge.initExtensionSystem(
        extensionsDir,
        dataDir,
        masterKey: masterKey,
        lyricsProviders: snapshot.lyricsProviders,
        lyricsFetchOptions: snapshot.lyricsFetchOptions,
        allowedDirectories: allowedDirectories,
      );
      final loaded = await loadExtensions(extensionsDir);
      final loadError = state.error;
      if (!loaded) {
        throw StateError(loadError ?? 'Failed to load installed extensions');
      }
      _bundledDataDir = dataDir;
      final bundledErrors = <String>[];
      {
        try {
          await bootstrapBundledExtensions(
            installMissing: bootstrapBundled,
            log: _logBundled,
            dataDir: dataDir,
            installedStatuses: {
              for (final e in await PlatformBridge.getInstalledExtensions())
                if (e['id'] is String)
                  (e['id'] as String).toLowerCase():
                      e['status']?.toString() ?? 'unknown',
            },
            installedVersions: {
              for (final e in await PlatformBridge.getInstalledExtensions())
                if (e['id'] is String)
                  (e['id'] as String).toLowerCase():
                      e['version']?.toString() ?? '',
            },
            install: _installBundledPackage,
            report: (message) {
              _log.w(message);
              bundledErrors.add(message);
            },
          );
          await refreshExtensions();
          // refreshExtensions reports failures in state instead of throwing.
          // Preserve them before startup publishes its final initialized state.
          final refreshError = state.error;
          if (refreshError != null && refreshError != loadError) {
            bundledErrors.add(refreshError);
          }
        } catch (error) {
          _log.w('Bundled extension bootstrap failed: $error');
          bundledErrors.add(error.toString());
        }
      }
      await loadProviderPriority();
      await loadMetadataProviderPriority();
      if (Platform.isAndroid || isDesktopPlatform) {
        // Exchange a cold-start browser callback before restored downloads can
        // bootstrap a replacement challenge and invalidate its original state.
        // Desktop queues a launch URL in the backend before this point.
        await PlatformBridge.processPendingExtensionCallbacks();
      }
      state = state.copyWith(
        isInitialized: true,
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.initialize,
        error: loadError != null || bundledErrors.isNotEmpty
            ? [?loadError, ...bundledErrors].join('\n')
            : null,
      );
      await _syncDownloadDirectory(ref.read(settingsProvider));
      if (Platform.isAndroid &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        scheduleStartupSessionPass();
      }
      _log.i('Extension system initialized');
    } catch (e) {
      _log.e('Failed to initialize extension system: $e');
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.initialize,
        error: e.toString(),
      );
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_initializationCompleter, completer)) {
        _initializationCompleter = null;
      }
    }
  }

  Future<void> waitForInitialization({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (state.isInitialized || !PlatformBridge.supportsExtensionSystem) {
      return;
    }

    final future = _initializationCompleter?.future;
    if (future == null) {
      return;
    }

    try {
      await future.timeout(timeout);
    } on TimeoutException {
      _log.w('Timed out waiting for extension initialization after $timeout');
    }
  }

  Future<bool> loadExtensions(String dirPath) async {
    state = state.copyWith(isLoading: true, error: null);
    final recoveringInventory = _extensionInventoryIncomplete;
    _extensionInventoryIncomplete = true;

    try {
      final result = await PlatformBridge.loadExtensionsFromDir(dirPath);
      _log.d('Load extensions result: $result');
      final loadErrors = (result['errors'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((error) => error.trim().isNotEmpty)
          .toList();
      _extensionInventoryIncomplete = loadErrors.isNotEmpty;
      await refreshExtensions();
      final refreshError = state.error;
      if (recoveringInventory &&
          !_extensionInventoryIncomplete &&
          refreshError == null) {
        await loadProviderPriority();
        await loadMetadataProviderPriority();
      }
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.load,
        error:
            refreshError ?? (loadErrors.isEmpty ? null : loadErrors.join('\n')),
      );
      // Native loading can succeed overall while individual packages fail.
      // Keep working extensions usable, but do not treat an unreadable install
      // directory as an empty, successfully initialized extension system.
      return refreshError == null &&
          (loadErrors.isEmpty || state.extensions.isNotEmpty);
    } catch (e) {
      _log.e('Failed to load extensions: $e');
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.load,
        error: e.toString(),
      );
      return false;
    }
  }

  Future<void> refreshExtensions({bool reconcilePreferences = true}) async {
    try {
      final list = await PlatformBridge.getInstalledExtensions();
      final extensions = list.map((e) => Extension.fromJson(e)).toList();
      state = state.copyWith(extensions: extensions);
      if (reconcilePreferences) {
        await _reconcileDownloadProviderPriority();
        await _reconcileDefaultDownloadService();
        await _reconcileMetadataProviderPriority();
        _reconcileSearchProvider();
      } else {
        await synchronizeNativeDownloadPriority();
      }
      _scheduleExtensionHealthRefresh(extensions);
      _log.d('Loaded ${extensions.length} extensions');

      for (final ext in extensions) {
        if (ext.searchBehavior != null) {
          _log.d(
            'Extension ${ext.id}: thumbnailRatio=${ext.searchBehavior!.thumbnailRatio}',
          );
        }
      }
    } catch (e) {
      _log.e('Failed to refresh extensions: $e');
      state = state.copyWith(
        errorOrigin: ExtensionErrorOrigin.load,
        error: e.toString(),
      );
    }
  }

  void _scheduleExtensionHealthRefresh(
    List<Extension> extensions, {
    bool force = false,
  }) {
    for (final ext in extensions) {
      if (!ext.enabled || !ext.hasServiceHealth) continue;
      unawaited(checkExtensionHealth(ext.id, force: force));
    }
  }

  void refreshEnabledExtensionHealth({bool force = false}) {
    _scheduleExtensionHealthRefresh(state.extensions, force: force);
  }

  Duration _extensionHealthCacheTtlFor(Extension extension) {
    var ttl = _extensionHealthDefaultCacheTtl;
    for (final check in extension.serviceHealth) {
      final seconds = check.cacheTtlSeconds;
      if (seconds == null || seconds <= 0) continue;

      var checkTtl = Duration(seconds: seconds);
      if (checkTtl < _extensionHealthMinimumCacheTtl) {
        checkTtl = _extensionHealthMinimumCacheTtl;
      }
      if (checkTtl < ttl) {
        ttl = checkTtl;
      }
    }
    return ttl;
  }

  Duration _extensionHealthCacheTtlForStatus(
    Extension extension,
    String status,
  ) {
    final ttl = _extensionHealthCacheTtlFor(extension);
    if (status == 'unknown' && ttl > _extensionHealthUnknownCacheTtl) {
      return _extensionHealthUnknownCacheTtl;
    }
    return ttl;
  }

  Future<ExtensionHealthStatus?> checkExtensionHealth(
    String extensionId, {
    bool force = false,
  }) async {
    final ext = state.extensions
        .where((extension) => extension.id == extensionId)
        .firstOrNull;
    if (ext == null || !ext.hasServiceHealth) {
      return null;
    }

    final expiresAt = _healthExpiresAt[extensionId];
    final cached = state.healthStatuses[extensionId];
    if (!force &&
        cached != null &&
        expiresAt != null &&
        DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    final inFlight = _healthInFlight[extensionId];
    if (!force && inFlight != null) {
      return inFlight;
    }

    final requestSerial = (_healthRequestSerial[extensionId] ?? 0) + 1;
    _healthRequestSerial[extensionId] = requestSerial;

    final future = () async {
      try {
        final result = await PlatformBridge.checkExtensionHealth(extensionId);
        final status = ExtensionHealthStatus.fromJson(result);
        if (_healthRequestSerial[extensionId] == requestSerial) {
          final updated = Map<String, ExtensionHealthStatus>.of(
            state.healthStatuses,
          )..[extensionId] = status;
          _healthExpiresAt[extensionId] = DateTime.now().add(
            _extensionHealthCacheTtlForStatus(ext, status.status),
          );
          state = state.copyWith(healthStatuses: updated);
        }
        return status;
      } catch (e) {
        _log.w('Failed to check extension health for $extensionId: $e');
        final status = ExtensionHealthStatus(
          status: 'unknown',
          checkedAt: DateTime.now(),
          checks: const [],
        );
        if (_healthRequestSerial[extensionId] == requestSerial) {
          final updated = Map<String, ExtensionHealthStatus>.of(
            state.healthStatuses,
          )..[extensionId] = status;
          _healthExpiresAt[extensionId] = DateTime.now().add(
            _extensionHealthUnknownCacheTtl,
          );
          state = state.copyWith(healthStatuses: updated);
        }
        return status;
      } finally {
        if (_healthRequestSerial[extensionId] == requestSerial) {
          _healthInFlight.remove(extensionId);
        }
      }
    }();

    _healthInFlight[extensionId] = future;
    return future;
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  Future<bool> installExtension(String filePath) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await ensureInitialized();
      final result = await PlatformBridge.loadExtensionFromPath(filePath);
      _log.i('Installed extension: ${result['name']}');
      await refreshExtensions();
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to install extension: $e');
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.install,
        error: e.toString(),
      );
      return false;
    }
  }

  Future<ExtensionInstallBatchResult> installExtensions(
    List<String> filePaths,
  ) async {
    final uniquePaths = <String>[];
    for (final path in filePaths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || uniquePaths.contains(trimmed)) continue;
      uniquePaths.add(trimmed);
    }

    if (uniquePaths.isEmpty) {
      return const ExtensionInstallBatchResult(attempted: 0, installed: 0);
    }

    state = state.copyWith(isLoading: true, error: null);

    var installed = 0;
    final failures = <String, String>{};

    try {
      await ensureInitialized();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.install,
        error: e.toString(),
      );
      return ExtensionInstallBatchResult(
        attempted: uniquePaths.length,
        installed: 0,
        failures: {for (final path in uniquePaths) path: e.toString()},
      );
    }

    for (final path in uniquePaths) {
      try {
        final result = await PlatformBridge.loadExtensionFromPath(path);
        installed++;
        _log.i('Installed extension: ${result['name']}');
      } catch (e) {
        _log.e('Failed to install extension from $path: $e');
        failures[path] = e.toString();
      }
    }

    if (installed > 0) {
      await refreshExtensions();
    }

    final firstError = failures.values.firstOrNull;
    state = state.copyWith(
      isLoading: false,
      errorOrigin: ExtensionErrorOrigin.install,
      error: firstError,
    );

    return ExtensionInstallBatchResult(
      attempted: uniquePaths.length,
      installed: installed,
      failures: failures,
    );
  }

  Future<Map<String, dynamic>> checkExtensionUpgrade(String filePath) async {
    try {
      await ensureInitialized();
      return await PlatformBridge.checkExtensionUpgrade(filePath);
    } catch (e) {
      _log.e('Failed to check extension upgrade: $e');
      return {'error': e.toString()};
    }
  }

  Future<bool> upgradeExtension(String filePath) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await ensureInitialized();
      final result = await PlatformBridge.upgradeExtension(filePath);
      _log.i(
        'Upgraded extension: ${result['display_name']} to v${result['version']}',
      );
      await refreshExtensions();
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to upgrade extension: $e');
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.upgrade,
        error: e.toString(),
      );
      return false;
    }
  }

  /// Adds missing packages only after an explicit user request. Registered
  /// disabled/error packages and their settings are never replaced.
  Future<void> installBundledExtensions({bool reconcilePreferences = true}) {
    return _bundledInstallFuture ??=
        _installBundledExtensions(
          reconcilePreferences: reconcilePreferences,
        ).whenComplete(() {
          _bundledInstallFuture = null;
        });
  }

  Future<void> _installBundledExtensions({
    required bool reconcilePreferences,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    final errors = <String>[];
    try {
      await ensureInitialized();
      final dataDir = _bundledDataDir;
      if (dataDir == null) return;
      await bootstrapBundledExtensions(
        dataDir: dataDir,
        installedStatuses: {
          for (final entry in await PlatformBridge.getInstalledExtensions())
            (entry['id'] as String).toLowerCase():
                entry['status']?.toString() ?? 'unknown',
        },
        installedVersions: {
          for (final entry in await PlatformBridge.getInstalledExtensions())
            (entry['id'] as String).toLowerCase():
                entry['version']?.toString() ?? '',
        },
        includePreviouslyRemoved: true,
        log: _logBundled,
        install: (path, id) async {
          final existed = (await PlatformBridge.getInstalledExtensions()).any(
            (e) => e['id'] == id,
          );
          await _installBundledPackage(path, id);
          // A package that was missing starts enabled; an upgraded one keeps
          // the enabled state and settings the user chose.
          if (!existed) await PlatformBridge.setExtensionEnabled(id, true);
        },
        report: errors.add,
      );
      await refreshExtensions(reconcilePreferences: reconcilePreferences);
      if (state.error != null) errors.add(state.error!);
    } catch (error) {
      errors.add(error.toString());
    } finally {
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.install,
        error: errors.isEmpty ? null : errors.join('\n'),
      );
    }
  }

  Future<bool> removeExtension(String extensionId) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final dataDir = _bundledDataDir;
      if (dataDir != null && RegExp(r'^[a-z0-9-]+$').hasMatch(extensionId)) {
        final markers = Directory(
          p.join(dataDir, '.bundled-extension-attempts'),
        );
        await markers.create(recursive: true);
        await File(
          p.join(markers.path, extensionId),
        ).writeAsString('done', flush: true);
      }
      await PlatformBridge.removeExtension(extensionId);
      _log.i('Removed extension: $extensionId');
      await refreshExtensions();
      if (_extensionInventoryIncomplete && state.error == null) {
        await _reconcileDefaultDownloadService(removedId: extensionId);
        _reconcileSearchProvider(removedId: extensionId);
      }
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to remove extension: $e');
      state = state.copyWith(
        isLoading: false,
        errorOrigin: ExtensionErrorOrigin.remove,
        error: e.toString(),
      );
      return false;
    }
  }

  Future<void> setExtensionEnabled(
    String extensionId,
    bool enabled, {
    bool reconcilePreferences = true,
  }) async {
    try {
      await PlatformBridge.setExtensionEnabled(extensionId, enabled);
      _log.d('Set extension $extensionId enabled: $enabled');

      final ext = state.extensions
          .where((e) => e.id == extensionId)
          .firstOrNull;

      final extensions = state.extensions.map((e) {
        if (e.id == extensionId) {
          return e.copyWith(enabled: enabled);
        }
        return e;
      }).toList();

      state = state.copyWith(extensions: extensions);
      if (reconcilePreferences) {
        await _reconcileDownloadProviderPriority();
        await _reconcileDefaultDownloadService();
        await _reconcileMetadataProviderPriority();
        _reconcileSearchProvider();
      } else {
        await synchronizeNativeDownloadPriority();
      }

      final updatedExt = extensions
          .where((extension) => extension.id == extensionId)
          .firstOrNull;
      if (enabled && updatedExt?.hasServiceHealth == true) {
        unawaited(checkExtensionHealth(extensionId, force: true));
      }

      if (reconcilePreferences && !enabled && ext != null) {
        final settings = ref.read(settingsProvider);

        if (settings.searchProvider == extensionId) {
          ref.read(settingsProvider.notifier).setSearchProvider(null);
          _log.d(
            'Cleared search provider because extension $extensionId was disabled',
          );
        }

        if (ext.hasDownloadProvider && settings.defaultService == extensionId) {
          final fallbackService =
              _firstEnabledExtensionDownloadProviderId() ?? '';
          _setDownloadProvider(fallbackService);
          _log.d(
            fallbackService.isEmpty
                ? 'Cleared default service because extension $extensionId was disabled'
                : 'Reset default service to $fallbackService because extension $extensionId was disabled',
          );
        }
      }
    } catch (e) {
      _log.e('Failed to set extension enabled: $e');
      state = state.copyWith(
        errorOrigin: ExtensionErrorOrigin.enable,
        error: e.toString(),
      );
    }
  }

  /// Collects the keys flagged as `secret` in an extension's manifest schema
  /// (top-level settings and quality-specific settings).
  Set<String> _secretKeysFromManifest(Map<String, dynamic> raw) {
    final keys = <String>{};

    void scan(Object? settingsList) {
      if (settingsList is! List) return;
      for (final entry in settingsList) {
        if (entry is Map && entry['secret'] == true && entry['key'] is String) {
          keys.add(entry['key'] as String);
        }
      }
    }

    scan(raw['settings']);
    final quality = raw['quality_options'];
    if (quality is List) {
      for (final option in quality) {
        if (option is Map) {
          scan(option['settings']);
        }
      }
    }
    return keys;
  }

  /// Builds the extensions section of a backup: the store registry URL, the
  /// installed extensions with their id, version, enabled flag and settings,
  /// and the download and metadata provider priority order.
  /// Secret-flagged settings (tokens, API keys) are only included when
  /// [includeSecrets] is true.
  Future<Map<String, dynamic>> exportBackup({
    required bool includeSecrets,
  }) async {
    if (!PlatformBridge.supportsExtensionSystem) {
      return {'registry_url': '', 'items': const <Map<String, dynamic>>[]};
    }

    final prefs = await SharedPreferences.getInstance();
    // The native repository is initialized lazily when Repo is opened. Keep
    // its persisted URL in backups made before that first visit.
    var registryUrl = (prefs.getString(_storeRegistryUrlPrefKey) ?? '').trim();
    try {
      final activeUrl = (await PlatformBridge.getRepoRegistryUrl()).trim();
      if (activeUrl.isNotEmpty) registryUrl = activeUrl;
    } catch (_) {}

    List<Map<String, dynamic>> installed;
    try {
      installed = await PlatformBridge.getInstalledExtensions();
    } catch (e) {
      _log.w('Backup: failed to list extensions: $e');
      installed = const [];
    }

    final items = <Map<String, dynamic>>[];
    for (final raw in installed) {
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final secretKeys = _secretKeysFromManifest(raw);
      // Older installed Apple Music manifests did not mark this token secret.
      if (id == 'apple-music') secretKeys.add('mediaUserToken');

      Map<String, dynamic> settings = {};
      try {
        settings = await PlatformBridge.getExtensionSettings(id);
      } catch (_) {}

      final filtered = <String, dynamic>{};
      var omittedSecret = false;
      settings.forEach((key, value) {
        if (secretKeys.contains(key)) {
          if (!includeSecrets) {
            omittedSecret = true;
            return;
          }
        }
        filtered[key] = value;
      });

      items.add({
        'id': id,
        'version': raw['version']?.toString() ?? '',
        'enabled': raw['enabled'] == true,
        'settings': filtered,
        if (omittedSecret) 'secrets_omitted': true,
      });
    }

    return {
      'registry_url': registryUrl,
      'items': items,
      ...providerPriorityBackup(),
    };
  }

  /// Restores extensions from a backup section produced by [exportBackup]:
  /// re-applies the store registry URL, reinstalls each extension from the
  /// store when missing, then merges settings and restores the enabled flag.
  /// Missing settings (e.g. omitted secrets) are merged with the current values
  /// so they are not wiped.
  Future<ExtensionRestoreResult> restoreFromBackup(
    Map<String, dynamic> data,
  ) async {
    if (!PlatformBridge.supportsExtensionSystem) {
      return const ExtensionRestoreResult();
    }

    await ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final backupUrl = (data['registry_url'] as String?)?.trim() ?? '';
    // Older backups may have omitted the URL when Repo had not been opened.
    final registryUrl = backupUrl.isNotEmpty
        ? backupUrl
        : (prefs.getString(_storeRegistryUrlPrefKey) ?? '').trim();
    final itemsRaw = data['items'];
    final items = itemsRaw is List
        ? itemsRaw
              .whereType<Map<Object?, Object?>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
        : <Map<String, dynamic>>[];

    Directory? destDir;
    try {
      final tmp = await getTemporaryDirectory();
      destDir = await Directory(
        '${tmp.path}/mornye_restore_ext',
      ).create(recursive: true);
      await PlatformBridge.initExtensionRepo(destDir.path);
      if (registryUrl.isNotEmpty) {
        await PlatformBridge.setRepoRegistryUrl(registryUrl);
        await prefs.setString(_storeRegistryUrlPrefKey, registryUrl);
      }
    } catch (e) {
      _log.w('Restore: failed to prepare extension store: $e');
    }

    await refreshExtensions();
    final installedIds = state.extensions
        .map((e) => e.id.toLowerCase())
        .toSet();

    var installedCount = 0;
    var alreadyPresent = 0;
    var failed = 0;
    final failedIds = <String>[];

    for (final item in items) {
      final id = item['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final enabled = item['enabled'] != false;
      var present = installedIds.contains(id.toLowerCase());

      if (!present) {
        if (destDir == null) {
          failed++;
          failedIds.add(id);
          continue;
        }
        try {
          final path = await PlatformBridge.downloadRepoExtension(
            id,
            destDir.path,
          );
          final ok = await installExtension(path);
          if (ok) {
            installedCount++;
            present = true;
          } else {
            failed++;
            failedIds.add(id);
          }
        } catch (e) {
          _log.w('Restore: failed to install extension $id: $e');
          failed++;
          failedIds.add(id);
        }
      } else {
        alreadyPresent++;
      }

      if (!present) continue;

      final settings = item['settings'];
      if (settings is Map && settings.isNotEmpty) {
        try {
          final current = await PlatformBridge.getExtensionSettings(id);
          final merged = <String, dynamic>{
            ...current,
            ...Map<String, dynamic>.from(settings),
          };
          await setExtensionSettings(id, merged);
        } catch (e) {
          _log.w('Restore: failed to apply settings for $id: $e');
        }
      }

      try {
        await setExtensionEnabled(id, enabled);
      } catch (_) {}
    }

    await refreshExtensions();
    // Reinstalled and re-enabled extensions now exist, so the saved order can
    // be applied in full instead of defaults winning.
    await restoreProviderPriorityBackup(data);

    return ExtensionRestoreResult(
      installed: installedCount,
      alreadyPresent: alreadyPresent,
      failed: failed,
      failedIds: failedIds,
    );
  }
}

final extensionProvider = NotifierProvider<ExtensionNotifier, ExtensionState>(
  ExtensionNotifier.new,
);

/// Gate for work that calls bundled add-ons at startup: it completes once the
/// bundled add-ons are installed or upgraded, or startup gave up.
final bundledExtensionsReadyProvider = FutureProvider<void>((ref) {
  return ref.read(extensionProvider.notifier).bundledExtensionsReady();
});

/// The installed version of an add-on, or empty when it is not known.
String installedExtensionVersion(Ref ref, String id) =>
    ref
        .read(extensionProvider)
        .extensions
        .where((e) => e.id.toLowerCase() == id)
        .firstOrNull
        ?.version ??
    '';

bool extensionStateHasCatalog(ExtensionState state) => state.extensions.any(
  (ext) => ext.enabled && (ext.hasMetadataProvider || ext.hasDownloadProvider),
);

final hasCatalogProvider = Provider<bool>(
  (ref) => ref.watch(extensionProvider.select(extensionStateHasCatalog)),
);

final localOnlyModeProvider = Provider<bool>((ref) {
  final initialized = ref.watch(
    extensionProvider.select((state) => state.isInitialized),
  );
  return initialized && !ref.watch(hasCatalogProvider);
});
