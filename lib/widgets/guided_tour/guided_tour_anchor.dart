import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';

class TourAnchor extends ConsumerStatefulWidget {
  const TourAnchor({super.key, required this.target, required this.child});

  final GuidedTourTarget target;
  final Widget child;

  @override
  ConsumerState<TourAnchor> createState() => _TourAnchorState();
}

class _TourAnchorState extends ConsumerState<TourAnchor> {
  late final GuidedTourAnchors _anchors;
  late final Object _token;

  @override
  void initState() {
    super.initState();
    _anchors = ref.read(guidedTourAnchorsProvider);
    _token = _anchors.register(widget.target, context);
  }

  @override
  void dispose() {
    _anchors.unregister(widget.target, _token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _anchors.setCurrent(
      _token,
      current: ModalRoute.isCurrentOf(context) ?? true,
    );
    return widget.child;
  }
}
