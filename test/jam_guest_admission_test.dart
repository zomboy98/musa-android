import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';

void main() {
  late JamSession session;
  setUp(() {
    session = JamSession(hostId: 'host');
    session.submit(
      authenticatedActorId: 'host',
      command: const SetJamGuest('join', 'host', 0, 'guest', true),
    );
  });
  tearDown(() => session.close());
  Future<JamResult> add(AddJamEntry command, {bool Function()? authorized}) =>
      session.submitRemote(
        authenticatedActorId: 'guest',
        command: command,
        isAuthorized: authorized ?? () => true,
      );
  const command = AddJamEntry('add', 'guest', 1, 'entry', 'track');

  test(
    'missing source leaves queue untouched and same ID retries safely',
    () async {
      var available = false;
      var probes = 0;
      session.canResolveGuestTrack = (_) async {
        probes++;
        return available;
      };
      final before = session.snapshot;
      expect((await add(command)).outcome, JamOutcome.unavailable);
      expect(session.snapshot, same(before));
      available = true;
      expect((await add(command)).outcome, JamOutcome.applied);
      available = false;
      expect((await add(command)).outcome, JamOutcome.duplicate);
      expect(probes, 2);
      expect(session.snapshot.entries, hasLength(1));
      expect(
        (await add(
          const AddJamEntry('add', 'guest', 1, 'entry', 'other'),
        )).outcome,
        JamOutcome.invalid,
      );
      expect(probes, 2);
    },
  );

  test('concurrent host mutation wins CAS during probe', () async {
    final gate = Completer<bool>();
    session.canResolveGuestTrack = (_) => gate.future;
    final pending = add(command);
    session.submit(
      authenticatedActorId: 'host',
      command: const AddJamEntry(
        'host-add',
        'host',
        1,
        'host-entry',
        'host-track',
      ),
    );
    gate.complete(true);
    expect((await pending).outcome, JamOutcome.conflict);
    expect(session.snapshot.entries.single.occurrenceId, 'host-entry');
  });

  for (final action in ['revoke', 'close', 'credential', 'cancel']) {
    test('rejects $action during probe', () async {
      final gate = Completer<bool>();
      var authorized = true;
      session.canResolveGuestTrack = (_) => gate.future;
      final pending = add(command, authorized: () => authorized);
      if (action == 'revoke') {
        session.revokeGuest(authenticatedActorId: 'host', guestId: 'guest');
      } else if (action == 'close') {
        await session.close();
      } else {
        authorized = false;
      }
      gate.complete(true);
      expect((await pending).outcome, JamOutcome.forbidden);
      expect(session.snapshot.entries, isEmpty);
    });
  }

  test(
    'probe errors reveal no details and leave same revision retryable',
    () async {
      session.canResolveGuestTrack = (_) async =>
          throw StateError('/private/path');
      final result = await add(command);
      expect(result.outcome, JamOutcome.unavailable);
      expect(result.state.revision, 1);
      expect(result.state.entries, isEmpty);
    },
  );

  test('parallel identical commands commit once', () async {
    final gate = Completer<bool>();
    session.canResolveGuestTrack = (_) => gate.future;
    final first = add(command);
    final second = add(command);
    gate.complete(true);
    expect((await first).outcome, JamOutcome.applied);
    expect((await second).outcome, JamOutcome.duplicate);
    expect(session.snapshot.entries, hasLength(1));
  });

  testWidgets('timeouts retain one probe slot until actual completion', (
    tester,
  ) async {
    final gate = Completer<bool>();
    var calls = 0;
    session.canResolveGuestTrack = (_) {
      calls++;
      return gate.future;
    };
    JamOutcome? outcome;
    for (var i = 0; i < 3; i++) {
      add(command).then((value) => outcome = value.outcome);
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(outcome, JamOutcome.unavailable);
      expect(calls, 1);
      add(
        const AddJamEntry('other', 'guest', 1, 'other', 'other-track'),
      ).then((value) => outcome = value.outcome);
      await tester.pump();
      expect(outcome, JamOutcome.unavailable);
      expect(calls, 1);
    }
    gate.complete(false);
    await tester.pump();
    session.canResolveGuestTrack = (_) async {
      calls++;
      return true;
    };
    add(command).then((value) => outcome = value.outcome);
    await tester.pump();
    expect(outcome, JamOutcome.applied);
    expect(calls, 2);
  });
}
