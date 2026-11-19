import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/album_quality_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/utils/album_quality.dart';
import 'package:mornye/utils/history_track.dart';
import 'package:mornye/utils/playback_quality_options.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/tap_target_expander.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/track_quality_selector.dart';

/// Large quality logo at the top of an album page. It shows the quality of
/// the album's downloaded files, or the one a download would use. Choosing a
/// format stores it for this album only; if files are already downloaded they
/// are replaced one at a time after a confirmation.
class AlbumQualityBadge extends ConsumerStatefulWidget {
  const AlbumQualityBadge({
    super.key,
    required this.albumName,
    required this.artistName,
    this.catalogTracks = const [],
    this.downloadedItems,
    this.size = 32,
  });

  final String albumName;
  final String? artistName;
  final List<Track> catalogTracks;

  /// Downloaded files of the album when the page lists them itself.
  final List<DownloadHistoryItem>? downloadedItems;
  final double size;

  @override
  ConsumerState<AlbumQualityBadge> createState() => _AlbumQualityBadgeState();
}

class _AlbumQualityBadgeState extends ConsumerState<AlbumQualityBadge> {
  @override
  void initState() {
    super.initState();
    SpecialQualityAvailability.instance.addListener(_availabilityChanged);
  }

  @override
  void dispose() {
    SpecialQualityAvailability.instance.removeListener(_availabilityChanged);
    super.dispose();
  }

  void _availabilityChanged() {
    if (mounted) setState(() {});
  }

  String get _key => albumQualityKey(widget.albumName, widget.artistName);

  Extension? _extension(String? serviceId) {
    final state = ref.read(extensionProvider);
    final settings = ref.read(settingsProvider);
    final id =
        (serviceId == null || serviceId.trim().isEmpty
                ? resolveQualityService(
                    extensionQualityView(state),
                    settings.defaultService,
                    settings.autoFallback,
                  )
                : serviceId)
            .trim()
            .toLowerCase();
    return state.extensions
        .where((e) => e.id.trim().toLowerCase() == id)
        .firstOrNull;
  }

  List<({Track track, DownloadHistoryItem item})> _downloads(
    Iterable<DownloadHistoryItem> history,
  ) {
    final given = widget.downloadedItems;
    if (given != null) {
      return [
        for (final item in given)
          if (!item.filePath.startsWith('network://'))
            (track: trackFromHistoryItem(item), item: item),
      ];
    }
    return albumDownloadsFor(widget.catalogTracks, history, widget.albumName);
  }

  Future<void> _select(
    TrackQualityChoice choice,
    List<({Track track, DownloadHistoryItem item})> downloads,
  ) async {
    final store = ref.read(albumQualityChoicesProvider.notifier);
    final replacer = ref.read(albumQualityReplacerProvider.notifier);
    if (replacer.isRunning(_key)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    if (downloads.isEmpty) {
      await store.choose(_key, choice.id);
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.albumQualityChosenForDownload)),
      );
      return;
    }
    final pending = [
      for (final entry in downloads)
        if (!downloadHasQuality(entry.item, choice)) entry,
    ];
    if (pending.isEmpty) {
      await store.choose(_key, choice.id);
      return;
    }
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(l10n.albumQualityReplaceTitle),
        content: Text(l10n.albumQualityReplaceMessage(pending.length)),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.albumQualityReplaceAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.choose(_key, choice.id);
    await replacer.replace(
      albumKey: _key,
      entries: pending,
      qualityId: choice.id,
    );
  }

  void _announce(AlbumReplaceProgress? previous, AlbumReplaceProgress? next) {
    if (previous?.running != true || next == null || next.running) return;
    if (!mounted) return;
    final l10n = context.l10n;
    final text = next.failed == 0
        ? l10n.albumQualityReplaceDone(next.done)
        : l10n.albumQualityReplacePartial(next.done, next.failed);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final key = _key;
    ref.listen<AlbumReplaceProgress?>(
      albumQualityReplacerProvider.select((progress) => progress[key]),
      _announce,
    );
    final history = ref.watch(
      downloadHistoryProvider.select((state) => state.lookupItems),
    );
    final chosenId = ref.watch(
      albumQualityChoicesProvider.select((choices) => choices[key]),
    );
    final progress = ref.watch(
      albumQualityReplacerProvider.select((value) => value[key]),
    );
    final settings = ref.watch(
      settingsProvider.select(
        (s) => (
          s.defaultService,
          s.autoFallback,
          s.audioQuality,
          s.downloadQualityByProvider,
        ),
      ),
    );
    ref.watch(extensionProvider.select(extensionQualityView));
    final downloads = _downloads(history);
    final extension = _extension(downloads.firstOrNull?.item.service);
    final options = extension == null
        ? const <QualityOption>[]
        : extension.qualityOptions;
    final firstTrack = widget.catalogTracks.firstOrNull;
    var choices = buildTrackQualityChoices(options: options, track: firstTrack);
    String? defaultId;
    if (extension != null && options.isNotEmpty) {
      defaultId = downloadQualitySelection(
        settings.$1,
        settings.$3,
        settings.$4,
        PlaybackQualityGroup(extension, options),
      ).id;
    }
    final view = resolveAlbumQuality(
      downloads: [for (final entry in downloads) entry.item],
      choices: choices,
      catalogTracks: widget.catalogTracks,
      chosenId: chosenId,
      defaultId: defaultId,
    );
    if (view == null) return const SizedBox.shrink();
    if (choices.isNotEmpty) {
      choices = buildTrackQualityChoices(
        options: options,
        currentId: view.choiceId,
        track: firstTrack,
      );
    }
    final scheme = HeaderPalette.of(context);
    final running = progress?.running == true;
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TapTargetExpander(
          child: TrackQualitySelector(
            currentFormat: view.format,
            currentMark: view.mark,
            currentDetail: view.detail,
            currentLabel: view.label,
            choices: choices,
            colorScheme: scheme,
            height: widget.size + 12,
            badgeSize: widget.size,
            replacesFile: view.downloaded,
            progress: running ? progress!.finished / progress.total : null,
            onSelected: (choice) {
              if (extension == null || choices.isEmpty || running) return;
              _select(choice, downloads);
            },
          ),
        ),
        if (running)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              label: l10n.albumQualityReplacing(
                progress!.finished,
                progress.total,
              ),
              child: ExcludeSemantics(
                child: Text(
                  '${progress.finished}/${progress.total}',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          )
        else if (view.mixed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.albumQualityMixed,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
