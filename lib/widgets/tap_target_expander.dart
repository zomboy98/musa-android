import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Makes [child] answer taps in an area at least [minHeight] tall without
/// changing the space it takes in the layout.
class TapTargetExpander extends SingleChildRenderObjectWidget {
  const TapTargetExpander({super.key, this.minHeight = 44, super.child});

  final double minHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapTargetExpander(minHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderTapTargetExpander).minHeight = minHeight;
  }
}

class _RenderTapTargetExpander extends RenderProxyBox {
  _RenderTapTargetExpander(this.minHeight);

  double minHeight;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final extra = math.max(0.0, minHeight - size.height) / 2;
    if (position.dx < 0 ||
        position.dx > size.width ||
        position.dy < -extra ||
        position.dy > size.height + extra) {
      return false;
    }
    final inside = Offset(
      math.min(position.dx, size.width - 0.01),
      position.dy.clamp(0.0, math.max(0.0, size.height - 0.01)).toDouble(),
    );
    return super.hitTest(result, position: inside);
  }
}
