import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show computeHitSlop;

/// Owns the long press for both selection and playlist dragging. The card
/// inside must not register a competing onLongPress gesture.
class LibraryPlaylistDragSource<T extends Object> extends StatefulWidget {
  const LibraryPlaylistDragSource({
    super.key,
    required this.data,
    required this.onSelect,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.feedbackBuilder,
    required this.child,
    this.onDragUpdate,
    this.onPointerRelease,
    this.onDragSourceDisposed,
    this.onAmbiguousRelease,
    this.enabled = true,
  });

  final T data;
  final VoidCallback onSelect;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final WidgetBuilder feedbackBuilder;
  final Widget child;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final ValueChanged<Offset>? onPointerRelease;
  final VoidCallback? onDragSourceDisposed;
  final VoidCallback? onAmbiguousRelease;
  final bool enabled;

  @override
  State<LibraryPlaylistDragSource<T>> createState() =>
      _LibraryPlaylistDragSourceState<T>();
}

class _LibraryPlaylistDragSourceState<T extends Object>
    extends State<LibraryPlaylistDragSource<T>>
    with AutomaticKeepAliveClientMixin {
  bool _dragging = false;
  int? _pointer;
  final Map<int, Offset> _eligiblePointers = {};
  ValueChanged<Offset>? _releaseForDrag;
  ValueChanged<DragUpdateDetails>? _updateForDrag;
  VoidCallback? _disposeForDrag;
  VoidCallback? _endForDrag;
  VoidCallback? _ambiguousForDrag;
  bool _ambiguousReleased = false;

  @override
  void dispose() {
    if (_dragging) _disposeForDrag?.call();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => _dragging;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Listener(
      onPointerDown: (event) {
        if (!_dragging) _eligiblePointers[event.pointer] = event.position;
      },
      onPointerMove: (event) {
        final start = _eligiblePointers[event.pointer];
        if (!_dragging &&
            start != null &&
            (event.position - start).distance >
                computeHitSlop(
                  event.kind,
                  MediaQuery.maybeGestureSettingsOf(context),
                )) {
          _eligiblePointers.remove(event.pointer);
        }
      },
      onPointerUp: (event) {
        _eligiblePointers.remove(event.pointer);
        if (_dragging && event.pointer == _pointer) {
          _releaseForDrag?.call(event.position);
        } else if (_dragging && _pointer == null) {
          _ambiguousReleased = true;
        }
      },
      onPointerCancel: (event) {
        _eligiblePointers.remove(event.pointer);
      },
      child: Semantics(
        onLongPress: widget.onSelect,
        child: LongPressDraggable<T>(
          data: widget.data,
          maxSimultaneousDrags: widget.enabled ? 1 : 0,
          dragAnchorStrategy: (draggable, dragContext, position) {
            final candidates = _eligiblePointers.entries
                .where((entry) => entry.value == position)
                .map((entry) => entry.key)
                .toList(growable: false);
            // Equal initial coordinates cannot identify which recognizer won.
            // Leave the manual drop unresolved instead of using another finger.
            _pointer = candidates.length == 1 ? candidates.single : null;
            return childDragAnchorStrategy(draggable, dragContext, position);
          },
          hapticFeedbackOnStart: false,
          onDragStarted: () {
            setState(() => _dragging = true);
            _releaseForDrag = widget.onPointerRelease;
            _updateForDrag = widget.onDragUpdate;
            _disposeForDrag = widget.onDragSourceDisposed;
            _endForDrag = widget.onDragEnd;
            _ambiguousForDrag = widget.onAmbiguousRelease;
            _ambiguousReleased = false;
            updateKeepAlive();
            widget.onDragStarted();
            widget.onSelect();
          },
          onDragUpdate: (details) => _updateForDrag?.call(details),
          onDragEnd: (_) {
            setState(() => _dragging = false);
            _pointer = null;
            _releaseForDrag = null;
            _updateForDrag = null;
            _disposeForDrag = null;
            updateKeepAlive();
            if (_ambiguousReleased) _ambiguousForDrag?.call();
            _ambiguousForDrag = null;
            _ambiguousReleased = false;
            final onEnd = _endForDrag;
            _endForDrag = null;
            onEnd?.call();
          },
          // Build after onSelect so the feedback reflects the selected batch.
          feedback: Builder(builder: widget.feedbackBuilder),
          child: Opacity(opacity: _dragging ? 0.4 : 1, child: widget.child),
        ),
      ),
    );
  }
}
