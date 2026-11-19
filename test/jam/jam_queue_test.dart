import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_queue.dart';

void main() {
  test('host can revoke membership even after its command budget is full', () {
    var state = JamQueue(
      hostId: 'host',
      participants: {'guest': JamRole.guest},
    );
    state = state
        .apply(const AddJamEntry('seed-host', 'host', 0, 'one', 'x'))
        .state;
    for (var i = 1; i < JamQueue.maxAcceptedCommands; i++) {
      final result = state.apply(
        MoveJamEntry('h$i', 'host', state.revision, 'one', null),
      );
      expect(result.outcome, JamOutcome.applied);
      state = result.state;
    }
    expect(
      state
          .apply(SetJamGuest('full', 'host', state.revision, 'guest', false))
          .outcome,
      JamOutcome.capacity,
    );
    expect(
      state
          .revokeGuest(authenticatedActorId: 'guest', guestId: 'guest')
          .outcome,
      JamOutcome.forbidden,
    );
    final revision = state.revision;
    final revoked = state.revokeGuest(
      authenticatedActorId: 'host',
      guestId: 'guest',
    );
    expect(revoked.outcome, JamOutcome.applied);
    expect(revoked.state.revision, revision + 1);
    expect(
      revoked.state
          .apply(
            AddJamEntry(
              'guest-attempt',
              'guest',
              revoked.state.revision,
              'two',
              'x',
            ),
          )
          .outcome,
      JamOutcome.forbidden,
    );
    expect(
      revoked.state
          .apply(const AddJamEntry('seed-host', 'host', 0, 'one', 'x'))
          .outcome,
      JamOutcome.duplicate,
    );
    expect(
      revoked.state
          .revokeGuest(authenticatedActorId: 'guest', guestId: 'guest')
          .outcome,
      JamOutcome.forbidden,
    );
  });
  test('guest command exhaustion preserves host control and retry history', () {
    var state = JamQueue(
      hostId: 'host',
      participants: {'guest': JamRole.guest},
    );
    state = state
        .apply(const AddJamEntry('seed', 'guest', 0, 'one', 'x'))
        .state;
    for (var i = 1; i < JamQueue.maxAcceptedCommands; i++) {
      final result = state.apply(
        MoveJamEntry('g$i', 'guest', state.revision, 'one', null),
      );
      expect(result.outcome, JamOutcome.applied);
      state = result.state;
    }
    expect(
      state
          .apply(MoveJamEntry('overflow', 'guest', state.revision, 'one', null))
          .outcome,
      JamOutcome.capacity,
    );
    expect(
      state.apply(const AddJamEntry('seed', 'guest', 0, 'one', 'x')).outcome,
      JamOutcome.duplicate,
    );
    final policy = state.apply(
      SetGuestEditing('policy', 'host', state.revision, false),
    );
    expect(policy.outcome, JamOutcome.applied);
    final removed = policy.state.apply(
      SetJamGuest('revoke', 'host', policy.state.revision, 'guest', false),
    );
    expect(removed.outcome, JamOutcome.applied);
  });
  JamQueue initial() =>
      JamQueue(hostId: 'host', participants: {'guest': JamRole.guest});

  test('same track can occur twice and removal targets an occurrence', () {
    var state = initial();
    state = state
        .apply(const AddJamEntry('a', 'guest', 0, 'one', 'track'))
        .state;
    state = state
        .apply(const AddJamEntry('b', 'guest', 1, 'two', 'track'))
        .state;
    state = state.apply(const RemoveJamEntry('c', 'host', 2, 'one')).state;
    expect(state.entries.single.occurrenceId, 'two');
    expect(state.revision, 3);
  });

  test(
    'stale concurrent command conflicts without losing accepted entries',
    () {
      final start = initial();
      final first = start
          .apply(const AddJamEntry('a', 'guest', 0, 'one', 'x'))
          .state;
      final stale = first.apply(const AddJamEntry('b', 'host', 0, 'two', 'y'));
      expect(stale.outcome, JamOutcome.conflict);
      expect(stale.state.entries.single.occurrenceId, 'one');
      final retried = stale.state.apply(
        const AddJamEntry('b', 'host', 1, 'two', 'y'),
      );
      expect(retried.state.entries.map((e) => e.occurrenceId), ['one', 'two']);
      expect(retried.state.revision, 2);
    },
  );

  test('retries are idempotent and command IDs cannot be repurposed', () {
    const add = AddJamEntry('a', 'guest', 0, 'one', 'track');
    final state = initial().apply(add).state;
    expect(state.apply(add).outcome, JamOutcome.duplicate);
    expect(
      state.apply(const AddJamEntry('a', 'guest', 0, 'two', 'track')).outcome,
      JamOutcome.invalid,
    );
    expect(
      state.apply(const AddJamEntry('b', 'guest', 1, 'one', 'track')).outcome,
      JamOutcome.invalid,
    );
    expect(state.revision, 1);
  });

  test('host can disable guest editing; unknown actors cannot add', () {
    final state = initial()
        .apply(const AddJamEntry('a', 'guest', 0, 'one', 'x'))
        .state
        .apply(const SetGuestEditing('policy', 'host', 1, false))
        .state;
    expect(
      state.apply(const MoveJamEntry('b', 'guest', 2, 'one', null)).outcome,
      JamOutcome.forbidden,
    );
    expect(
      state.apply(const RemoveJamEntry('c', 'guest', 2, 'one')).outcome,
      JamOutcome.forbidden,
    );
    expect(
      state.apply(const AddJamEntry('d', 'stranger', 2, 'two', 'x')).outcome,
      JamOutcome.forbidden,
    );
    expect(
      () => JamQueue(hostId: 'h', participants: {'other': JamRole.host}),
      throwsArgumentError,
    );
  });

  test('guests can edit by default, but cannot change the policy', () {
    var state = initial();
    state = state.apply(const AddJamEntry('a', 'host', 0, 'one', 'x')).state;
    state = state.apply(const AddJamEntry('b', 'guest', 1, 'two', 'y')).state;
    expect(
      state.apply(const SetGuestEditing('p', 'guest', 2, false)).outcome,
      JamOutcome.forbidden,
    );
    state = state
        .apply(const MoveJamEntry('c', 'guest', 2, 'two', 'one'))
        .state;
    expect(state.entries.map((e) => e.occurrenceId), ['two', 'one']);
    state = state.apply(const RemoveJamEntry('d', 'guest', 3, 'one')).state;
    expect(state.entries.single.occurrenceId, 'two');
    state = state.apply(const SetGuestEditing('e', 'host', 4, false)).state;
    expect(
      state.apply(const SetGuestEditing('f', 'host', 4, true)).outcome,
      JamOutcome.conflict,
    );
    state = state.apply(const SetGuestEditing('f', 'host', 5, true)).state;
    expect(
      state.apply(const RemoveJamEntry('g', 'guest', 6, 'two')).outcome,
      JamOutcome.applied,
    );
  });

  test('host moves entries by occurrence identity', () {
    var state = initial();
    state = state.apply(const AddJamEntry('a', 'host', 0, 'one', 'x')).state;
    state = state.apply(const AddJamEntry('b', 'host', 1, 'two', 'x')).state;
    state = state.apply(const MoveJamEntry('c', 'host', 2, 'two', 'one')).state;
    expect(state.entries.map((e) => e.occurrenceId), ['two', 'one']);
    expect(() => state.entries.clear(), throwsUnsupportedError);
  });
}
