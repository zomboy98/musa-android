import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart'
    show bundledExtensionsReadyProvider, installedExtensionVersion;
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_canvas_provider.dart'
    show canvasConnectivityProvider;
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/apple_animated_artwork.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/video_network_policy.dart';

final appleAnimatedArtworkLookupProvider = Provider(
  (ref) => AppleAnimatedArtworkLookup(
    ready: () => ref.read(bundledExtensionsReadyProvider.future),
    pluginVersion: () => installedExtensionVersion(ref, 'apple-music'),
    installed: () => installedExtensionVersion(ref, 'apple-music').isNotEmpty,
  ),
);

MotionArtworkAlbum appleAnimatedArtworkSlot(Track track) => (
  album: 'apple-animated:${animatedArtworkKey(track)}',
  artist: 'apple-music',
);

MotionArtworkAlbum appleTallArtworkSlot(Track track) => (
  album: 'apple-animated-tall:${animatedArtworkKey(track)}',
  artist: 'apple-music',
);

/// The tall 3:4 loop Apple Music offers for the album, saved on its own so the
/// full-screen player can use it. It is fetched only when the adaptive
/// full-screen setting is on; the square loop is fetched only if this fails.
final playerAppleTallArtworkProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      final enabled = ref.watch(
        settingsProvider.select(
          (s) => s.motionArtworkEnabled && s.playerAdaptiveFullBleed,
        ),
      );
      if (!enabled) return null;
      final track = await ref.watch(playerCollectionTrackProvider(item).future);
      if (!ref.mounted) return null;
      logAnimatedArtworkIsrc(item, track);
      if (track.name.trim().isEmpty || track.artistName.trim().isEmpty) {
        return null;
      }
      final store = ref.watch(motionArtworkStoreProvider);
      final slot = appleTallArtworkSlot(track);
      final saved = await store.find(slot);
      if (saved != null || !ref.mounted) return saved;
      final lookup = ref.read(appleAnimatedArtworkLookupProvider);
      if (lookup.saveBlocked(track, variant: AnimatedArtworkVariant.tall)) {
        return null;
      }
      final allowed = await videoNetworkAllowed(
        allowMobileData: ref.read(
          settingsProvider.select((s) => s.canvasMobileDataEnabled),
        ),
        check: ref.read(canvasConnectivityProvider),
      );
      if (!allowed || !ref.mounted) return null;
      final tall = (await lookup.lookup(track)).variants.tall;
      if (tall == null || !ref.mounted) return null;
      final artwork = await store.save(
        slot,
        resolveSource: () async => tall.url,
      );
      if (artwork == null) {
        lookup.recordSaveFailure(track, variant: AnimatedArtworkVariant.tall);
      }
      return artwork;
    });

/// Animated cover from Apple Music for the playing track's album. Resolves to
/// a saved local loop, so the full player and the mini player share one file.
/// A lookup that fails is retried soon; "no animated cover" is remembered.
/// With the adaptive full-screen setting on, a tall loop is left to
/// [playerAppleTallArtworkProvider] and this one only fills in when that
/// could not be saved and a square loop exists.
final playerAppleAnimatedArtworkProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return null;
      }
      final track = await ref.watch(playerCollectionTrackProvider(item).future);
      if (!ref.mounted) return null;
      logAnimatedArtworkIsrc(item, track);
      if (track.name.trim().isEmpty || track.artistName.trim().isEmpty) {
        return null;
      }
      final store = ref.watch(motionArtworkStoreProvider);
      final slot = appleAnimatedArtworkSlot(track);
      final saved = await store.find(slot);
      if (saved != null || !ref.mounted) return saved;
      final adaptive = ref.watch(
        settingsProvider.select((s) => s.playerAdaptiveFullBleed),
      );
      if (adaptive) {
        final tall = await ref.watch(
          playerAppleTallArtworkProvider(item).future,
        );
        if (tall != null || !ref.mounted) return null;
      }
      final lookup = ref.read(appleAnimatedArtworkLookupProvider);
      if (lookup.saveBlocked(track)) return null;
      final allowed = await videoNetworkAllowed(
        allowMobileData: ref.read(
          settingsProvider.select((s) => s.canvasMobileDataEnabled),
        ),
        check: ref.read(canvasConnectivityProvider),
      );
      if (!allowed || !ref.mounted) return null;
      final result = await lookup.lookup(track);
      final source = adaptive ? result.variants.square : result.source;
      if (source == null || !ref.mounted) return null;
      final artwork = await store.save(
        slot,
        resolveSource: () async => source.url,
      );
      if (artwork == null) lookup.recordSaveFailure(track);
      return artwork;
    });

/// The square cover loop for the player: a loop saved with the album
/// (downloads) first, then the one Apple Music offers for it.
final playerSquareCoverMotionProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      final stored = await ref.watch(
        playerMotionArtworkProvider((
          album: item.album ?? '',
          artist: item.artist ?? '',
        )).future,
      );
      if (stored != null || !ref.mounted) return stored;
      return ref.watch(playerAppleAnimatedArtworkProvider(item).future);
    });

/// Any cover loop for warming up and for the mini player: the square one,
/// else the tall one, which is cropped to the box.
final playerCoverMotionProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, MediaItem>((ref, item) async {
      final square = await ref.watch(
        playerSquareCoverMotionProvider(item).future,
      );
      if (square != null || !ref.mounted) return square;
      return ref.watch(playerAppleTallArtworkProvider(item).future);
    });
