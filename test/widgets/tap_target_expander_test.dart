import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/tap_target_expander.dart';

void main() {
  testWidgets('answers taps in a 44 dp band without growing the layout', (
    tester,
  ) async {
    var taps = 0;
    var rowTaps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => rowTaps++,
            child: SizedBox(
              width: 200,
              height: 80,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TapTargetExpander(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const SizedBox(width: 60, height: 18),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(TapTargetExpander));
    expect(box.height, 18);
    await tester.tapAt(box.center + const Offset(0, 12));
    await tester.tapAt(box.center - const Offset(0, 12));
    expect(taps, 2);
    await tester.tapAt(box.center + const Offset(0, 24));
    expect(taps, 2);
    expect(rowTaps, 1);
    await tester.tapAt(box.center + const Offset(80, 0));
    expect(taps, 2);
  });
}
