import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_playback.dart';
import 'package:mornye/services/jam/jam_playback_runtime.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_playback_deck.dart';

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();

  test(
    'local reconciliation preserves playback and rejects atomically',
    () async {
      final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
      await handler.setQueueAndPlay([testTracks.first]);
      await handler.seek(const Duration(seconds: 12));
      await handler.pause();
      final source = native.sources['music-player'];
      final position = handler.playbackState.value.position;
      final item = handler.mediaItem.value;
      await port.reconcileQueue([
        JamPlaybackEntry('current', testTracks.first),
        JamPlaybackEntry('other-1', testTracks[1]),
        JamPlaybackEntry('other-2', testTracks[1]),
      ]);
      expect(handler.mediaItem.value, same(item));
      expect(native.sources['music-player'], source);
      expect(handler.playbackState.value.position, position);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.queue.value.map((e) => e.extras?['jamOccurrenceId']), [
        'current',
        'other-1',
        'other-2',
      ]);
      final before = handler.queue.value;
      await expectLater(
        port.reconcileQueue([JamPlaybackEntry('other', testTracks[1])]),
        throwsStateError,
      );
      expect(handler.queue.value, same(before));
      expect(handler.mediaItem.value, same(item));
      expect(native.sources['music-player'], source);
    },
  );

  test('empty player accepts queue without starting audio', () async {
    final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
    await port.reconcileQueue([JamPlaybackEntry('one', testTracks.first)]);
    expect(handler.mediaItem.value, isNull);
    expect(handler.playbackState.value.playing, isFalse);
    expect(native.sources, isEmpty);
  });

  test(
    'Jam suppresses autoplay ticks and restores the configured setting',
    () async {
      final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
      await handler.setQueueAndPlay([testTracks.first]);
      await port.reconcileQueue([JamPlaybackEntry('one', testTracks.first)]);
      setAutoplayEnabled(true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(handler.queue.value.map((item) => item.id), ['one']);
      await port.closeJamPlayback();
      await waitUntil(() => handler.queue.value.length > 1);
      expect(musicPlayerRuntime.settings.autoplay, isTrue);
    },
  );

  test('Jam cancels a prepared AutoMix and restores its setting', () async {
    for (final track in testTracks) {
      native.durations[track.source] = const Duration(
        minutes: 4,
      ).inMilliseconds;
    }
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(testTracks);
    await handler.seek(const Duration(seconds: 100));
    await waitUntil(() => analyzer.calls.length >= 2);
    final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
    await port.reconcileQueue([
      JamPlaybackEntry('one', testTracks.first),
      JamPlaybackEntry('three', testTracks.last),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(handler.mediaItem.value?.id, 'one');
    expect(handler.queue.value.map((item) => item.id), ['one', 'three']);
    expect(native.sources['music-player'], '/one.flac');
    await port.closeJamPlayback();
    expect(musicPlayerRuntime.settings.autoMix, isTrue);
  });
  test('invalid initial snapshot leaves autoplay active', () async {
    await handler.setQueueAndPlay([testTracks.first]);
    final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
    await expectLater(
      port.reconcileQueue([JamPlaybackEntry('other', testTracks.last)]),
      throwsStateError,
    );
    setAutoplayEnabled(true);
    await waitUntil(() => handler.queue.value.length > 1);
    await port.closeJamPlayback();
  });

  for (final pending in [false, true]) {
    test('Jam rejects uncertain native transition pending=$pending', () async {
      AudioplayersPlaybackDeck.debugChainsPlayers = true;
      addTearDown(() => AudioplayersPlaybackDeck.debugChainsPlayers = null);
      setGaplessEnabled(true);
      if (pending) native.nextPlayerGate = Completer<void>();
      await handler.setQueueAndPlay(testTracks);
      await waitUntil(() => handler.mediaItem.value?.duration != null);
      await handler.seek(const Duration(seconds: 45));
      await waitUntil(() => native.calls.any((c) => c.$2 == 'setNextPlayer'));
      if (!pending) await waitUntil(() => native.nextPlayers.isNotEmpty);
      final original = handler.queue.value;
      final port = RuntimeJamPlaybackPort(musicPlayerRuntime);
      await expectLater(
        port.reconcileQueue([
          JamPlaybackEntry('one', testTracks.first),
          JamPlaybackEntry('three', testTracks.last),
        ]),
        throwsStateError,
      );
      expect(handler.queue.value, same(original));
      expect(native.sources['music-player'], '/one.flac');
      if (pending) native.nextPlayerGate!.complete();
      await port.closeJamPlayback();
    });
  }
}
