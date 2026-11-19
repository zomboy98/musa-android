import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('only ready playback of this queue confirms a playlist', () {
    bool confirmed(PlaybackState state, String? id) =>
        playlistPlaybackIsConfirmed(
          state: state,
          currentId: id,
          queueIds: {'a'},
        );
    expect(confirmed(PlaybackState(), 'a'), isFalse);
    expect(
      confirmed(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.loading,
          updatePosition: const Duration(seconds: 1),
        ),
        'a',
      ),
      isFalse,
    );
    expect(
      confirmed(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: const Duration(seconds: 1),
        ),
        'other',
      ),
      isFalse,
    );
    expect(
      confirmed(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: const Duration(seconds: 1),
        ),
        'a',
      ),
      isTrue,
    );
  });

  test(
    'pin and confirmed playback updates do not overwrite each other',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(libraryPlaylistOrderProvider.future);
      final order = container.read(libraryPlaylistOrderProvider.notifier);
      await Future.wait([
        order.togglePin('pinned'),
        order.recordPlayback('played'),
      ]);
      final value = await container.read(libraryPlaylistOrderProvider.future);
      expect(value.pinned, contains('pinned'));
      expect(value.played['played'], greaterThan(0));
      expect(value.played, isNot(contains('pinned')));
    },
  );
}
