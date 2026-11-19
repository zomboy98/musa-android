import 'package:shared_preferences/shared_preferences.dart';

class ReportRateLimiter {
  ReportRateLimiter({
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? now,
    this.limit = 5,
    this.window = const Duration(hours: 1),
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now;

  static const key = 'report_sent_at_v1';

  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _now;
  final int limit;
  final Duration window;

  List<int> _recent(SharedPreferences prefs) {
    final cutoff = _now().subtract(window).millisecondsSinceEpoch;
    return [
      for (final raw in prefs.getStringList(key) ?? const <String>[])
        if ((int.tryParse(raw) ?? 0) > cutoff) int.parse(raw),
    ];
  }

  Future<bool> canSend() async => _recent(await _preferences()).length < limit;

  Future<void> record() async {
    final prefs = await _preferences();
    final recent = _recent(prefs)..add(_now().millisecondsSinceEpoch);
    await prefs.setStringList(key, [for (final t in recent) '$t']);
  }
}
