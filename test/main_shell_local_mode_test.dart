import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _provider = Extension(
  id: 'example-provider',
  name: 'example-provider',
  displayName: 'Example Provider',
  version: '1.0.0',
  description: '',
  enabled: true,
  status: 'ready',
  hasMetadataProvider: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SchedulingStrategy schedulingStrategy;

  setUp(() {
    schedulingStrategy = SchedulerBinding.instance.schedulingStrategy;
    SchedulerBinding.instance.schedulingStrategy =
        ({required priority, required scheduler}) => true;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(backend, (_) async => null);
  });
  tearDown(() {
    SchedulerBinding.instance.schedulingStrategy = schedulingStrategy;
    messenger.setMockMethodCallHandler(backend, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool mornye,
    List<Extension> extensions = const [],
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const MainShell())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(
            () => _Extensions()..seed = extensions,
          ),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          downloadQueueProvider.overrideWith(_Queue.new),
          repoProvider.overrideWith(_Repo.new),
          libraryBrowsePageLoaderProvider.overrideWithValue(
            (page) async => const LibraryBrowsePage([]),
          ),
          libraryCountsProvider.overrideWith(
            (ref, request) async => const QueueLibraryCounts(
              allTrackCount: 0,
              albumCount: 0,
              singleTrackCount: 0,
            ),
          ),
          savedLibraryTracksProvider.overrideWithBuild(
            (ref, notifier) async => const [],
          ),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          desktopSidebarPlaylistsProvider.overrideWithValue(const []),
          desktopSidebarProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp.router(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          onNavigationNotification:
              ShellNavigationService.onNavigationNotification,
        ),
      ),
    );
    await tester.pump();
    await settle(tester);
  }

  Future<void> disposeShell(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  _Extensions extensionsOf(WidgetTester tester) =>
      ProviderScope.containerOf(
            tester.element(find.byType(MainShell)),
          ).read(extensionProvider.notifier)
          as _Extensions;

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('Without add-ons the shell shows only the local Library '
        '($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);

      expect(find.text('Home'), findsNothing);
      expect(find.text('Search'), findsNothing);
      if (mornye) {
        expect(find.text('Your library is empty'), findsOneWidget);
        expect(find.text('Add your music from your phone'), findsOneWidget);
        expect(find.text('Choose music folders'), findsOneWidget);
        expect(find.text('Downloaded'), findsNothing);
        expect(find.byKey(const ValueKey('library_import')), findsNothing);
      } else {
        expect(find.text('Library'), findsWidgets);
        expect(find.text('Settings'), findsWidgets);
      }
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.libraryTabNavigatorKey.currentState),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('With an add-on the shell shows Home and the catalog tabs '
        '($style)', (tester) async {
      await pumpShell(tester, mornye: mornye, extensions: const [_provider]);

      expect(find.text('Home'), findsWidgets);
      if (mornye) expect(find.text('Search'), findsWidgets);
      expect(find.text('Choose music folders'), findsNothing);
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.homeTabNavigatorKey.currentState),
      );
      expect(tester.takeException(), isNull);
      await disposeShell(tester);
    });

    testWidgets('Installing and removing the last add-on switches the '
        'shell without a restart ($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);
      expect(find.text('Home'), findsNothing);

      extensionsOf(tester).setExtensions(const [_provider]);
      await settle(tester);
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Choose music folders'), findsNothing);

      extensionsOf(tester).setExtensions(const []);
      await settle(tester);
      expect(find.text('Home'), findsNothing);
      if (mornye) expect(find.text('Choose music folders'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeShell(tester);
    });
  }

  test('hasCatalogProvider needs an enabled metadata or download provider', () {
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(_Extensions.new)],
    );
    addTearDown(container.dispose);
    expect(container.read(hasCatalogProvider), isFalse);
    expect(container.read(localOnlyModeProvider), isTrue);
    final notifier = container.read(extensionProvider.notifier) as _Extensions;
    notifier.setExtensions(const [
      Extension(
        id: 'lyrics-only',
        name: 'lyrics-only',
        displayName: 'Lyrics',
        version: '1',
        description: '',
        enabled: true,
        status: 'ready',
        hasLyricsProvider: true,
      ),
    ]);
    expect(container.read(hasCatalogProvider), isFalse);
    notifier.setExtensions(const [
      Extension(
        id: 'downloads',
        name: 'downloads',
        displayName: 'Downloads',
        version: '1',
        description: '',
        enabled: false,
        status: 'ready',
        hasDownloadProvider: true,
      ),
    ]);
    expect(container.read(hasCatalogProvider), isFalse);
    notifier.setExtensions(const [
      Extension(
        id: 'downloads',
        name: 'downloads',
        displayName: 'Downloads',
        version: '1',
        description: '',
        enabled: true,
        status: 'ready',
        hasDownloadProvider: true,
      ),
    ]);
    expect(container.read(hasCatalogProvider), isTrue);
    expect(container.read(localOnlyModeProvider), isFalse);
  });
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(searchProvider: 'example');
}

class _Extensions extends ExtensionNotifier {
  List<Extension> seed = const [];

  @override
  ExtensionState build() =>
      ExtensionState(isInitialized: true, extensions: seed);

  void setExtensions(List<Extension> extensions) =>
      state = ExtensionState(isInitialized: true, extensions: extensions);
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState();
}

class _Repo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(isInitialized: true);

  @override
  Future<void> initialize(String cacheDir) async {}
}
