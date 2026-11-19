import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/service_track_link.dart';
import 'package:mornye/widgets/add_to_music_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/track_collection_action_policy.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:share_plus/share_plus.dart';

/// Every action a song menu can offer. The order here is the order on screen
/// in the phone sheet, the Mornye popover and the desktop context menu.
enum TrackActionId {
  favorite('favorite'),
  addToMusic('library'),
  download('download'),
  playLocal('playLocal'),
  playNext('playNext'),
  addToQueue('addToQueue'),
  downloadOnDesktop('downloadOnDesktop'),
  goToAlbum('album'),
  goToArtist('artist'),
  share('share'),
  copyLink('copyLink'),
  copyTitle('copyTitle'),
  details('details'),
  shareLyrics('shareLyrics'),
  sendToDesktop('linkSend'),
  saveToPhone('linkSave'),
  equalizer('equalizer'),
  volume('volume'),
  sleepTimer('sleepTimer'),
  external('external');

  const TrackActionId(this.value);

  /// The stable string a menu returns when the row is chosen.
  final String value;
}

/// One row or round button of a song menu.
@immutable
class TrackAction {
  const TrackAction({
    required this.id,
    required this.icon,
    required this.cupertinoIcon,
    required this.label,
    this.subtitle,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
  });

  final TrackActionId id;
  final IconData icon;
  final IconData cupertinoIcon;
  final String label;
  final String? subtitle;

  /// The active state of a toggle: a favorite, a song already in the music.
  final bool selected;
  final bool enabled;
  final bool destructive;
}

/// The song menu: the quick actions shown as round buttons, then the rows.
///
/// All three presentations (Material sheet, Mornye popover, desktop context
/// menu) are drawn from one instance, so content and order cannot drift apart.
/// It is plain data resolved before the menu opens, so nothing in it changes
/// size or content once it is on screen.
@immutable
class TrackActionMenu {
  const TrackActionMenu({required this.quick, required this.groups});

  final List<TrackAction> quick;
  final List<List<TrackAction>> groups;

  Iterable<TrackAction> get all sync* {
    yield* quick;
    for (final group in groups) {
      yield* group;
    }
  }

  List<TrackActionId> get ids => [for (final action in all) action.id];

  /// Quick actions and rows as desktop context menu groups, in the same order.
  List<List<ContextMenuAction>> toContextGroups(
    void Function(TrackAction action) onSelected,
  ) => [
    for (final group in [quick, ...groups])
      [
        for (final action in group)
          ContextMenuAction(
            icon: action.icon,
            label: action.label,
            checked: action.selected,
            destructive: action.destructive,
            onSelected: action.enabled ? () => onSelected(action) : null,
          ),
      ],
  ];

  /// The Mornye popover's quick actions and groups.
  ({List<MornyeMenuAction> quick, List<List<MornyeMenuAction>> groups})
  toMornye(void Function(TrackAction action) onSelected) {
    MornyeMenuAction convert(TrackAction action) => MornyeMenuAction(
      icon: action.cupertinoIcon,
      label: action.label,
      subtitle: action.subtitle,
      selected: action.selected,
      destructive: action.destructive,
      onPressed: action.enabled ? () => onSelected(action) : null,
    );
    return (
      quick: [for (final action in quick) convert(action)],
      groups: [
        for (final group in groups)
          [for (final action in group) convert(action)],
      ],
    );
  }
}

enum TrackDownloadPhase { none, active, done }

/// Everything the menu depends on, as plain values.
@immutable
class TrackActionInputs {
  const TrackActionInputs({
    this.isLoved = false,
    this.inMusic = false,
    this.download = TrackDownloadPhase.none,
    this.canDownloadAgain = false,
    this.canPlayLocal = false,
    this.canQueue = false,
    this.hasAlbum = true,
    this.hasArtist = true,
    this.link,
    this.canCopyTitle = true,
    this.canDownload = true,
    this.canAddToMusic = true,
    this.canFavorite = true,
    this.desktopName,
    this.hasDetails = false,
    this.hasLyricsShare = false,
    this.sendToDesktopName,
    this.canSaveToPhone = false,
    this.playerTools = false,
    this.canEqualizer = false,
    this.volumeShown = true,
    this.sleepTimerSubtitle,
  });

  final bool isLoved;
  final bool inMusic;
  final TrackDownloadPhase download;
  final bool canDownloadAgain;
  final bool canPlayLocal;
  final bool canQueue;
  final bool hasAlbum;
  final bool hasArtist;
  final ServiceTrackLink? link;
  final bool canCopyTitle;
  final bool canDownload;
  final bool canAddToMusic;
  final bool canFavorite;
  final String? desktopName;
  final bool hasDetails;
  final bool hasLyricsShare;
  final String? sendToDesktopName;
  final bool canSaveToPhone;

  /// Adds the player-only group: equalizer, volume, sleep timer, external.
  final bool playerTools;

  /// Offers the equalizer on its own, for the desktop player.
  final bool canEqualizer;
  final bool volumeShown;
  final String? sleepTimerSubtitle;
}

/// Builds the song menu. The order, icons and labels live only here.
TrackActionMenu buildTrackActionMenu(
  AppLocalizations l10n,
  TrackActionInputs input,
) {
  final downloadLabel = switch (input.download) {
    TrackDownloadPhase.active => l10n.trackActionDownloading,
    TrackDownloadPhase.done => l10n.trackDownloaded,
    TrackDownloadPhase.none => l10n.dialogDownload,
  };
  final downloadEnabled = switch (input.download) {
    TrackDownloadPhase.active => false,
    TrackDownloadPhase.done => input.canDownloadAgain,
    TrackDownloadPhase.none => true,
  };
  final quick = [
    if (input.canFavorite)
      TrackAction(
        id: TrackActionId.favorite,
        icon: input.isLoved ? Icons.star_rounded : Icons.star_outline_rounded,
        cupertinoIcon: input.isLoved
            ? CupertinoIcons.star_fill
            : CupertinoIcons.star,
        label: input.isLoved ? l10n.mornyeFavorited : l10n.mornyeFavorite,
        selected: input.isLoved,
      ),
    if (input.canAddToMusic)
      TrackAction(
        id: TrackActionId.addToMusic,
        icon: input.inMusic
            ? Icons.check_circle_rounded
            : Icons.add_circle_outline_rounded,
        cupertinoIcon: input.inMusic
            ? CupertinoIcons.checkmark_circle_fill
            : CupertinoIcons.add_circled,
        label: l10n.addToMusicTitle,
        selected: input.inMusic,
      ),
    if (input.canDownload)
      TrackAction(
        id: TrackActionId.download,
        icon: input.download == TrackDownloadPhase.done
            ? Icons.download_done_rounded
            : Icons.download_rounded,
        cupertinoIcon: input.download == TrackDownloadPhase.done
            ? CupertinoIcons.checkmark_alt_circle
            : CupertinoIcons.arrow_down_circle,
        label: downloadLabel,
        selected: input.download == TrackDownloadPhase.done,
        enabled: downloadEnabled,
      ),
  ];
  final groups = <List<TrackAction>>[
    [
      if (input.canPlayLocal)
        TrackAction(
          id: TrackActionId.playLocal,
          icon: Icons.play_arrow_rounded,
          cupertinoIcon: CupertinoIcons.play,
          label: l10n.trackMetadataPlay,
        ),
      if (input.canQueue)
        TrackAction(
          id: TrackActionId.playNext,
          icon: Icons.playlist_play_rounded,
          cupertinoIcon: CupertinoIcons.text_insert,
          label: l10n.trackPlayNext,
        ),
      if (input.canQueue)
        TrackAction(
          id: TrackActionId.addToQueue,
          icon: Icons.queue_music_rounded,
          cupertinoIcon: CupertinoIcons.music_note_list,
          label: l10n.trackAddToQueue,
        ),
      if (input.desktopName case final name?)
        TrackAction(
          id: TrackActionId.downloadOnDesktop,
          icon: Icons.computer_rounded,
          cupertinoIcon: CupertinoIcons.desktopcomputer,
          label: l10n.linkDownloadOnDesktop(name),
        ),
    ],
    [
      if (input.hasAlbum)
        TrackAction(
          id: TrackActionId.goToAlbum,
          icon: Icons.album_outlined,
          cupertinoIcon: CupertinoIcons.square_stack,
          label: l10n.homeGoToAlbum,
        ),
      if (input.hasArtist)
        TrackAction(
          id: TrackActionId.goToArtist,
          icon: Icons.mic_none_rounded,
          cupertinoIcon: CupertinoIcons.mic,
          label: l10n.mornyeGoToArtist,
        ),
    ],
    [
      TrackAction(
        id: TrackActionId.share,
        icon: Icons.share_outlined,
        cupertinoIcon: CupertinoIcons.share,
        label: l10n.trackMetadataShare,
      ),
      if (input.link case final link?)
        TrackAction(
          id: TrackActionId.copyLink,
          icon: Icons.link_rounded,
          cupertinoIcon: CupertinoIcons.link,
          label: l10n.trackOptionCopyLink(link.serviceName),
        ),
      if (input.canCopyTitle)
        TrackAction(
          id: TrackActionId.copyTitle,
          icon: Icons.copy_all_rounded,
          cupertinoIcon: CupertinoIcons.doc_on_doc,
          label: l10n.trackOptionCopyTrackAndArtist,
        ),
      if (input.hasDetails)
        TrackAction(
          id: TrackActionId.details,
          icon: Icons.info_outline_rounded,
          cupertinoIcon: CupertinoIcons.info,
          label: l10n.nowPlayingDetails,
        ),
    ],
    [
      if (input.hasLyricsShare)
        TrackAction(
          id: TrackActionId.shareLyrics,
          icon: Icons.format_quote_rounded,
          cupertinoIcon: CupertinoIcons.quote_bubble,
          label: l10n.lyricsShareTitle,
        ),
      if (input.sendToDesktopName case final name?)
        TrackAction(
          id: TrackActionId.sendToDesktop,
          icon: Icons.computer_rounded,
          cupertinoIcon: CupertinoIcons.desktopcomputer,
          label: l10n.linkSendToDesktop(name),
        ),
      if (input.canSaveToPhone)
        TrackAction(
          id: TrackActionId.saveToPhone,
          icon: Icons.phone_android_rounded,
          cupertinoIcon: CupertinoIcons.device_phone_portrait,
          label: l10n.linkSaveToPhone,
        ),
    ],
    if (input.playerTools || input.canEqualizer)
      [
        TrackAction(
          id: TrackActionId.equalizer,
          icon: Icons.equalizer_rounded,
          cupertinoIcon: CupertinoIcons.slider_horizontal_3,
          label: l10n.equalizerTitle,
        ),
        if (input.playerTools) ...[
          TrackAction(
            id: TrackActionId.volume,
            icon: input.volumeShown
                ? Icons.volume_off_outlined
                : Icons.volume_up_outlined,
            cupertinoIcon: input.volumeShown
                ? CupertinoIcons.speaker_slash
                : CupertinoIcons.speaker_2,
            label: input.volumeShown
                ? l10n.nowPlayingHideVolume
                : l10n.nowPlayingShowVolume,
          ),
          TrackAction(
            id: TrackActionId.sleepTimer,
            icon: Icons.bedtime_outlined,
            cupertinoIcon: CupertinoIcons.moon_zzz,
            label: l10n.nowPlayingSleepTimer,
            subtitle: input.sleepTimerSubtitle,
          ),
          TrackAction(
            id: TrackActionId.external,
            icon: Icons.open_in_new_rounded,
            cupertinoIcon: CupertinoIcons.arrow_up_right_square,
            label: l10n.nowPlayingOpenInExternalPlayer,
          ),
        ],
      ],
  ];
  return TrackActionMenu(
    quick: quick,
    groups: [
      for (final group in groups)
        if (group.isNotEmpty) group,
    ],
  );
}

bool trackIsOnDevice(WidgetRef ref, Track track) {
  if (downloadHistoryHoldsTrack(ref.read(downloadHistoryProvider), track)) {
    return true;
  }
  return ref
      .read(localLibraryProvider)
      .existsInLibrary(
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      );
}

TrackDownloadPhase trackDownloadPhase(
  WidgetRef ref,
  Track track, {
  required bool onDevice,
}) {
  final status = ref
      .read(downloadQueueLookupProvider)
      .byTrackId[track.id]
      ?.status;
  return switch (status) {
    DownloadStatus.queued ||
    DownloadStatus.downloading ||
    DownloadStatus.finalizing => TrackDownloadPhase.active,
    DownloadStatus.completed => TrackDownloadPhase.done,
    _ => onDevice ? TrackDownloadPhase.done : TrackDownloadPhase.none,
  };
}

/// The menu for a catalog or library [track], resolved from what the app
/// already holds in memory. Nothing here waits for a query, so the menu
/// opens with its final content and size.
TrackActionMenu readTrackActionMenu(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  bool hasLocalPlaybackCandidate = false,
}) {
  final key = trackCollectionKey(track);
  final onDevice = hasLocalPlaybackCandidate || trackIsOnDevice(ref, track);
  final download = trackDownloadPhase(ref, track, onDevice: onDevice);
  final linkClient = ref.read(linkPhoneClientProvider);
  final qualityAction = resolveQualityVariantMenuAction(
    allowQualityVariants: ref.read(settingsProvider).allowQualityVariants,
    hasLocalPlaybackCandidate: onDevice,
  );
  return buildTrackActionMenu(
    context.l10n,
    TrackActionInputs(
      isLoved: ref.read(libraryCollectionsProvider).isLoved(track),
      inMusic: ref.read(librarySongKeysProvider).contains(key),
      download: download,
      canDownloadAgain: ref.read(settingsProvider).allowQualityVariants,
      canPlayLocal: qualityAction == QualityVariantMenuAction.playLocal,
      canQueue: ref.read(playerUiEnabledProvider),
      hasAlbum:
          track.albumName.trim().isNotEmpty ||
          (track.albumId ?? '').trim().isNotEmpty,
      hasArtist: track.artistName.trim().isNotEmpty,
      link: serviceTrackLinkFor(track),
      desktopName: linkClient == null ? null : linkDesktopName(linkClient),
    ),
  );
}

/// Runs the chosen song action on [track]. [root] is the root navigator's
/// context, still mounted after the menu that chose the action has closed.
Future<void> runTrackAction(
  BuildContext root,
  WidgetRef ref,
  Track track,
  TrackActionId id, {
  Rect? shareOrigin,
}) async {
  if (!root.mounted) return;
  void notify(String message) {
    if (!root.mounted) return;
    ScaffoldMessenger.of(root).showSnackBar(SnackBar(content: Text(message)));
  }

  switch (id) {
    case TrackActionId.favorite:
      final added = await ref
          .read(libraryCollectionsProvider.notifier)
          .toggleLoved(track);
      if (!root.mounted) return;
      final l10n = root.l10n;
      notify(
        added
            ? l10n.collectionAddedToLoved(track.name)
            : l10n.collectionRemovedFromLoved(track.name),
      );
    case TrackActionId.addToMusic:
      await showAddToMusicSheet(root, ref, track);
    case TrackActionId.download:
      await downloadSingleTrack(root, ref, track);
    case TrackActionId.playLocal:
      try {
        await ref.read(playbackProvider.notifier).playTrackList([track]);
      } catch (error) {
        if (root.mounted) showCannotOpenFileSnackBar(root, error);
      }
    case TrackActionId.playNext:
      await ref
          .read(musicPlayerControllerProvider)
          .playNext(playableFromCatalogTrack(track));
    case TrackActionId.addToQueue:
      await ref
          .read(musicPlayerControllerProvider)
          .addToQueue(playableFromCatalogTrack(track));
    case TrackActionId.downloadOnDesktop:
      await linkDownloadTracksOnDesktop(root, ref, [track]);
    case TrackActionId.goToAlbum:
      await navigateToTrackAlbum(root, track);
    case TrackActionId.goToArtist:
      await navigateToArtist(
        root,
        artistName: track.artistName,
        artistId: track.artistId,
        coverUrl: track.coverUrl,
        extensionId: track.source,
      );
    case TrackActionId.share:
      final link = serviceTrackLinkFor(track);
      await SharePlus.instance.share(
        ShareParams(
          text: [
            '${track.name} - ${track.artistName}',
            ?link?.webUrl,
          ].join('\n'),
          sharePositionOrigin:
              shareOrigin ??
              Rect.fromCenter(
                center: MediaQuery.sizeOf(root).center(Offset.zero),
                width: 1,
                height: 1,
              ),
        ),
      );
    case TrackActionId.copyLink:
      final link = serviceTrackLinkFor(track);
      if (link == null) return;
      await Clipboard.setData(ClipboardData(text: link.webUrl));
      if (!root.mounted) return;
      notify(root.l10n.snackbarUrlCopied(link.serviceName));
    case TrackActionId.copyTitle:
      await Clipboard.setData(
        ClipboardData(text: '${track.name} - ${track.artistName}'),
      );
      if (!root.mounted) return;
      notify(root.l10n.trackCopiedToClipboard);
    case TrackActionId.details ||
        TrackActionId.shareLyrics ||
        TrackActionId.sendToDesktop ||
        TrackActionId.saveToPhone ||
        TrackActionId.equalizer ||
        TrackActionId.volume ||
        TrackActionId.sleepTimer ||
        TrackActionId.external:
      break;
  }
}
