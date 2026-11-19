import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/artists_sheet.dart';
import 'package:mornye/widgets/tap_target_expander.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/downloaded_format_mark.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/save_library_track_button.dart';

/// Track row shared by the album and playlist screens. Tap plays the track,
/// preferring a local copy when available. Long-press opens the
/// track options sheet. Callers supply [leading] (track number, cover art,
/// ...) and choose whether the artist name links to the artist screen.
class TrackListTile extends ConsumerWidget {
  final Track track;
  final bool isInHistory;
  final void Function({bool forceQualityPicker}) onDownload;
  final Widget leading;
  final bool clickableArtist;
  final bool showQualityBadges;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onEnterSelectionMode;
  final VoidCallback? onActivate;
  final bool playlistActions;
  final String? listContext;
  final String? listOccurrence;

  /// [leading] is cover art. See [TrackCard.leadingArtwork].
  final bool leadingArtwork;

  const TrackListTile({
    super.key,
    required this.track,
    required this.isInHistory,
    required this.onDownload,
    required this.leading,
    this.clickableArtist = true,
    this.showQualityBadges = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onToggleSelection,
    this.onEnterSelectionMode,
    this.onActivate,
    this.playlistActions = false,
    this.listContext,
    this.listOccurrence,
    this.leadingArtwork = false,
  }) : assert(!isSelectionMode || onToggleSelection != null);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final playback = listContext != null && listOccurrence != null
        ? ref.watch(
            listOccurrencePlaybackUiProvider((
              context: listContext!,
              occurrence: listOccurrence!,
            )),
          )
        : ref.watch(catalogTrackPlaybackUiProvider(catalogTrackKey(track)));

    final isQueued = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => lookup.byTrackId.containsKey(track.id),
      ),
    );

    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    // A history or library row alone is not proof: the file must still be
    // there, the same check the download button and the playlists use.
    final verified = ref.watch(playlistRealDownloadProvider(track));
    final fileVerified = verified.hasValue ? verified.requireValue : null;
    final isInLocalLibrary = showLocalLibraryIndicator && fileVerified == true;
    final showDownloadedMark = fileVerified == null
        ? isInHistory || isInLocalLibrary
        : fileVerified && (isInHistory || showLocalLibraryIndicator);

    return TrackCard(
      style: TrackCardStyle.flat,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      isCurrent: playback.isCurrent,
      isPlaying: playback.isPlaying,
      leadingArtwork: leadingArtwork,
      leading: leading,
      title: track.name,
      subtitle: TrackMetadataBadgesLine(
        primary: clickableArtist && !isSelectionMode
            ? TapTargetExpander(
                child: ClickableArtistName(
                  artistName: track.artistName,
                  artistId: track.artistId,
                  extensionId: track.source,
                  onTap: () => showArtistsSheet(
                    context,
                    ref,
                    artistas: artistsSheetArtistsFrom(
                      track.artistName,
                      track.artistId,
                      extensionId: track.source,
                    ),
                    album: ArtistsSheetAlbum.fromTrack(track),
                  ),
                ),
              )
            : Text(
                track.artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        badges: [
          ...buildQualityBadges(
            audioQuality: showQualityBadges ? track.audioQuality : null,
            audioModes: showQualityBadges ? track.audioModes : null,
            colorScheme: colorScheme,
            explicit: track.isExplicit,
          ),
        ],
        trailing: !playlistActions && showDownloadedMark
            ? DownloadedFormatMark(track: track, removable: true)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SaveLibraryTrackButton(track: track, onDownload: () => onDownload()),
          TrackCollectionQuickActions(
            track: track,
            hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
          ),
        ],
      ),
      onTap: isSelectionMode
          ? onToggleSelection
          : onActivate ??
                () => _handleTap(
                  context,
                  ref,
                  isQueued: isQueued,
                  isInLocalLibrary: isInLocalLibrary,
                ),
      onLongPress: isSelectionMode
          ? null
          : onEnterSelectionMode ??
                () => TrackCollectionQuickActions.showTrackOptionsSheet(
                  context,
                  ref,
                  track,
                  hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                ),
    );
  }

  void _handleTap(
    BuildContext context,
    WidgetRef ref, {
    required bool isQueued,
    required bool isInLocalLibrary,
  }) async {
    await activate(
      context,
      ref,
      track,
      isInHistory: isInHistory,
      onDownload: onDownload,
    );
  }

  /// Plays a track from the desktop song table.
  static Future<void> activate(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    required bool isInHistory,
    required void Function({bool forceQualityPicker}) onDownload,
    List<Track>? queue,
    int startIndex = 0,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    try {
      final playback = ref.read(playbackProvider.notifier);
      if (await playback.openPlayerIfCurrent(
        track: track,
        listContext: listContext,
        listOccurrence:
            listOccurrences != null && startIndex < listOccurrences.length
            ? listOccurrences[startIndex]
            : null,
      )) {
        return;
      }
      await playback.playTrackList(
            queue ?? [track],
            startIndex: startIndex,
            exactStart: true,
            listContext: listContext,
            listOccurrences: listOccurrences,
          );
    } catch (error) {
      if (context.mounted) showCannotOpenFileSnackBar(context, error);
    }
  }
}

/// Explicit, Dolby Atmos and In Library badges of a [TrackListTile], for the
/// title cell of the desktop song table. Quality has its own column there.
class TrackListTileBadges extends ConsumerWidget {
  const TrackListTileBadges({
    super.key,
    required this.track,
    required this.isInHistory,
  });

  final Track track;
  final bool isInHistory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    final isInLocalLibrary =
        showLocalLibraryIndicator &&
        ref.watch(playlistRealDownloadProvider(track)).value == true;
    final badges = [
      ...buildQualityBadges(
        audioQuality: null,
        audioModes: track.audioModes,
        colorScheme: colorScheme,
        explicit: track.isExplicit,
      ),
      if (isInLocalLibrary || isInHistory) DownloadedFormatMark(track: track),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, badge) in badges.indexed) ...[
          if (index > 0) const SizedBox(width: 4),
          badge,
        ],
      ],
    );
  }
}
