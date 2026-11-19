import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';

void main() {
  test(
    'serialized compare and apply rejects one concurrent stale command',
    () async {
      final session = JamSession(hostId: 'host');
      final results = await Future.wait([
        Future(
          () => session.submit(
            authenticatedActorId: 'host',
            command: const AddJamEntry('a', 'host', 0, 'one', 'x'),
          ),
        ),
        Future(
          () => session.submit(
            authenticatedActorId: 'host',
            command: const AddJamEntry('b', 'host', 0, 'two', 'y'),
          ),
        ),
      ]);
      expect(
        results.map((r) => r.outcome),
        containsAll([JamOutcome.applied, JamOutcome.conflict]),
      );
      expect(session.snapshot.revision, 1);
      expect(session.snapshot.entries.length, 1);
    },
  );

  test(
    'only host admits and revokes; revoked and spoofed actors are rejected',
    () {
      final session = JamSession(hostId: 'host');
      JamResult send(String actor, JamCommand command) =>
          session.submit(authenticatedActorId: actor, command: command);
      expect(
        send('host', const SetJamGuest('a', 'host', 0, 'guest', true)).outcome,
        JamOutcome.applied,
      );
      expect(
        send(
          'guest',
          const SetJamGuest('b', 'guest', 1, 'other', true),
        ).outcome,
        JamOutcome.forbidden,
      );
      expect(
        send('guest', const SetJamGuest('c', 'host', 1, 'other', true)).outcome,
        JamOutcome.forbidden,
      );
      expect(
        send('guest', const AddJamEntry('d', 'guest', 1, 'one', 'x')).outcome,
        JamOutcome.applied,
      );
      expect(
        send('host', const SetJamGuest('e', 'host', 2, 'guest', false)).outcome,
        JamOutcome.applied,
      );
      expect(
        send('guest', const AddJamEntry('f', 'guest', 3, 'two', 'x')).outcome,
        JamOutcome.forbidden,
      );
      expect(session.snapshot.entries.single.occurrenceId, 'one');
    },
  );

  test('session limits reject excess members and overlong identities', () {
    final session = JamSession(hostId: 'host');
    for (var i = 0; i < JamQueue.maxParticipants - 1; i++) {
      expect(
        session
            .submit(
              authenticatedActorId: 'host',
              command: SetJamGuest('c$i', 'host', i, 'guest$i', true),
            )
            .outcome,
        JamOutcome.applied,
      );
    }
    expect(
      session
          .submit(
            authenticatedActorId: 'host',
            command: SetJamGuest(
              'overflow',
              'host',
              session.snapshot.revision,
              'extra',
              true,
            ),
          )
          .outcome,
      JamOutcome.capacity,
    );
    expect(
      session
          .submit(
            authenticatedActorId: 'host',
            command: SetJamGuest(
              'long',
              'host',
              session.snapshot.revision,
              'x' * 257,
              true,
            ),
          )
          .outcome,
      JamOutcome.invalid,
    );
  });
}
