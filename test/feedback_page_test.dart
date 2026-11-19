import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/screens/feedback_page.dart';
import 'package:mornye/services/feedback/feedback_diagnostics.dart';
import 'package:mornye/services/feedback/feedback_services.dart';
import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:mornye/services/feedback/feedback_token_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late FeedbackStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('musa_feedback_ui');
    store = FeedbackStore(root: () async => Directory(p.join(temp.path, 'fb')));
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      return;
    }
  });

  FeedbackServices services({
    FeedbackImagePicker? pick,
    FeedbackImagePreparer? prepare,
  }) => FeedbackServices(
    store: store,
    prepareImage: prepare,
    tokenStore: MemoryFeedbackTokenStore(),
    pickImages:
        pick ??
        () async => [
          FeedbackImage(name: 'x.png', bytes: Uint8List.fromList([1, 2, 3])),
        ],
    captureScreen: () async => Uint8List.fromList([9]),
    loadDiagnostics: (_) async => const FeedbackDiagnostics(
      appVersion: '1',
      build: '2',
      commit: '',
      device: 'Pixel',
      system: 'Android',
      locale: 'es',
      quality: '',
      provider: '',
      log: [],
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(finder);
    await tester.pump();
  }

  Widget app(
    FeedbackServices s, {
    double scale = 1,
    Future<Uint8List?>? shot,
  }) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: FeedbackPage(services: s, pendingScreenshot: shot),
  );

  testWidgets('creates a report with a screenshot and changes its status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = services();
    await tester.pumpWidget(
      app(s, scale: 2, shot: Future.value(Uint8List.fromList([9]))),
    );
    await settle(tester);
    expect(find.text('Comentarios y reportes'), findsOneWidget);
    expect(find.text('Capturar esta pantalla'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'Se corta la cancion');
    await reveal(tester, find.text('Adjuntar capturas'));
    expect(find.byKey(const ValueKey('feedback-draft-0')), findsOneWidget);
    await reveal(tester, find.text('Adjuntar capturas'));
    await tester.tap(find.text('Adjuntar capturas'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-draft-1')), findsOneWidget);

    await reveal(tester, find.text('Guardar reporte'));
    await tester.tap(find.text('Guardar reporte'));
    for (var i = 0; i < 60; i++) {
      await settle(tester);
    }

    final threads = await tester.runAsync(store.list);
    expect(threads, hasLength(1));
    expect(threads!.single.attachments, hasLength(2));
    expect(threads.single.diagnostics, contains('Pixel'));

    final card = find.byKey(ValueKey('feedback-thread-${threads.single.id}'));
    await reveal(
      tester,
      find.byKey(ValueKey('feedback-thread-${threads.single.id}')),
    );
    await tester.tap(card);
    await settle(tester);
    final reviewing = find.text('En revisión').last;
    await reveal(tester, reviewing);
    await tester.tap(reviewing);
    for (var i = 0; i < 10; i++) {
      await settle(tester);
    }
    final updated = await tester.runAsync(store.list);
    expect(updated!.single.status, FeedbackStatus.reviewing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery photos show progress and are replaced by the result', (
    tester,
  ) async {
    final gate = Completer<FeedbackImage?>();
    final s = services(
      pick: () async => [
        FeedbackImage(name: 'foto.jpg', path: p.join(temp.path, 'foto.jpg')),
      ],
      prepare: (_) => gate.future,
    );
    await tester.pumpWidget(app(s));
    await settle(tester);
    await reveal(tester, find.text('Adjuntar capturas'));
    await tester.tap(find.text('Adjuntar capturas'));
    await tester.pump();
    await tester.pump();
    await reveal(tester, find.byKey(const ValueKey('feedback-draft-0')));
    expect(find.byKey(const ValueKey('feedback-draft-0')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await reveal(tester, find.text('Guardar reporte'));
    final save = tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(save.onPressed, isNull);
    gate.complete(
      FeedbackImage(name: 'foto.png', bytes: Uint8List.fromList([1])),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.byKey(const ValueKey('feedback-draft-0'), skipOffstage: false),
      findsOneWidget,
    );
    final ready = tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(ready.onPressed, isNotNull);
  });

  testWidgets('a photo that cannot be prepared is dropped with a message', (
    tester,
  ) async {
    final s = services(
      pick: () async => [
        FeedbackImage(name: 'foto.jpg', path: p.join(temp.path, 'foto.jpg')),
      ],
      prepare: (_) async => null,
    );
    await tester.pumpWidget(app(s));
    await settle(tester);
    await reveal(tester, find.text('Adjuntar capturas'));
    await tester.tap(find.text('Adjuntar capturas'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-draft-0')), findsNothing);
    expect(
      find.text('No se pudo preparar una imagen. No se adjuntó.'),
      findsOneWidget,
    );
  });

  testWidgets('empty text shows an error and nothing is saved', (tester) async {
    final s = services();
    await tester.pumpWidget(app(s));
    await settle(tester);
    await reveal(tester, find.text('Guardar reporte'));
    await tester.tap(find.text('Guardar reporte'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pump();
    expect(
      find.text('Escribe una descripción para guardar el reporte.'),
      findsOneWidget,
    );
    final threads = await tester.runAsync(store.list);
    expect(threads, isEmpty);
  });
}
