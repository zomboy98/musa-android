import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mornye/constants/api_endpoints.dart';

enum ReportFailure { network, timeout, rateLimited, rejected, server }

class ReportException implements Exception {
  const ReportException(this.failure, [this.status]);

  final ReportFailure failure;
  final int? status;

  bool get retryable =>
      failure == ReportFailure.network ||
      failure == ReportFailure.timeout ||
      failure == ReportFailure.server;

  @override
  String toString() => 'ReportException(${failure.name}, $status)';
}

class ReportReceipt {
  const ReportReceipt(this.id, this.ref);

  final int id;
  final String ref;
}

class ReportClient {
  ReportClient({
    http.Client? client,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       endpoint = endpoint ?? musaApiUri(musaFeedbackPath);

  final http.Client _client;
  final Uri endpoint;
  final Duration timeout;

  Future<ReportReceipt> send(Map<String, Object?> body) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const ReportException(ReportFailure.timeout);
    } on SocketException {
      throw const ReportException(ReportFailure.network);
    } on http.ClientException {
      throw const ReportException(ReportFailure.network);
    } on HandshakeException {
      throw const ReportException(ReportFailure.network);
    }
    final status = response.statusCode;
    if (status == 201 || status == 200) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map && decoded['id'] is int) {
          final id = decoded['id'] as int;
          final ref = decoded['ref'];
          return ReportReceipt(id, ref is String ? ref : 'FB-$id');
        }
      } catch (_) {
        throw ReportException(ReportFailure.server, status);
      }
      throw ReportException(ReportFailure.server, status);
    }
    if (status == 429) throw ReportException(ReportFailure.rateLimited, status);
    if (status >= 400 && status < 500) {
      throw ReportException(ReportFailure.rejected, status);
    }
    throw ReportException(ReportFailure.server, status);
  }
}
