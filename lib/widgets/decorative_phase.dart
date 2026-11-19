import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A looping phase in `[0, 1)` for continuous decorative motion, such as
/// equalizer bars and wavy tracks.
///
/// Every running phase advances from one app-wide [Ticker], so decoration is
/// drawn once per display frame (60, 90 or 120 Hz) and stays in step with
/// scrolling instead of running at a fraction of the refresh rate. The value
/// comes from elapsed time, never from a frame count: the loop lasts [loop]
/// at any refresh rate, and a late frame only skips ahead.
///
/// The ticker runs only while a phase is running and the app draws frames, so
/// a hidden or paused app holds every phase. Owners stop their phase while
/// paused, under reduced motion, and while a disabled [TickerMode] hides them;
/// a stopped phase holds its value and resumes from it.
class DecorativePhase extends ChangeNotifier
    implements ValueListenable<double> {
  DecorativePhase(this.loop);

  /// Time for one full cycle from 0 back to 0.
  final Duration loop;

  /// Longest gap between two frames counted as motion. A longer one means the
  /// app was hidden or stalled, so the phase resumes instead of jumping.
  static const maxFrameGap = Duration(milliseconds: 250);

  static var _clock = _DecorativeClock();

  /// Lets a test that settles animations by pumping until no frame is
  /// scheduled keep decoration still: a vsync ticker that never ends would
  /// otherwise keep that loop going. Phases hold their value while it is set.
  @visibleForTesting
  static set debugHoldClock(bool hold) {
    _clock.hold = hold;
  }

  /// Whether the shared clock has a running phase to advance.
  @visibleForTesting
  static bool get debugClockRunning => _clock.running;

  /// Replaces the shared clock, so a phase a test left running cannot keep a
  /// ticker from a finished test.
  @visibleForTesting
  static void debugResetClock() {
    final hold = _clock._hold;
    _clock.dispose();
    _clock = _DecorativeClock().._hold = hold;
  }

  double _value = 0;
  double _startValue = 0;
  int? _startMicros;

  @override
  double get value => _value;

  bool get isRunning => _startMicros != null;

  void start() {
    if (isRunning) return;
    _startValue = _value;
    _startMicros = _clock.micros;
    _clock.addListener(_tick);
  }

  void stop() {
    if (!isRunning) return;
    _clock.removeListener(_tick);
    _startMicros = null;
  }

  void _tick() {
    final elapsed = _clock.micros - _startMicros!;
    _value = (_startValue + elapsed / loop.inMicroseconds) % 1;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class _DecorativeClock extends ChangeNotifier with WidgetsBindingObserver {
  Ticker? _ticker;
  bool _observing = false;
  Duration _lastElapsed = Duration.zero;
  bool _hold = false;

  set hold(bool value) {
    if (_hold == value) return;
    _hold = value;
    _sync();
  }

  /// Motion time in microseconds: frame gaps summed, each capped at
  /// [DecorativePhase.maxFrameGap].
  int micros = 0;

  bool get running => _ticker != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  void _onTick(Duration elapsed) {
    final gap = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    micros += gap > DecorativePhase.maxFrameGap
        ? DecorativePhase.maxFrameGap.inMicroseconds
        : gap.inMicroseconds;
    notifyListeners();
    _sync();
  }

  // Listeners removed during a notification only count once it ends, so a
  // tick syncs again afterwards.
  void _sync() {
    final observe = hasListeners;
    if (observe != _observing) {
      _observing = observe;
      observe
          ? WidgetsBinding.instance.addObserver(this)
          : WidgetsBinding.instance.removeObserver(this);
    }
    final run = observe && !_hold && SchedulerBinding.instance.framesEnabled;
    if (run == running) return;
    if (run) {
      _lastElapsed = Duration.zero;
      _ticker = Ticker(_onTick, debugLabel: 'DecorativePhase')..start();
    } else {
      _ticker!.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
