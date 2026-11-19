import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

AppSettings _fixtureSettings = const AppSettings();
bool _failSettingsLoad = false;
Completer<void>? _completionGate;
int _completionLoads = 0;

class _FailingStore extends SharedPreferencesStorePlatform {
  bool failWrites = false;
  Completer<void>? pendingWrite;
  Completer<void>? writeStarted;
  final values = <String, Object>{};
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writeStarted?.complete();
    writeStarted = null;
    await pendingWrite?.future;
    if (failWrites) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async => values.remove(key) != null;
  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => _fixtureSettings;

  @override
  Future<void> ensureLoaded() async {
    if (_failSettingsLoad) throw StateError('settings unavailable');
  }
}

class _RecoveringSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    if (_failSettingsLoad) throw StateError('settings unavailable');
    state = _fixtureSettings;
  }
}

class _BlockingSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    final gate = _completionGate;
    if (gate != null) {
      _completionLoads++;
      await gate.future;
    }
  }
}

const _backend = MethodChannel('com.zarz.mornye/backend');
const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3AMusic';

Widget _setup({
  bool disableAnimations = false,
  double textScale = 1,
  bool musa = false,
}) => ProviderScope(
  overrides: [settingsProvider.overrideWith(_Settings.new)],
  child: MaterialApp(
    theme: musa ? MornyeTheme.build(Brightness.dark) : null,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: disableAnimations,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const SetupScreen(),
  ),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  var permissionCalls = 0;
  var folderCalls = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _fixtureSettings = const AppSettings();
    _failSettingsLoad = false;
    _completionGate = null;
    _completionLoads = 0;
    prefs = await SharedPreferences.getInstance();
    permissionCalls = folderCalls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_permissions, (
      _,
    ) async {
      permissionCalls++;
      throw StateError('First run must not inspect or request permissions');
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_backend, (
      call,
    ) async {
      if (call.method == 'getAndroidSdkVersion') return 33;
      if (call.method.contains('Saf') || call.method.contains('Folder')) {
        folderCalls++;
      }
      return null;
    });
  });

  for (final mode in ['fresh', 'plain', 'saf', 'bookmark', 'network']) {
    testWidgets('completion goes Home and preserves $mode storage', (
      tester,
    ) async {
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => '/private/app',
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          paths,
          null,
        ),
      );
      _fixtureSettings = AppSettings(
        downloadDirectory: mode == 'fresh' || mode == 'network'
            ? ''
            : '/user/Music',
        networkDownloadFolder: mode == 'network' ? 'nas:Music' : '',
        storageMode: mode == 'saf' ? 'saf' : 'app',
        downloadTreeUri: mode == 'saf' ? _treeUri : '',
        downloadDirectoryBookmark: mode == 'bookmark' ? 'user-bookmark' : '',
      );
      await prefs.setString(
        'setup_progress_v1',
        jsonEncode({
          'flowVersion': 2,
          'step': 2,
          'genres': ['Banda'],
          'artistNames': ['Peso Pluma'],
        }),
      );
      final router = GoRouter(
        initialLocation: '/setup',
        routes: [
          GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
          GoRoute(path: '/', builder: (_, _) => const Text('Home fixture')),
          GoRoute(
            path: '/tutorial',
            builder: (_, _) => const Text('Forced tutorial'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsProvider.overrideWith(_Settings.new)],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SetupScreen)),
      );
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Home fixture'), findsOneWidget);
      expect(find.text('Forced tutorial'), findsNothing);
      final settings = container.read(settingsProvider);
      expect(settings.isFirstLaunch, isFalse);
      expect(settings.hasCompletedTutorial, isTrue);
      expect(
        settings.downloadDirectory,
        mode == 'fresh' || mode == 'network' ? '' : '/user/Music',
      );
      expect(settings.downloadTreeUri, mode == 'saf' ? _treeUri : '');
      expect(
        settings.downloadDirectoryBookmark,
        mode == 'bookmark' ? 'user-bookmark' : '',
      );
      expect(
        settings.networkDownloadFolder,
        mode == 'network' ? 'nas:Music' : '',
      );
      expect(prefs.getString('setup_progress_v1'), isNull);
      expect(permissionCalls, 0);
      expect(folderCalls, 0);
    });
  }
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_permissions, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_backend, null);
  });

  testWidgets(
    'new installation shows quality and import without permissions or folder picker',
    (tester) async {
      await prefs.setString(
        'setup_progress_v1',
        '{"flowVersion":4,"step":0}',
      );
      await tester.pumpWidget(_setup(disableAnimations: true));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('Sound quality'), findsOneWidget);
      expect(find.text('Which genres do you like?'), findsNothing);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('Import library'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
      for (final name in ['Spotify', 'Apple Music', 'YouTube Music']) {
        expect(find.byKey(ValueKey('setup_import_$name')), findsOneWidget);
      }
      expect(permissionCalls, 0);
      expect(folderCalls, 0);
      final draft = jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
      expect(draft['flowVersion'], 4);
      expect(draft.containsKey('genres'), isFalse);
      expect(draft.containsKey('artistNames'), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);
    },
  );

  for (final scenario in [
    'recover',
    'draft',
    'bookmark',
    'settings',
    'network',
    'newFlow',
    'invalid',
  ]) {
    testWidgets('native legacy SAF migration respects $scenario choice', (
      tester,
    ) async {
      var reads = 0;
      var acknowledgements = 0;
      final payload = jsonEncode({
        'tree_uri': scenario == 'invalid'
            ? 'https://example.com/tree/music'
            : _treeUri,
        'display_name': 'Recovered Music',
      });
      _fixtureSettings = AppSettings(
        downloadTreeUri: scenario == 'settings' ? 'content://new/tree/new' : '',
        networkDownloadFolder: scenario == 'network' ? 'nas:chosen' : '',
      );
      await prefs.setString(
        'setup_progress_v1',
        jsonEncode({
          'step': scenario == 'newFlow' ? 0 : 4,
          if (scenario == 'newFlow') 'flowVersion': 2,
          if (scenario == 'draft') 'treeUri': 'content://new/tree/draft',
          if (scenario == 'bookmark') 'bookmark': 'chosen-bookmark',
        }),
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_backend, (
        call,
      ) async {
        if (call.method == 'getAndroidSdkVersion') return 33;
        if (call.method == 'readSetupFolderSelection') {
          reads++;
          return payload;
        }
        if (call.method == 'acknowledgeSetupFolderSelection') {
          acknowledgements++;
          final draft =
              jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
          expect(draft['flowVersion'], 4);
          expect(draft['treeUri'], _treeUri);
          expect(draft['directory'], 'Recovered Music');
        }
        return null;
      });
      await tester.pumpWidget(_setup(disableAnimations: true));
      await tester.pumpAndSettle();
      expect(reads, scenario == 'recover' || scenario == 'invalid' ? 1 : 0);
      expect(acknowledgements, scenario == 'recover' ? 1 : 0);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      final draft = jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
      if (scenario == 'recover') expect(draft['treeUri'], _treeUri);
      if (scenario == 'draft') {
        expect(draft['treeUri'], 'content://new/tree/draft');
      }
      if (scenario == 'bookmark') expect(draft['bookmark'], 'chosen-bookmark');
      if (scenario == 'invalid') expect(draft['treeUri'], isNull);
      expect(permissionCalls, 0);
    });
  }

  for (final step in [0, 4, 5, 6, 7, 99]) {
    testWidgets('legacy step $step migrates without losing choices', (
      tester,
    ) async {
      await prefs.setString(
        'setup_progress_v1',
        jsonEncode({
          'step': step,
          'directory': 'Music',
          'treeUri': _treeUri,
        }),
      );
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      final migrated = (step - 5).clamp(0, 2);
      expect(find.text('${migrated == 2 ? 2 : 1}/2'), findsOneWidget);
      if (migrated < 2) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        final draft = jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
        expect(draft['treeUri'], _treeUri);
        expect(draft['flowVersion'], 4);
      }
      expect(permissionCalls, 0);
      expect(folderCalls, 0);
    });
  }

  testWidgets('stored music preferences are left alone by setup', (
    tester,
  ) async {
    const stored = '{"genres":["Rock"],"artists":["Someone"]}';
    await prefs.setString('setup_progress_v1', '{"flowVersion":4,"step":0}');
    await prefs.setString('music_preferences_v1', stored);
    await tester.pumpWidget(_setup(disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    final draft = jsonDecode(prefs.getString('setup_progress_v1')!) as Map;
    expect(draft.containsKey('genres'), isFalse);
    expect(prefs.getString('music_preferences_v1'), stored);
  });

  for (final step in [0, 1, 2]) {
    testWidgets('step $step keeps actions outside small large-text content', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await prefs.setString(
        'setup_progress_v1',
        jsonEncode({'flowVersion': 2, 'step': step}),
      );
      await tester.pumpWidget(_setup(textScale: 2, musa: true));
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(PageView));
      final actions = tester.getRect(
        find.byKey(const ValueKey('setup_navigation')),
      );
      expect(viewport.bottom, lessThanOrEqualTo(actions.top));
      expect(actions.bottom, lessThanOrEqualTo(568));
      if (step == 2) {
        expect(
          find.text(
            'Import a playlist from a file or public link. Automatic downloading is off.',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final enabled in [false, true]) {
    testWidgets('import description reflects automatic download $enabled', (
      tester,
    ) async {
      _fixtureSettings = AppSettings(autoDownloadSavedTracks: enabled);
      await prefs.setString(
        'setup_progress_v1',
        jsonEncode({'flowVersion': 2, 'step': 2}),
      );
      await tester.pumpWidget(_setup());
      await tester.pumpAndSettle();
      expect(
        find.text(
          enabled
              ? 'Import a playlist from a file or public link. Tracks may be queued for automatic download.'
              : 'Import a playlist from a file or public link. Automatic downloading is off.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('failed settings load blocks import until retry succeeds', (
    tester,
  ) async {
    await prefs.setString(
      'setup_progress_v1',
      jsonEncode({'flowVersion': 2, 'step': 2}),
    );
    _fixtureSettings = const AppSettings(autoDownloadSavedTracks: true);
    _failSettingsLoad = true;
    await tester.pumpWidget(_setup());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('setup_import_playlist_link')),
          )
          .enabled,
      isFalse,
    );
    _failSettingsLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('setup_import_playlist_link')),
          )
          .enabled,
      isTrue,
    );
    expect(
      find.textContaining('queued for automatic download'),
      findsOneWidget,
    );
  });

  testWidgets('completion retries settings load before touching saved folder', (
    tester,
  ) async {
    await prefs.setString(
      'setup_progress_v1',
      jsonEncode({
        'flowVersion': 2,
        'step': 2,
      }),
    );
    _fixtureSettings = const AppSettings(
      downloadDirectory: '/existing/music',
      autoDownloadSavedTracks: true,
    );
    _failSettingsLoad = true;
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
        GoRoute(path: '/', builder: (_, _) => const Text('Home fixture')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_RecoveringSettings.new)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SetupScreen)),
    );
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(container.read(settingsProvider).downloadDirectory, isEmpty);
    expect(prefs.getString('music_preferences_v1'), isNull);
    expect(prefs.getString('setup_progress_v1'), isNotNull);

    _failSettingsLoad = false;
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.text('Home fixture'), findsOneWidget);
    expect(
      container.read(settingsProvider).downloadDirectory,
      '/existing/music',
    );
    expect(container.read(settingsProvider).autoDownloadSavedTracks, isTrue);
    expect(prefs.getString('music_preferences_v1'), isNull);
  });

  testWidgets('failed step save offers retry and keeps the step', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = _FailingStore();
    SharedPreferencesStorePlatform.instance = store;
    store.values['flutter.setup_progress_v1'] = '{"flowVersion":4,"step":0}';
    await tester.pumpWidget(_setup(disableAnimations: true));
    await tester.pumpAndSettle();
    store.failWrites = true;
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Could not save progress. Your selections are still here.'),
      findsOneWidget,
    );
    expect(find.text('1/2'), findsOneWidget);
    store.failWrites = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    final draft =
        jsonDecode(store.values['flutter.setup_progress_v1'] as String) as Map;
    expect(draft['step'], 1);
  });

  testWidgets('a pending step save blocks further taps and recovers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = _FailingStore();
    SharedPreferencesStorePlatform.instance = store;
    store.values['flutter.setup_progress_v1'] = '{"flowVersion":4,"step":0}';
    await tester.pumpWidget(_setup(disableAnimations: true));
    await tester.pumpAndSettle();
    store.pendingWrite = Completer<void>();
    store.writeStarted = Completer<void>();
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(store.writeStarted, isNull);
    await tester.tap(find.text('Next'), warnIfMissed: false);
    await tester.pump();
    store.pendingWrite!.complete();
    store.pendingWrite = null;
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_setup(disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    final draft =
        jsonDecode(store.values['flutter.setup_progress_v1'] as String) as Map;
    expect(draft['step'], 1);
  });

  testWidgets('two completion actions start only one operation', (
    tester,
  ) async {
    await prefs.setString(
      'setup_progress_v1',
      jsonEncode({'flowVersion': 2, 'step': 2}),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_BlockingSettings.new)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final skip = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Skip for now'))
        .onPressed!;
    final gate = _completionGate = Completer<void>();
    skip();
    skip();
    await tester.pump();
    final calls = _completionLoads;
    gate.completeError(StateError('controlled completion failure'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
}
