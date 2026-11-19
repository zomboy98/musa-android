import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
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
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_navigation.dart';
import 'package:mornye/widgets/playback_provider_setup.dart';
import 'package:mornye/widgets/playback_feedback.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

import 'support/music_player_automix_harness.dart';

class _Runtime extends MusicPlayerRuntime {
  @override
  MusicPlayerHandler? get handler => handlerForTest;
  @override
  Future<void> restoreSession() async {}
  @override
  Stream<PlaybackState> playbackStateEvents() =>
      handlerForTest!.playbackState.stream;
}

MusicPlayerHandler? handlerForTest;

Future<void> openSettingsAndReturn(WidgetTester tester) async {
  await tester.tap(find.text('Open settings'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pageBack();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Remote implements RemotePlayback {
  @override
  String get name => 'Remote';
  @override
  Stream<MediaItem?> get mediaItems => const Stream.empty();
  @override
  Stream<PlaybackState> get playbackStates => const Stream.empty();
  @override
  Stream<List<MediaItem>> get queues => const Stream.empty();
  @override
  Stream<double> get volumes => const Stream.empty();
  @override
  Stream<RemoteTransfer?> get transfers => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RetryHandler extends MusicPlayerHandler {
  int generation = 1;
  int retries = 0;
  @override
  int get playbackRequestGeneration => generation;
  @override
  Future<void> skipToQueueItem(int index) async {
    retries++;
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    searchProvider: 'example',
    playerMode: 'external',
  );
  @override
  void setDefaultService(String v) => state = state.copyWith(defaultService: v);
  @override
  bool setDefaultDownloadExtension(Extension v, {bool confirmed = false}) {
    state = state.copyWith(
      defaultService: v.id,
      playbackProviderConfirmed: confirmed,
    );
    return true;
  }

  @override
  void setPlaybackQuality(String v) =>
      state = state.copyWith(playbackQuality: v);
  @override
  void setAudioQuality(String v) => state = state.copyWith(audioQuality: v);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [QualityOption(id: 'low', label: 'Low quality')],
      ),
    ],
  );
  @override
  Future<void> ensureInitialized() async {}
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

void main() {
  setUpMusicPlayerHarness();
  const backend = MethodChannel('com.zarz.mornye/backend');
  late SchedulingStrategy strategy;
  setUp(() async {
    strategy = SchedulerBinding.instance.schedulingStrategy;
    SchedulerBinding.instance.schedulingStrategy =
        ({required priority, required scheduler}) => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backend, (_) async => null);
    await handler.dispose();
    handler = _RetryHandler();
    handlerForTest = handler;
    handler.mediaItem.add(const MediaItem(id: 'catalog:one', title: 'One'));
  });
  tearDown(() {
    SchedulerBinding.instance.schedulingStrategy = strategy;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backend, null);
    debugDesktopPlatformOverride = null;
    handlerForTest = null;
  });

  RemotePlayback? remote;
  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDesktopPlatformOverride = false;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final runtime = _Runtime();
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const MainShell())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          activeRemotePlaybackProvider.overrideWith((_) => remote),
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          downloadQueueProvider.overrideWith(_Queue.new),
          repoProvider.overrideWith(_Repo.new),
          playbackStateProvider.overrideWith((_) => handler.playbackState),
          currentMediaItemProvider.overrideWithBuild(
            (_, _) => Stream.value(null),
          ),
          systemVolumeProvider.overrideWith((_) => Stream.value(0.5)),
          desktopSidebarPlaylistsProvider.overrideWithValue(const []),
          desktopSidebarProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp.router(
          builder: (_, child) =>
              AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return ProviderScope.containerOf(tester.element(find.byType(MainShell)));
  }

  Future<void> emit(WidgetTester tester, String error, {int? index}) async {
    if (index != null && handler.queue.value.isEmpty) {
      handler.queue.add([const MediaItem(id: 'catalog:one', title: 'One')]);
    }
    handler.playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: error,
        queueIndex: index,
      ),
    );
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('provider failure opens one sheet and cancel changes nothing', (
    tester,
  ) async {
    final container = await launch(tester);
    const error =
        'CatalogPlaybackException: $catalogProviderUnavailableCategory';
    await emit(tester, error);
    expect(find.byType(PlaybackProviderSetup), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await emit(tester, error);
    expect(find.byType(PlaybackProviderSetup), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(container.read(settingsProvider).defaultService, isEmpty);
    expect(container.read(settingsProvider).playerMode, 'external');
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final mutation in ['generation', 'handler']) {
    testWidgets('setup does not open after $mutation changes before callback', (
      tester,
    ) async {
      await launch(tester);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mutation == 'generation') {
          (handler as _RetryHandler).generation++;
        } else {
          handlerForTest = null;
        }
      });
      await emit(
        tester,
        'CatalogPlaybackException: $catalogProviderUnavailableCategory',
      );
      expect(find.byType(PlaybackProviderSetup), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      if (mutation == 'generation') {
        expect((handler as _RetryHandler).generation, 2);
      } else {
        expect(handlerForTest, isNull);
        handlerForTest = handler;
      }
      await emit(tester, 'CatalogPlaybackException: provider download failed');
      expect(
        find.text('The provider could not retrieve the song. Please try again.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('remote activation before callback prevents stale setup', (
    tester,
  ) async {
    remote = null;
    final container = await launch(tester);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      remote = _Remote();
      container.invalidate(activeRemotePlaybackProvider);
    });
    await emit(
      tester,
      'CatalogPlaybackException: $catalogProviderUnavailableCategory',
    );
    expect(find.byType(PlaybackProviderSetup), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(container.read(activeRemotePlaybackProvider), isNotNull);
    remote = null;
    container.invalidate(activeRemotePlaybackProvider);
    await tester.pump();
    await emit(tester, 'CatalogPlaybackException: provider download failed');
    expect(
      find.text('The provider could not retrieve the song. Please try again.'),
      findsOneWidget,
    );
  });

  for (final mismatch in ['message', 'generation']) {
    testWidgets('setup marker does not suppress a different $mismatch', (
      tester,
    ) async {
      remote = null;
      final container = await launch(tester);
      final marker = container.read(playbackSetupNoticeProvider);
      marker.handler = handler;
      marker.generation =
          (handler as _RetryHandler).generation +
          (mismatch == 'generation' ? 1 : 0);
      marker.message = mismatch == 'message'
          ? 'CatalogPlaybackException: $catalogProviderUnavailableCategory'
          : 'CatalogPlaybackException: provider download failed';
      await emit(tester, 'CatalogPlaybackException: provider download failed');
      expect(
        find.text(
          'The provider could not retrieve the song. Please try again.',
        ),
        findsOneWidget,
      );
      expect(find.byType(PlaybackProviderSetup), findsNothing);
    });
  }

  testWidgets('unrelated errors do not open setup', (tester) async {
    await launch(tester);
    for (final error in [
      'CatalogPlaybackException: preparation failed',
      'CatalogPlaybackException: provider download failed',
      'network error',
      'authentication failed',
    ]) {
      await emit(tester, error);
      expect(find.byType(PlaybackProviderSetup), findsNothing);
    }
  });

  testWidgets(
    'provider intervention reports access issue without changing provider',
    (tester) async {
      final container = await launch(tester);
      container.read(settingsProvider.notifier).setDefaultService('example');
      expect(container.read(settingsProvider).defaultService, 'example');
      await emit(
        tester,
        'CatalogPlaybackException: $catalogProviderInterventionCategory',
        index: 0,
      );
      expect(find.byType(PlaybackProviderSetup), findsNothing);
      expect(
        find.text('Complete the provider verification to play this song.'),
        findsOneWidget,
      );
      expect(container.read(settingsProvider).defaultService, 'example');
      expect((handler as _RetryHandler).retries, 0);
    },
  );

  testWidgets(
    'opening settings leaves preferences untouched and does not retry without a queue index',
    (tester) async {
      final container = await launch(tester);
      await emit(
        tester,
        'CatalogPlaybackException: $catalogProviderUnavailableCategory',
      );
      await openSettingsAndReturn(tester);
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(container.read(settingsProvider).defaultService, isEmpty);
      expect(container.read(settingsProvider).playerMode, 'external');
      expect((handler as _RetryHandler).retries, 0);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
    },
  );
  testWidgets('returning from settings retries once while the same request is current', (
    tester,
  ) async {
    await launch(tester);
    await emit(
      tester,
      'CatalogPlaybackException: $catalogProviderUnavailableCategory',
      index: 0,
    );
    await openSettingsAndReturn(tester);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect((handler as _RetryHandler).retries, 1);
  });

  testWidgets('a changed playback generation prevents retry', (tester) async {
    await launch(tester);
    await emit(
      tester,
      'CatalogPlaybackException: $catalogProviderUnavailableCategory',
      index: 0,
    );
    (handler as _RetryHandler).generation++;
    await openSettingsAndReturn(tester);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect((handler as _RetryHandler).retries, 0);
  });

  for (final mutation in ['reorder', 'remove', 'duplicates']) {
    testWidgets('queue $mutation while sheet is open prevents retry', (
      tester,
    ) async {
      await launch(tester);
      final first = const MediaItem(id: 'catalog:one', title: 'One');
      final second = MediaItem(
        id: mutation == 'duplicates' ? 'catalog:one' : 'catalog:two',
        title: 'Other',
      );
      handler.queue.add([first, second]);
      await emit(
        tester,
        'CatalogPlaybackException: $catalogProviderUnavailableCategory',
        index: 0,
      );
      handler.queue.add(mutation == 'remove' ? [second] : [second, first]);
      await tester.pump();
      await openSettingsAndReturn(tester);
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect((handler as _RetryHandler).retries, 0);
    });
  }
}
