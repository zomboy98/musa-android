import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'jam_bounded_tls_listener.dart';

/// Experimental single-request reader. The owner must close after responding.
class JamBoundedHttpRequest {
  JamBoundedHttpRequest(this.method, this.target, this.headers, this.body);
  final String method;
  final String target;
  final Map<String, String> headers;
  final List<int> body;
  StreamSubscription<RawSocketEvent>? responseSubscription;

  static Future<JamBoundedHttpRequest> read(
    RawSecureSocket socket,
    JamConnectionCancellation cancellation, {
    int maxHeaderBytes = 8192,
    int maxBodyBytes = 4096,
    Duration timeout = const Duration(seconds: 5),
    bool keepSocketOpen = false,
  }) async {
    if (maxHeaderBytes < 1 || maxBodyBytes < 0 || timeout <= Duration.zero) {
      throw ArgumentError('Invalid HTTP limits');
    }
    cancellation.throwIfCancelled();
    final result = Completer<JamBoundedHttpRequest>();
    final bytes = <int>[];
    int? end;
    int? length;
    String? method;
    String? target;
    Map<String, String>? headers;
    void fail(Object error) {
      if (!result.isCompleted) result.completeError(error);
    }

    void consume() {
      try {
        while (true) {
          final chunk = socket.read(
            maxHeaderBytes + maxBodyBytes + 1 - bytes.length,
          );
          if (chunk == null || chunk.isEmpty) break;
          for (final byte in chunk) {
            bytes.add(byte);
            if (end == null) {
              final n = bytes.length;
              if (n > maxHeaderBytes) {
                throw const FormatException('Headers too large');
              }
              if (n >= 4 &&
                  bytes[n - 4] == 13 &&
                  bytes[n - 3] == 10 &&
                  bytes[n - 2] == 13 &&
                  bytes[n - 1] == 10) {
                end = n;
                final lines = ascii
                    .decode(bytes.sublist(0, n - 4))
                    .split('\r\n');
                final first = lines.first.split(' ');
                if (first.length != 3 ||
                    !RegExp(r'^[A-Z]+$').hasMatch(first[0]) ||
                    !first[1].startsWith('/') ||
                    first[1].codeUnits.any((c) => c <= 32 || c == 127) ||
                    first[2] != 'HTTP/1.1') {
                  throw const FormatException('Request line');
                }
                method = first[0];
                target = first[1];
                headers = <String, String>{};
                for (final line in lines.skip(1)) {
                  final colon = line.indexOf(':');
                  if (colon <= 0) throw const FormatException('Header');
                  final name = line.substring(0, colon);
                  if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(name)) {
                    throw const FormatException('Header name');
                  }
                  final rawValue = line.substring(colon + 1);
                  if (rawValue.codeUnits.any(
                    (c) => (c < 32 && c != 9) || c == 127,
                  )) {
                    throw const FormatException('Header value');
                  }
                  final value = rawValue.replaceAll(
                    RegExp(r'^[ \t]+|[ \t]+$'),
                    '',
                  );
                  final key = name.toLowerCase();
                  if (headers!.containsKey(key)) {
                    throw const FormatException('Duplicate header');
                  }
                  headers![key] = value;
                }
                if (headers!.containsKey('transfer-encoding') ||
                    !headers!.containsKey('host')) {
                  throw const FormatException('Framing');
                }
                final rawLength = headers!['content-length'];
                if (rawLength == null) {
                  if (method != 'GET') {
                    throw const FormatException('Missing length');
                  }
                  length = 0;
                } else {
                  if (!RegExp(r'^[0-9]{1,5}$').hasMatch(rawLength)) {
                    throw const FormatException('Length');
                  }
                  length = int.parse(rawLength);
                  if (length! > maxBodyBytes) {
                    throw const FormatException('Body too large');
                  }
                }
              }
            } else if (bytes.length > end! + length!) {
              throw const FormatException('Trailing data');
            }
          }
        }
        if (end != null &&
            bytes.length == end! + length! &&
            !result.isCompleted) {
          result.complete(
            JamBoundedHttpRequest(
              method!,
              target!,
              Map.unmodifiable(headers!),
              List.unmodifiable(bytes.sublist(end!)),
            ),
          );
        }
      } catch (e) {
        fail(e);
      }
    }

    socket.writeEventsEnabled = false;
    final subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) consume();
        if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          fail(const FormatException('Unexpected EOF'));
        }
      },
      onError: (Object e) => fail(e),
      onDone: () => fail(const FormatException('Unexpected EOF')),
    );
    final timer = Timer(timeout, () => fail(TimeoutException('HTTP request')));
    unawaited(
      cancellation.cancelled.then(
        (_) => fail(StateError('Connection cancelled')),
      ),
    );
    var handedOff = false;
    try {
      final request = await result.future;
      if (keepSocketOpen) {
        subscription.pause();
        request.responseSubscription = subscription;
        handedOff = true;
      }
      return request;
    } finally {
      timer.cancel();
      if (!handedOff) await subscription.cancel();
    }
  }
}
