import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/playback_session_restore.dart';

final items = StreamController<MediaItem?>.broadcast();

class TestCurrent extends CurrentMediaItemNotifier {
  @override
  Stream<MediaItem?> build() => items.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'second duplicate alone matches, including after session restore',
    () async {
      const media = PlayableMedia(
        id: 'a',
        source: 'catalog:a',
        title: 'A',
        artist: 'Artist',
        listContext: 'list-1',
        listOccurrence: 'a-2',
      );
      final restored = await prepareRestoredPlaybackMedia([
        media.toJson(),
      ], loadLibraryCoverPath: (_) async => null);
      expect(restored.items.single.listOccurrence, 'a-2');
      expect(
        restored.items.single.toMediaItem().extras?['listContext'],
        'list-1',
      );
      final container = ProviderContainer(
      overrides: [
        currentMediaItemProvider.overrideWith(TestCurrent.new),
        playbackPlayingProvider.overrideWith((ref) => false),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
      );
      addTearDown(container.dispose);
      final first = listOccurrencePlaybackUiProvider((
        context: 'list-1',
        occurrence: 'a-1',
      ));
      final second = listOccurrencePlaybackUiProvider((
        context: 'list-1',
        occurrence: 'a-2',
      ));
      final other = listOccurrencePlaybackUiProvider((
        context: 'list-2',
        occurrence: 'a-2',
      ));
      final subscriptions = [
        first,
        second,
        other,
      ].map((p) => container.listen(p, (_, __) {})).toList();
      addTearDown(() {
        for (final subscription in subscriptions) {
          subscription.close();
        }
      });
      items.add(restored.items.single.toMediaItem());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(first).isCurrent, false);
      expect(container.read(second).isCurrent, true);
      expect(container.read(other).isCurrent, false);
    },
  );
}
