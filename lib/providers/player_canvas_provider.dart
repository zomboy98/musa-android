import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart'
    show bundledExtensionsReadyProvider, installedExtensionVersion;
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/spotify_canvas_lookup.dart';
import 'package:mornye/services/video_network_policy.dart';
import 'package:mornye/utils/string_utils.dart';

final canvasConnectivityProvider = Provider<ConnectivityCheck?>((ref) => null);

final spotifyCanvasLookupProvider = Provider(
  (ref) => SpotifyCanvasLookup(
    ready: () => ref.read(bundledExtensionsReadyProvider.future),
    pluginVersion: () =>
        installedExtensionVersion(ref, SpotifyCanvasLookup.extensionId),
    installed: () => installedExtensionVersion(
      ref,
      SpotifyCanvasLookup.extensionId,
    ).isNotEmpty,
  ),
);

MotionArtworkAlbum _appleSlot(Track track, String artist) =>
    (album: 'canvas:${track.id.trim()}', artist: artist);

MotionArtworkAlbum _spotifySlot(MediaItem item, String artist) =>
    (album: 'spotify-canvas:${item.id}', artist: artist);

/// Saving the loop (download, remux, full validation) can take seconds, so
/// the player streams the source right away and keeps the saved copy for the
/// next time.
MotionArtwork _streamWhileSaving(
  MotionArtworkStore store,
  MotionArtworkAlbum slot,
  String url,
) {
  debugPrint('canvas: streaming while saving');
  unawaited(
    store
        .save(slot, resolveSource: () async => url)
        .then<void>((_) {}, onError: (Object _) {}),
  );
  return MotionArtwork(url);
}

Future<MotionArtwork?> _spotifyCanvas(
  Ref ref,
  MediaItem item,
  Track track,
  String artist, {
  bool stream = false,
}) async {
  final store = ref.watch(motionArtworkStoreProvider);
  final slot = _spotifySlot(item, artist);
  final cached = await store.find(slot);
  if (cached != null || !ref.mounted) {
    if (cached != null) debugPrint('canvas: store hit');
    return cached;
  }
  final allowed = await videoNetworkAllowed(
    allowMobileData: ref.read(
      settingsProvider.select((s) => s.canvasMobileDataEnabled),
    ),
    check: ref.read(canvasConnectivityProvider),
  );
  if (!allowed || !ref.mounted) {
    if (!allowed) debugPrint('canvas: skipped by network policy');
    return null;
  }
  final url = await ref.read(spotifyCanvasLookupProvider).lookup(track);
  if (url == null || !ref.mounted) return null;
  if (stream) return _streamWhileSaving(store, slot, url);
  return store.save(slot, resolveSource: () async => url);
}

/// Starts the Spotify Canvas search as soon as a track starts, from the media
/// item alone, so it runs beside the audio preparation and never gates it.
final playerCanvasPrefetchProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      final settings = ref.watch(
        settingsProvider.select(
          (s) => s.motionArtworkEnabled && s.spotifyCanvasEnabled,
        ),
      );
      final artist = (item.artist ?? '').trim();
      if (!settings || artist.isEmpty || item.id.trim().isEmpty) return null;
      final track = collectionTrackForMedia(item, null);
      logAnimatedArtworkIsrc(item, track);
      return _spotifyCanvas(ref, item, track, artist);
    });

final playerCanvasProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return null;
      }
      final spotifyEnabled = ref.watch(
        settingsProvider.select((s) => s.spotifyCanvasEnabled),
      );
      final track = await ref.watch(playerCollectionTrackProvider(item).future);
      if (!ref.mounted) return null;
      logAnimatedArtworkIsrc(item, track);
      final artist = (item.artist ?? track.artistName).trim();
      if (artist.isEmpty || track.id.trim().isEmpty) return null;
      final appleUrl = normalizeRemoteHttpUrl(track.headerVideoUrl);
      final store = ref.watch(motionArtworkStoreProvider);
      final appleSlot = _appleSlot(track, artist);
      final cached = await store.find(appleSlot);
      if (!ref.mounted) return null;
      if (cached != null) return cached;
      if (appleUrl == null) {
        return spotifyEnabled
            ? _spotifyCanvas(ref, item, track, artist, stream: true)
            : null;
      }
      final allowed = await videoNetworkAllowed(
        allowMobileData: ref.read(
          settingsProvider.select((s) => s.canvasMobileDataEnabled),
        ),
        check: ref.read(canvasConnectivityProvider),
      );
      if (!allowed || !ref.mounted) return null;
      return _streamWhileSaving(store, appleSlot, appleUrl);
    });

/// Warms the loop of the next queue item so it is saved before its turn.
final playerNextCanvasPrefetchProvider = Provider.autoDispose<void>((ref) {
  final queue = ref.watch(playQueueProvider).value;
  if (queue == null) return;
  final index = ref.watch(currentQueueIndexProvider);
  if (index < 0 || index + 1 >= queue.length) return;
  ref.watch(playerCanvasPrefetchProvider(queue[index + 1]));
});
