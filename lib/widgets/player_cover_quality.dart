import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/quality_replace_result.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_file_catalog_track_provider.dart';
import 'package:mornye/providers/player_video_mode_provider.dart';
import 'package:mornye/providers/player_video_session_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:mornye/services/link/link_source_names.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:mornye/services/youtube_video_install.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:mornye/utils/history_track.dart';
import 'package:mornye/utils/download_provider_order.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/quality_switch_result.dart';
import 'package:mornye/widgets/verification_prompts.dart';
import 'package:mornye/widgets/audio_info_sheet.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';
import 'package:mornye/widgets/player_video_pill.dart';
import 'package:mornye/widgets/quality_mark_art.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:mornye/widgets/track_video_gate.dart';

const Duration qualitySwitchTimeout = Duration(seconds: 150);
const Duration switchFailureDuration = Duration(seconds: 10);
const Duration switchFailureTimedOutAfter = Duration(seconds: 60);

double estimatedQualityProgress(Duration elapsed, {required bool slow}) {
  final scale = slow ? 9000.0 : 4000.0;
  final t = elapsed.inMilliseconds / scale;
  return 0.95 * (1 - 1 / (1 + t));
}

const double _fullLockupWidth = 200;

final _log = AppLogger('PlayerQuality');

/// Kind of the playing file's source: `path` for a file on the device, `saf`
/// for a document URI, null for anything that is not a local file (streams,
/// network shares, catalog entries).
String? localSourceKind(String? source) {
  final value = source?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('content://')) return 'saf';
  if (value.startsWith('/') ||
      value.startsWith('file://') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    return 'path';
  }
  return null;
}

/// Quality badge and video chip of the playing song, wired to the player. A
/// streamed song switches quality in place; a downloaded one is downloaded
/// again and its file replaced. Anything else only shows its format.
class PlayerCoverQuality extends ConsumerStatefulWidget {
  const PlayerCoverQuality({
    super.key,
    required this.metadata,
    required this.colorScheme,
    this.preparation,
    this.inlineNotices = true,
    this.inlineVideo = true,
    this.slim = false,
  });

  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;
  final ValueListenable<CatalogPreparation?>? preparation;

  /// Whether the preparation notes sit under the badge. Layouts that keep the
  /// badge in a fixed slot show them elsewhere.
  final bool inlineNotices;

  /// Whether the video pill sits beside the badge. Layouts with the pill over
  /// the cover turn it off.
  final bool inlineVideo;

  /// A single small line of about 28 dp, for the fixed status row.
  final bool slim;

  @override
  ConsumerState<PlayerCoverQuality> createState() => _PlayerCoverQualityState();
}

class _PlayerCoverQualityState extends ConsumerState<PlayerCoverQuality> {
  final _lookup = TrackVideoLookup();
  double _availableWidth = double.infinity;
  bool _switching = false;
  QualityMark? _pendingMark;
  String? _pendingDetail;
  final _progress = ValueNotifier<double?>(null);
  Timer? _ticker;
  int _switchToken = 0;
  String? _switchKey;
  Track? _switchTrack;
  bool _switchCancellable = false;
  bool _switchReplacing = false;
  QualityMark? _playingMark;
  String? _playingDetail;
  QualityMark? _shownMark;
  String? _shownDetail;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    installYoutubeTrackVideoSource(ProviderScope.containerOf(context));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _progress.dispose();
    super.dispose();
  }

  int _beginSwitch(
    Track track,
    TrackQualityChoice choice, {
    double Function(Duration elapsed)? measured,
    bool replacing = false,
  }) {
    final started = DateTime.now();
    final slow = !isLossyMark(choice.mark);
    final token = ++_switchToken;
    _ticker?.cancel();
    setState(() {
      _switching = true;
      _pendingMark = choice.mark;
      _pendingDetail = choice.detail;
      _switchKey = trackCollectionKey(track);
      _switchTrack = track;
      _switchCancellable = measured == null || replacing;
      _switchReplacing = replacing;
    });
    _progress.value = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 160), (_) {
      final elapsed = DateTime.now().difference(started);
      if (measured == null && elapsed > qualitySwitchTimeout) {
        _failSwitch(token);
        return;
      }
      final real = measured?.call(elapsed);
      final next = real == null
          ? estimatedQualityProgress(elapsed, slow: slow)
          : math.min(real, 0.95);
      final previous = _progress.value ?? 0;
      _progress.value = math.max(previous, next);
    });
    return token;
  }

  void _failSwitch(int token) {
    if (token != _switchToken) return;
    final track = _switchTrack;
    final message = context.l10n.qualityPickerSwitchFailed;
    _resetSwitch();
    if (track != null) unawaited(cancelCatalogQualitySwitch(track));
    _tell(message);
  }

  void _cancelSwitch() {
    if (!_switching || !_switchCancellable) return;
    final track = _switchTrack;
    final replacing = _switchReplacing;
    _resetSwitch();
    if (track == null) return;
    if (replacing) {
      ref
          .read(downloadQueueProvider.notifier)
          .cancelTrackQualityReplacement(track);
    } else {
      unawaited(cancelCatalogQualitySwitch(track));
    }
  }

  void _resetSwitch() {
    _switchToken++;
    _ticker?.cancel();
    _ticker = null;
    _progress.value = null;
    if (!mounted) return;
    setState(() {
      _switching = false;
      _pendingMark = null;
      _pendingDetail = null;
      _switchKey = null;
      _switchTrack = null;
      _switchCancellable = false;
      _switchReplacing = false;
    });
  }

  void _abandonForTrack(String? key) {
    if (key == null) return;
    final switchChanged = _switching && _switchKey != null && _switchKey != key;
    if (!switchChanged) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (switchChanged && _switching && _switchKey != key) {
        final previous = _switchTrack;
        _resetSwitch();
        if (previous != null) unawaited(cancelCatalogQualitySwitch(previous));
      }
    });
  }

  Future<void> _endSwitch(int token, {required bool ok}) async {
    if (token != _switchToken) return;
    _ticker?.cancel();
    _ticker = null;
    if (ok && mounted) {
      _progress.value = 1;
      await Future<void>.delayed(const Duration(milliseconds: 420));
    }
    if (!mounted || token != _switchToken) return;
    _switchToken++;
    _progress.value = null;
    setState(() {
      _switching = false;
      _pendingMark = null;
      _pendingDetail = null;
      _switchKey = null;
      _switchTrack = null;
      _switchCancellable = false;
      _switchReplacing = false;
    });
  }

  double Function(Duration) _downloadProgress(Track track, String qualityId) {
    final key = trackCollectionKey(track);
    return (elapsed) {
      final items = ref.read(downloadQueueProvider).items;
      DownloadItem? found;
      for (final item in items.reversed) {
        if (trackCollectionKey(item.track) == key &&
            item.qualityOverride == qualityId) {
          found = item;
          break;
        }
      }
      if (found == null) return 0;
      final value = found.progress > 1 ? found.progress / 100 : found.progress;
      return value.clamp(0.0, 1.0).toDouble();
    };
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

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

  void _showInfo() => showAudioInfoSheet(
    context,
    metadata: widget.metadata,
    linkSources: ref.read(linkSourceNamesProvider),
  );

  Future<void> _switchStreaming(Track track, TrackQualityChoice choice) async {
    final token = _beginSwitch(track, choice);
    final started = DateTime.now();
    final already = context.l10n.qualityPickerAlreadyPlaying;
    final result = await requestCatalogQualitySwitchResult(
      track,
      choice.id,
      service: choice.service,
    );
    if (result.ok) {
      SpecialQualityAvailability.instance.clearAttemptFailure(
        track,
        choice.service,
        choice.id,
      );
    } else if (result.failure != QualitySwitchFailure.cancelled) {
      SpecialQualityAvailability.instance.noteAttemptFailed(
        track,
        choice.service,
        choice.id,
      );
    }
    debugPrint(
      'quality-list: switch ${result.ok ? 'ok' : 'failed'} '
      'service=${choice.service ?? 'none'} id=${choice.id} '
      'reason=${result.failure?.name ?? 'none'}',
    );
    if (token != _switchToken) return;
    if (result.ok && mounted) {
      ref.read(playerVideoSessionProvider.notifier).qualityChosen(choice.id);
    }
    await _endSwitch(token, ok: result.ok);
    if (!result.ok) {
      _tellSwitchFailure(
        choice,
        DateTime.now().difference(started),
        result: result,
        track: track,
      );
    } else if (_unchangedAfterSwitch(choice)) {
      _tell(already);
    }
  }

  String _failureReason(AppLocalizations l10n, QualitySwitchFailure failure) =>
      switch (failure) {
        QualitySwitchFailure.notCatalogTrack => l10n.qualityGuardNotCatalogTrack,
        QualitySwitchFailure.identityMismatch =>
          l10n.qualityGuardIdentityMismatch,
        QualitySwitchFailure.sourceNotReady => l10n.qualityGuardSourceNotReady,
        QualitySwitchFailure.casting => l10n.qualityGuardCasting,
        QualitySwitchFailure.directMode => l10n.qualityGuardDirectMode,
        QualitySwitchFailure.handoffRejected =>
          l10n.qualityGuardHandoffRejected,
        _ => l10n.qualityGuardOther,
      };

  void _tellSwitchFailure(
    TrackQualityChoice choice,
    Duration waited, {
    QualitySwitchResult? result,
    Track? track,
  }) {
    if (!mounted) return;
    final l10n = context.l10n;
    final format = qualityMarkText(
      context,
      choice.mark,
      detail: choice.detail,
    ).name;
    final provider = qualityServiceShortName(choice.service).isEmpty
        ? choice.id
        : qualityServiceShortName(choice.service);
    final failure = result?.failure;
    final verification = failure == QualitySwitchFailure.verificationRequired
        ? resolveVerificationTarget(ref, extensionId: result?.providerId)
        : null;
    final message = switch (failure) {
      QualitySwitchFailure.unavailable => l10n.qualityPickerSwitchUnavailable(
        provider,
      ),
      QualitySwitchFailure.timedOut => l10n.qualityPickerSwitchProviderSlow,
      QualitySwitchFailure.unsupportedFormat =>
        l10n.qualityPickerSwitchUnsupported,
      QualitySwitchFailure.verificationRequired =>
        l10n.qualityPickerSwitchVerify(verification?.name ?? provider),
      QualitySwitchFailure.cancelled => l10n.qualityPickerSwitchCancelled,
      QualitySwitchFailure.notCatalogTrack ||
      QualitySwitchFailure.identityMismatch ||
      QualitySwitchFailure.sourceNotReady ||
      QualitySwitchFailure.casting ||
      QualitySwitchFailure.directMode ||
      QualitySwitchFailure.handoffRejected => _failureReason(l10n, failure!),
      _ =>
        waited >= switchFailureTimedOutAfter
            ? l10n.qualityPickerSwitchTimedOut(provider, format)
            : l10n.qualityPickerSwitchFailedFor(format, provider),
    };
    final body =
        '${l10n.qualityPickerSwitchDetailsBody(format, provider, choice.id, '${waited.inSeconds}')}'
        '\n${l10n.qualityPickerSwitchDetailsCategory(_failureReason(l10n, failure ?? QualitySwitchFailure.other))}';
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: switchFailureDuration,
        showCloseIcon: true,
        action: verification != null && track != null
            ? SnackBarAction(
                label: l10n.verificationNoticeAction,
                onPressed: () => unawaited(
                  startVerification(
                    ref,
                    verification,
                    resume: () => _switchStreaming(track, choice),
                  ),
                ),
              )
            : _detailsAction(l10n, body),
      ),
    );
  }

  SnackBarAction _detailsAction(AppLocalizations l10n, String body) {
    final dialogContext = context;
    return SnackBarAction(
      label: l10n.qualityPickerSwitchDetails,
      onPressed: () {
        if (!dialogContext.mounted) return;
        showDialog<void>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: Text(l10n.qualityPickerSwitchDetailsTitle),
            content: SelectableText(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _unchangedAfterSwitch(TrackQualityChoice choice) {
    if (!mounted) return false;
    final mark = _shownMark;
    return mark != null &&
        mark == _playingMark &&
        _shownDetail == _playingDetail &&
        choice.mark == mark;
  }

  Future<void> _replaceDownload(
    Track track,
    TrackQualityChoice choice, {
    required String previous,
    String historyId = '',
    String? service,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final started = DateTime.now();
    final format = qualityMarkText(
      context,
      choice.mark,
      detail: choice.detail,
    ).name;
    final provider = qualityServiceShortName(choice.service ?? service).isEmpty
        ? choice.id
        : qualityServiceShortName(choice.service ?? service);
    final token = _beginSwitch(
      track,
      choice,
      measured: _downloadProgress(track, choice.id),
      replacing: true,
    );
    QualityReplaceResult result;
    try {
      result = await ref
          .read(downloadQueueProvider.notifier)
          .replaceTrackQuality(
            track,
            choice.service ?? service ?? 'tidal',
            choice.id,
            previousPath: previous,
            previousHistoryId: historyId,
            onReady: (newPath) async {
              final playing = widget.metadata.source;
              if (playing == null || !_samePhysicalFile(playing, previous)) {
                return true;
              }
              return requestPlaybackSourceSwitch(
                track,
                newPath,
                replacing: playing,
              );
            },
          );
    } catch (error) {
      debugPrint('replace: threw ${error.runtimeType}');
      result = QualityReplaceResult.failed(
        QualityReplaceFailure.downloadFailed,
        detail: error.runtimeType.toString(),
      );
    }
    final failure = result.failure;
    if (result.ok) {
      SpecialQualityAvailability.instance.clearAttemptFailure(
        track,
        choice.service ?? service,
        choice.id,
      );
    } else if (failure != QualityReplaceFailure.cancelled &&
        failure != QualityReplaceFailure.sameFile) {
      SpecialQualityAvailability.instance.noteAttemptFailed(
        track,
        choice.service ?? service,
        choice.id,
      );
    }
    debugPrint(
      'quality-list: replace ${result.ok ? 'ok' : 'failed'} '
      'service=${choice.service ?? service ?? 'none'} id=${choice.id} '
      'reason=${failure?.name ?? 'none'} '
      'current=${token == _switchToken ? 'yes' : 'no'}',
    );
    if (token == _switchToken) await _endSwitch(token, ok: result.ok);
    if (messenger == null) return;
    final message = _replaceMessage(l10n, result);
    final technical = [
      result.detail ?? '',
      result.summary ?? '',
    ].where((part) => part.isNotEmpty).join(' | ');
    final body = [
      l10n.qualityPickerSwitchDetailsBody(
        format,
        provider,
        choice.id,
        '${DateTime.now().difference(started).inSeconds}',
      ),
      l10n.qualityPickerSwitchDetailsCategory(message),
      if (technical.isNotEmpty) l10n.qualityReplaceDetailsTechnical(technical),
    ].join('\n');
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: result.ok ? const Duration(seconds: 4) : switchFailureDuration,
        showCloseIcon: !result.ok,
        action: result.ok ? null : _detailsAction(l10n, body),
      ),
    );
  }

  bool _samePhysicalFile(String a, String b) {
    if (a == b) return true;
    final keys = buildPathMatchKeys(b);
    return buildPathMatchKeys(a).any(keys.contains);
  }

  String _replaceMessage(AppLocalizations l10n, QualityReplaceResult result) {
    if (result.ok) {
      if (!result.switched) return l10n.qualityReplacedReload;
      if (!result.removedPrevious) return l10n.qualityReplacedKeptPrevious;
      return l10n.qualityPickerReplaced;
    }
    final typed = failureCauseForDownload(result.errorType);
    final cause = typed == null
        ? (result.detail ?? '')
        : failureMessage(l10n, typed);
    return switch (result.failure!) {
      QualityReplaceFailure.downloadFailed =>
        cause.isEmpty
            ? l10n.qualityReplaceDownloadFailedNoCause
            : l10n.qualityReplaceDownloadFailed(cause),
      QualityReplaceFailure.cancelled => l10n.qualityReplaceCancelled,
      QualityReplaceFailure.timedOut => l10n.qualityReplaceTimedOut,
      QualityReplaceFailure.noFile => l10n.qualityReplaceNoFile,
      QualityReplaceFailure.emptyFile => l10n.qualityReplaceEmpty,
      QualityReplaceFailure.sameFile => l10n.qualityReplaceNoOtherFormat,
      QualityReplaceFailure.durationMismatch => l10n.qualityReplaceDuration,
    };
  }

  Future<void> _pressVideo(
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _availableWidth = constraints.maxWidth;
      final preparation = _preparationSource;
      return ListenableBuilder(
        listenable: Listenable.merge([
          widget.metadata,
          SpecialQualityAvailability.instance,
          ?preparation,
        ]),
        builder: (context, _) =>
            Consumer(builder: (context, ref, _) => _content(context, ref)),
      );
    },
  );

  ValueListenable<CatalogPreparation?>? get _preparationSource =>
      widget.preparation ?? musicPlayerRuntime.handler?.catalogPreparation;

  Widget _fading(Object key, Widget child) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150),
    layoutBuilder: (current, previous) => Align(
      alignment: widget.slim ? Alignment.center : Alignment.centerLeft,
      child: current ?? const SizedBox.shrink(),
    ),
    child: KeyedSubtree(key: ValueKey(key), child: child),
  );

  double? Function() _preparationProgress(String key) => () {
    final items = ref.read(downloadQueueProvider).items;
    for (final item in items.reversed) {
      if (trackCollectionKey(item.track) != key) continue;
      if (item.status != DownloadStatus.downloading &&
          item.status != DownloadStatus.finalizing) {
        continue;
      }
      final value = item.progress > 1 ? item.progress / 100 : item.progress;
      if (value <= 0) return null;
      return value.clamp(0.0, 1.0).toDouble();
    }
    return null;
  };

  Future<void> _cancelPreparation(Track? track) async {
    await musicPlayerRuntime.handler?.cancelCurrentPreparation();
  }

  Future<void> _retryPreparation(Track? track) async {
    await musicPlayerRuntime.handler?.retryCurrentPreparation();
  }

  Widget _preparing(CatalogPreparation prep, Track? track) {
    final extension = _extension(prep.service) ?? _extension('tidal');
    final choices = extension == null
        ? const <TrackQualityChoice>[]
        : buildTrackQualityChoices(
            options: withDeclaredQualityKinds(
              extension.qualityOptions,
              fallbackTier: extension.capabilities['downloadFallbackTier']
                  ?.toString(),
            ),
            currentId: prep.quality,
            track: track,
            service: prep.service,
          );
    final chosen = choices.where((c) => c.current).firstOrNull;
    final mark = chosen?.mark ?? qualityMarkFor(prep.quality, prep.quality);
    final textScale = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3).scale(1);
    return _fading(
      'preparing',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          PreparingQualityMark(
            mark: mark,
            detail: chosen?.detail,
            started: prep.started,
            label: chosen?.label ?? prep.quality,
            realProgress: _preparationProgress(prep.key),
            colorScheme: widget.colorScheme,
            height: widget.slim ? 28 : 44,
            badgeSize: widget.slim ? 18 : (context.isMornye ? 22 : 26),
            compact:
                widget.slim || _availableWidth < _fullLockupWidth * textScale,
          ),
          if (widget.inlineNotices)
            PreparationFeedback(
              preparation: prep,
              colorScheme: widget.colorScheme,
              onRetry: () => _retryPreparation(track),
              onCancel: () => _cancelPreparation(track),
            ),
        ],
      ),
    );
  }

  String? _loggedSelector;

  void _logSelector(
    String origin,
    Track? track,
    int providers,
    List<TrackQualityChoice> choices,
    List<String> ruledOut,
    String src,
  ) {
    final isrc = (track?.isrc?.trim().isNotEmpty ?? false) ? 'si' : 'no';
    final failed = [
      for (final c in choices)
        if (c.failedLast) '${c.service ?? '-'}/${c.id}',
    ];
    final line =
        'quality: track=$origin isrc=$isrc providers=$providers '
        'choices=${choices.length} src=$src';
    final detail =
        '$line ruledOut=${ruledOut.join(',')} failedLast=${failed.join(',')}';
    if (_loggedSelector == detail) return;
    _loggedSelector = detail;
    _log.i(line);
    debugPrint('quality-list: $detail');
  }

  List<({String service, List<QualityOption> options})> _providers() {
    final extensions = [
      for (final e in ref.read(extensionProvider).extensions)
        if (e.enabled &&
            e.status != 'error' &&
            e.hasDownloadProvider &&
            e.qualityOptions.isNotEmpty)
          e,
    ];
    final order = defaultDownloadProviderOrder(extensions);
    int rank(Extension e) {
      final index = order.indexOf(e.id.trim());
      return index < 0 ? order.length : index;
    }

    extensions.sort((a, b) => rank(a).compareTo(rank(b)));
    return [
      for (final e in extensions)
        (
          service: e.id,
          options: withDeclaredQualityKinds(
            e.qualityOptions,
            fallbackTier: e.capabilities['downloadFallbackTier']?.toString(),
          ),
        ),
    ];
  }

  Widget _content(BuildContext context, WidgetRef ref) {
    final text = widget.metadata.qualityLabel;
    final source = widget.metadata.source;
    final catalog = playingCatalogTrack();
    final preparing = _preparationSource?.value;
    if (preparing != null &&
        (catalog == null || trackCollectionKey(catalog) == preparing.key)) {
      return _preparing(preparing, catalog);
    }
    final kind = catalog == null ? localSourceKind(source) : null;
    final memoryHistory = catalog != null || source == null
        ? null
        : ref.watch(
            downloadHistoryProvider.select(
              (state) => state.lookupItems
                  .where((item) => item.filePath == source)
                  .firstOrNull,
            ),
          );
    final storedHistory = memoryHistory != null || kind == null
        ? null
        : ref.watch(downloadHistoryForFileProvider(source!)).value;
    final history = memoryHistory ?? storedHistory;
    ref.watch(extensionProvider.select(extensionQualityView));
    final mediaItem = widget.metadata.item;
    final mediaTrack = kind == null || mediaItem == null
        ? null
        : collectionTrackForMedia(mediaItem, null);
    final mediaHasIsrc = mediaTrack?.isrc?.trim().isNotEmpty ?? false;
    final localTrack =
        catalog != null || history != null || kind == null || mediaHasIsrc
        ? null
        : ref.watch(localFileCatalogTrackProvider(source!)).value;
    final Track? track =
        catalog ??
        (history == null
            ? (localTrack ?? mediaTrack)
            : trackFromHistoryItem(history));
    final origin = catalog != null
        ? 'catalog'
        : history != null
        ? 'history'
        : localTrack != null
        ? 'library'
        : mediaTrack != null
        ? 'media'
        : 'none';
    final replacesFile = history != null || (kind != null && track != null);
    _abandonForTrack(track == null ? null : trackCollectionKey(track));
    final videoSession = ref.watch(playerVideoSessionProvider);
    final videoStarted = videoSession.started;
    if (videoStarted != null &&
        (track == null || videoSession.loadingFor(trackCollectionKey(track)))) {
      return _fading(
        'video',
        PreparingVideoMark(
          started: videoStarted,
          done: videoSession.done,
          colorScheme: widget.colorScheme,
          height: widget.slim ? 28 : 44,
          badgeSize: widget.slim ? 18 : (context.isMornye ? 22 : 26),
        ),
      );
    }
    final request = catalog == null ? null : playingCatalogRequest(catalog);
    final currentId = history == null ? request?.quality : history.quality;
    final ownOptions = track == null
        ? null
        : (_extension(history?.service ?? request?.service) ??
                  _extension('tidal'))
              ?.qualityOptions;
    final own = ownOptions == null
        ? const <TrackQualityChoice>[]
        : buildTrackQualityChoices(
            options: ownOptions,
            currentId: currentId,
            currentLabel: history?.quality,
            track: track,
            service: history?.service ?? request?.service ?? 'tidal',
          );
    final declared = own.where((c) => c.current).firstOrNull;
    final facts = widget.metadata.verifiedAudioMetadata;
    final fileFacts = widget.metadata.metadata;
    final codec =
        (facts['audio_codec'] ??
                fileFacts?['format'] ??
                fileFacts?['audio_codec'])
            ?.toString();
    final hasText = text != null && text.isNotEmpty;
    final hasCodec = codec != null && codec.trim().isNotEmpty;
    if (!hasText && declared == null && !hasCodec) {
      return _fading('none', const SizedBox.shrink());
    }
    final label = hasText
        ? text
        : declared != null
        ? declared.label
        : codec!.trim().toUpperCase();
    int? number(Object? v) => v is num && v > 0 ? v.toInt() : null;
    final sampleRate = number(
      facts['sample_rate'] ?? fileFacts?['sample_rate'],
    );
    final bitDepth = number(fileFacts?['bit_depth']);
    final bitrate = number(fileFacts?['bitrate']);
    final labelMark = qualityMarkFor('', label);
    final dolbyVerified = hasCodec
        ? isDolbyCodec(codec)
        : isDolbyCodec(currentId ?? '');
    var declaredMark = isDolbyMark(labelMark)
        ? labelMark
        : declared?.mark ?? labelMark;
    if (isDolbyMark(declaredMark) && !dolbyVerified) {
      if (!hasCodec) return _fading('none', const SizedBox.shrink());
      declaredMark = qualityMarkFor('', codec);
      if (isDolbyMark(declaredMark)) {
        return _fading('none', const SizedBox.shrink());
      }
    }
    final mark = verifiedQualityMark(
      declared: declaredMark,
      codec: codec,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
    final detail =
        qualityDetailFor(
          '',
          '',
          sampleRate: sampleRate,
          bitDepth: bitDepth,
          bitrateKbps: bitrate,
        ) ??
        (mark == declaredMark ? declared?.detail : null);
    final ruledOut = <String>[];
    final allChoices = track == null
        ? const <TrackQualityChoice>[]
        : mergeProviderQualityChoices(
            _providers(),
            track: track,
            currentService: history?.service ?? request?.service,
            currentId: currentId,
            currentLabel: history?.quality,
            currentMark: mark,
            currentDetail: detail,
            keepProviderTwins: true,
            onRuledOut: (service, id) => ruledOut.add('$service/$id'),
          );
    final choices = allChoices;
    final providerCount = _providers().length;
    _logSelector(origin, track, providerCount, choices, ruledOut, kind ?? 'other');
    final requestedId = catalog == null
        ? null
        : (catalogPlayback.qualityOverrideFor(catalog) ??
              catalogPlayback.quality);
    final requestedChoice = requestedId == null || requestedId.trim().isEmpty
        ? null
        : qualityMarkFor(requestedId, requestedId);
    final requestedNote =
        history == null &&
            requestedChoice != null &&
            qualityRequestDiffers(requestedChoice, mark)
        ? context.l10n.qualityPickerRequestedUnavailable(
            qualityMarkText(context, requestedChoice).name,
          )
        : null;
    _shownMark = mark;
    _shownDetail = detail;
    final selector = ValueListenableBuilder<double?>(
      valueListenable: _progress,
      builder: (context, progress, _) => TrackQualitySelector(
        currentFormat: qualityFormatForMark(mark),
        currentMark: mark,
        currentDetail: detail,
        pendingMark: _pendingMark,
        pendingDetail: _pendingDetail,
        progress: progress,
        currentLabel: label,
        choices: choices,
        noOffersNote: replacesFile && providerCount == 0
            ? context.l10n.qualityPickerNoProviders
            : null,
        switching: _switching,
        replacesFile: replacesFile,
        colorScheme: widget.colorScheme,
        lockup: true,
        compactLockup: true,
        capsule: true,
        height: widget.slim ? 26 : 30,
        badgeSize: widget.slim ? 15 : 17,
        onShowInfo: _showInfo,
        trackKey: track == null ? null : trackCollectionKey(track),
        onCancelSwitch: _switchCancellable ? _cancelSwitch : null,
        requestedNote: requestedNote,
        onCurrentTapped: () => _tell(context.l10n.qualityPickerAlreadyPlaying),
        onSelected: (choice) {
          final target = track;
          if (target == null) return;
          if (_switching) {
            _tell(context.l10n.qualityPickerSwitching);
            return;
          }
          if (qualityChoiceMatchesPlaying(choice, mark: mark, detail: detail)) {
            _tell(context.l10n.qualityPickerAlreadyPlaying);
            return;
          }
          _playingMark = mark;
          _playingDetail = detail;
          if (history != null) {
            _replaceDownload(
              target,
              choice,
              previous: history.filePath,
              historyId: history.id,
              service: history.service,
            );
          } else if (replacesFile && source != null) {
            _replaceDownload(target, choice, previous: source);
          } else {
            _switchStreaming(target, choice);
          }
        },
      ),
    );
    return _fading(
      'ready',
      Wrap(
        alignment: widget.slim ? WrapAlignment.center : WrapAlignment.start,
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          selector,
          if (track != null && widget.inlineVideo)
            TrackVideoGate(
              track: track,
              lookup: _lookup,
              active:
                  ref.watch(playerVideoModeProvider) != null &&
                  videoSession.activeKey == trackCollectionKey(track),
              loading: videoSession.loadingFor(trackCollectionKey(track)),
              colorScheme: widget.colorScheme,
              onPressed: (tag) =>
                  _pressVideo(track, tag, history?.filePath, currentId),
            ),
        ],
      ),
    );
  }
}
