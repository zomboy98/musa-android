const playerVideoEvalInterval = Duration(milliseconds: 500);
const playerVideoDeadband = Duration(milliseconds: 120);
const playerVideoSettled = Duration(milliseconds: 40);
const playerVideoSeekThreshold = Duration(milliseconds: 700);
const playerVideoCooldown = Duration(seconds: 2);
const playerVideoSummaryEvery = Duration(seconds: 30);
const double playerVideoStallRatio = 0.7;
const double playerVideoCatchUpRate = 1.04;
const double playerVideoEaseRate = 0.96;

enum PlayerVideoCorrection { none, seek, speedUp, slowDown, restoreSpeed }

PlayerVideoCorrection playerVideoCorrection({
  required Duration video,
  required Duration audio,
  Duration? duration,
}) {
  if (duration != null && duration > Duration.zero && audio >= duration) {
    return PlayerVideoCorrection.none;
  }
  final drift = video - audio;
  if (drift.abs() > playerVideoSeekThreshold) return PlayerVideoCorrection.seek;
  if (drift.abs() <= playerVideoDeadband) return PlayerVideoCorrection.none;
  return drift.isNegative
      ? PlayerVideoCorrection.speedUp
      : PlayerVideoCorrection.slowDown;
}

class PlayerVideoSyncGovernor {
  Duration? _lastEval;
  Duration? _lastCorrection;
  Duration? _lastVideo;
  Duration? _lastObserved;
  Duration _windowStart = Duration.zero;
  bool _windowOpen = false;
  double rate = 1.0;
  int evaluations = 0;
  int corrections = 0;
  int softAdjustments = 0;
  int stalls = 0;
  int _windowEvals = 0;
  int _windowCorrections = 0;
  int _windowSoft = 0;
  int _windowStalls = 0;
  int _driftSumMs = 0;
  int _maxDriftMs = 0;

  bool due(Duration now) {
    final last = _lastEval;
    if (last != null && now - last < playerVideoEvalInterval) return false;
    _lastEval = now;
    if (!_windowOpen) {
      _windowOpen = true;
      _windowStart = now;
    }
    return true;
  }

  void observe({
    required Duration now,
    required Duration video,
    required Duration audio,
    required bool playing,
  }) {
    evaluations++;
    _windowEvals++;
    final drift = (video - audio).inMilliseconds.abs();
    _driftSumMs += drift;
    if (drift > _maxDriftMs) _maxDriftMs = drift;
    final previous = _lastVideo;
    final before = _lastObserved;
    if (playing && previous != null && before != null) {
      final wall = (now - before).inMilliseconds;
      final advanced = (video - previous).inMilliseconds;
      if (wall > 0 &&
          advanced >= 0 &&
          advanced < wall * playerVideoStallRatio * rate) {
        stalls++;
        _windowStalls++;
      }
    }
    _lastVideo = video;
    _lastObserved = now;
  }

  /// Small drifts are absorbed by nudging the playback rate, which never
  /// interrupts the picture. Only a large drift seeks, at most once per
  /// cooldown.
  PlayerVideoCorrection correction({
    required Duration now,
    required Duration video,
    required Duration audio,
    Duration? duration,
  }) {
    final wanted = playerVideoCorrection(
      video: video,
      audio: audio,
      duration: duration,
    );
    if (wanted != PlayerVideoCorrection.seek) {
      final drift = (video - audio).abs();
      final target = switch (wanted) {
        PlayerVideoCorrection.speedUp => playerVideoCatchUpRate,
        PlayerVideoCorrection.slowDown => playerVideoEaseRate,
        _ => drift <= playerVideoSettled ? 1.0 : rate,
      };
      if (target == rate) return PlayerVideoCorrection.none;
      rate = target;
      softAdjustments++;
      _windowSoft++;
      return target == 1.0 ? PlayerVideoCorrection.restoreSpeed : wanted;
    }
    final last = _lastCorrection;
    if (last != null && now - last < playerVideoCooldown) {
      return PlayerVideoCorrection.none;
    }
    _lastCorrection = now;
    rate = 1.0;
    corrections++;
    _windowCorrections++;
    return wanted;
  }

  void restartAfterSeek() => _lastVideo = null;

  String? summary(Duration now, {bool force = false}) {
    if (!_windowOpen || _windowEvals == 0) return null;
    final span = now - _windowStart;
    if (!force && span < playerVideoSummaryEvery) return null;
    final minutes = span.inMilliseconds <= 0
        ? 1.0
        : span.inMilliseconds / 60000.0;
    final line =
        'video: sync window=${span.inSeconds}s evals=$_windowEvals '
        'seeks=$_windowCorrections '
        'perMin=${(_windowCorrections / minutes).toStringAsFixed(1)} '
        'rateAdjusts=$_windowSoft rate=${rate.toStringAsFixed(2)} '
        'stalls=$_windowStalls '
        'meanDrift=${_driftSumMs ~/ _windowEvals}ms maxDrift=${_maxDriftMs}ms';
    _windowOpen = false;
    _windowEvals = 0;
    _windowCorrections = 0;
    _windowSoft = 0;
    _windowStalls = 0;
    _driftSumMs = 0;
    _maxDriftMs = 0;
    return line;
  }
}
