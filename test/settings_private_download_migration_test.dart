import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _privateFolder = '/data/user/0/org.demo.app/app_flutter/MUSA';

class _Settings extends SettingsNotifier {
  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}

  @override
  Future<List<String>> privateDownloadFolders() async => [_privateFolder];
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

  Future<ProviderContainer> load(
    AppSettings saved, {
    int migration = 17,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(saved.toJson()),
      'settings_migration_version': migration,
    });
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(_Settings.new)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return container;
  }

  test('the private app folder saved as a choice returns to default', () async {
    final container = await load(
      const AppSettings(
        isFirstLaunch: false,
        downloadDirectory: _privateFolder,
      ),
    );
    expect(container.read(settingsProvider).downloadDirectory, '');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('settings_migration_version'), 18);
    final saved = jsonDecode(prefs.getString('app_settings')!) as Map;
    expect(saved['downloadDirectory'], '');
  });

  test('the other spelling of the private folder is also reset', () async {
    final container = await load(
      const AppSettings(
        isFirstLaunch: false,
        downloadDirectory: '/data/data/org.demo.app/app_flutter/MUSA/',
      ),
    );
    expect(container.read(settingsProvider).downloadDirectory, '');
  });

  test('a custom folder chosen by the user is kept', () async {
    for (final custom in [
      '/storage/emulated/0/Music/Mine',
      '/data/user/0/org.demo.app/app_flutter/MUSA/Mine',
    ]) {
      final container = await load(
        AppSettings(isFirstLaunch: false, downloadDirectory: custom),
      );
      expect(container.read(settingsProvider).downloadDirectory, custom);
    }
  });

  test('a SAF tree is left untouched', () async {
    final container = await load(
      const AppSettings(
        isFirstLaunch: false,
        storageMode: 'saf',
        downloadTreeUri: 'content://tree/demo',
        downloadDirectory: _privateFolder,
      ),
    );
    final settings = container.read(settingsProvider);
    expect(settings.storageMode, 'saf');
    expect(settings.downloadTreeUri, 'content://tree/demo');
    expect(settings.downloadDirectory, _privateFolder);
  });

  test('settings migrated before are not rewritten', () async {
    final container = await load(
      const AppSettings(
        isFirstLaunch: false,
        downloadDirectory: _privateFolder,
      ),
      migration: 18,
    );
    expect(container.read(settingsProvider).downloadDirectory, _privateFolder);
  });

  test('a temporary private folder is not saved as the chosen one', () async {
    final container = await load(
      const AppSettings(isFirstLaunch: false, downloadDirectory: '/custom/old'),
      migration: 18,
    );
    final notifier = container.read(settingsProvider.notifier);
    await notifier.useAppFolderStorage(_privateFolder, temporary: true);
    var settings = container.read(settingsProvider);
    expect(settings.downloadDirectory, '');
    expect(settings.storageMode, 'app');
    expect(settings.downloadTreeUri, '');
    await notifier.useAppFolderStorage('/storage/emulated/0/Music/MUSA');
    settings = container.read(settingsProvider);
    expect(settings.downloadDirectory, '/storage/emulated/0/Music/MUSA');
  });
}
