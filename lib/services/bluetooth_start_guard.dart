import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('BluetoothStart');

abstract interface class BluetoothStartPlatform {
  Future<bool> routedToBluetooth();
  Future<bool> playSilence(Duration length);
  Future<bool> setKeepAlive(bool enabled, Duration limit);
}

class _NoBluetoothPlatform implements BluetoothStartPlatform {
  const _NoBluetoothPlatform();

  @override
  Future<bool> routedToBluetooth() async => false;

  @override
  Future<bool> playSilence(Duration length) async => false;

  @override
  Future<bool> setKeepAlive(bool enabled, Duration limit) async => false;
}

class ChannelBluetoothStartPlatform implements BluetoothStartPlatform {
  const ChannelBluetoothStartPlatform();

  static const _channel = MethodChannel('com.zarz.mornye/audio_route');

  Future<bool> _flag(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } catch (error) {
      _log.w('$method failed: $error');
      return false;
    }
  }

  @override
  Future<bool> routedToBluetooth() => _flag('bluetoothRouted');

  @override
  Future<bool> playSilence(Duration length) =>
      _flag('silence', {'durationMs': length.inMilliseconds});

  @override
  Future<bool> setKeepAlive(bool enabled, Duration limit) =>
      _flag('keepAlive', {'enabled': enabled, 'limitMs': limit.inMilliseconds});
}

/// Keeps a Bluetooth output awake: a short stretch of silence before a song's
/// first audible sample when the link was idle, and a zero-volume loop that
/// runs while music plays, across track changes, and for a grace period after
/// a pause. Nothing happens on other outputs or when [enabled] is false.
class BluetoothStartGuard {
  BluetoothStartGuard({
    BluetoothStartPlatform? platform,
    DateTime Function()? clock,
    Future<void> Function(Duration)? wait,
    this.idleThreshold = const Duration(milliseconds: 2500),
    this.silence = const Duration(milliseconds: 250),
    this.callBudget = const Duration(milliseconds: 60),
    this.keepAliveDelay = const Duration(milliseconds: 1500),
    this.keepAliveLimit = const Duration(seconds: 60),
    this.keepAliveRefresh = const Duration(seconds: 30),
    this.keepAliveNativeLimit = const Duration(seconds: 120),
    void Function(String line)? trace,
  }) : assert(
         silence + callBudget * 2 <= maxStartDelay,
         'The start delay budget is exceeded',
       ),
       _platform = platform ?? const _NoBluetoothPlatform(),
       _clock = clock ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed,
       _trace = trace ?? _defaultTrace;

  factory BluetoothStartGuard.system() => BluetoothStartGuard(
    platform: Platform.isAndroid ? const ChannelBluetoothStartPlatform() : null,
  );

  static const maxStartDelay = Duration(milliseconds: 400);

  static void _defaultTrace(String line) {
    debugPrint(line);
    _log.i(line);
  }

  final BluetoothStartPlatform _platform;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _wait;
  final void Function(String line) _trace;

  /// Idle time after which the platform suspends a Bluetooth stream. Android
  /// puts the output to standby after 3 s without a track.
  final Duration idleThreshold;
  final Duration silence;
  final Duration callBudget;
  final Duration keepAliveDelay;

  /// How long the loop outlives the last audible deck.
  final Duration keepAliveLimit;

  /// How often a running loop re-arms its native safety limit and re-checks
  /// the route.
  final Duration keepAliveRefresh;
  final Duration keepAliveNativeLimit;

  bool _enabled = true;

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      if (_keepAliveStart != null) unawaited(_releaseKeepAlive('disabled'));
    } else if (_active.isNotEmpty) {
      unawaited(_acquireKeepAlive('playing'));
    }
  }

  final Set<String> _active = {};
  DateTime? _lastAudio;
  DateTime? _keepAliveStart;
  bool _acquiring = false;
  Timer? _keepAliveTimer;
  Timer? _keepAliveExpiry;
  Timer? _keepAliveRefreshTimer;
  Future<Duration>? _pending;

  bool get keepAliveActive => _keepAliveStart != null;

  /// True when Bluetooth output is selected and the guard is enabled. Bounded
  /// by [callBudget]; unknown counts as false.
  Future<bool> onBluetooth() async {
    if (!_enabled) return false;
    return await _bounded(_platform.routedToBluetooth()) == true;
  }

  Duration? _idle(DateTime now) {
    if (_active.isNotEmpty || _keepAliveStart != null) return Duration.zero;
    final last = _lastAudio;
    return last == null ? null : now.difference(last);
  }

  Future<T?> _bounded<T>(Future<T> call) => call
      .then<T?>((value) => value)
      .timeout(callBudget, onTimeout: () => null);

  /// Emits silence when a Bluetooth output has been idle long enough to be
  /// suspended and returns how long it took. Never longer than
  /// [maxStartDelay].
  Future<Duration> beforeStart(String deck) {
    final pending = _pending;
    if (pending != null) return pending.then((_) => Duration.zero);
    final future = _beforeStart(deck).whenComplete(() => _pending = null);
    _pending = future;
    return future;
  }

  Future<Duration> _beforeStart(String deck) async {
    if (!_enabled) return Duration.zero;
    final idle = _idle(_clock());
    if (idle != null && idle < idleThreshold) return Duration.zero;
    final started = _clock();
    Duration elapsed() => _clock().difference(started);
    final idleText = idle == null ? 'unknown' : '${idle.inMilliseconds}ms';
    final routed = await _bounded(_platform.routedToBluetooth());
    if (routed != true) {
      _trace(
        'bt-guard: start deck=$deck route=${routed == null ? 'unknown' : 'other'} '
        'idle=$idleText silence=none',
      );
      return elapsed();
    }
    final played = await _bounded(_platform.playSilence(silence));
    if (played != true) {
      _trace(
        'bt-guard: start deck=$deck route=bluetooth idle=$idleText '
        'silence=failed',
      );
      return elapsed();
    }
    await _wait(silence);
    _trace(
      'bt-guard: start deck=$deck route=bluetooth idle=$idleText '
      'silence=${silence.inMilliseconds}ms took=${elapsed().inMilliseconds}ms',
    );
    return elapsed();
  }

  void audioStarted(String deck) {
    _active.add(deck);
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _keepAliveExpiry?.cancel();
    _keepAliveExpiry = null;
    if (_keepAliveStart == null) unawaited(_acquireKeepAlive('playing'));
  }

  void audioStopped(String deck) {
    if (!_active.remove(deck) || _active.isNotEmpty) return;
    _lastAudio = _clock();
    if (!_enabled) return;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (_keepAliveStart != null) {
      _armExpiry();
      return;
    }
    _keepAliveTimer = Timer(keepAliveDelay, () {
      _keepAliveTimer = null;
      unawaited(_acquireKeepAlive('pause'));
    });
  }

  void _armExpiry() {
    _keepAliveExpiry?.cancel();
    _keepAliveExpiry = Timer(keepAliveLimit, () {
      _keepAliveExpiry = null;
      if (_active.isEmpty) unawaited(_releaseKeepAlive('grace-expired'));
    });
  }

  Future<void> _acquireKeepAlive(String reason) async {
    if (!_enabled || _acquiring || _keepAliveStart != null) return;
    _acquiring = true;
    try {
      final idle = _idle(_clock());
      final routed = await _bounded(_platform.routedToBluetooth());
      if (routed != true || !_enabled) return;
      if (reason == 'pause' && _active.isNotEmpty) return;
      final on = await _bounded(
        _platform.setKeepAlive(true, keepAliveNativeLimit),
      );
      if (on != true) return;
      if (!_enabled || (reason == 'pause' && _active.isNotEmpty)) {
        await _bounded(_platform.setKeepAlive(false, keepAliveNativeLimit));
        return;
      }
      _keepAliveStart = _clock();
      if (_active.isEmpty) _armExpiry();
      _keepAliveRefreshTimer?.cancel();
      _keepAliveRefreshTimer = Timer.periodic(
        keepAliveRefresh,
        (_) => unawaited(_refreshKeepAlive()),
      );
      _trace(
        'bt-guard: keep-alive on reason=$reason '
        'idle=${idle?.inMilliseconds ?? 0}ms '
        'grace=${keepAliveLimit.inSeconds}s',
      );
    } finally {
      _acquiring = false;
    }
  }

  Future<void> _refreshKeepAlive() async {
    if (_keepAliveStart == null) return;
    final routed = await _bounded(_platform.routedToBluetooth());
    if (_keepAliveStart == null) return;
    if (routed == false) {
      await _releaseKeepAlive('route-changed');
      return;
    }
    final on = await _bounded(
      _platform.setKeepAlive(true, keepAliveNativeLimit),
    );
    if (on == false) await _releaseKeepAlive('native-refused');
  }

  Future<void> _releaseKeepAlive(String reason) async {
    _keepAliveExpiry?.cancel();
    _keepAliveExpiry = null;
    _keepAliveRefreshTimer?.cancel();
    _keepAliveRefreshTimer = null;
    final started = _keepAliveStart;
    if (started == null) return;
    _keepAliveStart = null;
    _lastAudio = _clock();
    await _bounded(_platform.setKeepAlive(false, keepAliveNativeLimit));
    _trace(
      'bt-guard: keep-alive off reason=$reason after '
      '${_clock().difference(started).inMilliseconds}ms',
    );
  }

  void dispose() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (_keepAliveStart != null) unawaited(_releaseKeepAlive('dispose'));
    _keepAliveExpiry?.cancel();
    _keepAliveRefreshTimer?.cancel();
  }
}

final BluetoothStartGuard bluetoothStartGuard = BluetoothStartGuard.system();
