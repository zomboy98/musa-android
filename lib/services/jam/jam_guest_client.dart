import 'dart:convert';
import 'dart:io';

import 'jam_pinned_client.dart';
import 'jam_queue.dart';

/// A remote queue snapshot. It deliberately contains no inferred participant data.
class JamGuestSnapshot {
  JamGuestSnapshot({
    required this.revision,
    required this.guestEditingEnabled,
    this.currentOccurrenceId,
    this.pendingOccurrenceId,
    required List<JamEntry> entries,
  }) : entries = List.unmodifiable(entries);
  final int revision;
  final bool guestEditingEnabled;
  final String? currentOccurrenceId;
  final String? pendingOccurrenceId;
  final List<JamEntry> entries;

  factory JamGuestSnapshot.fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    final editing = json['guestEditingEnabled'];
    final entries = json['entries'];
    final current = json['currentOccurrenceId'];
    final pending = json['pendingOccurrenceId'];
    if (revision is! int ||
        revision < 0 ||
        editing is! bool ||
        entries is! List ||
        entries.length > JamQueue.maxEntries) {
      throw const FormatException('Invalid queue snapshot');
    }
    final seen = <String>{};
    final result = <JamEntry>[];
    for (final value in entries) {
      if (value is! Map ||
          value['occurrenceId'] is! String ||
          value['trackId'] is! String) {
        throw const FormatException('Invalid queue entry');
      }
      final occurrence = value['occurrenceId'] as String;
      final track = value['trackId'] as String;
      if (occurrence.isEmpty ||
          occurrence.length > 256 ||
          track.isEmpty ||
          track.length > 256 ||
          !seen.add(occurrence)) {
        throw const FormatException('Invalid queue entry');
      }
      result.add(JamEntry(occurrenceId: occurrence, trackId: track));
    }
    if (current != null && (current is! String || !seen.contains(current))) {
      throw const FormatException('Invalid current occurrence');
    }
    if (pending != null && (pending is! String || !seen.contains(pending))) {
      throw const FormatException('Invalid pending occurrence');
    }
    return JamGuestSnapshot(
      currentOccurrenceId: current as String?,
      pendingOccurrenceId: pending as String?,
      revision: revision,
      guestEditingEnabled: editing,
      entries: result,
    );
  }
}

class JamGuestResult {
  const JamGuestResult(this.outcome, this.snapshot);
  final JamOutcome outcome;
  final JamGuestSnapshot snapshot;
}

/// A request was rejected; no credential or response body is included.
class JamGuestException implements Exception {
  const JamGuestException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Jam request failed (HTTP $statusCode)';
}

/// Owns the pinned transport and an ephemeral, private guest credential.
class JamGuestClient {
  JamGuestClient(this._transport);
  final JamPinnedClient _transport;
  String? _credential;
  bool _closed = false;
  bool _pairing = false;
  int _generation = 0;
  bool get isPaired => !_closed && _credential != null;

  Future<void> pair(String grant) async {
    _ensureOpen();
    if (_credential != null || _pairing) {
      throw StateError('Already paired or pairing');
    }
    if (grant.isEmpty || grant.length > 256) {
      throw ArgumentError('Invalid grant');
    }
    _pairing = true;
    try {
      final response = await _transport.send(
        'POST',
        '/pair',
        body: utf8.encode(jsonEncode({'grant': grant})),
      );
      _ensureOpen();
      if (response.statusCode != HttpStatus.ok) {
        throw JamGuestException(response.statusCode);
      }
      final value = _decode(response);
      final credential = value['credential'];
      if (credential is! String ||
          credential.isEmpty ||
          credential.length > 256) {
        throw const FormatException('Invalid pairing response');
      }
      _credential = credential;
      _generation++;
    } finally {
      _pairing = false;
    }
  }

  Future<JamGuestSnapshot> fetchSnapshot() async {
    final response = await _send('GET');
    if (response.statusCode != HttpStatus.ok) {
      throw JamGuestException(response.statusCode);
    }
    return JamGuestSnapshot.fromJson(_decode(response));
  }

  Future<JamGuestResult> add({
    required String commandId,
    required int revision,
    required String occurrenceId,
    required String trackId,
  }) => _command({
    'type': 'add',
    'id': commandId,
    'revision': revision,
    'occurrenceId': occurrenceId,
    'trackId': trackId,
  });
  Future<JamGuestResult> move({
    required String commandId,
    required int revision,
    required String occurrenceId,
    String? beforeOccurrenceId,
  }) => _command({
    'type': 'move',
    'id': commandId,
    'revision': revision,
    'occurrenceId': occurrenceId,
    'beforeOccurrenceId': beforeOccurrenceId,
  });
  Future<JamGuestResult> remove({
    required String commandId,
    required int revision,
    required String occurrenceId,
  }) => _command({
    'type': 'remove',
    'id': commandId,
    'revision': revision,
    'occurrenceId': occurrenceId,
  });

  Future<JamGuestResult> _command(Map<String, Object?> body) async {
    final response = await _send('POST', body: utf8.encode(jsonEncode(body)));
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.conflict) {
      throw JamGuestException(response.statusCode);
    }
    final value = _decode(response);
    final outcome = JamOutcome.values
        .where((e) => e.name == value['outcome'])
        .firstOrNull;
    if (outcome == null ||
        (response.statusCode == HttpStatus.conflict) !=
            (outcome == JamOutcome.conflict)) {
      throw const FormatException('Invalid command response');
    }
    return JamGuestResult(outcome, JamGuestSnapshot.fromJson(value));
  }

  Future<JamPinnedResponse> _send(String method, {List<int>? body}) async {
    _ensureOpen();
    final credential = _credential;
    if (credential == null) throw StateError('Guest not paired');
    final generation = _generation;
    final response = await _transport.send(
      method,
      '/queue',
      bearer: credential,
      body: body,
    );
    _ensureOpen();
    if (generation != _generation) {
      throw StateError('Stale guest response');
    }
    if (response.statusCode == HttpStatus.unauthorized) {
      _credential = null;
      _generation++;
      throw const JamGuestException(HttpStatus.unauthorized);
    }
    return response;
  }

  Map<String, dynamic> _decode(JamPinnedResponse response) {
    final value = jsonDecode(utf8.decode(response.body));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid response');
    }
    return value;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Guest client closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _credential = null;
    _transport.close();
  }
}
