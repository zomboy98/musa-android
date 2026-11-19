import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/quality_badge_art.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

/// The playing format as a bare logo (no plate); tapping it opens a compact glass
/// popover anchored to it with the formats the song can be switched to. While a switch is
/// under way, [pendingMark] shows the requested logo greyed and [progress]
/// fills it in.
class TrackQualitySelector extends StatefulWidget {
  const TrackQualitySelector({
    super.key,
    required this.currentFormat,
    required this.currentLabel,
    required this.choices,
    required this.onSelected,
    this.onShowInfo,
    this.switching = false,
    this.replacesFile = false,
    this.colorScheme,
    this.height = 30,
    this.badgeSize,
    this.progress,
    this.currentMark,
    this.currentDetail,
    this.pendingMark,
    this.pendingDetail,
    this.lockup = false,
    this.trackKey,
    this.onCancelSwitch,
    this.compactLockup = false,
    this.onCurrentTapped,
    this.requestedNote,
    this.capsule = false,
  });

  final bool capsule;
  final QualityBadgeFormat currentFormat;
  final String currentLabel;
  final List<TrackQualityChoice> choices;
  final ValueChanged<TrackQualityChoice> onSelected;
  final VoidCallback? onShowInfo;
  final bool switching;
  final bool replacesFile;
  final ColorScheme? colorScheme;
  final double height;
  final double? badgeSize;
  final double? progress;
  final QualityMark? currentMark;
  final String? currentDetail;
  final QualityMark? pendingMark;
  final String? pendingDetail;

  /// Draws the timeline-row form (glyph, name and two small lines) instead of
  /// the compact logo.
  final bool lockup;

  final Object? trackKey;
  final VoidCallback? onCancelSwitch;
  final bool compactLockup;
  final VoidCallback? onCurrentTapped;
  final String? requestedNote;

  @override
  State<TrackQualitySelector> createState() => _TrackQualitySelectorState();
}

class _TrackQualitySelectorState extends State<TrackQualitySelector> {
  final _anchor = GlobalKey();
  Route<void>? _route;

  @override
  void didUpdateWidget(TrackQualitySelector old) {
    super.didUpdateWidget(old);
    if (_route == null) return;
    if (old.trackKey != widget.trackKey ||
        _signature(old.choices) != _signature(widget.choices)) {
      _close();
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  static String _signature(List<TrackQualityChoice> choices) => [
    for (final choice in choices)
      '${choice.service}|${choice.id}|${choice.available}|${choice.checking}|${choice.current}',
  ].join(';');

  void _close() {
    final route = _route;
    _route = null;
    if (route == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  List<TrackQualityChoice> get _offers => [
    for (final choice in widget.choices)
      if (choice.available) choice,
  ];

  Rect? _measure() {
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _open() {
    if (_route != null) {
      _close();
      return;
    }
    final offers = _offers;
    if (_measure() == null) return;
    final theme = Theme.of(context);
    final scheme = widget.colorScheme ?? theme.colorScheme;
    final cancel = widget.switching ? widget.onCancelSwitch : null;
    late final _QualityRoute route;
    route = _QualityRoute(
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (routeContext) => _QualityWindow(
        measure: _measure,
        theme: theme,
        scheme: scheme,
        choices: offers,
        currentLabel: widget.currentLabel,
        currentMark:
            widget.currentMark ?? qualityMarkForFormat(widget.currentFormat),
        onRemoved: () {
          if (_route == route) _route = null;
          if (route.isActive) route.navigator?.removeRoute(route);
        },
        onShowInfo: widget.onShowInfo,
        onCancelSwitch: cancel,
        requestedNote: widget.requestedNote,
        onSelected: (choice) {
          if (choice.current) {
            widget.onCurrentTapped?.call();
          } else {
            widget.onSelected(choice);
          }
        },
      ),
    );
    _route = route;
    Navigator.of(context, rootNavigator: true).push<void>(route);
  }

  Widget _plate(Color color, Widget child) => widget.capsule
      ? DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.22)),
          ),
          child: child,
        )
      : child;

  Widget _logo(QualityMark mark, String? detail, Color color) {
    if (widget.lockup) {
      return QualityMarkLockup(
        mark: mark,
        detail: detail,
        color: color,
        size: widget.badgeSize ?? 26,
        compact: widget.compactLockup,
      );
    }
    return QualityBadgeArt(
      format: qualityFormatForMark(mark),
      mark: mark,
      size: widget.badgeSize ?? (widget.height < 28 ? 15 : 18),
      color: color,
      semanticLabel: widget.currentLabel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final currentMark =
        widget.currentMark ?? qualityMarkForFormat(widget.currentFormat);
    final pending = widget.pendingMark;
    final shown = pending ?? currentMark;
    final detail = pending != null
        ? widget.pendingDetail
        : widget.currentDetail;
    final filling = pending != null || widget.progress != null;
    final color = scheme.onSurface;
    Widget content;
    if (filling) {
      final target = (widget.progress ?? 0).clamp(0.0, 1.0);
      content = TweenAnimationBuilder<double>(
        tween: Tween(end: target),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        builder: (context, fill, _) => Stack(
          children: [
            Opacity(opacity: 0.32, child: _logo(shown, detail, color)),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: fill,
                heightFactor: 1,
                child: _logo(shown, detail, color),
              ),
            ),
          ],
        ),
      );
    } else {
      content = Opacity(
        opacity: widget.switching ? 0.6 : 1,
        child: _logo(shown, detail, color),
      );
    }
    return Semantics(
      button: true,
      label: '${l10n.qualityPickerTitle}: ${widget.currentLabel}',
      value: widget.switching ? l10n.qualityPickerSwitching : null,
      child: Tooltip(
        message: widget.currentLabel,
        excludeFromSemantics: true,
        child: InkWell(
          key: _anchor,
          borderRadius: BorderRadius.circular(widget.capsule ? 999 : 10),
          onTap: _open,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.height),
            child: _plate(
              color,
              Padding(
                padding: widget.capsule
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 3)
                    : const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Center(
                  widthFactor: 1,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: KeyedSubtree(
                      key: ValueKey((shown, detail)),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityRoute extends PopupRoute<void> {
  _QualityRoute({required this.builder, required this.label});

  final WidgetBuilder builder;
  final String label;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => label;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);
}

class _QualityEntry {
  const _QualityEntry(this.choice, [this.group = const []]);

  final TrackQualityChoice choice;
  final List<TrackQualityChoice> group;

  bool get isGroup => group.length > 1;

  bool get current => isGroup ? group.any((c) => c.current) : choice.current;
}

List<_QualityEntry> _entriesFor(List<TrackQualityChoice> choices) {
  final groups = <QualityMark, List<TrackQualityChoice>>{};
  for (final choice in choices) {
    if (isLossyMark(choice.mark)) {
      groups.putIfAbsent(choice.mark, () => []).add(choice);
    }
  }
  for (final group in groups.values) {
    final order = {for (final c in group.indexed) c.$2: c.$1};
    group.sort((a, b) {
      final byRate = (bitrateOfDetail(b.detail) ?? 0).compareTo(
        bitrateOfDetail(a.detail) ?? 0,
      );
      return byRate != 0 ? byRate : order[a]!.compareTo(order[b]!);
    });
  }
  final entries = <_QualityEntry>[];
  final placed = <QualityMark>{};
  for (final choice in choices) {
    final group = groups[choice.mark];
    if (group == null || group.length < 2) {
      entries.add(_QualityEntry(choice));
    } else if (placed.add(choice.mark)) {
      entries.add(_QualityEntry(group.first, group));
    }
  }
  return entries;
}

String? _groupRange(List<TrackQualityChoice> group) {
  final rates = [
    for (final c in group)
      if (bitrateOfDetail(c.detail) != null) bitrateOfDetail(c.detail)!,
  ]..sort();
  if (rates.isEmpty) return null;
  if (rates.first == rates.last) return '${rates.last} kbps';
  return '${rates.first}–${rates.last} kbps';
}

const _softText = 0.9;
const _rowHeight = 52.0;
const _headerHeight = 48.0;
const _iconDisc = 30.0;
const _popoverWidth = 300.0;
const _popoverWidthFraction = 0.78;
const _popoverHeightFraction = 0.70;
const _popoverRadius = 26.0;
const _popoverGap = 8.0;
const _popoverMargin = 12.0;
const _enterDuration = Duration(milliseconds: 200);
const _exitDuration = Duration(milliseconds: 160);
const _confirmDuration = Duration(milliseconds: 140);
const _startScale = 0.92;

class _PopoverMotion {
  _PopoverMotion(TickerProvider vsync)
    : controller = AnimationController(
        vsync: vsync,
        duration: _enterDuration,
        reverseDuration: _exitDuration,
      ) {
    scale = Tween(begin: _startScale, end: 1.0).animate(
      CurvedAnimation(
        parent: controller,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    fade = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
  }

  final AnimationController controller;
  late final Animation<double> scale;
  late final Animation<double> fade;

  void start(bool reduce) {
    if (reduce) {
      controller.value = 1;
    } else {
      controller.forward();
    }
  }

  Future<void> reverse(bool reduce) async {
    if (!reduce) await controller.reverse();
  }

  void dispose() => controller.dispose();
}

Alignment _originFor(Rect anchor, double left, double width, bool below) {
  final x = width <= 0
      ? 0.0
      : (((anchor.center.dx - left) / width) * 2 - 1).clamp(-1.0, 1.0);
  return Alignment(x, below ? -1 : 1);
}

class _QualityWindow extends StatefulWidget {
  const _QualityWindow({
    required this.measure,
    required this.theme,
    required this.scheme,
    required this.choices,
    required this.currentLabel,
    required this.currentMark,
    required this.onRemoved,
    required this.onSelected,
    this.onShowInfo,
    this.onCancelSwitch,
    this.requestedNote,
  });

  final String currentLabel;
  final QualityMark currentMark;

  final String? requestedNote;
  final Rect? Function() measure;
  final ThemeData theme;
  final ColorScheme scheme;
  final List<TrackQualityChoice> choices;
  final VoidCallback onRemoved;
  final ValueChanged<TrackQualityChoice> onSelected;
  final VoidCallback? onShowInfo;
  final VoidCallback? onCancelSwitch;

  @override
  State<_QualityWindow> createState() => _QualityWindowState();
}

class _QualityWindowState extends State<_QualityWindow>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final List<_QualityEntry> _entries = _entriesFor(widget.choices);
  late final _PopoverMotion _motion = _PopoverMotion(this);
  late Rect _anchor = widget.measure() ?? Rect.zero;
  final _groupKeys = <QualityMark, GlobalKey>{};
  final _subKey = GlobalKey<_QualityGroupMenuState>();
  Rect? _subCell;
  List<TrackQualityChoice> _subChoices = const [];
  String? _confirmed;
  bool _leaving = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _motion.start(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leaving) return;
      final anchor = widget.measure();
      if (anchor == null) {
        _dismiss();
      } else if (anchor != _anchor || _subCell != null) {
        setState(() {
          _anchor = anchor;
          _subCell = null;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  Future<void> _dismiss([VoidCallback? after]) async {
    if (_leaving) return;
    _leaving = true;
    after?.call();
    await _motion.reverse(MediaQuery.disableAnimationsOf(context));
    widget.onRemoved();
  }

  Future<void> _pick(TrackQualityChoice choice) async {
    if (_leaving || _confirmed != null) return;
    final reduce = MediaQuery.disableAnimationsOf(context);
    widget.onSelected(choice);
    if (!mounted) return;
    setState(() => _confirmed = choice.id);
    if (!reduce) await Future<void>.delayed(_confirmDuration);
    if (!mounted) return;
    _dismiss();
  }

  void _openGroup(_QualityEntry entry) {
    final box =
        _groupKeys[entry.choice.mark]?.currentContext?.findRenderObject()
            as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    setState(() {
      _subChoices = entry.group;
      _subCell = box.localToGlobal(Offset.zero) & box.size;
    });
  }

  void _closeSub() {
    final menu = _subKey.currentState;
    if (menu == null) {
      if (_subCell != null) setState(() => _subCell = null);
      return;
    }
    menu.close();
  }

  void _back() {
    if (_subCell != null) {
      _closeSub();
    } else {
      _dismiss();
    }
  }

  Widget _onlyCurrent(Color fg, AppLocalizations l10n) {
    return Padding(
      key: const ValueKey('track-quality-only-current'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              QualityBadgeArt(
                format: qualityFormatForMark(widget.currentMark),
                mark: widget.currentMark,
                size: 22,
                color: fg,
                semanticLabel: widget.currentLabel,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.currentLabel,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.qualityPickerNoOtherQualities,
            style: TextStyle(
              color: fg.withValues(alpha: _softText),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(_QualityEntry entry, ColorScheme scheme) {
    if (entry.isGroup) {
      final range = _groupRange(entry.group);
      return _FormatCell(
        key: _groupKeys.putIfAbsent(entry.choice.mark, GlobalKey.new),
        inkKey: ValueKey('quality-choice-group-${entry.choice.mark.name}'),
        choice: entry.choice,
        scheme: scheme,
        current: entry.current,
        detail: range,
        tagged: false,
        semanticLabel: [
          qualityMarkText(context, entry.choice.mark).name,
          ?range,
        ].join(', '),
        chevron: true,
        onTap: () {
          if (_subCell == null) {
            _openGroup(entry);
          } else {
            _closeSub();
          }
        },
      );
    }
    return _FormatCell(
      choice: entry.choice,
      scheme: scheme,
      current: entry.choice.current || _confirmed == entry.choice.id,
      onTap: entry.choice.checking ? () {} : () => _pick(entry.choice),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final theme = widget.theme.copyWith(colorScheme: scheme);
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final anchor = _anchor;
    final width = math.min(
      _popoverWidth,
      math.min(
        size.width * _popoverWidthFraction,
        size.width - padding.horizontal - _popoverMargin * 2,
      ),
    );
    final left = (anchor.center.dx - width / 2)
        .clamp(
          padding.left + _popoverMargin,
          math.max(
            padding.left + _popoverMargin,
            size.width - padding.right - _popoverMargin - width,
          ),
        )
        .toDouble();
    final below = size.height - padding.bottom - anchor.bottom - _popoverGap;
    final above = anchor.top - padding.top - _popoverGap;
    final need = _headerHeight + math.max(_entries.length, 1) * _rowHeight + 12;
    final opensDown = below >= need || below >= above;
    final room = (opensDown ? below : above) - _popoverMargin;
    final maxHeight = math.max(
      _rowHeight + _headerHeight,
      math.min(size.height * _popoverHeightFraction, room),
    );
    final lossless = <_QualityEntry>[];
    final lossy = <_QualityEntry>[];
    for (final entry in _entries) {
      (isLossyMark(entry.choice.mark) ? lossy : lossless).add(entry);
    }
    final fg = scheme.onSurface;
    final rows = <Widget>[
      for (final entry in lossless) _cell(entry, scheme),
      if (lossless.isNotEmpty && lossy.isNotEmpty)
        Divider(
          height: 9,
          thickness: 0.5,
          indent: 16,
          endIndent: 16,
          color: fg.withValues(alpha: 0.16),
        ),
      for (final entry in lossy) _cell(entry, scheme),
      if (_entries.isEmpty) _onlyCurrent(fg, l10n),
    ];
    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _headerHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 18, end: 4),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  l10n.qualityPickerTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg.withValues(alpha: _softText),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
            if (widget.onShowInfo != null)
              Tooltip(
                message: l10n.audioInfoTitle,
                child: IconButton(
                  key: const ValueKey('track-quality-info'),
                  onPressed: () => _dismiss(widget.onShowInfo),
                  iconSize: 20,
                  color: fg.withValues(alpha: _softText),
                  icon: const Icon(Icons.info_outline_rounded),
                ),
              ),
          ],
        ),
      ),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Flexible(
          child: _FadingScroll(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onCancelSwitch != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: const ValueKey('track-quality-cancel'),
                        onPressed: () => _dismiss(widget.onCancelSwitch),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(l10n.qualityPickerCancelSwitch),
                      ),
                    ),
                  ...rows,
                  if (widget.requestedNote != null)
                    Padding(
                      key: const ValueKey('track-quality-requested-note'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                      child: Text(
                        widget.requestedNote!,
                        style: TextStyle(
                          color: fg.withValues(alpha: _softText),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Theme(
        data: theme,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    label: MaterialLocalizations.of(
                      context,
                    ).modalBarrierDismissLabel,
                    child: GestureDetector(
                      key: const ValueKey('track-quality-scrim'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _dismiss,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Positioned(
                  left: left,
                  top: opensDown ? anchor.bottom + _popoverGap : null,
                  bottom: opensDown
                      ? null
                      : size.height - anchor.top + _popoverGap,
                  width: width,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: ScaleTransition(
                      scale: _motion.scale,
                      alignment: _originFor(anchor, left, width, opensDown),
                      child: mornyeMenuGlass(
                        context,
                        key: const ValueKey('track-quality-panel'),
                        radius: _popoverRadius,
                        child: FadeTransition(
                          opacity: _motion.fade,
                          child: content,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_subCell != null)
                  Positioned.fill(
                    child: _QualityGroupMenu(
                      key: _subKey,
                      cell: _subCell!,
                      choices: _subChoices,
                      scheme: scheme,
                      onClosed: () {
                        if (mounted) setState(() => _subCell = null);
                      },
                      onPicked: _pick,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Softens the rows that scroll out of the popover instead of cutting them.
class _FadingScroll extends StatefulWidget {
  const _FadingScroll({required this.child});

  final Widget child;

  @override
  State<_FadingScroll> createState() => _FadingScrollState();
}

class _FadingScrollState extends State<_FadingScroll> {
  static const _edge = 18.0;
  bool _top = false;
  bool _bottom = false;

  bool _update(ScrollMetrics metrics) {
    final top = metrics.extentBefore > 1;
    final bottom = metrics.extentAfter > 1;
    if (top != _top || bottom != _bottom) {
      setState(() {
        _top = top;
        _bottom = bottom;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _update(n.metrics);
        });
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _update(n.metrics),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final f = rect.height <= 0
                ? 0.0
                : (_edge / rect.height).clamp(0.0, 0.5);
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, f, 1 - f, 1],
              colors: [
                _top ? const Color(0x00ffffff) : const Color(0xffffffff),
                const Color(0xffffffff),
                const Color(0xffffffff),
                _bottom ? const Color(0x00ffffff) : const Color(0xffffffff),
              ],
            ).createShader(rect);
          },
          child: widget.child,
        ),
      ),
    );
  }
}

QualityMarkText _textFor(
  BuildContext context,
  TrackQualityChoice choice,
  String? detail, {
  bool tagged = true,
}) {
  final text = qualityMarkText(context, choice.mark, detail: detail);
  final tag = tagged ? choice.tag : null;
  if (tag == null) return text;
  return QualityMarkText(
    text.name,
    text.first,
    text.second == null ? tag : '${text.second} · $tag',
  );
}

class _QualityGroupMenu extends StatefulWidget {
  const _QualityGroupMenu({
    super.key,
    required this.cell,
    required this.choices,
    required this.scheme,
    required this.onClosed,
    required this.onPicked,
  });

  final Rect cell;
  final List<TrackQualityChoice> choices;
  final ColorScheme scheme;
  final VoidCallback onClosed;
  final ValueChanged<TrackQualityChoice> onPicked;

  @override
  State<_QualityGroupMenu> createState() => _QualityGroupMenuState();
}

class _QualityGroupMenuState extends State<_QualityGroupMenu>
    with SingleTickerProviderStateMixin {
  late final _PopoverMotion _motion = _PopoverMotion(this);
  bool _started = false;
  bool _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _motion.start(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _motion.reverse(MediaQuery.disableAnimationsOf(context));
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final cell = widget.cell;
    final width = math.min(
      _popoverWidth - 20,
      size.width - _popoverMargin * 2 - padding.horizontal,
    );
    final onLeft = cell.center.dx < size.width / 2;
    final left = (onLeft ? cell.left + 6 : cell.right - width - 6)
        .clamp(
          _popoverMargin,
          math.max(_popoverMargin, size.width - _popoverMargin - width),
        )
        .toDouble();
    final need = widget.choices.length * _rowHeight + 16;
    final below = size.height - padding.bottom - cell.bottom - 8;
    final above = cell.top - padding.top - 8;
    final opensDown = below >= need || below >= above;
    final maxHeight = math.max(
      _rowHeight + 16,
      math.min(size.height * _popoverHeightFraction, opensDown ? below : above),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: opensDown ? cell.bottom - 6 : null,
          bottom: opensDown ? null : size.height - cell.top - 6,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ScaleTransition(
              scale: _motion.scale,
              alignment: _originFor(
                Rect.fromLTWH(cell.right - 20, cell.top, 0, cell.height),
                left,
                width,
                opensDown,
              ),
              child: mornyeMenuGlass(
                context,
                key: const ValueKey('track-quality-group-menu'),
                radius: _popoverRadius - 4,
                child: FadeTransition(
                  opacity: _motion.fade,
                  child: _FadingScroll(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final choice in widget.choices)
                            _QualityGroupRow(
                              choice: choice,
                              scheme: widget.scheme,
                              onTap: () => widget.onPicked(choice),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _QualityGroupRow extends StatelessWidget {
  const _QualityGroupRow({
    required this.choice,
    required this.scheme,
    required this.onTap,
  });

  final TrackQualityChoice choice;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = qualityMarkText(context, choice.mark).name;
    final detail = choice.detail;
    final title = detail == null || choice.mark == QualityMark.lossy
        ? choice.label
        : '$name $detail';
    final provider = qualityServiceShortName(choice.service);
    final showLabel =
        title != choice.label &&
        !choice.label.toLowerCase().contains(name.toLowerCase());
    final subtitle = [
      if (provider.isNotEmpty) provider,
      if (showLabel) choice.label,
    ].join(' · ');
    final fg = scheme.onSurface;
    return Semantics(
      button: true,
      selected: choice.current,
      label: [title, if (subtitle.isNotEmpty) subtitle].join(', '),
      value: choice.current ? context.l10n.qualityPickerCurrent : null,
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: choice.current
              ? fg.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('quality-choice-${choice.id}'),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _rowHeight - 2),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    QualityBadgeArt(
                      format: choice.format,
                      mark: choice.mark,
                      iconOnly: true,
                      size: 22,
                      color: fg,
                      semanticLabel: choice.label,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: 15,
                              height: 1.15,
                              fontWeight: choice.current
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg.withValues(alpha: _softText),
                                fontSize: 12,
                                height: 1.15,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (choice.current)
                      Icon(Icons.check_rounded, size: 20, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _rowTitle(BuildContext context, QualityMark mark, String fallback) =>
    switch (mark) {
      QualityMark.atmos => 'Atmos',
      QualityMark.max => 'Max',
      QualityMark.hiRes => 'Hi-Res',
      QualityMark.dolbyPlus => 'Dolby Digital Plus',
      QualityMark.lossless => context.l10n.qualityFormatLossless,
      QualityMark.opus => 'Opus',
      QualityMark.lossy => context.l10n.qualityFormatLossy,
      _ => fallback,
    };

class _FormatCell extends StatelessWidget {
  const _FormatCell({
    super.key,
    required this.choice,
    required this.scheme,
    required this.onTap,
    this.current,
    this.detail,
    this.semanticLabel,
    this.inkKey,
    this.chevron = false,
    this.tagged = true,
  });

  final TrackQualityChoice choice;
  final ColorScheme scheme;
  final VoidCallback onTap;
  final bool? current;
  final String? detail;
  final String? semanticLabel;
  final Key? inkKey;
  final bool chevron;
  final bool tagged;

  @override
  Widget build(BuildContext context) {
    final text = _textFor(
      context,
      choice,
      detail ?? (tagged ? choice.detail : null),
      tagged: tagged,
    );
    final isCurrent = current ?? choice.current;
    final checking = choice.checking;
    final fg = scheme.onSurface;
    final title = _rowTitle(context, choice.mark, text.name);
    final description = [
      for (final line
          in checking ? [_checkingLabel(context)] : [text.first, ?text.second])
        if (line.toLowerCase() != title.toLowerCase()) line,
    ].join(' · ');
    return Semantics(
      button: true,
      selected: isCurrent,
      label: semanticLabel ?? choice.label,
      value: isCurrent ? context.l10n.qualityPickerCurrent : null,
      excludeSemantics: true,
      onTap: checking ? null : onTap,
      child: Opacity(
        opacity: checking ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Material(
            color: isCurrent ? fg.withValues(alpha: 0.12) : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: isCurrent
                  ? BorderSide(color: fg.withValues(alpha: 0.16), width: 0.8)
                  : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: inkKey ?? ValueKey('quality-choice-${choice.id}'),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _rowHeight - 2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Container(
                        key: const ValueKey('quality-row-icon'),
                        width: _iconDisc,
                        height: _iconDisc,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: fg.withValues(alpha: 0.10),
                        ),
                        child: QualityBadgeArt(
                          format: choice.format,
                          mark: choice.mark,
                          iconOnly: true,
                          size: 18,
                          color: fg,
                          semanticLabel: choice.label,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg,
                                fontSize: 15,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (description.isNotEmpty)
                              Text(
                                description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: fg.withValues(alpha: _softText),
                                  fontSize: 12,
                                  height: 1.2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check_rounded, size: 20, color: fg),
                      ],
                      if (chevron) ...[
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: fg.withValues(alpha: _softText),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _checkingLabel(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'es'
    ? 'Comprobando…'
    : 'Checking…';
