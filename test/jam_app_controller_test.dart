import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_playback.dart';
import 'package:mornye/services/local_network_access.dart';
import 'support/jam_track_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'background close reports cleanup errors without an unhandled future',
    () async {
      final reported = Completer<FlutterErrorDetails>();
      final previousHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!reported.isCompleted) reported.complete(details);
      };
      addTearDown(() => FlutterError.onError = previousHandler);
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
      );
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      final port = _FailingClosePort();
      await host
          .attachHostPlayback<String>(resolver: _Resolver(), port: port)
          .settled;
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      final details = await reported.future.timeout(const Duration(seconds: 5));
      expect(details.exception, isA<StateError>());
      expect(details.library, 'Jam');
      expect(port.closed, isTrue);
    },
  );

  test(
    'idle notification cannot start a session while close is pending',
    () async {
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
      );
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      Future<void>? attempt;
      host.addListener(() {
        if (host.phase == JamAppPhase.idle && attempt == null) {
          attempt = host.startHosting(address: InternetAddress.loopbackIPv4);
          attempt!.ignore();
        }
      });
      await host.close();
      await expectLater(attempt, throwsStateError);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      expect(host.phase, JamAppPhase.hosting);
      await host.close();
    },
  );

  test('dispose handles a playback cleanup failure', () async {
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final port = _FailingClosePort();
    final binding = host.attachHostPlayback<String>(
      resolver: _Resolver(),
      port: port,
    );
    await binding.settled;
    host.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(port.closed, isTrue);
    expect(host.snapshot, isNull);
  });

  test('close is guarded before notifying reentrant listeners', () async {
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    Future<void>? nested;
    var closingNotifications = 0;
    host.addListener(() {
      if (host.phase == JamAppPhase.closing) {
        closingNotifications++;
        nested = host.close();
      }
    });
    final outer = host.close();
    expect(identical(nested, outer), isTrue);
    await outer;
    expect(closingNotifications, 1);
    expect(host.phase, JamAppPhase.idle);
  });

  test('dispose during notification completes safely and only once', () async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    var closing = 0;
    host.addListener(() {
      if (host.phase == JamAppPhase.closing) closing++;
      host.dispose();
    });
    // This notification invokes dispose, which itself announces closing.
    host.renewInvitation();
    await host.close();
    await Future<void>.delayed(Duration.zero);
    expect(closing, 1);
    expect(errors, isEmpty);
  });

  test('host and guest pair and edit the authoritative queue', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final network = LocalNetworkAccess(isAndroid: false);
    final now = DateTime(2026, 1, 1);
    final host = JamAppController(networkAccess: network, now: () => now);
    final resolver = _GuestResolver();
    final guest = JamAppController(networkAccess: network);
    addTearDown(host.dispose);
    addTearDown(guest.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    expect(host.phase, JamAppPhase.hosting);
    expect(host.invitationExpiresAt, now.add(const Duration(minutes: 2)));
    await guest.join(host.invitation!);
    expect(guest.phase, JamAppPhase.connected);
    final oldGrant = host.invitation!.grant;
    host.renewInvitation();
    expect(host.invitation!.grant, isNot(oldGrant));
    final revision = guest.snapshot!.revision;
    // Product sessions fail closed until a host source probe is attached.
    expect(
      await guest.add(trackId: jamTestTrack('track-1')),
      JamOutcome.unavailable,
    );
    expect(guest.snapshot!.revision, revision);
    expect(guest.snapshot!.entries, isEmpty);
    final binding = host.attachHostPlayback<String>(
      resolver: resolver,
      port: _Port(),
    );
    expect(
      await guest.add(
        trackId: jamTestTrack('track-1'),
        occurrenceId: 'occ-1',
        commandId: 'cmd-1',
        revision: revision,
      ),
      JamOutcome.unavailable,
    );
    resolver.available = true;
    expect(
      await guest.add(
        trackId: jamTestTrack('track-1'),
        occurrenceId: 'occ-1',
        commandId: 'cmd-1',
        revision: revision,
      ),
      JamOutcome.applied,
    );
    expect(
      await guest.add(
        trackId: jamTestTrack('track-1'),
        occurrenceId: 'occ-1',
        commandId: 'cmd-1',
        revision: revision,
      ),
      JamOutcome.duplicate,
    );
    await Future<void>.delayed(Duration.zero);
    expect(host.snapshot!.entries.single.trackId, jamTestTrack('track-1'));
    await binding.settled;
    expect(host.playbackState, JamPlaybackState.synchronized);
    final occurrence = guest.snapshot!.entries.single.occurrenceId;
    expect(await guest.remove(occurrenceId: occurrence), JamOutcome.applied);
    await host.close();
    await guest.close();
    expect(host.phase, JamAppPhase.idle);
    expect(guest.snapshot, isNull);
    expect(host.invitation, isNull);
    expect(host.invitationExpiresAt, isNull);
  });

  test('invitation capacity error preserves the current invitation', () async {
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    for (var i = 0; i < 31; i++) {
      host.renewInvitation();
    }
    final invitation = host.invitation;
    final deadline = host.invitationExpiresAt;
    expect(host.renewInvitation, throwsStateError);
    expect(host.invitation, same(invitation));
    expect(host.invitationExpiresAt, deadline);
    await host.close();
  });

  test(
    'host defaults to authoritative revision but honors explicit revision',
    () async {
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
      );
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      final staleProjection = host.snapshot!;
      expect(
        await host.add(trackId: 'one', occurrenceId: 'one'),
        JamOutcome.applied,
      );

      // Model a queued coordinator event that has not reached the view yet.
      host.snapshot = staleProjection;
      expect(
        await host.add(trackId: 'two', occurrenceId: 'two'),
        JamOutcome.applied,
      );
      expect(host.snapshot!.entries.map((e) => e.occurrenceId), ['one', 'two']);

      host.snapshot = staleProjection;
      expect(await host.setGuestEditing(false), JamOutcome.applied);
      expect(host.snapshot!.guestEditingEnabled, isFalse);
      expect(
        await host.add(trackId: 'three', revision: staleProjection.revision),
        JamOutcome.conflict,
      );
      await host.close();
    },
  );

  test(
    'resume permission check failure closes session and reports error',
    () async {
      final network = _FailingCheckNetwork();
      final host = JamAppController(networkAccess: network);
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      expect(host.phase, JamAppPhase.hosting);
      final reported = Completer<void>();
      host.addListener(() {
        if (host.phase == JamAppPhase.error && !reported.isCompleted) {
          reported.complete();
        }
      });
      host.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await reported.future.timeout(const Duration(seconds: 5));
      expect(host.error, isA<StateError>());
      expect(host.invitation, isNull);
      expect(host.snapshot, isNull);
    },
  );

  test('backgrounding closes the session and discards invitation', () async {
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final closed = Completer<void>();
    host.addListener(() {
      if (host.phase == JamAppPhase.idle && !closed.isCompleted) {
        closed.complete();
      }
    });
    host.didChangeAppLifecycleState(AppLifecycleState.paused);
    await closed.future.timeout(const Duration(seconds: 5));
    expect(host.invitation, isNull);
    expect(host.snapshot, isNull);
  });

  test(
    'confirmed host lease survives pause and is released on close',
    () async {
      final stopped = <String>[];
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
        startBackgroundLease: (_) async => true,
        stopBackgroundLease: (token) async {
          stopped.add(token);
        },
      );
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(host.phase, JamAppPhase.hosting);
      await host.close();
      expect(stopped, hasLength(1));
    },
  );

  test(
    'loss of confirmed lease closes a paused host; stale loss is ignored',
    () async {
      final losses = StreamController<String>.broadcast(sync: true);
      String? token;
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
        startBackgroundLease: (value) async {
          token = value;
          return true;
        },
        stopBackgroundLease: (_) async {},
        backgroundLeaseLosses: losses.stream,
      );
      addTearDown(() async {
        host.dispose();
        await losses.close();
      });
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      losses.add('old-generation');
      expect(host.phase, JamAppPhase.hosting);
      final closed = Completer<void>();
      host.addListener(() {
        if (host.phase == JamAppPhase.idle && !closed.isCompleted)
          closed.complete();
      });
      losses.add(token!);
      await closed.future.timeout(const Duration(seconds: 5));
      expect(host.invitation, isNull);
    },
  );

  test('lease loss while visible closes on later pause', () async {
    final losses = StreamController<String>.broadcast(sync: true);
    String? token;
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
      startBackgroundLease: (value) async {
        token = value;
        return true;
      },
      stopBackgroundLease: (_) async {},
      backgroundLeaseLosses: losses.stream,
    );
    addTearDown(() async {
      host.dispose();
      await losses.close();
    });
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    losses.add(token!);
    expect(host.phase, JamAppPhase.hosting);
    final closed = Completer<void>();
    host.addListener(() {
      if (host.phase == JamAppPhase.idle && !closed.isCompleted)
        closed.complete();
    });
    host.didChangeAppLifecycleState(AppLifecycleState.paused);
    await closed.future.timeout(const Duration(seconds: 5));
    expect(host.invitation, isNull);
  });

  test('event channel failure retains lease token for close', () async {
    final losses = StreamController<String>.broadcast(sync: true);
    String? token;
    final stopped = <String>[];
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
      startBackgroundLease: (value) async {
        token = value;
        return true;
      },
      stopBackgroundLease: (value) async {
        stopped.add(value);
      },
      backgroundLeaseLosses: losses.stream,
    );
    addTearDown(() async {
      host.dispose();
      await losses.close();
    });
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    host.didChangeAppLifecycleState(AppLifecycleState.paused);
    final closed = Completer<void>();
    host.addListener(() {
      if (host.phase == JamAppPhase.idle && !closed.isCompleted)
        closed.complete();
    });
    losses.addError(StateError('event channel unavailable'));
    await closed.future.timeout(const Duration(seconds: 5));
    expect(stopped, [token]);
  });

  test(
    'pause during pending lease closes and releases late confirmation',
    () async {
      final pending = Completer<bool>();
      final started = Completer<void>();
      final stopped = <String>[];
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
        startBackgroundLease: (_) {
          started.complete();
          return pending.future;
        },
        stopBackgroundLease: (token) async {
          stopped.add(token);
        },
      );
      addTearDown(host.dispose);
      final start = host.startHosting(address: InternetAddress.loopbackIPv4);
      await started.future;
      host.didChangeAppLifecycleState(AppLifecycleState.paused);
      pending.complete(true);
      await start;
      await host.close();
      expect(host.phase, JamAppPhase.idle);
      expect(stopped, isNotEmpty);
      expect(host.invitation, isNull);
    },
  );

  test(
    'host playback injection resolves local tracks and rejects missing sources',
    () async {
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
      );
      final port = _Port();
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      host.attachHostPlayback<String>(resolver: _Resolver(), port: port);
      await port.updated.future.timeout(const Duration(seconds: 5));
      port.updated = Completer<void>();
      expect(await host.add(trackId: 'local'), JamOutcome.applied);
      await port.updated.future.timeout(const Duration(seconds: 5));
      expect(port.entries.single.track, 'local source');
      final partial = Completer<void>();
      host.addListener(() {
        if (host.playbackState == JamPlaybackState.partial &&
            !partial.isCompleted)
          partial.complete();
      });
      expect(await host.add(trackId: 'missing'), JamOutcome.applied);
      await partial.future.timeout(const Duration(seconds: 5));
      expect(port.entries.single.track, 'local source');
      expect(host.unavailablePlaybackOccurrences, {
        host.snapshot!.entries.last.occurrenceId,
      });
      final existingError = host.playbackError;
      expect(
        () => host.attachHostPlayback<String>(
          resolver: _Resolver(),
          port: _Port(),
        ),
        throwsStateError,
      );
      expect(host.playbackError, same(existingError));
      final recovered = Completer<void>();
      host.addListener(() {
        if (host.playbackState == JamPlaybackState.synchronized &&
            !recovered.isCompleted) {
          recovered.complete();
        }
      });
      final missing = host.snapshot!.entries.last.occurrenceId;
      expect(await host.remove(occurrenceId: missing), JamOutcome.applied);
      await recovered.future.timeout(const Duration(seconds: 5));
      expect(host.playbackError, isNull);
      await host.close();
      expect(port.closed, isTrue);
    },
  );
}

class _FailingCheckNetwork extends LocalNetworkAccess {
  _FailingCheckNetwork() : super(isAndroid: false);
  @override
  Future<void> ensureGranted() async {}
  @override
  Future<bool> isGranted() async => throw StateError('platform failure');
}

class _Resolver implements JamTrackResolver<String> {
  @override
  Future<String?> resolveLocal(String trackId) async =>
      trackId == 'local' ? 'local source' : null;
}

class _GuestResolver implements JamTrackResolver<String> {
  bool available = false;
  @override
  Future<String?> resolveLocal(String trackId) async =>
      available ? 'authorized local source' : null;
}

class _FailingClosePort
    implements JamPlaybackPort<String>, JamPlaybackLifecycle {
  bool closed = false;
  @override
  Future<void> reconcileQueue(List<JamPlaybackEntry<String>> entries) async {}
  @override
  Future<void> closeJamPlayback() async {
    closed = true;
    throw StateError('cleanup failed');
  }
}

class _Port implements JamPlaybackPort<String>, JamPlaybackLifecycle {
  Completer<void> updated = Completer<void>();
  List<JamPlaybackEntry<String>> entries = [];
  bool closed = false;
  @override
  Future<void> reconcileQueue(List<JamPlaybackEntry<String>> value) async {
    entries = value;
    if (!updated.isCompleted) updated.complete();
  }

  @override
  Future<void> closeJamPlayback() async {
    closed = true;
  }
}
