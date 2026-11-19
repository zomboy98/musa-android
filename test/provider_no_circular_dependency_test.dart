import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  test(
    'real notifiers reconcile and explicitly select enabled Deezer without a cycle',
    () async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getInstalledExtensions':
            return [
              {
                'id': 'deezer',
                'name': 'Deezer',
                'enabled': true,
                'has_download_provider': true,
              },
              {
                'id': 'disabled',
                'name': 'Disabled',
                'enabled': false,
                'has_download_provider': true,
              },
            ];
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final first = ProviderContainer();
      final settings = first.read(settingsProvider.notifier);
      await settings.ensureLoaded();
      expect(first.read(settingsProvider).defaultService, isEmpty);
      final extensions = first.read(extensionProvider.notifier);
      await extensions.refreshExtensions();
      expect(first.read(settingsProvider).defaultService, 'deezer');
      expect(first.read(settingsProvider).playbackProviderConfirmed, isFalse);
      expect(extensions.selectPlaybackProvider('unknown'), isFalse);
      expect(extensions.selectPlaybackProvider('disabled'), isFalse);
      expect(extensions.selectPlaybackProvider('deezer'), isTrue);
      expect(first.read(settingsProvider).playbackProviderConfirmed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      for (var i = 0; i < 50; i++) {
        final raw = prefs.getString('app_settings');
        if (raw != null &&
            (jsonDecode(raw) as Map)['playbackProviderConfirmed'] == true)
          break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      first.dispose();
      final second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(settingsProvider.notifier).ensureLoaded();
      await second.read(extensionProvider.notifier).refreshExtensions();
      expect(second.read(settingsProvider).defaultService, 'deezer');
      expect(second.read(settingsProvider).playbackProviderConfirmed, isTrue);
    },
  );
  test(
    'setup activation does not reconcile default search or priority preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'getInstalledExtensions':
            return [
              {
                'id': 'deezer',
                'name': 'Deezer',
                'enabled': false,
                'has_download_provider': true,
                'has_metadata_provider': true,
              },
            ];
          case 'getProviderPriority':
          case 'getMetadataProviderPriority':
            return <String>[];
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.notifier).ensureLoaded();
      final extensions = container.read(extensionProvider.notifier);
      await extensions.refreshExtensions(reconcilePreferences: false);
      final before = container.read(settingsProvider).toJson();
      final priorities = container
          .read(extensionProvider)
          .providerPriority
          .toList();
      calls.clear();
      await extensions.setExtensionEnabled(
        'deezer',
        true,
        reconcilePreferences: false,
      );
      expect(
        container.read(extensionProvider).extensions.single.enabled,
        isTrue,
      );
      expect(container.read(settingsProvider).toJson(), before);
      expect(container.read(extensionProvider).providerPriority, priorities);
      expect(calls, isNot(contains('setProviderPriority')));
      expect(extensions.selectPlaybackProvider('deezer'), isTrue);
      expect(container.read(settingsProvider).defaultService, 'deezer');
      expect(
        container.read(settingsProvider).playbackProviderConfirmed,
        isTrue,
      );
    },
  );
}
