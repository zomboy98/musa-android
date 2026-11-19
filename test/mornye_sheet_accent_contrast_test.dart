import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

double contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance() + 0.05;
  final b = background.computeLuminance() + 0.05;
  return a > b ? a / b : b / a;
}

Color panelFill(Element child) {
  Color? fill;
  child.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is DecoratedBox && widget.decoration is BoxDecoration) {
      final color = (widget.decoration as BoxDecoration).color;
      if (color != null) {
        fill = color;
        return false;
      }
    }
    return true;
  });
  return fill!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'locale': 'en'}));

  testWidgets('tonal outlined action contrasts with its fill over the sheet', (
    tester,
  ) async {
    final theme = MornyeTheme.build(
      Brightness.dark,
      customAccent: Colors.black,
      glassClarity: 0,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppBottomSheet<void>(
                  context: context,
                  builder: (_) => AppActionButton(
                    outlined: true,
                    tonal: true,
                    onPressed: () {},
                    icon: const Icon(Icons.add),
                    label: const Text('Sheet action'),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(seconds: 1));
    final action = find.byType(AppActionButton);
    final button = tester.widget<CupertinoButton>(
      find.descendant(of: action, matching: find.byType(CupertinoButton)),
    );
    final background = Color.alphaBlend(
      button.color!,
      panelFill(tester.element(action)),
    );
    final label = tester.element(find.text('Sheet action'));
    expect(
      contrast(DefaultTextStyle.of(label).style.color!, background),
      greaterThanOrEqualTo(4.5),
    );
    final icon = tester.element(
      find.descendant(of: action, matching: find.byType(Icon)),
    );
    expect(
      contrast(IconTheme.of(icon).color!, background),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final (brightness, clarity) in [
    (Brightness.dark, 0.0),
    (Brightness.light, 0.75),
  ]) {
    testWidgets(
      'selected language contrasts on the blue preset panel ($brightness, $clarity)',
      (tester) async {
        final theme = MornyeTheme.build(brightness, glassClarity: clarity);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mornyeGlassLevelProvider.overrideWithValue(
                MornyeGlassLevel.frosted,
              ),
            ],
            child: MaterialApp(
              locale: const Locale('en'),
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const AppearanceSettingsPage(),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        final language = find.widgetWithText(ListTile, 'App Language');
        await tester.scrollUntilVisible(
          language,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(language), alignment: .5);
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(language);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(AppSheetOption), findsWidgets);
        final option = tester
            .widgetList<AppSheetOption>(find.byType(AppSheetOption))
            .singleWhere((option) => option.selected == true);
        final label = option.title as Text;
        final fill = panelFill(tester.element(find.byWidget(option)));
        expect(fill.a, clarity == 0 ? 1 : lessThan(1));
        final background = Color.alphaBlend(fill, Colors.black);
        expect(
          contrast(label.style!.color!, background),
          greaterThanOrEqualTo(4.5),
        );
        final trailing = option.trailing! as DecoratedBox;
        final checkBackground = (trailing.decoration as BoxDecoration).color!;
        final check = tester.widget<Icon>(
          find.descendant(
            of: find.byWidget(trailing),
            matching: find.byType(Icon),
          ),
        );
        expect(checkBackground, theme.colorScheme.primary);
        expect(
          contrast(check.color!, checkBackground),
          greaterThanOrEqualTo(3),
        );
        expect(
          contrast((option.leading! as AppIcon).color!, background),
          greaterThanOrEqualTo(4.5),
        );
      },
    );
  }
}
