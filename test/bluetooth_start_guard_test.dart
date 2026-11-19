import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/bluetooth_start_guard.dart';

class _FakePlatform implements BluetoothStartPlatform {
  _FakePlatform({this.bluetooth = true, this.hang = false});

  bool bluetooth;
  final bool hang;
  final silences = <Duration>[];
  final keepAlive = <bool>[];
  bool nativeAccepts = true;
  int routeReads = 0;

  @override
  Future<bool> routedToBluetooth() {
    routeReads++;
    if (hang) return Completer<bool>().future;
    return Future.value(bluetooth);
  }

  @override
  Future<bool> playSilence(Duration length) {
    silences.add(length);
    if (hang) return Completer<bool>().future;
    return Future.value(true);
  }

  @override
  Future<bool> setKeepAlive(bool enabled, Duration limit) {
    keepAlive.add(enabled);
    return Future.value(!enabled || nativeAccepts);
  }
}

class _Harness {
  _Harness({
    bool bluetooth = true,
    bool hang = false,
    Duration keepAliveLimit = const Duration(seconds: 60),
  }) : platform = _FakePlatform(bluetooth: bluetooth, hang: hang) {
    guard = BluetoothStartGuard(
      platform: platform,
      clock: () => now,
      wait: (duration) async => now = now.add(duration),
      callBudget: Duration(milliseconds: hang ? 5 : 60),
      keepAliveDelay: const Duration(milliseconds: 20),
      keepAliveLimit: keepAliveLimit,
      keepAliveRefresh: const Duration(milliseconds: 30),
      trace: lines.add,
    );
  }

  final _FakePlatform platform;
  late final BluetoothStartGuard guard;
  final lines = <String>[];
  DateTime now = DateTime(2026, 11, 15, 12);

  void advance(Duration duration) => now = now.add(duration);
}

void main() {
  test('wakes a Bluetooth output that has never played or sat idle', () async {
    final harness = _Harness();
    final delay = await harness.guard.beforeStart('a');
    expect(harness.platform.silences, [const Duration(milliseconds: 250)]);
    expect(delay, const Duration(milliseconds: 250));
    expect(harness.lines.single, contains('bt-guard: start deck=a'));
    expect(harness.lines.single, contains('route=bluetooth'));
    expect(harness.lines.single, contains('idle=unknown'));
    expect(harness.lines.single, contains('silence=250ms'));
  });

  test('emits silence once the idle time reaches the threshold', () async {
    final harness = _Harness();
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    harness.advance(const Duration(milliseconds: 2500));
    await harness.guard.beforeStart('b');
    expect(harness.platform.silences, hasLength(1));
    expect(
      harness.lines.where((line) => line.contains('bt-guard: start')).single,
      contains('idle=2500ms'),
    );
  });

  test('does nothing between consecutive songs', () async {
    final harness = _Harness();
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    harness.advance(const Duration(milliseconds: 2499));
    final delay = await harness.guard.beforeStart('b');
    expect(delay, Duration.zero);
    expect(harness.platform.silences, isEmpty);
    expect(
      harness.lines.where((line) => line.contains('bt-guard: start')),
      isEmpty,
    );
  });

  test('does nothing while another deck is still audible', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    harness.advance(const Duration(minutes: 5));
    await harness.guard.beforeStart('b');
    expect(harness.platform.silences, isEmpty);
  });

  test('does nothing on speaker, USB or wired outputs', () async {
    final harness = _Harness(bluetooth: false);
    final delay = await harness.guard.beforeStart('a');
    expect(delay, Duration.zero);
    expect(harness.platform.silences, isEmpty);
    expect(harness.lines.single, contains('route=other'));
    expect(harness.lines.single, contains('silence=none'));
  });

  test('turned off, it neither reads the route nor plays silence', () async {
    final harness = _Harness()..guard.enabled = false;
    await harness.guard.beforeStart('a');
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(harness.platform.routeReads, 0);
    expect(harness.platform.silences, isEmpty);
    expect(harness.platform.keepAlive, isEmpty);
  });

  test('a stalled platform never delays the start past 400 ms', () async {
    final harness = _Harness(hang: true);
    final delay = await harness.guard.beforeStart('a');
    expect(delay, lessThanOrEqualTo(BluetoothStartGuard.maxStartDelay));
    expect(harness.platform.silences, isEmpty);
  });

  test('the default budget stays within 400 ms', () async {
    final harness = _Harness();
    final delay = await harness.guard.beforeStart('a');
    expect(delay, lessThanOrEqualTo(BluetoothStartGuard.maxStartDelay));
    expect(
      () => BluetoothStartGuard(silence: const Duration(milliseconds: 390)),
      throwsA(isA<AssertionError>()),
    );
  });

  Future<void> settle([int ms = 80]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('keeps the link awake while music plays and across tracks', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    await settle();
    expect(harness.platform.keepAlive.first, isTrue);
    expect(harness.guard.keepAliveActive, isTrue);
    harness.guard
      ..audioStopped('a')
      ..audioStarted('b');
    await settle();
    harness.advance(const Duration(minutes: 5));
    expect(harness.platform.keepAlive.where((on) => !on), isEmpty);
    expect(harness.guard.keepAliveActive, isTrue);
    expect(
      harness.lines.where((line) => line.contains('keep-alive on')),
      hasLength(1),
    );
    expect(harness.lines.first, contains('reason=playing'));
    final delay = await harness.guard.beforeStart('b');
    expect(delay, Duration.zero);
    expect(harness.platform.silences, isEmpty);
    harness.guard.dispose();
  });

  test('re-arms the native limit while it runs', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    await settle(150);
    expect(harness.platform.keepAlive.where((on) => on).length, greaterThan(1));
    expect(harness.guard.keepAliveActive, isTrue);
    harness.guard.dispose();
  });

  test('releases the link after the grace period following a pause', () async {
    final harness = _Harness(keepAliveLimit: const Duration(milliseconds: 60));
    harness.guard.audioStarted('a');
    await settle(10);
    harness.guard.audioStopped('a');
    await settle(20);
    expect(harness.guard.keepAliveActive, isTrue);
    await settle(150);
    expect(harness.guard.keepAliveActive, isFalse);
    expect(harness.platform.keepAlive.last, isFalse);
    expect(
      harness.lines.any((line) => line.contains('reason=grace-expired')),
      isTrue,
    );
  });

  test('resuming within the grace period keeps the same loop', () async {
    final harness = _Harness(keepAliveLimit: const Duration(milliseconds: 60));
    harness.guard.audioStarted('a');
    await settle(10);
    harness.guard.audioStopped('a');
    await settle(30);
    harness.guard.audioStarted('a');
    await settle(120);
    expect(harness.guard.keepAliveActive, isTrue);
    expect(harness.platform.keepAlive.where((on) => !on), isEmpty);
    harness.guard.dispose();
  });

  test('starts the loop after a pause when none was running', () async {
    final harness = _Harness(bluetooth: false);
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    await settle();
    expect(harness.platform.keepAlive, isEmpty);
    harness.platform.bluetooth = true;
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    await settle();
    expect(harness.platform.keepAlive.first, isTrue);
    expect(harness.lines.first, contains('keep-alive on'));
    harness.guard.dispose();
  });

  test('turning the setting off releases a running loop', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    await settle();
    harness.guard.enabled = false;
    await settle(20);
    expect(harness.guard.keepAliveActive, isFalse);
    expect(harness.platform.keepAlive.last, isFalse);
    expect(harness.lines.last, contains('reason=disabled'));
  });

  test('releases when the route leaves Bluetooth', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    await settle();
    harness.platform.bluetooth = false;
    await settle(100);
    expect(harness.guard.keepAliveActive, isFalse);
    expect(harness.lines.last, contains('reason=route-changed'));
  });

  test('releases when the platform refuses to keep it', () async {
    final harness = _Harness();
    harness.guard.audioStarted('a');
    await settle();
    harness.platform.nativeAccepts = false;
    await settle(100);
    expect(harness.guard.keepAliveActive, isFalse);
    expect(harness.lines.last, contains('reason=native-refused'));
  });

  test('no keep-alive off Bluetooth', () async {
    final harness = _Harness(bluetooth: false);
    harness.guard
      ..audioStarted('a')
      ..audioStopped('a');
    await settle();
    expect(harness.platform.keepAlive, isEmpty);
    expect(harness.guard.keepAliveActive, isFalse);
  });

  test('onBluetooth reflects route and setting', () async {
    final harness = _Harness();
    expect(await harness.guard.onBluetooth(), isTrue);
    harness.platform.bluetooth = false;
    expect(await harness.guard.onBluetooth(), isFalse);
    harness.platform.bluetooth = true;
    harness.guard.enabled = false;
    expect(await harness.guard.onBluetooth(), isFalse);
  });
}
