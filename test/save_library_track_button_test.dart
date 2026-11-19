// Test doubles expose captured calls and gates for assertions.
// ignore_for_file: avoid_public_notifier_properties

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'support/add_to_music_helpers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/widgets/download_progress_icon.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

/// Whether the download button currently paints the "available" check.
bool _showsDownloadedCheck(WidgetTester tester) => find
    .descendant(
      of: find.byKey(const ValueKey('download-library-track')),
      matching: find.byType(CustomPaint),
    )
    .evaluate()
    .map((e) => (e.widget as CustomPaint).painter)
    .whereType<DownloadIconPainter>()
    .any((p) => p.phase == DownloadIconPhase.completed);

Future<T> _unlocked<T>(Future<T> Function() action) => action();

class _Queue extends DownloadQueueNotifier {
  final services = <String>[];
  final tracks = <Track>[];
  bool fail = false;

  @override
  Future<String?> addCurrentSavedTrackToQueue(
    Track track,
    String service,
    bool Function() isCurrent,
  ) => addSavedTrackToQueue(track, service);

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) async {
    return addToQueue(track, service);
  }

  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) {
    if (fail) throw StateError('queue unavailable');
    services.add(service);
    tracks.add(track);
    return 'queued';
  }
}

class _DelayedSaved extends SavedLibraryTracksNotifier {
  final pending = Completer<bool>();
  Track? added;
  @override
  Future<List<Track>> build() async => [];
  @override
  Future<({bool added, bool promoted, Object? retentionError})>
  addWithRetention(Track track) async {
    added = track;
    final committed = await pending.future;
    final promoted = committed
        ? await ref.read(promoteSavedCatalogAudioProvider)(track)
        : false;
    return (added: committed, promoted: promoted, retentionError: null);
  }
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.available);
  final bool available;

  @override
  ExtensionState build() => ExtensionState(
    extensions: available
        ? [
            Extension.fromJson({
              'id': 'configured',
              'enabled': true,
              'has_download_provider': true,
            }),
          ]
        : [],
  );
}

void main() {
  const track = Track(
    id: 'saved',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 120,
    source: 'catalog',
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> mount(
    WidgetTester tester,
    _Queue queue, {
    bool enabled = true,
    bool available = true,
    String defaultService = 'configured',
    bool autoFallback = true,
    bool menu = false,
    _DelayedSaved? delayed,
    Future<bool> Function(Track)? promote,
    Future<bool>? Function(Track)? pending,
    bool downloaded = false,
    bool downloadFailed = false,
    CatalogAudioStore? store,
    VoidCallback? onDownload,
  }) async {
    final container = ProviderContainer(
      overrides: [
        playlistRealDownloadProvider(
          track,
        ).overrideWith((ref) async => downloaded),
        if (store == null)
          persistentCatalogAudioProvider.overrideWithValue((_) async => false)
        else
          catalogAudioStoreProvider.overrideWithValue(Future.value(store)),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(
              autoDownloadSavedTracks: enabled,
              defaultService: defaultService,
              autoFallback: autoFallback,
            ),
          ),
        ),
        extensionProvider.overrideWith(() => _Extensions(available)),
        downloadQueueProvider.overrideWith(() => queue),
        savedCatalogRetentionLockProvider.overrideWithValue(_unlocked),
        promoteSavedCatalogAudioProvider.overrideWithValue(
          promote ?? (_) async => false,
        ),
        pendingSavedCatalogPromotionProvider.overrideWithValue(
          pending ?? (_) => null,
        ),
        if (delayed != null)
          savedLibraryTracksProvider.overrideWith(() => delayed),
      ],
    );
    addTearDown(container.dispose);
    await container.read(savedLibraryTracksProvider.future);
    if (store != null) {
      await tester.runAsync(() async {
        final subscription = container.listen(
          playlistOfflineAudioProvider(track),
          (_, _) {},
        );
        addTearDown(subscription.close);
        await container.read(playlistOfflineAudioProvider(track).future);
      });
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: menu
                ? Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () =>
                          TrackCollectionQuickActions.showTrackOptionsSheet(
                            context,
                            ref,
                            track,
                          ),
                      child: const Text('Open options'),
                    ),
                  )
                : SaveLibraryTrackButton(
                    track: track,
                    onDownload: onDownload,
                    downloadFailed: downloadFailed,
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'download button invokes only its own action on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var downloads = 0;
      final queue = _Queue();
      final container = await mount(
        tester,
        queue,
        enabled: false,
        onDownload: () => downloads++,
      );
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('download-library-track')));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(await container.read(savedLibraryTracksProvider.future), isEmpty);
      expect(queue.tracks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final replaceTrack in [false, true]) {
    testWidgets(
      replaceTrack
          ? 'delayed save enqueues original track after widget track changes'
          : 'delayed save enqueues after button is unmounted',
      (tester) async {
        final queue = _Queue();
        final saved = _DelayedSaved();
        final container = await mount(tester, queue, delayed: saved);
        await tapSaveToLibrary(tester);
        expect(saved.added, track);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: replaceTrack
                    ? const SaveLibraryTrackButton(
                        track: Track(
                          id: 'other',
                          name: 'Other',
                          artistName: 'Artist',
                          albumName: 'Album',
                          duration: 100,
                        ),
                      )
                    : const SizedBox(),
              ),
            ),
          ),
        );
        saved.pending.complete(true);
        await tester.pumpAndSettle();
        expect(queue.tracks, [track]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'saving queues configured provider; tapping saved opens options without removal',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final queue = _Queue();
      final container = await mount(tester, queue);
      await tapSaveToLibrary(tester);
      await tester.pumpAndSettle();
      expect(queue.services, ['configured']);
      expect(
        (await container.read(savedLibraryTracksProvider.future)).length,
        1,
      );
      final context = tester.element(find.byType(Scaffold));
      final label =
          '${context.l10n.libraryInLibrary} • ${MaterialLocalizations.of(context).showMenuTooltip}';
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('save-library-track')))
            .tooltip,
        label,
      );
      semantics.dispose();
      await tapSaveThenCancel(tester);
      expect(queue.services, ['configured']);
      expect(
        (await container.read(savedLibraryTracksProvider.future)).length,
        1,
      );
      // The sheet closed with Cancel: nothing was removed.
      expect(find.byKey(const ValueKey('add-to-music-library')), findsNothing);
    },
  );

  testWidgets('disabled automatic downloads only save references', (
    tester,
  ) async {
    final queue = _Queue();
    final container = await mount(tester, queue, enabled: false);
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(queue.services, isEmpty);
    expect((await container.read(savedLibraryTracksProvider.future)).length, 1);
  });

  testWidgets('downloaded file and library membership remain independent', (
    tester,
  ) async {
    final queue = _Queue();
    final container = await mount(
      tester,
      queue,
      enabled: false,
      downloaded: true,
    );
    expect(_showsDownloadedCheck(tester), isTrue);
    final downloadedLabel = tester
        .element(find.byType(Scaffold))
        .l10n
        .trackRemoveFromDevice;
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            (widget.tooltip?.contains(downloadedLabel) ?? false),
      ),
      findsOneWidget,
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    expect(_showsDownloadedCheck(tester), isTrue);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tapSaveThenCancel(tester);
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    expect(queue.tracks, isEmpty);
  });

  testWidgets('accessible download takes precedence over an old failure', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, _Queue(), downloaded: true, downloadFailed: true);
    final finder = find.byKey(const ValueKey('download-library-track'));
    final button = tester.widget<IconButton>(finder);
    expect(_showsDownloadedCheck(tester), isTrue);
    expect(button.onPressed, isNotNull);
    final tooltip = tester.getSemantics(finder).tooltip;
    semantics.dispose();
    expect(
      tooltip,
      tester.element(find.byType(Scaffold)).l10n.trackRemoveFromDevice,
    );
  });

  testWidgets('failed download with no accessible file offers retry', (
    tester,
  ) async {
    var retries = 0;
    await mount(
      tester,
      _Queue(),
      downloadFailed: true,
      onDownload: () => retries++,
    );
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-library-track')));
    expect(retries, 1);
  });

  for (final state in ['retained', 'temporary', 'missing']) {
    testWidgets('$state catalog audio exposes the correct download action', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final store = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('musa-offline-');
        addTearDown(() => root.delete(recursive: true));
        final store = CatalogAudioStore(
          cacheDirectory: Directory('${root.path}/cache'),
          libraryDirectory: Directory('${root.path}/library'),
        );
        await store.initialize();
        final source = await File('${root.path}/source').writeAsString('audio');
        final key = catalogPlayback.key(track);
        await store.putTemporary(key, source, extension: '.m4a');
        if (state != 'temporary') {
          final retained = await store.promote(key);
          if (state == 'missing') await File(retained!.path).delete();
        }
        return store;
      });
      expect(store, isNotNull);
      final queue = _Queue();
      await mount(tester, queue, store: store);
      final finder = find.byKey(const ValueKey('download-library-track'));
      final l10n = tester.element(find.byType(Scaffold)).l10n;
      final retained = state == 'retained';
      expect(_showsDownloadedCheck(tester), retained);
      if (!retained) {
        expect(
          find.descendant(
            of: finder,
            matching: find.byIcon(Icons.download_outlined),
          ),
          findsOneWidget,
        );
      }
      final tooltip = tester.getSemantics(finder).tooltip;
      semantics.dispose();
      expect(
        tooltip,
        retained ? l10n.trackRemoveFromDevice : l10n.dialogDownload,
      );
      if (retained) return;
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(queue.tracks, [track]);
      expect(queue.services, ['configured']);
    });
  }

  testWidgets('promoted audio still queues the automatic download', (
    tester,
  ) async {
    final queue = _Queue();
    final promoted = <Track>[];
    final container = await mount(
      tester,
      queue,
      promote: (track) async {
        promoted.add(track);
        return true;
      },
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(promoted, [track]);
    expect(queue.tracks, [track]);
    expect((await container.read(savedLibraryTracksProvider.future)).length, 1);
    await tapSaveThenCancel(tester);
    expect(promoted, [track]);
  });

  for (final scenario in ['success', 'failure-auto', 'failure-manual']) {
    testWidgets('pending preparation $scenario preserves saved reference', (
      tester,
    ) async {
      final queue = _Queue();
      final preparation = Completer<bool>();
      final container = await mount(
        tester,
        queue,
        enabled: scenario != 'failure-manual',
        pending: (_) => preparation.future,
      );
      await tapSaveToLibrary(tester);
      await tester.pumpAndSettle();
      expect(await container.read(savedLibraryTracksProvider.future), [track]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SavedLibraryTracksNotifier.storageKey), isNotNull);
      expect(queue.tracks, isEmpty);

      preparation.complete(scenario == 'success');
      await tester.pumpAndSettle();
      expect(await container.read(savedLibraryTracksProvider.future), [track]);
      expect(queue.tracks, scenario == 'failure-manual' ? isEmpty : [track]);
      final l10n = tester.element(find.byType(Scaffold)).l10n;
      expect(
        find.text(l10n.savedTrackRetentionError),
        scenario == 'failure-manual' ? findsOneWidget : findsNothing,
      );
    });
  }

  for (final menu in [false, true]) {
    for (final readd in [false, true]) {
      testWidgets('pending save removed readd=$readd menu=$menu', (
        tester,
      ) async {
        final queue = _Queue();
        final preparation = Completer<bool>();
        final container = await mount(
          tester,
          queue,
          menu: menu,
          pending: (_) => preparation.future,
        );
        if (menu) {
          await tester.tap(find.text('Open options'));
          await tester.pumpAndSettle();
          final l10n = tester.element(find.byType(Scaffold).first).l10n;
          await tester.tap(find.text(l10n.addToMusicTitle));
          await confirmLibraryInSheet(tester);
        } else {
          await tapSaveToLibrary(tester);
        }
        await tester.pumpAndSettle();
        final notifier = container.read(savedLibraryTracksProvider.notifier);
        expect(await container.read(savedLibraryTracksProvider.future), [
          track,
        ]);
        final originalIntention = notifier.currentSaveIntention(track);
        await notifier.remove(track);
        Future<({bool added, bool promoted, Object? retentionError})>? second;
        if (readd) {
          second = notifier.addWithRetention(track);
          await tester.pumpAndSettle();
        }
        preparation.complete(false);
        if (second != null) expect((await second).added, isTrue);
        expect(originalIntention(), isFalse);
        if (readd) expect(notifier.currentSaveIntention(track)(), isTrue);
        await tester.pumpAndSettle();
        expect(queue.tracks, isEmpty);
        expect(
          await container.read(savedLibraryTracksProvider.future),
          readd ? [track] : isEmpty,
        );
      });
    }
  }

  testWidgets('restoring empty backup invalidates pending save', (
    tester,
  ) async {
    final queue = _Queue();
    final preparation = Completer<bool>();
    final container = await mount(
      tester,
      queue,
      pending: (_) => preparation.future,
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    await container
        .read(savedLibraryTracksProvider.notifier)
        .restoreFromBackup([]);
    preparation.complete(false);
    await tester.pumpAndSettle();
    expect(queue.tracks, isEmpty);
  });

  testWidgets('restoring identical backup invalidates pending save', (
    tester,
  ) async {
    final queue = _Queue();
    final preparation = Completer<bool>();
    final container = await mount(
      tester,
      queue,
      pending: (_) => preparation.future,
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    final original = notifier.currentSaveIntention(track);
    await notifier.restoreFromBackup([track]);
    preparation.complete(false);
    await tester.pumpAndSettle();
    expect(original(), isFalse);
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    expect(queue.tracks, isEmpty);
  });

  testWidgets('second UI save queues once after removing pending save', (
    tester,
  ) async {
    final queue = _Queue();
    final preparation = Completer<bool>();
    final container = await mount(
      tester,
      queue,
      menu: true,
      pending: (_) => preparation.future,
    );
    Future<void> saveFromMenu() async {
      await tester.tap(find.text('Open options'));
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(Scaffold).first).l10n;
      await tester.tap(find.text(l10n.addToMusicTitle));
      await confirmLibraryInSheet(tester);
      await tester.pumpAndSettle();
    }

    await saveFromMenu();
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    await notifier.remove(track);
    await tester.pumpAndSettle();
    await saveFromMenu();
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    preparation.complete(false);
    await tester.pumpAndSettle();
    expect(queue.tracks, [track]);
  });

  testWidgets('promotion failure reports the error and preserves reference', (
    tester,
  ) async {
    final queue = _Queue();
    final container = await mount(
      tester,
      queue,
      promote: (_) async {
        throw StateError('copy failed');
      },
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(queue.tracks, [track]);
    expect((await container.read(savedLibraryTracksProvider.future)).length, 1);
    final l10n = tester.element(find.byType(Scaffold)).l10n;
    expect(find.text(l10n.savedTrackRetentionError), findsOneWidget);
    expect(find.text(l10n.savedTrackAutoDownloadError), findsNothing);
  });

  testWidgets('retention failure with auto download disabled is reported', (
    tester,
  ) async {
    final queue = _Queue();
    final container = await mount(
      tester,
      queue,
      enabled: false,
      promote: (_) async => throw StateError('copy failed'),
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(queue.tracks, isEmpty);
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    final l10n = tester.element(find.byType(Scaffold)).l10n;
    expect(find.text(l10n.savedTrackRetentionError), findsOneWidget);
    expect(find.text(l10n.savedTrackAutoDownloadError), findsNothing);
  });

  testWidgets('missing provider preserves saved reference', (tester) async {
    final queue = _Queue();
    final container = await mount(tester, queue, available: false);
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(queue.services, isEmpty);
    expect((await container.read(savedLibraryTracksProvider.future)).length, 1);
    final l10n = tester.element(find.byType(Scaffold)).l10n;
    expect(find.text(l10n.savedTrackAutoDownloadError), findsOneWidget);
  });

  for (final autoFallback in [false, true]) {
    testWidgets(
      'unavailable selected provider respects fallback $autoFallback',
      (tester) async {
        final queue = _Queue();
        final container = await mount(
          tester,
          queue,
          defaultService: 'missing',
          autoFallback: autoFallback,
        );
        await tapSaveToLibrary(tester);
        await tester.pumpAndSettle();
        expect(await container.read(savedLibraryTracksProvider.future), [
          track,
        ]);
        expect(queue.services, autoFallback ? ['configured'] : isEmpty);
        final l10n = tester.element(find.byType(Scaffold)).l10n;
        expect(
          find.text(l10n.savedTrackAutoDownloadError),
          autoFallback ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  for (final scenario in ['no fallback', 'fallback', 'queue failure']) {
    testWidgets('options menu saves with $scenario', (tester) async {
      final queue = _Queue()..fail = scenario == 'queue failure';
      final container = await mount(
        tester,
        queue,
        menu: true,
        defaultService: scenario == 'queue failure' ? 'configured' : 'missing',
        autoFallback: scenario == 'fallback',
      );
      await tester.tap(find.text('Open options'));
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(Scaffold).first).l10n;
      await tester.tap(find.text(l10n.addToMusicTitle));
      await confirmLibraryInSheet(tester);
      await tester.pumpAndSettle();
      expect(await container.read(savedLibraryTracksProvider.future), [track]);
      expect(queue.services, scenario == 'fallback' ? ['configured'] : isEmpty);
      expect(
        find.text(l10n.savedTrackAutoDownloadError),
        scenario == 'fallback' ? findsNothing : findsOneWidget,
      );
      expect(find.text(l10n.savedCatalogTracksError), findsNothing);
    });
  }

  testWidgets(
    'enqueue failure reports separately and preserves saved reference',
    (tester) async {
      final queue = _Queue()..fail = true;
      final container = await mount(tester, queue);
      await tapSaveToLibrary(tester);
      await tester.pumpAndSettle();
      expect(
        (await container.read(savedLibraryTracksProvider.future)).length,
        1,
      );
      final l10n = tester.element(find.byType(Scaffold)).l10n;
      expect(find.text(l10n.savedTrackAutoDownloadError), findsOneWidget);
      expect(find.text(l10n.savedCatalogTracksError), findsNothing);
    },
  );

  testWidgets('queue failure leaves promoted audio and reference intact', (
    tester,
  ) async {
    final queue = _Queue()..fail = true;
    var promotedAudioExists = false;
    final container = await mount(
      tester,
      queue,
      promote: (_) async {
        promotedAudioExists = true;
        return true;
      },
    );
    await tapSaveToLibrary(tester);
    await tester.pumpAndSettle();
    expect(promotedAudioExists, isTrue);
    expect(await container.read(savedLibraryTracksProvider.future), [track]);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final l10n = tester.element(find.byType(Scaffold)).l10n;
    expect(find.text(l10n.savedTrackAutoDownloadError), findsOneWidget);
  });
}
