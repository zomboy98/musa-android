import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/add_to_music_helpers.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;

import 'support/fixed_settings.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String id) async => null;
  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String id) async => null;
  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String a,
    String b,
  ) async => null;
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'configured',
        'enabled': true,
        'has_download_provider': true,
      }),
    ],
  );
}

void main() {
  testWidgets(
    'unverified temporary stays playable while configured download is queued',
    (tester) async {
      const track = Track(
        id: 'saved-integration',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 120,
        source: 'catalog',
      );
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('saved-real-queue-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      final previousFactory = databaseFactoryOrNull;
      PathProviderPlatform.instance = _Paths(root.path);
      databaseFactory = databaseFactorySqflitePlugin;
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
        'download_queue_user_paused_v1': true,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const sqlite = MethodChannel('com.tekartik.sqflite');
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        if (call.method == 'openDatabase') return {'id': 1};
        final args = call.arguments as Map? ?? {};
        final sql = args['sql'] as String? ?? '';
        if (call.method == 'query') {
          if (sql.toLowerCase().contains('pragma user_version')) {
            return {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            };
          }
          return {'columns': <String>[], 'rows': <List<Object?>>[]};
        }
        return null;
      });
      final playback = CatalogPlayback();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                autoDownloadSavedTracks: true,
                defaultService: 'configured',
                audioQuality: 'LOSSLESS',
                localLibraryEnabled: false,
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          downloadHistoryProvider.overrideWith(_History.new),
          promoteSavedCatalogAudioProvider.overrideWithValue(playback.promote),
          pendingSavedCatalogPromotionProvider.overrideWithValue(
            playback.pendingSavedPromotion,
          ),
          savedCatalogRetentionLockProvider.overrideWithValue(
            playback.withRetentionLock,
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        messenger.setMockMethodCallHandler(sqlite, null);
        PathProviderPlatform.instance = previousPaths;
        databaseFactory = previousFactory;
        await tester.runAsync(() => root.delete(recursive: true));
      });
      late CatalogAudioLease playing;
      await tester.runAsync(() async {
        final store = await playback.store;
        final input = File('${root.path}/input.opus');
        await input.writeAsBytes([1, 2, 3]);
        await store.putTemporary(playback.key(track), input);
        playing = (await store.acquire(playback.key(track)))!;
        await container.read(savedLibraryTracksProvider.future);
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue();
        await queue.flushQueuePersistence();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SaveLibraryTrackButton(track: track)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('download-library-track')),
        findsOneWidget,
      );
      await tapSaveToLibrary(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      for (
        var i = 0;
        i < 100 && container.read(downloadQueueProvider).items.isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      final state = container.read(downloadQueueProvider);
      expect(state.items, hasLength(1));
      expect(await tester.runAsync(() => File(playing.path).readAsBytes()), [1, 2, 3]);
      expect(state.items.single.track.id, track.id);
      expect(state.items.single.service, 'configured');
      expect(state.items.single.qualityOverride, isNull);
      expect(state.audioQuality, 'LOSSLESS');
      expect(state.isPaused, isTrue);
      expect(state.isProcessing, isFalse);
      var released = false;
      playing.release().then((_) => released = true);
      for (var i = 0; i < 100 && !released; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(released, isTrue, reason: 'playback lease release must complete');
      // Let the confirmation snackbar expire.
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
