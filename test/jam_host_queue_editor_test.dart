import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_host_queue_editor.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/local_network_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'registers opaque media before commit and rolls back rejected edits',
    () async {
      final host = _Host();
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      final registry = JamHostTrackRegistry<String>();
      final editor = JamHostQueueEditor(controller: host, registry: registry);
      host.onSubmit = (entries) {
        expect(entries.single.trackId, startsWith('jamhost1:'));
        expect(entries.single.trackId, isNot(contains('private')));
        expect(registry.resolve(entries.single.trackId), 'C:/private/song.mp3');
      };
      final result = editor.edit(
        (draft) => draft.entries.add(draft.create('C:/private/song.mp3')),
      );
      expect(result.outcome, JamOutcome.applied);
      expect(
        registry.resolve(result.state.entries.single.trackId),
        'C:/private/song.mp3',
      );
      String? rejected;
      host.onSubmit = (entries) {
        rejected = entries.last.trackId;
      };
      host.reject = true;
      final failed = editor.edit(
        (draft) => draft.entries.add(draft.create('secret')),
      );
      expect(failed.outcome, JamOutcome.invalid);
      expect(registry.resolve(rejected!), isNull);
      expect(host.snapshot!.entries, hasLength(1));
      await host.close();
      expect(() => editor.edit((draft) {}), throwsStateError);
    },
  );

  test('conflict rebuilds the edit against the returned state', () async {
    final host = _Host();
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final registry = JamHostTrackRegistry<String>();
    final editor = JamHostQueueEditor(controller: host, registry: registry);
    host.conflictOnce = true;
    String? firstToken;
    var attempts = 0;
    host.onSubmit = (entries) {
      attempts++;
      if (attempts == 1) firstToken = entries.last.trackId;
      if (attempts == 2) expect(registry.resolve(firstToken!), isNull);
    };
    final result = editor.edit(
      (draft) => draft.entries.add(draft.create('local')),
    );
    expect(result.outcome, JamOutcome.applied);
    expect(attempts, 2);
    expect(
      result.state.entries.map((e) => e.trackId),
      contains('jamhost1:0123456789abcdefghijklmnopqrstuv'),
    );
    expect(registry.resolve(result.state.entries.last.trackId), 'local');
    await host.close();
  });

  test('rolls back provisional tokens if session ends during submit', () async {
    final host = _Host();
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final registry = JamHostTrackRegistry<String>();
    final editor = JamHostQueueEditor(controller: host, registry: registry);
    String? token;
    host.onSubmit = (entries) {
      token = entries.single.trackId;
      expect(registry.resolve(token!), 'private');
      host.close();
    };
    expect(
      () => editor.edit((d) => d.entries.add(d.create('private'))),
      throwsStateError,
    );
    expect(registry.resolve(token!), isNull);
    await host.close();
  });

  test(
    'reentrant edit commits independently and stale draft retries',
    () async {
      final host = _Host();
      addTearDown(host.dispose);
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      final registry = JamHostTrackRegistry<String>();
      final editor = JamHostQueueEditor(controller: host, registry: registry);
      String? firstToken;
      var entered = false;
      host.onSubmit = (entries) {
        if (!entered) {
          entered = true;
          firstToken = entries.last.trackId;
          expect(registry.resolve(firstToken!), 'outer');
          expect(
            editor.edit((d) => d.entries.add(d.create('inner'))).outcome,
            JamOutcome.applied,
          );
        }
      };
      final result = editor.edit((d) => d.entries.add(d.create('outer')));
      expect(result.outcome, JamOutcome.applied);
      expect(registry.resolve(firstToken!), isNull);
      expect(result.state.entries.map((e) => registry.resolve(e.trackId)), [
        'inner',
        'outer',
      ]);
      expect(
        result.state.entries.every(
          (e) => !e.trackId.contains('outer') && !e.trackId.contains('inner'),
        ),
        isTrue,
      );
      await host.close();
    },
  );
  test('reentrant edit cannot publish an uncommitted token', () async {
    final host = _Host();
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final registry = JamHostTrackRegistry<String>();
    final editor = JamHostQueueEditor(controller: host, registry: registry);
    host.onSubmit = (entries) {
      host.onSubmit = null;
      expect(
        () => editor.edit((d) => d.entries.add(entries.single)),
        throwsStateError,
      );
    };
    expect(
      editor.edit((d) => d.entries.add(d.create('outer'))).outcome,
      JamOutcome.applied,
    );
    await host.close();
  });

  test('removed sources and closed sessions release their registry', () async {
    final host = _Host();
    addTearDown(host.dispose);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    final registry = JamHostTrackRegistry<String>();
    final editor = JamHostQueueEditor(controller: host, registry: registry);
    final first = editor
        .edit((d) => d.entries.add(d.create('first')))
        .state
        .entries
        .single;
    editor.edit((d) => d.entries.clear());
    expect(registry.resolve(first.trackId), isNull);
    final second = editor
        .edit((d) => d.entries.add(d.create('second')))
        .state
        .entries
        .single;
    expect(registry.resolve(second.trackId), 'second');
    await host.close();
    expect(registry.resolve(second.trackId), isNull);
    await host.startHosting(address: InternetAddress.loopbackIPv4);
    expect(
      () => JamHostQueueEditor(controller: host, registry: registry),
      throwsStateError,
    );
    expect(() => editor.edit((d) {}), throwsStateError);
    await host.close();
  });

  test(
    'external removal prunes tokens and direct dispose releases the rest',
    () async {
      final host = _Host();
      await host.startHosting(address: InternetAddress.loopbackIPv4);
      final registry = JamHostTrackRegistry<String>();
      final editor = JamHostQueueEditor(controller: host, registry: registry);
      final first = editor
          .edit((d) => d.entries.add(d.create('first')))
          .state
          .entries
          .single;
      expect(
        await host.remove(occurrenceId: first.occurrenceId),
        JamOutcome.applied,
      );
      expect(registry.resolve(first.trackId), isNull);
      final second = editor
          .edit((d) => d.entries.add(d.create('second')))
          .state
          .entries
          .single;
      var closingNotified = false;
      host.addListener(() {
        if (host.phase == JamAppPhase.closing) closingNotified = true;
      });
      host.dispose();
      expect(closingNotified, isTrue);
      expect(registry.resolve(second.trackId), isNull);
      expect(() => editor.edit((d) {}), throwsStateError);
      await host.close();
    },
  );
}

class _Host extends JamAppController {
  _Host() : super(networkAccess: LocalNetworkAccess(isAndroid: false));
  bool reject = false;
  bool conflictOnce = false;
  void Function(List<JamEntry>)? onSubmit;
  @override
  JamResult replaceHostQueue({
    required List<JamEntry> entries,
    required int expectedRevision,
    required String commandId,
  }) {
    onSubmit?.call(entries);
    if (conflictOnce) {
      conflictOnce = false;
      // A concurrent host command simulates an intervening guest revision.
      super.replaceHostQueue(
        entries: [
          const JamEntry(
            occurrenceId: '0123456789abcdefghijklmnopqrstuv',
            trackId: 'jamhost1:0123456789abcdefghijklmnopqrstuv',
          ),
        ],
        expectedRevision: expectedRevision,
        commandId: 'race',
      );
    }
    if (reject) return JamResult(JamQueue(hostId: 'host'), JamOutcome.invalid);
    return super.replaceHostQueue(
      entries: entries,
      expectedRevision: expectedRevision,
      commandId: commandId,
    );
  }
}
