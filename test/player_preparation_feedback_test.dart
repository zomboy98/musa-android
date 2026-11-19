import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';

CatalogPreparation _prep(DateTime started, {String quality = 'opus_160'}) =>
    CatalogPreparation(
      key: 'k',
      service: 'ytmusic',
      quality: quality,
      started: started,
    );

Widget _host(
  ValueNotifier<CatalogPreparation?> source, {
  bool reduce = false,
  VoidCallback? onRetry,
  VoidCallback? onCancel,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
      child: Scaffold(
        body: ValueListenableBuilder<CatalogPreparation?>(
          valueListenable: source,
          builder: (context, prep, _) => prep == null
              ? const SizedBox.shrink()
              : PreparationFeedback(
                  preparation: prep,
                  onRetry: onRetry ?? () {},
                  onCancel: onCancel ?? () {},
                ),
        ),
      ),
    ),
  ),
);

const _slow = 'Preparando… tarda más de lo normal';
const _trying = 'Probando otro formato o proveedor…';

void main() {
  testWidgets('the three notes appear in order and go with the preparation', (
    tester,
  ) async {
    final started = DateTime.now();
    final source = ValueNotifier<CatalogPreparation?>(_prep(started));
    var retried = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      _host(source, onRetry: () => retried++, onCancel: () => cancelled++),
    );
    await tester.pump(const Duration(seconds: 7));
    expect(find.text(_slow), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_slow), findsOneWidget);
    expect(find.byKey(const ValueKey('preparation-retry')), findsNothing);

    source.value = _prep(started, quality: 'HIGH');
    await tester.pump();
    source.value = _prep(started, quality: 'LOW');
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_trying), findsOneWidget);
    expect(find.text(_slow), findsNothing);
    expect(find.byKey(const ValueKey('preparation-retry')), findsNothing);

    await tester.pump(const Duration(seconds: 26));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('preparation-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preparation-retry')));
    await tester.tap(find.byKey(const ValueKey('preparation-cancel')));
    expect(retried, 1);
    expect(cancelled, 1);

    source.value = null;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PreparationFeedback), findsNothing);
    expect(find.text(_trying), findsNothing);
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('without a relay the slow note stays until the buttons come', (
    tester,
  ) async {
    final source = ValueNotifier<CatalogPreparation?>(_prep(DateTime.now()));
    await tester.pumpWidget(_host(source));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text(_slow), findsOneWidget);
    expect(find.text(_trying), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_slow), findsOneWidget);
    expect(find.byKey(const ValueKey('preparation-cancel')), findsOneWidget);
    source.value = null;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_slow), findsNothing);
  });

  testWidgets('the slow note is announced and changes at once without motion', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final source = ValueNotifier<CatalogPreparation?>(_prep(DateTime.now()));
    await tester.pumpWidget(_host(source, reduce: true));
    await tester.pump(const Duration(seconds: 8));
    expect(
      find.bySemanticsLabel('Preparando, tarda más de lo normal'),
      findsOneWidget,
    );
    expect(find.byType(AnimatedSwitcher), findsOneWidget);
    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
      Duration.zero,
    );
    semantics.dispose();
  });

  testWidgets('a new song restarts the clock', (tester) async {
    final source = ValueNotifier<CatalogPreparation?>(_prep(DateTime.now()));
    await tester.pumpWidget(_host(source));
    await tester.pump(const Duration(seconds: 10));
    expect(find.text(_slow), findsOneWidget);
    source.value = CatalogPreparation(
      key: 'other',
      service: 'ytmusic',
      quality: 'opus_160',
      started: DateTime.now().add(const Duration(seconds: 1)),
    );
    await tester.pump();
    expect(find.text(_slow), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text(_slow), findsOneWidget);
    source.value = null;
    await tester.pump(const Duration(milliseconds: 300));
  });
}
