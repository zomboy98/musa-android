import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';

class _PriorityPreferenceStore extends InMemorySharedPreferencesStore {
  _PriorityPreferenceStore() : super.empty();

  bool? throwOnNextMetadataWrite;
  Completer<void>? metadataWriteEntered;
  Completer<void>? releaseMetadataWrite;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final failure = throwOnNextMetadataWrite;
    if (key == 'flutter.metadata_provider_priority' && failure != null) {
      throwOnNextMetadataWrite = null;
      if (metadataWriteEntered case final entered?) {
        metadataWriteEntered = null;
        entered.complete();
        await releaseMetadataWrite!.future;
      }
      if (failure) throw StateError('fixture preference write failed');
      return false;
    }
    return super.setValue(type, key, value);
  }
}

class _ChannelTestDesktopBackend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<T>(method, arguments);
}

class _DelayedSettingsNotifier extends SettingsNotifier {
  final _ready = Completer<void>();
  int _loads = 0;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    _loads++;
    await _ready.future;
  }

  void complete() {
    if (!_ready.isCompleted) _ready.complete();
  }
}

class _RetryingSettingsNotifier extends SettingsNotifier {
  int _syncAttempts = 0;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    _syncAttempts++;
    if (_syncAttempts == 1) {
      throw StateError('Settings load failed');
    }
  }
}

class _FailingSettingsSyncNotifier extends SettingsNotifier {
  int _syncs = 0;

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    if (++_syncs == 1) throw StateError('Settings sync unavailable');
    await super.syncLyricsSettingsToBackend(settings: settings);
  }
}

class _DelayedExtensionNotifier extends ExtensionNotifier {
  final _started = Completer<void>();
  final _ready = Completer<void>();
  int _initializations = 0;
  bool _failInitialization = false;

  @override
  Future<void> initialize(
    String extensionsDir,
    String dataDir, {
    required String masterKey,
    bool bootstrapBundled = false,
  }) async {
    _initializations++;
    expect(await Directory(extensionsDir).exists(), isTrue);
    expect(await Directory(dataDir).exists(), isTrue);
    expect(base64Decode(masterKey), hasLength(32));
    if (!_started.isCompleted) _started.complete();
    await _ready.future;
    state = state.copyWith(
      isInitialized: !_failInitialization,
      error: _failInitialization ? 'Native initialization failed' : null,
    );
  }

  @override
  Future<void> refreshExtensions({bool reconcilePreferences = true}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const backend = MethodChannel('com.zarz.mornye/backend');
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('extension-initialization-');
    messenger.setMockMethodCallHandler(paths, (call) async {
      return call.method == 'getApplicationSupportDirectory'
          ? '${root.path}/support'
          : '${root.path}/documents';
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'read') return base64Encode(List.filled(32, 1));
      return null;
    });
  });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(backend, null);
    await root.delete(recursive: true);
  });

  testWidgets(
    'activity detach releases idle memory without closing extensions',
    (tester) async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        methods.add(call.method);
        return null;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(extensionProvider);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      expect(methods, contains('releaseMemory'));
      expect(methods, isNot(contains('cleanupExtensions')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  test(
    'storage preparation retries a transient failure and coalesces callers',
    () async {
      var supportReads = 0;
      messenger.setMockMethodCallHandler(paths, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          supportReads++;
          if (supportReads == 1) {
            throw PlatformException(code: 'temporarily_unavailable');
          }
          return '${root.path}/support';
        }
        return '${root.path}/documents';
      });
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      final first = ExtensionStorageService.prepare();
      final second = ExtensionStorageService.prepare();
      expect(identical(first, second), isTrue);
      final storage = await first;
      expect(supportReads, 2);
      expect(
        storage.extensionsDir,
        p.join('${root.path}/support', 'extensions'),
      );
      expect(storage.dataDir, p.join('${root.path}/support', 'extension_data'));
    },
  );

  test(
    'delayed settings load gates startup, install, upgrade, and repository init',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = _DelayedSettingsNotifier();
      final notifier = _DelayedExtensionNotifier();
      final container = ProviderContainer(
        overrides: [
          extensionProvider.overrideWith(() => notifier),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      final calls = <String>[];
      messenger.setMockMethodCallHandler(backend, (call) async {
        calls.add(call.method);
        return {
          'name': 'example-extension',
          'display_name': 'Example',
          'version': '1.0.0',
        };
      });

      final startup = notifier.ensureInitialized();
      final install = notifier.installExtension(
        '/cache/example-extension.sflx',
      );
      final upgrade = notifier.upgradeExtension(
        '/cache/example-extension.sflx',
      );
      final repository = container
          .read(repoProvider.notifier)
          .initialize('/cache/store');
      await Future<void>.delayed(Duration.zero);

      expect(settings._loads, 1);
      expect(notifier._initializations, 0);
      expect(notifier._started.isCompleted, isFalse);
      expect(calls, isEmpty);

      settings.complete();
      await notifier._started.future;
      expect(notifier._initializations, 1);
      expect(calls, isEmpty);

      notifier._ready.complete();
      await startup;
      expect(await install, isTrue);
      expect(await upgrade, isTrue);
      await repository;
      expect(container.read(repoProvider).isInitialized, isTrue);
      expect(settings._loads, 1);
      expect(notifier._initializations, 1);
      expect(
        calls,
        containsAll([
          'loadExtensionFromPath',
          'upgradeExtension',
          'initExtensionRepo',
        ]),
      );
    },
  );

  test('startup, install and upgrade wait for one initialization', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _DelayedExtensionNotifier();
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(extensionProvider);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setLoggingEnabled') return null;
      expect(container.read(extensionProvider).isInitialized, isTrue);
      calls.add(call.method);
      return {
        'name': 'example-extension',
        'display_name': 'Example',
        'version': '1.0.0',
      };
    });

    final startup = notifier.ensureInitialized();
    await notifier._started.future;
    final install = notifier.installExtension('/cache/example-extension.sflx');
    final batch = notifier.installExtensions(['/cache/example-b.sflx']);
    final check = notifier.checkExtensionUpgrade(
      '/cache/example-extension.sflx',
    );
    final upgrade = notifier.upgradeExtension('/cache/example-extension.sflx');
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    notifier._ready.complete();
    await startup;
    expect(await install, isTrue);
    expect((await batch).installed, 1);
    expect((await check)['error'], isNull);
    expect(await upgrade, isTrue);
    expect(notifier._initializations, 1);
    expect(
      calls,
      containsAll([
        'loadExtensionFromPath',
        'checkExtensionUpgrade',
        'upgradeExtension',
      ]),
    );
  });

  test(
    'failed initialization prevents installation and can be retried',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier().._failInitialization = true;
      notifier._ready.complete();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      var installs = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'setLoggingEnabled') return null;
        expect(call.method, 'loadExtensionFromPath');
        installs++;
        return {'name': 'example-extension'};
      });
      expect(await notifier.installExtension('/cache/example.sflx'), isFalse);
      expect(installs, 0);
      expect(
        container.read(extensionProvider).error,
        contains('Native initialization failed'),
      );
      notifier._failInitialization = false;
      expect(await notifier.installExtension('/cache/example.sflx'), isTrue);
      expect(installs, 1);
      expect(notifier._initializations, 2);
    },
  );

  test('repository waits for a successful owner and retries failure', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _DelayedExtensionNotifier().._failInitialization = true;
    notifier._ready.complete();
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    var repositoryInitializations = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setLoggingEnabled') return null;
      expect(call.method, 'initExtensionRepo');
      expect(container.read(extensionProvider).isInitialized, isTrue);
      repositoryInitializations++;
      return null;
    });
    final repository = container.read(repoProvider.notifier);
    await repository.initialize('/cache/store');
    expect(repositoryInitializations, 0);
    expect(container.read(repoProvider).isInitialized, isFalse);
    expect(
      container.read(repoProvider).error,
      contains('Native initialization failed'),
    );
    notifier._failInitialization = false;
    await repository.initialize('/cache/store');
    expect(repositoryInitializations, 1);
    expect(container.read(repoProvider).isInitialized, isTrue);
    expect(container.read(repoProvider).error, isNull);
  });

  test(
    'adding a repository retries initialization before changing the URL',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier().._failInitialization = true;
      notifier._ready.complete();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      final calls = <String>[];
      const url = 'https://example.com/registry.json';
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'setLoggingEnabled') return null;
        calls.add(call.method);
        switch (call.method) {
          case 'initExtensionRepo':
            expect(container.read(extensionProvider).isInitialized, isTrue);
            return null;
          case 'setRepoRegistryUrl':
            expect(container.read(repoProvider).isInitialized, isTrue);
            return null;
          case 'getRepoRegistryUrl':
            return url;
          case 'getRepoExtensions':
            return <Map<String, dynamic>>[];
          default:
            throw StateError('Unexpected backend call: ${call.method}');
        }
      });
      final repository = container.read(repoProvider.notifier);
      await repository.initialize('/cache/store');
      await repository.setRegistryUrl(url);
      expect(
        container.read(repoProvider).error,
        contains('Native initialization failed'),
      );
      expect(calls, isEmpty);
      notifier._failInitialization = false;
      await repository.setRegistryUrl(url);
      expect(calls, [
        'initExtensionRepo',
        'setRepoRegistryUrl',
        'getRepoRegistryUrl',
        'getRepoExtensions',
      ]);
      expect(container.read(repoProvider).registryUrl, url);
      expect(container.read(repoProvider).error, isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('store_registry_url'),
        url,
      );
    },
  );

  test(
    'concurrent repository startup shares one native initialization',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _DelayedExtensionNotifier();
      final container = ProviderContainer(
        overrides: [extensionProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      var initializations = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'initExtensionRepo') initializations++;
        return null;
      });
      final repository = container.read(repoProvider.notifier);
      final first = repository.initialize('/cache/store');
      expect(identical(first, repository.initialize('/cache/store')), isTrue);
      await notifier._started.future;
      expect(initializations, 0);
      notifier._ready.complete();
      await first;
      expect(initializations, 1);
      expect(container.read(repoProvider).isInitialized, isTrue);
    },
  );

  test(
    'concurrent bundled installs share one snapshot and native installation',
    () async {
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      RustFfiBackend.debugShared = _ChannelTestDesktopBackend();
      addTearDown(() => RustFfiBackend.debugShared = null);
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(extensionProvider.notifier);
      final manifest =
          jsonDecode(
                await File(
                  'assets/bundled_extensions/manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final installed = <Map<String, dynamic>>[
        for (final entry
            in (manifest['extensions'] as List).cast<Map<String, dynamic>>())
          if (entry['id'] != 'amazon')
            {
              'id': entry['id'],
              'name': entry['id'],
              'version': entry['version'],
              'enabled': false,
              'status': 'loaded',
            },
      ];
      final started = Completer<void>();
      final release = Completer<void>();
      var installs = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'loadExtensionsFromDir':
            return {'loaded': <String>[], 'errors': <String>[]};
          case 'getInstalledExtensions':
            return installed;
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          case 'loadExtensionFromPath':
            installs++;
            started.complete();
            await release.future;
            installed.add({
              'id': 'amazon',
              'name': 'amazon',
              'version': '2.3.16',
              'enabled': true,
              'status': 'loaded',
              'has_download_provider': true,
              'has_metadata_provider': true,
            });
            return {'name': 'amazon'};
          default:
            return null;
        }
      });
      await notifier.initialize(
        '${root.path}/bundled-extensions',
        '${root.path}/bundled-data',
        masterKey: base64Encode(List.filled(32, 1)),
      );
      expect(notifier.state.isInitialized, isTrue);
      final settingsBefore = container.read(settingsProvider).toJson();
      final priorityBefore = notifier.state.providerPriority.toList();
      final markers = Directory(
        '${root.path}/bundled-data/.bundled-extension-attempts',
      );
      await markers.create(recursive: true);
      await File('${markers.path}/amazon').writeAsString('done');
      final first = notifier.installBundledExtensions(
        reconcilePreferences: false,
      );
      final second = notifier.installBundledExtensions(
        reconcilePreferences: false,
      );
      expect(identical(first, second), isTrue);
      await Future.any([started.future, first]);
      expect(started.isCompleted, isTrue, reason: notifier.state.error);
      expect(installs, 1);
      expect(notifier.state.isLoading, isTrue);
      release.complete();
      await Future.wait([first, second]);
      expect(installs, 1);
      expect(notifier.state.error, isNull);
      expect(container.read(settingsProvider).toJson(), settingsBefore);
      expect(notifier.state.providerPriority, priorityBefore);
      expect(
        notifier.state.extensions
            .where((ext) => ext.id != 'amazon')
            .every((ext) => !ext.enabled),
        isTrue,
      );
      await notifier.installBundledExtensions();
      expect(installs, 1);
    },
  );

  for (final hasWorkingExtension in [false, true]) {
    test('native package load errors stay visible and recover on retry '
        '(partial=$hasWorkingExtension)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(extensionProvider.notifier);
      var fail = true;
      const loadError =
          'example-unreadable: cipher: message authentication failed';
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'loadExtensionsFromDir':
            return {
              'loaded': hasWorkingExtension ? ['example-working'] : null,
              'errors': fail ? [loadError] : <String>[],
            };
          case 'getInstalledExtensions':
            return <Map<String, dynamic>>[
              if (hasWorkingExtension)
                {
                  'id': 'example-working',
                  'name': 'example-working',
                  'display_name': 'Example Working',
                  'version': '1.0.0',
                  'enabled': false,
                },
            ];
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          default:
            return null;
        }
      });

      await container.read(settingsProvider.notifier).ensureLoaded();
      final loaded = await notifier.loadExtensions('${root.path}/sources');
      expect(notifier.state.error, contains(loadError));
      expect(loaded, hasWorkingExtension);
      expect(notifier.state.isLoading, isFalse);
      expect(
        notifier.state.extensions.map((extension) => extension.id),
        hasWorkingExtension ? ['example-working'] : isEmpty,
      );

      fail = false;
      expect(await notifier.loadExtensions('${root.path}/sources'), isTrue);
      expect(notifier.state.error, isNull);
    });
  }

  test('partial startup preserves the selected provider until recovery', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(extensionProvider.notifier);
    final settings = container.read(settingsProvider.notifier);
    await settings.ensureLoaded();
    var partial = false;
    var disabled = false;
    var removed = false;
    var preferredMissing = false;
    String? searchedProvider;
    Map<String, dynamic> provider(String id, {bool enabled = true}) => {
      'id': id,
      'name': id,
      'version': '1.0.0',
      'enabled': enabled,
      'status': 'loaded',
      'has_download_provider': true,
      'has_metadata_provider': true,
      'search_behavior': {'enabled': true},
    };
    messenger.setMockMethodCallHandler(backend, (call) async {
      switch (call.method) {
        case 'loadExtensionsFromDir':
          return {
            'loaded': ['deezer', if (!preferredMissing && !removed) 'amazon'],
            'errors': [
              if (partial) 'amazon: bundled update could not complete',
            ],
          };
        case 'getInstalledExtensions':
          return jsonEncode([
            provider('deezer'),
            if (!preferredMissing && !removed)
              provider('amazon', enabled: !disabled),
          ]);
        case 'customSearchWithExtension':
          searchedProvider = (call.arguments as Map)['extension_id'] as String;
          return <Map<String, dynamic>>[];
        case 'removeExtension':
          removed = true;
          return null;
        case 'getProviderPriority':
        case 'getMetadataProviderPriority':
          return <String>[];
        default:
          return null;
      }
    });
    final path = '${root.path}/sources';
    await notifier.refreshExtensions();
    expect(notifier.selectPlaybackProvider('amazon'), isTrue);
    settings.setSearchProvider('amazon');
    await notifier.setProviderPriority(['amazon', 'deezer']);
    await notifier.setMetadataProviderPriority(['amazon', 'deezer']);
    final prefs = await SharedPreferences.getInstance();

    partial = true;
    preferredMissing = true;
    expect(await notifier.loadExtensions(path), isTrue);
    expect(notifier.state.extensions.single.id, 'deezer');
    expect(container.read(settingsProvider).defaultService, 'amazon');
    expect(container.read(settingsProvider).playbackProviderConfirmed, isTrue);
    expect(container.read(settingsProvider).searchProvider, 'amazon');
    await container.read(trackProvider.notifier).search('fixture search');
    expect(searchedProvider, 'deezer');
    expect(container.read(settingsProvider).searchProvider, 'amazon');
    await notifier.loadProviderPriority();
    await notifier.loadMetadataProviderPriority();
    expect(jsonDecode(prefs.getString('provider_priority')!), [
      'amazon',
      'deezer',
    ]);
    expect(jsonDecode(prefs.getString('metadata_provider_priority')!), [
      'amazon',
      'deezer',
    ]);
    await notifier.refreshExtensions();
    expect(container.read(settingsProvider).defaultService, 'amazon');

    partial = false;
    preferredMissing = false;
    expect(await notifier.loadExtensions(path), isTrue);
    expect(notifier.state.error, isNull);
    expect(container.read(settingsProvider).defaultService, 'amazon');

    partial = true;
    disabled = true;
    expect(await notifier.loadExtensions(path), isTrue);
    expect(container.read(settingsProvider).defaultService, 'deezer');

    disabled = false;
    expect(await notifier.loadExtensions(path), isTrue);
    expect(notifier.selectPlaybackProvider('amazon'), isTrue);
    expect(await notifier.removeExtension('amazon'), isTrue);
    expect(container.read(settingsProvider).defaultService, 'deezer');
  });

  test('partial inventory preserves priorities stored only in native', () async {
    SharedPreferences.setMockInitialValues({});
    final previousStore = SharedPreferencesStorePlatform.instance;
    final store = _PriorityPreferenceStore();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previousStore);
    var partial = true;
    var nativeDownload = ['deezer', 'amazon', 'tidal-web'];
    var nativeMetadata = ['deezer', 'amazon', 'tidal-web'];
    var failMetadataRead = false;
    final metadataReadEntered = Completer<void>();
    final releaseMetadataRead = Completer<void>();
    final partialScanEntered = Completer<void>();
    var failMetadataWrite = false;
    Completer<void>? metadataWriteEntered;
    Completer<void>? releaseMetadataWrite;
    messenger.setMockMethodCallHandler(backend, (call) async {
      switch (call.method) {
        case 'loadExtensionsFromDir':
          if (!partialScanEntered.isCompleted) partialScanEntered.complete();
          return {
            'loaded': ['deezer', 'tidal-web', if (!partial) 'amazon'],
            'errors': [if (partial) 'amazon: bundled update could not complete'],
          };
        case 'getInstalledExtensions':
          return [
            for (final id in ['deezer', 'tidal-web', if (!partial) 'amazon'])
              {
                'id': id,
                'name': id,
                'enabled': true,
                'has_download_provider': true,
                'has_metadata_provider': true,
              },
          ];
        case 'getProviderPriority':
          return nativeDownload;
        case 'getMetadataProviderPriority':
          if (failMetadataRead) throw PlatformException(code: 'unavailable');
          if (!metadataReadEntered.isCompleted) {
            metadataReadEntered.complete();
            await releaseMetadataRead.future;
          }
          return nativeMetadata;
        case 'setProviderPriority':
          nativeDownload = (jsonDecode(
            (call.arguments as Map)['priority'] as String,
          ) as List).cast<String>();
          return null;
        case 'setMetadataProviderPriority':
          if (metadataWriteEntered case final entered?) {
            metadataWriteEntered = null;
            entered.complete();
            await releaseMetadataWrite!.future;
            throw PlatformException(code: 'first_write_failed');
          }
          if (failMetadataWrite) throw PlatformException(code: 'unavailable');
          nativeMetadata = (jsonDecode(
            (call.arguments as Map)['priority'] as String,
          ) as List).cast<String>();
          return null;
        default:
          return null;
      }
    });
    final path = '${root.path}/sources';
    final first = ProviderContainer();
    try {
      await first.read(settingsProvider.notifier).ensureLoaded();
      final notifier = first.read(extensionProvider.notifier);
      final metadataLoad = notifier.loadMetadataProviderPriority();
      await metadataReadEntered.future;
      final partialLoad = notifier.loadExtensions(path);
      await partialScanEntered.future;
      releaseMetadataRead.complete();
      await metadataLoad;
      expect(await partialLoad, isTrue);
      await notifier.loadProviderPriority();
      await notifier.loadMetadataProviderPriority();
      expect(await notifier.loadExtensions(path), isTrue);
      expect(notifier.state.error, contains('bundled update could not complete'));
    } finally {
      first.dispose();
    }
    expect(nativeDownload, ['deezer', 'amazon', 'tidal-web']);
    expect(nativeMetadata, ['deezer', 'amazon', 'tidal-web']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('provider_priority'), isNull);
    expect(prefs.getString('metadata_provider_priority'), isNull);

    final second = ProviderContainer();
    addTearDown(second.dispose);
    await second.read(settingsProvider.notifier).ensureLoaded();
    final notifier = second.read(extensionProvider.notifier);
    expect(await notifier.loadExtensions(path), isTrue);
    expect(await notifier.setProviderPriority(['tidal-web', 'deezer']), isTrue);
    failMetadataRead = true;
    expect(
      await notifier.setMetadataProviderPriority(['tidal-web', 'deezer']),
      isFalse,
    );
    expect(prefs.getString('metadata_provider_priority'), isNull);
    expect(nativeMetadata, ['deezer', 'amazon', 'tidal-web']);
    failMetadataRead = false;
    expect(
      await notifier.setMetadataProviderPriority(['tidal-web', 'deezer']),
      isTrue,
    );
    const reordered = ['tidal-web', 'amazon', 'deezer'];
    expect(notifier.state.providerPriority, reordered);
    expect(notifier.state.metadataProviderPriority, reordered);
    expect(jsonDecode(prefs.getString('provider_priority')!), reordered);
    expect(jsonDecode(prefs.getString('metadata_provider_priority')!), reordered);

    for (final throws in [false, true]) {
      store.throwOnNextMetadataWrite = throws;
      expect(
        await notifier.setMetadataProviderPriority(['deezer', 'tidal-web']),
        isFalse,
      );
      expect(jsonDecode(prefs.getString('metadata_provider_priority')!), reordered);
      await notifier.refreshExtensions();
      expect(notifier.state.metadataProviderPriority, reordered);
      expect(nativeMetadata, reordered);
    }

    final storeWriteEntered = Completer<void>();
    store.metadataWriteEntered = storeWriteEntered;
    final releaseStoreWrite = Completer<void>();
    store.releaseMetadataWrite = releaseStoreWrite;
    store.throwOnNextMetadataWrite = false;
    final rejectedSave = notifier.setMetadataProviderPriority(['deezer', 'tidal-web']);
    await storeWriteEntered.future;
    final refresh = notifier.refreshExtensions();
    await Future<void>.delayed(Duration.zero);
    releaseStoreWrite.complete();
    expect(await rejectedSave, isFalse);
    await refresh;
    expect(nativeMetadata, reordered);
    expect(notifier.state.metadataProviderPriority, reordered);

    failMetadataWrite = true;
    expect(
      await notifier.setMetadataProviderPriority(['deezer', 'tidal-web']),
      isFalse,
    );
    expect(jsonDecode(prefs.getString('metadata_provider_priority')!), reordered);
    expect(notifier.state.metadataProviderPriority, reordered);
    expect(nativeMetadata, reordered);
    failMetadataWrite = false;

    const changed = ['deezer', 'amazon', 'tidal-web'];
    for (final secondSucceeds in [false, true]) {
      final entered = Completer<void>();
      metadataWriteEntered = entered;
      releaseMetadataWrite = Completer<void>();
      final firstSave = notifier.setMetadataProviderPriority(['deezer', 'tidal-web']);
      await entered.future;
      failMetadataWrite = !secondSucceeds;
      final secondSave = notifier.setMetadataProviderPriority(['deezer', 'tidal-web']);
      await Future<void>.delayed(Duration.zero);
      releaseMetadataWrite.complete();
      expect(await firstSave, isFalse);
      expect(await secondSave, secondSucceeds);
      final expected = secondSucceeds ? changed : reordered;
      expect(jsonDecode(prefs.getString('metadata_provider_priority')!), expected);
      expect(notifier.state.metadataProviderPriority, expected);
      expect(nativeMetadata, expected);
      failMetadataWrite = false;
    }
    expect(await notifier.setMetadataProviderPriority(['tidal-web', 'deezer']), isTrue);

    nativeDownload = [];
    nativeMetadata = [];
    expect(await notifier.loadExtensions(path), isTrue);
    expect(nativeDownload, reordered);
    expect(nativeMetadata, reordered);

    partial = false;
    expect(await notifier.loadExtensions(path), isTrue);
    await notifier.loadProviderPriority();
    await notifier.loadMetadataProviderPriority();
    expect(notifier.state.providerPriority, reordered);
    expect(notifier.state.metadataProviderPriority, reordered);
    expect(nativeDownload, reordered);
    expect(nativeMetadata, reordered);

    await notifier.setProviderPriority(['amazon', 'deezer', 'tidal-web']);
    await notifier.setMetadataProviderPriority(['amazon', 'deezer', 'tidal-web']);
    expect(nativeDownload, ['amazon', 'deezer', 'tidal-web']);
    expect(nativeMetadata, ['amazon', 'deezer', 'tidal-web']);
  });

  for (final failureMethod in const [
    'loadExtensionsFromDir',
    'getInstalledExtensions',
  ]) {
    test('extension refresh failure remains visible and can be retried '
        '($failureMethod)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(extensionProvider.notifier);
      final extensionsDir = Directory('${root.path}/production-$failureMethod');
      await extensionsDir.create(recursive: true);

      var targetAttempts = 0;
      var loadAttempts = 0;
      var refreshAttempts = 0;
      final expectedError = failureMethod == 'loadExtensionsFromDir'
          ? 'transient_load'
          : 'transient_refresh';
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'loadExtensionsFromDir':
            loadAttempts++;
            if (failureMethod == call.method && ++targetAttempts == 1) {
              throw PlatformException(code: 'transient_load');
            }
            return {'loaded': <String>[], 'errors': <Map<String, dynamic>>[]};
          case 'getInstalledExtensions':
            refreshAttempts++;
            if (failureMethod == call.method && ++targetAttempts == 1) {
              throw PlatformException(code: 'transient_refresh');
            }
            return <Map<String, dynamic>>[];
          default:
            throw StateError('Unexpected backend method: ${call.method}');
        }
      });

      await notifier.loadExtensions(extensionsDir.path);
      expect(notifier.state.isInitialized, isFalse);
      expect(notifier.state.error, contains(expectedError));
      expect(targetAttempts, 1);

      await notifier.loadExtensions(extensionsDir.path);
      expect(notifier.state.isInitialized, isFalse);
      expect(notifier.state.error, isNull);
      expect(loadAttempts, 2);
      expect(
        refreshAttempts,
        failureMethod == 'getInstalledExtensions' ? 2 : 1,
      );
      expect(targetAttempts, 2);
    });
  }

  test(
    'settings load failure prevents initialization and a retry works',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = _RetryingSettingsNotifier();
      final notifier = _DelayedExtensionNotifier().._ready.complete();
      final container = ProviderContainer(
        overrides: [
          extensionProvider.overrideWith(() => notifier),
          settingsProvider.overrideWith(() => settings),
        ],
      );
      addTearDown(container.dispose);
      container.read(extensionProvider);
      var installs = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'loadExtensionFromPath') installs++;
        return {'name': 'example-extension'};
      });

      await expectLater(
        notifier.ensureInitialized(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Settings load failed',
          ),
        ),
      );
      expect(settings._syncAttempts, 1);
      expect(notifier._initializations, 0);
      expect(container.read(extensionProvider).isInitialized, isFalse);
      expect(
        container.read(extensionProvider).error,
        contains('Settings load failed'),
      );
      expect(installs, 0);

      expect(
        await notifier.installExtension('/cache/example-extension.sflx'),
        isTrue,
      );
      expect(settings._syncAttempts, 2);
      expect(notifier._initializations, 1);
      expect(installs, 1);
    },
  );

  test(
    'SettingsNotifier coalesces load and restores persisted lyrics settings',
    () async {
      const providers = [
        'extension:example.provider.primary',
        'extension:example.provider.fallback',
      ];
      const persisted = AppSettings(
        lyricsProviders: providers,
        lyricsIncludeTranslationNetease: true,
        lyricsIncludeRomanizationNetease: true,
        lyricsMultiPersonWordByWord: true,
        lyricsAppleElrcWordSync: true,
        musixmatchLanguage: 'id',
      );
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(persisted.toJson()),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(settingsProvider.notifier);
      final first = notifier.ensureLoaded();
      final second = notifier.ensureLoaded();
      expect(identical(first, second), isTrue);

      await first;
      final loaded = container.read(settingsProvider);
      expect(loaded.lyricsProviders, providers);
      expect(loaded.lyricsIncludeTranslationNetease, isTrue);
      expect(loaded.lyricsIncludeRomanizationNetease, isTrue);
      expect(loaded.lyricsMultiPersonWordByWord, isTrue);
      expect(loaded.lyricsAppleElrcWordSync, isTrue);
      expect(loaded.musixmatchLanguage, 'id');
      expect(loaded.lyricsFetchOptions, {
        'include_translation_netease': true,
        'include_romanization_netease': true,
        'multi_person_word_by_word': true,
        'apple_elrc_word_sync': true,
        'musixmatch_language': 'id',
      });
    },
  );

  test('real settings loader retries a failed shared future', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = _FailingSettingsSyncNotifier();
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider);
    final failed = notifier.ensureLoaded();
    expect(identical(failed, notifier.ensureLoaded()), isTrue);
    await expectLater(
      failed,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Settings sync unavailable',
        ),
      ),
    );
    final retry = notifier.ensureLoaded();
    expect(identical(failed, retry), isFalse);
    expect(identical(retry, notifier.ensureLoaded()), isTrue);
    await retry;
    expect(notifier._syncs, 2);
    expect(identical(retry, notifier.ensureLoaded()), isTrue);
  });

  test(
    'init channel encodes nondefault lyrics providers and options',
    () async {
      late Map<String, dynamic> arguments;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'initExtensionSystem');
        arguments = Map<String, dynamic>.from(call.arguments as Map);
        return null;
      });
      const providers = [
        'extension:example.provider.primary',
        'extension:example.provider.fallback',
      ];
      const options = <String, dynamic>{
        'include_translation_netease': true,
        'musixmatch_language': 'id',
      };
      final masterKey = base64Encode(List.filled(32, 7));

      await PlatformBridge.initExtensionSystem(
        '/tmp/example-extensions',
        '/tmp/example-extension-data',
        masterKey: masterKey,
        lyricsProviders: providers,
        lyricsFetchOptions: options,
        allowedDirectories: const ['/tmp/example-output'],
      );

      expect(arguments['extensions_dir'], '/tmp/example-extensions');
      expect(arguments['data_dir'], '/tmp/example-extension-data');
      expect(arguments['master_key'], masterKey);
      expect(arguments['allowed_directories'], ['/tmp/example-output']);
      expect(
        jsonDecode(arguments['lyrics_providers_json'] as String),
        providers,
      );
      expect(jsonDecode(arguments['lyrics_options_json'] as String), options);
    },
  );
}
