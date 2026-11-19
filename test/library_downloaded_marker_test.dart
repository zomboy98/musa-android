import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

import 'support/library_home_fixture.dart';

final _saved = libraryTrack('catalog-id', name: 'Mar Azul', artist: 'Cano');
final _other = libraryTrack('other-id', name: 'Other', artist: 'Someone');

class _HistoryWithFile extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      DownloadHistoryItem(
        id: 'history-id',
        trackName: 'Mar Azul',
        artistName: 'Cano',
        albumName: 'Album',
        filePath: '/music/mar-azul.flac',
        service: 'example',
        downloadedAt: DateTime.utc(2026, 11, 13),
      ),
    ],
    totalCount: 1,
  );
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: libraryHomeOverrides(
        favorites: [favoriteEntry(_saved)],
        history: _HistoryWithFile.new,
      ),
      child: MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: home),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a saved song with a downloaded file is marked in the song list '
      'and its menu offers no download', (tester) async {
    seedSavedTracks([_saved, _other]);
    await _pump(tester, MornyeLibraryScreen(onOpenSection: (_) {}));
    await tester.tap(find.byKey(const ValueKey('library-filter-songs')));
    await tester.pumpAndSettle();

    final marker = find.byKey(
      ValueKey('library-downloaded-${trackCollectionKey(_saved)}'),
    );
    expect(marker, findsOneWidget);
    expect(
      find.descendant(
        of: marker,
        matching: find.byKey(const ValueKey('downloaded-format-mark-flac')),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
    expect(
      find.byKey(ValueKey('library-downloaded-${trackCollectionKey(_other)}')),
      findsNothing,
    );

    final row = find.byKey(
      ValueKey('library-entry-song:${trackCollectionKey(_saved)}'),
    );
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.byType(TrackCollectionQuickActions),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Downloaded'), findsWidgets);
    expect(find.text('Download'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a track menu detects the downloaded file on its own', (
    tester,
  ) async {
    await _pump(tester, TrackCollectionQuickActions(track: _saved));
    await tester.tap(find.byType(TrackCollectionQuickActions));
    await tester.pumpAndSettle();
    expect(find.text('Downloaded'), findsWidgets);
    expect(find.text('Download'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a track without a file still offers the download', (
    tester,
  ) async {
    await _pump(tester, TrackCollectionQuickActions(track: _other));
    await tester.tap(find.byType(TrackCollectionQuickActions));
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsWidgets);
    expect(find.text('Downloaded'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
