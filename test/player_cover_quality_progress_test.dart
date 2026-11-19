import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/player_cover_quality.dart';

void main() {
  test('the estimate starts at zero and never reaches the ceiling', () {
    expect(estimatedQualityProgress(Duration.zero, slow: true), 0);
    for (final slow in [true, false]) {
      final end = estimatedQualityProgress(qualitySwitchTimeout, slow: slow);
      expect(end, lessThan(0.95));
    }
  });

  test('the estimate keeps moving for the whole allowed time', () {
    for (final slow in [true, false]) {
      var previous = -1.0;
      for (
        var seconds = 0;
        seconds <= qualitySwitchTimeout.inSeconds;
        seconds += 5
      ) {
        final value = estimatedQualityProgress(
          Duration(seconds: seconds),
          slow: slow,
        );
        expect(value, greaterThan(previous));
        previous = value;
      }
    }
  });

  test(
    'a long hi-res transfer is not shown as nearly done after ten seconds',
    () {
      expect(
        estimatedQualityProgress(const Duration(seconds: 10), slow: true),
        lessThan(0.6),
      );
      expect(
        estimatedQualityProgress(const Duration(seconds: 60), slow: true),
        greaterThan(
          estimatedQualityProgress(const Duration(seconds: 10), slow: true),
        ),
      );
    },
  );

  test('a stalled switch ends on its own within a bounded time', () {
    expect(qualitySwitchTimeout, lessThanOrEqualTo(const Duration(minutes: 3)));
    expect(qualitySwitchTimeout, greaterThan(const Duration(seconds: 30)));
  });
}
