import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/downloadable_cover.dart';

void main() {
  testWidgets('a cover is announced by its title, not as a download', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: DownloadableCover(
              coverUrl: 'https://example.com/cover.jpg',
              baseName: 'Grupo Frontera - No Te Detengas',
              child: SizedBox(width: 80, height: 80),
            ),
          ),
        ),
      ),
    );

    final data = tester
        .getSemantics(find.byType(DownloadableCover))
        .getSemanticsData();
    expect(data.label, 'Grupo Frontera - No Te Detengas');
    expect(data.label, isNot(contains('Descargar')));
    handle.dispose();
  });
}
