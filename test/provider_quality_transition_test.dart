import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reselect recovers a saved tier after a legacy empty active value', () async {
    SharedPreferences.setMockInitialValues({'settings_migration_version': 15, 'app_settings': jsonEncode({'defaultService': 'a', 'audioQuality': '', 'downloadQualityByProvider': {'a': 'retired'}})});
    const a = Extension(id: 'a', name: 'a', displayName: 'A', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true, qualityOptions: [QualityOption(id: 'new', label: 'New')]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setDefaultDownloadExtension(a);
    expect(container.read(settingsProvider).audioQuality, 'retired');
    notifier.setAudioQualityForProvider('a', '');
    notifier.setDefaultDownloadExtension(a);
    expect(container.read(settingsProvider).audioQuality, isEmpty);
    expect(container.read(settingsProvider).downloadQualityByProvider['a'], isEmpty);
  });
  test('missing remembered tier survives switching and restart with metadata', () async {
    SharedPreferences.setMockInitialValues({});
    const old = QualityOption(id: 'retired', label: '24-bit', kind: 'lossless');
    const a = Extension(id: 'a', name: 'a', displayName: 'A', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true, qualityOptions: [QualityOption(id: 'new', label: 'New')]);
    const b = Extension(id: 'b', name: 'b', displayName: 'B', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true, qualityOptions: [QualityOption(id: 'b1', label: 'B1')]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setDefaultDownloadExtension(a);
    notifier.setAudioQualityForProvider('a', old.id, option: old);
    notifier.setDefaultDownloadExtension(b);
    notifier.setDefaultDownloadExtension(a);
    expect(container.read(settingsProvider).audioQuality, 'retired');
    expect(container.read(settingsProvider).downloadQualitySourceFor('a', 'retired')?.label, '24-bit');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    final restored = restarted.read(settingsProvider.notifier);
    await restored.ensureLoaded();
    restored.setDefaultDownloadExtension(b);
    restored.setDefaultDownloadExtension(a);
    expect(restarted.read(settingsProvider).audioQuality, 'retired');
    expect(restarted.read(settingsProvider).downloadQualitySourceFor('a', 'retired')?.kind, 'lossless');
  });

  test('legacy active choice survives switching without inventing metadata', () async {
    SharedPreferences.setMockInitialValues({'settings_migration_version': 15, 'app_settings': jsonEncode({'defaultService': 'a', 'audioQuality': 'retired'})});
    const a = Extension(id: 'a', name: 'a', displayName: 'A', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true, qualityOptions: [QualityOption(id: 'new', label: 'New')]);
    const b = Extension(id: 'b', name: 'b', displayName: 'B', version: '1', description: '', enabled: true, status: 'loaded', hasDownloadProvider: true, qualityOptions: []);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setDefaultDownloadExtension(b);
    notifier.setDefaultDownloadExtension(a);
    expect(container.read(settingsProvider).audioQuality, 'retired');
    expect(container.read(settingsProvider).downloadQualitySourceFor('a', 'retired'), isNull);
  });
  test('switching providers restores the canonical remembered quality', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(const AppSettings(
        defaultService: 'other',
        audioQuality: 'aac',
        downloadQualityByProvider: {'example': ' FLAC '},
      )),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    const source = Extension(
      id: 'example', name: 'example', displayName: 'Example', version: '1',
      description: '', enabled: true, status: 'loaded', hasDownloadProvider: true,
      qualityOptions: [
        QualityOption(id: ' flac ', label: 'FLAC'),
        QualityOption(id: 'FLAC', label: 'Duplicate'),
      ],
    );
    expect(notifier.setDefaultDownloadExtension(source), isTrue);
    final settings = container.read(settingsProvider);
    expect(settings.defaultService, 'example');
    expect(settings.audioQuality, 'flac');
    expect(settings.downloadQualityByProvider, {'other': 'aac', 'example': 'flac'});
  });
  test('generated settings serializer normalizes provider IDs', () {
    final decoded = AppSettings.fromJson({'downloadQualityByProvider': {' Foo ': 'b'}});
    expect(decoded.downloadQualityByProvider, {'foo': 'b'});
    expect(decoded.toJson()['downloadQualityByProvider'], {'foo': 'b'});
  });
  test('provider IDs with whitespace never create empty keys', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(const AppSettings(defaultService: '  ', audioQuality: 'old')),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    const source = Extension(id: ' Foo ', name: 'foo', displayName: 'Foo', version: '1',
      description: '', enabled: true, status: 'loaded', hasDownloadProvider: true,
      qualityOptions: [QualityOption(id: 'new', label: 'New')]);
    expect(notifier.setDefaultDownloadExtension(source), isTrue);
    expect(container.read(settingsProvider).defaultService, 'Foo');
    expect(container.read(settingsProvider).audioQuality, 'new');
    notifier.setAudioQualityForProvider(' fOo ', 'chosen');
    expect(container.read(settingsProvider).audioQuality, 'chosen');
    expect(container.read(settingsProvider).downloadQualityByProvider, {'foo': 'chosen'});
  });
  test('case variants normalize and a new choice survives restart', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(const AppSettings(defaultService: 'other', downloadQualityByProvider: {'foo': 'old', 'Foo': 'older'}).toJson()),
      'settings_migration_version': 15,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    expect(container.read(settingsProvider).downloadQualityByProvider, {'foo': 'old'});
    notifier.setAudioQualityForProvider('Foo', 'new');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    await restarted.read(settingsProvider.notifier).ensureLoaded();
    expect(restarted.read(settingsProvider).downloadQualityByProvider, {'foo': 'new'});
    expect(loadBootstrapSettings(prefs).downloadQualityByProvider, {'foo': 'new'});
  });
  test('early fallback choice does not replace the loaded primary source', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(const AppSettings(defaultService: 'a', audioQuality: 'opus').toJson()),
      'settings_migration_version': 15,
    });
    final prefs = await SharedPreferences.getInstance();
    final pending = Completer<SharedPreferences>();
    final container = ProviderContainer(overrides: [
      settingsProvider.overrideWith(() => SettingsNotifier(preferences: () => pending.future)),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    notifier.setAudioQualityForProvider('b', 'aac');
    pending.complete(prefs);
    await notifier.ensureLoaded();
    expect(container.read(settingsProvider).defaultService, 'a');
    expect(container.read(settingsProvider).audioQuality, 'opus');
    expect(container.read(settingsProvider).downloadQualityByProvider['b'], 'aac');
  });
  test('source change only selects an unambiguous quality', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(
            defaultService: 'a',
            audioQuality: 'opus',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    Extension source(List<QualityOption> options) => Extension(
      id: 'b',
      name: 'b',
      displayName: 'B',
      version: '1',
      description: '',
      enabled: true,
      status: 'loaded',
      hasDownloadProvider: true,
      qualityOptions: options,
    );
    notifier.setDefaultDownloadExtension(source(const []));
    expect(container.read(settingsProvider).audioQuality, isEmpty);
    notifier.setDefaultDownloadExtension(
      source(const [
        QualityOption(id: 'aac', label: 'AAC'),
        QualityOption(id: 'flac', label: 'FLAC'),
      ]),
    );
    expect(container.read(settingsProvider).audioQuality, isEmpty);
    notifier.setDefaultDownloadExtension(
      source(const [QualityOption(id: 'aac', label: 'AAC')]),
    );
    expect(container.read(settingsProvider).audioQuality, isEmpty);
    notifier.setAudioQuality('aac');
    final settings = container.read(settingsProvider);
    expect(settings.audioQuality, 'aac');
    notifier.setDefaultDownloadExtension(
      source(const [
        QualityOption(id: 'aac', label: 'AAC'),
        QualityOption(id: 'flac', label: 'FLAC'),
      ]),
    );
    expect(container.read(settingsProvider).audioQuality, 'aac');
    const a = Extension(
      id: 'a',
      name: 'a',
      displayName: 'A',
      version: '1',
      description: '',
      enabled: true,
      status: 'loaded',
      hasDownloadProvider: true,
      qualityOptions: [QualityOption(id: 'opus', label: 'Opus')],
    );
    notifier.setDefaultDownloadExtension(a);
    expect(container.read(settingsProvider).audioQuality, 'opus');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final persisted = loadBootstrapSettings(
      await SharedPreferences.getInstance(),
    );
    expect(persisted.downloadQualityByProvider['b'], 'aac');
    expect(persisted.audioQuality, 'opus');
  });

  test(
    'late initial read retains latest selection and persisted unrelated settings',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(
          const AppSettings(
            defaultService: 'a',
            audioQuality: 'opus',
          ).toJson(),
        ),
        'settings_migration_version': 15,
      });
      final prefs = await SharedPreferences.getInstance();
      final pending = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => SettingsNotifier(preferences: () => pending.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      const b = Extension(
        id: 'b',
        name: 'b',
        displayName: 'B',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [
          QualityOption(id: 'aac', label: 'AAC'),
          QualityOption(id: 'flac', label: 'FLAC'),
        ],
      );
      notifier.setDefaultDownloadExtension(b);
      notifier.setAudioQuality('flac');
      pending.complete(prefs);
      await notifier.ensureLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final saved = loadBootstrapSettings(prefs);
      expect(saved.defaultService, 'b');
      expect(saved.audioQuality, 'flac');
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      final restoredNotifier = restarted.read(settingsProvider.notifier);
      await restoredNotifier.ensureLoaded();
      expect(restarted.read(settingsProvider).defaultService, 'b');
      expect(restarted.read(settingsProvider).audioQuality, 'flac');
      expect(
        restarted.read(settingsProvider).downloadQualityByProvider['b'],
        'flac',
      );
      const a = Extension(
        id: 'a',
        name: 'a',
        displayName: 'A',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [QualityOption(id: 'opus', label: 'Opus')],
      );
      restoredNotifier.setDefaultDownloadExtension(a);
      expect(restarted.read(settingsProvider).audioQuality, 'opus');
      restoredNotifier.setAudioQualityForProvider('b', 'aac');
      restoredNotifier.setAudioQualityForProvider('a', 'opus');
      expect(restarted.read(settingsProvider).audioQuality, 'opus');
      expect(
        restarted.read(settingsProvider).downloadQualityByProvider['b'],
        'aac',
      );
    },
  );

  test('reset clears the explicit source preference across restart and switching', () async {
    SharedPreferences.setMockInitialValues({});
    const amazon = Extension(
      id: 'amazon',
      name: 'amazon',
      displayName: 'Amazon Music',
      version: '1',
      description: '',
      enabled: true,
      status: 'loaded',
      hasDownloadProvider: true,
      qualityOptions: [
        QualityOption(id: 'best', label: 'FLAC Best Available'),
        QualityOption(id: 'opus', label: 'Opus 320kbps'),
      ],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setDefaultDownloadExtension(amazon);
    notifier.setAudioQuality('opus');
    expect(container.read(settingsProvider).audioQuality, 'opus');

    notifier.setAudioQualityForProvider('amazon', '');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    final restored = restarted.read(settingsProvider.notifier);
    await restored.ensureLoaded();
    expect(restarted.read(settingsProvider).audioQuality, isEmpty);
    expect(restarted.read(settingsProvider).downloadQualityByProvider['amazon'], isEmpty);
    restored.setDefaultDownloadExtension(amazon.copyWith(id: 'other'));
    restored.setDefaultDownloadExtension(amazon);
    expect(restarted.read(settingsProvider).audioQuality, isEmpty);
  });

  test('known provider does not save its only tier when the default is absent', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ensureLoaded();
    notifier.setDefaultDownloadExtension(const Extension(
      id: 'amazon',
      name: 'amazon',
      displayName: 'Amazon Music',
      version: '1',
      description: '',
      enabled: true,
      status: 'loaded',
      hasDownloadProvider: true,
      qualityOptions: [QualityOption(id: 'eac3', label: 'Dolby Digital Plus')],
    ));
    expect(container.read(settingsProvider).audioQuality, isEmpty);
    expect(container.read(settingsProvider).downloadQualityByProvider, isEmpty);
  });
}
