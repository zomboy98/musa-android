import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// Session-scoped, in-memory identity. Never serialize the security context.
class JamEphemeralIdentity {
  JamEphemeralIdentity._(this.context, this.certificateSha256);

  final SecurityContext context;
  final String certificateSha256;

  static JamEphemeralIdentity generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'Mornye Jam'},
      privateKey,
      publicKey,
    );
    final random = Random.secure();
    var serial = BigInt.one;
    for (var i = 0; i < 16; i++) {
      serial = (serial << 8) | BigInt.from(random.nextInt(256));
    }
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      1,
      serialNumber: serial.toString(),
      notBefore: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );
    final der = base64.decode(
      certificate
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s'), ''),
    );
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(
        utf8.encode(CryptoUtils.encodeEcPrivateKeyToPem(privateKey)),
      );
    return JamEphemeralIdentity._(context, sha256.convert(der).toString());
  }
}
