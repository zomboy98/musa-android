import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(secure, null));

  Future<String> loadedDirectory(String saved, {int migration = 15}) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        AppSettings(isFirstLaunch: false, downloadDirectory: saved).toJson(),
      ),
      'settings_migration_version': migration,
    });
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(_Settings.new)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return container.read(settingsProvider).downloadDirectory;
  }

  test('the former default folder falls back to the new default', () async {
    expect(await loadedDirectory('/storage/emulated/0/Download/Mornye'), '');
    expect(await loadedDirectory('/storage/emulated/0/Download/Mornye/'), '');
  });

  test('custom folders are kept', () async {
    expect(
      await loadedDirectory('/storage/emulated/0/Music'),
      '/storage/emulated/0/Music',
    );
    expect(
      await loadedDirectory('/storage/emulated/0/Download/Mornye/Old'),
      '/storage/emulated/0/Download/Mornye/Old',
    );
  });

  test('already migrated settings are not rewritten', () async {
    expect(
      await loadedDirectory(
        '/storage/emulated/0/Download/Mornye',
        migration: 16,
      ),
      '/storage/emulated/0/Download/Mornye',
    );
  });
}
