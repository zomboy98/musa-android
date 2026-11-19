import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    SharedPreferences.setMockInitialValues({'guided_tour_completed': true});
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

  Future<void> pumpShell(WidgetTester tester, {required bool mornye}) async {
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
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          downloadQueueProvider.overrideWith(_Queue.new),
          repoProvider.overrideWith(_Repo.new),
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

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('Back from a Library page returns to the Library root and '
        'keeps the tab ($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      final navigator =
          ShellNavigationService.libraryTabNavigatorKey.currentState!;
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('probe-section')),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('probe-section'), findsOneWidget);

      await back(tester);

      expect(find.text('probe-section'), findsNothing);
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.libraryTabNavigatorKey.currentState),
      );
      expect(navigator.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Back from the Library root goes to Home ($style)', (
      tester,
    ) async {
      await pumpShell(tester, mornye: mornye);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.libraryTabNavigatorKey.currentState),
      );

      await back(tester);

      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.homeTabNavigatorKey.currentState),
      );
      expect(tester.takeException(), isNull);
    });
  }

  {
    // The chips belong to the Mornye library home.
    const mornye = true;
    const style = 'Mornye';

    testWidgets('Back from a Library filter returns to All, then to Home '
        '($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      expect(find.byKey(const ValueKey('library-filter-clear')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('library-filter-songs')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('library-filter-clear')),
        findsOneWidget,
      );

      await back(tester);

      expect(find.byKey(const ValueKey('library-filter-clear')), findsNothing);
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.libraryTabNavigatorKey.currentState),
      );

      await back(tester);

      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.homeTabNavigatorKey.currentState),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Back from a page opened over a filter returns to that '
        'filter, then to All ($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('library-filter-albums')));
      await settle(tester);
      final navigator =
          ShellNavigationService.libraryTabNavigatorKey.currentState!;
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('probe-album')),
          ),
        ),
      );
      await settle(tester);

      await back(tester);

      expect(find.text('probe-album'), findsNothing);
      expect(
        find.byKey(const ValueKey('library-filter-clear')),
        findsOneWidget,
      );

      await back(tester);

      expect(find.byKey(const ValueKey('library-filter-clear')), findsNothing);
      expect(
        ShellNavigationService.activeTabNavigator(),
        same(ShellNavigationService.libraryTabNavigatorKey.currentState),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Opening the Songs collection from All and going back '
        'returns to All ($style)', (tester) async {
      await pumpShell(tester, mornye: mornye);
      ShellNavigationService.requestTab(ShellTab.library);
      await settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('library-entry-pinned:songs')),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey('library-filter-clear')),
        findsOneWidget,
      );

      await back(tester);

      expect(find.byKey(const ValueKey('library-filter-clear')), findsNothing);
      expect(
        find.byKey(const ValueKey('library-entry-pinned:songs')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('The shell keeps system back with the framework after a root '
      'dialog closes over a Library page', (tester) async {
    final handlesBack = <bool>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        handlesBack.add(call.arguments as bool);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpShell(tester, mornye: true);
    ShellNavigationService.requestTab(ShellTab.library);
    await settle(tester);
    unawaited(
      ShellNavigationService.libraryTabNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('probe-section')),
        ),
      ),
    );
    await settle(tester);
    final context = tester.element(find.text('probe-section'));
    final dialog = showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const AlertDialog(content: Text('probe-dialog')),
    );
    await settle(tester);
    Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    await settle(tester);

    expect(handlesBack, isNotEmpty);
    expect(handlesBack.last, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back from Favoritas opened from the Library returns to the '
      'Library (Mornye)', (tester) async {
    await pumpShell(tester, mornye: true);
    await tester.tap(find.text('Library').last);
    await settle(tester);
    final navigator =
        ShellNavigationService.libraryTabNavigatorKey.currentState!;
    await tester.tap(find.text('Favorites').first);
    await settle(tester);
    expect(navigator.canPop(), isTrue);

    await back(tester);

    expect(navigator.canPop(), isFalse);
    expect(
      ShellNavigationService.activeTabNavigator(),
      same(ShellNavigationService.libraryTabNavigatorKey.currentState),
    );
    expect(tester.takeException(), isNull);
  });
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(searchProvider: 'example');
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'catalog',
        name: 'catalog',
        displayName: 'Catalog',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
      ),
    ],
  );
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

  void setQueued(int count) => state = state.copyWith(
    items: [
      for (var i = 0; i < count; i++)
        DownloadItem(
          id: 'queued-$i',
          track: Track(
            id: 'track-$i',
            name: 'Song $i',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1000,
          ),
          service: 'example-provider',
          createdAt: DateTime(2026),
        ),
    ],
  );
}

class _Repo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(isInitialized: true);

  @override
  Future<void> initialize(String cacheDir) async {}

  void setUpdates(int count) => state = state.copyWith(
    extensions: [
      for (var i = 0; i < count; i++)
        RepoExtension(
          id: 'extension-$i',
          name: 'extension-$i',
          displayName: 'Extension $i',
          version: '1.0.0',
          description: '',
          category: RepoCategory.metadata,
          updatedAt: '2026-01-01',
          isInstalled: true,
          hasUpdate: true,
        ),
    ],
  );
}
