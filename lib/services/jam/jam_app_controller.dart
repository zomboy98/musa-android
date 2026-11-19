import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../local_network_access.dart';
import '../platform_bridge.dart';
import '../playable_media.dart';
import 'jam_coordinator.dart';
import 'jam_guest_client.dart';
import 'jam_invitation_codec.dart';
import 'jam_pinned_client.dart';
import 'jam_playback.dart';
import 'jam_queue.dart';
import 'jam_track_reference.dart';

enum JamAppPhase { idle, starting, hosting, pairing, connected, error, closing }

enum JamPlaybackState { idle, pending, synchronized, partial, error }

/// Owns one ephemeral session. No queue, invitation or credentials are persisted.
class JamAppController extends ChangeNotifier with WidgetsBindingObserver {
  JamAppController({
    LocalNetworkAccess? networkAccess,
    this.pollInterval = const Duration(seconds: 3),
    DateTime Function()? now,
    Future<bool> Function(String)? startBackgroundLease,
    Future<void> Function(String)? stopBackgroundLease,
    Stream<String>? backgroundLeaseLosses,
  }) : _network = networkAccess ?? LocalNetworkAccess.instance,
       _now = now ?? DateTime.now,
       _startBackgroundLease = startBackgroundLease ?? _defaultStartLease,
       _stopBackgroundLease = stopBackgroundLease ?? _defaultStopLease {
    if (pollInterval <= Duration.zero) throw ArgumentError.value(pollInterval);
    WidgetsBinding.instance.addObserver(this);
    final losses =
        backgroundLeaseLosses ??
        (Platform.isAndroid
            ? _nativeLeaseLosses
            : const Stream<String>.empty());
    _leaseLossSubscription = losses.listen(
      _onLeaseLost,
      onError: (_) {
        _leaseEventsAvailable = false;
        // The event channel failed; the native service may still be alive.
        // Retain its token so close() can release it.
        _leaseConfirmed = false;
        if (_leaseToken != null &&
            _paused &&
            phase != JamAppPhase.idle &&
            phase != JamAppPhase.closing) {
          _closeInBackground();
        }
      },
    );
  }

  final LocalNetworkAccess _network;
  final DateTime Function() _now;
  final Future<bool> Function(String) _startBackgroundLease;
  final Future<void> Function(String) _stopBackgroundLease;
  static final Stream<String> _nativeLeaseLosses = const EventChannel(
    'mornye/jam_lease_events',
  ).receiveBroadcastStream().where((event) => event is String).cast<String>();
  StreamSubscription<String>? _leaseLossSubscription;
  bool _paused = false;
  bool _leaseEventsAvailable = true;
  static Future<bool> _defaultStartLease(String token) async =>
      Platform.isAndroid &&
      await PlatformBridge.startJamConnectionService(token);
  static Future<void> _defaultStopLease(String token) async {
    if (Platform.isAndroid) {
      await PlatformBridge.stopJamConnectionService(token);
    }
  }

  String? _leaseToken;
  bool _leaseConfirmed = false;
  void _onLeaseLost(String token) {
    if (token != _leaseToken) return;
    _leaseToken = null;
    _leaseConfirmed = false;
    if (_paused && phase != JamAppPhase.idle && phase != JamAppPhase.closing) {
      _closeInBackground();
    }
  }

  final Duration pollInterval;
  JamAppPhase phase = JamAppPhase.idle;
  JamGuestSnapshot? snapshot;
  JamInvitation? invitation;

  /// Conservative deadline measured immediately before the server issues it.
  DateTime? invitationExpiresAt;
  Object? error;

  /// Queue projection failed; the authoritative Jam queue remains available.
  Object? playbackError;
  JamPlaybackState playbackState = JamPlaybackState.idle;
  Set<String> unavailablePlaybackOccurrences = const {};
  bool Function()? _retryPlayback;
  Future<JamResult> Function(PlayableMedia)? _addHostMedia;

  void installHostMediaEditor(Future<JamResult> Function(PlayableMedia) add) {
    if (phase != JamAppPhase.starting || _host == null) {
      throw StateError('Host editor can only be installed during startup');
    }
    _addHostMedia = add;
  }

  /// Adds local media through the authoritative queue.
  Future<JamResult> addHostMedia(PlayableMedia media) {
    final add = _addHostMedia;
    if (phase != JamAppPhase.hosting || add == null) {
      throw StateError('Host media editor unavailable');
    }
    return add(media);
  }

  JamCoordinator? _host;
  JamGuestClient? _guest;
  StreamSubscription<JamQueue>? _subscription;
  Timer? _timer;
  Future<void>? _closing;
  String? _hostId;
  int _generation = 0;

  /// Changes whenever the controller starts or closes a session.
  int get sessionGeneration => _generation;
  bool _disposed = false;
  bool _disposing = false;

  /// Host-local bootstrap runs before any invitation is issued.
  Future<void> Function(JamAppController controller)? prepareHostPlayback;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _phase(JamAppPhase value) {
    phase = value;
    _notify();
  }

  static String _id() => base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  JamGuestSnapshot _convert(JamQueue q) => JamGuestSnapshot(
    revision: q.revision,
    guestEditingEnabled: q.guestEditingEnabled,
    entries: q.entries,
  );
  void _update(JamGuestSnapshot next) {
    if (snapshot == null || next.revision >= snapshot!.revision) {
      snapshot = next;
      _notify();
    }
  }

  Future<void> startHosting({required InternetAddress address}) async {
    if (_disposed ||
        _disposing ||
        _closing != null ||
        (phase != JamAppPhase.idle && phase != JamAppPhase.error)) {
      throw StateError('Jam is active');
    }
    final generation = ++_generation;
    error = null;
    _phase(JamAppPhase.starting);
    JamCoordinator? host;
    try {
      await _network.ensureGranted();
      if (generation != _generation) return;
      final token = _id();
      _leaseToken = token;
      bool confirmed = false;
      try {
        confirmed = await _startBackgroundLease(token);
      } catch (_) {}
      if (generation != _generation) {
        try {
          await _stopBackgroundLease(token);
        } catch (_) {}
        return;
      }
      _leaseConfirmed =
          confirmed && _leaseToken == token && _leaseEventsAvailable;
      final hostId = _id();
      host = await JamCoordinator.startEphemeral(
        hostId: hostId,
        address: address,
        requireGuestSources: true,
      );
      if (generation != _generation) {
        await host.close();
        return;
      }
      _host = host;
      _hostId = hostId;
      await prepareHostPlayback?.call(this);
      if (generation != _generation) {
        await host.close();
        return;
      }
      _issueInvitation(host);
      snapshot = _convert(host.snapshot);
      _subscription = host.events.listen((q) {
        if (generation == _generation) _update(_convert(q));
      });
      _phase(JamAppPhase.hosting);
    } catch (e) {
      if (host != null) {
        if (generation == _generation && identical(_host, host)) {
          _host = null;
          _hostId = null;
        }
        await host.close();
      }
      if (generation == _generation) {
        final token = _leaseToken;
        _leaseToken = null;
        _leaseConfirmed = false;
        if (token != null) {
          try {
            await _stopBackgroundLease(token);
          } catch (_) {}
        }
        _addHostMedia = null;
        error = e;
        _phase(JamAppPhase.error);
      }
    }
  }

  /// Each invitation is short-lived and usable once; issue a new one per guest.
  void renewInvitation() {
    final host = _host;
    if (host == null || phase != JamAppPhase.hosting) {
      throw StateError('Not hosting');
    }
    _issueInvitation(host);
    _notify();
  }

  void _issueInvitation(JamCoordinator host) {
    const lifetime = Duration(minutes: 2);
    final expiresAt = _now().add(lifetime);
    final issued = host.server.issueInvitation(lifetime: lifetime);
    invitation = JamInvitation(
      endpoint: issued.endpoint,
      certificateSha256: issued.certificateSha256,
      grant: issued.grant,
    );
    invitationExpiresAt = expiresAt;
  }

  /// Opt-in host-only projection. The resolver must only return authorized
  /// local sources, and the port must preserve player state as documented by
  /// [JamPlaybackPort]. Guests never receive this capability.
  JamPlaybackBinding<T> attachHostPlayback<T extends Object>({
    required JamTrackResolver<T> resolver,
    required JamPlaybackPort<T> port,
  }) {
    final host = _host;
    if (host == null ||
        (phase != JamAppPhase.hosting && phase != JamAppPhase.starting)) {
      throw StateError('Not hosting');
    }
    final generation = _generation;
    final binding = host.attachPlayback<T>(
      resolver: resolver,
      port: port,
      allowPartial: () => phase == JamAppPhase.hosting,
      onPending: (revision) {
        if (generation == _generation && identical(host, _host)) {
          playbackError = null;
          playbackState = JamPlaybackState.pending;
          unavailablePlaybackOccurrences = const {};
          _notify();
        }
      },
      onAvailability: (revision, unavailable) {
        if (generation == _generation && identical(host, _host)) {
          unavailablePlaybackOccurrences = unavailable;
          _notify();
        }
      },
      onPartial: (revision) {
        if (generation == _generation && identical(host, _host)) {
          playbackState = JamPlaybackState.partial;
          _notify();
        }
      },
      onSuccess: (revision) {
        if (generation == _generation && identical(host, _host)) {
          playbackError = null;
          playbackState = JamPlaybackState.synchronized;
          _notify();
        }
      },
      onError: (error, stack) {
        if (generation == _generation && identical(host, _host)) {
          // Do not expose opaque IDs or source details in the UI.
          playbackState = JamPlaybackState.error;
          playbackError = StateError(
            'Jam playback source unavailable or player cannot reconcile the queue',
          );
          _notify();
        }
      },
    );
    _retryPlayback = binding.retry;
    return binding;
  }

  /// Seeds every existing occurrence before the session can be shared.
  void seedHostQueue(List<JamEntry> entries) {
    final host = _host;
    final id = _hostId;
    if (phase != JamAppPhase.starting ||
        host == null ||
        id == null ||
        host.snapshot.entries.isNotEmpty) {
      throw StateError('Host queue can only be initialized during startup');
    }
    if (entries.length > JamQueue.maxEntries) {
      throw StateError('Local queue exceeds Jam capacity');
    }
    for (final entry in entries) {
      final result = host.submitHost(
        AddJamEntry(
          _id(),
          id,
          host.snapshot.revision,
          entry.occurrenceId,
          entry.trackId,
        ),
      );
      if (result.outcome != JamOutcome.applied) {
        throw StateError('Cannot import the complete local queue');
      }
    }
  }

  void setHostCurrentOccurrence(String? occurrenceId) {
    final host = _host;
    if (host == null) throw StateError('Not hosting');
    final result = host.setCurrentOccurrence(occurrenceId);
    if (result.outcome != JamOutcome.applied &&
        result.outcome != JamOutcome.duplicate) {
      throw StateError('Cannot update the current Jam occurrence');
    }
    _update(_convert(result.state));
  }

  bool setHostPlaybackOccurrences(String? current, String? pending) {
    final host = _host;
    if (host == null) return false;
    final result = host.setPlaybackOccurrences(current, pending);
    if (result.outcome != JamOutcome.applied &&
        result.outcome != JamOutcome.duplicate) {
      return false;
    }
    _update(_convert(result.state));
    return true;
  }

  /// Retries the latest failed host projection without mutating the queue.
  bool retryHostPlayback() => _retryPlayback?.call() ?? false;

  Future<void> join(JamInvitation invite) async {
    if (_disposed ||
        _disposing ||
        _closing != null ||
        (phase != JamAppPhase.idle && phase != JamAppPhase.error)) {
      throw StateError('Jam is active');
    }
    final generation = ++_generation;
    error = null;
    _phase(JamAppPhase.pairing);
    try {
      await _network.ensureAccess(invite.endpoint);
      if (generation != _generation) return;
      final guest = JamGuestClient(
        JamPinnedClient(invite.endpoint, invite.certificateSha256),
      );
      _guest = guest;
      await guest.pair(invite.grant);
      final initial = await guest.fetchSnapshot();
      if (generation != _generation) return;
      snapshot = initial;
      _phase(JamAppPhase.connected);
      _schedulePoll(generation);
    } catch (e) {
      if (generation == _generation) {
        _guest?.close();
        _guest = null;
        error = e;
        _phase(JamAppPhase.error);
      }
    }
  }

  void _schedulePoll(int generation) {
    _timer?.cancel();
    _timer = Timer(pollInterval, () async {
      if (generation != _generation) return;
      final guest = _guest;
      if (guest == null) return;
      try {
        if (!await _network.isGranted()) {
          throw const LocalNetworkPermissionException();
        }
        if (generation != _generation) return;
        final next = await guest.fetchSnapshot();
        if (generation == _generation) _update(next);
      } catch (e) {
        if (generation == _generation) {
          await _fail(e);
        }
      } finally {
        if (generation == _generation && phase == JamAppPhase.connected) {
          _schedulePoll(generation);
        }
      }
    });
  }

  Future<void> _fail(Object e) async {
    await close();
    if (!_disposed) {
      error = e;
      _phase(JamAppPhase.error);
    }
  }

  Future<JamOutcome> add({
    required String trackId,
    String? occurrenceId,
    String? commandId,
    int? revision,
  }) => _command(
    'add',
    occurrenceId ?? _id(),
    trackId: trackId,
    commandId: commandId,
    revision: revision,
  );
  Future<JamOutcome> move({
    required String occurrenceId,
    String? beforeOccurrenceId,
    String? commandId,
    int? revision,
  }) => _command(
    'move',
    occurrenceId,
    before: beforeOccurrenceId,
    commandId: commandId,
    revision: revision,
  );
  Future<JamOutcome> remove({
    required String occurrenceId,
    String? commandId,
    int? revision,
  }) => _command(
    'remove',
    occurrenceId,
    commandId: commandId,
    revision: revision,
  );

  /// Atomically submits an already tokenized host queue at a captured Jam
  /// revision. Conflicts return the latest state for explicit reconciliation.
  JamResult replaceHostQueue({
    required List<JamEntry> entries,
    required int expectedRevision,
    required String commandId,
  }) {
    final host = _host;
    final id = _hostId;
    if (host == null || id == null || phase != JamAppPhase.hosting) {
      throw StateError('Not hosting');
    }
    final state = host.snapshot;
    if (entries.length > JamQueue.maxEntries) {
      return JamResult(state, JamOutcome.capacity);
    }
    if (entries.any(
      (e) => e.occurrenceId.length > 256 || e.trackId.length > 256,
    )) {
      return JamResult(state, JamOutcome.invalid);
    }
    final command = ReplaceHostJamEntries(
      commandId,
      id,
      expectedRevision,
      entries,
    );
    final accepted = state.acceptedOutcome(command);
    if (accepted != null) return JamResult(state, accepted);
    if (expectedRevision != state.revision) {
      _update(_convert(state));
      return JamResult(state, JamOutcome.conflict);
    }
    // Existing entries may originate from guests and must remain untouched.
    // New host entries must use generated opaque IDs or validated references,
    // never raw local paths or URLs in a snapshot visible to guests.
    final existingOccurrences = {
      for (final entry in state.entries) entry.occurrenceId,
    };
    final existingTracks = {for (final entry in state.entries) entry.trackId};
    final opaque = RegExp(r'^[A-Za-z0-9_-]{32}$');
    bool safeTrack(String track) =>
        existingTracks.contains(track) ||
        (track.startsWith('jamhost1:') &&
            opaque.hasMatch(track.substring('jamhost1:'.length))) ||
        JamTrackReference.tryDecode(track) != null;
    if (entries.any(
      (entry) =>
          !existingOccurrences.contains(entry.occurrenceId) &&
          (!opaque.hasMatch(entry.occurrenceId) || !safeTrack(entry.trackId)),
    )) {
      return JamResult(state, JamOutcome.invalid);
    }
    final result = host.submitHost(command);
    _update(_convert(result.state));
    return result;
  }

  Future<JamOutcome> setGuestEditing(bool enabled) async {
    final host = _host;
    final id = _hostId;
    final current = snapshot;
    if (host == null ||
        id == null ||
        current == null ||
        phase != JamAppPhase.hosting) {
      throw StateError('Not hosting');
    }
    final result = host.submitHost(
      SetGuestEditing(_id(), id, host.snapshot.revision, enabled),
    );
    _update(_convert(result.state));
    return result.outcome;
  }

  Future<JamOutcome> _command(
    String type,
    String occurrence, {
    String? trackId,
    String? before,
    String? commandId,
    int? revision,
  }) async {
    final current = snapshot;
    if (current == null) throw StateError('No Jam session');
    commandId ??= _id();
    final host = _host;
    if (host != null && phase == JamAppPhase.hosting) {
      final id = _hostId!;
      revision ??= host.snapshot.revision;
      final JamCommand command = switch (type) {
        'add' => AddJamEntry(commandId, id, revision, occurrence, trackId!),
        'move' => MoveJamEntry(commandId, id, revision, occurrence, before),
        _ => RemoveJamEntry(commandId, id, revision, occurrence),
      };
      final result = host.submitHost(command);
      _update(_convert(result.state));
      return result.outcome;
    }
    final guest = _guest;
    if (guest == null || phase != JamAppPhase.connected) {
      throw StateError('Not connected');
    }
    revision ??= current.revision;
    final generation = _generation;
    try {
      final result = switch (type) {
        'add' => await guest.add(
          commandId: commandId,
          revision: revision,
          occurrenceId: occurrence,
          trackId: trackId!,
        ),
        'move' => await guest.move(
          commandId: commandId,
          revision: revision,
          occurrenceId: occurrence,
          beforeOccurrenceId: before,
        ),
        _ => await guest.remove(
          commandId: commandId,
          revision: revision,
          occurrenceId: occurrence,
        ),
      };
      if (generation == _generation) _update(result.snapshot);
      return result.outcome;
    } catch (e) {
      if (generation == _generation) await _fail(e);
      rethrow;
    }
  }

  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    // Install the guard before _close synchronously notifies listeners.
    final completer = Completer<void>();
    final future = completer.future;
    _closing = future;
    () async {
      try {
        await _close();
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _closing = null;
      }
    }();
    return future;
  }

  void _closeInBackground() {
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Jam',
            context: ErrorDescription('while closing a session in background'),
          ),
        );
      }),
    );
  }

  Future<void> _close() async {
    ++_generation;
    _phase(JamAppPhase.closing);
    final token = _leaseToken;
    _leaseToken = null;
    _leaseConfirmed = false;
    if (token != null) {
      try {
        await _stopBackgroundLease(token);
      } catch (_) {}
    }
    _timer?.cancel();
    _timer = null;
    Object? cleanupError;
    StackTrace? cleanupStack;
    void failed(Object error, StackTrace stack) {
      cleanupError ??= error;
      cleanupStack ??= stack;
    }

    try {
      _guest?.close();
    } catch (error, stack) {
      failed(error, stack);
    }
    _guest = null;
    try {
      await _subscription?.cancel();
    } catch (error, stack) {
      failed(error, stack);
    }
    _subscription = null;
    final host = _host;
    _host = null;
    _hostId = null;
    invitation = null;
    invitationExpiresAt = null;
    playbackError = null;
    playbackState = JamPlaybackState.idle;
    unavailablePlaybackOccurrences = const {};
    _retryPlayback = null;
    _addHostMedia = null;
    snapshot = null;
    try {
      try {
        await host?.close();
      } catch (error, stack) {
        failed(error, stack);
      }
    } finally {
      if (!_disposed) _phase(JamAppPhase.idle);
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStack!);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _paused = true;
    if (state == AppLifecycleState.resumed) _paused = false;
    if (state == AppLifecycleState.paused &&
        phase != JamAppPhase.idle &&
        phase != JamAppPhase.closing) {
      if (phase == JamAppPhase.hosting && _leaseConfirmed) return;
      _closeInBackground();
      return;
    }
    if (state == AppLifecycleState.resumed &&
        (phase == JamAppPhase.hosting || phase == JamAppPhase.connected)) {
      final generation = _generation;
      unawaited(_checkNetworkOnResume(generation));
    }
  }

  Future<void> _checkNetworkOnResume(int generation) async {
    try {
      if (!await _network.isGranted() && generation == _generation) {
        await _fail(const LocalNetworkPermissionException());
      }
    } catch (error) {
      if (generation == _generation) await _fail(error);
    }
  }

  @override
  void dispose() {
    if (_disposed || _disposing) return;
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_leaseLossSubscription?.cancel().catchError((_) {}));
    // close() synchronously changes the generation and announces closing.
    // Session-scoped listeners must release private resources before the
    // ChangeNotifier is disposed; subsequent asynchronous notifications are
    // suppressed by _disposed.
    unawaited(close().catchError((_) {}));
    _disposed = true;
    // A listener may dispose the controller while notifyListeners is still
    // iterating. Defer ChangeNotifier's teardown until that stack unwinds.
    scheduleMicrotask(() => super.dispose());
  }
}
