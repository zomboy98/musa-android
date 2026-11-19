import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Backend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<T>(method, arguments);
}

class _Settings extends FixedSettingsNotifier {
  _Settings(List<String>? allowed)
    : super(
        AppSettings(
          defaultService: 'amazon',
          autoFallback: true,
          downloadFallbackExtensionIds: allowed,
        ),
      );
  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late List<Map<String, dynamic>> installed;
  late List<String> nativePriority;
  late List<String> calls;
  late int failedPushes;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-priority-');
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = _Backend();
    final manifest =
        jsonDecode(
              await File(
                'assets/bundled_extensions/manifest.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    installed = (manifest['extensions'] as List)
        .cast<Map<String, dynamic>>()
        .map((entry) {
          final id = entry['id'] as String;
          return <String, dynamic>{
            'id': id,
            'name': id,
            'version': '1',
            'status': 'loaded',
            'enabled': id == 'amazon' || id == 'deezer',
            'has_download_provider': true,
          };
        })
        .toList();
    nativePriority = [];
    calls = [];
    failedPushes = 0;
    SharedPreferences.setMockInitialValues({
      'provider_priority': jsonEncode(['deezer', 'amazon']),
      'sources_unified_v1': true,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'loadExtensionsFromDir':
          return {
            'loaded': ['amazon', 'deezer'],
            'errors': <String>[],
          };
        case 'getInstalledExtensions':
          return jsonEncode(installed);
        case 'getProviderPriority':
          return jsonEncode(nativePriority);
        case 'getMetadataProviderPriority':
          return '[]';
        case 'setProviderPriority':
          if (failedPushes > 0) {
            failedPushes--;
            throw PlatformException(code: 'test_priority_sync_failed');
          }
          nativePriority = (jsonDecode(args['priority'] as String) as List)
              .cast<String>();
          return null;
        case 'setExtensionEnabled':
          installed.firstWhere(
            (e) => e['id'] == args['extension_id'],
          )['enabled'] = args['enabled'];
          return null;
        case 'loadExtensionFromPath':
          final path = args.values.whereType<String>().first;
          final id = p.basenameWithoutExtension(path);
          expect(id, 'soundcloud');
          installed.add({
            'id': id,
            'name': id,
            'version': '1',
            'status': 'loaded',
            'enabled': true,
            'has_download_provider': true,
          });
          return {'name': id};
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    RustFfiBackend.debugShared = null;
    debugDesktopPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<ProviderContainer> initialized({List<String>? allowed}) async {
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => _Settings(allowed))],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionProvider.notifier)
        .initialize(
          p.join(root.path, 'extensions'),
          p.join(root.path, 'data'),
          masterKey: base64Encode(List.filled(32, 1)),
        );
    expect(container.read(extensionProvider).isInitialized, isTrue);
    return container;
  }

  for (final restore in [false, true]) {
    for (final allowed in [null, <String>[]]) {
      test(
        'runtime priority follows ${restore ? 'restore' : 'enable'} without changing preferences ($allowed)',
        () async {
          if (restore) installed.removeWhere((e) => e['id'] == 'soundcloud');
          final container = await initialized(allowed: allowed);
          final notifier = container.read(extensionProvider.notifier);
          final prefs = await SharedPreferences.getInstance();
          final beforePrefs = {
            for (final key in prefs.getKeys()) key: prefs.get(key),
          };
          final beforeSettings = container.read(settingsProvider).toJson();
          final beforeOrder = container
              .read(extensionProvider)
              .providerPriority;
          calls.clear();
          if (restore) {
            await notifier.installBundledExtensions(
              reconcilePreferences: false,
            );
          } else {
            await notifier.setExtensionEnabled(
              'soundcloud',
              true,
              reconcilePreferences: false,
            );
          }
          expect(container.read(extensionProvider).error, isNull);
          expect(nativePriority, ['deezer', 'amazon', 'soundcloud']);
          expect(
            container.read(extensionProvider).providerPriority,
            beforeOrder,
          );
          expect(container.read(settingsProvider).toJson(), beforeSettings);
          expect({
            for (final key in prefs.getKeys()) key: prefs.get(key),
          }, beforePrefs);
          expect(calls, isNot(contains('setDownloadFallbackExtensionIds')));
          expect(calls, isNot(contains('setMetadataProviderPriority')));
          calls.clear();
          await notifier.ensureInitialized();
          expect(calls, isNot(contains('setProviderPriority')));
        },
      );
    }
  }

  test(
    'playback initialization repairs a failed activation push and a reset backend',
    () async {
      final container = await initialized();
      final notifier = container.read(extensionProvider.notifier);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('provider_priority');
      failedPushes = 1;
      await notifier.setExtensionEnabled(
        'soundcloud',
        true,
        reconcilePreferences: false,
      );
      expect(nativePriority, ['deezer', 'amazon']);
      expect(
        container
            .read(extensionProvider)
            .extensions
            .firstWhere((e) => e.id == 'soundcloud')
            .enabled,
        isTrue,
      );
      await notifier.ensureInitialized();
      expect(nativePriority, ['deezer', 'amazon', 'soundcloud']);
      nativePriority = [];
      await notifier.ensureInitialized();
      expect(nativePriority, ['deezer', 'amazon', 'soundcloud']);
      expect(prefs.getString('provider_priority'), saved);
      expect(container.read(settingsProvider).defaultService, 'deezer');
    },
  );
}
