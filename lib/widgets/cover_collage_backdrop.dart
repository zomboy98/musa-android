import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settled_blur.dart';

typedef CollageGridTiles = ({int columns, List<String> tiles});

CollageGridTiles collageGridTiles(Iterable<String?> sources) {
  final unique = <String>[];
  for (final source in sources) {
    final value = source?.trim();
    if (value == null || value.isEmpty || unique.contains(value)) continue;
    unique.add(value);
    if (unique.length == 9) break;
  }
  if (unique.isEmpty) return (columns: 1, tiles: const <String>[]);
  if (unique.length == 1) return (columns: 1, tiles: unique);
  if (unique.length >= 9) return (columns: 3, tiles: unique);
  return (
    columns: 2,
    tiles: [for (var i = 0; i < 4; i++) unique[i % unique.length]],
  );
}

double collageHeaderHeight(Size viewport) {
  final share = viewport.width > viewport.height ? 0.40 : 0.46;
  return math.min(viewport.width, viewport.height * share);
}

class CoverCollageBackdrop extends StatelessWidget {
  const CoverCollageBackdrop({super.key, required this.sources});

  final List<String> sources;

  static const _textZoneAlpha = 0.88;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final solid = MediaQuery.highContrastOf(context);
    final viewport = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final layout = collageGridTiles(sources);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gridHeight = math.min(
          collageHeaderHeight(viewport),
          constraints.maxHeight.isFinite
              ? constraints.maxHeight * 0.8
              : double.infinity,
        );
        final cacheWidth = (width / layout.columns * dpr).ceil().clamp(
          64,
          1024,
        );
        Widget grid() => _CollageGrid(layout: layout, cacheWidth: cacheWidth);
        Widget fade(double top, double? height, double from, double to) =>
            Positioned(
              left: 0,
              right: 0,
              top: top,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: from),
                      surface.withValues(alpha: to),
                    ],
                  ),
                ),
              ),
            );
        if (solid) {
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: gridHeight,
                  child: RepaintBoundary(
                    key: const ValueKey('collage_backdrop_grid'),
                    child: grid(),
                  ),
                ),
                fade(gridHeight * 0.5, gridHeight * 0.5, 0, 1),
                Positioned(
                  left: 0,
                  right: 0,
                  top: gridHeight,
                  bottom: 0,
                  child: ColoredBox(color: surface),
                ),
              ],
            ),
          );
        }
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: gridHeight * 0.5,
                height: gridHeight,
                child: RepaintBoundary(
                  key: const ValueKey('collage_backdrop_glow'),
                  child: SettledBlur(sigma: 36, child: grid()),
                ),
              ),
              fade(gridHeight * 0.45, gridHeight * 0.4, 0, _textZoneAlpha),
              Positioned(
                left: 0,
                right: 0,
                top: gridHeight * 0.85,
                bottom: 0,
                child: ColoredBox(
                  color: surface.withValues(alpha: _textZoneAlpha),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: gridHeight,
                child: RepaintBoundary(
                  key: const ValueKey('collage_backdrop_grid'),
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0, 0.55, 1],
                    ).createShader(rect),
                    child: grid(),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 48,
                child: DecoratedBox(
                  key: const ValueKey('collage_backdrop_fade'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [surface.withValues(alpha: 0), surface],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CollageGrid extends StatelessWidget {
  const _CollageGrid({required this.layout, required this.cacheWidth});

  final CollageGridTiles layout;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (layout.tiles.isEmpty) {
      return ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.queue_music,
            size: 64,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final columns = layout.columns;
    final rows = layout.tiles.length ~/ columns;
    return ExcludeSemantics(
      child: Column(
        children: [
          for (var r = 0; r < rows; r++)
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < columns; c++)
                    Expanded(
                      child: PlayerArtwork(
                        artUri: layout.tiles[r * columns + c],
                        colorScheme: scheme,
                        cacheWidth: cacheWidth,
                        iconSize: 24,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
