import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _MockDesktopBackend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<T>(method, arguments);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bundled-first-launch-');
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = _MockDesktopBackend();
    ExtensionStorageService.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(
      secure,
      (call) async =>
          call.method == 'read' ? base64Encode(List.filled(32, 1)) : null,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    RustFfiBackend.debugShared = null;
    debugDesktopPlatformOverride = null;
    ExtensionStorageService.resetForTesting();
    await root.delete(recursive: true);
  });

  test(
    'empty storage opts into bundled bootstrap durably across restart',
    () async {
      final first = await ExtensionStorageService.prepare();
      expect(first.isNewStorage, isTrue);
      ExtensionStorageService.resetForTesting();
      expect((await ExtensionStorageService.prepare()).isNewStorage, isTrue);
    },
  );

  test(
    'pre-existing storage does not opt into automatic installation',
    () async {
      await Directory(p.join(root.path, 'extensions')).create();
      expect((await ExtensionStorageService.prepare()).isNewStorage, isFalse);
    },
  );

  for (final scenario in ['success', 'install failure', 'refresh failure']) {
    final failAmazon = scenario == 'install failure';
    final failRefresh = scenario == 'refresh failure';
    test('first launch installs packaged assets and adopts providers '
        '($scenario)', () async {
      final manifest =
          jsonDecode(
                await File(
                  'assets/bundled_extensions/manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final entries = (manifest['extensions'] as List)
          .cast<Map<String, dynamic>>();
      final installed = <Map<String, dynamic>>[];
      final installs = <String>[];
      final calls = <String>[];
      var completedInventoryReads = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'loadExtensionsFromDir':
            return {'loaded': <String>[], 'errors': <String>[]};
          case 'getInstalledExtensions':
            if (failRefresh &&
                installed.length == entries.length &&
                ++completedInventoryReads == 2) {
              throw PlatformException(code: 'test_refresh_failure');
            }
            return jsonEncode(installed);
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          case 'loadExtensionFromPath':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final path = args.values.whereType<String>().first;
            final entry = entries.singleWhere(
              (e) => e['file'] == p.basename(path),
            );
            final id = entry['id'] as String;
            expect(await File(path).exists(), isTrue);
            installs.add(id);
            if (failAmazon && id == 'amazon') {
              throw PlatformException(code: 'test_native_failure');
            }
            // Native runtime response is mocked. This checks Dart startup,
            // asset/hash handling and provider reconciliation, not WASM execution.
            installed.add({
              'id': id,
              'name': id,
              'version': entry['version'],
              'enabled': true,
              'status': 'loaded',
              'has_download_provider': true,
              if (id == 'spotify-web')
                'search_behavior': {'enabled': true, 'primary': true},
            });
            return {'name': id};
          default:
            return null;
        }
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(extensionProvider.notifier).ensureInitialized();
      final state = container.read(extensionProvider);
      expect(state.isInitialized, isTrue);
      expect(state.isLoading, isFalse);
      expect(installs, entries.map((e) => e['id']).toList());
      if (failRefresh) {
        expect(state.error, contains('test_refresh_failure'));
        return;
      }
      expect(
        state.extensions,
        hasLength(entries.length - (failAmazon ? 1 : 0)),
      );
      expect(state.extensions.every((e) => e.enabled), isTrue);
      expect(container.read(settingsProvider).searchProvider, 'spotify-web');
      expect(
        container.read(settingsProvider).defaultService,
        failAmazon ? 'tidal-web' : 'amazon',
      );
      expect(calls, isNot(contains('downloadRepoExtension')));
      expect(calls, isNot(contains('setExtensionSettings')));
      if (failAmazon) {
        expect(state.error, contains('amazon'));
        expect(state.error, contains('test_native_failure'));
      } else {
        expect(state.error, isNull);
      }
    });
  }

  test('existing enabled provider choices survive initialization', () async {
    await Directory(p.join(root.path, 'extensions')).create();
    const saved = AppSettings(
      defaultService: 'custom',
      searchProvider: 'custom',
    );
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(saved.toJson()),
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      switch (call.method) {
        case 'loadExtensionsFromDir':
          return {
            'loaded': ['custom'],
            'errors': <String>[],
          };
        case 'getInstalledExtensions':
          return jsonEncode([
            {
              'id': 'custom',
              'name': 'custom',
              'enabled': true,
              'has_download_provider': true,
              'search_behavior': {'enabled': true},
            },
          ]);
        case 'getProviderPriority':
        case 'getMetadataProviderPriority':
          return <String>[];
        case 'loadExtensionFromPath':
        case 'setExtensionSettings':
        case 'setExtensionEnabled':
          fail('Existing installation must be preserved: ${call.method}');
        default:
          return null;
      }
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(extensionProvider.notifier).ensureInitialized();
    expect(container.read(extensionProvider).error, isNull);
    expect(container.read(settingsProvider).searchProvider, 'custom');
    expect(container.read(settingsProvider).defaultService, 'custom');
  });
}
