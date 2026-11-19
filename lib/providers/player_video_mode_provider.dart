import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';

class PlayerVideoMode {
  const PlayerVideoMode({required this.mediaId, required this.path});

  final String mediaId;
  final String path;
}

class PlayerVideoModeNotifier extends Notifier<PlayerVideoMode?> {
  @override
  PlayerVideoMode? build() {
    ref.listen(currentMediaItemProvider.select((item) => item.value?.id), (
      _,
      id,
    ) {
      final mode = state;
      if (mode != null && mode.mediaId != id) state = null;
    });
    return null;
  }

  void show(PlayerVideoMode mode) => state = mode;

  void clear() => state = null;
}

final playerVideoModeProvider =
    NotifierProvider<PlayerVideoModeNotifier, PlayerVideoMode?>(
      PlayerVideoModeNotifier.new,
    );

final playerVideoPathProvider = Provider.autoDispose.family<String?, MediaItem>(
  (ref, item) {
    final mode = ref.watch(playerVideoModeProvider);
    return mode != null && mode.mediaId == item.id ? mode.path : null;
  },
);
