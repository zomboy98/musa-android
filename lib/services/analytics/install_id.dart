import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class InstallId {
  InstallId({Future<SharedPreferences> Function()? preferences, Random? random})
    : _preferences = preferences ?? SharedPreferences.getInstance,
      _random = random ?? Random.secure();

  static const key = 'anonymous_install_id_v1';
  static final instance = InstallId();
  static final _shape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  final Future<SharedPreferences> Function() _preferences;
  final Random _random;
  String? _cached;

  Future<String> read() async {
    final cached = _cached;
    if (cached != null) return cached;
    final prefs = await _preferences();
    final stored = prefs.getString(key);
    if (stored != null && _shape.hasMatch(stored)) return _cached = stored;
    final created = generate(_random);
    await prefs.setString(key, created);
    return _cached = created;
  }

  static String generate(Random random) {
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = [
      for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
