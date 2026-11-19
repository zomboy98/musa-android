import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_video_mode_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/track_video_tags.dart';

enum PlayerVideoOutcome { started, left, failed, needsNetwork, abandoned }

/// The video of one song while it is prepared and once it is playing.
class PlayerVideoSession {
  const PlayerVideoSession({
    this.loadingKey,
    this.started,
    this.done = false,
    this.activeKey,
  });

  final String? loadingKey;
  final DateTime? started;
  final bool done;
  final String? activeKey;

  bool loadingFor(String key) => loadingKey == key;
}

class PlayerVideoSessionNotifier extends Notifier<PlayerVideoSession> {
  int _token = 0;
  String? _returnPath;
  String? _returnQuality;

  @override
  PlayerVideoSession build() => const PlayerVideoSession();

  void abandonUnless(String? key) {
    final loading = state.loadingKey;
    if (key == null || loading == null || loading == key) return;
    _token++;
    state = PlayerVideoSession(activeKey: state.activeKey);
  }

  Future<PlayerVideoOutcome> toggle(
    Track track,
    TrackVideoTag tag, {
    String? replacing,
    String? currentQuality,
    Duration settle = const Duration(milliseconds: 360),
  }) async {
    final key = trackCollectionKey(track);
    final mode = ref.read(playerVideoModeProvider);
    if (mode != null && state.activeKey == key) {
      await _leave(track, mode.path);
      return PlayerVideoOutcome.left;
    }
    if (state.loadingKey != null) return PlayerVideoOutcome.abandoned;
    final source = trackVideoSource;
    final videoId = tag.videoId;
    if (source == null || videoId == null) return PlayerVideoOutcome.failed;
    final token = ++_token;
    state = PlayerVideoSession(
      loadingKey: key,
      started: DateTime.now(),
      activeKey: state.activeKey,
    );
    String? path;
    var needsNetwork = false;
    try {
      path = await source.prepare(
        track,
        TrackVideoOffer(provider: tag.provider ?? '', videoId: videoId),
      );
    } on TrackVideoNeedsNetwork {
      needsNetwork = true;
    } catch (_) {
      path = null;
    }
    final switched = path == null
        ? false
        : await requestPlaybackSourceSwitch(
            track,
            path,
            replacing: replacing ?? '',
            sourceKind: 'video',
          );
    if (token != _token) return PlayerVideoOutcome.abandoned;
    if (!switched) {
      state = PlayerVideoSession(activeKey: state.activeKey);
      return needsNetwork
          ? PlayerVideoOutcome.needsNetwork
          : PlayerVideoOutcome.failed;
    }
    _returnPath = replacing;
    _returnQuality = currentQuality;
    final mediaId = ref.read(currentMediaItemProvider).value?.id;
    if (mediaId != null) {
      ref
          .read(playerVideoModeProvider.notifier)
          .show(PlayerVideoMode(mediaId: mediaId, path: path));
    }
    state = PlayerVideoSession(
      loadingKey: key,
      started: state.started,
      done: true,
      activeKey: key,
    );
    if (settle > Duration.zero) await Future<void>.delayed(settle);
    if (token == _token) state = PlayerVideoSession(activeKey: key);
    return PlayerVideoOutcome.started;
  }

  void qualityChosen(String quality) {
    if (_returnQuality == null || quality.trim().isEmpty) return;
    _returnQuality = quality;
  }

  Future<void> _leave(Track track, String videoPath) async {
    ref.read(playerVideoModeProvider.notifier).clear();
    final path = _returnPath;
    final quality = _returnQuality;
    _returnPath = null;
    _returnQuality = null;
    state = const PlayerVideoSession();
    if (path != null && path.isNotEmpty) {
      await requestPlaybackSourceSwitch(track, path, replacing: videoPath);
    } else if (quality != null && quality.isNotEmpty) {
      await requestCatalogQualitySwitch(track, quality);
    }
  }
}

final playerVideoSessionProvider =
    NotifierProvider<PlayerVideoSessionNotifier, PlayerVideoSession>(
      PlayerVideoSessionNotifier.new,
    );
