import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';

void main() {
  const safeTop = 40.0;
  const header = 56.0;

  Future<void> pumpHome(
    WidgetTester tester, {
    required bool reducedMotion,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: safeTop),
            disableAnimations: reducedMotion,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: AppRefreshIndicator(
            edgeOffset: safeTop,
            headerExtent: header,
            onRefresh: () => Future<void>.delayed(const Duration(milliseconds: 900)),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const SliverAppBar(
                  pinned: true,
                  toolbarHeight: header,
                  title: Text('Inicio'),
                ),
                SliverList.builder(
                  itemCount: 20,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text('fila $i')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void expectNothingAboveSafeArea(WidgetTester tester) {
    for (final positioned in tester.widgetList<Positioned>(
      find.byType(Positioned),
    )) {
      expect(positioned.top ?? 0, greaterThanOrEqualTo(0));
    }
  }

  testWidgets('reduced motion: one spinner, below the header, title intact', (
    tester,
  ) async {
    await pumpHome(tester, reducedMotion: true);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.text('Inicio'), findsOneWidget);
    final spinner = tester.getRect(find.byType(RefreshProgressIndicator));
    expect(spinner.top, greaterThanOrEqualTo(safeTop + header));
    final title = tester.getRect(find.text('Inicio'));
    expect(spinner.top, greaterThanOrEqualTo(title.bottom));
    expectNothingAboveSafeArea(tester);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('expressive: one indicator, content starts below the inset', (
    tester,
  ) async {
    await pumpHome(tester, reducedMotion: false);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.text('Inicio'), findsOneWidget);
    expect(
      tester.getRect(find.text('Inicio')).top,
      greaterThanOrEqualTo(safeTop),
    );
    expectNothingAboveSafeArea(tester);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });
}
