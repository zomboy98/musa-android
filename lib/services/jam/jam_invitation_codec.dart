import 'dart:convert';
import 'dart:io';

import 'jam_network_address.dart';

/// A short-lived pairing grant and the pinned endpoint it is valid for.
///
/// Treat this entire object and its encoded representation as secrets. Exchange
/// them over a trusted channel: encoding does not authenticate the sender.
class JamInvitation {
  JamInvitation({
    required this.endpoint,
    required this.certificateSha256,
    required this.grant,
  }) {
    final address = InternetAddress.tryParse(endpoint.host);
    if (endpoint.scheme != 'https' ||
        address == null ||
        !isJamAddress(address) ||
        endpoint.host != address.address ||
        !endpoint.hasPort ||
        endpoint.port < 1 ||
        endpoint.port > 65535 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw const FormatException('Invalid Jam invitation endpoint');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(certificateSha256)) {
      throw const FormatException('Invalid Jam invitation pin');
    }
    // JamPairing issues 32 random bytes as unpadded canonical base64url.
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(grant)) {
      throw const FormatException('Invalid Jam invitation grant');
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(grant));
      if (bytes.length != 32 ||
          base64Url.encode(bytes).replaceAll('=', '') != grant) {
        throw const FormatException('Invalid Jam invitation grant');
      }
    } on FormatException {
      throw const FormatException('Invalid Jam invitation grant');
    }
  }

  final Uri endpoint;
  final String certificateSha256;
  final String grant;
}

/// Versioned, bounded, canonical text for manual transfer or a QR payload.
/// This is deliberately not a URL and must not be logged or persisted.
class JamInvitationCodec {
  const JamInvitationCodec._();

  static const _prefix = 'jam1.';
  static const maxEncodedLength = 1024;

  static String encode(JamInvitation invitation) {
    final payload = jsonEncode({
      'v': 1,
      'endpoint': invitation.endpoint.toString(),
      'pin': invitation.certificateSha256,
      'grant': invitation.grant,
    });
    return '$_prefix${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  static JamInvitation decode(String encoded) {
    if (encoded.length > maxEncodedLength || !encoded.startsWith(_prefix)) {
      throw const FormatException('Invalid Jam invitation');
    }
    final payload = encoded.substring(_prefix.length);
    if (payload.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(payload)) {
      throw const FormatException('Invalid Jam invitation');
    }
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(payload))),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 4 ||
          decoded['v'] != 1 ||
          decoded['endpoint'] is! String ||
          decoded['pin'] is! String ||
          decoded['grant'] is! String) {
        throw const FormatException('Invalid Jam invitation');
      }
      final invitation = JamInvitation(
        endpoint: Uri.parse(decoded['endpoint'] as String),
        certificateSha256: decoded['pin'] as String,
        grant: decoded['grant'] as String,
      );
      // Reject duplicate keys, alternative encodings and noncanonical data.
      if (encode(invitation) != encoded) {
        throw const FormatException('Invalid Jam invitation');
      }
      return invitation;
    } on FormatException {
      throw const FormatException('Invalid Jam invitation');
    } on ArgumentError {
      throw const FormatException('Invalid Jam invitation');
    }
  }
}
