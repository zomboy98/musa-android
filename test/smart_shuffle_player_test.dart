import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/music_player_automix_harness.dart';

final _mixed = [
  for (var i = 0; i < 24; i++)
    PlayableMedia(
      id: 'song-$i',
      source: '/song-$i.flac',
      title: 'Song $i',
      artist: 'Artist ${i % 6}',
      album: 'Album ${i % 8}',
      albumId: 'album-${i % 8}',
    ),
];

final _oneAlbum = [
  for (var i = 0; i < 8; i++)
    PlayableMedia(
      id: 'track-$i',
      source: '/track-$i.flac',
      title: 'Track $i',
      artist: 'Band',
      album: 'Record',
      albumId: 'record',
    ),
];

List<String> _ids() => handler.queue.value.map((item) => item.id).toList();

void main() {
  setUpMusicPlayerHarness();

  test(
    'smart shuffle plans the whole queue once and off restores it',
    () async {
      await handler.setQueueAndPlay(_mixed, initialIndex: 5);
      await handler.setShuffleStrategy(ShuffleStrategy.smart);
      expect(handler.shuffleStrategy, ShuffleStrategy.smart);
      final planned = _ids();
      expect(planned.first, 'song-5');
      expect(planned.toSet(), _mixed.map((item) => item.id).toSet());
      for (var i = 1; i < planned.length; i++) {
        expect(
          handler.queue.value[i].artist != handler.queue.value[i - 1].artist,
          isTrue,
        );
      }
      await handler.setShuffleStrategy(ShuffleStrategy.off);
      expect(_ids(), _mixed.map((item) => item.id).toList());
      expect(handler.mediaItem.value?.id, 'song-5');
      expect(handler.playbackState.value.queueIndex, 5);
      expect(handler.shuffleStrategy, ShuffleStrategy.off);
    },
  );

  test('the strategy follows the queue session and reports changes', () async {
    final seen = <ShuffleStrategy>[];
    final events = handler.shuffleStrategyChanges().listen(seen.add);
    await handler.setQueueAndPlay(_mixed);
    await handler.setShuffleStrategy(ShuffleStrategy.smart);
    await handler.setShuffleStrategy(ShuffleStrategy.random);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    expect(handler.shuffleStrategy, ShuffleStrategy.random);
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    await events.cancel();
    expect(seen, [
      ShuffleStrategy.off,
      ShuffleStrategy.smart,
      ShuffleStrategy.random,
      ShuffleStrategy.off,
    ]);
  });

  test('a single album never keeps the smart strategy', () async {
    await handler.setShuffleStrategy(ShuffleStrategy.smart);
    await handler.setQueueAndPlay(_oneAlbum, initialIndex: 2);
    expect(handler.shuffleStrategy, ShuffleStrategy.random);
    expect(_ids().first, 'track-2');
    expect(_ids().toSet().length, _oneAlbum.length);
  });

  test('the random order stays stable while the queue plays', () async {
    await handler.setQueueAndPlay(_mixed);
    await handler.setShuffleStrategy(ShuffleStrategy.random);
    final planned = _ids();
    for (var i = 1; i < 6; i++) {
      await handler.skipToNext();
      expect(_ids(), planned);
    }
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.id, planned[4]);
    expect(_ids(), planned);
  });

  test('a quick skip reorders only the queue beyond the next three', () async {
    await handler.setQueueAndPlay(_mixed);
    await handler.setShuffleStrategy(ShuffleStrategy.smart);
    final before = _ids();
    await handler.skipToNext();
    final after = _ids();
    expect(after.sublist(0, 5), before.sublist(0, 5));
    expect(after.toSet(), before.toSet());
    expect(handler.playbackState.value.queueIndex, 1);
    await handler.skipToNext();
    await handler.skipToNext();
    final later = _ids();
    expect(later.sublist(0, 7), after.sublist(0, 7));
    expect(later.toSet(), before.toSet());
  });

  test('repeat all opens a new smart round with another song', () async {
    final tracks = _mixed.take(10).toList();
    await handler.setQueueAndPlay(tracks);
    await handler.setShuffleStrategy(ShuffleStrategy.smart);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    final planned = _ids();
    bool ready() =>
        handler.playbackState.value.processingState ==
        AudioProcessingState.ready;
    for (var i = 1; i < planned.length; i++) {
      await native.event('music-player', 'audio.onComplete');
      await waitUntil(
        () => handler.mediaItem.value?.id == planned[i] && ready(),
      );
    }
    await native.event('music-player', 'audio.onComplete');
    await waitUntil(
      () =>
          handler.playbackState.value.queueIndex == 0 &&
          handler.mediaItem.value?.id != planned.last &&
          ready(),
    );
    expect(_ids().toSet(), planned.toSet());
  });
}
