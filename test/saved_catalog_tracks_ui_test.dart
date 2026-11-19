import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/screens/saved_catalog_tracks_screen.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/widgets/download_progress_icon.dart';
import 'support/add_to_music_helpers.dart';

Future<T> _unlocked<T>(Future<T> Function() action) => action();

class FakeQueue extends DownloadQueueNotifier {
  FakeQueue(this.items);
  final List<DownloadItem> items;
  @override
  DownloadQueueState build() => DownloadQueueState(items: items);
}

class FakePlayback extends PlaybackController {
  final played = <Track>[];

  @override
  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? playlistId,
    bool exactStart = false,
    bool requireLocalStart = false,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    played.addAll(tracks);
  }
}

int _completedChecks(WidgetTester tester) => find
    .byType(CustomPaint)
    .evaluate()
    .map((e) => (e.widget as CustomPaint).painter)
    .whereType<DownloadIconPainter>()
    .where((p) => p.phase == DownloadIconPhase.completed)
    .length;

void main() {
  const track = Track(
    id: '1',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 120,
    source: 'catalog',
  );

  testWidgets(
    'tapping a saved song starts catalog playback without downloading',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        SavedLibraryTracksNotifier.storageKey: jsonEncode([track.toJson()]),
      });
      final playback = FakePlayback();
      final queue = FakeQueue([]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackProvider.overrideWith(() => playback),
            downloadQueueProvider.overrideWith(() => queue),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SavedCatalogTracksScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song'));
      await tester.pumpAndSettle();
      expect(playback.played.map((item) => item.id), [track.id]);
      expect(playback.played.single.source, track.source);
      expect(queue.items, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('save, view and remove a catalog reference', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedCatalogRetentionLockProvider.overrideWithValue(_unlocked),
          promoteSavedCatalogAudioProvider.overrideWithValue(
            (_) async => false,
          ),
          pendingSavedCatalogPromotionProvider.overrideWithValue((_) => null),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                const SaveLibraryTrackButton(track: track),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SavedCatalogTracksScreen(),
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save song to library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-to-music-library')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-to-music-confirm')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Song'), findsOneWidget);
    expect(find.byTooltip('Download'), findsOneWidget);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    // The download action leaves the saved reference intact.
    expect(find.text('Song'), findsWidgets);
    // The saved row has no menu: the "+" sheet removes it from the library.
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(find.text('No saved songs yet'), findsOneWidget);
  });

  testWidgets('accessible download hides stale failure in the saved row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      SavedLibraryTracksNotifier.storageKey: jsonEncode([track.toJson()]),
    });
    final item = DownloadItem(
      id: 'job',
      track: track,
      service: 'test',
      status: DownloadStatus.failed,
      createdAt: DateTime(2026),
    );
    var checks = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadQueueProvider.overrideWith(() => FakeQueue([item])),
          savedLibraryTracksProvider.overrideWithBuild(
            (ref, notifier) async => [track],
          ),
          playlistRealDownloadProvider(track).overrideWith((ref) async {
            checks++;
            return true;
          }),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SavedCatalogTracksScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed'), findsNothing);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('download-library-track')),
    );
    expect(_completedChecks(tester), 1);
    expect(button.onPressed, isNull);
    expect(checks, 1);
  });

  for (final status in [
    DownloadStatus.queued,
    DownloadStatus.downloading,
    DownloadStatus.finalizing,
    DownloadStatus.failed,
    DownloadStatus.completed,
  ]) {
    testWidgets('queue status $status controls the download action', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        SavedLibraryTracksNotifier.storageKey: jsonEncode([track.toJson()]),
      });
      final item = DownloadItem(
        id: 'job',
        track: track,
        service: 'test',
        status: status,
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadQueueProvider.overrideWith(() => FakeQueue([item])),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SavedCatalogTracksScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final failed = status == DownloadStatus.failed;
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == (failed ? 'Retry' : 'Download'),
        ),
      );
      final active =
          status == DownloadStatus.queued ||
          status == DownloadStatus.downloading ||
          status == DownloadStatus.finalizing;
      expect(button.onPressed == null, active);
      if (failed) {
        expect(find.textContaining('Failed'), findsOneWidget);
        await tester.tap(find.byTooltip('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Song'), findsWidgets);
      }
      if (status == DownloadStatus.completed) {
        expect(find.text('Artist'), findsOneWidget);
        expect(find.textContaining('Downloaded'), findsNothing);
        expect(find.textContaining('Done'), findsNothing);
      }
    });
  }
}
