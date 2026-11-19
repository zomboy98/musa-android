import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_library_inventory.dart';
import 'package:mornye/services/jam/jam_host_queue_editor.dart';
import 'package:mornye/services/jam/jam_playback.dart';
import 'package:mornye/services/jam/jam_playback_runtime.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });

  JamAppController host() {
    final controller = JamAppController(
      networkAccess: LocalNetworkAccess(isAndroid: false),
    );
    controller.prepareHostPlayback = (c) => initializeJamLibraryPlayback(
      controller: c,
      runtime: musicPlayerRuntime,
      includeLocalLibrary: () => false,
      fileExists: (_) async => true,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'host add projects the shared registry and clears it on close',
    () async {
      await handler.setQueueAndPlay([testTracks.first]);
      final registry = JamHostTrackRegistry<PlayableMedia>();
      final c = host();
      c.prepareHostPlayback = (controller) => initializeJamLibraryPlayback(
        controller: controller,
        runtime: musicPlayerRuntime,
        includeLocalLibrary: () => false,
        hostRegistry: registry,
        fileExists: (_) async => true,
      );
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      final result = await c.addHostMedia(testTracks[1]);
      expect(result.outcome, JamOutcome.applied);
      final added = c.snapshot!.entries.last;
      expect(added.trackId, matches(r'^jamhost1:[A-Za-z0-9_-]{32}$'));
      expect(registry.resolve(added.trackId), same(testTracks[1]));
      await waitUntil(() => handler.queue.value.length == 2);
      expect(handler.queue.value.map((item) => item.id), ['one', 'two']);
      expect(
        c.snapshot!.entries.toString(),
        isNot(contains(testTracks[1].source)),
      );
      await c.close();
      expect(registry.resolve(added.trackId), isNull);
      expect(() => c.addHostMedia(testTracks[1]), throwsStateError);
    },
  );

  test(
    'invalid host media is rejected before queue or player changes',
    () async {
      await handler.setQueueAndPlay([testTracks.first]);
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      final before = c.snapshot!;
      const remote = PlayableMedia(
        id: 'remote',
        source: 'https://example.test/secret',
        title: 'Remote',
        artist: 'Artist',
      );
      await expectLater(c.addHostMedia(remote), throwsStateError);
      expect(c.snapshot!.revision, before.revision);
      expect(handler.queue.value.map((item) => item.id), ['one']);
      await c.close();
    },
  );

  test('added host occurrence resolves its relocated source', () async {
    await handler.setQueueAndPlay([testTracks.first]);
    final registry = JamHostTrackRegistry<PlayableMedia>();
    final c = host();
    var moved = false;
    var checkedMoved = false;
    c.prepareHostPlayback = (controller) => initializeJamLibraryPlayback(
      controller: controller,
      runtime: musicPlayerRuntime,
      includeLocalLibrary: () => false,
      hostRegistry: registry,
      fileExists: (path) async {
        if (path == testTracks.first.source) return true;
        if (moved) checkedMoved = true;
        return moved
            ? path == '/moved/private-two.flac'
            : path == testTracks[1].source;
      },
    );
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    expect((await c.addHostMedia(testTracks[1])).outcome, JamOutcome.applied);
    final wire = c.snapshot!.entries.last;
    await waitUntil(() => handler.queue.value.length == 2);
    await handler.onSourceRelocated(
      testTracks[1].source,
      '/moved/private-two.flac',
    );
    moved = true;
    await c.setGuestEditing(false);
    await waitUntil(
      () => checkedMoved && c.playbackState == JamPlaybackState.synchronized,
    );
    expect(
      handler.captureJamQueue().entries.last.source,
      '/moved/private-two.flac',
    );
    expect(c.snapshot!.entries.last.trackId, wire.trackId);
    expect(c.snapshot!.entries.toString(), isNot(contains('/moved')));
    await c.close();
    expect(registry.resolve(wire.trackId), isNull);
  });

  test('missing and revoked sources cannot project', () async {
    await handler.setQueueAndPlay([testTracks.first]);
    final c = host();
    var readable = false;
    c.prepareHostPlayback = (controller) => initializeJamLibraryPlayback(
      controller: controller,
      runtime: musicPlayerRuntime,
      includeLocalLibrary: () => false,
      fileExists: (path) async => path == testTracks.first.source || readable,
    );
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    final revision = c.snapshot!.revision;
    await expectLater(c.addHostMedia(testTracks[1]), throwsStateError);
    expect(c.snapshot!.revision, revision);
    readable = true;
    expect((await c.addHostMedia(testTracks[1])).outcome, JamOutcome.applied);
    await waitUntil(() => handler.queue.value.length == 2);
    readable = false;
    await c.setGuestEditing(false);
    await waitUntil(() => c.playbackState == JamPlaybackState.partial);
    expect(handler.queue.value.map((item) => item.id), ['one']);
    readable = true;
    expect(c.retryHostPlayback(), isTrue);
    await waitUntil(() => c.playbackState == JamPlaybackState.synchronized);
    await c.close();
  });

  test('SAF permission is checked on add and subsequent projections', () async {
    await handler.setQueueAndPlay([testTracks.first]);
    final c = host();
    var allowed = true;
    c.prepareHostPlayback = (controller) => initializeJamLibraryPlayback(
      controller: controller,
      runtime: musicPlayerRuntime,
      includeLocalLibrary: () => false,
      fileExists: (_) async => true,
      safCanOpenRead: (_) async => allowed,
    );
    const media = PlayableMedia(
      id: 'saf',
      source: 'content://provider/document/123',
      title: 'Local',
      artist: 'Artist',
    );
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    expect((await c.addHostMedia(media)).outcome, JamOutcome.applied);
    await waitUntil(() => handler.queue.value.length == 2);
    allowed = false;
    await c.setGuestEditing(false);
    await waitUntil(() => c.playbackState == JamPlaybackState.partial);
    await expectLater(c.addHostMedia(media), throwsStateError);
    expect(handler.queue.value.map((item) => item.id), ['one']);
    await c.close();
  });

  test('closing during access check prevents a late addition', () async {
    await handler.setQueueAndPlay([testTracks.first]);
    final c = host();
    final entered = Completer<void>();
    final gate = Completer<bool>();
    c.prepareHostPlayback = (controller) => initializeJamLibraryPlayback(
      controller: controller,
      runtime: musicPlayerRuntime,
      includeLocalLibrary: () => false,
      fileExists: (path) {
        if (path == testTracks.first.source) return Future.value(true);
        entered.complete();
        return gate.future;
      },
    );
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    final pending = c.addHostMedia(testTracks[1]);
    await entered.future;
    await c.close();
    gate.complete(true);
    await expectLater(pending, throwsStateError);
    expect(handler.queue.value.map((item) => item.id), ['one']);
  });

  test(
    'relocated host occurrences retain new sources on the next Jam revision',
    () async {
      await handler.setQueueAndPlay([
        testTracks.first,
        testTracks[1],
        testTracks[1],
      ]);
      await handler.seek(const Duration(seconds: 11));
      await handler.pause();
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      final wire = c.snapshot!.entries
          .map((e) => (e.occurrenceId, e.trackId))
          .toList();
      final source = native.sources['music-player'];
      final position = handler.playbackState.value.position;
      await handler.onSourceRelocated(
        testTracks[1].source,
        '/moved/private-two.flac',
      );
      await handler.onSourceRelocated(
        testTracks.first.source,
        '/moved/private-one.flac',
      );
      expect(await c.setGuestEditing(false), JamOutcome.applied);
      await waitUntil(() => c.playbackState == JamPlaybackState.synchronized);
      expect(handler.captureJamQueue().entries.map((e) => e.source), [
        '/moved/private-one.flac',
        '/moved/private-two.flac',
        '/moved/private-two.flac',
      ]);
      expect(c.snapshot!.entries.map((e) => (e.occurrenceId, e.trackId)), wire);
      expect(wire.toString(), isNot(contains('private-two')));
      expect(native.sources['music-player'], source);
      expect(handler.playbackState.value.position, position);
      expect(handler.playbackState.value.playing, isFalse);
      await c.close();
    },
  );

  test(
    'late failure of startup A cannot clear a newer hosting session B',
    () async {
      final c = host();
      final initialize = c.prepareHostPlayback!;
      final entered = Completer<void>();
      final fail = Completer<void>();
      var starts = 0;
      c.prepareHostPlayback = (controller) async {
        if (++starts == 1) {
          entered.complete();
          await fail.future;
          throw StateError('Late failure of A');
        }
        await initialize(controller);
      };
      final a = c.startHosting(address: InternetAddress.loopbackIPv4);
      await entered.future;
      await c.close();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      final invitation = c.invitation;
      fail.complete();
      await a;
      expect(c.phase, JamAppPhase.hosting);
      expect(c.invitation, same(invitation));
      expect(await c.setGuestEditing(false), JamOutcome.applied);
      c.renewInvitation();
      expect(c.invitation, isNotNull);
      await c.close();
    },
  );

  test(
    'does not publish an invitation before host bootstrap succeeds',
    () async {
      final c = host();
      final entered = Completer<void>();
      final release = Completer<void>();
      final initialize = c.prepareHostPlayback!;
      c.prepareHostPlayback = (controller) async {
        entered.complete();
        await release.future;
        await initialize(controller);
      };
      final starting = c.startHosting(address: InternetAddress.loopbackIPv4);
      await entered.future;
      expect(c.phase, JamAppPhase.starting);
      expect(c.invitation, isNull);
      release.complete();
      await starting;
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      expect(c.playbackState, JamPlaybackState.synchronized);
      expect(c.invitation, isNotNull);
      expect(native.sources, isEmpty);
      await c.close();
    },
  );

  test(
    'imports every occurrence without ISRC, preserving duplicate current and deck',
    () async {
      HttpOverrides.global = null;
      await handler.setQueueAndPlay([
        testTracks.first,
        testTracks[1],
        testTracks.first,
      ], initialIndex: 2);
      await handler.seek(const Duration(seconds: 13));
      await handler.pause();
      final source = native.sources['music-player'];
      final position = handler.playbackState.value.position;
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      expect(c.playbackState, JamPlaybackState.synchronized);
      expect(c.invitation, isNotNull);
      expect(c.snapshot!.entries, hasLength(3));
      expect(
        c.snapshot!.entries.map((e) => e.occurrenceId).toSet(),
        hasLength(3),
      );
      expect(
        c.snapshot!.entries.map((e) => e.trackId),
        everyElement(matches(r'^jamhost1:[A-Za-z0-9_-]{32}$')),
      );
      expect(handler.queue.value.map((e) => e.id), ['one', 'two', 'one']);
      expect(handler.playbackState.value.queueIndex, 2);
      expect(handler.playbackState.value.position, position);
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.sources['music-player'], source);
      await c.close();
      expect(handler.queue.value, hasLength(3));
      expect(native.sources['music-player'], source);
    },
  );

  test(
    'local edits are rejected and advancing protects the new occurrence',
    () async {
      await handler.setQueueAndPlay([testTracks.first, testTracks[1]]);
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.hosting, reason: '${c.error}');
      final entries = c.snapshot!.entries;
      await expectLater(handler.enqueue(testTracks.first), throwsStateError);
      expect(() => handler.moveQueueItem(0, 1), throwsStateError);
      expect(
        () => handler.removeQueuedItem(handler.queue.value[1]),
        throwsStateError,
      );
      expect(handler.queue.value.map((item) => item.id), ['one', 'two']);
      await handler.skipToNext();
      expect(
        await c.remove(occurrenceId: entries[1].occurrenceId),
        JamOutcome.currentPlaying,
      );
      await c.close();
    },
  );

  test(
    'transition protects audible and pending occurrences until source starts',
    () async {
      await handler.setQueueAndPlay([testTracks.first, testTracks[1]]);
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      final entries = c.snapshot!.entries;
      final gate = Completer<void>();
      native.resumeGate = gate;
      final next = handler.skipToNext();
      await waitUntil(() => native.sources['music-player'] == '/two.flac');
      expect(
        await c.remove(occurrenceId: entries[0].occurrenceId),
        JamOutcome.currentPlaying,
      );
      expect(
        await c.remove(occurrenceId: entries[1].occurrenceId),
        JamOutcome.currentPlaying,
      );
      gate.complete();
      await next;
      native.resumeGate = null;
      expect(
        await c.remove(occurrenceId: entries[1].occurrenceId),
        JamOutcome.currentPlaying,
      );
      await c.close();
    },
  );

  test('failed transition keeps both occurrences protected', () async {
    await handler.setQueueAndPlay([testTracks.first, testTracks[1]]);
    final c = host();
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    final entries = c.snapshot!.entries;
    native.failResumeMethod = true;
    await handler.skipToNext();
    expect(handler.queue.value.map((item) => item.id), ['one', 'two']);
    expect(handler.playbackState.value.errorMessage, isNotNull);
    expect(
      await c.remove(occurrenceId: entries[0].occurrenceId),
      JamOutcome.currentPlaying,
    );
    expect(
      await c.remove(occurrenceId: entries[1].occurrenceId),
      JamOutcome.currentPlaying,
    );
    native.failResumeMethod = false;
    await handler.play();
    expect(handler.playbackState.value.errorMessage, isNull);
    expect(
      await c.remove(occurrenceId: entries[0].occurrenceId),
      JamOutcome.applied,
    );
    await c.close();
  });

  test('a removed target is rejected before the player changes', () async {
    await handler.setQueueAndPlay([testTracks.first, testTracks[1]]);
    final c = host();
    await c.startHosting(address: InternetAddress.loopbackIPv4);
    final target = c.snapshot!.entries[1].occurrenceId;
    expect(await c.remove(occurrenceId: target), JamOutcome.applied);
    await handler.skipToNext();
    expect(handler.playbackState.value.queueIndex, 0);
    expect(native.sources['music-player'], '/one.flac');
    await c.close();
  });

  test(
    'unsupported entry rejects all startup before invitation or queue mutation',
    () async {
      HttpOverrides.global = null;
      const unsupported = PlayableMedia(
        id: 'remote',
        source: 'https://example.test/private.flac',
        title: 'Remote',
        artist: 'Artist',
      );
      await handler.setQueueAndPlay([testTracks.first, unsupported]);
      final before = handler.queue.value;
      final source = native.sources['music-player'];
      final c = host();
      await c.startHosting(address: InternetAddress.loopbackIPv4);
      expect(c.phase, JamAppPhase.error);
      expect(c.invitation, isNull);
      expect(handler.queue.value, same(before));
      expect(native.sources['music-player'], source);
    },
  );

  test(
    'captured queue revision rejects a stale startup without changing newer queue',
    () async {
      await handler.setQueueAndPlay([testTracks.first]);
      final captured = handler.captureJamQueue();
      await handler.enqueue(testTracks[1]);
      final before = handler.queue.value;
      final port = RuntimeJamPlaybackPort(
        musicPlayerRuntime,
        initialQueueRevision: captured.revision,
        initialCurrentOccurrenceId: 'one',
      );
      await expectLater(
        port.reconcileQueue([JamPlaybackEntry('one', testTracks.first)]),
        throwsStateError,
      );
      expect(handler.queue.value, same(before));
      await port.closeJamPlayback();
    },
  );
}
