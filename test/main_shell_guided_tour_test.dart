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
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_overlay.dart';
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
          locale: const Locale('es'),
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

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    testWidgets('tour spotlights a real tab ($style)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpShell(tester, mornye: mornye);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.text('Siguiente'), findsOneWidget);
      final paint = tester.widget<CustomPaint>(
        find
            .descendant(
              of: find.byType(GuidedTourOverlay),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      final painter = paint.painter! as GuidedTourScrimPainter;

      expect(painter.hole, isNotNull);
      expect(painter.hole!.width, lessThan(215));
    });

    testWidgets('tour walks through Complementos and Fuentes ($style)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpShell(tester, mornye: mornye);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);

      Rect hole() {
        final paint = tester.widget<CustomPaint>(
          find
              .descendant(
                of: find.byType(GuidedTourOverlay),
                matching: find.byType(CustomPaint),
              )
              .first,
        );
        return (paint.painter! as GuidedTourScrimPainter).hole!;
      }

      Future<void> until(String title) async {
        for (var i = 0; i < 14 && find.text(title).evaluate().isEmpty; i++) {
          await tester.tap(find.text('Siguiente'));
          await settle(tester);
          await tester.pump(const Duration(milliseconds: 300));
          await settle(tester);
        }
        expect(find.text(title), findsOneWidget);
      }

      if (mornye) await until('Tu foto y Complementos');
      await until('Escribe tu código');
      expect(find.byType(ExtensionsPage), findsOneWidget);
      final field = tester.getRect(
        find.byKey(const ValueKey('plugin-code-field')),
      );
      expect(hole().contains(field.center), isTrue);

      await until('Fuente del catálogo');
      expect(find.byType(SourcesPage), findsOneWidget);

      await until('Fuente de Inicio');
      final home = tester.getRect(
        find.byKey(const ValueKey('sources_home_provider')),
      );
      expect(hole().contains(home.center), isTrue);

      await until('Listo para empezar');
      expect(find.byType(SourcesPage), findsNothing);
      expect(find.byType(ExtensionsPage), findsNothing);

      await tester.tap(find.text('Listo'));
      await settle(tester);
      expect(find.text('Siguiente'), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'guided_tour_completed',
        ),
        isTrue,
      );
    });

    testWidgets('skipping from a pushed page closes it ($style)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpShell(tester, mornye: mornye);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      for (
        var i = 0;
        i < 14 && find.byType(ExtensionsPage).evaluate().isEmpty;
        i++
      ) {
        await tester.tap(find.text('Siguiente'));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 300));
        await settle(tester);
      }
      expect(find.byType(ExtensionsPage), findsOneWidget);
      await tester.tap(find.text('Omitir'));
      await settle(tester);
      expect(find.byType(ExtensionsPage), findsNothing);
      expect(find.text('Siguiente'), findsNothing);
    });
  }
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
