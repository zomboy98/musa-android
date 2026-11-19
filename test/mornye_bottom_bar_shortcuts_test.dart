import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';

/// The folded bar shows shortcuts to the two OTHER tabs around the player, and
/// scroll direction folds/unfolds it with hysteresis.
void main() {
  late MornyeChromeController chrome;
  late ScrollController scroll;
  late ValueNotifier<int> active;
  late int pageBuilds;

  setUp(() {
    chrome = MornyeChromeController();
    scroll = ScrollController();
    active = ValueNotifier(0);
    pageBuilds = 0;
  });
  tearDown(() {
    chrome.dispose();
    scroll.dispose();
    active.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    bool disableAnimations = false,
    int rows = 60,
  }) async {
    tester.view.physicalSize = const Size(393, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Built once: the scroll must never rebuild the page.
    final page = Builder(
      builder: (_) {
        pageBuilds++;
        return ListView.builder(
          controller: scroll,
          itemExtent: 60,
          itemCount: rows,
          itemBuilder: (_, index) => Text('Row $index'),
        );
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(
              const MediaItem(id: 'track', title: 'A song', artist: 'Artist'),
            ),
          ),
          playbackStateProvider.overrideWith((ref) => const Stream.empty()),
          lowEndDeviceProvider.overrideWithValue(true),
          backdropBlurEnabledProvider.overrideWithValue(false),
          mornyeLiquidGlassProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: disableAnimations),
            child: child!,
          ),
          home: Scaffold(
            extendBody: true,
            body: NotificationListener<ScrollNotification>(
              onNotification: chrome.handleScroll,
              child: page,
            ),
            bottomNavigationBar: ListenableBuilder(
              listenable: Listenable.merge([chrome, active]),
              builder: (_, _) => MornyeBottomBar(
                collapsed: chrome.value,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home),
                    label: 'Inicio',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search),
                    label: 'Buscar',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.library_music),
                    label: 'Biblioteca',
                  ),
                ],
                searchIndex: 1,
                selectedIndex: active.value,
                onSelected: (index) {
                  active.value = index;
                  chrome.expand();
                },
                onHome: () {
                  active.value = 0;
                  chrome.expand();
                },
                onSearch: () {
                  active.value = 1;
                  chrome.expand();
                },
                onExpand: chrome.expand,
                blurEnabled: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder shortcut(String label) => find.byWidgetPredicate(
    (w) => w is IconButton && w.tooltip == label && w.key != null,
  );

  const names = ['Inicio', 'Buscar', 'Biblioteca'];
  for (final (tab, expected) in [
    (0, ['Buscar', 'Biblioteca']),
    (1, ['Inicio', 'Biblioteca']),
    (2, ['Inicio', 'Buscar']),
  ]) {
    testWidgets('folded in ${names[tab]} shows $expected and not itself', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      active.value = tab;
      await pump(tester);
      chrome.value = true;
      await tester.pumpAndSettle();
      for (final name in names) {
        expect(
          shortcut(name),
          expected.contains(name) ? findsOneWidget : findsNothing,
          reason: '$name while folded in ${names[tab]}',
        );
      }
      // Canonical order, either side of the player; 48 dp minimum targets.
      final first = tester.getCenter(shortcut(expected[0])).dx;
      final second = tester.getCenter(shortcut(expected[1])).dx;
      expect(first, lessThan(second));
      for (final name in expected) {
        final size = tester.getSize(shortcut(name));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      // Semantics label present for assistive tech.
      for (final name in expected) {
        expect(find.bySemanticsLabel(name), findsWidgets);
      }
      handle.dispose();
    });
  }

  testWidgets('tapping a folded shortcut navigates and unfolds', (
    tester,
  ) async {
    await pump(tester);
    chrome.value = true;
    await tester.pumpAndSettle();
    await tester.tap(shortcut('Biblioteca'));
    await tester.pumpAndSettle();
    expect(active.value, 2);
    expect(chrome.value, isFalse);

    chrome.value = true;
    await tester.pumpAndSettle();
    await tester.tap(shortcut('Inicio'));
    await tester.pumpAndSettle();
    expect(active.value, 0);
    expect(chrome.value, isFalse);
  });

  testWidgets('tapping the folded bar background unfolds it', (tester) async {
    await pump(tester);
    chrome.value = true;
    await tester.pumpAndSettle();
    final background = find.byKey(const ValueKey('mornye-compact-background'));
    expect(background, findsOneWidget);
    final box = tester.getRect(background);
    // The bare strip above the 52 dp row, away from player and shortcuts.
    await tester.tapAt(Offset(box.center.dx, box.bottom - 3));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    expect(active.value, 0);
  });

  testWidgets('drag down folds; ~40 dp back up unfolds from any position', (
    tester,
  ) async {
    await pump(tester);
    final list = find.byType(ListView);
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    final offset = scroll.offset;
    expect(offset, greaterThan(100));
    await tester.drag(list, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    // Not at the top: the unfold did not need it.
    expect(scroll.offset, greaterThan(50));
    // And it folds again with another downward drag.
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
  });

  testWidgets('reaching the top unfolds', (tester) async {
    await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -10));
    await tester.drag(find.byType(ListView), const Offset(0, 10));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
  });

  testWidgets('hysteresis: small or alternating moves do not toggle', (
    tester,
  ) async {
    await pump(tester);
    final list = find.byType(ListView);
    scroll.jumpTo(300);
    await tester.pumpAndSettle();
    // Short wobbles in both directions never accumulate to the threshold.
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -20));
      await tester.drag(list, const Offset(0, 20));
    }
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);

    chrome.value = true;
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, 20));
      await tester.drag(list, const Offset(0, -20));
    }
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue);
  });

  testWidgets('short content never folds', (tester) async {
    await pump(tester, rows: 14); // 840 dp: barely scrollable
    final short = scroll.position.maxScrollExtent;
    expect(short, lessThan(MornyeChromeController.minFoldableExtent + 200));
    await tester.pumpWidget(const SizedBox());
    await pump(tester, rows: 12); // 720 dp: fits the viewport
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
  });

  testWidgets('disableAnimations switches state in a single frame', (
    tester,
  ) async {
    await pump(tester, disableAnimations: true);
    chrome.value = true;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(shortcut('Buscar'), findsOneWidget);
    chrome.expand();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the fold animation settles within 220 ms', (tester) async {
    await pump(tester);
    chrome.value = true;
    await tester.pump();
    var elapsed = 0;
    while (tester.hasRunningAnimations && elapsed < 1000) {
      await tester.pump(const Duration(milliseconds: 10));
      elapsed += 10;
    }
    expect(elapsed, lessThanOrEqualTo(220));
  });

  testWidgets('scrolling and folding never rebuild the page', (tester) async {
    await pump(tester);
    final builds = pageBuilds;
    final list = find.byType(ListView);
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(pageBuilds, builds);
  });
}
