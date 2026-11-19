import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';

void main() {
  testWidgets('language sheet builds only the visible rows and still picks', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showLyricsLanguagePicker(
                  context,
                  title: 'Translate Into',
                  selected: '',
                  appDefaultLabel: 'App language',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final total = lyricsTranslationLanguages.length;
    expect(find.text('App language'), findsOneWidget);
    // A long list must not mount every row when the sheet opens.
    final built = tester.widgetList(find.byType(AppSheetOption)).length;
    expect(built, lessThan(total));

    final last = find.byKey(
      ValueKey('lyrics-language-${lyricsTranslationLanguages.last.code}'),
    );
    await tester.scrollUntilVisible(
      last,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(picked, lyricsTranslationLanguages.last.code);
  });
}
