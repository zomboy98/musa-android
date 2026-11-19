import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/download_progress_icon.dart';

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState();

  void setItems(List<DownloadItem> items) => state = DownloadQueueState(
    items: items,
    lookup: DownloadQueueLookup.fromItems(items),
  );
}

Track _track(String id) => Track(
  id: id,
  name: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
);

DownloadItem _item(
  String id, {
  DownloadStatus status = DownloadStatus.queued,
  double progress = 0,
  int bytesTotal = 0,
}) => DownloadItem(
  id: 'item-$id',
  track: _track(id),
  service: 'svc',
  status: status,
  progress: progress,
  bytesTotal: bytesTotal,
  createdAt: DateTime(2026),
);

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

DownloadIconPainter? _painter(WidgetTester tester) {
  final paints = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter)
      .whereType<DownloadIconPainter>();
  return paints.isEmpty ? null : paints.first;
}

void main() {
  group('resolveDownloadIconPhase', () {
    test('maps queue states to phases', () {
      DownloadIconQueueSnapshot snap(
        DownloadStatus s, {
        double p = 0,
        bool preparing = false,
      }) => (status: s, progress: p, preparing: preparing);

      expect(
        resolveDownloadIconPhase(queue: null).phase,
        DownloadIconPhase.idle,
      );
      expect(
        resolveDownloadIconPhase(queue: snap(DownloadStatus.queued)).phase,
        DownloadIconPhase.queued,
      );
      final half = resolveDownloadIconPhase(
        queue: snap(DownloadStatus.downloading, p: 0.5),
      );
      expect(half.phase, DownloadIconPhase.downloading);
      expect(half.progress, 0.5);
      expect(
        resolveDownloadIconPhase(
          queue: snap(DownloadStatus.downloading, preparing: true),
        ).progress,
        isNull,
      );
      expect(
        resolveDownloadIconPhase(queue: snap(DownloadStatus.finalizing)).phase,
        DownloadIconPhase.finalizing,
      );
      expect(
        resolveDownloadIconPhase(queue: snap(DownloadStatus.completed)).phase,
        DownloadIconPhase.completed,
      );
      expect(
        resolveDownloadIconPhase(queue: snap(DownloadStatus.failed)).phase,
        DownloadIconPhase.failed,
      );
      // Cancelled returns to the initial state.
      expect(
        resolveDownloadIconPhase(queue: snap(DownloadStatus.skipped)).phase,
        DownloadIconPhase.idle,
      );
    });

    test('tap shows queued before the queue knows the item', () {
      expect(
        resolveDownloadIconPhase(queue: null, pending: true).phase,
        DownloadIconPhase.queued,
      );
      // A retry tap wins over a stale failed item.
      expect(
        resolveDownloadIconPhase(
          queue: (status: DownloadStatus.failed, progress: 0, preparing: false),
          pending: true,
        ).phase,
        DownloadIconPhase.queued,
      );
      expect(
        resolveDownloadIconPhase(queue: null, available: true).phase,
        DownloadIconPhase.completed,
      );
      expect(
        resolveDownloadIconPhase(queue: null, failed: true).phase,
        DownloadIconPhase.failed,
      );
    });
  });

  group('DownloadProgressIcon', () {
    Future<void> pumpIcon(
      WidgetTester tester,
      DownloadIconPhase phase, {
      double? progress,
      bool disableAnimations = false,
    }) => tester.pumpWidget(
      _host(
        DownloadProgressIcon(phase: phase, progress: progress),
        disableAnimations: disableAnimations,
      ),
    );

    testWidgets('paints each state and exposes semantics', (tester) async {
      final handle = tester.ensureSemantics();

      await pumpIcon(tester, DownloadIconPhase.idle);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(_painter(tester), isNull);
      expect(find.bySemanticsLabel('Download'), findsOneWidget);

      await pumpIcon(tester, DownloadIconPhase.queued);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_painter(tester), isNull);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.bySemanticsLabel('Queued'), findsOneWidget);

      await pumpIcon(tester, DownloadIconPhase.downloading, progress: 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_painter(tester)!.progress, 0);

      await pumpIcon(tester, DownloadIconPhase.downloading, progress: 0.5);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_painter(tester)!.progress, closeTo(0.5, 1e-6));
      expect(find.bySemanticsLabel('Downloading 50 %'), findsOneWidget);

      await pumpIcon(tester, DownloadIconPhase.downloading, progress: 1);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_painter(tester)!.progress, closeTo(1, 1e-6));

      await pumpIcon(tester, DownloadIconPhase.downloading);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_painter(tester)!.progress, isNull);
      expect(find.bySemanticsLabel('Downloading'), findsOneWidget);

      await pumpIcon(tester, DownloadIconPhase.completed);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_painter(tester)!.phase, DownloadIconPhase.completed);
      expect(find.bySemanticsLabel('Downloaded'), findsOneWidget);

      await pumpIcon(tester, DownloadIconPhase.failed);
      await tester.pump(const Duration(milliseconds: 300));
      final icon = tester.widget<Icon>(find.byIcon(Icons.refresh));
      final scheme = Theme.of(
        tester.element(find.byIcon(Icons.refresh)),
      ).colorScheme;
      expect(icon.color, scheme.error);
      expect(find.bySemanticsLabel('Retry'), findsOneWidget);

      // Cancelled: the idle glyph returns.
      await pumpIcon(tester, DownloadIconPhase.idle);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      handle.dispose();
    });

    testWidgets('interpolates progress between updates', (tester) async {
      await pumpIcon(tester, DownloadIconPhase.downloading, progress: 0.2);
      await tester.pump(const Duration(milliseconds: 600));
      await pumpIcon(tester, DownloadIconPhase.downloading, progress: 0.8);
      await tester.pump(const Duration(milliseconds: 120));
      final mid = _painter(tester)!.progress!;
      expect(mid, greaterThan(0.2));
      expect(mid, lessThan(0.8));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_painter(tester)!.progress, closeTo(0.8, 1e-6));
    });

    testWidgets('loops animate only with animations enabled', (tester) async {
      await pumpIcon(tester, DownloadIconPhase.queued);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);
      await pumpIcon(tester, DownloadIconPhase.finalizing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      await pumpIcon(tester, DownloadIconPhase.idle);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.hasRunningAnimations, isFalse);

      await pumpIcon(tester, DownloadIconPhase.queued, disableAnimations: true);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);
      await pumpIcon(
        tester,
        DownloadIconPhase.downloading,
        disableAnimations: true,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);

      // Fill follows the value directly, no tween.
      await pumpIcon(
        tester,
        DownloadIconPhase.downloading,
        progress: 0.3,
        disableAnimations: true,
      );
      await tester.pump();
      expect(_painter(tester)!.progress, closeTo(0.3, 1e-6));
    });

    for (final seed in const [Colors.teal, Colors.deepOrange]) {
      for (final brightness in Brightness.values) {
        testWidgets('colors come from the theme ($seed, $brightness)', (
          tester,
        ) async {
          final scheme = ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
          );
          Future<void> pump(
            DownloadIconPhase phase, {
            double? progress,
          }) => tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(colorScheme: scheme),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: DownloadProgressIcon(phase: phase, progress: progress),
              ),
            ),
          );

          await pump(DownloadIconPhase.queued);
          await tester.pump(const Duration(milliseconds: 500));
          final queued = tester.widget<Icon>(
            find.byIcon(Icons.download_outlined),
          );
          expect(queued.color, scheme.onSurfaceVariant);
          expect(queued.color, isNot(scheme.primary));
          expect(
            find.descendant(
              of: find.byType(DownloadProgressIcon),
              matching: find.byType(AnimatedBuilder),
            ),
            findsNothing,
          );
          final fade = tester.widget<FadeTransition>(
            find.descendant(
              of: find.byType(DownloadProgressIcon),
              matching: find.byType(FadeTransition),
            ),
          );
          expect(fade.opacity.value, 1.0);
          expect(fade.opacity.status, AnimationStatus.completed);
          expect(
            find
                .byType(CustomPaint)
                .evaluate()
                .where(
                  (e) =>
                      (e.widget as CustomPaint).painter is DownloadIconPainter,
                ),
            isEmpty,
          );
          expect(tester.hasRunningAnimations, isFalse);

          await pump(DownloadIconPhase.downloading, progress: 0.4);
          await tester.pump(const Duration(milliseconds: 600));
          expect(_painter(tester)!.color, scheme.primary);

          await pump(DownloadIconPhase.completed);
          await tester.pump(const Duration(milliseconds: 600));
          expect(_painter(tester)!.color, scheme.primary);
          expect(_painter(tester)!.onColor, scheme.onPrimary);

          await pump(DownloadIconPhase.failed);
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester.widget<Icon>(find.byIcon(Icons.refresh)).color,
            scheme.error,
          );
        });
      }
    }

    testWidgets('keeps a 48 dp touch target inside IconButton', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          IconButton(
            onPressed: () => taps++,
            icon: const DownloadProgressIcon(
              phase: DownloadIconPhase.downloading,
              progress: 0.4,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final size = tester.getSize(find.byType(IconButton));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(find.byType(IconButton));
      expect(taps, 1);
    });
  });

  group('TrackDownloadProgressIcon', () {
    testWidgets('queued rows stay static, only the active one is drawn', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(_Queue.new)],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier) as _Queue;
      queue.setItems([
        _item('a', status: DownloadStatus.downloading, progress: 0.5),
        for (final id in ['b', 'c', 'd', 'e']) _item(id),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _host(
            Column(
              children: [
                for (final id in ['a', 'b', 'c', 'd', 'e'])
                  TrackDownloadProgressIcon(
                    key: ValueKey('icon-$id'),
                    track: _track(id),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('download-icon-queued')),
        findsNWidgets(4),
      );
      expect(
        find.byKey(const ValueKey('download-icon-progress')),
        findsOneWidget,
      );
      expect(tester.hasRunningAnimations, isFalse);

      queue.setItems([
        for (final id in ['b', 'c', 'd', 'e']) _item(id),
      ]);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('download-icon-progress')),
        findsNothing,
      );
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('follows the queue and does not rebuild other rows', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(_Queue.new)],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier) as _Queue;

      final rowBuilds = <String, int>{'a': 0, 'b': 0};
      Widget row(String id) => Builder(
        builder: (context) {
          rowBuilds[id] = rowBuilds[id]! + 1;
          return TrackDownloadProgressIcon(
            key: ValueKey('icon-$id'),
            track: _track(id),
          );
        },
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _host(Column(children: [row('a'), row('b')])),
        ),
      );
      expect(find.byIcon(Icons.download_outlined), findsNWidgets(2));

      DownloadIconPainter? iconPainter(String id) => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byKey(ValueKey('icon-$id')),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((p) => p.painter)
          .whereType<DownloadIconPainter>()
          .firstOrNull;

      queue.setItems([
        _item('a', status: DownloadStatus.queued),
        _item('b', status: DownloadStatus.queued),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(iconPainter('a'), isNull);
      expect(iconPainter('b'), isNull);

      queue.setItems([
        _item('a', status: DownloadStatus.downloading, progress: 0.1),
        _item('b', status: DownloadStatus.completed, progress: 1),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final bPainterBefore = iconPainter('b');
      final buildsBefore = Map.of(rowBuilds);

      for (final p in [0.25, 0.5, 0.75]) {
        queue.setItems([
          _item(
            'a',
            status: DownloadStatus.downloading,
            progress: p,
            bytesTotal: 1000,
          ),
          _item('b', status: DownloadStatus.completed, progress: 1),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(iconPainter('a')!.progress, closeTo(0.75, 1e-6));
      expect(iconPainter('a')!.phase, DownloadIconPhase.downloading);
      // Row widgets (the hosts) never rebuilt, nor did B's icon repaint
      // with a new painter.
      expect(rowBuilds, buildsBefore);
      expect(identical(iconPainter('b'), bPainterBefore), isTrue);

      queue.setItems([
        _item('a', status: DownloadStatus.completed, progress: 1),
        _item('b', status: DownloadStatus.completed, progress: 1),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(iconPainter('a')!.phase, DownloadIconPhase.completed);

      queue.setItems([
        _item('a', status: DownloadStatus.completed, progress: 1),
        _item('b', status: DownloadStatus.failed),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('icon-b')),
          matching: find.byIcon(Icons.refresh),
        ),
        findsOneWidget,
      );

      // Cancel: the queue marks it skipped; b returns to the plain glyph.
      queue.setItems([
        _item('a', status: DownloadStatus.completed, progress: 1),
        _item('b', status: DownloadStatus.skipped),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('icon-b')),
          matching: find.byIcon(Icons.download_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('tap flag shows queued immediately', (tester) async {
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(_Queue.new)],
      );
      addTearDown(container.dispose);
      final pending = ValueNotifier<bool>(false);
      addTearDown(pending.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _host(
            TrackDownloadProgressIcon(track: _track('a'), pending: pending),
          ),
        ),
      );
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      pending.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('download-icon-queued')),
        findsOneWidget,
      );
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
