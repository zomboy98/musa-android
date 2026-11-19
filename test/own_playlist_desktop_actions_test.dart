import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/widgets/download_progress_icon.dart';

const track = Track(
  id: 'a',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 30,
);

int _completedChecks(WidgetTester tester) => find
    .byType(CustomPaint)
    .evaluate()
    .map((e) => (e.widget as CustomPaint).painter)
    .whereType<DownloadIconPainter>()
    .where((p) => p.phase == DownloadIconPhase.completed)
    .length;

void main() {
  for (final verified in [false, true]) {
    testWidgets('desktop song artist artwork and body activate ($verified)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var activations = 0;
      var selections = 0;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistDownloadedFileProvider(
              track,
            ).overrideWith((ref) async => false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TrackListTable(
                    tracks: const [track],
                    ids: const ['a'],
                    isInHistory: const [true],
                    selectedIds: const {},
                    showArtwork: true,
                    verifiedDownloadedIndicator: verified,
                    onSelect: (_, _, _) => selections++,
                    onActivate: (_) => activations++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.text('Artist').last));
      await tester.pumpAndSettle();
      expect(activations, 1, reason: 'artist');
      DesktopDoubleClick.reset();
      await tester.tap(find.text('Song'));
      await tester.pumpAndSettle();
      expect(activations, 2, reason: 'title');
      DesktopDoubleClick.reset();
      await tester.tapAt(tester.getTopLeft(find.text('Song')) + const Offset(-15, 5));
      await tester.pumpAndSettle();
      expect(activations, 3);
      if (verified)
        expect(find.byIcon(Icons.download_done_rounded), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Song'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(selections, greaterThan(0));
      expect(activations, 3);
    });
  }
  testWidgets('download callback follows the current playlist name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final downloads = <String>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page(String name) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              TrackListTable(
                tracks: const [track],
                ids: const ['a'],
                isInHistory: const [false],
                selectedIds: const {},
                onSelect: (_, _, _) {},
                onActivate: (_) {},
                onDownloadRow: (_) => downloads.add(name),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(page('Old'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(page('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.download_outlined));
    expect(downloads, ['Old', 'New']);
  });

  testWidgets(
    'verified indicator and download action are independent of desktop row activation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var activations = 0;
      var downloads = 0;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistDownloadedFileProvider(
              track,
            ).overrideWith((ref) async => true),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TrackListTable(
                    tracks: const [track],
                    ids: const ['a'],
                    isInHistory: const [true],
                    selectedIds: const {},
                    onSelect: (_, _, _) {},
                    onActivate: (_) => activations++,
                    verifiedDownloadedIndicator: true,
                    rowAction: (_) => IconButton(
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () => downloads++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_completedChecks(tester), 1);
      await tester.tap(find.byIcon(Icons.download_outlined));
      expect(downloads, 1);
      expect(activations, 0);
    },
  );
}
