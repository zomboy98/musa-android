import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:mornye/theme/cover_mimic.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// Longest side, in pixels, the cover is reduced to before it is blurred.
const int mimicSampleExtent = 64;

/// Blur sigma, in pixels of the reduced cover (about 6 % of its width).
const double mimicBlurSigma = 4;

/// Duration of the colour mutation when the track changes.
const Duration mimicAdaptDuration = Duration(milliseconds: 600);

/// Duration of each mutation step while an animated cover is playing.
const Duration mimicLiveAdaptDuration = Duration(milliseconds: 450);

/// Time between samples of an animated cover's current frame.
const Duration mimicLiveSampleInterval = Duration(milliseconds: 400);

/// Width in pixels of the frame read back from an animated cover.
const double mimicLiveSampleWidth = 32;

/// Opacity of the blurred cover image over the base colour.
const double mimicImageOpacity = 0.85;

/// Opacity of the blurred image while an animated cover drives the colours.
const double mimicLiveImageOpacity = 0.4;

/// Alpha at the centre of each colour blob: the strength of the camouflage.
const double mimicBlobOpacity = 0.78;

/// Radius of the corner blobs and the centre one, in fractions of the width.
const double mimicCornerRadius = 0.85;
const double mimicCenterRadius = 0.7;

/// Saturation applied to the blurred image.
const double mimicImageSaturation = 1.25;

/// Seconds between repaints of the idle drift, which is slow enough for ~12
/// frames per second to look continuous.
const double mimicRepaintInterval = 0.08;

const List<Offset> _anchors = [
  Offset(0, 0),
  Offset(1, 0),
  Offset(0, 1),
  Offset(1, 1),
  Offset(0.5, 0.5),
];

/// A blurred cover, its zone colours and veil, ready to paint.
class CoverMimicData {
  const CoverMimicData(this.image, this.look);

  final ui.Image image;
  final CoverMimicLook look;
}

class _Entry {
  _Entry(this.data, this.stamp);

  final CoverMimicData data;
  final String stamp;
}

/// Blurred covers, computed once per cover and kept for later tracks.
class CoverMimicCache {
  const CoverMimicCache._();

  static const int maxEntries = 8;
  static final Map<String, _Entry> _entries = {};
  static final Map<String, Future<CoverMimicData?>> _pending = {};

  @visibleForTesting
  static Future<CoverMimicData?> Function(String source)? debugLoader;

  @visibleForTesting
  static void debugClear() {
    for (final entry in _entries.values) {
      entry.data.image.dispose();
    }
    _entries.clear();
    _pending.clear();
  }

  static String keyOf(String source) => coverImageSource(source) ?? source;

  /// The cover already resolved, or null.
  static CoverMimicData? peek(String source) => _entries[keyOf(source)]?.data;

  static Future<CoverMimicData?> resolve(String source) {
    final key = keyOf(source);
    return _pending.putIfAbsent(
      key,
      () => _resolve(key).whenComplete(() {
        _pending.remove(key);
      }),
    );
  }

  static Future<String> _stamp(String key) async {
    if (isHttpCoverUrl(key)) return '';
    try {
      final stat = await File(key).stat();
      return '${stat.modified.microsecondsSinceEpoch}|${stat.size}';
    } catch (_) {
      return '';
    }
  }

  static Future<CoverMimicData?> _resolve(String key) async {
    final loader = debugLoader;
    if (loader != null) return loader(key);
    final stamp = await _stamp(key);
    final cached = _entries[key];
    if (cached != null && cached.stamp == stamp) return cached.data;
    try {
      final data = await _load(key);
      if (data == null) return null;
      _entries.remove(key)?.data.image.dispose();
      _entries[key] = _Entry(data, stamp);
      while (_entries.length > maxEntries) {
        final oldest = _entries.keys.first;
        _entries.remove(oldest)?.data.image.dispose();
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<CoverMimicData?> _load(String key) async {
    final ImageProvider provider;
    if (isHttpCoverUrl(key)) {
      provider = cachedCoverImageProvider(key);
    } else {
      final file = File(key);
      if (!await file.exists()) return null;
      provider = FileImage(file);
    }
    final decoded = Completer<ImageInfo>();
    final stream = ResizeImage(
      provider,
      width: mimicSampleExtent,
      height: mimicSampleExtent,
      policy: ResizeImagePolicy.fit,
    ).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!decoded.isCompleted) decoded.complete(info);
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!decoded.isCompleted) decoded.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final info = await decoded.future.timeout(const Duration(seconds: 5));
    try {
      return await blurCover(info.image);
    } finally {
      info.dispose();
    }
  }

  /// Zone colours and a blurred copy of [source], which stays with the caller.
  static Future<CoverMimicData?> blurCover(ui.Image source) async {
    final width = source.width;
    final height = source.height;
    final bytes = await source.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) return null;
    final look = mimicLookOf(sampleCoverZones(bytes, width, height));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.saveLayer(
      bounds,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: mimicBlurSigma,
          sigmaY: mimicBlurSigma,
          tileMode: TileMode.mirror,
        ),
    );
    canvas.drawImage(
      source,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(width, height);
    picture.dispose();
    return CoverMimicData(blurred, look);
  }
}

/// Everything the backdrop paints, and its transitions. Painters listen to it
/// and read its caches, so a steady frame allocates nothing: shaders and
/// paints are rebuilt only while colours change or the layout does.
class CoverMimicScene extends ChangeNotifier {
  CoverMimicScene({this.animated = true});

  /// Without it the backdrop changes at once and never drifts.
  bool animated;

  ui.Image? _image;
  ui.Image? _previousImage;
  CoverMimicLook _from = CoverMimicLook.neutral;
  CoverMimicLook _to = CoverMimicLook.neutral;
  List<Color> _colors = CoverMimicLook.neutral.colors;
  double _veil = CoverMimicLook.neutral.veil;
  double _mix = 1;
  double _startedAt = 0;
  double _durationSeconds = 0.6;
  double _clock = 0;
  double _lastRepaint = -1;
  bool _live = false;
  double _artworkHeight = 0;

  int _paintVersion = 0;
  int _preparedVersion = -1;
  Size _preparedSize = Size.zero;
  final Paint _base = Paint();
  final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = false
    ..colorFilter = ColorFilter.matrix(_saturation(mimicImageSaturation));
  final Paint _previousPaint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = false
    ..colorFilter = ColorFilter.matrix(_saturation(mimicImageSaturation));
  final Paint _veilPaint = Paint();
  final List<Paint> _blobs = [for (var i = 0; i < mimicZoneCount; i++) Paint()];
  Rect _imageSource = Rect.zero;
  Rect _previousSource = Rect.zero;
  Rect _imageTarget = Rect.zero;
  Rect _previousTarget = Rect.zero;
  Rect _screen = Rect.zero;

  static List<double> _saturation(double s) {
    const r = 0.2126;
    const g = 0.7152;
    const b = 0.0722;
    return [
      r * (1 - s) + s, g * (1 - s), b * (1 - s), 0, 0, //
      r * (1 - s), g * (1 - s) + s, b * (1 - s), 0, 0, //
      r * (1 - s), g * (1 - s), b * (1 - s) + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }

  /// Colours currently painted, one per zone.
  List<Color> get colors => _colors;

  /// Black veil alpha currently painted at the top.
  double get veil => _veil;

  bool get transitioning => _mix < 1;

  /// Seconds the backdrop has lived, drift included.
  double get clock => _clock;

  bool get hasImage => _image != null;

  /// Called when a transition starts, so its owner can wake the clock.
  VoidCallback? onWake;

  set artworkHeight(double value) {
    if (value == _artworkHeight) return;
    _artworkHeight = value;
    _paintVersion++;
    notifyListeners();
  }

  /// Starts mutating to [look] over [duration]; with [image] the blurred
  /// cover cross-fades too. A null [image] with [swapImage] fades it out.
  void apply(
    CoverMimicLook look, {
    ui.Image? image,
    bool swapImage = true,
    Duration duration = mimicAdaptDuration,
    bool live = false,
  }) {
    _from = CoverMimicLook(_colors, _veil);
    _to = look;
    if (swapImage) {
      _previousImage?.dispose();
      _previousImage = _image;
      _image = image?.clone();
    }
    _live = live;
    _startedAt = _clock;
    _durationSeconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    _mix = 0;
    if (!animated) _finish();
    _paintVersion++;
    notifyListeners();
    if (transitioning) onWake?.call();
  }

  /// Colour step of an animated cover's current frame, with the same image.
  void applyLive(CoverMimicLook look) {
    var changed = false;
    for (var i = 0; i < look.colors.length && !changed; i++) {
      final a = _to.colors[i];
      final b = look.colors[i];
      changed =
          (a.r - b.r).abs() > 0.012 ||
          (a.g - b.g).abs() > 0.012 ||
          (a.b - b.b).abs() > 0.012;
    }
    if (!changed) {
      if (!_live) {
        _live = true;
        _paintVersion++;
        notifyListeners();
      }
      return;
    }
    apply(look, swapImage: false, duration: mimicLiveAdaptDuration, live: true);
  }

  void _finish() {
    _mix = 1;
    _colors = _to.colors;
    _veil = _to.veil;
    _previousImage?.dispose();
    _previousImage = null;
  }

  /// Advances the clock to [seconds]; repaints only when something moves.
  void tick(double seconds) {
    _clock = seconds;
    if (_mix < 1) {
      final raw = ((seconds - _startedAt) / _durationSeconds).clamp(0.0, 1.0);
      if (raw >= 1) {
        _finish();
      } else {
        final eased = mimicEase(raw);
        _mix = raw;
        _colors = lerpMimicColors(_from.colors, _to.colors, eased);
        _veil = _from.veil + (_to.veil - _from.veil) * eased;
      }
      _paintVersion++;
      notifyListeners();
    } else if (animated && seconds - _lastRepaint >= mimicRepaintInterval) {
      _lastRepaint = seconds;
      notifyListeners();
    }
  }

  void _prepare(Size size) {
    if (_preparedVersion == _paintVersion && _preparedSize == size) return;
    _preparedVersion = _paintVersion;
    _preparedSize = size;
    _screen = Offset.zero & size;
    _base.color = Color.lerp(_colors[2], _colors[3], 0.5)!.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(_base.color);
    _base.color = hsl.withLightness(hsl.lightness * 0.5).toColor();
    final image = _image;
    final previous = _previousImage;
    if (image != null) {
      _imageSource = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      _imageTarget = _cover(image, size);
    }
    if (previous != null) {
      _previousSource = Rect.fromLTWH(
        0,
        0,
        previous.width.toDouble(),
        previous.height.toDouble(),
      );
      _previousTarget = _cover(previous, size);
    }
    final live = _live ? mimicLiveImageOpacity : mimicImageOpacity;
    final fadeIn = image == null ? 0.0 : _mix;
    _imagePaint.color = Color.fromRGBO(255, 255, 255, live * fadeIn);
    _previousPaint.color = Color.fromRGBO(
      255,
      255,
      255,
      live * (image == null ? 1 - _mix : 1),
    );
    for (var i = 0; i < mimicZoneCount; i++) {
      final color = _colors[i];
      _blobs[i].shader = ui.Gradient.radial(
        Offset.zero,
        1,
        [
          color.withValues(alpha: mimicBlobOpacity),
          color.withValues(alpha: mimicBlobOpacity * 0.5),
          color.withValues(alpha: 0),
        ],
        const [0, 0.5, 1],
      );
    }
    final bottom = (_veil + mimicVeilBottomBoost).clamp(0.0, 0.9);
    _veilPaint.shader =
        ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          Colors.black.withValues(alpha: _veil),
          Colors.black.withValues(alpha: bottom),
        ]);
  }

  static Rect _cover(ui.Image image, Size size) {
    final scale = size.width / image.width > size.height / image.height
        ? size.width / image.width
        : size.height / image.height;
    final width = image.width * scale;
    final height = image.height * scale;
    return Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
  }

  /// Paints the whole backdrop over [size].
  void draw(Canvas canvas, Size size) {
    _prepare(size);
    canvas.drawRect(_screen, _base);
    if (_previousImage != null) {
      canvas.drawImageRect(
        _previousImage!,
        _previousSource,
        _previousTarget,
        _previousPaint,
      );
    }
    if (_image != null) {
      canvas.drawImageRect(_image!, _imageSource, _imageTarget, _imagePaint);
    }
    final w = size.width;
    final h = _artworkHeight > 0 ? _artworkHeight : size.height * 0.5;
    for (var i = 0; i < mimicZoneCount; i++) {
      final radius =
          (i == 4 ? mimicCenterRadius : mimicCornerRadius) *
          w *
          mimicBreath(i, _clock);
      canvas.save();
      canvas.translate(
        _anchors[i].dx * w + mimicDrift(i, _clock, vertical: false) * w,
        _anchors[i].dy * h + mimicDrift(i, _clock, vertical: true) * h,
      );
      canvas.scale(radius);
      canvas.drawRect(_unit, _blobs[i]);
      canvas.restore();
    }
    canvas.drawRect(_screen, _veilPaint);
  }

  static const Rect _unit = Rect.fromLTRB(-1, -1, 1, 1);

  @override
  void dispose() {
    _image?.dispose();
    _previousImage?.dispose();
    _image = null;
    _previousImage = null;
    super.dispose();
  }
}

class _MimicPainter extends CustomPainter {
  _MimicPainter(this.scene) : super(repaint: scene);

  final CoverMimicScene scene;

  @override
  void paint(Canvas canvas, Size size) => scene.draw(canvas, size);

  @override
  bool shouldRepaint(_MimicPainter oldDelegate) => oldDelegate.scene != scene;

  @override
  bool? hitTest(Offset position) => false;
}

class _MimicFadePainter extends CustomPainter {
  _MimicFadePainter(this.scene, this.top, this.bottom) : super(repaint: scene);

  final CoverMimicScene scene;
  final double top;
  final double bottom;
  static final Paint _layer = Paint();
  static final Paint _mask = Paint()..blendMode = BlendMode.dstIn;
  double _maskTop = -1;
  double _maskBottom = -1;

  @override
  void paint(Canvas canvas, Size size) {
    if (bottom <= top) return;
    final rect = Rect.fromLTRB(0, top, size.width, bottom);
    if (_maskTop != top || _maskBottom != bottom) {
      _maskTop = top;
      _maskBottom = bottom;
      _mask.shader = ui.Gradient.linear(
        rect.topCenter,
        rect.bottomCenter,
        [
          const Color(0x00ffffff),
          const Color(0x33ffffff),
          const Color(0xb3ffffff),
          const Color(0xffffffff),
        ],
        const [0, 0.3, 0.7, 1],
      );
    }
    canvas.saveLayer(rect, _layer);
    scene.draw(canvas, size);
    canvas.drawRect(rect, _mask);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MimicFadePainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.top != top ||
      oldDelegate.bottom != bottom;

  @override
  bool? hitTest(Offset position) => false;
}

/// The backdrop, isolated in its own layer.
class CoverMimicLayer extends StatelessWidget {
  const CoverMimicLayer({super.key, required this.scene});

  final CoverMimicScene scene;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _MimicPainter(scene), size: Size.infinite),
  );
}

/// The backdrop over the lower part of the artwork, fading in from [top] to
/// [bottom] so the artwork melts into it without an edge.
class CoverMimicFade extends StatelessWidget {
  const CoverMimicFade({
    super.key,
    required this.scene,
    required this.top,
    required this.bottom,
  });

  final CoverMimicScene scene;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _MimicFadePainter(scene, top, bottom),
      size: Size.infinite,
    ),
  );
}

/// Where the live sampler finds the boundary of an animated cover.
class CoverMimicLiveSource {
  RenderRepaintBoundary? boundary;

  /// Height share of the bottom strip that tints the lower zones; zero keeps
  /// the corner zones.
  double bottomBand = 0;
}

/// Marks its child as the animated cover [source] samples.
class CoverMimicLiveBoundary extends SingleChildRenderObjectWidget {
  const CoverMimicLiveBoundary({
    super.key,
    required this.source,
    required super.child,
  });

  final CoverMimicLiveSource source;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _LiveBoundary(source);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _LiveBoundary).source = source;
}

class _LiveBoundary extends RenderRepaintBoundary {
  _LiveBoundary(this.source);

  CoverMimicLiveSource source;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    source.boundary = this;
  }

  @override
  void detach() {
    if (identical(source.boundary, this)) source.boundary = null;
    super.detach();
  }
}

/// Owns the [CoverMimicScene] of one cover: resolves its image, follows it
/// when the track changes, and with [live] re-samples the animated cover.
class CoverMimicScope extends StatefulWidget {
  const CoverMimicScope({
    super.key,
    required this.source,
    required this.artworkHeight,
    required this.builder,
    this.live = false,
    this.liveSource,
  });

  /// A cover string in any form [coverImageSource] reads; null is neutral.
  final String? source;
  final double artworkHeight;
  final bool live;
  final CoverMimicLiveSource? liveSource;
  final Widget Function(BuildContext context, CoverMimicScene scene) builder;

  /// Tests turn the endless drift off so their frames can settle; colour
  /// changes still animate.
  @visibleForTesting
  static bool debugAmbientDrift = true;

  @override
  State<CoverMimicScope> createState() => _CoverMimicScopeState();
}

class _CoverMimicScopeState extends State<CoverMimicScope>
    with SingleTickerProviderStateMixin {
  final CoverMimicScene _scene = CoverMimicScene();
  late final Ticker _ticker;
  double _clockBase = 0;
  Timer? _liveTimer;
  int _generation = 0;
  bool _sampling = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _scene.tick(_clockBase + elapsed.inMicroseconds / 1e6);
      if (!CoverMimicScope.debugAmbientDrift && !_scene.transitioning) {
        _ticker.stop();
      }
    });
    _scene.onWake = _syncTicker;
    _scene.artworkHeight = widget.artworkHeight;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animated = !MediaQuery.disableAnimationsOf(context);
    _scene.animated = animated;
    _syncTicker();
    if (!animated && _scene.transitioning) _scene.tick(double.maxFinite);
    _syncLive();
  }

  void _syncTicker() {
    final run =
        _scene.animated &&
        (CoverMimicScope.debugAmbientDrift || _scene.transitioning);
    if (run && !_ticker.isActive) {
      _clockBase = _scene.clock;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(CoverMimicScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scene.artworkHeight = widget.artworkHeight;
    if (oldWidget.source != widget.source) _sync();
    if (oldWidget.live != widget.live) _syncLive();
  }

  void _syncLive() {
    final want =
        widget.live &&
        widget.liveSource != null &&
        !MediaQuery.disableAnimationsOf(context);
    if (want && _liveTimer == null) {
      _liveTimer = Timer.periodic(
        mimicLiveSampleInterval,
        (_) => unawaited(_sampleLive()),
      );
    } else if (!want) {
      _liveTimer?.cancel();
      _liveTimer = null;
    }
  }

  Future<void> _sampleLive() async {
    if (_sampling || !mounted || !TickerMode.valuesOf(context).enabled) return;
    final boundary = widget.liveSource?.boundary;
    if (boundary == null ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.size.isEmpty ||
        boundary.debugNeedsPaint) {
      return;
    }
    _sampling = true;
    ui.Image? image;
    try {
      final scale = (mimicLiveSampleWidth / boundary.size.width).clamp(
        0.01,
        1.0,
      );
      image = await boundary.toImage(pixelRatio: scale);
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (bytes == null || !mounted) return;
      _scene.applyLive(
        mimicLookOf(
          sampleCoverZones(
            bytes,
            image.width,
            image.height,
            bottomBand: widget.liveSource?.bottomBand ?? 0,
          ),
        ),
      );
    } catch (_) {
      // The next sample tries again; the still cover colours stay meanwhile.
    } finally {
      image?.dispose();
      _sampling = false;
    }
  }

  void _sync() {
    final source = widget.source;
    final generation = ++_generation;
    if (source == null || source.isEmpty) {
      _scene.apply(CoverMimicLook.neutral);
      return;
    }
    final cached = CoverMimicCache.peek(source);
    if (cached != null) {
      _scene.apply(cached.look, image: cached.image);
    }
    CoverMimicCache.resolve(source).then(
      (data) {
        if (!mounted || _generation != generation) return;
        if (data == null) {
          _scene.apply(CoverMimicLook.neutral);
        } else if (!identical(data, cached)) {
          _scene.apply(data.look, image: data.image);
        }
      },
      onError: (Object _) {
        if (mounted && _generation == generation) {
          _scene.apply(CoverMimicLook.neutral);
        }
      },
    );
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _ticker.dispose();
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _scene);
}
