import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/widgets/decorative_phase.dart';

import 'support/app_icon_finder.dart';

void main() {
  // El reloj decorativo a vsync nunca termina y estas pruebas esperan con
  // pumpAndSettle: se mantiene quieto durante la prueba.
  setUp(() => DecorativePhase.debugHoldClock = true);
  tearDown(() => DecorativePhase.debugHoldClock = false);
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final (scenario, service, id) in [
    ('Deezer identity with fallback downloader', 'tidal', 'deezer:123'),
    (
      'Spotify identity with fallback downloader',
      'deezer',
      '0123456789abcdefghijkl',
    ),
    ('namespaced Tidal identity', 'tidal', 'tidal:123'),
    ('namespaced Qobuz identity', 'qobuz', 'qobuz:123'),
    // The backend accepts bare numbers as Deezer IDs. History's download
    // service cannot disambiguate the catalog, so the picker preserves them.
    ('legacy numeric identity without service', '', '123'),
    ('legacy numeric identity with ambiguous downloader', 'tidal', '123'),
    ('local track without catalog identity', 'local', ''),
  ]) {
    testWidgets('manual lyrics picker forwards $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const path = 'content://library/document/manual-lyrics.flac';
      const lyrics = '[00:01.00]Selected lyric line';
      final requests = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'safStat':
            return jsonEncode({'exists': true, 'size': 100});
          case 'readFileMetadata':
            return jsonEncode({
              'title': 'Current title',
              'artist': 'Current artist',
              'duration': 126,
            });
          case 'readAudioMetadata':
          case 'getSafFileModTimes':
            return '{}';
          case 'getLyricsLRCWithSource':
            return jsonEncode({'lyrics': ''});
          case 'getEnabledLyricsProviders':
            return jsonEncode(['deezer', 'lrclib']);
          case 'getLyricsFromProvider':
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            requests.add(args);
            return jsonEncode({
              'lyrics': args['provider'] == 'lrclib' ? lyrics : '',
              'sync_type': 'LINE_SYNCED',
            });
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(
              item: service == 'local'
                  ? null
                  : DownloadHistoryItem(
                      id: 'history-track',
                      trackName: 'History title',
                      artistName: 'History artist',
                      albumName: 'Album',
                      filePath: path,
                      service: service,
                      spotifyId: id,
                      duration: 98,
                      downloadedAt: DateTime(2026),
                    ),
              localItem: service == 'local'
                  ? LocalLibraryItem(
                      id: 'local-file-id',
                      trackName: 'Scanned title',
                      artistName: 'Scanned artist',
                      albumName: 'Album',
                      filePath: path,
                      duration: 98,
                      scannedAt: DateTime(2026),
                    )
                  : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(findAppIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit Metadata'));
      final title = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText && widget.controller.text == 'Current title',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Edit Metadata'));
        for (var i = 0; i < 100 && title.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump(const Duration(milliseconds: 500));
      expect(title, findsOneWidget);
      await tester.enterText(title, 'Edited title');
      final findLyrics = find.byKey(const ValueKey('find-lyrics-online'));
      await tester.ensureVisible(findLyrics);
      await tester.tap(findLyrics);
      await tester.pumpAndSettle();

      expect(
        requests,
        unorderedEquals([
          for (final provider in ['deezer', 'lrclib'])
            {
              'provider': provider,
              'spotify_id': id,
              'track_name': 'Edited title',
              'artist_name': 'Current artist',
              'duration_ms': 126000,
            },
        ]),
      );
      await tester.tap(find.text('Selected lyric line'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is EditableText && widget.controller.text == lyrics,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
