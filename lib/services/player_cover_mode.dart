const playerCoverCrossfade = Duration(milliseconds: 560);

enum PlayerCoverMode { fullBleedVideo, canvasBackdrop, squareVideo, still }

enum PlayerCoverVideoKind { appleTall, canvas, appleSquare }

class PlayerCoverVideo {
  const PlayerCoverVideo(this.source, {this.local = true});

  final String source;
  final bool local;

  @override
  bool operator ==(Object other) =>
      other is PlayerCoverVideo &&
      other.source == source &&
      other.local == local;

  @override
  int get hashCode => Object.hash(source, local);
}

class PlayerCoverDecision {
  const PlayerCoverDecision(this.mode, [this.kind, this.video]);

  static const still = PlayerCoverDecision(PlayerCoverMode.still);

  final PlayerCoverMode mode;
  final PlayerCoverVideoKind? kind;
  final PlayerCoverVideo? video;

  String? get source => video?.source;

  @override
  bool operator ==(Object other) =>
      other is PlayerCoverDecision &&
      other.mode == mode &&
      other.kind == kind &&
      other.video == video;

  @override
  int get hashCode => Object.hash(mode, kind, video);
}

/// Chooses how the player shows the cover of the playing track: a vertical
/// loop (Apple tall, then Spotify Canvas) fills the screen; a square Apple
/// loop sits in the cover frame; without any, the complete still cover.
/// With the setting off, or in landscape, a Canvas stays a backdrop behind
/// the cover frame, as before.
/// A candidate that is not saved on the device needs the network to be
/// allowed. [tallEnabled] is the user's adaptive full screen setting.
PlayerCoverDecision decidePlayerCoverMode({
  required bool motionEnabled,
  required bool tallEnabled,
  required bool networkAllowed,
  required bool reduceAnimations,
  required bool musicVideoActive,
  bool landscape = false,
  PlayerCoverVideo? appleTall,
  PlayerCoverVideo? canvas,
  PlayerCoverVideo? appleSquare,
}) {
  if (!motionEnabled || reduceAnimations || musicVideoActive) {
    return PlayerCoverDecision.still;
  }
  PlayerCoverVideo? usable(PlayerCoverVideo? video) =>
      video != null &&
          video.source.isNotEmpty &&
          (video.local || networkAllowed)
      ? video
      : null;
  if (tallEnabled && !landscape) {
    final tall = usable(appleTall);
    if (tall != null) {
      return PlayerCoverDecision(
        PlayerCoverMode.fullBleedVideo,
        PlayerCoverVideoKind.appleTall,
        tall,
      );
    }
  }
  final vertical = usable(canvas);
  if (vertical != null) {
    return PlayerCoverDecision(
      tallEnabled && !landscape
          ? PlayerCoverMode.fullBleedVideo
          : PlayerCoverMode.canvasBackdrop,
      PlayerCoverVideoKind.canvas,
      vertical,
    );
  }
  final square = usable(appleSquare);
  if (square != null) {
    return PlayerCoverDecision(
      PlayerCoverMode.squareVideo,
      PlayerCoverVideoKind.appleSquare,
      square,
    );
  }
  return PlayerCoverDecision.still;
}

/// Most of its width a full-screen video may lose to `BoxFit.cover` before
/// the player shows it at the full screen width instead.
const double playerVideoMaxCropFraction = 0.12;

enum PlayerVideoFit { cover, fitWidth }

class PlayerVideoFitResult {
  const PlayerVideoFitResult(this.fit, this.cropFraction);

  final PlayerVideoFit fit;

  /// Share of the video's width `BoxFit.cover` would cut off at the sides.
  final double cropFraction;

  @override
  bool operator ==(Object other) =>
      other is PlayerVideoFitResult &&
      other.fit == fit &&
      other.cropFraction == cropFraction;

  @override
  int get hashCode => Object.hash(fit, cropFraction);
}

/// Chooses how a video of [videoAspect] (width over height) fills an area of
/// [areaAspect]: `cover` unless it would lose more than
/// [playerVideoMaxCropFraction] of its width, then `fitWidth`.
PlayerVideoFitResult videoFitForAspect(double videoAspect, double areaAspect) {
  if (!(videoAspect > 0) || !(areaAspect > 0)) {
    return const PlayerVideoFitResult(PlayerVideoFit.cover, 0);
  }
  final crop = videoAspect <= areaAspect ? 0.0 : 1 - areaAspect / videoAspect;
  return PlayerVideoFitResult(
    crop > playerVideoMaxCropFraction
        ? PlayerVideoFit.fitWidth
        : PlayerVideoFit.cover,
    crop,
  );
}
