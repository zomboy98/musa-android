import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/genre_normalizer.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/streaming_quality_notice.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/journey_artists_list.dart'
    show splitJourneyArtists;
import 'package:mornye/widgets/settings_group.dart';
import 'package:url_launcher/url_launcher.dart';

enum TrackCreditRole { composer, lyricist, producer, engineer, lyricsProvider }

/// A verified resource, with its source credit retained alongside the image.
class JourneyIdentityArtwork {
  const JourneyIdentityArtwork({
    required this.url,
    required this.attribution,
    required this.license,
    this.sourceUrl,
    this.licenseUrl,
  });

  final String url;
  final String attribution;
  final String license;
  final String? sourceUrl;
  final String? licenseUrl;
}

class TrackInfoFacts {
  const TrackInfoFacts({
    this.labels = const [],
    this.artists = const [],
    this.labelImages = const {},
    this.artistImages = const {},
    this.producerImages = const {},
    this.copyright,
    this.releaseDate,
    this.trackNumber,
    this.totalTracks,
    this.discNumber,
    this.totalDiscs,
    this.duration,
    this.genres = const [],
    this.explicit = false,
    this.quality,
    this.isrc,
    this.bpm,
    this.musicalKey,
    this.credits = const [],
  });

  final List<String> labels;
  final List<String> artists;

  /// Actual artwork associated with this exact entity; missing art is allowed.
  final Map<String, JourneyIdentityArtwork> labelImages;
  final Map<String, JourneyIdentityArtwork> artistImages;
  final Map<String, JourneyIdentityArtwork> producerImages;
  final String? copyright;
  final String? releaseDate;
  final int? trackNumber;
  final int? totalTracks;
  final int? discNumber;
  final int? totalDiscs;
  final Duration? duration;
  final List<String> genres;
  final bool explicit;
  final String? quality;
  final String? isrc;
  final String? bpm;
  final String? musicalKey;
  final List<(TrackCreditRole, String)> credits;

  /// Replace only enriched identity fields, retaining all track facts.
  TrackInfoFacts copyWith({
    List<String>? labels,
    List<String>? artists,
    List<(TrackCreditRole, String)>? credits,
    Map<String, JourneyIdentityArtwork>? labelImages,
    Map<String, JourneyIdentityArtwork>? artistImages,
    Map<String, JourneyIdentityArtwork>? producerImages,
  }) => TrackInfoFacts(
    labels: labels ?? this.labels,
    artists: artists ?? this.artists,
    labelImages: labelImages ?? this.labelImages,
    artistImages: artistImages ?? this.artistImages,
    producerImages: producerImages ?? this.producerImages,
    copyright: copyright,
    releaseDate: releaseDate,
    trackNumber: trackNumber,
    totalTracks: totalTracks,
    discNumber: discNumber,
    totalDiscs: totalDiscs,
    duration: duration,
    genres: genres,
    explicit: explicit,
    quality: quality,
    isrc: isrc,
    bpm: bpm,
    musicalKey: musicalKey,
    credits: credits ?? this.credits,
  );

  bool get hasTrackPosition => trackNumber != null;

  bool get showsDisc =>
      discNumber != null && ((totalDiscs ?? 1) > 1 || discNumber! > 1);

  bool get isEmpty =>
      labels.isEmpty &&
      artists.isEmpty &&
      copyright == null &&
      releaseDate == null &&
      trackNumber == null &&
      !showsDisc &&
      duration == null &&
      genres.isEmpty &&
      !explicit &&
      quality == null &&
      isrc == null &&
      bpm == null &&
      musicalKey == null &&
      credits.isEmpty;
}

/// Labels in one credit such as "Rancho Humilde/Sony Music Latin".
List<String> splitRecordLabels(String raw) {
  final seen = <String>{};
  final labels = <String>[];
  for (final part in raw.split(RegExp(r'\s*(?:/|;|\|)\s*'))) {
    final label = part.trim();
    if (label.isNotEmpty && seen.add(label.toLowerCase())) labels.add(label);
  }
  return labels;
}

(int?, int?) _numberAndTotal(Object? value) {
  if (value == null) return (null, null);
  if (value is num) return (value > 0 ? value.toInt() : null, null);
  final match = RegExp(
    r'^\s*(\d+)\s*(?:/|of)?\s*(\d+)?\s*$',
  ).firstMatch(value.toString());
  if (match == null) return (null, null);
  final number = int.parse(match[1]!);
  final total = match[2] == null ? null : int.parse(match[2]!);
  return (
    number > 0 ? number : null,
    total != null && total > 0 ? total : null,
  );
}

Track? journeyCatalogTrack(MediaItem item) {
  final source = item.extras?['source'];
  if (source is! String || !source.startsWith('catalog:')) return null;
  return PlayableMedia(
    id: item.id,
    source: source,
    title: item.title,
    artist: item.artist ?? '',
  ).catalogTrack;
}

String? journeyQualityText(Map<String, dynamic> facts) {
  final rawCodec = (facts['audio_codec'] ?? facts['format'])?.toString().trim();
  final codec = rawCodec == null || rawCodec.isEmpty ? null : rawCodec;
  if (codec == null) return null;
  int? number(Object? value) =>
      value is num && value > 0 ? value.toInt() : null;
  final sampleRate = number(facts['sample_rate']);
  final bitDepth = number(facts['bit_depth']);
  final bitrate = number(facts['bitrate']);
  final declared = qualityMarkFor('', codec);
  if (isDolbyMark(declared) && !isDolbyCodec(codec)) return null;
  final mark = verifiedQualityMark(
    declared: declared,
    codec: codec,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );
  final detail = qualityDetailFor(
    '',
    '',
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    bitrateKbps: bitrate,
  );
  final name = qualityNoticeMarkName(mark);
  return detail == null ? name : '$name · $detail';
}

TrackInfoFacts buildTrackInfoFacts({
  required MediaItem item,
  required String? Function(String key) field,
  String? lyricsWriters,
  String? lyricsProvider,
  Map<String, dynamic> audioFacts = const {},
}) {
  final catalog = journeyCatalogTrack(item);
  final date = field('date') ?? field('release_date') ?? catalog?.releaseDate;
  final year = int.tryParse(
    RegExp(r'^\d{4}').firstMatch(date?.trim() ?? '')?[0] ?? '',
  );
  final (trackNo, trackTotal) = _numberAndTotal(
    field('track_number') ?? field('track') ?? catalog?.trackNumber,
  );
  final (discNo, discTotal) = _numberAndTotal(
    field('disc_number') ?? field('disc') ?? catalog?.discNumber,
  );
  final duration = item.duration;
  final bpm = field('bpm') ?? field('tempo');
  final bpmNumber = double.tryParse(bpm ?? '');
  final labelText = field('label') ?? catalog?.label;
  final copyright = field('copyright') ?? catalog?.copyright;
  final isrc = (field('isrc') ?? catalog?.isrc)?.trim().toUpperCase();
  final explicit =
      parseExplicitFlag(field('explicit')) ??
      parseExplicitFlag(item.extras?['explicit']) ??
      (catalog?.isExplicit ?? false);
  final genres = normalizeGenres([field('genre') ?? catalog?.genre]);
  String? text(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
  final credits = <(TrackCreditRole, String)>[
    if (text(field('composer') ?? catalog?.composer) case final String v)
      (TrackCreditRole.composer, v),
    if (text(field('lyricist') ?? lyricsWriters) case final String v)
      (TrackCreditRole.lyricist, v),
    if (text(field('producer')) case final String v)
      (TrackCreditRole.producer, v),
    if (text(field('engineer') ?? field('mixer')) case final String v)
      (TrackCreditRole.engineer, v),
    if (text(field('lyrics_provider') ?? lyricsProvider) case final String v)
      (TrackCreditRole.lyricsProvider, v),
  ];
  return TrackInfoFacts(
    labels: labelText == null ? const [] : splitRecordLabels(labelText),
    artists: (item.artist ?? '').trim().toLowerCase() == 'unknown artist'
        ? const []
        : splitJourneyArtists(item.artist ?? '', artistIds: catalog?.artistId),
    copyright: text(copyright),
    releaseDate: text(date),
    trackNumber: trackNo,
    totalTracks: trackTotal ?? catalog?.totalTracks,
    discNumber: discNo,
    totalDiscs: discTotal ?? catalog?.totalDiscs,
    duration: duration != null && duration > Duration.zero ? duration : null,
    genres: genres,
    explicit: explicit,
    quality: journeyQualityText(audioFacts),
    isrc: isrc == null || isrc.isEmpty ? null : isrc,
    bpm: bpmNumber == null || bpmNumber <= 0
        ? null
        : bpmNumber.roundToDouble() == bpmNumber
        ? bpmNumber.toInt().toString()
        : bpmNumber.toStringAsFixed(1),
    musicalKey: text(field('initial_key') ?? field('key')),
    credits: credits,
  );
}

String formatJourneyDate(String raw, String locale) {
  final match = RegExp(
    r'^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?(?:[T ].*)?$',
  ).firstMatch(raw.trim());
  if (match == null) return raw.trim();
  final year = int.parse(match[1]!);
  final month = match[2] == null ? null : int.parse(match[2]!);
  final day = match[3] == null ? null : int.parse(match[3]!);
  if (month == null) return '$year';
  if (month < 1 || month > 12) return raw.trim();
  try {
    if (day == null || day < 1 || day > 31) {
      return DateFormat.yMMMM(locale).format(DateTime(year, month));
    }
    return DateFormat.yMMMMd(locale).format(DateTime(year, month, day));
  } catch (_) {
    return raw.trim();
  }
}

String formatJourneyDuration(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

class _InfoCell {
  const _InfoCell({
    required this.label,
    required this.child,
    required this.semantics,
    this.wide = false,
    this.interactive = false,
  });

  final bool interactive;
  final String label;
  final Widget child;
  final String semantics;
  final bool wide;
}

/// Glass card with the facts of the playing track, two compact columns, and a
/// foldable credits section. Rows without data are never built.
class PlayerTrackInfoCard extends StatefulWidget {
  const PlayerTrackInfoCard({
    super.key,
    required this.facts,
    this.creditsExpanded = true,
  });

  final TrackInfoFacts facts;
  final bool creditsExpanded;

  @override
  State<PlayerTrackInfoCard> createState() => _PlayerTrackInfoCardState();
}

class _PlayerTrackInfoCardState extends State<PlayerTrackInfoCard> {
  static const double _gap = 16;
  late bool _creditsOpen = widget.creditsExpanded;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copyIsrc(String isrc) async {
    try {
      await Clipboard.setData(ClipboardData(text: isrc));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  String _creditLabel(TrackCreditRole role) {
    final l10n = context.l10n;
    return switch (role) {
      TrackCreditRole.composer => l10n.editMetadataFieldComposer,
      TrackCreditRole.lyricist => l10n.journeyCreditLyricist,
      TrackCreditRole.producer => l10n.journeyCreditProducer,
      TrackCreditRole.engineer => l10n.journeyCreditEngineer,
      TrackCreditRole.lyricsProvider => l10n.extensionLyricsProvider,
    };
  }

  Widget _textValue(String value, {int maxLines = 3}) => Text(
    value,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: Colors.white,
    ),
  );

  _InfoCell _text(String label, String value, {bool wide = false}) => _InfoCell(
    label: label,
    semantics: '$label: $value',
    wide: wide,
    child: _textValue(value),
  );

  List<_InfoCell> _cells(BuildContext context) {
    final l10n = context.l10n;
    final facts = widget.facts;
    final locale = Localizations.localeOf(context).toString();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final cells = <_InfoCell>[];
    if (facts.releaseDate != null) {
      final date = formatJourneyDate(facts.releaseDate!, locale);
      cells.add(_text(l10n.journeyReleaseDate, date, wide: date.length > 20));
    }
    if (facts.copyright != null) {
      cells.add(
        _text(l10n.editMetadataFieldCopyright, facts.copyright!, wide: true),
      );
    }
    if (facts.hasTrackPosition || facts.showsDisc) {
      final parts = <String>[
        if (facts.trackNumber != null)
          facts.totalTracks != null
              ? l10n.journeyTrackOfTotal(facts.trackNumber!, facts.totalTracks!)
              : l10n.journeyTrackNumber(facts.trackNumber!),
        if (facts.showsDisc) l10n.journeyDiscNumber(facts.discNumber!),
      ];
      final value = parts.join(' · ');
      cells.add(
        _text(l10n.journeyTrackPosition, value, wide: value.length > 18),
      );
    }
    if (facts.duration != null) {
      cells.add(
        _text(l10n.trackDuration, formatJourneyDuration(facts.duration!)),
      );
    }
    if (facts.genres.isNotEmpty) {
      cells.add(
        _InfoCell(
          label: l10n.editMetadataFieldGenre,
          semantics:
              '${l10n.editMetadataFieldGenre}: ${facts.genres.join(', ')}',
          wide: true,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final genre in facts.genres) _Chip(genre)],
          ),
        ),
      );
    }
    if (facts.quality != null) {
      cells.add(
        _text(
          l10n.trackAudioQuality,
          facts.quality!,
          wide: facts.quality!.length > 16,
        ),
      );
    }
    if (facts.explicit) {
      cells.add(
        _InfoCell(
          label: l10n.editMetadataFieldExplicit,
          semantics: l10n.metadataExplicitValue,
          child: const Align(
            alignment: AlignmentDirectional.centerStart,
            child: _ExplicitTag(),
          ),
        ),
      );
    }
    if (facts.bpm != null) {
      cells.add(_text(l10n.journeyBpm, facts.bpm!));
    }
    if (facts.musicalKey != null) {
      cells.add(_text(l10n.journeyKey, facts.musicalKey!));
    }
    if (facts.isrc != null) {
      final isrc = facts.isrc!;
      cells.add(
        _InfoCell(
          label: l10n.editMetadataFieldIsrc,
          semantics: '${l10n.editMetadataFieldIsrc}: $isrc',
          wide: true,
          interactive: true,
          child: Row(
            children: [
              Flexible(child: _textValue(isrc, maxLines: 1)),
              Semantics(
                liveRegion: true,
                label: _copied ? l10n.trackCopiedToClipboard : null,
                child: IconButton(
                  key: const ValueKey('journey-copy-isrc'),
                  tooltip: l10n.journeyCopyIsrc,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => _copyIsrc(isrc),
                  icon: AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: Icon(
                      _copied ? Icons.check : Icons.copy_outlined,
                      key: ValueKey(_copied),
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return cells;
  }

  Widget _grid(List<_InfoCell> cells) {
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Colors.white.withValues(alpha: .62),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth;
        final half = ((full - _gap) / 2).floorToDouble();
        return Wrap(
          spacing: _gap,
          runSpacing: 14,
          children: [
            for (final cell in cells)
              SizedBox(
                width: cell.wide ? full : half,
                child: Semantics(
                  container: true,
                  label: cell.interactive ? null : cell.semantics,
                  excludeSemantics: !cell.interactive,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cell.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                      const SizedBox(height: 2),
                      cell.child,
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _credits(BuildContext context) {
    final facts = widget.facts;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final theme = Theme.of(context);
    final title = context.l10n.journeyCredits;
    final cells = [
      for (final (role, value) in facts.credits)
        if (role != TrackCreditRole.producer)
          _text(_creditLabel(role), value, wide: true),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _creditsOpen,
          label: title,
          excludeSemantics: true,
          onTap: () => setState(() => _creditsOpen = !_creditsOpen),
          child: InkWell(
            key: const ValueKey('journey-credits-toggle'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _creditsOpen = !_creditsOpen),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _creditsOpen ? .5 : 0,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: _creditsOpen
              ? Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _grid(cells),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Uri? _httpsUrl(String? raw) {
    final uri = Uri.tryParse(raw?.trim() ?? '');
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  /// Artwork is optional; never turn an unverified name into an invented logo.
  JourneyIdentityArtwork? _imageFor(
    Map<String, JourneyIdentityArtwork> images,
    String name,
  ) {
    JourneyIdentityArtwork? value = images[name];
    if (value == null) {
      for (final entry in images.entries) {
        if (entry.key.trim().toLowerCase() == name.trim().toLowerCase()) {
          value = entry.value;
          break;
        }
      }
    }
    final license = value?.license.trim().toLowerCase() ?? '';
    final publicDomain = const {
      'public domain',
      'public domain mark',
      'cc0',
      'cc0 1.0',
      'cc0-1.0',
      'cc0 1.0 universal',
    }.contains(license);
    if (_httpsUrl(value?.url) == null ||
        _httpsUrl(value?.sourceUrl) == null ||
        license.isEmpty ||
        (!publicDomain && _httpsUrl(value?.licenseUrl) == null) ||
        ((value?.licenseUrl?.trim().isNotEmpty ?? false) &&
            _httpsUrl(value?.licenseUrl) == null) ||
        (value?.attribution.trim().isEmpty ?? true)) {
      return null;
    }
    return value;
  }

  Future<void> _openAttribution(String? raw) async {
    final uri = _httpsUrl(raw);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A browser failure must not interrupt the player's information.
    }
  }

  String _artworkCredit(JourneyIdentityArtwork image) {
    final attribution = image.attribution.trim();
    final license = image.license.trim();
    return attribution.toLowerCase().contains(license.toLowerCase())
        ? attribution
        : '$attribution · $license';
  }

  Widget _identitySection(
    String title,
    List<String> names,
    Map<String, JourneyIdentityArtwork> images,
  ) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white.withValues(alpha: .62),
            ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in names)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .055),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .10),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_imageFor(images, name)
                              case final JourneyIdentityArtwork image)
                            ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Image.network(
                                  image.url,
                                  width: 52,
                                  height: 30,
                                  cacheWidth: 208,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  name,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (_imageFor(images, name)
                                    case final JourneyIdentityArtwork image)
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _artworkCredit(image),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: Colors.white.withValues(
                                                alpha: .70,
                                              ),
                                            ),
                                      ),
                                      Wrap(
                                        spacing: 4,
                                        children: [
                                          TextButton(
                                            onPressed: () => _openAttribution(
                                              image.sourceUrl,
                                            ),
                                            child: Text(
                                              context.l10n.libraryFilterSource,
                                            ),
                                          ),
                                          if (_httpsUrl(image.licenseUrl) !=
                                              null)
                                            TextButton(
                                              onPressed: () => _openAttribution(
                                                image.licenseUrl,
                                              ),
                                              child: Text(
                                                MaterialLocalizations.of(
                                                  context,
                                                ).licensesPageTitle,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts;
    final cells = _cells(context);
    final producers = <String>[];
    final seenProducers = <String>{};
    for (final (role, value) in facts.credits) {
      if (role != TrackCreditRole.producer) continue;
      for (final name in splitRecordLabels(value)) {
        if (seenProducers.add(name.toLowerCase())) producers.add(name);
      }
    }
    final hasOtherCredits = facts.credits.any(
      (credit) => credit.$1 != TrackCreditRole.producer,
    );
    return VisionGradientCard(
      key: const ValueKey('journey-credits'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                context.l10n.trackMetadata,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
            ),
            if (facts.labels.isNotEmpty) ...[
              const SizedBox(height: 16),
              _identitySection(
                context.l10n.editMetadataFieldLabel,
                facts.labels,
                facts.labelImages,
              ),
            ],
            if (producers.isNotEmpty) ...[
              const SizedBox(height: 16),
              _identitySection(
                context.l10n.journeyCreditProducer,
                producers,
                facts.producerImages,
              ),
            ],
            if (facts.artists.isNotEmpty) ...[
              const SizedBox(height: 16),
              _identitySection(
                context.l10n.trackArtist,
                facts.artists,
                facts.artistImages,
              ),
            ],
            if (cells.isNotEmpty) ...[const SizedBox(height: 14), _grid(cells)],
            if (hasOtherCredits) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: Colors.white.withValues(alpha: .14)),
              _credits(context),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .10),
      border: Border.all(color: Colors.white.withValues(alpha: .18)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: Colors.white),
      ),
    ),
  );
}

class _ExplicitTag extends StatelessWidget {
  const _ExplicitTag();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      child: Text(
        'E',
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    ),
  );
}
