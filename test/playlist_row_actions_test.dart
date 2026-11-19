import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/widgets/download_progress_icon.dart';

const track = Track(
  id: 'playlist-song',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 120,
);

class _History extends DownloadHistoryNotifier {
  _History(this.item);
  final DownloadHistoryItem? item;

  @override
  DownloadHistoryState build() =>
      DownloadHistoryState(items: item == null ? [] : [item!]);

  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String id) async => item;
  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String isrc) async => item;
  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String name,
    String artist,
  ) async => item;

  @override
  Future<List<DownloadHistoryItem>> findTrackCandidatesAsync(
    HistoryLookupRequest request,
  ) async => item == null ? [] : [item!];
}

class _CandidateHistory extends DownloadHistoryNotifier {
  _CandidateHistory(this.candidates);
  final List<DownloadHistoryItem> candidates;
  @override
  DownloadHistoryState build() => DownloadHistoryState(items: candidates);
  @override
  Future<List<DownloadHistoryItem>> findTrackCandidatesAsync(
    HistoryLookupRequest request,
  ) async => candidates;
}

int _completedChecks(WidgetTester tester) => find
    .byType(CustomPaint)
    .evaluate()
    .map((e) => (e.widget as CustomPaint).painter)
    .whereType<DownloadIconPainter>()
    .where((p) => p.phase == DownloadIconPhase.completed)
    .length;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'older accessible matching copy survives a missing newer candidate',
    () async {
      final dir = await Directory.systemTemp.createTemp('playlist-candidates-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/old.mp3').writeAsBytes([1]);
      DownloadHistoryItem item(String id, String path) => DownloadHistoryItem(
        id: id,
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: path,
        service: 'catalog',
        downloadedAt: DateTime.now(),
      );
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(
            () => _CandidateHistory([
              item('new', '${dir.path}/missing.mp3'),
              item('old', file.path),
            ]),
          ),
          persistentCatalogAudioProvider.overrideWith(
            (ref) =>
                (_) async => false,
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        playlistDownloadedFileProvider(track),
        (_, _) {},
      );
      addTearDown(sub.close);
      expect(
        await container.read(playlistDownloadedFileProvider(track).future),
        isTrue,
      );
    },
  );

  test('only promoted catalog audio is persistent', () async {
    final dir = await Directory.systemTemp.createTemp('playlist-catalog-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${dir.path}/cache'),
      libraryDirectory: Directory('${dir.path}/library'),
    );
    await store.initialize();
    final source = await File('${dir.path}/source.opus').writeAsBytes([1]);
    final key = trackCollectionKey(track);
    await store.putTemporary(key, source);
    expect((await store.lookup(key))?.persistent, isFalse);
    await store.promote(key);
    expect((await store.lookup(key))?.persistent, isTrue);
    expect(await File((await store.lookup(key))!.path).exists(), isTrue);
  });

  test(
    'only an accessible matching history file counts as downloaded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'playlist-status-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/song.mp3');
      final item = DownloadHistoryItem(
        id: 'history',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: file.path,
        service: 'catalog',
        downloadedAt: DateTime.now(),
      );
      Future<bool> check(DownloadHistoryItem? candidate) async {
        final container = ProviderContainer(
          overrides: [
            downloadHistoryProvider.overrideWith(() => _History(candidate)),
            persistentCatalogAudioProvider.overrideWith(
              (ref) =>
                  (_) async => false,
            ),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          playlistDownloadedFileProvider(track),
          (previous, next) {},
        );
        addTearDown(subscription.close);
        return container.read(playlistDownloadedFileProvider(track).future);
      }

      expect(
        await check(null),
        isFalse,
      ); // A saved reference alone has no history file.
      expect(await check(item), isFalse);
      await file.writeAsBytes([1, 2, 3]);
      expect(await check(item), isTrue);
      await file.delete();
      expect(await check(item), isFalse);
    },
  );

  for (final downloaded in [false, true]) {
    testWidgets('playlist download indicator: $downloaded', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistRealDownloadProvider(
              track,
            ).overrideWith((ref) async => downloaded),
            playlistOfflineAudioProvider(
              track,
            ).overrideWith((ref) async => false),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: PlaylistDownloadedIndicator(track: track)),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byIcon(Icons.download_done_rounded),
        downloaded ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets(
    'offline copy is labelled separately and download stays actionable',
    (tester) async {
      var downloads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistRealDownloadProvider(
              track,
            ).overrideWith((ref) async => false),
            playlistOfflineAudioProvider(
              track,
            ).overrideWith((ref) async => true),
          ],
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: TrackListTile(
                track: track,
                isInHistory: false,
                clickableArtist: false,
                playlistActions: true,
                leading: const Icon(Icons.music_note),
                onActivate: () {},
                onDownload: ({forceQualityPicker = false}) => downloads++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byTooltip('Disponible sin conexión • Descargar');
      expect(button, findsOneWidget);
      expect(_completedChecks(tester), 1);
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      await tester.tap(button);
      expect(downloads, 1);
    },
  );

  testWidgets('row plays and direct download invokes only its callback', (
    tester,
  ) async {
    var played = 0;
    var downloads = 0;
    var fileChecks = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playlistRealDownloadProvider(track).overrideWith((ref) async {
            fileChecks++;
            return false;
          }),
          playlistOfflineAudioProvider(track).overrideWith((ref) async => false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TrackListTile(
              track: track,
              isInHistory: false,
              clickableArtist: false,
              playlistActions: true,
              leading: const Icon(Icons.music_note),
              onActivate: () => played++,
              onDownload: ({forceQualityPicker = false}) => downloads++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fileChecks, greaterThan(0));
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    expect(find.byType(TrackCollectionQuickActions), findsOneWidget);
    await tester.tap(find.text('Artist'));
    expect(played, 1);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    expect(played, 1);
    await tester.tap(find.byType(TrackCollectionQuickActions));
    await tester.pumpAndSettle();
    expect(
      find.text(
        tester.element(find.byType(Scaffold).first).l10n.dialogDownload,
      ),
      findsOneWidget,
    );
    expect(downloads, 1);
    expect(played, 1);
  });
}
