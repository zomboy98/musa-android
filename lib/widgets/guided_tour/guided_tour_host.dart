import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/guided_tour_provider.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_overlay.dart';

/// Shows the first-run guided tour above [child] and starts it once, when
/// nothing else is covering the shell.
class GuidedTourHost extends ConsumerStatefulWidget {
  const GuidedTourHost({
    super.key,
    required this.anchors,
    required this.child,
    this.enabled = true,
    this.startDelay = const Duration(milliseconds: 1500),
  });

  final GuidedTourAnchors anchors;
  final Widget child;
  final bool enabled;
  final Duration startDelay;

  @override
  ConsumerState<GuidedTourHost> createState() => _GuidedTourHostState();
}

class _GuidedTourHostState extends ConsumerState<GuidedTourHost> {
  Timer? _timer;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _schedule(widget.startDelay);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _tryStart);
  }

  void _tryStart() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent && _attempts++ < 30) {
      _schedule(const Duration(seconds: 2));
      return;
    }
    unawaited(ref.read(guidedTourProvider.notifier).startIfFirstTime());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running =
        widget.enabled &&
        ref.watch(guidedTourProvider.select((state) => state.running));
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (running)
          Positioned.fill(child: GuidedTourOverlay(anchors: widget.anchors)),
      ],
    );
  }
}
