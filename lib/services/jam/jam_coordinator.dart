import 'dart:async';
import 'dart:io';

import 'jam_bounded_server.dart';
import 'jam_queue.dart';
import 'jam_session.dart';
import 'jam_playback.dart';

/// Owns one authoritative, in-memory session and its loopback transport.
/// Playback is connected only through an explicitly supplied host-local port.
class JamCoordinator {
  JamCoordinator._(this._session, this.server);

  final JamSession _session;
  final JamBoundedServer server;
  Future<void>? _closing;
  Future<void> Function()? _closePlayback;

  static Future<JamCoordinator> start({
    required String hostId,
    required SecurityContext identity,
  }) async {
    final session = JamSession(hostId: hostId);
    try {
      final server = await JamBoundedServer.start(
        identity: identity,
        session: session,
      );
      return JamCoordinator._(session, server);
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// Starts a loopback session with its own certificate and invitation pin.
  static Future<JamCoordinator> startEphemeral({
    required String hostId,
    InternetAddress? address,
    bool requireGuestSources = false,
  }) async {
    final session = JamSession(hostId: hostId);
    if (requireGuestSources) {
      // Fail closed throughout bootstrap until host playback installs its probe.
      session.canResolveGuestTrack = (_) async => false;
    }
    try {
      final server = await JamBoundedServer.startEphemeral(
        session: session,
        address: address,
      );
      return JamCoordinator._(session, server);
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  JamQueue get snapshot => _session.snapshot;
  JamResult setCurrentOccurrence(String? occurrenceId) =>
      _session.setCurrentOccurrence(occurrenceId);
  JamResult setPlaybackOccurrences(String? current, String? pending) =>
      _session.setPlaybackOccurrences(
        currentOccurrenceId: current,
        pendingOccurrenceId: pending,
      );
  Stream<JamQueue> get events => _session.events;

  /// Installs a host-owned adapter; this capability is never exposed to guests.
  JamPlaybackBinding<T> attachPlayback<T extends Object>({
    required JamTrackResolver<T> resolver,
    required JamPlaybackPort<T> port,
    void Function(Object, StackTrace)? onError,
    void Function(int revision)? onSuccess,
    void Function(int revision)? onPending,
    void Function(int revision, Set<String> unavailable)? onAvailability,
    void Function(int revision)? onPartial,
    bool Function()? allowPartial,
  }) {
    if (_closing != null) throw StateError('Coordinator closed');
    if (_closePlayback != null) throw StateError('Playback already attached');
    _session.canResolveGuestTrack = (trackId) async =>
        await resolver.resolveLocal(trackId) != null;
    final binding = JamPlaybackBinding<T>(
      events: events,
      initial: snapshot,
      resolver: resolver,
      port: port,
      onError: onError,
      onSuccess: onSuccess,
      onPending: onPending,
      onAvailability: onAvailability,
      onPartial: onPartial,
      allowPartial: allowPartial,
      currentRevision: () => snapshot.revision,
    );
    _closePlayback = binding.close;
    return binding;
  }

  /// Commands carry caller-provided IDs and revisions for safe retries.
  JamResult submitHost(JamCommand command) {
    if (_closing != null) throw StateError('Coordinator closed');
    return _session.submit(
      authenticatedActorId: _session.hostId,
      command: command,
    );
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await server.close();
    } finally {
      try {
        await _closePlayback?.call();
      } finally {
        await _session.close();
      }
    }
  }
}
