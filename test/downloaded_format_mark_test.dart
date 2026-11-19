import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/widgets/downloaded_format_mark.dart';
import 'package:mornye/widgets/track_list_tile.dart';

DownloadHistoryItem _item({
  String? format,
  String? quality,
  int? bitDepth,
  int? sampleRate,
  int? bitrate,
  String path = '/music/song',
}) => DownloadHistoryItem(
  id: 'id',
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: path,
  service: 'example',
  downloadedAt: DateTime.utc(2026, 11, 15),
  format: format,
  quality: quality,
  bitDepth: bitDepth,
  sampleRate: sampleRate,
  bitrate: bitrate,
);

Widget _app(Widget child, {double scale = 1}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('es'),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('formato real del archivo descargado', () {
    test('FLAC 16/44.1 es FLAC', () {
      final f = DownloadedFormat.fromHistory(
        _item(format: 'flac', bitDepth: 16, sampleRate: 44100),
      );
      expect(f.mark?.name, 'flac');
    });

    test('FLAC 24/48 es HI-RES', () {
      final f = DownloadedFormat.fromHistory(
        _item(format: 'flac', bitDepth: 24, sampleRate: 48000),
      );
      expect(f.mark?.name, 'hiRes');
    });

    test('AAC es AAC y nunca ATMOS sin codec Dolby', () {
      final f = DownloadedFormat.fromHistory(
        _item(format: 'aac', quality: 'ATMOS', bitrate: 256),
      );
      expect(f.mark?.name, 'aac');
    });

    test('Dolby E-AC-3 si es ATMOS', () {
      final f = DownloadedFormat.fromHistory(_item(format: 'eac3'));
      expect(f.mark?.name, 'atmos');
    });

    test('sin datos usa la extension y sin nada es neutra', () {
      expect(
        DownloadedFormat.fromHistory(_item(path: '/a/b.mp3')).mark?.name,
        'mp3',
      );
      expect(DownloadedFormat.fromHistory(_item()).mark, isNull);
    });
  });

  group('marca', () {
    for (final (format, label, key) in [
      (
        DownloadedFormat.fromFile(
          filePath: 'a.flac',
          format: 'flac',
          bitDepth: 16,
          sampleRate: 44100,
        ),
        'FLAC',
        'flac',
      ),
      (
        DownloadedFormat.fromFile(
          filePath: 'a.flac',
          format: 'flac',
          bitDepth: 24,
          sampleRate: 48000,
        ),
        'HI-RES',
        'hiRes',
      ),
      (
        DownloadedFormat.fromFile(filePath: 'a.m4a', format: 'aac'),
        'AAC',
        'aac',
      ),
    ]) {
      testWidgets('muestra $label con semantica Descargada en', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_app(DownloadedFormatMark(format: format)));
        expect(find.text(label), findsOneWidget);
        expect(
          find.byKey(ValueKey('downloaded-format-mark-$key')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Descargada · $label'), findsOneWidget);
        expect(find.byIcon(Icons.folder_outlined), findsNothing);
        handle.dispose();
      });
    }

    testWidgets('sin datos muestra Descargada neutra', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(const DownloadedFormatMark(format: DownloadedFormat.neutral)),
      );
      expect(
        find.byKey(const ValueKey('downloaded-format-mark-neutral')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Descargada'), findsOneWidget);
      expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      handle.dispose();
    });
  });

  group('fila de pista', () {
    const track = Track(
      id: 'track-1',
      name:
          'Una cancion con un titulo extremadamente largo que no cabe en la fila',
      artistName: 'Un artista con un nombre igualmente largo y explicito',
      albumName: 'Album',
      duration: 180,
      trackNumber: 1,
      explicit: true,
    );

    Widget row({required bool downloaded, DownloadedFormat? format}) =>
        ProviderScope(
          overrides: [
            trackDownloadedFormatProvider(track).overrideWithValue(format),
          ],
          child: TrackListTile(
            track: track,
            isInHistory: downloaded,
            clickableArtist: false,
            onDownload: ({bool forceQualityPicker = false}) {},
            leading: const SizedBox(width: 32, child: Text('1')),
          ),
        );

    Future<double> heightOf(
      WidgetTester tester, {
      required bool downloaded,
      DownloadedFormat? format,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(row(downloaded: downloaded, format: format), scale: 1.3),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(TrackListTile)).height;
    }

    testWidgets('la marca no cambia la altura ni usa carpeta', (tester) async {
      final plain = await heightOf(tester, downloaded: false);
      expect(find.byType(DownloadedFormatMark), findsNothing);
      final flac = await heightOf(
        tester,
        downloaded: true,
        format: DownloadedFormat.fromFile(
          filePath: 'a.flac',
          format: 'flac',
          bitDepth: 16,
          sampleRate: 44100,
        ),
      );
      expect(find.text('FLAC'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      expect(find.byIcon(Icons.folder), findsNothing);
      expect(flac, plain);
      final neutral = await heightOf(tester, downloaded: true);
      expect(
        find.byKey(const ValueKey('downloaded-format-mark-neutral')),
        findsOneWidget,
      );
      expect(neutral, plain);
      expect(tester.takeException(), isNull);
    });
  });
}
