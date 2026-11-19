import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/controllers/player_track_navigation.dart';
import 'package:mornye/theme/cover_backdrop.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/artist_avatar.dart';
import 'package:mornye/widgets/journey_artists_list.dart';
import 'package:mornye/widgets/journey_enriched_info_card.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/player_track_info_card.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';

/// Only jump if both the current item and the displayed successor still match.
Future<void> playJourneyNext(
  WidgetRef ref,
  MediaItem current,
  MediaItem next,
) async {
  bool same(MediaItem? a, MediaItem b) =>
      a != null && a.id == b.id && a.extras?['source'] == b.extras?['source'];
  final liveCurrent = ref.read(currentMediaItemProvider).value;
  final queue = ref.read(playQueueProvider).value ?? const <MediaItem>[];
  final index = ref.read(currentQueueIndexProvider);
  if (!same(liveCurrent, current) ||
      index < 0 ||
      index + 1 >= queue.length ||
      !same(queue[index], current) ||
      !same(queue[index + 1], next))
    return;
  await ref.read(musicPlayerControllerProvider).jumpTo(index + 1);
}

/// Portrait journey from the playback surface to the current track's data.
class PlayerSongJourney extends StatefulWidget {
  const PlayerSongJourney({
    super.key,
    required this.item,
    required this.metadata,
    required this.player,
    required this.playerHeight,
    required this.lyrics,
    this.enabled = true,
    this.compactAction,
    this.nextItem,
    this.onNextItem,
    this.onOpenQueue,
    this.onArtist,
    this.onArtistNamed,
    this.onAlbum,
    this.artistImageResolver = defaultArtistImageResolver,
    this.artistImageProviderFactory = defaultArtistImageProvider,
  });

  final MediaItem item;
  final PlayerMetadataController metadata;
  final Widget player;
  final double playerHeight;
  final Widget lyrics;
  final bool enabled;
  final Widget? compactAction;
  final MediaItem? nextItem;
  final VoidCallback? onNextItem;
  final VoidCallback? onOpenQueue;
  final VoidCallback? onArtist;
  final ValueChanged<String>? onArtistNamed;
  final VoidCallback? onAlbum;
  final ArtistImageResolver artistImageResolver;
  final ArtistImageProviderFactory artistImageProviderFactory;

  @override
  State<PlayerSongJourney> createState() => _PlayerSongJourneyState();
}

class _PlayerSongJourneyState extends State<PlayerSongJourney> {
  final ValueNotifier<bool> _lyricsVisible = ValueNotifier(false);
  final GlobalKey _lyricsCardKey = GlobalKey();
  final ScrollController _scroll = ScrollController();
  bool _showCompact = false;
  Map<String, dynamic> _details = const {};
  int _detailsGeneration = 0;

  void _inspectVisibleLyrics() {
    final item = widget.item;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.enabled ||
          !_lyricsVisible.value ||
          !identical(widget.item, item))
        return;
      final generation = ++_detailsGeneration;
      unawaited(() async {
        await widget.metadata.load(item, inspectUnresolvedContentUri: true);
        if (!mounted ||
            generation != _detailsGeneration ||
            !identical(widget.item, item))
          return;
        final details = await widget.metadata.readDetails(item);
        if (mounted &&
            generation == _detailsGeneration &&
            identical(widget.item, item)) {
          setState(() => _details = details);
        }
      }());
    });
  }

  @override
  void didUpdateWidget(covariant PlayerSongJourney oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.item, widget.item)) {
      _detailsGeneration++;
      _details = const {};
    }
    if (!widget.enabled) {
      _lyricsVisible.value = false;
    } else if (_lyricsVisible.value &&
        (!identical(oldWidget.item, widget.item) ||
            oldWidget.metadata != widget.metadata)) {
      _inspectVisibleLyrics();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _lyricsVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glassText = Theme.of(
      context,
    ).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white);
    final item = widget.item;
    final metadata = widget.metadata;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Ignore the nested lyrics list: only the outer viewport determines
            // whether the lyric card is on screen.
            if (notification.depth == 0) {
              final metrics = notification.metrics;
              final compact = widget.enabled && metrics.pixels > 100;
              if (_showCompact != compact)
                setState(() => _showCompact = compact);
              final cardHeight =
                  _lyricsCardKey.currentContext?.size?.height ?? 0;
              final visible =
                  widget.enabled &&
                  metrics.pixels + metrics.viewportDimension >
                      widget.playerHeight &&
                  metrics.pixels < widget.playerHeight + cardHeight;
              if (_lyricsVisible.value != visible) {
                _lyricsVisible.value = visible;
                if (visible) _inspectVisibleLyrics();
              }
            }
            return false;
          },
          child: SingleChildScrollView(
            key: const ValueKey('player-song-journey'),
            controller: _scroll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: widget.playerHeight, child: widget.player),
                if (widget.enabled)
                  Padding(
                    key: _lyricsCardKey,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                          child: Text(
                            context.l10n.trackLyrics,
                            style: glassText.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 300,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _lyricsVisible,
                            child: widget.lyrics,
                            builder: (context, visible, child) =>
                                TickerMode(enabled: visible, child: child!),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.enabled && (item.artist ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: VisionGradientCard(
                      key: const ValueKey('journey-artist'),
                      child: JourneyArtistsList(
                        artistNames: item.artist!.trim(),
                        artistIds: journeyCatalogTrack(item)?.artistId,
                        extensionId: playingCatalogExtensionId(item),
                        onSingleArtist: widget.onArtist,
                        onArtist: widget.onArtistNamed,
                        resolver: widget.artistImageResolver,
                        imageProviderFactory: widget.artistImageProviderFactory,
                      ),
                    ),
                  ),
                if (widget.enabled && (item.album ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: VisionGradientCard(
                      key: const ValueKey('journey-album'),
                      child: ListTile(
                        title: Text(context.l10n.trackAlbum),
                        subtitle: Text(item.album!),
                        trailing: widget.onAlbum == null
                            ? null
                            : const Icon(Icons.chevron_right),
                        onTap: widget.onAlbum,
                      ),
                    ),
                  ),
                if (widget.enabled)
                  ListenableBuilder(
                    listenable: metadata,
                    builder: (context, _) {
                      // detailsSnapshot scopes cached tags by id AND source.
                      final details = metadata.detailsSnapshot(item);
                      String? field(String key) {
                        final value =
                            (details.containsKey(key)
                                    ? details[key]
                                    : _details[key])
                                ?.toString()
                                .trim();
                        return value == null || value.isEmpty ? null : value;
                      }

                      final loaded = metadata.item;
                      final sameSource =
                          loaded?.id == item.id &&
                          loaded?.extras?['source'] == item.extras?['source'];
                      final lyricist = sameSource
                          ? metadata.lyrics.writers
                          : null;
                      final isCatalog =
                          item.extras?['source']?.toString().startsWith(
                            'catalog:',
                          ) ==
                          true;
                      final audio = isCatalog
                          ? (sameSource
                                ? metadata.verifiedAudioMetadata
                                : const <String, dynamic>{})
                          : <String, dynamic>{
                              'audio_codec': details['audio_codec'],
                              'format': details['format'],
                              'sample_rate': details['sample_rate'],
                              'bit_depth': details['bit_depth'],
                              'bitrate': details['bitrate'],
                            };
                      final facts = buildTrackInfoFacts(
                        item: item,
                        field: field,
                        lyricsWriters: lyricist,
                        audioFacts: audio,
                      );
                      if (facts.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        child: JourneyEnrichedInfoCard(
                          item: item,
                          facts: facts,
                        ),
                      );
                    },
                  ),
                if (widget.enabled && widget.nextItem != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      MediaQuery.textScalerOf(context).scale(88),
                    ),
                    child: VisionGradientCard(
                      child: ListTile(
                        title: Text(context.l10n.nowPlayingNextTrack),
                        subtitle: Text(
                          widget.nextItem!.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          key: const ValueKey('journey-open-queue'),
                          tooltip: context.l10n.snackbarViewQueue,
                          onPressed: widget.onOpenQueue,
                          icon: const Icon(Icons.queue_music),
                        ),
                        onTap: widget.onNextItem,
                      ),
                    ),
                  )
                else if (widget.enabled)
                  SizedBox(height: MediaQuery.textScalerOf(context).scale(88)),
              ],
            ),
          ),
        ),
        if (_showCompact && widget.enabled)
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: PlayerJourneyCompactBar(
              key: const ValueKey('journey-compact-player'),
              item: item,
              action: widget.compactAction,
              onTap: () => _scroll.animateTo(
                0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              ),
            ),
          ),
      ],
    );
  }
}

Color journeyOnColor(Color background) {
  final white = Colors.white.computeLuminance();
  final black = Colors.black.computeLuminance();
  final light = background.computeLuminance();
  final whiteContrast = (white + 0.05) / (light + 0.05);
  final blackContrast = (light + 0.05) / (black + 0.05);
  return whiteContrast >= blackContrast ? Colors.white : Colors.black;
}

double journeyContrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  final hi = math.max(x, y);
  final lo = math.min(x, y);
  return (hi + 0.05) / (lo + 0.05);
}

/// White or black, whichever reads best over every colour in [fills]. Each
/// fill is judged over a dark base, as the translucent bar sits on one.
Color journeyOnColorFor(Iterable<Color> fills) {
  final bases = [
    for (final fill in fills)
      Color.alphaBlend(fill, Colors.black.withValues(alpha: .45)),
  ];
  double worst(Color on) =>
      bases.map((base) => journeyContrast(on, base)).reduce(math.min);
  return worst(Colors.white) >= worst(Colors.black)
      ? Colors.white
      : Colors.black;
}

/// Fill of the compact bar for a cover [tint]: solid with high contrast.
Color journeyFill(Color tint, {required bool highContrast}) => highContrast
    ? Color.alphaBlend(tint, Colors.black)
    : Color.alphaBlend(
        tint.withValues(alpha: .62),
        Colors.black.withValues(alpha: .30),
      );

/// Tint, in the cover's own colours, used by the compact bar. Tones stay low
/// enough for white text.
Color journeyCoverTint(CoverBackdrop backdrop) =>
    backdrop.gradientColors(const [40]).first;

/// Floating bar with the cover, the title and the play control: tinted glass
/// in the cover's colour that fades to the next cover's colour on a track
/// change. Without animations the colour changes at once; with high contrast
/// the fill is solid and no blur is drawn.
class PlayerJourneyCompactBar extends StatelessWidget {
  const PlayerJourneyCompactBar({
    super.key,
    required this.item,
    required this.onTap,
    this.action,
    this.backdrop,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final Widget? action;

  final CoverBackdrop? backdrop;

  static const double _thumb = 44;
  static const BorderRadius _radius = BorderRadius.all(Radius.circular(18));

  Widget _bar(BuildContext context, CoverBackdrop palette) {
    final highContrast = MediaQuery.highContrastOf(context);
    final fade = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 500);
    final tint = journeyCoverTint(palette);
    final fill = journeyFill(tint, highContrast: highContrast);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: fill),
      duration: fade,
      curve: Curves.easeInOut,
      builder: (context, color, _) {
        final background = color ?? fill;
        final onColor = journeyOnColor(
          Color.alphaBlend(background, Colors.black.withValues(alpha: .45)),
        );
        final textTheme = Theme.of(context).textTheme;
        final cacheSize = (_thumb * MediaQuery.devicePixelRatioOf(context))
            .ceil();
        final fallback = Container(
          width: _thumb,
          height: _thumb,
          alignment: Alignment.center,
          color: onColor.withValues(alpha: .16),
          child: Icon(Icons.music_note, color: onColor, size: 22),
        );
        final art = item.artUri?.toString() ?? '';
        final content = Material(
          type: MaterialType.transparency,
          child: IconTheme(
            data: IconThemeData(color: onColor),
            child: Theme(
              data: Theme.of(context).copyWith(
                iconButtonTheme: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    foregroundColor: onColor,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: onTap,
                      borderRadius: _radius,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox.square(
                                dimension: _thumb,
                                child: art.isEmpty
                                    ? fallback
                                    : CachedCoverImage(
                                        key: const ValueKey(
                                          'journey-compact-art',
                                        ),
                                        imageUrl: art,
                                        width: _thumb,
                                        height: _thumb,
                                        memCacheWidth: cacheSize,
                                        memCacheHeight: cacheSize,
                                        placeholder: (_, _) => fallback,
                                        errorWidget: (_, _, _) => fallback,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall?.copyWith(
                                      color: onColor,
                                    ),
                                  ),
                                  if ((item.artist ?? '').trim().isNotEmpty)
                                    Text(
                                      item.artist!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: onColor.withValues(alpha: .86),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ?action,
                ],
              ),
            ),
          ),
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: _radius,
            border: Border.all(color: onColor.withValues(alpha: .22)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: _radius,
            child: BackdropFilter(
              enabled: !highContrast,
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: ColoredBox(
                key: const ValueKey('journey-compact-fill'),
                color: background,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fixed = backdrop;
    if (fixed != null) return _bar(context, fixed);
    return CoverBackdropBuilder(
      imageSource: item.artUri?.toString(),
      builder: _bar,
    );
  }
}
