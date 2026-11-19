import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/player_video_mode_provider.dart';
import 'package:mornye/providers/player_video_session_provider.dart';
import 'package:mornye/services/catalog_playback.dart' show CatalogPreparation;
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:mornye/services/youtube_video_install.dart';
import 'package:mornye/utils/history_track.dart';
import 'package:mornye/widgets/automix_status_badge.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';
import 'package:mornye/widgets/player_video_fill.dart';
import 'package:mornye/widgets/track_video_gate.dart';

const Duration videoFailureDuration = Duration(seconds: 8);

double estimatedVideoProgress(Duration elapsed) =>
    videoFillProgress(elapsed.inMilliseconds / 1000.0);

void tellPlayerVideoOutcome(BuildContext context, PlayerVideoOutcome outcome) {
  final l10n = context.l10n;
  final message = switch (outcome) {
    PlayerVideoOutcome.failed => l10n.qualityVideoFailed,
    PlayerVideoOutcome.needsNetwork => l10n.qualityVideoNeedsWifi,
    _ => null,
  };
  if (message == null) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: videoFailureDuration,
      showCloseIcon: true,
    ),
  );
}

/// The video offer of the playing song as a pill. It lives over the cover and
/// takes no layout space: it fades in only when the song has a video.
class PlayerVideoPill extends ConsumerStatefulWidget {
  const PlayerVideoPill({
    super.key,
    required this.metadata,
    required this.colorScheme,
  });

  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;

  @override
  ConsumerState<PlayerVideoPill> createState() => _PlayerVideoPillState();
}

class _PlayerVideoPillState extends ConsumerState<PlayerVideoPill> {
  final _lookup = TrackVideoLookup();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    installYoutubeTrackVideoSource(ProviderScope.containerOf(context));
  }

  Future<void> _press(
    Track track,
    TrackVideoTag tag,
    String? replacing,
    String? quality,
  ) async {
    final outcome = await ref
        .read(playerVideoSessionProvider.notifier)
        .toggle(track, tag, replacing: replacing, currentQuality: quality);
    if (mounted) tellPlayerVideoOutcome(context, outcome);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.metadata,
    builder: (context, _) => Consumer(
      builder: (context, ref, _) {
        final catalog = playingCatalogTrack();
        final source = widget.metadata.source;
        final history = catalog != null || source == null
            ? null
            : ref.watch(
                downloadHistoryProvider.select(
                  (state) => state.lookupItems
                      .where((item) => item.filePath == source)
                      .firstOrNull,
                ),
              );
        final Track? track =
            catalog ?? (history == null ? null : trackFromHistoryItem(history));
        if (track == null) return const SizedBox.shrink();
        final key = trackCollectionKey(track);
        final session = ref.watch(playerVideoSessionProvider);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(playerVideoSessionProvider.notifier).abandonUnless(key);
          }
        });
        final request = catalog == null ? null : playingCatalogRequest(catalog);
        final currentId = history == null ? request?.quality : history.quality;
        return TrackVideoGate(
          track: track,
          lookup: _lookup,
          active:
              ref.watch(playerVideoModeProvider) != null &&
              session.activeKey == key,
          loading: session.loadingFor(key),
          colorScheme: widget.colorScheme,
          onPressed: (tag) => _press(track, tag, history?.filePath, currentId),
        );
      },
    ),
  );
}

class PreparingVideoMark extends StatefulWidget {
  const PreparingVideoMark({
    super.key,
    required this.started,
    this.done = false,
    this.realProgress,
    this.colorScheme,
    this.height = 44,
    this.badgeSize = 26,
  });

  final DateTime started;
  final bool done;
  final double? realProgress;
  final ColorScheme? colorScheme;
  final double height;
  final double badgeSize;

  @override
  State<PreparingVideoMark> createState() => _PreparingVideoMarkState();
}

class _PreparingVideoMarkState extends State<PreparingVideoMark>
    with SingleTickerProviderStateMixin {
  static const _horizonSeconds = 3600;
  late final AnimationController _clock;
  late final VideoFillState _fill;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController.unbounded(vsync: this);
    _fill = VideoFillState(_clock);
    _restart();
    _fill.real = widget.realProgress;
    if (widget.done) _fill.complete();
  }

  void _restart() {
    final elapsed = DateTime.now().difference(widget.started);
    final start = math.max(0, elapsed.inMilliseconds) / 1000.0;
    _fill.reset();
    _clock.value = start;
    unawaited(
      _clock.animateTo(
        start + _horizonSeconds,
        duration: const Duration(seconds: _horizonSeconds),
        curve: Curves.linear,
      ),
    );
  }

  @override
  void didUpdateWidget(PreparingVideoMark old) {
    super.didUpdateWidget(old);
    if (old.started != widget.started) _restart();
    _fill.real = widget.realProgress;
    if (widget.done) _fill.complete();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Widget _logo(Color color, String label, String detail) {
    final size = widget.badgeSize;
    final rule = Container(
      width: 1,
      height: size * 0.82,
      margin: EdgeInsets.symmetric(horizontal: size * 0.3),
      color: color.withValues(alpha: 0.55),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.6),
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          child: SizedBox.square(
            dimension: size,
            child: Icon(
              Icons.play_arrow_rounded,
              size: size * 0.78,
              color: color,
            ),
          ),
        ),
        rule,
        Text(
          label.toUpperCase(),
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: color,
            fontSize: math.max(11, size * 0.62),
            fontWeight: FontWeight.w800,
            height: 1,
            letterSpacing: size * 0.02,
          ),
        ),
        rule,
        Text(
          detail,
          maxLines: 1,
          softWrap: false,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: color,
            fontSize: math.max(10, size * 0.46),
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? Theme.of(context).colorScheme;
    final color = scheme.onSurface;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final l10n = context.l10n;
    final label = l10n.qualityVideoLabel;
    final real = widget.realProgress;
    final detail = real == null ? '…' : '${(real * 100).floor()} %';
    final logo = _logo(color, label, detail);
    return RepaintBoundary(
      child: Semantics(
        label: label,
        value: real == null
            ? l10n.qualityPickerSwitching
            : '${(real * 20).floor() * 5} %',
        child: ExcludeSemantics(
          child: SizedBox(
            key: const ValueKey('video-preparing-mark'),
            height: widget.height,
            child: Center(
              widthFactor: 1,
              child: AnimatedBuilder(
                animation: _clock,
                builder: (context, _) {
                  if (_fill.doneAt != null && _fill.fill >= 1) {
                    return KeyedSubtree(
                      key: const ValueKey('video-mark-full'),
                      child: logo,
                    );
                  }
                  return Stack(
                    key: const ValueKey('video-mark-filling'),
                    children: [
                      Opacity(opacity: 0.32, child: logo),
                      ClipRect(clipper: VideoFillClipper(_fill), child: logo),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            key: const ValueKey('video-fill-glow'),
                            painter: VideoFillGlowPainter(
                              state: _fill,
                              color: color,
                              shimmer: !reduce,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Notes about a song's preparation and the automix, shown over the cover so
/// they never take height from the cover or the controls.
class PlayerStatusNotices extends StatelessWidget {
  const PlayerStatusNotices({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final handler = musicPlayerRuntime.handler;
    final source = handler?.catalogPreparation;
    Widget notices(CatalogPreparation? prep) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (prep != null)
          PreparationFeedback(
            key: ValueKey('notice-${prep.key}'),
            preparation: prep,
            colorScheme: colorScheme,
            onRetry: () => handler?.retryCurrentPreparation(),
            onCancel: () => handler?.cancelCurrentPreparation(),
          ),
        const AutoMixStatusBadge(),
      ],
    );
    if (source == null) return notices(null);
    return ValueListenableBuilder(
      valueListenable: source,
      builder: (context, prep, _) {
        final catalog = playingCatalogTrack();
        final matches =
            prep != null &&
            (catalog == null || trackCollectionKey(catalog) == prep.key);
        return notices(matches ? prep : null);
      },
    );
  }
}
