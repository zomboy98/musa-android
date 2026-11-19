import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/library_home_strings.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/add_to_music_sheet.dart';

/// The player's "+": adds the playing song to the library, or removes it.
/// The star beside it marks a favorite, which is always a library song.
class PlayerLibraryButton extends ConsumerStatefulWidget {
  const PlayerLibraryButton({
    super.key,
    required this.mediaItem,
    this.color,
    this.iconSize = 24,
    this.padding = const EdgeInsets.all(8),
  });

  final MediaItem mediaItem;
  final Color? color;
  final double iconSize;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<PlayerLibraryButton> createState() =>
      _PlayerLibraryButtonState();
}

class _PlayerLibraryButtonState extends ConsumerState<PlayerLibraryButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final provider = playerCollectionTrackProvider(widget.mediaItem);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final track = await ref.read(provider.future);
      if (!mounted) return;
      await showAddToMusicSheet(context, ref, track);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = ref
        .watch(playerCollectionTrackProvider(widget.mediaItem))
        .value;
    final inLibrary = ref.watch(
      librarySongKeysProvider.select(
        (keys) => track != null && keys.contains(trackCollectionKey(track)),
      ),
    );
    final strings = LibraryHomeStrings.of(context);
    return Semantics(
      toggled: inLibrary,
      child: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: MornyePlaybackButton(
          key: ValueKey(inLibrary),
          icon: inLibrary
              ? CupertinoIcons.checkmark_circle_fill
              : CupertinoIcons.plus_circle,
          tooltip: inLibrary ? strings.removeFromLibrary : strings.addToLibrary,
          color: widget.color ?? Theme.of(context).colorScheme.onSurface,
          iconSize: widget.iconSize,
          padding: widget.padding,
          onPressed: _busy ? null : _toggle,
        ),
      ),
    );
  }
}
