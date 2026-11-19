import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/widgets/mornye_level_slider.dart';

void main() {
  tearDown(() => debugAndroidTvOverride = null);

  Future<void> pumpSlider(
    WidgetTester tester, {
    bool vertical = false,
    bool enabled = true,
    double initialValue = 0,
    required ValueChanged<double> onChanged,
  }) async {
    var value = initialValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Center(
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: MornyeLevelSlider(
                    value: value,
                    min: -1,
                    max: 1,
                    step: 0.5,
                    vertical: vertical,
                    semanticLabel: 'Gain',
                    semanticFormatterCallback: (v) => '$v dB',
                    onChanged: enabled
                        ? (next) {
                            setState(() => value = next);
                            onChanged(next);
                          }
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  for (final tv in [false, true]) {
    for (final vertical in [false, true]) {
      testWidgets(
        'Tab and arrows adjust ${vertical ? 'vertical' : 'horizontal'} slider on ${tv ? 'TV' : 'non-TV'}',
        (tester) async {
          debugAndroidTvOverride = tv;
          final values = <double>[];
          await pumpSlider(tester, vertical: vertical, onChanged: values.add);
          await tester.sendKeyEvent(
            vertical
                ? LogicalKeyboardKey.arrowUp
                : LogicalKeyboardKey.arrowRight,
          );
          expect(values, isEmpty);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await tester.sendKeyEvent(
            vertical
                ? LogicalKeyboardKey.arrowUp
                : LogicalKeyboardKey.arrowRight,
          );
          await tester.pump();
          expect(values, [0.5]);
          await tester.sendKeyEvent(
            vertical
                ? LogicalKeyboardKey.arrowDown
                : LogicalKeyboardKey.arrowLeft,
          );
          await tester.pump();
          expect(values, [0.5, 0]);
        },
      );
    }
  }

  testWidgets('keyboard clamps gain at both limits', (tester) async {
    debugAndroidTvOverride = false;
    final values = <double>[];
    await pumpSlider(tester, initialValue: 1, onChanged: values.add);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(values.last, 1);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }
    expect(values.last, -1);
    expect(values.every((v) => v >= -1 && v <= 1), isTrue);
  });

  testWidgets('keyboard focus shows a border and blur removes it', (
    tester,
  ) async {
    await pumpSlider(tester, onChanged: (_) {});
    final borders = find.descendant(
      of: find.byType(MornyeLevelSlider),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border != null,
      ),
    );
    expect(borders, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(borders, findsOneWidget);
    await tester.tap(
      find.byType(MornyeLevelSlider),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(borders, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(borders, findsOneWidget);
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pumpAndSettle();
    expect(borders, findsNothing);
  });

  testWidgets(
    'disabled slider skips keyboard and exposes no adjustment actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final values = <double>[];
      await pumpSlider(tester, enabled: false, onChanged: values.add);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.tap(find.byType(MornyeLevelSlider));
      await tester.pump();
      expect(values, isEmpty);
      final node = tester.getSemantics(find.byType(MornyeLevelSlider));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isFalse,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isFalse,
      );
      semantics.dispose();
    },
  );

  testWidgets('screen reader adjustments preserve label and formatted gain', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final values = <double>[];
    await pumpSlider(tester, onChanged: values.add);
    var node = tester.getSemantics(find.byType(MornyeLevelSlider));
    expect(node.label, 'Gain');
    expect(node.value, '0.0 dB');
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(values, [0.5]);
    node = tester.getSemantics(find.byType(MornyeLevelSlider));
    expect(node.value, '0.5 dB');
    node.owner!.performAction(node.id, SemanticsAction.decrease);
    await tester.pump();
    expect(values, [0.5, 0]);
    semantics.dispose();
  });
}
