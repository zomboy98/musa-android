import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/player_video_sync.dart';

Duration _ms(int value) => Duration(milliseconds: value);

void main() {
  test('evaluates at most every 500 ms', () {
    final governor = PlayerVideoSyncGovernor();
    expect(governor.due(_ms(0)), isTrue);
    expect(governor.due(_ms(200)), isFalse);
    expect(governor.due(_ms(499)), isFalse);
    expect(governor.due(_ms(500)), isTrue);
    var due = 0;
    for (var t = 500; t <= 10500; t += 200) {
      if (governor.due(_ms(t))) due++;
    }
    expect(due, lessThanOrEqualTo(20));
  });

  test('stays quiet inside the deadband', () {
    final governor = PlayerVideoSyncGovernor();
    for (var i = 0; i < 100; i++) {
      final drift = (i.isEven ? 1 : -1) * 110;
      expect(
        governor.correction(
          now: _ms(i * 500),
          video: _ms(10000 + drift),
          audio: const Duration(seconds: 10),
        ),
        PlayerVideoCorrection.none,
      );
    }
    expect(governor.corrections, 0);
  });

  test('corrections respect a 2 s cooldown and never exceed 30 per minute', () {
    final governor = PlayerVideoSyncGovernor();
    var seeks = 0;
    for (var t = 0; t < 60000; t += 100) {
      final action = governor.correction(
        now: _ms(t),
        video: const Duration(seconds: 5),
        audio: const Duration(seconds: 10),
      );
      if (action == PlayerVideoCorrection.seek) seeks++;
    }
    expect(seeks, 30);
    expect(governor.corrections, 30);
    final single = PlayerVideoSyncGovernor();
    expect(
      single.correction(
        now: _ms(0),
        video: _ms(0),
        audio: const Duration(seconds: 1),
      ),
      PlayerVideoCorrection.seek,
    );
    expect(
      single.correction(
        now: _ms(1999),
        video: _ms(0),
        audio: const Duration(seconds: 1),
      ),
      PlayerVideoCorrection.none,
    );
    expect(
      single.correction(
        now: _ms(2000),
        video: _ms(0),
        audio: const Duration(seconds: 1),
      ),
      PlayerVideoCorrection.seek,
    );
  });

  test('never corrects past the end of the clip', () {
    final governor = PlayerVideoSyncGovernor();
    expect(
      governor.correction(
        now: _ms(0),
        video: const Duration(seconds: 30),
        audio: const Duration(seconds: 40),
        duration: const Duration(seconds: 30),
      ),
      PlayerVideoCorrection.none,
    );
  });

  test('summary reports corrections per minute and stalls', () {
    final governor = PlayerVideoSyncGovernor();
    for (var i = 0; i < 61; i++) {
      final now = _ms(i * 500);
      if (!governor.due(now)) continue;
      governor.observe(
        now: now,
        video: _ms(i * 500 ~/ 2),
        audio: _ms(i * 500),
        playing: true,
      );
    }
    final line = governor.summary(const Duration(seconds: 31));
    expect(line, isNotNull);
    expect(line, contains('video: sync'));
    expect(line, contains('stalls=60'));
    expect(governor.summary(const Duration(seconds: 32)), isNull);
  });
}
