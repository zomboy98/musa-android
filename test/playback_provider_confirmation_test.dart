import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'deezer',
        name: 'Deezer',
        displayName: 'Deezer',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
      Extension(
        id: 'qobuz-web',
        name: 'Qobuz',
        displayName: 'Qobuz',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
      Extension(
        id: 'tidal-web',
        name: 'Tidal',
        displayName: 'Tidal',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'legacy settings require confirmation without changing other fields',
    () {
      final settings = AppSettings.fromJson({
        'defaultService': 'example',
        'playerMode': 'external',
      });
      expect(settings.playbackProviderConfirmed, isFalse);
      expect(settings.defaultService, 'example');
      expect(settings.playerMode, 'external');
    },
  );

  test('explicit confirmation survives serialization and restart', () {
    final selected = const AppSettings(
      defaultService: 'example',
    ).copyWith(playbackProviderConfirmed: true);
    final restored = AppSettings.fromJson(
      jsonDecode(jsonEncode(selected.toJson())) as Map<String, dynamic>,
    );
    expect(restored.playbackProviderConfirmed, isTrue);
    expect(restored.defaultService, 'example');
  });
  for (final id in ['deezer', 'qobuz-web', 'tidal-web']) {
    test('real notifier persists explicit bundled provider $id', () async {
      SharedPreferences.setMockInitialValues({});
      ProviderContainer container() => ProviderContainer(
        overrides: [extensionProvider.overrideWith(_Extensions.new)],
      );
      final first = container();
      final notifier = first.read(settingsProvider.notifier);
      await notifier.ensureLoaded();
      notifier.setDefaultDownloadExtension(
        first
            .read(extensionProvider)
            .extensions
            .firstWhere((ext) => ext.id == id),
      );
      expect(first.read(settingsProvider).playbackProviderConfirmed, isFalse);
      first.read(extensionProvider.notifier).selectPlaybackProvider(id);
      expect(first.read(settingsProvider).defaultService, id);
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
      final second = container();
      addTearDown(second.dispose);
      await second.read(settingsProvider.notifier).ensureLoaded();
      expect(second.read(settingsProvider).defaultService, id);
      expect(second.read(settingsProvider).playbackProviderConfirmed, isTrue);
      second.read(extensionProvider.notifier).selectPlaybackProvider('youtube');
      expect(second.read(settingsProvider).defaultService, id);
    });
  }
}
