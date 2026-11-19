import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

void main() {
  testWidgets('the sheet surface behind the glass is fully opaque', (
    tester,
  ) async {
    final theme = MornyeTheme.build(Brightness.dark);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppModalBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 120),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final boxes = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.borderRadius != null && d.color != null);
    expect(boxes, isNotEmpty);
    expect(
      boxes.any(
        (d) =>
            d.color!.a == 1 &&
            d.color == theme.colorScheme.surfaceContainerHigh,
      ),
      isTrue,
    );
  });
}
