import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum GuidedTourTarget {
  home,
  search,
  library,
  miniPlayer,
  store,
  settings,
  profile,
  code,
  catalog,
  homeSource,
  finale,
}

const List<GuidedTourTarget> guidedTourOrder = [
  GuidedTourTarget.home,
  GuidedTourTarget.search,
  GuidedTourTarget.library,
  GuidedTourTarget.miniPlayer,
  GuidedTourTarget.store,
  GuidedTourTarget.settings,
  GuidedTourTarget.profile,
  GuidedTourTarget.code,
  GuidedTourTarget.catalog,
  GuidedTourTarget.homeSource,
  GuidedTourTarget.finale,
];

enum GuidedTourScreen { shell, extensions, sources }

enum GuidedTourTap { advance, passThrough, block }

GuidedTourScreen guidedTourScreenOf(GuidedTourTarget target) =>
    switch (target) {
      GuidedTourTarget.code => GuidedTourScreen.extensions,
      GuidedTourTarget.catalog ||
      GuidedTourTarget.homeSource => GuidedTourScreen.sources,
      _ => GuidedTourScreen.shell,
    };

GuidedTourTap guidedTourTapOf(GuidedTourTarget target) => switch (target) {
  GuidedTourTarget.home ||
  GuidedTourTarget.search ||
  GuidedTourTarget.library ||
  GuidedTourTarget.store ||
  GuidedTourTarget.settings ||
  GuidedTourTarget.finale => GuidedTourTap.advance,
  GuidedTourTarget.code ||
  GuidedTourTarget.catalog ||
  GuidedTourTarget.homeSource => GuidedTourTap.passThrough,
  GuidedTourTarget.miniPlayer ||
  GuidedTourTarget.profile => GuidedTourTap.block,
};

final guidedTourAnchorsProvider = Provider<GuidedTourAnchors>(
  (ref) => GuidedTourAnchors(),
);

class _Registered {
  _Registered(this.context);

  final BuildContext context;
  bool current = true;
}

class GuidedTourAnchors {
  final GlobalKey navKey = GlobalKey(debugLabel: 'guidedTourNav');
  final GlobalKey miniPlayerKey = GlobalKey(debugLabel: 'guidedTourPlayer');

  Map<GuidedTourTarget, int> _navSlots = const {};
  int _navSlotCount = 0;
  bool _sliceable = false;
  Axis _axis = Axis.horizontal;
  double _inset = 0;
  bool _homeHasSearch = false;
  bool _profileEntry = false;
  VoidCallback? _prepare;
  Future<void> Function(GuidedTourScreen screen)? _openScreen;
  final Map<GuidedTourTarget, List<_Registered>> _registered = {};

  bool get homeHasSearch => _homeHasSearch;

  void configure({
    Map<GuidedTourTarget, int> navSlots = const {},
    int navSlotCount = 0,
    bool sliceable = false,
    Axis axis = Axis.horizontal,
    double inset = 0,
    bool homeHasSearch = false,
    bool profileEntry = false,
    VoidCallback? prepare,
    Future<void> Function(GuidedTourScreen screen)? openScreen,
  }) {
    _navSlots = navSlots;
    _navSlotCount = navSlotCount;
    _sliceable = sliceable;
    _axis = axis;
    _inset = inset;
    _homeHasSearch = homeHasSearch;
    _profileEntry = profileEntry;
    _prepare = prepare;
    _openScreen = openScreen;
  }

  void prepare() => _prepare?.call();

  Future<void> openScreen(GuidedTourScreen screen) async =>
      _openScreen?.call(screen);

  Object register(GuidedTourTarget target, BuildContext context) {
    final entry = _Registered(context);
    (_registered[target] ??= []).add(entry);
    return entry;
  }

  void unregister(GuidedTourTarget target, Object token) {
    _registered[target]?.remove(token);
  }

  void setCurrent(Object token, {required bool current}) {
    (token as _Registered).current = current;
  }

  RenderBox? _box(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object;
  }

  RenderBox? _boxOf(BuildContext context) {
    if (!context.mounted) return null;
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object;
  }

  Rect? _rectOf(GlobalKey key, RenderObject ancestor) {
    final box = _box(key);
    return box == null ? null : _toRect(box, ancestor);
  }

  Rect? _toRect(RenderBox box, RenderObject ancestor) {
    if (box.size.isEmpty) return null;
    try {
      return box.localToGlobal(Offset.zero, ancestor: ancestor) & box.size;
    } catch (_) {
      return null;
    }
  }

  Iterable<_Registered> _live(GuidedTourTarget target) sync* {
    for (final entry in _registered[target] ?? const <_Registered>[]) {
      if (entry.current && _boxOf(entry.context) != null) yield entry;
    }
  }

  bool isAvailable(GuidedTourTarget target) {
    switch (target) {
      case GuidedTourTarget.miniPlayer:
        final box = _box(miniPlayerKey);
        return box != null && box.size.height > 8 && box.size.width > 8;
      case GuidedTourTarget.profile:
        return _profileEntry && _live(target).isNotEmpty;
      case GuidedTourTarget.code:
      case GuidedTourTarget.catalog:
      case GuidedTourTarget.homeSource:
        return _openScreen != null;
      default:
        return _navSlots.containsKey(target);
    }
  }

  BuildContext? scrollContextFor(GuidedTourTarget target) {
    if (guidedTourScreenOf(target) == GuidedTourScreen.shell) return null;
    return _live(target).firstOrNull?.context;
  }

  Rect? rectFor(GuidedTourTarget target, RenderObject ancestor) {
    switch (target) {
      case GuidedTourTarget.miniPlayer:
        final rect = _rectOf(miniPlayerKey, ancestor);
        return rect == null || rect.height <= 8 ? null : rect;
      case GuidedTourTarget.profile:
      case GuidedTourTarget.code:
      case GuidedTourTarget.catalog:
      case GuidedTourTarget.homeSource:
        return _registeredRect(target, ancestor);
      default:
        return _navRect(target, ancestor);
    }
  }

  Rect? _registeredRect(GuidedTourTarget target, RenderObject ancestor) {
    final bounds = ancestor is RenderBox ? Offset.zero & ancestor.size : null;
    final onShell = guidedTourScreenOf(target) == GuidedTourScreen.shell;
    Rect? offscreen;
    for (final entry in _live(target)) {
      final rect = _toRect(_boxOf(entry.context)!, ancestor);
      if (rect == null) continue;
      if (bounds == null || bounds.contains(rect.center)) return rect;
      offscreen ??= rect;
    }
    return onShell ? null : offscreen;
  }

  Rect? _navRect(GuidedTourTarget target, RenderObject ancestor) {
    final slot = _navSlots[target];
    if (slot == null) return null;
    final bar = _rectOf(navKey, ancestor);
    if (bar == null) return null;
    if (!_sliceable || _navSlotCount <= 0) return bar;
    if (_axis == Axis.horizontal) {
      final inner = bar.deflate(_inset).intersect(bar);
      final width = inner.width / _navSlotCount;
      return Rect.fromLTWH(
        inner.left + width * slot,
        bar.top,
        width,
        bar.height,
      );
    }
    final height = bar.height / _navSlotCount;
    return Rect.fromLTWH(bar.left, bar.top + height * slot, bar.width, height);
  }
}
