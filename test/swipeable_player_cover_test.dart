import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/player_gesture_regions.dart';
import 'package:mornye/widgets/player_track_swipe.dart';
import 'package:mornye/widgets/swipeable_player_cover.dart';

void main() {
  final queue = [
    for (var i = 0; i < 3; i++)
      MediaItem(id: '$i', title: 'Song $i', artist: 'Artist $i'),
  ];
  const coverKey = ValueKey('cover');

  Future<List<int>> pumpCover(
    WidgetTester tester, {
    int start = 0,
    bool reduced = false,
  }) async {
    final selected = <int>[];
    var index = start;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: StatefulBuilder(
            builder: (context, setState) => PlayerTrackSwipe(
              queue: queue,
              currentIndex: index,
              onSelected: (item) async {
                selected.add(queue.indexOf(item));
                setState(() => index = queue.indexOf(item));
              },
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 300,
                    height: 300,
                    child: PlayerArtworkDragRegion(
                      child: SwipeablePlayerCover(
                        current: queue[index],
                        neighborBuilder: (context, item) => ColoredBox(
                          color: Colors.blue,
                          child: Text('n:${item.title}'),
                        ),
                        child: ColoredBox(
                          key: coverKey,
                          color: Colors.black,
                          child: Text(queue[index].title),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return selected;
  }

  testWidgets('dragging half the cover left advances once and recentres', (
    tester,
  ) async {
    final selected = await pumpCover(tester);
    final rest = tester.getRect(find.byKey(coverKey));
    final gesture = await tester.startGesture(rest.center);
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    expect(tester.getRect(find.byKey(coverKey)).center.dx, lessThan(rest.left));
    expect(find.text('n:Song 1'), findsOneWidget);
    expect(find.text('n:Song 2'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, [1]);
    expect(find.text('Song 1'), findsOneWidget);
    expect(find.text('n:Song 1'), findsNothing);
    expect(tester.getRect(find.byKey(coverKey)), rest);
  });

  testWidgets('dragging right goes to the previous track', (tester) async {
    final selected = await pumpCover(tester, start: 1);
    final rest = tester.getRect(find.byKey(coverKey));
    final gesture = await tester.startGesture(rest.center);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();
    expect(find.text('n:Song 0'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, [0]);
    expect(tester.getRect(find.byKey(coverKey)), rest);
  });

  testWidgets('a short drag springs back without changing track', (
    tester,
  ) async {
    final selected = await pumpCover(tester);
    final rest = tester.getRect(find.byKey(coverKey));
    final gesture = await tester.startGesture(rest.center);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Song 0'), findsOneWidget);
    expect(tester.getRect(find.byKey(coverKey)), rest);
  });

  testWidgets('a fast fling changes track even over a short distance', (
    tester,
  ) async {
    final selected = await pumpCover(tester);
    await tester.fling(find.byKey(coverKey), const Offset(-60, 0), 1500);
    await tester.pumpAndSettle();
    expect(selected, [1]);
  });

  testWidgets('the last track resists and rebounds without a neighbour', (
    tester,
  ) async {
    final selected = await pumpCover(tester, start: 2);
    final rest = tester.getRect(find.byKey(coverKey));
    final gesture = await tester.startGesture(rest.center);
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    final moved = rest.left - tester.getRect(find.byKey(coverKey)).left;
    expect(moved, greaterThan(0));
    expect(moved, lessThan(200 * 0.3 * 1.3));
    expect(find.textContaining('n:'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(tester.getRect(find.byKey(coverKey)), rest);
  });

  testWidgets('a vertical drag does not change track', (tester) async {
    final selected = await pumpCover(tester);
    await tester.drag(find.byKey(coverKey), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('reduced motion changes directly without moving the cover', (
    tester,
  ) async {
    final selected = await pumpCover(tester, reduced: true);
    final rest = tester.getRect(find.byKey(coverKey));
    final gesture = await tester.startGesture(rest.center);
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    expect(tester.getRect(find.byKey(coverKey)), rest);
    expect(find.text('n:Song 1'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(selected, [1]);
    await tester.pump(const Duration(milliseconds: 130));
    expect(find.text('Song 1'), findsOneWidget);
  });

  testWidgets('semantic actions move to the next and previous track', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final selected = await pumpCover(tester, start: 1);
    final data = tester
        .getSemantics(find.byType(SwipeablePlayerCover))
        .getSemanticsData();
    expect(data.hasAction(SemanticsAction.scrollLeft), isTrue);
    expect(data.hasAction(SemanticsAction.scrollRight), isTrue);
    expect(data.customSemanticsActionIds, hasLength(2));
    tester.semantics.performAction(
      find.semantics.byAction(SemanticsAction.scrollLeft).first,
      SemanticsAction.scrollLeft,
    );
    await tester.pumpAndSettle();
    expect(selected, [2]);
    tester.semantics.performAction(
      find.semantics.byAction(SemanticsAction.scrollRight).first,
      SemanticsAction.scrollRight,
    );
    await tester.pumpAndSettle();
    expect(selected, [2, 1]);
    handle.dispose();
  });
}
