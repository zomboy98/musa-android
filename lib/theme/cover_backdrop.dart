import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:material_color_utilities/hct/hct.dart';

/// One dominant colour of a cover, in HCT, with the share of the cover's
/// weighted population it stands for.
@immutable
class CoverBackdropSample {
  const CoverBackdropSample({
    required this.hue,
    required this.chroma,
    required this.tone,
    required this.share,
  });

  final double hue;
  final double chroma;
  final double tone;

  /// Fraction of the selected samples' weight, in (0, 1]; the samples of one
  /// [CoverBackdrop] add up to 1.
  final double share;

  @override
  bool operator ==(Object other) =>
      other is CoverBackdropSample &&
      other.hue == hue &&
      other.chroma == chroma &&
      other.tone == tone &&
      other.share == share;

  @override
  int get hashCode => Object.hash(hue, chroma, tone, share);
}

/// The 1 to 3 dominant colours of a cover, weighted by population, plus how
/// colourful the whole cover is. It is the input of every cover-tinted
/// backdrop, so any cover produces a background without per-cover tuning.
@immutable
class CoverBackdrop {
  const CoverBackdrop(this.samples, {this.meanChroma = 0});

  /// Neutral backdrop for a missing, unreadable or colourless cover.
  static const neutral = CoverBackdrop(<CoverBackdropSample>[]);

  /// Dominant samples, heaviest first. Empty for [neutral].
  final List<CoverBackdropSample> samples;

  /// Population-weighted mean HCT chroma of all the cover's pixels.
  final double meanChroma;

  /// Below this mean chroma a cover reads as black and white, however
  /// saturated its small details are.
  static const double neutralMeanChroma = 10;

  /// Chroma any tint keeps on a mostly neutral cover.
  static const double neutralChromaCap = 8;

  /// Hue and chroma of nothing: the backdrop of a cover that tints nothing.
  bool get isNeutral => samples.isEmpty;

  /// Whether the cover as a whole is close to black and white.
  bool get isMostlyNeutral => samples.isEmpty || meanChroma < neutralMeanChroma;

  /// Highest chroma a stop keeps on a colourful cover.
  static const double chromaCap = 64;

  /// Share of the dominant colour's chroma every stop of a colourful cover
  /// keeps, so a gray or black zone never washes the gradient out.
  static const double _minimumChromaKeep = 0.85;

  /// Highest tone any [gradientColors] stop reaches. White text on it keeps
  /// a contrast ratio of at least 5.
  static const double maxTone = 46;

  /// [count] gradient colours for a dark surface with white text over it:
  /// the colour of each stop blends from the dominant sample toward the
  /// stop's own sample by how much of the cover that sample covers, chroma is
  /// reduced and capped so no hue shouts, and tones follow [tones] (nudged a
  /// little by the sample's own tone, never above [maxTone]).
  List<Color> gradientColors(List<double> tones) {
    final primary = samples.isEmpty ? null : samples.first;
    final neutralCover = isMostlyNeutral;
    return [
      for (var index = 0; index < tones.length; index++)
        _stopColor(
          primary,
          index < samples.length ? samples[index] : null,
          index == 0 ? 1 : _presence(index),
          tones[index],
          neutralCover,
        ),
    ];
  }

  double _presence(int index) {
    if (index >= samples.length) return 0;
    return (samples[index].share / 0.35).clamp(0.0, 1.0);
  }

  static Color _stopColor(
    CoverBackdropSample? primary,
    CoverBackdropSample? own,
    double presence,
    double baseTone,
    bool neutralCover,
  ) {
    if (primary == null) {
      return Color(Hct.from(0, 0, baseTone).toInt());
    }
    final other = own ?? primary;
    final t = own == null ? 0.0 : presence;
    final hue = _lerpHue(primary.hue, other.hue, t);
    final blended = primary.chroma + (other.chroma - primary.chroma) * t;
    final chroma = neutralCover
        ? blended
        : math.max(blended, primary.chroma * _minimumChromaKeep);
    final tone = primary.tone + (other.tone - primary.tone) * t;
    final cap = neutralCover ? neutralChromaCap : chromaCap;
    final shaped = math.min(chroma * (neutralCover ? 0.5 : 0.9), cap);
    final adjusted = (baseTone + (tone - 50) * 0.12).clamp(
      baseTone - 5,
      baseTone + 5,
    );
    return Color(
      Hct.from(hue, shaped, adjusted.clamp(14.0, maxTone).toDouble()).toInt(),
    );
  }

  static double _lerpHue(double from, double to, double t) {
    var delta = (to - from) % 360;
    if (delta > 180) delta -= 360;
    return (from + delta * t + 360) % 360;
  }

  @override
  bool operator ==(Object other) =>
      other is CoverBackdrop &&
      other.meanChroma == meanChroma &&
      listEquals(other.samples, samples);

  @override
  int get hashCode => Object.hash(meanChroma, Object.hashAll(samples));
}

/// Population weight multiplier of a colour of HCT [chroma]: from 1 for gray
/// up to 2.5 at chroma 60 and beyond. It is capped, so colourful zones beat
/// gray and beige ones of similar size but a very saturated small area can
/// never outweigh a large one.
@visibleForTesting
double coverChromaWeight(double chroma) => 1 + 1.5 * math.min(chroma, 60) / 60;

/// Smallest share of the weighted population a secondary colour needs to
/// take part in the backdrop.
const double _minimumShare = 0.10;

/// Dominant colours of straight RGBA [data] (any size), weighted by
/// population. Deterministic: the same pixels always give the same result.
///
/// Pixels are counted in 5-bit RGB bins, each bin is converted to HCT once,
/// bins of near hues (chromatic) or near tones (gray) are merged heaviest
/// first, and up to three clusters holding at least 10 % of the weight remain.
CoverBackdrop analyzeCoverBackdrop(ByteData data) {
  final bins = Float64List(32768);
  // Channel sums per bin: its real mean colour, not the bin's centre, so a
  // near-black or near-white cover is not tinted by the quantization step.
  final sums = Float64List(32768 * 3);
  var total = 0.0;
  for (var index = 0; index + 3 < data.lengthInBytes; index += 4) {
    final alpha = data.getUint8(index + 3);
    if (alpha < 128) continue;
    final r = data.getUint8(index);
    final g = data.getUint8(index + 1);
    final b = data.getUint8(index + 2);
    final bin = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
    bins[bin] += 1;
    sums[bin * 3] += r;
    sums[bin * 3 + 1] += g;
    sums[bin * 3 + 2] += b;
    total += 1;
  }
  if (total == 0) return CoverBackdrop.neutral;

  final entries = <_Entry>[];
  var chromaSum = 0.0;
  for (var bin = 0; bin < bins.length; bin++) {
    final population = bins[bin];
    if (population == 0) continue;
    final r = (sums[bin * 3] / population).round();
    final g = (sums[bin * 3 + 1] / population).round();
    final b = (sums[bin * 3 + 2] / population).round();
    final hct = Hct.fromInt(0xff000000 | (r << 16) | (g << 8) | b);
    chromaSum += hct.chroma * population;
    entries.add(
      _Entry(
        hct.hue,
        hct.chroma,
        hct.tone,
        population * coverChromaWeight(hct.chroma),
        bin,
      ),
    );
  }
  // Heaviest first; the bin index breaks ties so the order never depends on
  // floating point noise.
  entries.sort((a, b) {
    final byWeight = b.weight.compareTo(a.weight);
    return byWeight != 0 ? byWeight : a.bin.compareTo(b.bin);
  });

  final clusters = <_Cluster>[];
  var weightTotal = 0.0;
  for (final entry in entries) {
    weightTotal += entry.weight;
    _Cluster? target;
    for (final cluster in clusters) {
      if (cluster.accepts(entry)) {
        target = cluster;
        break;
      }
    }
    if (target == null) {
      target = _Cluster();
      clusters.add(target);
    }
    target.add(entry);
  }
  clusters.sort((a, b) {
    final byWeight = b.weight.compareTo(a.weight);
    return byWeight != 0 ? byWeight : a.firstBin.compareTo(b.firstBin);
  });

  final chosen = <_Cluster>[];
  for (final cluster in clusters) {
    if (chosen.length == 3) break;
    if (chosen.isNotEmpty && cluster.weight / weightTotal < _minimumShare) {
      break;
    }
    chosen.add(cluster);
  }
  final chosenWeight = chosen.fold<double>(0, (sum, c) => sum + c.weight);
  return CoverBackdrop([
    for (final cluster in chosen)
      CoverBackdropSample(
        hue: cluster.hue,
        chroma: cluster.chroma,
        tone: cluster.tone,
        share: cluster.weight / chosenWeight,
      ),
  ], meanChroma: chromaSum / total);
}

/// Analyses a cover given as [Uint8List] of straight RGBA, or neutral for
/// null, as the background job passes it.
CoverBackdrop analyzeCoverBackdropBytes(Uint8List? straight) => straight == null
    ? CoverBackdrop.neutral
    : analyzeCoverBackdrop(ByteData.sublistView(straight));

class _Entry {
  const _Entry(this.hue, this.chroma, this.tone, this.weight, this.bin);

  final double hue;
  final double chroma;
  final double tone;
  final double weight;
  final int bin;
}

class _Cluster {
  double weight = 0;
  double _x = 0;
  double _y = 0;
  double _chroma = 0;
  double _tone = 0;
  int firstBin = -1;

  static const double _chromatic = 8;

  double get chroma => weight == 0 ? 0 : _chroma / weight;
  double get tone => weight == 0 ? 0 : _tone / weight;
  double get hue {
    if (_x == 0 && _y == 0) return 0;
    final degrees = math.atan2(_y, _x) * 180 / math.pi;
    return (degrees + 360) % 360;
  }

  bool accepts(_Entry entry) {
    final mine = chroma;
    if (mine >= _chromatic && entry.chroma >= _chromatic) {
      var delta = (entry.hue - hue).abs() % 360;
      if (delta > 180) delta = 360 - delta;
      return delta <= 32;
    }
    if (mine < _chromatic && entry.chroma < _chromatic) {
      return (entry.tone - tone).abs() <= 24;
    }
    return false;
  }

  void add(_Entry entry) {
    if (firstBin < 0) firstBin = entry.bin;
    final radians = entry.hue * math.pi / 180;
    final w = entry.weight * math.max(entry.chroma, 1);
    _x += math.cos(radians) * w;
    _y += math.sin(radians) * w;
    weight += entry.weight;
    _chroma += entry.chroma * entry.weight;
    _tone += entry.tone * entry.weight;
  }
}
