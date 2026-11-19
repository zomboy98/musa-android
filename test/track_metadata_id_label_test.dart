import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';

class _History extends DownloadHistoryNotifier {
  _History(this._item);
  final DownloadHistoryItem _item;

  @override
  DownloadHistoryState build() => DownloadHistoryState(items: [_item]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> pumpScreen(
    WidgetTester tester, {
    required String id,
    required String service,
    Locale locale = const Locale('en'),
  }) async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'safStat' => jsonEncode({'exists': true, 'size': 100}),
        'readAudioMetadata' => jsonEncode({}),
        'readFileMetadata' => jsonEncode({'audio_codec': 'flac'}),
        'getLyricsLRCWithSource' => jsonEncode({'lyrics': '', 'source': ''}),
        'getSafFileModTimes' => '{}',
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final item = DownloadHistoryItem(
      id: 'track-1',
      trackName: 'Track',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: 'content://library/document/track-1.flac',
      service: service,
      downloadedAt: DateTime(2026),
      spotifyId: id,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadHistoryProvider.overrideWith(() => _History(item))],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TrackMetadataScreen(item: item),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an Amazon ASIN shows an Amazon label and no Spotify button', (
    tester,
  ) async {
    await pumpScreen(tester, id: 'B0HCWPPR8N', service: 'tidal-web');
    await tester.scrollUntilVisible(
      find.text('B0HCWPPR8N'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Amazon Music ID'), findsOneWidget);
    expect(find.text('Spotify ID'), findsNothing);
    expect(find.text('Open in Spotify'), findsNothing);
    expect(find.text('Open in Amazon Music'), findsOneWidget);
    expect(find.text('Catalog source'), findsOneWidget);
    expect(find.text('Amazon Music'), findsOneWidget);
    expect(find.text('Audio service'), findsOneWidget);
    expect(find.text('TIDAL-WEB'), findsWidgets);
  });

  testWidgets('a real Spotify id shows Spotify ID and its button', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      id: '4uLU6hMCjMI75M1A2tKUQC',
      service: 'tidal-web',
    );
    await tester.scrollUntilVisible(
      find.text('4uLU6hMCjMI75M1A2tKUQC'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Spotify ID'), findsOneWidget);
    expect(find.text('Open in Spotify'), findsOneWidget);
  });

  testWidgets('an unrecognised id gets a neutral label and no button', (
    tester,
  ) async {
    await pumpScreen(tester, id: '123456', service: 'tidal-web');
    await tester.scrollUntilVisible(
      find.text('123456'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Track ID'), findsOneWidget);
    expect(find.text('Spotify ID'), findsNothing);
    expect(find.textContaining('Open in'), findsNothing);
    expect(find.text('Catalog source'), findsNothing);
    expect(find.text('Audio service'), findsOneWidget);
  });

  testWidgets('Spanish neutral id label', (tester) async {
    await pumpScreen(
      tester,
      id: '123456',
      service: 'tidal-web',
      locale: const Locale('es'),
    );
    expect(find.text('ID de pista'), findsOneWidget);
  });
}
