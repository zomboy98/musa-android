import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'jam_network_address.dart';
import 'jam_transport_limits.dart';

class JamPinnedResponse {
  const JamPinnedResponse(this.statusCode, this.body, this.location);
  final int statusCode;
  final List<int> body;
  final String? location;
}

/// HTTPS client for a single self-signed server certificate. The pin is SHA-256
/// of the DER certificate, obtained through an authenticated pairing channel.
class JamPinnedClient {
  JamPinnedClient(
    this.endpoint,
    String certificateSha256, {
    this.deadline = const Duration(seconds: 10),
  }) : _pin = certificateSha256.toLowerCase() {
    final address = InternetAddress.tryParse(endpoint.host);
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        address == null ||
        !isJamAddress(address) ||
        endpoint.host != address.address ||
        !endpoint.hasPort ||
        endpoint.port == 0 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.path.isNotEmpty && endpoint.path != '/') {
      throw ArgumentError.value(endpoint, 'endpoint');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(_pin)) {
      throw ArgumentError.value(certificateSha256, 'certificateSha256');
    }
    if (deadline <= Duration.zero) {
      throw ArgumentError.value(deadline, 'deadline');
    }
  }

  final Uri endpoint;
  final String _pin;
  final Duration deadline;
  final _clients = <HttpClient>{};
  bool _closed = false;

  Future<JamPinnedResponse> send(
    String method,
    String path, {
    String? bearer,
    List<int>? body,
  }) async {
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('?') ||
        path.contains('#')) {
      throw ArgumentError.value(path, 'path');
    }
    if (_closed) throw StateError('Client closed');
    // Isolate each request so a timeout can close its connection without
    // interrupting other requests. No system roots may bypass the pin check.
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (certificate, host, port) =>
        host == endpoint.host &&
        port == endpoint.port &&
        sha256.convert(certificate.der).toString() == _pin;
    _clients.add(client);
    try {
      return await _send(client, method, path, bearer, body).timeout(deadline);
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<JamPinnedResponse> _send(
    HttpClient client,
    String method,
    String path,
    String? bearer,
    List<int>? body,
  ) async {
    final request = await client.openUrl(method, endpoint.replace(path: path));
    request.followRedirects = false;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // The bounded server intentionally rejects chunked request bodies.
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > jamMaxResponseBytes - bytes.length) {
        throw const FormatException('Jam response exceeds byte limit');
      }
      bytes.add(chunk);
    }
    return JamPinnedResponse(
      response.statusCode,
      bytes.takeBytes().asUnmodifiableView(),
      response.headers.value(HttpHeaders.locationHeader),
    );
  }

  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
