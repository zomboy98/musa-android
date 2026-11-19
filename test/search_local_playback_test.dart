// Test doubles expose captured calls for assertions.
// ignore_for_file: avoid_public_notifier_properties

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/widgets/save_library_track_button.dart';

import 'support/search_results_fixture.dart';
import 'support/add_to_music_helpers.dart';

class _CatalogPlayback extends PlaybackController {
  final catalogTracks = <Track>[];
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
    catalogTracks.addAll(tracks);
  }
}

class _Queue extends DownloadQueueNotifier {
  final tracks = <Track>[];
  @override
  DownloadQueueState build() => const DownloadQueueState();
  @override
  Future<String?> addCurrentSavedTrackToQueue(
    Track track,
    String service,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return null;
    return addSavedTrackToQueue(track, service);
  }

  @override
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) async {
    tracks.add(track);
    return track.id;
  }
}

class _Extensions extends SearchFixtureExtensions {
  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    extensions: [
      ...super.build().extensions,
      Extension.fromJson({
        'id': 'configured',
        'enabled': true,
        'has_download_provider': true,
      }),
    ],
  );
}

void main() {
  const settings = AppSettings(
    searchProvider: 'example',
    localLibraryEnabled: false,
  );

  for (final desktop in [false, true]) {
    testWidgets(
      'search song starts playback on ${desktop ? 'desktop' : 'mobile'}',
      (tester) async {
        final playback = _CatalogPlayback();
        final queue = _Queue();
        await pumpSearchFixture(
          tester,
          size: Size(desktop ? 820 : 320, 1400),
          mornye: true,
          desktop: desktop,
          settings: settings,
          playback: playback,
          queue: queue,
        );
        await tester.tap(find.text('Found track 0'));
        await tester.pumpAndSettle();
        expect(playback.catalogTracks.map((track) => track.id), ['track-0']);
        expect(queue.tracks, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  }

  testWidgets('tapping the Top Results song subtitle starts playback', (
    tester,
  ) async {
    final playback = _CatalogPlayback();
    await pumpSearchFixture(
      tester,
      size: const Size(1000, 1800),
      mornye: true,
      desktop: true,
      settings: settings.copyWith(searchViewMode: 'grid'),
      results: SearchFixtureResults(count: 3, songCount: 8),
      filters: searchFixtureAllFilters,
      playback: playback,
    );
    const label = 'Song · Example artist 0';
    final subtitle = find.descendant(
      of: find.byKey(const ValueKey('top-track-track-0')),
      matching: find.text(label),
    );
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(label))), findsWidgets);
    await tester.tap(subtitle);
    await tester.pumpAndSettle();
    expect(playback.catalogTracks.map((track) => track.id), ['track-0']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search save toggles once and queues only when newly saved', (
    tester,
  ) async {
    final queue = _Queue();
    await pumpSearchFixture(
      tester,
      size: const Size(390, 1400),
      mornye: true,
      settings: settings.copyWith(
        autoDownloadSavedTracks: true,
        defaultService: 'configured',
      ),
      queue: queue,
      extensions: _Extensions(),
      simulateNoCachedAudio: true,
      // Keep the real lock scoped to this widget test clock.
      retentionLock: CatalogPlayback().withRetentionLock,
    );
    final save = find.byWidgetPredicate(
      (widget) =>
          widget is SaveLibraryTrackButton && widget.track.id == 'track-0',
    );
    expect(save, findsOneWidget);
    final saveButton = find.descendant(
      of: save,
      matching: find.byKey(const ValueKey('save-library-track')),
    );
    await tapSaveToLibrary(tester, plus: saveButton);
    await tester.pumpAndSettle();
    expect(queue.tracks.map((track) => track.id), ['track-0']);
    expect(
      find.descendant(of: save, matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    // Removing goes through the same sheet: the Library row flips off.
    await tapSaveToLibrary(tester, plus: saveButton);
    await tester.pumpAndSettle();
    expect(queue.tracks.length, 1);
    expect(
      find.descendant(
        of: save,
        matching: find.byIcon(Icons.add_circle_outline),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
