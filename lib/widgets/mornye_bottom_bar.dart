import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// Deliberate vertical drags fold the chrome; a deliberate drag back the other
/// way (or reaching the page's top) unfolds it. Horizontal rows, programmatic
/// scrolling and bounce must not toggle it.
class MornyeChromeController extends ValueNotifier<bool> {
  MornyeChromeController() : super(false);

  /// Accumulated drag, in dp, needed in one direction to fold or unfold. The
  /// distance restarts on every change of direction and after each toggle, so
  /// small jitters never flip the bar back and forth.
  static const toggleDistance = 36.0;

  /// Pages shorter than this never fold the chrome: there is nothing to
  /// scroll away from.
  static const minFoldableExtent = 96.0;

  double _distance = 0;

  void expand() {
    _distance = 0;
    value = false;
  }

  bool handleScroll(ScrollNotification notification) {
    // Library's active list sits inside a PageView and NestedScrollView. Its
    // drag notifications have a greater depth than the outer header's scroll.
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _distance = 0;
    }
    if (notification is! ScrollUpdateNotification) return false;
    final metrics = notification.metrics;
    if (metrics.pixels <= metrics.minScrollExtent + 12) {
      // The Library list can reach its start while its outer header is still
      // collapsed. Restore the tabs only when both scroll positions return.
      final outer = notification.context
          ?.findAncestorStateOfType<NestedScrollViewState>()
          ?.outerController;
      if (outer != null &&
          outer.positions.any((p) => p.pixels > p.minScrollExtent + 12)) {
        return false;
      }
      expand();
      return false;
    }
    if (metrics.outOfRange || notification.dragDetails == null) return false;
    final delta = notification.scrollDelta ?? 0;
    if (delta == 0) return false;
    if (_distance.sign != delta.sign) _distance = 0;
    _distance += delta;
    if (!value &&
        _distance >= toggleDistance &&
        metrics.maxScrollExtent - metrics.minScrollExtent >=
            minFoldableExtent) {
      value = true;
      _distance = 0;
    } else if (value && _distance <= -toggleDistance) {
      // Scrolling back toward the top unfolds at once, without having to
      // reach the very top of the list.
      expand();
    }
    return false;
  }
}

/// The tabs' foreground leaves early, before the glass under it narrows past
/// the outer tabs, and stays bounded while the spring overshoots.
class _TabOpacity extends Animatable<double> {
  const _TabOpacity();

  @override
  double transform(double t) => (1 - t / 0.45).clamp(0.0, 1.0);
}

/// A single mini-player survives the transition, preserving its artwork Hero,
/// playback controls and track swipe gestures as the tabs fold away.
class MornyeBottomBar extends ConsumerStatefulWidget {
  const MornyeBottomBar({
    super.key,
    required this.collapsed,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.onHome,
    required this.onSearch,
    required this.blurEnabled,
    this.searchIndex,
    this.onExpand,
  }) : assert(
         searchIndex == null ||
             (searchIndex >= 0 && searchIndex < destinations.length),
       );

  final bool collapsed;
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onHome;
  final VoidCallback onSearch;
  final bool blurEnabled;

  /// Search's position in [destinations]; defaults to the legacy last tab.
  final int? searchIndex;

  /// Called when the folded bar's own background is tapped.
  final VoidCallback? onExpand;

  @override
  ConsumerState<MornyeBottomBar> createState() => _MornyeBottomBarState();
}

class _MornyeBottomBarState extends ConsumerState<MornyeBottomBar>
    with SingleTickerProviderStateMixin {
  // A spring keeps its velocity when a scroll reverses the fold mid-flight. It
  // is stiff enough to settle within about 220 ms.
  static const _foldSpring = SpringDescription(
    mass: 1,
    stiffness: 1200,
    damping: 58,
  );

  /// Runs past 0 and 1 by the spring's overshoot.
  late final _controller = AnimationController.unbounded(
    vsync: this,
    value: widget.collapsed ? 1 : 0,
  );
  late double _target = widget.collapsed ? 1 : 0;
  late final _tabOpacity = _controller.drive(const _TabOpacity());
  // Side capsules move between backdrop batches; keep their lenses mounted.
  final _leadingSurfaceKey = GlobalKey();
  final _searchSurfaceKey = GlobalKey();

  void _updateCollapse() {
    final target = widget.collapsed ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _target = target;
      _controller.value = target;
      return;
    }
    if (target == _target) return;
    _target = target;
    _controller.animateWith(
      SpringSimulation(
        _foldSpring,
        _controller.value,
        target,
        _controller.velocity,
        snapToEnd: true,
        tolerance: const Tolerance(distance: 0.02, velocity: 0.4),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCollapse();
  }

  @override
  void didUpdateWidget(MornyeBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed != widget.collapsed) _updateCollapse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collapsed = widget.collapsed;
    final destinations = widget.destinations;
    final selectedIndex = widget.selectedIndex;
    final onSelected = widget.onSelected;
    final onHome = widget.onHome;
    final onSearch = widget.onSearch;
    final blurEnabled = widget.blurEnabled;
    final hasPlayer =
        ref.watch(playerUiEnabledProvider) &&
        ref.watch(
          currentMediaItemProvider.select((item) => item.value != null),
        );
    final liquidGlass = ref.watch(mornyeLiquidGlassProvider);
    // Animated glass tabs already reserve 8px above their visible capsule.
    final glassTabs = MornyeTabBar.usesLiquidGlass(
      context,
      blurEnabled: blurEnabled,
      liquidGlass: liquidGlass,
      contrastBlocked: ref.watch(
        mornyeGlassContrastBlockedProvider(MediaQuery.highContrastOf(context)),
      ),
    );
    final tabGap = glassTabs ? 0.0 : 8.0;
    // These contents do not depend on animation progress. Retain their widget
    // instances so folding only updates geometry and foreground opacity. A
    // backdrop inside a fading layer loses access to the page behind the bar.
    Widget sideSurface(Key key) => RepaintBoundary(
      key: key,
      child: MornyeGlass.navigation(
        blurEnabled: blurEnabled,
        strongTint: true,
        tintOpacity: MornyeTheme.navigationOpacity(context),
        radius: 26,
        child: const SizedBox.expand(),
      ),
    );
    final leadingSurface = sideSurface(_leadingSurfaceKey);
    final searchSurface = sideSurface(_searchSurfaceKey);
    final searchIndex = widget.searchIndex ?? destinations.length - 1;
    // With the three phone shortcuts (Home, Search, Library) the folded bar
    // shows the two OTHER destinations, in canonical order, around the player.
    // Other layouts keep the legacy pair: the active tab and Search.
    final shortcutMode = destinations.length == 3;
    final shortcuts = shortcutMode
        ? [
            for (var i = 0; i < 3; i++)
              if (i != selectedIndex) i,
          ]
        : const <int>[];
    final leadingIndex = shortcutMode
        ? shortcuts[0]
        : selectedIndex == searchIndex
        ? 0
        : selectedIndex;
    final trailingIndex = shortcutMode ? shortcuts[1] : searchIndex;
    void goTo(int index) {
      if (index == searchIndex) {
        onSearch();
      } else if (index == 0) {
        onHome();
      } else {
        onSelected(index);
      }
    }

    final scheme = Theme.of(context).colorScheme;
    final inactiveIconColor = scheme.onSurface;
    final player = MiniPlayer(compact: collapsed, bottomPadding: 0);
    Widget tabs({required bool hideMovingIcons}) => TickerMode(
      enabled: !collapsed,
      child: RepaintBoundary(
        child: MornyeTabBar(
          destinations: destinations,
          selectedIndex: selectedIndex,
          onSelected: (index) =>
              index == searchIndex ? onSearch() : onSelected(index),
          blurEnabled: blurEnabled,
          liquidGlass: liquidGlass,
          contentOpacity: _tabOpacity,
          fold: _controller,
          hiddenIconIndices: hideMovingIcons
              ? {leadingIndex, trailingIndex}
              : const {},
        ),
      ),
    );
    // At rest the glass bar must paint its own active icon: its selected layer
    // follows a dragged pill before the destination is committed. Hand them
    // to the moving overlays only while folding, at the same coordinates.
    final fullTabs = tabs(hideMovingIcons: false);
    final foldingTabs = tabs(hideMovingIcons: true);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Match the tab's actual label height, including accessibility scaling.
        // Both icons stay mounted above the fading capsule for the whole trip.
        final labelStyle = Theme.of(context).textTheme.labelSmall!.copyWith(
          fontSize: glassTabs ? 11 : null,
          fontWeight: FontWeight.w600,
        );
        final labelPainter = TextPainter(
          text: TextSpan(text: destinations.first.label, style: labelStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final labelHeight = labelPainter.height;
        labelPainter.dispose();
        final fullIconBottom = glassTabs
            ? 8 + math.max(64, 37 + labelHeight) / 2 + (labelHeight + 2) / 2
            : math.max(64.0, 49 + labelHeight) - 23.5;
        final tabInset = glassTabs ? 6.0 : 5.0;
        double fullIconStart(int index) =>
            tabInset +
            (constraints.maxWidth - tabInset * 2) /
                destinations.length *
                (index + 0.5);
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final fold = _controller.value;
            // Layout stops at the ends; only the capsules take the overshoot.
            // The snap keeps the wobble around 1 from reopening the tab bar.
            final clamped = fold.clamp(0.0, 1.0);
            final amount = clamped > 0.995
                ? 1.0
                : clamped < 0.005
                ? 0.0
                : clamped;
            // A capsule grows quickly out of the bar, and stretches along its
            // path with its speed, as a drop of glass does.
            final grown =
                math.pow(clamped, 0.6) * (1 + (fold - clamped).abs() * 2);
            final stretch = (_controller.velocity.abs() * 0.045).clamp(
              0.0,
              0.28,
            );
            final drop = Matrix4.diagonal3Values(
              grown * (1 + stretch),
              grown * (1 - stretch * 0.6),
              1,
            );
            Widget movingIcon({
              required bool leading,
              required Widget surface,
            }) {
              final index = leading ? leadingIndex : trailingIndex;
              final origin = fullIconStart(index);
              final offset =
                  ((leading ? origin : constraints.maxWidth - origin) - 26) *
                  (1 - amount);
              const size = 52.0;
              return PositionedDirectional(
                start: leading ? offset : null,
                end: leading ? null : offset,
                bottom: fullIconBottom * (1 - amount) + 34 * amount - 26,
                width: size,
                height: size,
                child: IgnorePointer(
                  ignoring: amount < 0.5,
                  child: ExcludeSemantics(
                    excluding: amount < 0.5,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: Offstage(
                            // The tab bar's own glass becomes the leading
                            // circle and hands over only once it is one.
                            offstage: leading ? amount < 1 : amount == 0,
                            child: Transform(
                              alignment: Alignment.center,
                              transform: drop,
                              transformHitTests: false,
                              // While folding, a capsule crosses the tab bar
                              // and needs a backdrop sample of its own.
                              child: amount == 1
                                  ? surface
                                  : LiquidGlassBatch(child: surface),
                            ),
                          ),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: Semantics(
                            button: true,
                            label: destinations[index].label,
                            excludeSemantics: true,
                            child: IconButton(
                              key: ValueKey(
                                leading
                                    ? 'mornye-compact-leading'
                                    : shortcutMode
                                    ? 'mornye-compact-trailing'
                                    : 'mornye-compact-search',
                              ),
                              tooltip: shortcutMode || leading
                                  ? destinations[index].label
                                  : context.l10n.mornyeSearch,
                              iconSize: 25,
                              constraints: BoxConstraints.tightFor(
                                width: size,
                                height: size,
                              ),
                              color: index == selectedIndex
                                  ? scheme.primary
                                  : inactiveIconColor,
                              icon: Opacity(
                                opacity: amount == 0 ? 0 : 1,
                                child: destinations[index].icon,
                              ),
                              onPressed: shortcutMode
                                  ? () => goTo(index)
                                  : leading
                                  ? leadingIndex == 0
                                        ? onHome
                                        : () => onSelected(leadingIndex)
                                  : onSearch,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            // Only non-overlapping surfaces share a backdrop: the player, the
            // tabs and, at rest, the side capsules. Frosted capsules stay out
            // of the blur group, since they cross the tab bar while folding.
            return LiquidGlassBatch(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (collapsed && widget.onExpand != null)
                    // Behind the player and shortcuts: only the bar's bare
                    // background reaches it.
                    Positioned.fill(
                      child: GestureDetector(
                        key: const ValueKey('mornye-compact-background'),
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onExpand,
                      ),
                    ),
                  BackdropGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      // Laid out top to bottom, but painted bottom first: the
                      // player settles in front of the shrinking tab bar.
                      verticalDirection: VerticalDirection.up,
                      children: [
                        Offstage(
                          // Retain tab state, but drop its backdrop layers only
                          // after the last visible frame of the fold.
                          offstage: amount == 1,
                          // Unclipped: the bar's glass narrows and shortens
                          // into the leading circle as one shape.
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            heightFactor: 1 - amount,
                            child: IgnorePointer(
                              ignoring: amount > 0.5,
                              child: ExcludeSemantics(
                                excluding: amount > 0.5,
                                child: amount == 0 ? fullTabs : foldingTabs,
                              ),
                            ),
                          ),
                        ),
                        if (hasPlayer || amount > 0)
                          Align(
                            alignment: Alignment.bottomCenter,
                            // With no track, introducing the row at full height would
                            // make the bar jump taller on the first animation frame.
                            heightFactor: hasPlayer ? 1 : amount,
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom: hasPlayer
                                    ? tabGap + (8 - tabGap) * amount
                                    : 8,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 60 * amount,
                                    height: hasPlayer ? 48 + 4 * amount : 52,
                                  ),
                                  Expanded(child: player),
                                  SizedBox(
                                    width: 60 * amount,
                                    height: hasPlayer ? 48 + 4 * amount : 52,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  movingIcon(leading: true, surface: leadingSurface),
                  movingIcon(leading: false, surface: searchSurface),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
