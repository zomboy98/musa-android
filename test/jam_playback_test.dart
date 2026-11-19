import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_coordinator.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_playback.dart';
import 'package:mornye/services/jam/jam_queue.dart';

class _Resolver implements JamTrackResolver<Object> {
  @override
  Future<Object?> resolveLocal(String trackId) async =>
      trackId == 'missing' ? null : 'local:$trackId';
}

class _Port implements JamPlaybackPort<Object> {
  final snapshots = <List<JamPlaybackEntry<Object>>>[];
  final current = 'existing';
  final position = const Duration(seconds: 42);
  bool playing = false;
  @override
  Future<void> reconcileQueue(List<JamPlaybackEntry<Object>> entries) async {
    snapshots.add(entries);
  }
}

class _BlockingPort implements JamPlaybackPort<Object> {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> reconcileQueue(List<JamPlaybackEntry<Object>> entries) async {
    entered.complete();
    await release.future;
  }
}

class _FirstBlockingPort implements JamPlaybackPort<Object> {
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<void> reconcileQueue(List<JamPlaybackEntry<Object>> entries) async {
    if (calls++ == 0) {
      entered.complete();
      await release.future;
    }
  }
}

class _RecoveringResolver implements JamTrackResolver<Object> {
  bool available = false;
  @override
  Future<Object?> resolveLocal(String trackId) async =>
      available ? 'local:$trackId' : null;
}

void main() {
  test(
    'missing current or pending occurrence never changes the player',
    () async {
      for (final pending in [false, true]) {
        final events = StreamController<JamQueue>.broadcast();
        final queue = JamQueue(hostId: 'host')
            .apply(const AddJamEntry('a', 'host', 0, 'one', 'song'))
            .state
            .apply(const AddJamEntry('b', 'host', 1, 'two', 'missing'))
            .state;
        final protected = queue
            .setPlaybackOccurrences(
              currentOccurrenceId: pending ? 'one' : 'two',
              pendingOccurrenceId: pending ? 'two' : null,
            )
            .state;
        final port = _Port();
        final unavailable = <Set<String>>[];
        final errors = <Object>[];
        final binding = JamPlaybackBinding<Object>(
          events: events.stream,
          initial: protected,
          resolver: _Resolver(),
          port: port,
          onAvailability: (_, ids) => unavailable.add(ids),
          onError: (error, _) => errors.add(error),
        );
        await binding.settled;
        expect(port.snapshots, isEmpty);
        expect(unavailable.single, {'two'});
        expect(errors, hasLength(1));
        expect(protected.entries.map((e) => e.occurrenceId), ['one', 'two']);
        expect(protected.pendingOccurrenceId, pending ? 'two' : null);
        await binding.close();
        await events.close();
      }
    },
  );
  test(
    'retry reconciles the same failed revision without changing the queue',
    () async {
      final events = StreamController<JamQueue>.broadcast();
      final resolver = _RecoveringResolver();
      final port = _Port();
      final pending = <int>[];
      final success = <int>[];
      final initial = JamQueue(
        hostId: 'host',
      ).apply(const AddJamEntry('a', 'host', 0, 'one', 'song')).state;
      var authoritativeRevision = initial.revision;
      final binding = JamPlaybackBinding<Object>(
        events: events.stream,
        initial: initial,
        resolver: resolver,
        port: port,
        currentRevision: () => authoritativeRevision,
        onPending: pending.add,
        onSuccess: success.add,
      );
      expect(pending, [1]);
      await binding.settled;
      expect(port.snapshots.single, isEmpty);
      resolver.available = true;
      expect(binding.retry(), isTrue);
      expect(binding.retry(), isFalse);
      await binding.settled;
      expect(success, [1]);
      expect(pending, [1, 1]);
      expect(port.snapshots.last.single.occurrenceId, 'one');
      expect(initial.revision, 1);
      expect(binding.retry(), isFalse);
      await binding.close();
      await events.close();
    },
  );

  test(
    'retry rejects a failed revision already superseded at the authority',
    () async {
      final events = StreamController<JamQueue>.broadcast();
      final resolver = _RecoveringResolver();
      final initial = JamQueue(
        hostId: 'host',
      ).apply(const AddJamEntry('a', 'host', 0, 'one', 'song')).state;
      var authoritativeRevision = initial.revision;
      final port = _Port();
      final binding = JamPlaybackBinding<Object>(
        events: events.stream,
        initial: initial,
        resolver: resolver,
        port: port,
        currentRevision: () => authoritativeRevision,
      );
      await binding.settled;
      authoritativeRevision = 2;
      resolver.available = true;
      expect(binding.retry(), isFalse);
      expect(port.snapshots.single, isEmpty);
      await binding.close();
      await events.close();
    },
  );

  test('superseded projection cannot report success', () async {
    final events = StreamController<JamQueue>.broadcast();
    final port = _FirstBlockingPort();
    final successes = <int>[];
    final initial = JamQueue(hostId: 'host');
    final binding = JamPlaybackBinding<Object>(
      events: events.stream,
      initial: initial,
      resolver: _Resolver(),
      port: port,
      onSuccess: successes.add,
    );
    await port.entered.future;
    events.add(
      initial.apply(const AddJamEntry('a', 'host', 0, 'one', 'song')).state,
    );
    await Future<void>.delayed(Duration.zero);
    port.release.complete();
    await binding.settled;
    expect(successes, [1]);
    await binding.close();
    await events.close();
  });
  test('concurrent close calls wait for in-flight reconciliation', () async {
    final events = StreamController<JamQueue>.broadcast();
    final port = _BlockingPort();
    final binding = JamPlaybackBinding<Object>(
      events: events.stream,
      initial: JamQueue(hostId: 'host'),
      resolver: _Resolver(),
      port: port,
    );
    await port.entered.future;
    var completed = false;
    final first = binding.close();
    final second = binding.close();
    expect(identical(first, second), isTrue);
    second.then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    port.release.complete();
    await Future.wait([first, second]);
    expect(completed, isTrue);
    await events.close();
  });

  test('throwing error observer does not block a later snapshot', () async {
    final events = StreamController<JamQueue>.broadcast();
    final port = _Port();
    final binding = JamPlaybackBinding<Object>(
      events: events.stream,
      initial: JamQueue(hostId: 'host'),
      resolver: _Resolver(),
      port: port,
      onError: (_, _) => throw StateError('observer failed'),
    );
    await binding.settled;
    final missing = JamQueue(
      hostId: 'host',
    ).apply(const AddJamEntry('a', 'host', 0, 'one', 'missing')).state;
    events.add(missing);
    await Future<void>.delayed(Duration.zero);
    await binding.settled;
    final recovered = missing
        .apply(const RemoveJamEntry('b', 'host', 1, 'one'))
        .state;
    events.add(recovered);
    await Future<void>.delayed(Duration.zero);
    await binding.settled;
    expect(port.snapshots, hasLength(3));
    expect(port.snapshots.last, isEmpty);
    await binding.close();
    await events.close();
  });

  test('ephemeral coordinator pairs with pin and shares its queue', () async {
    final coordinator = await JamCoordinator.startEphemeral(hostId: 'host');
    addTearDown(coordinator.close);
    final invitation = coordinator.server.issueInvitation();
    expect(invitation.endpoint.host, '127.0.0.1');
    final client = JamPinnedClient(
      invitation.endpoint,
      invitation.certificateSha256,
    );
    addTearDown(client.close);
    final response = await client.send(
      'POST',
      '/pair',
      body: utf8.encode(jsonEncode({'grant': invitation.grant})),
    );
    expect(response.statusCode, 200);
    final body = jsonDecode(utf8.decode(response.body)) as Map<String, dynamic>;
    expect(body['credential'], isNotEmpty);
    expect(coordinator.snapshot.revision, 1);
  });

  test(
    'host port projects duplicates and reports unavailable occurrences',
    () async {
      final coordinator = await JamCoordinator.startEphemeral(hostId: 'host');
      addTearDown(coordinator.close);
      final port = _Port();
      final errors = <Object>[];
      final unavailable = <Set<String>>[];
      final binding = coordinator.attachPlayback(
        resolver: _Resolver(),
        port: port,
        onError: (e, _) => errors.add(e),
        onAvailability: (_, ids) => unavailable.add(ids),
      );
      await binding.settled;
      coordinator.submitHost(const AddJamEntry('a', 'host', 0, 'one', 'song'));
      coordinator.submitHost(const AddJamEntry('b', 'host', 1, 'two', 'song'));
      await Future<void>.delayed(Duration.zero);
      await binding.settled;
      expect(port.snapshots.last.map((e) => e.occurrenceId), ['one', 'two']);
      expect(port.snapshots.last.map((e) => e.track), [
        'local:song',
        'local:song',
      ]);
      expect(port.current, 'existing');
      expect(port.position, const Duration(seconds: 42));
      expect(port.playing, isFalse);
      final count = port.snapshots.length;
      coordinator.submitHost(
        const AddJamEntry('c', 'host', 2, 'three', 'missing'),
      );
      await Future<void>.delayed(Duration.zero);
      await binding.settled;
      expect(errors, isEmpty);
      expect(port.snapshots, hasLength(count + 1));
      expect(port.snapshots.last.map((e) => e.occurrenceId), ['one', 'two']);
      expect(unavailable.last, {'three'});
      await coordinator.close();
      expect(
        () => coordinator.attachPlayback(resolver: _Resolver(), port: port),
        throwsStateError,
      );
    },
  );
}
