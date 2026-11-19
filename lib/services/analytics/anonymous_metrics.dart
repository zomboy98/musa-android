import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mornye/constants/api_endpoints.dart';
import 'package:mornye/services/analytics/install_id.dart';
import 'package:mornye/services/diagnostics/report_device_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Anonymous usage counters: a random installation id, the app and Android
/// versions and how many songs were downloaded or streamed since the last
/// delivery. No titles, searches, account or address ever go in the request.
class AnonymousMetrics {
  AnonymousMetrics({
    http.Client? client,
    Uri? endpoint,
    Future<SharedPreferences> Function()? preferences,
    InstallId? installId,
    Future<int> Function()? osVersion,
    String? appVersion,
    this.interval = const Duration(minutes: 4),
    this.maxBackoff = const Duration(hours: 1),
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _endpoint = endpoint ?? musaApiUri(musaMetricsPath),
       _preferences = preferences ?? SharedPreferences.getInstance,
       _installId = installId ?? InstallId.instance,
       _osVersion = osVersion ?? _defaultOs,
       _appVersion = appVersion ?? ReportDeviceInfo.currentAppVersion;

  static final instance = AnonymousMetrics();

  static const downloadsKey = 'analytics_pending_downloads_v1';
  static const streamsKey = 'analytics_pending_streams_v1';
  static const maxPerRequest = 500;

  static void recordDownloadCompleted() => instance.recordDownload();
  static void recordStreamPlayed() => instance.recordStream();

  static Future<int> _defaultOs() async =>
      (await ReportDeviceInfo.collect(locale: '')).osMajor;

  final http.Client _client;
  final Uri _endpoint;
  final Future<SharedPreferences> Function() _preferences;
  final InstallId _installId;
  final Future<int> Function() _osVersion;
  final String _appVersion;
  final Duration interval;
  final Duration maxBackoff;
  final Duration requestTimeout;

  bool _allowed = false;
  bool _foreground = false;
  bool _sending = false;
  bool _disposed = false;
  int _failures = 0;
  int _downloads = 0;
  int _streams = 0;
  Timer? _timer;
  Future<void>? _loaded;

  bool get allowed => _allowed;
  bool get foreground => _foreground;
  bool get running => _timer != null;
  int get pendingDownloads => _downloads;
  int get pendingStreams => _streams;

  Future<void> _ensureLoaded() => _loaded ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      _downloads += prefs.getInt(downloadsKey) ?? 0;
      _streams += prefs.getInt(streamsKey) ?? 0;
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await _preferences();
      await prefs.setInt(downloadsKey, _downloads);
      await prefs.setInt(streamsKey, _streams);
    } catch (_) {}
  }

  void recordDownload() {
    if (!_allowed) return;
    unawaited(
      _ensureLoaded().then((_) {
        _downloads++;
        return _persist();
      }),
    );
  }

  void recordStream() {
    if (!_allowed) return;
    unawaited(
      _ensureLoaded().then((_) {
        _streams++;
        return _persist();
      }),
    );
  }

  void setAllowed(bool value) {
    if (_allowed == value) return;
    _allowed = value;
    if (!value) {
      unawaited(
        _ensureLoaded().then((_) {
          _downloads = 0;
          _streams = 0;
          return _persist();
        }),
      );
    }
    _refresh();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _refresh();
  }

  void _refresh() {
    if (_disposed) return;
    if (_allowed && _foreground) {
      if (_timer == null) _schedule(Duration.zero);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(beat());
    });
  }

  Duration _nextDelay() {
    if (_failures == 0) return interval;
    var delay = interval;
    for (var i = 0; i < _failures && delay < maxBackoff; i++) {
      delay *= 2;
    }
    return delay > maxBackoff ? maxBackoff : delay;
  }

  Map<String, Object> bodyFor(String id, int os, int dl, int st) => {
    'id': id,
    'v': _appVersion,
    'os': os,
    'dl': dl,
    'st': st,
  };

  /// One delivery. Counters only go down after the server accepts them.
  Future<void> beat() async {
    if (_disposed || _sending || !_allowed || !_foreground) return;
    _sending = true;
    try {
      await _ensureLoaded();
      final dl = _downloads > maxPerRequest ? maxPerRequest : _downloads;
      final st = _streams > maxPerRequest ? maxPerRequest : _streams;
      final id = await _installId.read();
      final os = await _osVersion();
      if (!_allowed || !_foreground) return;
      final response = await _client
          .post(
            _endpoint,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(bodyFor(id, os, dl, st)),
          )
          .timeout(requestTimeout);
      if (response.statusCode == 200) {
        _failures = 0;
        _downloads -= dl;
        _streams -= st;
        await _persist();
      } else if (response.statusCode != 429) {
        _failures++;
      }
    } catch (_) {
      _failures++;
    } finally {
      _sending = false;
      if (!_disposed && _allowed && _foreground) _schedule(_nextDelay());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
