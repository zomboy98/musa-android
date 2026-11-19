import 'package:flutter/material.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:mornye/widgets/track_video_chip.dart';

/// Shows the video chip only for a song whose tag says it has a video. A song
/// without a tag is searched once in the background; changing song cancels
/// the search that is still running.
class TrackVideoGate extends StatefulWidget {
  const TrackVideoGate({
    super.key,
    required this.track,
    required this.lookup,
    required this.onPressed,
    this.active = false,
    this.loading = false,
    this.colorScheme,
  });

  final Track track;
  final TrackVideoLookup lookup;
  final ValueChanged<TrackVideoTag> onPressed;
  final bool active;
  final bool loading;
  final ColorScheme? colorScheme;

  @override
  State<TrackVideoGate> createState() => _TrackVideoGateState();
}

class _TrackVideoGateState extends State<TrackVideoGate> {
  TrackVideoTag? _tag;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _resolve(widget.track);
  }

  @override
  void didUpdateWidget(TrackVideoGate old) {
    super.didUpdateWidget(old);
    if (trackCollectionKey(old.track) != trackCollectionKey(widget.track)) {
      old.lookup.cancel(old.track);
      _tag = null;
      _resolve(widget.track);
    }
  }

  @override
  void dispose() {
    widget.lookup.cancel(widget.track);
    _request++;
    super.dispose();
  }

  Future<void> _resolve(Track track) async {
    final request = ++_request;
    final tag = await widget.lookup.tagFor(track);
    if (!mounted || request != _request) return;
    setState(() => _tag = tag);
  }

  @override
  Widget build(BuildContext context) {
    final tag = _tag;
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      layoutBuilder: (current, previous) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: current ?? const SizedBox.shrink(),
      ),
      child: tag != null && tag.hasVideo
          ? TrackVideoChip(
              key: const ValueKey('track-video-chip'),
              active: widget.active,
              loading: widget.loading,
              colorScheme: widget.colorScheme,
              onPressed: widget.loading ? null : () => widget.onPressed(tag),
            )
          : const SizedBox.shrink(key: ValueKey('track-video-none')),
    );
  }
}
