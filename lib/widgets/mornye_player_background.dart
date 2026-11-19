import 'package:flutter/material.dart';
import 'package:mornye/theme/cover_backdrop.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';

/// Gradient of a [CoverBackdrop] on the dark player surface: up to three
/// colours of the cover's own dominant hues (population weighted, see
/// [analyzeCoverBackdrop]) with chroma capped and tones normalised so white
/// text keeps a contrast of at least 5. [fullBleed] is the vertical gradient
/// under the artwork fade; otherwise the diagonal one behind lyrics and the
/// queue. A [CoverBackdrop.neutral] gives plain gray, never an accent.
LinearGradient mornyeBackdropGradient(
  CoverBackdrop backdrop, {
  required bool fullBleed,
}) => LinearGradient(
  begin: fullBleed ? Alignment.topCenter : Alignment.topLeft,
  end: fullBleed ? Alignment.bottomCenter : Alignment.bottomRight,
  stops: fullBleed ? const [0, 0.5, 1] : null,
  colors: backdrop.gradientColors(
    fullBleed ? const [43, 37, 28] : const [36, 30, 22],
  ),
);

/// Mimetic cover-derived surface: the cover itself, reduced, blurred and
/// tinted by colour blobs sampled from its corners and centre, under an
/// adaptive veil that keeps white text legible (see [CoverMimicScene]). The
/// full-bleed artwork on the player page melts into it, so cover and
/// background read as one piece; behind lyrics and the queue the same
/// surface shows without the artwork. With [live], the colours follow the
/// current frame of an animated cover.
class MornyePlayerBackground extends StatefulWidget {
  const MornyePlayerBackground({
    super.key,
    required this.artUri,
    this.artwork,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
    this.live = false,
    this.liveSource,
  });

  final Uri? artUri;
  final Widget? artwork;
  final bool squareArtwork;
  final double? artworkAspectRatio;

  /// Fraction of the artwork's height that stays sharp before fading out.
  final double fadeStart;

  /// Whether the artwork is animated and the colours should follow it.
  final bool live;

  /// Boundary of a video drawn outside this widget whose frames tint the
  /// surface; it makes the colours follow it even without [artwork].
  final CoverMimicLiveSource? liveSource;

  @override
  State<MornyePlayerBackground> createState() => _MornyePlayerBackgroundState();
}

class _MornyePlayerBackgroundState extends State<MornyePlayerBackground> {
  final CoverMimicLiveSource _ownSource = CoverMimicLiveSource();

  CoverMimicLiveSource get _liveSource => widget.liveSource ?? _ownSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artwork = widget.artwork;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    final size = MediaQuery.sizeOf(context);
    final ratio = widget.artworkAspectRatio;
    final artworkHeight = ratio != null && ratio > 0
        ? (size.width / ratio).clamp(0.0, size.height * 0.75)
        : widget.squareArtwork
        ? size.width
        : size.height * 0.66;

    return Theme(
      // Missing or unreadable covers use neutral gray, not the app's accent.
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.dark,
          primary: const Color(0xff808080),
        ),
      ),
      child: CoverMimicScope(
        source: widget.artUri?.toString(),
        artworkHeight: artworkHeight,
        live: widget.live && (artwork != null || widget.liveSource != null),
        liveSource: _liveSource,
        builder: (context, scene) => Stack(
          fit: StackFit.expand,
          children: [
            CoverMimicLayer(scene: scene),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: artworkHeight,
              child: HeroMode(
                // The compact header owns the route hero while the
                // full cover is fading out behind the lyrics.
                enabled: artwork != null,
                child: AnimatedSwitcher(
                  duration: motion,
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final child in previous)
                        HeroMode(enabled: false, child: child),
                      ?current,
                    ],
                  ),
                  child: artwork == null
                      ? null
                      : KeyedSubtree(
                          key: const ValueKey('full-player-artwork'),
                          child: CoverMimicLiveBoundary(
                            source: _liveSource,
                            child: artwork,
                          ),
                        ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: artwork == null ? 0 : 1,
                  duration: motion,
                  curve: Curves.easeInOutCubic,
                  child: CoverMimicFade(
                    scene: scene,
                    top: artworkHeight * widget.fadeStart,
                    bottom: artworkHeight,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
