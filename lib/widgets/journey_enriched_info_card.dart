import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:mornye/services/journey_credit_artwork_lookup.dart';
import 'package:mornye/services/journey_credit_lookup.dart';
import 'package:mornye/widgets/player_track_info_card.dart';

/// Additional, conservatively matched information. Existing tags take priority.
class JourneyEnrichment {
  const JourneyEnrichment({
    this.labels = const [],
    this.producers = const [],
    this.labelImages = const {},
    this.artistImages = const {},
    this.producerImages = const {},
    this.artistIds = const {},
    this.labelIds = const {},
    this.producerIds = const {},
  });

  final List<String> labels;
  final List<String> producers;
  final Map<String, JourneyIdentityArtwork> labelImages;
  final Map<String, JourneyIdentityArtwork> artistImages;
  final Map<String, JourneyIdentityArtwork> producerImages;
  final Map<String, String> artistIds;
  final Map<String, String> labelIds;
  final Map<String, String> producerIds;
}

typedef JourneyEnrichmentLoader =
    Future<JourneyEnrichment> Function(MediaItem item, TrackInfoFacts facts);

Future<JourneyEnrichment> _defaultLookup(
  MediaItem item,
  TrackInfoFacts facts,
) async {
  final isrc = facts.isrc;
  if (isrc == null || isrc.isEmpty || facts.artists.isEmpty) {
    return const JourneyEnrichment();
  }
  final result = await JourneyCreditLookup.shared.lookup(
    isrc: isrc,
    album: item.album,
    artists: facts.artists,
  );
  return JourneyEnrichment(
    labels: result.labels,
    producers: result.producers,
    artistIds: result.artistIds,
    labelIds: result.labelIds,
    producerIds: result.producerIds,
  );
}

/// Keeps asynchronous credits tied to the item that requested them.
class JourneyEnrichedInfoCard extends StatefulWidget {
  const JourneyEnrichedInfoCard({
    super.key,
    required this.item,
    required this.facts,
    this.loader,
  });

  final MediaItem item;
  final TrackInfoFacts facts;
  final JourneyEnrichmentLoader? loader;

  @override
  State<JourneyEnrichedInfoCard> createState() =>
      _JourneyEnrichedInfoCardState();
}

class _JourneyEnrichedInfoCardState extends State<JourneyEnrichedInfoCard> {
  JourneyEnrichment _enrichment = const JourneyEnrichment();
  int _generation = 0;

  String _identity(JourneyEnrichedInfoCard value) => jsonEncode([
    value.item.id,
    value.item.extras?['source']?.toString(),
    value.item.album,
    value.facts.isrc,
    value.facts.artists,
  ]);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant JourneyEnrichedInfoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_identity(oldWidget) != _identity(widget) ||
        oldWidget.loader != widget.loader) {
      _enrichment = const JourneyEnrichment();
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    final loader = widget.loader ?? _defaultLookup;
    Future<JourneyEnrichment>.sync(() => loader(widget.item, widget.facts))
        .then((value) {
          if (!mounted || generation != _generation) return;
          setState(() => _enrichment = value);
          if (widget.loader == null) unawaited(_loadArtwork(value, generation));
        })
        .catchError((_) {
          // Metadata is optional; preserve the original visible facts.
        });
  }

  Future<void> _loadArtwork(JourneyEnrichment value, int generation) async {
    if (value.artistIds.isEmpty &&
        value.labelIds.isEmpty &&
        value.producerIds.isEmpty) {
      return;
    }
    try {
      final result = await JourneyCreditArtworkLookup.shared.lookup(
        artistIds: value.artistIds,
        labelIds: value.labelIds,
        producerIds: value.producerIds,
      );
      if (!mounted || generation != _generation) return;
      Map<String, JourneyIdentityArtwork> convert(
        Map<String, JourneyCreditArtwork> input,
      ) => {
        for (final entry in input.entries)
          entry.key: JourneyIdentityArtwork(
            url: entry.value.imageUrl.toString(),
            attribution: entry.value.author,
            license: entry.value.license,
            sourceUrl: entry.value.sourcePage.toString(),
            licenseUrl: entry.value.licenseUrl?.toString(),
          ),
      };
      setState(() {
        _enrichment = JourneyEnrichment(
          labels: value.labels,
          producers: value.producers,
          labelImages: convert(result.labels),
          artistImages: convert(result.artists),
          producerImages: convert(result.producers),
          artistIds: value.artistIds,
          labelIds: value.labelIds,
          producerIds: value.producerIds,
        );
      });
    } catch (_) {
      // Images are optional; text credits remain visible if lookup fails.
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts;
    final credits = [...facts.credits];
    final known = credits
        .where((entry) => entry.$1 == TrackCreditRole.producer)
        .map((entry) => entry.$2.trim().toLowerCase())
        .toSet();
    for (final producer in _enrichment.producers) {
      final name = producer.trim();
      if (name.isNotEmpty && known.add(name.toLowerCase())) {
        credits.add((TrackCreditRole.producer, name));
      }
    }
    final labels = facts.labels.isEmpty ? _enrichment.labels : facts.labels;
    return PlayerTrackInfoCard(
      facts: facts.copyWith(
        labels: labels,
        credits: credits,
        labelImages: {..._enrichment.labelImages, ...facts.labelImages},
        artistImages: {..._enrichment.artistImages, ...facts.artistImages},
        producerImages: {
          ..._enrichment.producerImages,
          ...facts.producerImages,
        },
      ),
    );
  }
}
