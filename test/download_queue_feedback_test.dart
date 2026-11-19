import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/widgets/download_queue_feedback.dart';
import 'package:mornye/widgets/queue_selection_persistence_notice.dart';

class _Queue extends DownloadQueueNotifier {
  int _retryCalls = 0;
  bool? _retriedNetworkOnly;
  int _selectionRetryCalls = 0;
  bool _selectionRetryFails = false;
  int _nativeRetryCalls = 0;

  @override
  DownloadQueueState build() => const DownloadQueueState();

  void reconnect(int count) => state = state.copyWith(
    reconnectRetry: DownloadQueueReconnectRetry(count),
  );

  void progressSnapshot() => state = state.copyWith(isProcessing: true);

  void retryFailure() => state = state.copyWith(manualRetryFailure: Object());

  void blockSelection() =>
      state = state.copyWith(selectionPersistenceBlocked: true);

  void blockNativeRecovery() =>
      state = state.copyWith(nativeRecoveryRequired: true);

  @override
  void resumeQueue() {
    _nativeRetryCalls++;
    state = state.copyWith(nativeRecoveryRequired: false);
  }

  @override
  Future<void> retrySelectionPersistence() async {
    _selectionRetryCalls++;
    if (!_selectionRetryFails) {
      state = state.copyWith(selectionPersistenceBlocked: false);
    }
  }

  @override
  Future<void> retryAllFailed({bool networkOnly = false}) async {
    _retryCalls++;
    _retriedNetworkOnly = networkOnly;
  }
}

Widget _app(
  ProviderContainer container, {
  Key? feedbackKey,
  Locale locale = const Locale('en'),
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: DownloadQueueFeedback(
      key: feedbackKey,
      child: const Scaffold(body: Text('Queue')),
    ),
  ),
);

void main() {
  testWidgets('selection persistence failure offers a retry from the shell', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, locale: const Locale('es', 'MX')));
    queue.blockSelection();
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo guardar la selección. Reinténtalo para continuar.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(queue._selectionRetryCalls, 1);
    expect(
      container.read(downloadQueueProvider).selectionPersistenceBlocked,
      isFalse,
    );
  });

  testWidgets('selection persistence notice remains available after remount', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    queue.blockSelection();
    Widget noticeApp() => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: QueueSelectionPersistenceNotice()),
      ),
    );
    await tester.pumpWidget(noticeApp());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(noticeApp());
    expect(
      find.text('Could not save the selection. Retry to continue.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(queue._selectionRetryCalls, 1);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('selection failure while backgrounded is shown on resume', (
    tester,
  ) async {
    final queue = _Queue().._selectionRetryFails = true;
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    queue.blockSelection();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save the selection. Retry to continue.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(queue._selectionRetryCalls, 1);
    expect(
      container.read(downloadQueueProvider).selectionPersistenceBlocked,
      isTrue,
    );
  });

  testWidgets('native recovery is visible after returning to foreground', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, locale: const Locale('es')));
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    queue.blockNativeRecovery();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No se pudo confirmar el estado de la descarga. Reintenta para recuperar la cola.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(queue._nativeRetryCalls, 1);
    expect(
      container.read(downloadQueueProvider).nativeRecoveryRequired,
      isFalse,
    );
  });

  testWidgets('an existing selection failure is shown when the shell mounts', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    queue.blockSelection();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save the selection. Retry to continue.'),
      findsOneWidget,
    );
  });

  testWidgets('recovery notices take priority over unrelated queue messages', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    queue.blockNativeRecovery();
    queue.blockSelection();
    queue.reconnect(3);
    queue.retryFailure();
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save the selection. Retry to continue.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not confirm the download state. Retry to recover the queue.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('manual retry failure is localized for Latin American Spanish', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, locale: const Locale('es', 'MX')));
    queue.retryFailure();
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo reintentar la descarga. Inténtalo de nuevo.'),
      findsOneWidget,
    );
  });

  testWidgets('manual retry failure shows a fresh message each time', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    queue.retryFailure();
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    expect(find.text(l10n.queueRetryPreparationFailed), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    queue.retryFailure();
    await tester.pumpAndSettle();
    expect(find.text(l10n.queueRetryPreparationFailed), findsOneWidget);
  });
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  testWidgets(
    'reconnect retry counts never show a failure notice or retry action',
    (tester) async {
      final queue = _Queue();
      final container = ProviderContainer(
        overrides: [downloadQueueProvider.overrideWith(() => queue)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(Scaffold)).l10n;
      for (final count in [1, 2, 3]) {
        queue.reconnect(count);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text(l10n.queueNetworkFailedOffline(count)), findsNothing);
        expect(find.text(l10n.dialogRetry), findsNothing);
      }
      queue.progressSnapshot();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(queue._retryCalls, 0);
      expect(queue._retriedNetworkOnly, isNull);
    },
  );

  testWidgets('remounting with a reconnect retry never shows a notice', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    container.read(downloadQueueProvider);
    queue.reconnect(2);
    expect(
      container.read(downloadQueueProvider).reconnectRetry!.failedCount,
      2,
    );
    await tester.pumpWidget(
      _app(container, feedbackKey: const ValueKey('first')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    queue.reconnect(3);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(
      _app(container, feedbackKey: const ValueKey('second')),
    );
    await tester.pumpAndSettle();
    queue.progressSnapshot();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnect retries while backgrounded never show a notice', (
    tester,
  ) async {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => queue)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    queue.reconnect(2);
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    queue.progressSnapshot();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    queue.reconnect(3);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
