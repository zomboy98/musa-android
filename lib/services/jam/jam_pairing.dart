import 'dart:convert';
import 'dart:math';

/// In-memory, single-use pairing grants. This does not start a network server.
class JamPairing {
  JamPairing({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _pending = <String, DateTime>{};
  final _guests = <String, String>{};
  final _random = Random.secure();

  String _secret() => base64Url
      .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// A grant is valid until, but not including, its expiration instant.
  String issue({Duration lifetime = const Duration(minutes: 2)}) {
    if (lifetime <= Duration.zero || lifetime > const Duration(minutes: 5)) {
      throw ArgumentError.value(lifetime, 'lifetime');
    }
    final now = _now();
    _pending.removeWhere((_, expiry) => !now.isBefore(expiry));
    if (_pending.length >= 32) throw StateError('Too many pairing grants');
    final secret = _secret();
    _pending[secret] = now.add(lifetime);
    return secret;
  }

  /// Consumes the grant once and returns a credential for a new guest only.
  String? redeem(String secret) {
    final expiry = _pending.remove(secret);
    if (expiry == null || !_now().isBefore(expiry)) return null;
    if (_guests.length >= 32) return null;
    final credential = _secret();
    _guests[credential] = _secret();
    return credential;
  }

  String? authenticateGuest(String credential) => _guests[credential];

  bool revoke(String credential) => _guests.remove(credential) != null;

  void close() {
    _pending.clear();
    _guests.clear();
  }
}
