import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';
import 'package:mornye/services/local_network_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = JamEntry(occurrenceId: 'a', trackId: 'track');
  const b = JamEntry(occurrenceId: 'b', trackId: 'track');
  const c = JamEntry(occurrenceId: 'c', trackId: 'other');

  test(
    'host replacement is atomic, retryable and rejects invalid edits',
    () async {
      final session = JamSession(hostId: 'host');
      addTearDown(session.close);
      JamResult submit(JamCommand command) => session.submit(
        authenticatedActorId: command.actorId,
        command: command,
      );
      expect(
        submit(const AddJamEntry('a1', 'host', 0, 'a', 'track')).outcome,
        JamOutcome.applied,
      );
      expect(
        submit(const AddJamEntry('b1', 'host', 1, 'b', 'track')).outcome,
        JamOutcome.applied,
      );
      final events = <JamQueue>[];
      final sub = session.events.listen(events.add);
      addTearDown(sub.cancel);
      final edit = ReplaceHostJamEntries('edit', 'host', 2, [b, a, c]);
      expect(submit(edit).outcome, JamOutcome.applied);
      expect(
        submit(ReplaceHostJamEntries('edit', 'host', 2, [b, a, c])).outcome,
        JamOutcome.duplicate,
      );
      expect(
        submit(ReplaceHostJamEntries('edit', 'host', 2, [a])).outcome,
        JamOutcome.invalid,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(session.snapshot.entries.map((e) => e.occurrenceId), [
        'b',
        'a',
        'c',
      ]);
      final before = session.snapshot;
      expect(
        submit(ReplaceHostJamEntries('bad', 'host', 3, [a, a])).outcome,
        JamOutcome.invalid,
      );
      expect(
        submit(
          ReplaceHostJamEntries('bad2', 'host', 3, [
            const JamEntry(occurrenceId: 'a', trackId: 'changed'),
          ]),
        ).outcome,
        JamOutcome.invalid,
      );
      expect(session.snapshot, same(before));
      session.setPlaybackOccurrences(
        currentOccurrenceId: 'a',
        pendingOccurrenceId: 'b',
      );
      final protected = session.snapshot;
      expect(
        submit(
          ReplaceHostJamEntries('bad3', 'host', protected.revision, [a, c]),
        ).outcome,
        JamOutcome.currentPlaying,
      );
      expect(session.snapshot, same(protected));
    },
  );

  test(
    'guest race conflicts and guest cannot invoke host replacement',
    () async {
      final session = JamSession(hostId: 'host');
      addTearDown(session.close);
      session.submit(
        authenticatedActorId: 'host',
        command: const SetJamGuest('join', 'host', 0, 'guest', true),
      );
      final captured = session.snapshot.revision;
      session.submit(
        authenticatedActorId: 'guest',
        command: AddJamEntry('guest-add', 'guest', captured, 'a', 'track'),
      );
      final stale = session.submit(
        authenticatedActorId: 'host',
        command: ReplaceHostJamEntries('host-edit', 'host', captured, [b]),
      );
      expect(stale.outcome, JamOutcome.conflict);
      expect(stale.state.entries.single.occurrenceId, 'a');
      expect(
        session
            .submit(
              authenticatedActorId: 'guest',
              command: ReplaceHostJamEntries(
                'guest-edit',
                'guest',
                stale.state.revision,
                [b],
              ),
            )
            .outcome,
        JamOutcome.forbidden,
      );
      expect(session.snapshot.entries.single.occurrenceId, 'a');
    },
  );

  test('controller exposes conflict snapshot and atomic host edit', () async {
    final host = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final old = host.snapshot!.revision;
    await host.add(trackId: 'track', occurrenceId: 'a');
    const tokenized = JamEntry(
      occurrenceId: '0123456789abcdefghijklmnopqrstuv',
      trackId: 'track',
    );
    final conflict = host.replaceHostQueue(
      entries: [tokenized],
      expectedRevision: old,
      commandId: 'stale',
    );
    expect(conflict.outcome, JamOutcome.conflict);
    expect(conflict.state.entries.single.occurrenceId, 'a');
    final applied = host.replaceHostQueue(
      entries: [a, tokenized],
      expectedRevision: conflict.state.revision,
      commandId: 'fresh',
    );
    expect(applied.outcome, JamOutcome.applied);
    expect(host.snapshot!.entries.map((e) => e.occurrenceId), [
      'a',
      tokenized.occurrenceId,
    ]);
    final revision = host.snapshot!.revision;
    for (final track in [
      r'C:\secret\music.mp3',
      'https://example.com/song',
      'jamhost1:C:/secret',
    ]) {
      final rejected = host.replaceHostQueue(
        entries: [
          a,
          tokenized,
          JamEntry(
            occurrenceId: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef',
            trackId: track,
          ),
        ],
        expectedRevision: revision,
        commandId: 'path',
      );
      expect(rejected.outcome, JamOutcome.invalid);
      expect(host.snapshot!.revision, revision);
    }
    expect(
      host
          .replaceHostQueue(
            entries: [
              a,
              tokenized,
              const JamEntry(occurrenceId: 'C:/private', trackId: 'track'),
            ],
            expectedRevision: revision,
            commandId: 'path-id',
          )
          .outcome,
      JamOutcome.invalid,
    );
    const valid = JamEntry(
      occurrenceId: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef',
      trackId: 'jamhost1:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef',
    );
    expect(
      host
          .replaceHostQueue(
            entries: [a, tokenized, valid],
            expectedRevision: revision,
            commandId: 'safe',
          )
          .outcome,
      JamOutcome.applied,
    );
    await host.close();
  });

  test(
    'controller retries accepted legacy occurrence after it is removed',
    () async {
      final host = JamAppController(
        networkAccess: LocalNetworkAccess(isAndroid: false),
      );
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      await host.add(trackId: 'legacy', occurrenceId: 'legacy');
      final revision = host.snapshot!.revision;
      const legacy = JamEntry(occurrenceId: 'legacy', trackId: 'legacy');
      JamResult edit() => host.replaceHostQueue(
        entries: [legacy],
        expectedRevision: revision,
        commandId: 'legacy-edit',
      );
      expect(edit().outcome, JamOutcome.applied);
      expect(await host.remove(occurrenceId: 'legacy'), JamOutcome.applied);
      expect(edit().outcome, JamOutcome.duplicate);
      expect(
        host
            .replaceHostQueue(
              entries: [legacy],
              expectedRevision: revision,
              commandId: 'new-stale-edit',
            )
            .outcome,
        JamOutcome.conflict,
      );
      expect(host.snapshot!.entries, isEmpty);
      await host.close();
    },
  );

  test('atomic edit enforces 1000 entries before retry hashing', () async {
    final session = JamSession(hostId: 'host');
    addTearDown(session.close);
    final entries = List.generate(
      1000,
      (i) => JamEntry(occurrenceId: 'occ$i', trackId: 'track'),
    );
    JamResult submit(List<JamEntry> value, String id, int revision) =>
        session.submit(
          authenticatedActorId: 'host',
          command: ReplaceHostJamEntries(id, 'host', revision, value),
        );
    expect(submit(entries, 'large', 0).outcome, JamOutcome.applied);
    expect(submit(List.of(entries), 'large', 0).outcome, JamOutcome.duplicate);
    expect(submit([...entries, c], 'large', 0).outcome, JamOutcome.capacity);
    expect(
      submit([...entries.reversed], 'large', 0).outcome,
      JamOutcome.invalid,
    );
    expect(session.snapshot.entries, hasLength(1000));
  });
}
