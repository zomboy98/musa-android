import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// Isolated, best-effort replay. Callers provide opaque track tokens and actual
/// recorder deltas, never song metadata. This class has no persistence access.
class ListeningShadow {
  ListeningShadow({
    required this.run,
    this.timeout = const Duration(seconds: 5),
    this.maxQueuedEvents = 256,
    this.maxQueuedBytes = 65536,
    this.maxSegments = 4096,
  });

  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final Duration timeout;

  /// These bounds apply to waiting entries. At most one additional entry is
  /// in flight, and it passed the same individual byte and segment bounds.
  final int maxQueuedEvents;
  final int maxQueuedBytes;
  final int maxSegments;
  final Queue<_Entry> _queue = Queue();
  Map<String, dynamic> _state = {
    'version': 1,
    'track': null,
    'playing': false,
    'enabled': true,
    'session_ms': 0,
    'counted': false,
  };
  bool _active = true;
  bool _running = false;
  int _generation = 0;
  int _bytes = 0;
  int _segments = 0;
  Completer<void>? _drained;

  bool get active => _active;

  /// Enqueues immutable JSON data. Any malformed or excessive input disables
  /// replay; failure is never exposed to the recorder.
  void submit(
    Map<String, dynamic> event, {
    List<Map<String, dynamic>>? expected,
  }) {
    if (!_active) return;
    try {
      if (!_validEvent(event, expected) ||
          !_fitsBeforeEncoding(event, expected)) {
        invalidate();
        return;
      }
      final encoded = jsonEncode({'event': event, 'expected': expected});
      final size = utf8.encode(encoded).length;
      final copied = jsonDecode(encoded) as Map<String, dynamic>;
      final value = copied['event'] as Map<String, dynamic>;
      final type = value['type'];
      if (!const {'advance', 'update', 'enabled', 'reset'}.contains(type) ||
          (type == 'advance') != (expected != null)) {
        invalidate();
        return;
      }
      final count = type == 'advance' ? (value['segments'] as List).length : 0;
      if (_queue.length >= maxQueuedEvents ||
          _bytes + size > maxQueuedBytes ||
          _segments + count > maxSegments) {
        invalidate();
        return;
      }
      _queue.add(
        _Entry(value, copied['expected'] as List<Object?>?, size, count),
      );
      _bytes += size;
      _segments += count;
      _drained ??= Completer<void>();
      if (!_running) unawaited(_pump());
    } catch (_) {
      invalidate();
    }
  }

  /// Permanently invalidates pending and in-flight work, including late replies.
  void invalidate() {
    _active = false;
    _generation++;
    _queue.clear();
    _bytes = 0;
    _segments = 0;
    _state = {};
    _drained?.complete();
    _drained = null;
  }

  Future<void> drain() => _drained?.future ?? Future<void>.value();

  bool _boundedString(Object? value, int limit) =>
      value is String &&
      value.length <= limit &&
      utf8.encode(value).length <= limit;

  bool _validEvent(
    Map<String, dynamic> event,
    List<Map<String, dynamic>>? expected,
  ) {
    final type = event['type'];
    if (type == 'reset') return event.length == 1 && expected == null;
    if (type == 'enabled') {
      return event.length == 2 && event['value'] is bool && expected == null;
    }
    if (type == 'update') {
      final track = event['track'];
      return event.length == 4 &&
          event.containsKey('track') &&
          (track == null || _boundedString(track, 1024)) &&
          event['playing'] is bool &&
          event['ended'] is bool &&
          expected == null;
    }
    if (type != 'advance' || event.length != 2 || expected == null) {
      return false;
    }
    final segments = event['segments'];
    if (segments is! List<Object?> ||
        segments.length > 4096 ||
        segments.length > maxSegments ||
        expected.length > 4096 ||
        expected.length > maxSegments) {
      return false;
    }
    for (final segment in segments) {
      if (segment is! Map<Object?, Object?> ||
          segment.length != 2 ||
          !_boundedString(segment['day'], 32) ||
          !_positiveInt(segment['milliseconds'])) {
        return false;
      }
    }
    for (final delta in expected) {
      if (delta.length != 4 ||
          !_boundedString(delta['day'], 32) ||
          !_boundedString(delta['track'], 1024) ||
          !_positiveInt(delta['milliseconds']) ||
          (delta['plays'] != 0 && delta['plays'] != 1) ||
          delta['plays'] is! int) {
        return false;
      }
    }
    return true;
  }

  bool _positiveInt(Object? value) =>
      value is int && value > 0 && value <= 9223372036854775807;

  // JSON escapes can occupy six bytes per UTF-16 code unit. Fixed allowances
  // cover field names, punctuation, booleans and the largest i64 numbers.
  bool _fitsBeforeEncoding(
    Map<String, dynamic> event,
    List<Map<String, dynamic>>? expected,
  ) {
    var estimate = 512;
    bool add(int amount) {
      estimate += amount;
      return estimate + _bytes <= maxQueuedBytes;
    }

    if (!add(0)) return false;
    final track = event['track'];
    if (track is String && !add(track.length * 6)) return false;
    if (event['type'] == 'advance') {
      for (final item in event['segments'] as List<Object?>) {
        final segment = item as Map<Object?, Object?>;
        if (!add(100 + (segment['day'] as String).length * 6)) return false;
      }
      for (final delta in expected!) {
        if (!add(
          200 +
              (delta['day'] as String).length * 6 +
              (delta['track'] as String).length * 6,
        )) {
          return false;
        }
      }
    }
    return true;
  }

  Future<void> _pump() async {
    _running = true;
    final generation = _generation;
    try {
      while (_active && _queue.isNotEmpty && generation == _generation) {
        final entry = _queue.removeFirst();
        _bytes -= entry.bytes;
        _segments -= entry.segments;
        final response = await Future<Map<String, dynamic>>.sync(
          () => run({
            'operation': 'musa_listening_step_v2',
            'version': 2,
            'state': Map<String, dynamic>.from(_state),
            'events': [entry.event],
          }),
        ).timeout(timeout);
        if (!_active || generation != _generation) return;
        final state = response['state'];
        final batches = response['batches'];
        if (response['version'] is! int ||
            response['version'] != 2 ||
            !_validState(state) ||
            batches is! List ||
            (entry.expected == null
                ? batches.isNotEmpty
                : batches.length != 1 ||
                      !_sameDeltas(batches[0], entry.expected!))) {
          invalidate();
          return;
        }
        _state = Map<String, dynamic>.from(state as Map);
      }
    } catch (_) {
      invalidate();
    } finally {
      _running = false;
      if (_active && _queue.isEmpty) {
        _drained?.complete();
        _drained = null;
      }
    }
  }

  bool _validState(dynamic state) {
    if (state is! Map<Object?, Object?>) return false;
    final track = state['track'];
    final ms = state['session_ms'];
    return state.length == 6 &&
        state['version'] is int &&
        state['version'] == 1 &&
        state.containsKey('track') &&
        (track == null || _boundedString(track, 1024)) &&
        state['playing'] is bool &&
        state['enabled'] is bool &&
        ms is int &&
        ms >= 0 &&
        ms <= 9223372036854775807 &&
        state['counted'] is bool &&
        state['counted'] == (ms >= 30000) &&
        (track != null || ms == 0);
  }

  bool _sameDeltas(dynamic actual, List<Object?> expected) {
    if (actual is! List<Object?> || actual.length != expected.length) {
      return false;
    }
    for (var i = 0; i < expected.length; i++) {
      final a = actual[i];
      final e = expected[i];
      if (a is! Map<Object?, Object?> ||
          e is! Map<Object?, Object?> ||
          a.length != 4 ||
          e.length != 4 ||
          a['day'] is! String ||
          a['track'] is! String ||
          a['milliseconds'] is! int ||
          a['plays'] is! int ||
          e['day'] is! String ||
          e['track'] is! String ||
          e['milliseconds'] is! int ||
          e['plays'] is! int ||
          a['day'] != e['day'] ||
          a['track'] != e['track'] ||
          a['milliseconds'] != e['milliseconds'] ||
          a['plays'] != e['plays']) {
        return false;
      }
    }
    return true;
  }
}

class _Entry {
  _Entry(this.event, this.expected, this.bytes, this.segments);
  final Map<String, dynamic> event;
  final List<Object?>? expected;
  final int bytes;
  final int segments;
}
