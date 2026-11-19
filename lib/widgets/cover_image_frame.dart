import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Paints a cover whole inside whatever frame it is given.
///
/// When the decoded image and the frame share their proportions (within
/// [tolerance]) the image is cropped by [BoxFit.cover], which loses nothing
/// visible. Otherwise the full image is drawn with [BoxFit.contain] and the
/// empty sides are filled with a blurred, enlarged copy of the same image, or
/// with the surface colour on small frames where a blur is not worth its cost.
class CoverImageFrame extends StatefulWidget {
  /// Frames at or below this shortest side skip the blurred fill.
  static const smallFrameExtent = 96.0;

  /// Relative difference in aspect ratio that still counts as "the same".
  static const defaultTolerance = 0.03;

  const CoverImageFrame({
    super.key,
    required this.image,
    this.tolerance = defaultTolerance,
    this.filterQuality = FilterQuality.low,
    this.errorBuilder,
    this.frameBuilder,
  });

  final ImageProvider image;
  final double tolerance;
  final FilterQuality filterQuality;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageFrameBuilder? frameBuilder;

  static const foregroundKey = ValueKey('cover-frame-foreground');
  static const fillKey = ValueKey('cover-frame-fill');

  /// Aspect ratio (width / height) already measured for [image], if any.
  static double? knownAspect(ImageProvider image) => _CoverAspects.get(image);

  /// Whether [image] drawn into a frame of [frame] ratio must be shown whole
  /// rather than cropped.
  static bool needsContain(
    double imageAspect,
    double frameAspect, {
    double tolerance = defaultTolerance,
  }) {
    if (imageAspect <= 0 || frameAspect <= 0) return false;
    return (imageAspect / frameAspect - 1).abs() > tolerance;
  }

  @override
  State<CoverImageFrame> createState() => _CoverImageFrameState();
}

class _CoverImageFrameState extends State<CoverImageFrame> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverImageFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    final known = _CoverAspects.get(widget.image);
    _aspect = known;
    _detach();
    if (known != null) return;
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      final width = info.image.width;
      final height = info.image.height;
      if (width <= 0 || height <= 0) return;
      final aspect = width / height;
      _CoverAspects.put(widget.image, aspect);
      if (mounted && _aspect != aspect) setState(() => _aspect = aspect);
    }, onError: (_, _) {});
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  Image _paint(BoxFit fit, {Key? key, bool withFrame = false}) => Image(
    key: key,
    image: widget.image,
    fit: fit,
    gaplessPlayback: true,
    filterQuality: widget.filterQuality,
    frameBuilder: withFrame ? widget.frameBuilder : null,
    errorBuilder: widget.errorBuilder,
  );

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect;
    if (aspect == null) {
      return _paint(BoxFit.cover, key: CoverImageFrame.foregroundKey);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0;
        if (!bounded) {
          return _paint(BoxFit.cover, key: CoverImageFrame.foregroundKey);
        }
        final frameAspect = constraints.maxWidth / constraints.maxHeight;
        if (!CoverImageFrame.needsContain(
          aspect,
          frameAspect,
          tolerance: widget.tolerance,
        )) {
          return _paint(
            BoxFit.cover,
            key: CoverImageFrame.foregroundKey,
            withFrame: true,
          );
        }
        final small =
            constraints.biggest.shortestSide <=
            CoverImageFrame.smallFrameExtent;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (small)
              ColoredBox(
                key: CoverImageFrame.fillKey,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              )
            else
              RepaintBoundary(
                key: CoverImageFrame.fillKey,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 24,
                          sigmaY: 24,
                          tileMode: TileMode.mirror,
                        ),
                        child: _paint(BoxFit.cover),
                      ),
                      const ColoredBox(color: Color(0x2E000000)),
                    ],
                  ),
                ),
              ),
            _paint(
              BoxFit.contain,
              key: CoverImageFrame.foregroundKey,
              withFrame: true,
            ),
          ],
        );
      },
    );
  }
}

class _CoverAspects {
  static const _capacity = 400;
  static final _values = <ImageProvider, double>{};

  static double? get(ImageProvider key) {
    final value = _values.remove(key);
    if (value != null) _values[key] = value;
    return value;
  }

  static void put(ImageProvider key, double aspect) {
    _values.remove(key);
    _values[key] = aspect;
    while (_values.length > _capacity) {
      _values.remove(_values.keys.first);
    }
  }

  @visibleForTesting
  static void clear() => _values.clear();
}

@visibleForTesting
void clearCoverAspectCache() => _CoverAspects.clear();
