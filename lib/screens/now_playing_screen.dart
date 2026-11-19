import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/widgets/player_artist_sheet.dart';
import 'package:mornye/controllers/player_track_navigation.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/widgets/add_to_music_sheet.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/audio_output_button.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart'
    show DesktopCommand, desktopTooltip;
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/lyrics_screen_awake.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_gesture_regions.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';
import 'package:mornye/widgets/verification_prompts.dart';
import 'package:mornye/widgets/player_details_sheet.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/material_player_layout.dart';
import 'package:mornye/widgets/mornye_player_layout.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mornye_player_actions_sheet.dart';
import 'package:mornye/widgets/track_actions.dart';
import 'package:mornye/widgets/track_actions_sheet.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/utils/service_track_link.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/providers/player_apple_artwork_provider.dart';
import 'package:mornye/providers/player_canvas_provider.dart';
import 'package:mornye/services/player_cover_mode.dart';
import 'package:mornye/services/motion_artwork_store.dart' show MotionArtwork;
import 'package:mornye/providers/player_video_mode_provider.dart';
import 'package:mornye/widgets/player_video_pill.dart';
import 'package:mornye/widgets/player_canvas_background.dart';
import 'package:mornye/widgets/player_video_glow.dart';

export 'package:mornye/routes/now_playing_route.dart';

/// Portrait's "Playing on" row, kept while empty.
const _playingOnRowHeight = 28.0;

/// Screens shorter than this keep Mornye's volume row clear by leaving the
/// empty row out; its cover and controls need the height.
const _mornyePlayingOnMinScreenHeight = 720.0;

/// What Mornye holds back above its volume row, so the toolbar reaches
/// Material's height while the track header stays level with Material's.
const _mornyeControlsHeadroom = 0.0;

/// How much of an iPhone's home indicator inset stays under that row. The
/// indicator sits in the screen's bottom 13pt, and the label's text ends 8pt
/// above the row's bottom, so it still clears the indicator.
const _homeIndicatorBelowRow = 12.0;

/// AppBar wrapper that fades with the route transition (see contentOpacity
/// in [_NowPlayingScreenState.build]).
class _FadingAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Animation<double> opacity;
  final AppBar child;

  /// Material's immersive lyrics fade the bar's buttons away too.
  final bool hidden;

  const _FadingAppBar({
    required this.opacity,
    required this.child,
    this.hidden = false,
  });

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: opacity,
    child: PlayerLyricsControlsVisibility(hidden: hidden, child: child),
  );
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({
    super.key,
    this.metadataControllerFactory,
    this.initialPage = 0,
    this.embedded = false,
  });

  final PlayerMetadataController Function()? metadataControllerFactory;

  /// The page shown first: 0 is the player, 1 the lyrics and 2 Up Next
  /// (Mornye only).
  final int initialPage;

  /// Shown in the desktop content pane rather than as a route. Minimizing
  /// returns to the content, and lyrics and Up Next open in the desktop
  /// inspector beside the player instead of replacing it.
  final bool embedded;

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  ProviderSubscription<bool>? _lyricsPlayingSub;
  ProviderSubscription<bool>? _lyricsAutoHideSub;
  late final _trackMetadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  late final LyricsTranslationController _lyricsTranslation;
  late int _currentPage = widget.initialPage;
  bool _landscape = false;
  bool _canvasLayout = false;
  bool _canvasFullBleed = false;
  bool _queueSheetShowing = false;
  String? _measuredMotionSource;
  double? _motionAspectRatio;
  String? _failedMotionSource;
  bool _lyricsControlsHidden = false;
  bool _lyricsOptionsOpen = false;
  bool _audioOutputOpen = false;
  bool _sharingLyrics = false;
  double _lyricsScrollDistance = 0;
  Timer? _lyricsIdleTimer;
  final _lyricsPointers = <int, Offset>{};
  bool _lyricsPointerMoved = false;
  // Skipping, seeking or opening the queue from the compact player keeps it
  // compact; only a touch elsewhere restores the full player.
  bool _compactPlayerTouched = false;
  final _artworkHeaderKey = GlobalKey();
  final _artworkControlsKey = GlobalKey();
  final _artworkVolumeKey = GlobalKey();
  final _expandedArtworkKey = GlobalKey();
  final _compactArtworkKey = GlobalKey();
  final _motionArtworkKey = GlobalKey();
  final _videoLiveSource = CoverMimicLiveSource();
  final _artworkForeground = ValueNotifier<Map<String, Color>>({});
  final _seekPreview = PlaybackSeekPreview();
  NowPlayingRoute? _artworkRoute;

  @override
  void initState() {
    super.initState();
    _lyricsTranslation = ref.read(lyricsTranslationProvider.notifier);
    if (widget.embedded) desktopInspectorPanel.addListener(_onInspectorChanged);
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id != next.value?.id) _seekPreview.reset();
        unawaited(
          _trackMetadata.load(
            next.value,
            inspectUnresolvedContentUri: _currentPage == 1,
          ),
        );
      },
    );
    _lyricsPlayingSub = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      playing,
    ) {
      if (!playing && _lyricsControlsHidden) {
        setState(() => _lyricsControlsHidden = false);
      }
      _scheduleLyricsControlsHide();
    });
    _lyricsAutoHideSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.autoHideLyricsControls),
      (_, enabled) {
        if (!enabled) {
          _lyricsPointers.clear();
          _lyricsScrollDistance = 0;
          if (_lyricsControlsHidden) {
            setState(() => _lyricsControlsHidden = false);
          }
        }
        _scheduleLyricsControlsHide();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: _currentPage == 1,
        ),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _landscape = context.isMornye && size.width > size.height;
    if (!_lyricsAutoHideLayout || MediaQuery.accessibleNavigationOf(context)) {
      _lyricsControlsHidden = false;
    }
    _scheduleLyricsControlsHide();
  }

  void _onInspectorChanged() {
    if (mounted) setState(() {});
  }

  /// Whether the lyrics (1) or Up Next (2) toggle shows as selected. The
  /// embedded player shows them in the desktop inspector instead.
  bool _showsPage(int page) => widget.embedded
      ? desktopInspectorPanel.value ==
            (page == 1
                ? DesktopInspectorPanel.lyrics
                : DesktopInspectorPanel.upNext)
      : _currentPage == page;

  /// Opens lyrics (1) or Up Next (2) in the desktop inspector when embedded.
  /// Returns false when the player should switch pages itself.
  bool _toggleInspector(int page) {
    if (!widget.embedded) return false;
    if (page == 1 || page == 2) {
      toggleDesktopInspector(
        page == 1 ? DesktopInspectorPanel.lyrics : DesktopInspectorPanel.upNext,
      );
    }
    return true;
  }

  String _minimizeTooltip(BuildContext context) => desktopTooltip(
    context,
    context.l10n.nowPlayingMinimize,
    DesktopCommand.dismiss,
  );

  void _minimize() {
    if (widget.embedded) {
      desktopNowPlayingOpen.value = false;
    } else {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  @override
  void dispose() {
    if (widget.embedded) {
      desktopInspectorPanel.removeListener(_onInspectorChanged);
    }
    _artworkRoute?.readArtwork = null;
    _lyricsIdleTimer?.cancel();
    _mediaItemSub?.close();
    _lyricsPlayingSub?.close();
    _lyricsAutoHideSub?.close();
    _lyricsTranslation.cancel(owner: this);
    _trackMetadata.dispose();
    _artworkForeground.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(playerUiEnabledProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).maybePop();
        }
      });
      return const SizedBox.shrink();
    }
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final mornye = context.isMornye;
    final fullScreenCover = ref.watch(
      settingsProvider.select(
        (s) => s.playerCoverStyleFor(mornye: mornye) == 'fullscreen',
      ),
    );
    return LyricsScreenAwake(
      visible: _currentPage == 1 && mediaItem != null,
      child: mornye
          ? _buildPlayer(context, mediaItem, fullScreenCover: fullScreenCover)
          // Material takes the track's artwork scheme. The providers it needs
          // are read above, so the scoped builder reads none.
          : PlayerArtworkTheme(
              artUri: mediaItem?.artUri?.toString(),
              child: Builder(
                builder: (context) => _buildPlayer(
                  context,
                  mediaItem,
                  fullScreenCover: fullScreenCover,
                ),
              ),
            ),
    );
  }

  Widget _buildPlayer(
    BuildContext context,
    MediaItem? mediaItem, {
    required bool fullScreenCover,
  }) {
    final mornye = context.isMornye;
    final colorScheme = mornye
        ? MornyeTheme.fromContext(
            context,
            brightness: Brightness.dark,
          ).colorScheme
        : Theme.of(context).colorScheme;

    if (mediaItem == null) {
      return Scaffold(
        appBar: AppBar(
          leading: AppIconButton(
            tooltip: _minimizeTooltip(context),
            icon: const AppIcon(Icons.keyboard_arrow_down),
            onPressed: _minimize,
          ),
        ),
        body: Center(child: Text(context.l10n.nowPlayingNothingPlaying)),
      );
    }

    final source = mediaItem.extras?['source']?.toString() ?? '';
    final videoPath = ref.watch(playerVideoPathProvider(mediaItem));
    final motionEnabled = ref.watch(
      settingsProvider.select((s) => s.motionArtworkEnabled),
    );
    final adaptive = ref.watch(
      settingsProvider.select((s) => s.playerAdaptiveFullBleed),
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final motionAllowed =
        mornye && videoPath == null && motionEnabled && !reduceMotion;
    final motionState = motionAllowed
        ? ref.watch(playerSquareCoverMotionProvider(mediaItem))
        : null;
    final tallState = motionAllowed && adaptive && !_landscape
        ? ref.watch(playerAppleTallArtworkProvider(mediaItem))
        : null;
    final resolvedMotion = motionState?.value;
    final squareMotion = resolvedMotion?.source == _failedMotionSource
        ? null
        : resolvedMotion;
    final tallArtwork = tallState?.value;
    final canvasWanted =
        videoPath == null &&
        !reduceMotion &&
        (mornye
            ? motionEnabled &&
                  tallArtwork == null &&
                  tallState?.isLoading != true
            : squareMotion == null &&
                  motionState?.isLoading != true &&
                  fullScreenCover &&
                  !_landscape);
    final canvasState = canvasWanted
        ? ref.watch(playerCanvasProvider(mediaItem))
        : null;
    final canvasSource = canvasState?.value?.source;
    final decision = mornye
        ? decidePlayerCoverMode(
            motionEnabled: motionEnabled,
            tallEnabled: adaptive,
            networkAllowed: true,
            reduceAnimations: reduceMotion,
            musicVideoActive: videoPath != null,
            landscape: _landscape,
            appleTall: _coverVideo(tallArtwork),
            canvas: _coverVideo(canvasState?.value),
            appleSquare: _coverVideo(squareMotion),
          )
        : PlayerCoverDecision.still;
    final motionArtwork = decision.mode == PlayerCoverMode.squareVideo
        ? squareMotion
        : null;
    final motionRatio =
        motionArtwork?.aspectRatio ??
        (_measuredMotionSource == motionArtwork?.source
            ? _motionAspectRatio
            : null);
    final squareArtwork =
        motionArtwork == null || (motionRatio != null && motionRatio >= 0.95);
    final fullBleedVideo = decision.mode == PlayerCoverMode.fullBleedVideo;
    final backdropSource = mornye
        ? switch (decision.mode) {
            PlayerCoverMode.fullBleedVideo ||
            PlayerCoverMode.canvasBackdrop => decision.source,
            _ => null,
          }
        : canvasSource;
    if (!mornye || canvasState == null) {
      _canvasLayout = false;
      _canvasFullBleed = false;
    } else if (!canvasState.isLoading) {
      _canvasLayout = backdropSource != null;
      _canvasFullBleed = fullBleedVideo;
    }
    final hideCover =
        fullBleedVideo ||
        (backdropSource == null &&
            canvasState?.isLoading == true &&
            _canvasFullBleed);
    final canvasLayout =
        backdropSource != null || (canvasState != null && _canvasLayout);
    final fullBleed =
        mornye &&
        videoPath == null &&
        !canvasLayout &&
        (motionArtwork != null || fullScreenCover);
    final screen = MediaQuery.sizeOf(context);
    // A still cover is cropped at the sides to reach down to the title, as
    // in the Material full-screen style; landscape keeps the square card.
    final stillFullBleed = fullBleed && motionArtwork == null;
    final artworkRatio = videoPath != null
        ? 16 / 9
        : stillFullBleed
        ? _landscape || screen.height <= 0
              ? 1.0
              : (screen.width / (screen.height * 0.56)).clamp(0.5, 1.0)
        : motionRatio;
    final materialBackdrop = !mornye && fullScreenCover;
    // Two-pane landscape keeps its side-by-side cover over the blurred surface.
    final materialFullScreen =
        materialBackdrop &&
        videoPath == null &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final overCover = materialFullScreen && _currentPage != 1;
    // Portrait keeps the "Playing on" row while empty, so the controls stay
    // put when a computer takes over playback. On an iPhone the row reaches
    // into the home indicator's inset rather than stacking a second empty
    // band on top of it.
    final reservesPlayingOnRow =
        MediaQuery.orientationOf(context) == Orientation.portrait &&
        screen.height >= (mornye ? _mornyePlayingOnMinScreenHeight : 640);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final homeIndicatorBelowRow =
        reservesPlayingOnRow && Theme.of(context).platform == TargetPlatform.iOS
        ? bottomInset.clamp(0.0, _homeIndicatorBelowRow)
        : null;
    if (!fullBleed && _artworkForeground.value.isNotEmpty) {
      _artworkForeground.value = {};
    }
    Widget artwork() => MornyePlayerArtwork(
      mediaItem: mediaItem,
      videoUrl: motionArtwork?.source,
      resolvingVideo: motionState?.isLoading == true,
      onAspectRatioChanged: (ratio) {
        if (!mounted ||
            (_measuredMotionSource == motionArtwork?.source &&
                _motionAspectRatio == ratio)) {
          return;
        }
        setState(() {
          _measuredMotionSource = motionArtwork?.source;
          _motionAspectRatio = ratio;
        });
      },
      onError: () {
        if (mounted) {
          setState(() => _failedMotionSource = motionArtwork?.source);
        }
      },
    );

    // The Mornye route moves the entire player together. A second,
    // delayed content fade would make dismissal appear to pause partway down.
    final route = ModalRoute.of(context);
    final routeAnimation = route?.animation ?? kAlwaysCompleteAnimation;
    if (_artworkRoute != route) {
      _artworkRoute?.readArtwork = null;
      _artworkRoute = null;
    }
    if (mornye && route is NowPlayingRoute) {
      _artworkRoute = route;
      route.readArtwork = () {
        final key = _landscape
            ? _expandedArtworkKey
            : _currentPage != 0
            ? _compactArtworkKey
            : hideCover
            ? null
            : fullBleed
            ? _motionArtworkKey
            : _expandedArtworkKey;
        final box = key?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return null;
        final overlay = route.navigator?.overlay?.context.findRenderObject();
        return (
          bounds: MatrixUtils.transformRect(
            box.getTransformTo(overlay),
            Offset.zero & box.size,
          ),
          fullBleed: key == _motionArtworkKey,
          child: Theme(
            data: MornyeTheme.fromContext(context, brightness: Brightness.dark),
            child: key == _compactArtworkKey
                ? PlayerArtwork(
                    artUri: mediaItem.artUri?.toString(),
                    fallbackUri: mediaItem.extras?['fallbackArt']?.toString(),
                    colorScheme: colorScheme,
                    cacheWidth: PlayerArtwork.transitionCacheWidth(context),
                  )
                : artwork(),
          ),
        );
      };
    }
    final contentOpacity = mornye
        ? kAlwaysCompleteAnimation
        : routeAnimation.drive(
            CurveTween(curve: const Interval(0.4, 1.0, curve: Curves.easeOut)),
          );

    // The embedded desktop player keeps a toolbar for its minimize button,
    // which a route reaches by swiping down instead.
    final double? mornyeToolbarHeight = !mornye
        ? null
        : widget.embedded
        ? 48
        : MediaQuery.orientationOf(context) == Orientation.landscape
        ? 0
        : 36;
    final materialLandscapeArtwork =
        !mornye &&
        !widget.embedded &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        ref.watch(settingsProvider.select((s) => s.landscapeLyricsArtwork));
    final player = Scaffold(
      extendBodyBehindAppBar: materialLandscapeArtwork,
      backgroundColor: mornye || materialBackdrop
          ? Colors.transparent
          : colorScheme.surface,
      appBar: _FadingAppBar(
        opacity: contentOpacity,
        hidden: !mornye && _lyricsImmersive,
        child: AppBar(
          backgroundColor: mornye || materialBackdrop
              ? Colors.transparent
              : colorScheme.surface,
          foregroundColor: overCover ? Colors.white : colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: mornye || overCover
              ? SystemUiOverlayStyle.light
              : null,
          toolbarHeight: mornyeToolbarHeight ?? kToolbarHeight,
          automaticallyImplyLeading: false,
          title: mornye
              ? MediaQuery.orientationOf(context) == Orientation.landscape ||
                        widget.embedded
                    ? null
                    : IconButton(
                        tooltip: context.l10n.nowPlayingMinimize,
                        onPressed: _minimize,
                        icon: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      )
              : Text(
                  context.l10n.nowPlayingTitle,
                  // The app theme's title style carries its own colour.
                  style: overCover
                      ? const TextStyle(color: Colors.white)
                      : null,
                ),
          centerTitle: true,
          leading: mornye && !widget.embedded
              ? null
              : AppIconButton(
                  key: const ValueKey('now-playing-minimize'),
                  tooltip: _minimizeTooltip(context),
                  color: overCover || mornye ? Colors.white : null,
                  icon: const AppIcon(Icons.keyboard_arrow_down),
                  onPressed: _minimize,
                ),
          actions: mornye
              ? null
              : [
                  LinkDevicesButton(color: overCover ? Colors.white : null),
                  AppIconButton(
                    tooltip: context.l10n.nowPlayingUpNext,
                    color: overCover ? Colors.white : null,
                    icon: const AppIcon(Icons.queue_music),
                    onPressed: () => _showQueueSheet(context, colorScheme),
                  ),
                  AppIconButton(
                    color: overCover ? Colors.white : null,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    icon: const AppIcon(Icons.more_vert),
                    onPressed: () => _showMoreActions(
                      context: context,
                      mediaItem: mediaItem,
                      source: source,
                      colorScheme: colorScheme,
                    ),
                  ),
                ],
        ),
      ),
      body: FadeTransition(
        opacity: contentOpacity,
        child: SafeArea(
          top: !materialLandscapeArtwork,
          bottom: homeIndicatorBelowRow == null,
          child: Column(
            children: [
              if (materialLandscapeArtwork) ...[
                SizedBox(height: MediaQuery.viewPaddingOf(context).top),
                PlayerLyricsControlsCollapse(
                  key: const ValueKey('material-landscape-toolbar-space'),
                  hidden: _lyricsImmersive,
                  child: const SizedBox(height: kToolbarHeight),
                ),
              ],
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _calmWhileVideo(
                        context,
                        videoPath != null,
                        mornye
                            ? NotificationListener<ScrollUpdateNotification>(
                                onNotification: _onLyricsScroll,
                                child: MornyePlayerLayout(
                                  mediaItem: mediaItem,
                                  metadata: _trackMetadata,
                                  seekPreview: _seekPreview,
                                  colorScheme: colorScheme,
                                  page: _currentPage,
                                  motionArtwork: artwork(),
                                  videoPath: videoPath,
                                  artworkAspectRatio: artworkRatio,
                                  controlsHeadroom: reservesPlayingOnRow
                                      ? _mornyeControlsHeadroom
                                      : 0,
                                  insetArtwork: !fullBleed,
                                  hideCover: hideCover,
                                  artworkTopInset:
                                      MediaQuery.paddingOf(context).top +
                                      (widget.embedded
                                          ? mornyeToolbarHeight!
                                          : 36),
                                  artworkKeys: (
                                    header: _artworkHeaderKey,
                                    controls: _artworkControlsKey,
                                    volume: _artworkVolumeKey,
                                    expanded: _expandedArtworkKey,
                                    compact: _compactArtworkKey,
                                  ),
                                  artworkForeground: _artworkForeground,
                                  lyricsControlsHidden: _lyricsControlsHidden,
                                  lyricsOptionsOpen: _lyricsOptionsOpen,
                                  lyricsBuilder: (showOptions) =>
                                      _lyricsSection(
                                        colorScheme,
                                        isActive: _currentPage != 2,
                                        showOptions: showOptions,
                                      ),
                                  lyricsOptions: _lyricsOptionsButton(
                                    colorScheme,
                                  ),
                                  onShareLyrics: _shareLyrics,
                                  onPageChanged: _setMornyePage,
                                  onTrackNavigation: _showTrackNavigationMenu,
                                  onMoreActions:
                                      (buttonContext, item, anchor) =>
                                          _showMoreActions(
                                            context: buttonContext,
                                            mediaItem: item,
                                            source:
                                                item.extras?['source']
                                                    ?.toString() ??
                                                '',
                                            colorScheme: colorScheme,
                                            anchor: anchor,
                                          ),
                                ),
                              )
                            : MaterialPlayerLayout(
                                mediaItem: mediaItem,
                                metadata: _trackMetadata,
                                seekPreview: _seekPreview,
                                colorScheme: colorScheme,
                                showLyrics: _currentPage == 1,
                                immersive: _lyricsImmersive,
                                compactPlayer: ref.watch(
                                  settingsProvider.select(
                                    (s) => s.compactPlayer,
                                  ),
                                ),
                                onCompactPlayerTouch: () =>
                                    _compactPlayerTouched = true,
                                fullScreenArtwork: materialFullScreen,
                                videoPath: videoPath,
                                landscapeLyricsArtwork: ref.watch(
                                  settingsProvider.select(
                                    (s) => s.landscapeLyricsArtwork,
                                  ),
                                ),
                                lyricsBuilder: (_) =>
                                    _lyricsSection(colorScheme, isActive: true),
                                onOpenQueue: () =>
                                    _showQueueSheet(context, colorScheme),
                              ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const PendingVerificationChip(),
                            PlayerStatusNotices(colorScheme: colorScheme),
                            if (!reservesPlayingOnRow &&
                                MediaQuery.orientationOf(context) ==
                                    Orientation.portrait)
                              LinkPlayingOnLabel(
                                color: mornye ? Colors.white : null,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _autoHidingLyricsControls(
                PlayerQueueSwipeRegion(
                  onOpenQueue: () => _showQueueSheet(context, colorScheme),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (mornye && !_landscape)
                        FractionallySizedBox(
                          widthFactor: 0.72,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                isSelected: _showsPage(1),
                                color: Colors.white,
                                style: IconButton.styleFrom(
                                  backgroundColor: _showsPage(1)
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const AppIcon(
                                  CupertinoIcons.quote_bubble,
                                ),
                                onPressed: _toggleMornyeLyrics,
                              ),
                              AudioOutputButton(
                                color: Colors.white,
                                onPickerChanged: (open) {
                                  if (!mounted) return;
                                  setState(() => _audioOutputOpen = open);
                                  _scheduleLyricsControlsHide();
                                },
                              ),
                              // The row spreads its buttons apart, so the
                              // Devices entry only takes a slot when paired.
                              if (ref.watch(linkPhoneClientProvider) != null)
                                const LinkDevicesButton(color: Colors.white),
                              IconButton(
                                tooltip: context.l10n.nowPlayingUpNext,
                                color: Colors.white,
                                isSelected: _showsPage(2),
                                style: IconButton.styleFrom(
                                  backgroundColor: _showsPage(2)
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const AppIcon(CupertinoIcons.list_bullet),
                                onPressed: () =>
                                    _setMornyePage(_currentPage == 2 ? 0 : 2),
                              ),
                            ],
                          ),
                        )
                      else if (!mornye)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Filled pills like the shuffle and repeat
                              // segments between them.
                              ExpressiveIconButton(
                                key: const ValueKey('material-lyrics-toggle'),
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                selected: _showsPage(1),
                                width: PlayerPlaybackModeToolbar.segmentWidth,
                                foregroundColor: _showsPage(1)
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurfaceVariant,
                                backgroundColor: _showsPage(1)
                                    ? colorScheme.primaryContainer
                                    : colorScheme.surfaceContainerHigh,
                                icon: const AppIcon(Icons.lyrics_outlined),
                                onPressed: _toggleMaterialLyrics,
                              ),
                              PlayerPlaybackModeToolbar(
                                colorScheme: colorScheme,
                              ),
                              AudioOutputButton(
                                color: colorScheme.onSurfaceVariant,
                                backgroundColor:
                                    colorScheme.surfaceContainerHigh,
                                width: PlayerPlaybackModeToolbar.segmentWidth,
                              ),
                            ],
                          ),
                        ),
                      // Landscape has no row to spare; the toolbar's devices
                      // button shows the device there. Short phones' lyrics
                      // keep the room an empty row would take.
                      if (MediaQuery.orientationOf(context) ==
                          Orientation.portrait) ...[
                        if (reservesPlayingOnRow)
                          SizedBox(
                            key: const ValueKey('link-playing-on-row'),
                            height: _playingOnRowHeight,
                            child: Center(
                              child: LinkPlayingOnLabel(
                                color: mornye ? Colors.white : null,
                                height: _playingOnRowHeight,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                collapse: true,
              ),
              if (homeIndicatorBelowRow != null)
                SizedBox(height: homeIndicatorBelowRow),
            ],
          ),
        ),
      ),
    );
    if (!mornye) {
      if (!materialBackdrop) return _lyricsPointerListener(player);
      return Stack(
        fit: StackFit.expand,
        children: [
          MaterialPlayerBackdrop(
            mediaItem: mediaItem,
            colorScheme: colorScheme,
            showArtwork: materialFullScreen && _currentPage != 1,
            canvas: canvasSource == null
                ? null
                : PlayerCanvasBackground(
                    source: canvasSource,
                    veilColor: colorScheme.surface,
                    veil: 0.5,
                  ),
          ),
          const PlayerVideoGlow(),
          _lyricsPointerListener(player),
        ],
      );
    }
    return HeroMode(
      // A route Hero renders outside the panel's gradient and slide, briefly
      // exposing a detached rectangle. Keep Mornye artwork inside its panel.
      enabled: false,
      child: Theme(
        data: MornyeTheme.fromContext(context, brightness: Brightness.dark),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MornyeArtworkContrast(
              enabled: fullBleed && !_landscape && _currentPage == 0,
              continuous: motionArtwork != null,
              targets: {
                'header': _artworkHeaderKey,
                'controls': _artworkControlsKey,
                'volume': _artworkVolumeKey,
              },
              onChanged: (colors) {
                if (!mounted) return;
                _artworkForeground.value = colors;
              },
              child: MornyePlayerBackground(
                artUri: mediaItem.artUri,
                squareArtwork: squareArtwork,
                artworkAspectRatio: artworkRatio,
                fadeStart: stillFullBleed ? 0.72 : 0.58,
                live: motionArtwork != null || fullBleedVideo,
                liveSource: fullBleedVideo ? _videoLiveSource : null,
                artwork: fullBleed && !_landscape && _currentPage == 0
                    ? PlayerTransitionArtwork(
                        artworkKey: _motionArtworkKey,
                        child: Hero(
                          tag: kNowPlayingArtworkHeroTag,
                          child: artwork(),
                        ),
                      )
                    : null,
              ),
            ),
            const Positioned.fill(child: PlayerVideoGlow()),
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : playerCoverCrossfade,
                switchInCurve: Curves.easeInOutCubic,
                switchOutCurve: Curves.easeInOutCubic,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: backdropSource == null
                    ? const SizedBox.expand(key: ValueKey('no-cover-video'))
                    : PlayerCanvasBackground(
                        key: ValueKey(backdropSource),
                        source: backdropSource,
                        veil: _currentPage == 0 ? 0.3 : 0.5,
                        edgeScrims: fullBleedVideo && _currentPage == 0,
                        adaptiveFit: fullBleedVideo,
                        liveSource: fullBleedVideo ? _videoLiveSource : null,
                        fadeDuration: playerCoverCrossfade,
                      ),
              ),
            ),
            _lyricsPointerListener(
              fullBleedVideo && _currentPage == 0
                  ? _overVideoStyle(player)
                  : player,
            ),
          ],
        ),
      ),
    );
  }

  Widget _overVideoStyle(Widget child) => DefaultTextStyle.merge(
    style: const TextStyle(shadows: _overVideoShadows),
    child: IconTheme.merge(
      data: const IconThemeData(shadows: _overVideoShadows),
      child: child,
    ),
  );

  /// A touch on the lyrics page holds the controls; a tap brings hidden
  /// ones back.
  Widget _lyricsPointerListener(Widget child) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if (!_canAutoHideLyricsControls) return;
      if (_lyricsPointers.isEmpty) _lyricsPointerMoved = false;
      _lyricsPointers[event.pointer] = event.position;
      _lyricsIdleTimer?.cancel();
    },
    onPointerMove: (event) {
      final origin = _lyricsPointers[event.pointer];
      if (origin != null && (event.position - origin).distance > 12) {
        _lyricsPointerMoved = true;
      }
    },
    onPointerUp: (event) => _endLyricsInteraction(event.pointer),
    onPointerCancel: (event) =>
        _endLyricsInteraction(event.pointer, cancelled: true),
    child: child,
  );

  void _toggleMaterialLyrics() {
    if (_toggleInspector(1)) return;
    setState(() {
      _currentPage = _currentPage == 1 ? 0 : 1;
      _lyricsControlsHidden = false;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: true,
        ),
      );
    }
  }

  void _toggleMornyeLyrics() {
    _setMornyePage(_currentPage == 1 ? 0 : 1);
  }

  void _setMornyePage(int page) {
    if (_toggleInspector(page)) return;
    setState(() {
      _currentPage = page;
      _lyricsControlsHidden = false;
      _lyricsScrollDistance = 0;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: true,
        ),
      );
    }
  }

  /// Lyrics fill the column, so idle controls can hide: Mornye in portrait
  /// (its landscape player hides its own actions), and Material's portrait
  /// column or its landscape artwork beside lyrics, which shows no transport
  /// either, like Mornye's. Two plain panes keep the transport beside the
  /// lyrics, and the desktop opens lyrics in the inspector.
  bool get _lyricsAutoHideLayout => context.isMornye
      ? !_landscape
      : !widget.embedded &&
            (MediaQuery.orientationOf(context) == Orientation.portrait ||
                ref.read(settingsProvider).landscapeLyricsArtwork);

  bool get _canAutoHideLyricsControls =>
      _lyricsAutoHideLayout &&
      ref.read(settingsProvider).autoHideLyricsControls &&
      _currentPage == 1 &&
      ref.read(playbackPlayingProvider) &&
      !MediaQuery.accessibleNavigationOf(context);

  void _scheduleLyricsControlsHide() {
    _lyricsIdleTimer?.cancel();
    if (!_canAutoHideLyricsControls ||
        _lyricsOptionsOpen ||
        _audioOutputOpen ||
        _lyricsControlsHidden ||
        _lyricsPointers.isNotEmpty) {
      return;
    }
    _lyricsIdleTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || !_canAutoHideLyricsControls) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduleLyricsControlsHide();
        return;
      }
      setState(() => _lyricsControlsHidden = true);
    });
  }

  void _endLyricsInteraction(int pointer, {bool cancelled = false}) {
    if (_lyricsPointers.remove(pointer) == null || _lyricsPointers.isNotEmpty) {
      return;
    }
    final compactTouch = _compactPlayerTouched;
    _compactPlayerTouched = false;
    if (!cancelled &&
        !_lyricsPointerMoved &&
        !compactTouch &&
        _lyricsControlsHidden) {
      setState(() => _lyricsControlsHidden = false);
    }
    _scheduleLyricsControlsHide();
  }

  bool _onLyricsScroll(ScrollUpdateNotification notification) {
    if (_currentPage != 1 ||
        !ref.read(settingsProvider).autoHideLyricsControls ||
        _landscape ||
        notification.dragDetails == null ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final delta = notification.scrollDelta ?? 0;
    if (delta.sign != _lyricsScrollDistance.sign) _lyricsScrollDistance = 0;
    _lyricsScrollDistance += delta;
    if (_lyricsScrollDistance.abs() >= 16) {
      final hidden = _lyricsScrollDistance > 0;
      if (hidden != _lyricsControlsHidden) {
        setState(() => _lyricsControlsHidden = hidden);
      }
      _lyricsScrollDistance = 0;
    }
    return false;
  }

  bool get _lyricsImmersive =>
      _currentPage == 1 && _lyricsControlsHidden && _lyricsAutoHideLayout;

  /// Mornye fades the controls in place; Material folds a [collapse] row
  /// away so the lyrics take its room.
  Widget _autoHidingLyricsControls(Widget child, {bool collapse = false}) =>
      !context.isMornye && collapse
      ? PlayerLyricsControlsCollapse(hidden: _lyricsImmersive, child: child)
      : PlayerLyricsControlsVisibility(hidden: _lyricsImmersive, child: child);

  Widget _calmWhileVideo(BuildContext context, bool video, Widget child) {
    if (!video) return child;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child,
    );
  }

  Widget _lyricsSection(
    ColorScheme colorScheme, {
    required bool isActive,
    bool showOptions = true,
  }) => PlayerLyricsSection(
    metadata: _trackMetadata,
    seekPreview: _seekPreview,
    colorScheme: colorScheme,
    isActive: isActive,
    options: showOptions && isActive && !_landscape
        ? _autoHidingLyricsControls(
            _lyricsOptionsButton(colorScheme, flat: true),
          )
        : null,
    onShareLyrics: _shareLyrics,
    showCorrectionHint: showOptions || _currentPage == 1,
  );

  Future<void> _shareLyrics([LyricLine? line]) async {
    if (_sharingLyrics) return;
    final mediaItem = ref.read(currentMediaItemProvider).value;
    if (mediaItem == null) return;
    _sharingLyrics = true;
    try {
      // The menu offers sharing before the lyrics page has read the file, so
      // read it now (including an unresolved document) and wait for parsing.
      if (_trackMetadata.lyrics.isEmpty) {
        await _trackMetadata.load(mediaItem, inspectUnresolvedContentUri: true);
        await _untilMetadataLoaded();
      }
      if (!mounted) return;
      final current = ref.read(currentMediaItemProvider).value;
      if (current?.id != mediaItem.id ||
          current?.extras?['source'] != mediaItem.extras?['source']) {
        return;
      }
      if (_trackMetadata.lyrics.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(context.l10n.nowPlayingNoLyrics)),
          );
        return;
      }
      await openLyricsShare(
        context,
        mediaItem: mediaItem,
        lyrics: _trackMetadata.lyrics,
        initial: line,
      );
    } finally {
      _sharingLyrics = false;
    }
  }

  /// Completes once a load already in flight (started elsewhere) finishes.
  Future<void> _untilMetadataLoaded() {
    if (!_trackMetadata.loading) return Future.value();
    final done = Completer<void>();
    void listener() {
      if (_trackMetadata.loading || done.isCompleted) return;
      _trackMetadata.removeListener(listener);
      done.complete();
    }

    _trackMetadata.addListener(listener);
    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => _trackMetadata.removeListener(listener),
    );
  }

  Widget _lyricsOptionsButton(ColorScheme colorScheme, {bool flat = false}) =>
      LyricsOptionsButton(
        flat: flat,
        metadata: _trackMetadata,
        colorScheme: colorScheme,
        translationOwner: this,
        onOpenChanged: _onLyricsOptionsOpenChanged,
      );

  void _onLyricsOptionsOpenChanged(bool open) {
    if (!mounted) return;
    if (open) _lyricsIdleTimer?.cancel();
    setState(() => _lyricsOptionsOpen = open);
    if (!open) _scheduleLyricsControlsHide();
  }

  Future<void> _openExternally(String source) async {
    if (source.isEmpty) return;
    try {
      await openFile(source);
    } catch (e) {
      if (!mounted) return;
      showCannotOpenFileSnackBar(context, e);
    }
  }

  Future<void> _showTrackNavigationMenu(
    BuildContext titleContext,
    MediaItem mediaItem,
  ) async {
    final action = await showAppBottomSheet<Object>(
      context: titleContext,
      useRootNavigator: true,
      maxHeightFactor: 0.75,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final track = ref
              .watch(playerCollectionTrackProvider(mediaItem))
              .value;
          return PlayerArtistSheet(
            mediaItem: mediaItem,
            artistIds: track?.artistId,
            albumType:
                mediaItem.extras?['albumType']?.toString() ?? track?.albumType,
            onArtist: (artist) => Navigator.of(sheetContext).pop(artist),
            onAlbum: () => Navigator.of(sheetContext).pop('album'),
          );
        },
      ),
    );
    if (!mounted) return;
    final current = ref.read(currentMediaItemProvider).value;
    if (current?.id != mediaItem.id ||
        current?.extras?['source'] != mediaItem.extras?['source']) {
      return;
    }
    if (action == 'album') {
      await _goToCurrentAlbum(
        mediaItem: mediaItem,
        source: mediaItem.extras?['source']?.toString() ?? '',
      );
    } else if (action is ArtistTapTarget) {
      await navigateToArtist(
        context,
        artistName: action.name,
        artistId: action.artistId,
        extensionId: playingCatalogExtensionId(mediaItem),
      );
    }
  }

  Future<void> _goToCurrentArtist(MediaItem mediaItem) =>
      openPlayingArtist(context, ref, mediaItem);

  /// The menu's "+": adds the playing song to the library or removes it.
  Future<void> _togglePlayerLibrary(MediaItem item) async {
    try {
      final provider = playerCollectionTrackProvider(item);
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
    }
  }

  Future<void> _updatePlayerCollection(
    MediaItem item, {
    required bool favorite,
  }) async {
    try {
      final provider = playerCollectionTrackProvider(item);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final track = await ref.read(provider.future);
      if (!mounted) return;
      if (favorite) {
        await ref.read(libraryCollectionsProvider.notifier).toggleLoved(track);
      } else {
        await showAddTrackToPlaylistSheet(context, ref, track);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    }
  }

  Future<void> _showMoreActions({
    required BuildContext context,
    required MediaItem mediaItem,
    required String source,
    required ColorScheme colorScheme,
    Rect? anchor,
  }) async {
    final controller = ref.read(musicPlayerControllerProvider);
    final sleepTimerEndsAt = controller.sleepTimerEndsAt;
    final sleepTimerSubtitle = sleepTimerEndsAt == null
        ? null
        : context.l10n.nowPlayingSleepTimerActive(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(sleepTimerEndsAt)),
          );
    final volumeShown = ref.read(settingsProvider).playerShowVolume;
    final linkClient = ref.read(linkPhoneClientProvider);
    final artSource = mediaItem.artUri?.toString();
    final isMornye = context.isMornye;
    final transferFuture = linkTransferSongsOfPlaying(
      ref,
      mediaId: mediaItem.id,
      source: source,
    );
    final trackFuture = _resolvePlayerTrack(mediaItem);
    final colorFuture = isMornye && artSource != null && artSource.isNotEmpty
        ? _resolveCoverColor(artSource)
        : Future<Color?>.value();
    final transfer = await transferFuture;
    final playerTrack = await trackFuture;
    final sourceColor = await colorFuture;
    if (!mounted || !context.mounted) return;
    final sendToDesktop = transfer.phone.isEmpty || linkClient == null
        ? null
        : linkDesktopName(linkClient);
    final saveToPhone = transfer.desktop.isNotEmpty;
    final downloadPhase = playerTrack == null || source.startsWith('network://')
        ? null
        : trackDownloadPhase(
            ref,
            playerTrack,
            onDevice: trackIsOnDevice(ref, playerTrack),
          );
    final menu = buildTrackActionMenu(
      context.l10n,
      TrackActionInputs(
        isLoved:
            playerTrack != null &&
            ref.read(libraryCollectionsProvider).isLoved(playerTrack),
        inMusic:
            playerTrack != null &&
            ref
                .read(librarySongKeysProvider)
                .contains(trackCollectionKey(playerTrack)),
        canDownload:
            downloadPhase != null && downloadPhase != TrackDownloadPhase.done,
        download: downloadPhase ?? TrackDownloadPhase.none,
        hasAlbum: (mediaItem.album ?? '').trim().isNotEmpty,
        hasArtist: (mediaItem.artist ?? '').trim().isNotEmpty,
        link: playerTrack == null ? null : serviceTrackLinkFor(playerTrack),
        hasDetails: true,
        hasLyricsShare: true,
        sendToDesktopName: sendToDesktop,
        canSaveToPhone: saveToPhone,
        playerTools: true,
        volumeShown: volumeShown,
        sleepTimerSubtitle: sleepTimerSubtitle,
      ),
    );
    final action = isMornye
        ? await showMornyeContextMenu<TrackActionId>(
            context: context,
            anchor: anchor,
            preferAbove: true,
            maxWidth: 280,
            builder: (_) => MornyePlayerActionsSheet(
              mediaItem: mediaItem,
              menu: menu,
              sourceColor: sourceColor,
            ),
          )
        : await showAppModalBottomSheet<TrackActionId>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: colorScheme.surfaceContainerHigh,
            builder: (_) => TrackActionsSheet(
              menu: menu,
              title: mediaItem.title,
              artist: mediaItem.artist ?? '',
              coverUrl: artSource,
            ),
          );
    if (!mounted || !context.mounted || action == null) return;
    final shareOrigin =
        anchor ??
        Rect.fromCenter(
          center: MediaQuery.sizeOf(context).center(Offset.zero),
          width: 1,
          height: 1,
        );
    switch (action) {
      case TrackActionId.favorite:
        await _updatePlayerCollection(mediaItem, favorite: true);
      case TrackActionId.addToMusic:
        await _togglePlayerLibrary(mediaItem);
      case TrackActionId.goToArtist:
        await _goToCurrentArtist(mediaItem);
      case TrackActionId.goToAlbum:
        await _goToCurrentAlbum(mediaItem: mediaItem, source: source);
      case TrackActionId.share:
        await SharePlus.instance.share(
          ShareParams(
            text: '${mediaItem.title} — ${mediaItem.artist ?? ''}',
            sharePositionOrigin: shareOrigin,
          ),
        );
      case TrackActionId.copyLink:
        final link = playerTrack == null
            ? null
            : serviceTrackLinkFor(playerTrack);
        if (link == null) return;
        await Clipboard.setData(ClipboardData(text: link.webUrl));
        if (!mounted || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarUrlCopied(link.serviceName)),
          ),
        );
      case TrackActionId.copyTitle:
        await Clipboard.setData(
          ClipboardData(text: '${mediaItem.title} - ${mediaItem.artist ?? ''}'),
        );
        if (!mounted || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.trackCopiedToClipboard)),
        );
      case TrackActionId.details:
        unawaited(
          showPlayerDetailsSheet(
            context,
            colorScheme,
            metadata: _trackMetadata,
            mediaItem: ref.read(currentMediaItemProvider).value,
          ),
        );
      case TrackActionId.shareLyrics:
        await _shareLyrics();
      case TrackActionId.sendToDesktop:
        await linkSendSongsToDesktop(context, ref, transfer.phone);
      case TrackActionId.saveToPhone:
        linkSaveSongsToPhone(context, ref, transfer.desktop);
      case TrackActionId.sleepTimer:
        await _showSleepTimerSheet(context, controller, colorScheme);
      case TrackActionId.equalizer:
        await pushPage<void>(context, (_) => const EqualizerScreen());
      case TrackActionId.volume:
        ref.read(settingsProvider.notifier).setPlayerShowVolume(!volumeShown);
      case TrackActionId.external:
        await _openExternally(source);
      case TrackActionId.download:
        if (playerTrack != null) {
          await downloadSingleTrack(context, ref, playerTrack);
        }
      case TrackActionId.playLocal ||
          TrackActionId.playNext ||
          TrackActionId.addToQueue ||
          TrackActionId.downloadOnDesktop:
        break;
    }
  }

  /// The collection track of the playing song, from memory when already
  /// resolved and otherwise within a short wait, so the menu opens with its
  /// final state.
  Future<Track?> _resolvePlayerTrack(MediaItem item) async {
    try {
      final provider = playerCollectionTrackProvider(item);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      return await ref
          .read(provider.future)
          .timeout(const Duration(milliseconds: 350));
    } catch (_) {
      return null;
    }
  }

  Future<Color?> _resolveCoverColor(String source) async {
    final cached = CoverPalette.peekSourceColor(source);
    if (cached != null) return cached;
    try {
      return await CoverPalette.resolveSourceColor(
        source,
      ).timeout(const Duration(milliseconds: 250));
    } catch (_) {
      return null;
    }
  }

  Future<void> _showSleepTimerSheet(
    BuildContext context,
    MusicPlayerController controller,
    ColorScheme colorScheme,
  ) async {
    const durations = [15, 30, 45, 60];
    final isActive = controller.sleepTimerEndsAt != null;
    final selection = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.nowPlayingSleepTimer,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SettingsGroup(
          children: [
            for (final minutes in durations)
              SettingsItem(
                icon: Icons.timer_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerMinutes(minutes),
                showDivider: isActive || minutes != durations.last,
                onTap: () => Navigator.of(sheetContext).pop('$minutes'),
              ),
            if (isActive)
              SettingsItem(
                icon: Icons.timer_off_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerOff,
                showDivider: false,
                onTap: () => Navigator.of(sheetContext).pop('off'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !context.mounted || selection == null) return;

    if (selection == 'off') {
      controller.cancelSleepTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.nowPlayingSleepTimerCancelled)),
      );
      return;
    }

    final minutes = int.tryParse(selection);
    if (minutes == null) return;
    controller.setSleepTimer(Duration(minutes: minutes));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.nowPlayingSleepTimerSet(
            context.l10n.nowPlayingSleepTimerMinutes(minutes),
          ),
        ),
      ),
    );
  }

  Future<void> _goToCurrentAlbum({
    required MediaItem mediaItem,
    required String source,
  }) => openPlayingAlbum(context, ref, mediaItem: mediaItem, source: source);

  /// Opens Up Next. The Material sheet captures the theme of [context], the
  /// player's artwork scope.
  void _showQueueSheet(BuildContext context, ColorScheme colorScheme) {
    if (_toggleInspector(2)) return;
    if (context.isMornye) {
      _setMornyePage(2);
      return;
    }
    if (_queueSheetShowing) return;
    _queueSheetShowing = true;
    showPlayerQueueSheet(
      context,
      colorScheme,
    ).whenComplete(() => _queueSheetShowing = false);
  }
}

const _overVideoShadows = [
  Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1)),
  Shadow(color: Color(0x66000000), blurRadius: 2),
];

PlayerCoverVideo? _coverVideo(MotionArtwork? artwork) => artwork == null
    ? null
    : PlayerCoverVideo(
        artwork.source,
        local: !artwork.source.startsWith('http'),
      );
