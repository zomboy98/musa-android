import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/track_quality_choices.dart'
    show withDeclaredQualityKinds;

/// Stable id of the default streaming mode: ask the provider for its light
/// (lossy AAC/Opus/m4a) format so playback starts quickly.
const autoLightStreamingQuality = 'auto_light';

/// What to request for one streaming playback. It never changes the saved
/// settings.
class StreamingRequest {
  const StreamingRequest(this.serviceId, this.qualityId, {this.slower = false});

  final String serviceId;
  final String qualityId;

  /// True when the request is heavy (lossless/spatial or >= 320 kbps), so
  /// playback may take longer to start.
  final bool slower;

  @override
  bool operator ==(Object other) =>
      other is StreamingRequest &&
      other.serviceId == serviceId &&
      other.qualityId == qualityId &&
      other.slower == slower;

  @override
  int get hashCode => Object.hash(serviceId, qualityId, slower);

  @override
  String toString() => 'StreamingRequest($serviceId, $qualityId, $slower)';
}

String _kind(QualityOption option) => option.kind.trim().toLowerCase();

/// [extension] with the kind of its generic quality ids ("best", "default")
/// filled in from its declared `downloadFallbackTier`, so a provider whose
/// only option is "best" with tier `low_res` is lossy and not lossless.
Extension withDeclaredExtensionKinds(Extension extension) {
  final options = withDeclaredQualityKinds(
    extension.qualityOptions,
    fallbackTier: extension.capabilities['downloadFallbackTier']?.toString(),
  );
  for (var i = 0; i < options.length; i++) {
    if (!identical(options[i], extension.qualityOptions[i])) {
      return extension.copyWith(qualityOptions: options);
    }
  }
  return extension;
}

final _bitrateToken = RegExp(r'(?<![\d.])(\d{2,3})\s*(?:k|kbps|kb/s)?(?![\d])');

/// Bitrate in kbps inferred from the id or label ("AAC_320", "AAC 160 kbps"),
/// or null when none is written.
int? inferBitrateKbps(QualityOption option) {
  for (final text in [option.id, option.label]) {
    for (final match in _bitrateToken.allMatches(text)) {
      final value = int.parse(match[1]!);
      if (value >= 32 && value <= 512) return value;
    }
  }
  return null;
}

bool _isMp3(QualityOption option) =>
    '${option.id} ${option.label}'.toLowerCase().contains('mp3');

/// Light (lossy) option to stream: AAC/Opus/m4a before mp3, then the lightest
/// bitrate that is still >= 128 kbps (else the highest below it). When no
/// bitrate can be read, the first lossy option of the manifest.
QualityOption? lightestLossyOption(List<QualityOption> options) {
  var lossy = options.where((o) => _kind(o) == 'lossy').toList();
  if (lossy.isEmpty) return null;
  final withoutMp3 = lossy.where((o) => !_isMp3(o)).toList();
  if (withoutMp3.isNotEmpty) lossy = withoutMp3;
  final known = [
    for (final o in lossy)
      if (inferBitrateKbps(o) case final rate?) (o, rate),
  ];
  if (known.isEmpty) return lossy.first;
  final enough = known.where((e) => e.$2 >= 128).toList();
  if (enough.isNotEmpty) {
    var best = enough.first;
    for (final entry in enough.skip(1)) {
      if (entry.$2 < best.$2) best = entry;
    }
    return best.$1;
  }
  var best = known.first;
  for (final entry in known.skip(1)) {
    if (entry.$2 > best.$2) best = entry;
  }
  return best.$1;
}

/// Weight used to pick the lightest option when nothing is lossy.
int _weight(QualityOption option) {
  final kind = _kind(option);
  final base = kind == 'lossy' ? 0 : (kind == 'spatial' ? 2 : 1);
  return base * 1000 + (inferBitrateKbps(option) ?? 0);
}

bool _isSlow(String id, String label, String kind) {
  if (kind == 'lossless' || kind == 'spatial') return true;
  if (kind == 'lossy') {
    final rate = inferBitrateKbps(QualityOption(id: id, label: label));
    // "HIGH" tiers are 320 kbps even when the number is not written.
    return (rate != null && rate >= 320) ||
        '$id $label'.toLowerCase().contains('high');
  }
  // Older manifests without a kind: judge by the words in the id.
  final text = '$id $label'.toLowerCase();
  const heavy = [
    'lossless',
    'hi_res',
    'hires',
    'hi-res',
    'flac',
    'alac',
    'atmos',
    'high',
    'best',
  ];
  if (heavy.any(text.contains)) return true;
  final rate = inferBitrateKbps(QualityOption(id: id, label: label));
  return rate != null && rate >= 320;
}

/// Decides provider and quality for a streaming request.
///
/// * [settingsQuality] == [autoLightStreamingQuality]: the selected provider's
///   light format; if it has none and [autoFallback] allows it, the first
///   other provider (by [providerPriority], then alphabetically) that has
///   one; if nobody has one, the lightest option of the selected provider
///   with `slower: true`.
/// * Any other value is the user's explicit choice and is kept with the
///   selected provider (Rust maps it across providers by kind).
///
/// Disabled, failing and download-less extensions are ignored.
StreamingRequest resolveStreamingRequest({
  required String settingsQuality,
  required String selectedServiceId,
  required List<Extension> extensions,
  List<String> providerPriority = const [],
  bool autoFallback = true,
}) {
  final selectedKey = selectedServiceId.trim().toLowerCase();
  final priority = <String, int>{
    for (final entry in providerPriority.indexed)
      entry.$2.trim().toLowerCase(): entry.$1,
  };
  final usable = extensions
      .where(
        (e) =>
            e.enabled &&
            e.status != 'error' &&
            e.hasDownloadProvider &&
            e.qualityOptions.isNotEmpty,
      )
      .map(withDeclaredExtensionKinds)
      .toList();
  Extension? selected;
  for (final e in usable) {
    if (e.id.trim().toLowerCase() == selectedKey) selected = e;
  }
  final others =
      [
        for (final e in usable)
          if (e != selected) e,
      ]..sort((a, b) {
        final byPriority =
            (priority[a.id.trim().toLowerCase()] ?? providerPriority.length)
                .compareTo(
                  priority[b.id.trim().toLowerCase()] ??
                      providerPriority.length,
                );
        if (byPriority != 0) return byPriority;
        final byId = a.id.toLowerCase().compareTo(b.id.toLowerCase());
        return byId != 0 ? byId : a.id.compareTo(b.id);
      });
  final requested = settingsQuality.trim();

  if (requested.isNotEmpty && requested != autoLightStreamingQuality) {
    var kind = '';
    var label = '';
    final pool = [if (selected != null) selected, ...others];
    for (final e in pool) {
      final found = findDownloadQualityOption(e.qualityOptions, requested);
      if (found != null) {
        kind = _kind(found);
        label = found.label;
        break;
      }
    }
    return StreamingRequest(
      selectedServiceId,
      requested,
      slower: _isSlow(requested, label, kind),
    );
  }

  if (selected != null) {
    final light = lightestLossyOption(selected.qualityOptions);
    if (light != null) {
      return StreamingRequest(selected.id, light.id);
    }
  }
  if (autoFallback || selected == null) {
    for (final e in others) {
      final light = lightestLossyOption(e.qualityOptions);
      if (light != null) return StreamingRequest(e.id, light.id);
    }
  }
  final pool = selected ?? (others.isEmpty ? null : others.first);
  if (pool == null) {
    return StreamingRequest(selectedServiceId, 'LOSSLESS', slower: true);
  }
  var lightest = pool.qualityOptions.first;
  for (final option in pool.qualityOptions.skip(1)) {
    if (_weight(option) < _weight(lightest)) lightest = option;
  }
  return StreamingRequest(pool.id, lightest.id, slower: true);
}

/// Kind of an id that no manifest in hand declares ("lossless", "lossy" or
/// "spatial"), judged from its words.
///
/// A generic id ("best", "default") says nothing by itself: when the
/// provider's `downloadFallbackTier` is known it decides (`low_res` is lossy,
/// `lossless` and `hi_res` are lossless).
String inferQualityKind(String id, [String label = '', String? fallbackTier]) {
  final text = '$id $label'.toLowerCase();
  const spatial = ['atmos', 'eac3', 'ac4', 'spatial'];
  if (spatial.any(text.contains)) return 'spatial';
  if (const {'best', 'default', ''}.contains(id.trim().toLowerCase())) {
    switch (fallbackTier?.trim().toLowerCase()) {
      case 'low_res':
        return 'lossy';
      case 'lossless' || 'hi_res':
        return 'lossless';
    }
  }
  const lossless = [
    'lossless',
    'hi_res',
    'hires',
    'hi-res',
    'flac',
    'alac',
    'best',
  ];
  if (lossless.any(text.contains)) return 'lossless';
  return 'lossy';
}

/// Keeps a saved streaming quality valid after the configured provider
/// changes. `auto_light` never depends on a provider. An explicit id that the
/// new provider also offers is kept; otherwise the closest equivalent of the
/// new provider is used (same kind; closest bitrate for lossy), and when there
/// is none the result is `auto_light`. Never returns an empty value.
///
/// [fallbackTier] is the new provider's `downloadFallbackTier` and
/// [savedKind] the known kind of [saved] (from the provider it came from);
/// both stop a generic "best" from being read as lossless.
String reconcilePlaybackQuality(
  String saved,
  List<QualityOption> providerOptions, {
  String? fallbackTier,
  String? savedKind,
}) {
  final newProviderOptions = withDeclaredQualityKinds(
    providerOptions,
    fallbackTier: fallbackTier,
  );
  final current = saved.trim();
  if (current.isEmpty || current == autoLightStreamingQuality) {
    return autoLightStreamingQuality;
  }
  if (findDownloadQualityOption(newProviderOptions, current) != null) {
    return current;
  }
  final declared = savedKind?.trim().toLowerCase() ?? '';
  final kind = declared.isNotEmpty ? declared : inferQualityKind(current);
  final sameKind = [
    for (final o in newProviderOptions)
      if ((_kind(o).isEmpty ? inferQualityKind(o.id, o.label) : _kind(o)) ==
          kind)
        o,
  ];
  if (sameKind.isEmpty) return autoLightStreamingQuality;
  if (kind != 'lossy') return sameKind.first.id; // manifests list best first
  final wanted = inferBitrateKbps(QualityOption(id: current, label: ''));
  if (wanted == null) return sameKind.first.id;
  QualityOption? best;
  int? bestDistance;
  for (final o in sameKind) {
    final rate = inferBitrateKbps(o);
    if (rate == null) continue;
    final distance = (rate - wanted).abs();
    if (bestDistance == null || distance < bestDistance) {
      best = o;
      bestDistance = distance;
    }
  }
  return (best ?? sameKind.first).id;
}

/// Other (provider, quality) requests to try, in order, when [first] could not
/// be prepared: a lighter format of the same provider, then every other usable
/// provider by [providerPriority], each asked for the closest equivalent of
/// the saved choice.
List<StreamingRequest> streamingRelayCandidates({
  required String settingsQuality,
  required StreamingRequest first,
  required List<Extension> extensions,
  List<String> providerPriority = const [],
}) {
  final usable = extensions
      .where(
        (e) =>
            e.enabled &&
            e.status != 'error' &&
            e.hasDownloadProvider &&
            e.qualityOptions.isNotEmpty,
      )
      .map(withDeclaredExtensionKinds)
      .toList();
  final priority = <String, int>{
    for (final entry in providerPriority.indexed)
      entry.$2.trim().toLowerCase(): entry.$1,
  };
  int rank(Extension e) =>
      priority[e.id.trim().toLowerCase()] ?? providerPriority.length;
  final firstKey = first.serviceId.trim().toLowerCase();
  final result = <StreamingRequest>[];
  final seen = <String>{'$firstKey|${first.qualityId.trim().toLowerCase()}'};
  void add(Extension e, String qualityId) {
    final key =
        '${e.id.trim().toLowerCase()}|${qualityId.trim().toLowerCase()}';
    if (qualityId.trim().isNotEmpty && seen.add(key)) {
      result.add(StreamingRequest(e.id, qualityId));
    }
  }

  final others =
      [
        for (final e in usable)
          if (e.id.trim().toLowerCase() != firstKey) e,
      ]..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0
            ? byRank
            : a.id.toLowerCase().compareTo(b.id.toLowerCase());
      });
  final requested = settingsQuality.trim();
  var requestedKind = '';
  for (final e in usable) {
    if (e.id.trim().toLowerCase() != firstKey) continue;
    final found = findDownloadQualityOption(e.qualityOptions, requested);
    if (found != null) requestedKind = _kind(found);
  }
  final explicit =
      requested.isNotEmpty && requested != autoLightStreamingQuality;
  String kindOf(QualityOption o) =>
      _kind(o).isEmpty ? inferQualityKind(o.id, o.label) : _kind(o);
  QualityOption? firstOfKind(Extension e, String kind) {
    for (final o in e.qualityOptions) {
      if (kindOf(o) == kind) return o;
    }
    return null;
  }

  if (explicit &&
      (requestedKind == 'spatial' || inferQualityKind(requested) == 'spatial')) {
    for (final e in others) {
      final spatial = firstOfKind(e, 'spatial');
      if (spatial != null) add(e, spatial.id);
    }
    for (final e in usable) {
      if (e.id.trim().toLowerCase() != firstKey) continue;
      final lossless = firstOfKind(e, 'lossless');
      if (lossless != null) add(e, lossless.id);
    }
    for (final e in others) {
      final lossless = firstOfKind(e, 'lossless');
      if (lossless != null) add(e, lossless.id);
    }
    for (final e in usable) {
      if (e.id.trim().toLowerCase() != firstKey) continue;
      final light = lightestLossyOption(e.qualityOptions);
      if (light != null) add(e, light.id);
    }
    return result;
  }

  final exactFirst = <Extension>[];
  final equivalents = <Extension>[];
  for (final e in others) {
    if (explicit &&
        findDownloadQualityOption(e.qualityOptions, requested) != null) {
      exactFirst.add(e);
    } else {
      equivalents.add(e);
    }
  }
  void sameProviderLighter() {
    for (final e in usable) {
      if (e.id.trim().toLowerCase() != firstKey) continue;
      final light = lightestLossyOption(e.qualityOptions);
      if (light != null) add(e, light.id);
    }
  }

  if (!explicit) sameProviderLighter();
  for (final e in [...exactFirst, ...equivalents]) {
    final light = lightestLossyOption(e.qualityOptions);
    final String id;
    if (requested.isEmpty || requested == autoLightStreamingQuality) {
      id = (light ?? e.qualityOptions.first).id;
    } else {
      final exact = findDownloadQualityOption(e.qualityOptions, requested);
      if (exact != null) {
        id = exact.id;
      } else {
        final mapped = reconcilePlaybackQuality(
          requested,
          e.qualityOptions,
          savedKind: requestedKind,
        );
        id = mapped == autoLightStreamingQuality
            ? (light ?? e.qualityOptions.first).id
            : mapped;
      }
    }
    add(e, id);
  }
  if (explicit) sameProviderLighter();
  return result;
}
