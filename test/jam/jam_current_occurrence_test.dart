import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_guest_client.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';

void main() {
  test(
    'transition protects both tracks until playback confirms or fails',
    () async {
      final session = JamSession(hostId: 'host');
      JamResult submit(JamCommand command) => session.submit(
        authenticatedActorId: command.actorId,
        command: command,
      );
      submit(const AddJamEntry('a', 'host', 0, 'a', 'track'));
      submit(const AddJamEntry('b', 'host', 1, 'b', 'track'));
      session.setCurrentOccurrence('a');
      final before = session.snapshot.revision;
      expect(
        session
            .setPlaybackOccurrences(
              currentOccurrenceId: 'a',
              pendingOccurrenceId: 'b',
            )
            .outcome,
        JamOutcome.applied,
      );
      expect(
        submit(RemoveJamEntry('stale', 'host', before, 'b')).outcome,
        JamOutcome.conflict,
      );
      for (final id in ['a', 'b']) {
        expect(
          submit(
            RemoveJamEntry('remove-$id', 'host', session.snapshot.revision, id),
          ).outcome,
          JamOutcome.currentPlaying,
        );
      }
      expect(
        session
            .setPlaybackOccurrences(
              currentOccurrenceId: 'a',
              pendingOccurrenceId: 'missing',
            )
            .outcome,
        JamOutcome.invalid,
      );
      expect(session.snapshot.pendingOccurrenceId, 'b');
      session.setPlaybackOccurrences(currentOccurrenceId: 'b');
      expect(
        submit(
          RemoveJamEntry('old', 'host', session.snapshot.revision, 'a'),
        ).outcome,
        JamOutcome.applied,
      );
      expect(
        submit(
          RemoveJamEntry('new', 'host', session.snapshot.revision, 'b'),
        ).outcome,
        JamOutcome.currentPlaying,
      );
      await session.close();
    },
  );
  test('current playback and queue edits share one atomic revision', () async {
    final session = JamSession(hostId: 'host');
    JamResult submit(JamCommand command) =>
        session.submit(authenticatedActorId: command.actorId, command: command);
    submit(const SetJamGuest('g', 'host', 0, 'guest', true));
    submit(const AddJamEntry('a', 'host', 1, 'one', 'track'));
    submit(const AddJamEntry('b', 'host', 2, 'two', 'track'));
    expect(session.setCurrentOccurrence('one').outcome, JamOutcome.applied);
    final revision = session.snapshot.revision;
    for (final actor in ['host', 'guest']) {
      final result = submit(
        RemoveJamEntry('remove-$actor', actor, revision, 'one'),
      );
      expect(result.outcome, JamOutcome.currentPlaying);
      expect(result.state.revision, revision);
      expect(result.state.entries.length, 2);
    }
    expect(session.setCurrentOccurrence('missing').outcome, JamOutcome.invalid);
    expect(session.setCurrentOccurrence('two').outcome, JamOutcome.applied);
    expect(
      submit(RemoveJamEntry('stale', 'guest', revision, 'two')).outcome,
      JamOutcome.conflict,
    );
    expect(
      submit(
        RemoveJamEntry('current', 'guest', session.snapshot.revision, 'two'),
      ).outcome,
      JamOutcome.currentPlaying,
    );
    expect(
      submit(
        RemoveJamEntry('old', 'guest', session.snapshot.revision, 'one'),
      ).outcome,
      JamOutcome.applied,
    );
    await session.close();
  });

  test('guest snapshot validates current occurrence', () {
    final json = <String, dynamic>{
      'revision': 1,
      'guestEditingEnabled': true,
      'currentOccurrenceId': 'one',
      'entries': [
        {'occurrenceId': 'one', 'trackId': 'track'},
      ],
    };
    expect(JamGuestSnapshot.fromJson(json).currentOccurrenceId, 'one');
    json['currentOccurrenceId'] = 'missing';
    expect(() => JamGuestSnapshot.fromJson(json), throwsFormatException);
  });
}
