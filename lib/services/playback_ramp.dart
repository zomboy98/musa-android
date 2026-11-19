import 'dart:math';

class PlaybackRamp {
  static const Duration startFadeIn = Duration(milliseconds: 25);
  static const int startFadeSteps = 5;
  static const Duration bluetoothFadeIn = Duration(milliseconds: 140);
  static const int bluetoothFadeSteps = 14;
  static const Duration bluetoothSettle = Duration(milliseconds: 80);
  static const Duration startPoll = Duration(milliseconds: 5);
  static const Duration startLimit = Duration(milliseconds: 1500);

  PlaybackRamp({
    required this.apply,
    this.fadeIn = const Duration(milliseconds: 120),
    this.fadeOut = const Duration(milliseconds: 48),
    this.steps = 24,
    this.outSteps = 12,
    this.trace,
  });

  final Future<void> Function(double gain) apply;
  final Duration fadeIn;
  final Duration fadeOut;
  final int steps;
  final int outSteps;
  final void Function(String event)? trace;

  int _generation = 0;
  bool _active = false;

  double _level = 0;

  bool get active => _active;

  double get level => _level;

  void cancel() {
    _generation++;
    _active = false;
  }

  static double curve(double t) => 0.5 - 0.5 * cos(pi * t.clamp(0.0, 1.0));

  static double fadeInCurve(double t) {
    final c = curve(t);
    return c * c;
  }

  static double startCurve(double t) => (1 - cos(pi * t.clamp(0.0, 1.0))) / 2;

  static double fadeOutCurve(double t) => 1 - fadeInCurve(1 - t);

  Future<void> _run(
    int generation,
    double from,
    double Function() target,
    Duration duration,
    int count,
    double Function(double t) shape,
    String label,
  ) async {
    _active = true;
    final step = Duration(microseconds: duration.inMicroseconds ~/ count);
    final clock = Stopwatch()..start();
    trace?.call('ramp $label start steps=$count');
    var applied = 0;
    try {
      for (var i = 1; i <= count; i++) {
        if (generation != _generation) {
          trace?.call('ramp $label cancelled after $applied steps');
          return;
        }
        final end = target();
        final gain = from + (end - from) * shape(i / count);
        _level = gain;
        await apply(gain);
        applied++;
        if (i < count) await Future<void>.delayed(step);
      }
    } catch (_) {
      if (generation == _generation) _active = false;
      rethrow;
    }
    if (generation == _generation) _active = false;
    trace?.call(
      'ramp $label end steps=$applied took=${clock.elapsedMilliseconds}ms',
    );
  }

  Future<void> rampIn(double Function() target) {
    final generation = ++_generation;
    return _run(generation, 0, target, fadeIn, steps, fadeInCurve, 'in');
  }

  Future<void> rampInAfter(
    Future<bool> Function() advanced,
    double Function() target, {
    Duration poll = startPoll,
    Duration limit = startLimit,
    Duration fade = startFadeIn,
    int fadeSteps = startFadeSteps,
    Duration settle = Duration.zero,
  }) async {
    final generation = ++_generation;
    _active = true;
    _level = 0;
    final clock = Stopwatch()..start();
    var advancedIn = -1;
    while (clock.elapsed < limit) {
      await Future<void>.delayed(poll);
      if (generation != _generation) {
        trace?.call('ramp wait cancelled after ${clock.elapsedMilliseconds}ms');
        return;
      }
      var moving = false;
      try {
        moving = await advanced();
      } catch (_) {}
      if (generation != _generation) {
        trace?.call('ramp wait cancelled after ${clock.elapsedMilliseconds}ms');
        return;
      }
      if (moving) {
        advancedIn = clock.elapsedMilliseconds;
        break;
      }
    }
    trace?.call(
      advancedIn >= 0
          ? 'first position advance after ${advancedIn}ms'
          : 'no position advance after ${clock.elapsedMilliseconds}ms',
    );
    if (settle > Duration.zero) {
      await Future<void>.delayed(settle);
      if (generation != _generation) {
        trace?.call('ramp settle cancelled');
        return;
      }
      trace?.call('ramp settled ${settle.inMilliseconds}ms');
    }
    await _run(
      generation,
      0,
      target,
      fade,
      fadeSteps,
      startCurve,
      settle > Duration.zero ? 'in long' : 'in',
    );
  }

  Future<void> rampOut(double from) {
    final generation = ++_generation;
    return _run(
      generation,
      from,
      () => 0,
      fadeOut,
      outSteps,
      fadeOutCurve,
      'out',
    );
  }
}
