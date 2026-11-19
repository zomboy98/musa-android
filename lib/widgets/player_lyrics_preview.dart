import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_timing_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/widgets/lyrics_align_picker.dart';
import 'package:mornye/widgets/track_video_chip.dart';

const double playerLyricsPreviewMaxHeight = 92;
const double playerLyricsPreviewPillGap = 14;
const double playerLyricsPreviewHandleWidth = 26;
const Duration playerLyricsPreviewLineDuration = Duration(milliseconds: 420);
const Duration playerLyricsPreviewSlideDuration = Duration(milliseconds: 320);

const double _verticalPad = 4;
const double _lineGap = 3;
const int _activeMaxLines = 3;
const int _nextMaxLines = 2;
const TextStyle _lyricBase = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w700,
  height: 1.25,
);
const Color _lyricColor = Colors.white;
const List<Shadow> _lyricShadows = [
  Shadow(color: Color(0x73000000), blurRadius: 6, offset: Offset(0, 1)),
  Shadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 0.5)),
];

/// Row beside the video pill: the pill keeps its own width and the live lyrics
/// take the rest, or the whole width when the song has no video. The lyrics
/// are plain text over the player, with no box around them.
class PlayerVideoLyricsRow extends StatefulWidget {
  const PlayerVideoLyricsRow({
    super.key,
    required this.pill,
    required this.metadata,
    required this.onOpenLyrics,
    this.onLongPressLine,
  });

  final Widget pill;
  final PlayerMetadataController metadata;
  final VoidCallback onOpenLyrics;
  final ValueChanged<LyricLine>? onLongPressLine;

  @override
  State<PlayerVideoLyricsRow> createState() => _PlayerVideoLyricsRowState();
}

class _PlayerVideoLyricsRowState extends State<PlayerVideoLyricsRow> {
  final _pillKey = GlobalKey();
  Size _pill = Size.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(PlayerVideoLyricsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final box = _pillKey.currentContext?.findRenderObject();
    final size = box is RenderBox && box.hasSize ? box.size : Size.zero;
    if (size != _pill) setState(() => _pill = size);
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
          return false;
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizeChangedLayoutNotifier(
              child: KeyedSubtree(key: _pillKey, child: widget.pill),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: _pill.width > 0 ? playerLyricsPreviewPillGap : 0,
                ),
                child: PlayerLyricsPreview(
                  metadata: widget.metadata,
                  onOpen: widget.onOpenLyrics,
                  onLongPressLine: widget.onLongPressLine,
                  minHeight: _pill.height > 0
                      ? _pill.height
                      : trackVideoChipTouchHeight,
                ),
              ),
            ),
          ],
        ),
      );
}

/// The current line of the synced lyrics, with the next one dimmed. It only
/// reads what the lyrics view already loaded and never starts a search.
class PlayerLyricsPreview extends StatelessWidget {
  const PlayerLyricsPreview({
    super.key,
    required this.metadata,
    required this.onOpen,
    this.onLongPressLine,
    this.minHeight = 0,
  });

  final PlayerMetadataController metadata;
  final VoidCallback onOpen;
  final ValueChanged<LyricLine>? onLongPressLine;
  final double minHeight;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) {
      final lyrics = metadata.lyrics;
      if (metadata.loading || !lyrics.synced) return const SizedBox.shrink();
      final lines = [
        for (final line in lyrics.lines)
          if (!line.isBackground && line.text.trim().isNotEmpty) line,
      ];
      if (lines.isEmpty) return const SizedBox.shrink();
      return Consumer(
        builder: (context, ref, _) {
          final offset = ref.watch(
            lyricsTimingOffsetProvider((
              trackMs: metadata.trackOffsetMs,
              autoMs: metadata.autoOffsetMs,
            )),
          );
          final shifted = lyricsShiftedBy(
            lines,
            Duration(milliseconds: offset),
          );
          return _PreviewDock(
            onOpen: onOpen,
            body: (reveal) => _PreviewBody(
              key: ValueKey((lyrics, offset)),
              lines: shifted,
              minHeight: minHeight,
              reveal: reveal,
              onLongPressLine: onLongPressLine == null
                  ? null
                  : (line) {
                      final index = shifted.indexOf(line);
                      onLongPressLine!(index < 0 ? line : lines[index]);
                    },
            ),
          );
        },
      );
    },
  );
}

/// One-finger horizontal drag that only claims the gesture when it goes the
/// way [accepts] allows, so the opposite direction still reaches the player
/// pages behind the pill.
class _EdgeDrag extends OneSequenceGestureRecognizer {
  _EdgeDrag({required this.accepts});

  final bool Function(double dx) accepts;
  void Function()? onStart;
  void Function(double dx)? onUpdate;
  void Function(double velocity)? onEnd;
  void Function()? onCancel;

  int? _pointer;
  double _total = 0;
  bool _claimed = false;
  VelocityTracker? _tracker;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) {
      startTrackingPointer(event.pointer, event.transform);
      resolvePointer(event.pointer, GestureDisposition.rejected);
      return;
    }
    startTrackingPointer(event.pointer, event.transform);
    _pointer = event.pointer;
    _total = 0;
    _claimed = false;
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      _tracker?.addPosition(event.timeStamp, event.position);
      _total += event.delta.dx;
      if (_claimed) {
        onUpdate?.call(event.delta.dx);
      } else if (_total.abs() > 6 && !accepts(_total)) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        _pointer = null;
      } else if (_total.abs() > kTouchSlop) {
        resolve(GestureDisposition.accepted);
      }
    } else if (event is PointerUpEvent) {
      if (_claimed) {
        onEnd?.call(_tracker?.getVelocity().pixelsPerSecond.dx ?? 0);
      }
      _release(event.pointer);
    } else if (event is PointerCancelEvent) {
      if (_claimed) onCancel?.call();
      _release(event.pointer);
    }
  }

  void _release(int pointer) {
    stopTrackingPointer(pointer);
    _pointer = null;
    _claimed = false;
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _pointer) return;
    _claimed = true;
    onStart?.call();
    onUpdate?.call(_total);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _pointer) return;
    stopTrackingPointer(pointer);
    _pointer = null;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'player lyrics edge drag';
}

/// Slides the lyrics out to the right, leaving only a small handle, and
/// back. Dragging right hides it, dragging left on the handle shows it, and
/// the choice is saved.
class _PreviewDock extends ConsumerStatefulWidget {
  const _PreviewDock({required this.body, required this.onOpen});

  final Widget Function(ValueListenable<double> reveal) body;
  final VoidCallback onOpen;

  @override
  ConsumerState<_PreviewDock> createState() => _PreviewDockState();
}

class _PreviewDockState extends ConsumerState<_PreviewDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  double _travel = 1;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(
      vsync: this,
      duration: playerLyricsPreviewSlideDuration,
      value: ref.read(settingsProvider).playerLyricsPreviewHidden ? 0 : 1,
    );
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _moveTo(bool visible) {
    final target = visible ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = target;
    } else {
      _reveal.animateTo(
        target,
        duration: playerLyricsPreviewSlideDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _settle(bool visible) {
    _moveTo(visible);
    final hidden = ref.read(settingsProvider).playerLyricsPreviewHidden;
    if (hidden == visible) {
      ref
          .read(settingsProvider.notifier)
          .setPlayerLyricsPreviewHidden(!visible);
    }
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  void _dragStart() {
    _dragging = true;
    _reveal.stop();
  }

  void _dragUpdate(double dx) {
    final delta = (_rtl ? -dx : dx) / _travel;
    _reveal.value = (_reveal.value - delta).clamp(0.0, 1.0);
  }

  void _dragEnd(double velocity) {
    _dragging = false;
    final vx = velocity * (_rtl ? -1 : 1);
    _settle(vx.abs() > 350 ? vx < 0 : _reveal.value > 0.5);
  }

  void _dragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _settle(_reveal.value > 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(
      settingsProvider.select((s) => s.playerLyricsPreviewHidden),
    );
    ref.listen(settingsProvider.select((s) => s.playerLyricsPreviewHidden), (
      _,
      next,
    ) {
      if (!_dragging) _moveTo(!next);
    });
    final l10n = context.l10n;
    final rtl = _rtl;
    return LayoutBuilder(
      builder: (context, constraints) {
        _travel = math.max(
          1,
          constraints.maxWidth - playerLyricsPreviewHandleWidth,
        );
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _EdgeDrag: GestureRecognizerFactoryWithHandlers<_EdgeDrag>(
              () => _EdgeDrag(
                accepts: (dx) => (_reveal.value > 0.5 ? dx > 0 : dx < 0) ^ _rtl,
              ),
              (recognizer) {
                recognizer
                  ..onStart = _dragStart
                  ..onUpdate = _dragUpdate
                  ..onEnd = _dragEnd
                  ..onCancel = _dragCancel;
              },
            ),
          },
          child: Semantics(
            container: true,
            customSemanticsActions: {
              CustomSemanticsAction(
                label: hidden
                    ? l10n.playerLyricsPreviewShow
                    : l10n.playerLyricsPreviewHide,
              ): () =>
                  _settle(hidden),
            },
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _reveal,
                child: widget.body(_reveal),
                builder: (context, body) {
                  final shown = _reveal.value;
                  final collapsed = shown < 0.02;
                  final label = collapsed
                      ? l10n.playerLyricsPreviewShow
                      : l10n.playerLyricsPreviewOpen;
                  return Transform.translate(
                    offset: Offset((1 - shown) * _travel * (rtl ? -1 : 1), 0),
                    child: _Handled(
                      onTap: collapsed ? () => _settle(true) : widget.onOpen,
                      label: label,
                      fade: shown,
                      rtl: rtl,
                      child: body!,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Handled extends StatelessWidget {
  const _Handled({
    required this.onTap,
    required this.label,
    required this.fade,
    required this.rtl,
    required this.child,
  });

  final VoidCallback onTap;
  final String label;
  final double fade;
  final bool rtl;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: RepaintBoundary(
        child: GestureDetector(
          key: const ValueKey('player-lyrics-preview'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Stack(
            children: [
              Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: IgnorePointer(ignoring: fade < 0.5, child: child),
              ),
              PositionedDirectional(
                start: 0,
                top: 0,
                bottom: 0,
                width: playerLyricsPreviewHandleWidth,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1 - fade * 4).clamp(0.0, 1.0),
                    child: Icon(
                      rtl
                          ? Icons.chevron_right_rounded
                          : Icons.chevron_left_rounded,
                      size: 22,
                      color: _lyricColor,
                      shadows: _lyricShadows,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Fraction of [line] already sung at [position], in [0, 1]: by timed word
/// when the line carries them, linearly up to the next mark otherwise.
double lyricsLineProgress(LyricLine line, Duration? next, Duration position) {
  if (position <= line.time) return 0;
  final words = line.words;
  final joined = words.map((w) => w.text).join();
  if (words.isNotEmpty && joined.trim() == line.text.trim()) {
    final total = joined.length;
    if (total > 0) {
      var sung = 0.0;
      for (var i = 0; i < words.length; i++) {
        final word = words[i];
        final start = word.time;
        if (position <= start) break;
        var end = word.end;
        if (end == null || end <= start) {
          end = i + 1 < words.length ? words[i + 1].time : null;
        }
        end ??= line.end ?? start + const Duration(milliseconds: 650);
        sung +=
            word.text.length *
            syncedLyricSegmentProgress(
              position: position,
              start: start,
              end: end,
            );
      }
      return (sung / total).clamp(0.0, 1.0);
    }
  }
  var end = line.end ?? next ?? line.time + const Duration(seconds: 4);
  if (end <= line.time) end = line.time + const Duration(seconds: 4);
  final cap = line.time + const Duration(seconds: 10);
  if (end > cap) end = cap;
  return syncedLyricSegmentProgress(
    position: position,
    start: line.time,
    end: end,
  );
}

/// Opacity of a line [d] rows from the one being sung (negative: already
/// sung). The outgoing line is gone by the middle of a change and the incoming
/// one is mostly there, so two lines never read at once in the same place.
double lyricsPreviewLineOpacity(double d, bool previousShowsNext) {
  if (d < -1) return 0;
  if (d < 0) return (1 + 2.5 * d).clamp(0.0, 1.0);
  final sn = previousShowsNext ? 1.0 : 0.0;
  if (d <= 1) {
    final enter = (2 * (1 - d)).clamp(0.0, 1.0);
    return (1 - 0.5 * d) * (sn + (1 - sn) * enter);
  }
  return 0.5 * (2 - d) * sn;
}

class _Placed {
  const _Placed(this.index, this.top, this.height, this.opacity, this.near);

  final int index;
  final double top;
  final double height;
  final double opacity;
  final double near;
}

class _PreviewBody extends ConsumerStatefulWidget {
  const _PreviewBody({
    super.key,
    required this.lines,
    required this.minHeight,
    required this.reveal,
    this.onLongPressLine,
  });

  final List<LyricLine> lines;
  final double minHeight;
  final ValueListenable<double> reveal;
  final ValueChanged<LyricLine>? onLongPressLine;

  @override
  ConsumerState<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends ConsumerState<_PreviewBody>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _scroll;
  final _active = ValueNotifier<int>(-1);
  final _cursor = ValueNotifier<double>(-1);
  late Duration _anchor;
  Duration _anchorAt = Duration.zero;
  Duration _tick = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  double _speed = 1;
  double _from = -1;
  double _to = -1;
  bool _reduce = false;

  final _measures = <int, (int, double)>{};
  double _width = 0;
  double _maxContent = 0;
  double _measuredFor = -1;
  double _measuredScale = -1;
  TextStyle _style = _lyricBase;
  TextDirection _direction = TextDirection.ltr;
  TextScaler _scaler = TextScaler.noScaling;

  bool get _advancing => _playing && !_loading && _speed > 0;

  Duration get _now => _advancing
      ? interpolatedSyncedLyricsPosition(
          anchorPosition: _anchor,
          elapsedSinceAnchor: Duration(
            microseconds: ((_tick - _anchorAt).inMicroseconds * _speed).round(),
          ),
          isPlaying: true,
        )
      : _anchor;

  double get _scrollPosition =>
      _from +
      (_to - _from) * Curves.easeOutCubic.transform(_scroll.value.clamp(0, 1));

  @override
  void initState() {
    super.initState();
    _anchor = ref.read(playbackPositionProvider);
    _playing = ref.read(playbackPlayingProvider);
    _loading = ref.read(playbackLoadingProvider);
    _speed = _readSpeed(ref.read(playbackStateProvider).value?.speed);
    _scroll = AnimationController(
      vsync: this,
      duration: playerLyricsPreviewLineDuration,
      value: 1,
    );
    _ticker = createTicker((elapsed) {
      _tick = elapsed;
      _evaluate();
    });
    final first = _locate(_anchor);
    _active.value = first.$1;
    _cursor.value = first.$2;
    _from = _to = first.$1.toDouble();
    ref.listenManual<Duration>(playbackPositionProvider, (_, next) {
      final predicted = _now;
      _anchor = _advancing
          ? reconcileSyncedLyricsPosition(
              predictedPosition: predicted,
              reportedPosition: next,
            )
          : next;
      _anchorAt = _tick;
      _evaluate();
    });
    ref.listenManual<bool>(
      playbackPlayingProvider,
      (_, next) => _retime(() => _playing = next),
    );
    ref.listenManual<bool>(
      playbackLoadingProvider,
      (_, next) => _retime(() => _loading = next),
    );
    ref.listenManual<double>(
      playbackStateProvider.select((s) => s.value?.speed ?? 1),
      (_, next) => _retime(() => _speed = _readSpeed(next)),
    );
    _syncTicker();
  }

  double _readSpeed(double? speed) {
    if (speed == null) return 1;
    return speed.isFinite && speed > 0 ? speed : 0;
  }

  void _retime(VoidCallback change) {
    final position = _now;
    change();
    _anchor = _advancing ? position : ref.read(playbackPositionProvider);
    _syncTicker();
    _anchorAt = _tick;
    _evaluate();
  }

  void _syncTicker() {
    if (_advancing) {
      if (!_ticker.isActive) {
        _tick = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  (int, double) _locate(Duration position) {
    final lines = widget.lines;
    final index = LyricsParser.activeIndex(lines, position);
    if (index < 0) return (-1, -1);
    final next = index + 1 < lines.length ? lines[index + 1].time : null;
    return (index, index + lyricsLineProgress(lines[index], next, position));
  }

  void _evaluate() {
    if (!mounted) return;
    final (index, cursor) = _locate(_now);
    if (index != _active.value) {
      _active.value = index;
      if (_reduce) {
        _from = _to = index.toDouble();
        _scroll.value = 1;
      } else {
        _from = _scrollPosition;
        _to = index.toDouble();
        _scroll.forward(from: 0);
      }
    }
    _cursor.value = _reduce ? index.toDouble() : cursor;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduce) {
      _reduce = reduce;
      if (reduce) {
        _from = _to = _active.value.toDouble();
        _scroll.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    _active.dispose();
    _cursor.dispose();
    super.dispose();
  }

  (int, double) _measure(int k) {
    if (k < 0 || k >= widget.lines.length) return (0, 0);
    return _measures[k] ??= _compute(k);
  }

  (int, double) _compute(int k) {
    final painter = TextPainter(
      text: TextSpan(text: widget.lines[k].text.trim(), style: _style),
      textDirection: _direction,
      textScaler: _scaler,
    )..layout(maxWidth: _width);
    final metrics = painter.computeLineMetrics();
    painter.dispose();
    final total = math.max(1, metrics.length);
    double heightOf(int n) {
      var sum = 0.0;
      for (var i = 0; i < n && i < metrics.length; i++) {
        sum += metrics[i].height;
      }
      return sum;
    }

    var take = math.min(total, _activeMaxLines);
    while (take > 1 && heightOf(take) > _maxContent) {
      take--;
    }
    return (total, heightOf(take));
  }

  double _heightOf(int k) => _measure(k).$2;

  ({double active, bool next, double nextHeight, double content}) _geo(int i) {
    final active = i < 0 ? 0.0 : _heightOf(i);
    final gap = i < 0 ? 0.0 : _lineGap;
    var next = false;
    var nextHeight = 0.0;
    if (i + 1 < widget.lines.length) {
      final (count, height) = _measure(i + 1);
      next = count <= _nextMaxLines && active + gap + height <= _maxContent;
      if (next) nextHeight = height;
    }
    return (
      active: active,
      next: next,
      nextHeight: nextHeight,
      content: active + (next ? gap + nextHeight : 0),
    );
  }

  double _rowHeight(int i) =>
      math.max(widget.minHeight, _geo(i).content + 2 * _verticalPad);

  double _offsetOf(int k, int i) {
    var y = 0.0;
    final start = math.max(i, 0);
    if (k >= start) {
      for (var j = start; j < k; j++) {
        y += _heightOf(j) + _lineGap;
      }
    } else {
      for (var j = k; j < i; j++) {
        y -= _heightOf(j) + _lineGap;
      }
    }
    return y;
  }

  (double, List<_Placed>) _frame(double t) {
    final count = widget.lines.length;
    var a = t.floor().clamp(-1, count - 1);
    var frac = t - a;
    if (a >= count - 1 || frac < 0.0001) frac = 0;
    if (frac > 0.9999) {
      a += 1;
      frac = 0;
    }
    final b = frac > 0 ? a + 1 : a;
    final rowA = _rowHeight(a);
    final rowB = frac > 0 ? _rowHeight(b) : rowA;
    final topA = (rowA - _geo(a).content) / 2;
    final topB = frac > 0 ? (rowB - _geo(b).content) / 2 : topA;
    final height = rowA + (rowB - rowA) * frac;
    final placed = <_Placed>[];
    final lo = a - 1;
    for (var k = lo; k <= lo + 4; k++) {
      if (k < 0 || k >= count) continue;
      final d = k - (a + frac);
      final yA = topA + _offsetOf(k, a);
      final yB = topB + _offsetOf(k, b);
      final opacity = lyricsPreviewLineOpacity(d, _geo(k - 1).next);
      if (opacity <= 0) continue;
      placed.add(
        _Placed(
          k,
          yA + (yB - yA) * frac,
          _heightOf(k),
          opacity.clamp(0.0, 1.0),
          (1 - d.abs()).clamp(0.0, 1.0),
        ),
      );
    }
    return (height, placed);
  }

  void _longPress(double dy) {
    final t = _reduce ? _active.value.toDouble() : _scrollPosition;
    final (_, placed) = _frame(t);
    _Placed? best;
    var bestDistance = double.infinity;
    for (final line in placed) {
      if (line.opacity < 0.2) continue;
      final distance = dy < line.top
          ? line.top - dy
          : dy > line.top + line.height
          ? dy - line.top - line.height
          : 0.0;
      if (distance < bestDistance) {
        best = line;
        bestDistance = distance;
      }
    }
    if (best == null) return;
    HapticFeedback.mediumImpact();
    widget.onLongPressLine?.call(widget.lines[best.index]);
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.1);
    _scaler = scaler;
    _direction = Directionality.of(context);
    _style = DefaultTextStyle.of(context).style.merge(_lyricBase);
    final align = lyricsTextAlignFor(
      ref.watch(settingsProvider.select((s) => s.playerLyricsPreviewAlign)),
      _direction,
    );
    final anchor = switch (align) {
      TextAlign.center => Alignment.topCenter,
      TextAlign.end || TextAlign.right => AlignmentDirectional.topEnd,
      _ => AlignmentDirectional.topStart,
    };
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: widget.onLongPressLine == null
            ? null
            : (details) => _longPress(details.localPosition.dy),
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxHeight = constraints.maxHeight.isFinite
                  ? math.min(
                      constraints.maxHeight,
                      playerLyricsPreviewMaxHeight,
                    )
                  : playerLyricsPreviewMaxHeight;
              final scale = scaler.scale(14);
              if (constraints.maxWidth != _measuredFor ||
                  scale != _measuredScale) {
                _measures.clear();
                _measuredFor = constraints.maxWidth;
                _measuredScale = scale;
              }
              _width = constraints.maxWidth;
              _maxContent = math.max(0, maxHeight - 2 * _verticalPad);
              return AnimatedBuilder(
                animation: Listenable.merge([_scroll, _active, widget.reveal]),
                builder: (context, _) {
                  final t = _reduce
                      ? _active.value.toDouble()
                      : _scrollPosition;
                  final (full, placed) = _frame(t);
                  final shown = widget.reveal.value.clamp(0.0, 1.0);
                  final height =
                      widget.minHeight + (full - widget.minHeight) * shown;
                  return SizedBox(
                    height: height,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        for (final line in placed)
                          Positioned(
                            key: ValueKey(line.index),
                            left: 0,
                            right: 0,
                            top: line.top,
                            height: line.height,
                            child: Opacity(
                              opacity: line.opacity,
                              child: Transform.scale(
                                scale: 0.857 + 0.143 * line.near,
                                alignment: anchor,
                                child: _LyricRow(
                                  line: widget.lines[line.index],
                                  index: line.index,
                                  cursor: _cursor,
                                  reduce: _reduce,
                                  scaler: scaler,
                                  style: _style,
                                  direction: _direction,
                                  align: align,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SweepClipper extends CustomClipper<Path> {
  _SweepClipper({
    required this.text,
    required this.style,
    required this.scaler,
    required this.direction,
    required this.align,
    required this.index,
    required this.reduce,
    required this.cursor,
  }) : super(reclip: cursor);

  final String text;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final TextAlign align;
  final int index;
  final bool reduce;
  final ValueListenable<double> cursor;

  @override
  Path getClip(Size size) {
    final value = cursor.value;
    final fraction = reduce
        ? (value >= index ? 1.0 : 0.0)
        : (value - index).clamp(0.0, 1.0);
    final path = Path();
    if (fraction >= 1) return path..addRect(Offset.zero & size);
    if (fraction <= 0 || text.isEmpty) return path;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textAlign: align,
      textScaler: scaler,
      maxLines: _activeMaxLines,
      ellipsis: '…',
    )..layout(minWidth: size.width, maxWidth: size.width);
    final metrics = painter.computeLineMetrics();
    final sung = fraction * text.length;
    final ltr = direction == TextDirection.ltr;
    var start = 0;
    var top = 0.0;
    for (var j = 0; j < metrics.length; j++) {
      final line = metrics[j];
      final last = j == metrics.length - 1;
      final end = last
          ? text.length
          : painter.getLineBoundary(TextPosition(offset: start)).end;
      if (sung >= end) {
        path.addRect(Rect.fromLTRB(0, top, size.width, top + line.height));
      } else if (sung > start) {
        final i0 = sung.floor();
        final x0 = painter
            .getOffsetForCaret(TextPosition(offset: i0), Rect.zero)
            .dx;
        final x1 = i0 + 1 < end
            ? painter
                  .getOffsetForCaret(TextPosition(offset: i0 + 1), Rect.zero)
                  .dx
            : (ltr ? line.left + line.width : line.left);
        final x = x0 + (x1 - x0) * (sung - i0);
        path.addRect(
          ltr
              ? Rect.fromLTRB(0, top, x, top + line.height)
              : Rect.fromLTRB(x, top, size.width, top + line.height),
        );
      }
      top += line.height;
      start = end;
    }
    painter.dispose();
    return path;
  }

  @override
  bool shouldReclip(_SweepClipper oldClipper) =>
      text != oldClipper.text ||
      style != oldClipper.style ||
      scaler != oldClipper.scaler ||
      direction != oldClipper.direction ||
      align != oldClipper.align ||
      index != oldClipper.index ||
      reduce != oldClipper.reduce;
}

class _LyricRow extends StatelessWidget {
  const _LyricRow({
    required this.line,
    required this.index,
    required this.cursor,
    required this.reduce,
    required this.scaler,
    required this.style,
    required this.direction,
    required this.align,
  });

  final LyricLine line;
  final int index;
  final ValueListenable<double> cursor;
  final bool reduce;
  final TextScaler scaler;
  final TextStyle style;
  final TextDirection direction;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final text = line.text.trim();
    final dim = _lyricColor.withValues(alpha: 0.58);
    final inherited = DefaultTextStyle.of(context);
    Widget layer(Color color, {List<Shadow>? shadows, bool main = false}) {
      final layerStyle = style.copyWith(color: color, shadows: shadows);
      Widget paragraph() => main
          ? Text(
              text,
              textAlign: align,
              maxLines: _activeMaxLines,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              textScaler: scaler,
              textWidthBasis: inherited.textWidthBasis,
              textHeightBehavior: inherited.textHeightBehavior,
              style: layerStyle,
            )
          : RichText(
              text: TextSpan(text: text, style: layerStyle),
              textAlign: align,
              textDirection: direction,
              maxLines: _activeMaxLines,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              textScaler: scaler,
              textWidthBasis: inherited.textWidthBasis,
              textHeightBehavior: inherited.textHeightBehavior,
            );
      final box = SizedBox(width: double.infinity, child: paragraph());
      return main ? box : ExcludeSemantics(child: box);
    }

    return Stack(
      children: [
        layer(Colors.transparent, shadows: _lyricShadows),
        layer(dim),
        ClipPath(
          clipper: _SweepClipper(
            text: text,
            style: style,
            scaler: scaler,
            direction: direction,
            align: align,
            index: index,
            reduce: reduce,
            cursor: cursor,
          ),
          child: layer(_lyricColor, main: true),
        ),
      ],
    );
  }
}
