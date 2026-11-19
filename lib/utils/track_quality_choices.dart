import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/quality_mark.dart';

enum QualityBadgeFormat { spatial, hiRes, max, lossless, flac, aac, lossy }

const _spatialWords = ['atmos', 'eac3', 'ac4', 'spatial'];

QualityBadgeFormat qualityBadgeFormatFor(
  String id, [
  String label = '',
  String kind = '',
]) {
  final text = '$id $label'.toLowerCase();
  if (kind.trim().toLowerCase() == 'spatial' ||
      _spatialWords.any(text.contains)) {
    return QualityBadgeFormat.spatial;
  }
  if (RegExp(r'hi[-_ ]?res|(^|\D)(24|32)\s*[-_]?\s*bit').hasMatch(text)) {
    return QualityBadgeFormat.hiRes;
  }
  if (RegExp(r'(^|[^a-z])max([^a-z]|$)').hasMatch(text)) {
    return QualityBadgeFormat.max;
  }
  if (text.contains('flac')) return QualityBadgeFormat.flac;
  if (RegExp(r'aac|m4a|he-?aac').hasMatch(text)) return QualityBadgeFormat.aac;
  final resolved = kind.trim().isEmpty ? inferQualityKind(id, label) : kind;
  if (resolved.trim().toLowerCase() == 'lossless') {
    return QualityBadgeFormat.lossless;
  }
  return QualityBadgeFormat.lossy;
}

class QualityCandidate {
  const QualityCandidate(this.service, this.id);

  final String service;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is QualityCandidate &&
      other.service.trim().toLowerCase() == service.trim().toLowerCase() &&
      other.id.trim().toLowerCase() == id.trim().toLowerCase();

  @override
  int get hashCode =>
      Object.hash(service.trim().toLowerCase(), id.trim().toLowerCase());

  @override
  String toString() => '$service/$id';
}

class TrackQualityChoice {
  const TrackQualityChoice({
    required this.id,
    required this.label,
    required this.format,
    required this.kind,
    this.description,
    this.current = false,
    this.available = true,
    this.checking = false,
    this.failedLast = false,
    this.markOverride,
    this.detail,
    this.service,
    this.tag,
    this.candidates = const [],
  });

  final String id;
  final String label;
  final QualityBadgeFormat format;
  final String kind;
  final String? description;
  final bool current;
  final bool available;
  final bool checking;

  /// The last attempt to switch to this format failed. It only informs: the
  /// format stays offered and can be asked for again.
  final bool failedLast;
  final QualityMark? markOverride;
  final String? detail;
  final String? service;
  final String? tag;

  /// Providers that offer this format, in priority order, each with the id it
  /// answers to. The first is the one asked first; the rest take over when it
  /// does not give the format.
  final List<QualityCandidate> candidates;

  QualityMark get mark => markOverride ?? qualityMarkForFormat(format);

  String? get spatialCodec => spatialCodecLabelFor(mark, id, label);

  TrackQualityChoice copyWith({
    bool? current,
    String? detail,
    String? tag,
    bool? checking,
    bool? failedLast,
    List<QualityCandidate>? candidates,
  }) => TrackQualityChoice(
    id: id,
    label: label,
    format: format,
    kind: kind,
    description: description,
    current: current ?? this.current,
    available: available,
    checking: checking ?? this.checking,
    failedLast: failedLast ?? this.failedLast,
    markOverride: markOverride,
    detail: detail ?? this.detail,
    service: service,
    tag: tag ?? this.tag,
    candidates: candidates ?? this.candidates,
  );
}

QualityMark qualityMarkForFormat(QualityBadgeFormat format) => switch (format) {
  QualityBadgeFormat.spatial => QualityMark.atmos,
  QualityBadgeFormat.hiRes => QualityMark.hiRes,
  QualityBadgeFormat.max => QualityMark.max,
  QualityBadgeFormat.lossless => QualityMark.lossless,
  QualityBadgeFormat.flac => QualityMark.flac,
  QualityBadgeFormat.aac => QualityMark.aac,
  QualityBadgeFormat.lossy => QualityMark.lossy,
};

QualityBadgeFormat qualityFormatForMark(QualityMark mark) => switch (mark) {
  QualityMark.atmos || QualityMark.dolbyPlus => QualityBadgeFormat.spatial,
  QualityMark.hiRes => QualityBadgeFormat.hiRes,
  QualityMark.max => QualityBadgeFormat.max,
  QualityMark.lossless ||
  QualityMark.alac ||
  QualityMark.wav ||
  QualityMark.aiff ||
  QualityMark.ape ||
  QualityMark.dsd => QualityBadgeFormat.lossless,
  QualityMark.flac => QualityBadgeFormat.flac,
  QualityMark.aac || QualityMark.m4a => QualityBadgeFormat.aac,
  _ => QualityBadgeFormat.lossy,
};

bool _tidalService(String? service) =>
    (service ?? '').toLowerCase().contains('tidal');

({QualityMark mark, String detail})? _impliedLossyProfile(
  String? service,
  QualityOption option,
) {
  if (!_tidalService(service)) return null;
  return switch (option.id.trim().toUpperCase()) {
    'HIGH' => (mark: QualityMark.aac, detail: '320 kbps'),
    'LOW' => (mark: QualityMark.aac, detail: '96 kbps'),
    _ => null,
  };
}

/// Fills the kind of options whose manifest does not declare one, using the
/// provider's fallback tier for the generic ids ("best", "default").
List<QualityOption> withDeclaredQualityKinds(
  Iterable<QualityOption> options, {
  String? fallbackTier,
}) {
  final tier = fallbackTier?.trim().toLowerCase() ?? '';
  final fallbackKind = switch (tier) {
    'low_res' => 'lossy',
    'lossless' || 'hi_res' => 'lossless',
    _ => '',
  };
  return [
    for (final option in options)
      if (option.kind.trim().isEmpty &&
          fallbackKind.isNotEmpty &&
          const {
            'best',
            'default',
            '',
          }.contains(option.id.trim().toLowerCase()))
        QualityOption(
          id: option.id,
          label: option.label,
          description: option.description,
          settingsCount: option.settingsCount,
          kind: fallbackKind,
        )
      else
        option,
  ];
}

/// Whether the song's own catalog data rules out [format]. Spatial audio is
/// offered only once it is confirmed for the song and provider (declared by
/// the catalog, found by a lookup, or already played); while a lookup runs it
/// is not ruled out but shown as checking. A lookup that finished without
/// confirming it rules it out; one that could not run (no network, provider
/// resting) leaves it offered on request, unconfirmed. On Tidal the declared audio quality
/// is the ceiling for lossless and Hi-Res. Missing data rules out nothing
/// else. A failed attempt to switch never rules a format out.
bool qualityRuledOutForTrack(
  QualityBadgeFormat format,
  Track? track, {
  String? service,
  SpecialQualityAvailability? availability,
  bool spatialOnRequest = false,
}) {
  if (track == null) return false;
  if (format == QualityBadgeFormat.spatial) {
    final status = (availability ?? SpecialQualityAvailability.instance)
        .atmosStatus(track, service);
    if (spatialOnRequest &&
        atmosCapableProviders.contains(
          normalizeAvailabilityProvider(service),
        )) {
      return status == SpecialQualityStatus.unavailable;
    }
    return status != SpecialQualityStatus.confirmed &&
        status != SpecialQualityStatus.checking;
  }
  if (!_tidalService(service)) return false;
  final declared = track.audioQuality?.trim().toUpperCase() ?? '';
  if (declared.isEmpty) return false;
  final hiRes = declared.contains('HI_RES') || declared.contains('HIRES');
  if (format == QualityBadgeFormat.hiRes || format == QualityBadgeFormat.max) {
    return !hiRes;
  }
  if (format == QualityBadgeFormat.lossless ||
      format == QualityBadgeFormat.flac) {
    return !hiRes && !declared.contains('LOSSLESS');
  }
  return false;
}

/// Quality catalog of one provider shaped for one song. The provider's
/// manifest is a fixed list, so each option is checked against what the
/// song's own catalog data declares and left out when that rules it out.
List<TrackQualityChoice> buildTrackQualityChoices({
  required Iterable<QualityOption> options,
  String? currentId,
  String? currentLabel,
  Track? track,
  String? service,
  SpecialQualityAvailability? availability,
  bool spatialOnRequest = false,
}) {
  final registry = availability ?? SpecialQualityAvailability.instance;
  final distinct = distinctDownloadQualityOptions(options).toList();
  final active = currentId == null || currentId.trim().isEmpty
      ? null
      : findDownloadQualityOption(distinct, currentId);
  final byLabel = active != null || currentLabel == null
      ? null
      : distinct
            .where(
              (o) =>
                  o.label.trim().toLowerCase() ==
                  currentLabel.trim().toLowerCase(),
            )
            .firstOrNull;
  final current = active ?? byLabel;
  return [
    for (final option in distinct)
      () {
        final kind = option.kind.trim().isEmpty
            ? inferQualityKind(option.id, option.label)
            : option.kind.trim().toLowerCase();
        var format = qualityBadgeFormatFor(option.id, option.label, kind);
        var mark = qualityMarkFor(option.id, option.label, kind);
        var detail = qualityDetailFor(
          option.id,
          option.label,
          lossy: isLossyMark(mark),
        );
        final implied = mark == QualityMark.lossy && detail == null
            ? _impliedLossyProfile(service, option)
            : null;
        if (implied != null) {
          mark = implied.mark;
          detail = implied.detail;
          format = qualityFormatForMark(mark);
        }
        final isCurrent = identical(option, current);
        final spatialStatus = format == QualityBadgeFormat.spatial
            ? registry.atmosStatus(track, service)
            : null;
        final checking =
            track != null &&
            !isCurrent &&
            spatialStatus == SpecialQualityStatus.checking;
        final ruledOut =
            !isCurrent &&
            !checking &&
            qualityRuledOutForTrack(
              format,
              track,
              service: service,
              availability: registry,
              spatialOnRequest: spatialOnRequest,
            );
        return TrackQualityChoice(
          markOverride: mark,
          detail: detail,
          id: option.id,
          label: option.label.trim().isEmpty ? option.id : option.label.trim(),
          format: format,
          kind: kind,
          description: option.description?.trim().isEmpty ?? true
              ? null
              : option.description!.trim(),
          current: isCurrent,
          available: !ruledOut,
          checking: checking,
          failedLast:
              !isCurrent && registry.attemptFailed(track, service, option.id),
        );
      }(),
  ];
}

List<QualityCandidate> _withCandidate(
  List<QualityCandidate> list,
  QualityCandidate next,
) => list.contains(next) ? list : [...list, next];

bool _sameMark(QualityMark a, QualityMark b) =>
    a == b ||
    ((a == QualityMark.hiRes || a == QualityMark.max) &&
        (b == QualityMark.hiRes || b == QualityMark.max));

class _Merged {
  _Merged(this.choice, this.rank, this.current);

  TrackQualityChoice choice;
  final int rank;
  bool current;
}

const _serviceNames = {
  'tidal': 'Tidal',
  'ytmusic': 'YouTube Music',
  'youtube': 'YouTube',
  'soundcloud': 'SoundCloud',
  'amzn': 'Amazon Music',
  'amazon': 'Amazon Music',
  'jiosaavn': 'JioSaavn',
  'qobuz': 'Qobuz',
  'deezer': 'Deezer',
  'beatport': 'Beatport',
  'apple': 'Apple Music',
  'spotify': 'Spotify',
  'bugs': 'Bugs',
  'melon': 'Melon',
  'genie': 'Genie',
};

String qualityServiceShortName(String? service) {
  final first = (service ?? '')
      .trim()
      .split(RegExp(r'[-_.\s]'))
      .where((part) => part.isNotEmpty)
      .firstOrNull;
  if (first == null) return '';
  return _serviceNames[first.toLowerCase()] ??
      first[0].toUpperCase() + first.substring(1).toLowerCase();
}

bool _sameService(String? a, String? b) =>
    (a ?? '').trim().toLowerCase() == (b ?? '').trim().toLowerCase();

bool _detailsCompatible(String? option, String? playing) {
  if (option == null || playing == null) return false;
  return option == playing ||
      playing.startsWith('$option /') ||
      option.startsWith('$playing /');
}

/// Whether [choice] is declared to give the file that already plays: same
/// mark and the same measured detail (bits and rate, or bitrate).
bool qualityChoiceMatchesPlaying(
  TrackQualityChoice choice, {
  required QualityMark? mark,
  required String? detail,
}) =>
    mark != null &&
    choice.mark == mark &&
    choice.detail != null &&
    choice.detail == detail;

/// Whether what was asked for is a different format from the file that
/// plays: lossy against lossless, or two different lossy codecs.
bool qualityRequestDiffers(QualityMark requested, QualityMark actual) {
  if (requested == QualityMark.lossy || requested == actual) return false;
  if (isLossyMark(requested) != isLossyMark(actual)) return true;
  return isLossyMark(requested) && requested != actual;
}

/// Every quality the song offers across providers. The providers arrive in
/// priority order. Options with the same mark and the same properties are one
/// entry, kept from the first provider that offers it; an option that declares
/// no properties folds into a same-mark option that does. Options that stay
/// alike get the provider's short name as a tag. Unavailable entries are left
/// out. With [keepProviderTwins] an option another provider also offers is
/// kept under each provider, so the user picks the provider as well as the
/// format. [onRuledOut] hears each option the song's catalog data rules out.
List<TrackQualityChoice> mergeProviderQualityChoices(
  Iterable<({String service, Iterable<QualityOption> options})> providers, {
  Track? track,
  String? currentService,
  String? currentId,
  String? currentLabel,
  QualityMark? currentMark,
  String? currentDetail,
  SpecialQualityAvailability? availability,
  bool keepProviderTwins = false,
  void Function(String service, String id)? onRuledOut,
}) {
  final entries = <_Merged>[];
  var rank = -1;
  for (final provider in providers) {
    rank++;
    final isCurrent =
        currentService != null &&
        _sameService(provider.service, currentService);
    final choices = buildTrackQualityChoices(
      options: provider.options,
      currentId: isCurrent ? currentId : null,
      currentLabel: isCurrent ? currentLabel : null,
      track: track,
      service: provider.service,
      availability: availability,
      spatialOnRequest: true,
    );
    for (final choice in choices) {
      if (!choice.available) {
        onRuledOut?.call(provider.service, choice.id);
        continue;
      }
      final unproven =
          choice.detail == null && choice.mark == QualityMark.lossy;
      final twin = unproven
          ? null
          : entries
                .where(
                  (e) =>
                      _sameMark(e.choice.mark, choice.mark) &&
                      e.choice.detail == choice.detail &&
                      e.choice.spatialCodec == choice.spatialCodec &&
                      (!keepProviderTwins ||
                          _sameService(e.choice.service, provider.service)) &&
                      !(choice.detail == null &&
                          isLossyMark(choice.mark) &&
                          _sameService(e.choice.service, provider.service) &&
                          e.choice.id.toLowerCase() != choice.id.toLowerCase()),
                )
                .firstOrNull;
      if (twin != null) {
        twin.current = twin.current || choice.current;
        twin.choice = twin.choice.copyWith(
          candidates: _withCandidate(
            twin.choice.candidates,
            QualityCandidate(provider.service, choice.id),
          ),
        );
        if (twin.choice.checking && !choice.checking) {
          twin.choice = twin.choice.copyWith(checking: false);
        }
        continue;
      }
      entries.add(
        _Merged(
          TrackQualityChoice(
            id: choice.id,
            label: choice.label,
            format: choice.format,
            kind: choice.kind,
            description: choice.description,
            markOverride: choice.mark,
            detail: choice.detail,
            service: provider.service,
            checking: choice.checking,
            failedLast: choice.failedLast,
            candidates: [QualityCandidate(provider.service, choice.id)],
          ),
          rank,
          choice.current,
        ),
      );
    }
  }
  for (final bare in [
    for (final e in entries)
      if (e.choice.detail == null && e.choice.mark != QualityMark.lossy) e,
  ]) {
    final known = entries
        .where(
          (e) =>
              _sameMark(e.choice.mark, bare.choice.mark) &&
              e.choice.detail != null &&
              (!keepProviderTwins ||
                  _sameService(e.choice.service, bare.choice.service)),
        )
        .toList();
    if (known.isEmpty) continue;
    final target = known.reduce((a, b) => b.rank < a.rank ? b : a);
    entries.remove(bare);
    if (bare.rank <= target.rank) {
      final at = entries.indexOf(target);
      entries[at] = _Merged(
        bare.choice.copyWith(
          detail: target.choice.detail,
          candidates: [
            ...bare.choice.candidates,
            for (final c in target.choice.candidates)
              if (!bare.choice.candidates.contains(c)) c,
          ],
        ),
        bare.rank,
        bare.current || target.current,
      );
    } else {
      target.current = target.current || bare.current;
      target.choice = target.choice.copyWith(
        candidates: [
          ...target.choice.candidates,
          for (final c in bare.choice.candidates)
            if (!target.choice.candidates.contains(c)) c,
        ],
      );
    }
  }
  if (currentMark != null &&
      entries.any((e) => e.current) &&
      !entries.any((e) => e.current && _sameMark(e.choice.mark, currentMark))) {
    for (final e in entries) {
      e.current = false;
    }
  }
  if (currentMark != null && currentDetail != null) {
    final held = entries.where((e) => e.current).toList();
    final betterFit = entries.where(
      (e) =>
          _sameMark(e.choice.mark, currentMark) &&
          e.choice.detail != null &&
          _detailsCompatible(e.choice.detail, currentDetail),
    );
    if (held.isNotEmpty &&
        betterFit.isNotEmpty &&
        held.every(
          (e) =>
              e.choice.detail != null &&
              !_detailsCompatible(e.choice.detail, currentDetail),
        )) {
      for (final e in held) {
        e.current = false;
      }
    }
  }
  final playing = currentService == null || currentId == null
      ? null
      : QualityCandidate(currentService, currentId);
  if (!entries.any((e) => e.current) && currentMark != null) {
    final sameMark = entries
        .where((e) => _sameMark(e.choice.mark, currentMark))
        .toList();
    _Merged? pick(bool Function(_Merged) test) =>
        sameMark.where(test).firstOrNull;
    final chosen =
        (currentDetail == null
            ? null
            : pick((e) => e.choice.detail == currentDetail)) ??
        pick((e) => _detailsCompatible(e.choice.detail, currentDetail)) ??
        pick((e) => playing != null && e.choice.candidates.contains(playing)) ??
        sameMark.firstOrNull;
    if (chosen != null) chosen.current = true;
  }
  final marked = entries.where((e) => e.current).toList();
  if (marked.length > 1) {
    final keep =
        marked
            .where((e) => e.choice.candidates.contains(playing))
            .firstOrNull ??
        marked.reduce((a, b) => b.rank < a.rank ? b : a);
    for (final e in marked) {
      e.current = identical(e, keep);
    }
  }
  final byDisplay = <String, List<_Merged>>{};
  for (final e in entries) {
    byDisplay
        .putIfAbsent(
          '${e.choice.mark.name}|${e.choice.detail}|${e.choice.spatialCodec}',
          () => [],
        )
        .add(e);
  }
  for (final group in byDisplay.values) {
    if (group.length < 2) continue;
    for (final e in group) {
      final short = qualityServiceShortName(e.choice.service);
      final alike = group.where(
        (o) => qualityServiceShortName(o.choice.service) == short,
      );
      final tag = alike.length > 1 ? '$short · ${e.choice.id}' : short;
      e.choice = e.choice.copyWith(tag: tag.isEmpty ? e.choice.id : tag);
    }
  }
  final position = {for (final e in entries.indexed) e.$2: e.$1};
  final sorted = [...entries]
    ..sort((a, b) {
      final byMark = qualityMarkOrder(
        a.choice.mark,
      ).compareTo(qualityMarkOrder(b.choice.mark));
      if (byMark != 0) return byMark;
      final byRate = (bitrateOfDetail(b.choice.detail) ?? 0).compareTo(
        bitrateOfDetail(a.choice.detail) ?? 0,
      );
      if (byRate != 0) return byRate;
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : position[a]!.compareTo(position[b]!);
    });
  return [for (final e in sorted) e.choice.copyWith(current: e.current)];
}
