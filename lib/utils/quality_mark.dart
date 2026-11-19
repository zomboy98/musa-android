import 'package:mornye/services/streaming_quality_resolver.dart';

enum QualityMark {
  atmos,
  dolbyPlus,
  max,
  hiRes,
  dsd,
  lossless,
  flac,
  alac,
  wav,
  aiff,
  ape,
  aac,
  m4a,
  mp3,
  opus,
  ogg,
  wma,
  lossy,
}

final _bitrateText = RegExp(
  r'(\d{2,3})\s*(?:k|kbps|kb/s)\b',
  caseSensitive: false,
);
final _depthText = RegExp(
  r'(?<!\d)(\d{2})\s*[-_ ]?\s*bit',
  caseSensitive: false,
);
final _rateText = RegExp(
  r'(?<![\d.])(\d{2,3}(?:\.\d)?)\s*[-_ ]?\s*khz',
  caseSensitive: false,
);

String _words(String id, String label) => '$id $label'.toLowerCase();

final _eac3Text = RegExp(r'e-?ac-?3|(^|[^a-z])ec-?3|digital\s*plus');
final _ac4Text = RegExp(r'(^|[^a-z])ac-?4');

bool isDolbyMark(QualityMark mark) =>
    mark == QualityMark.atmos || mark == QualityMark.dolbyPlus;

QualityMark qualityMarkFor(String id, [String label = '', String kind = '']) {
  final text = _words(id, label);
  final k = kind.trim().toLowerCase();
  if (_eac3Text.hasMatch(text) && !_ac4Text.hasMatch(text)) {
    return QualityMark.dolbyPlus;
  }
  if (k == 'spatial' ||
      const ['atmos', 'eac3', 'ac4', 'spatial'].any(text.contains)) {
    return QualityMark.atmos;
  }
  if (RegExp(r'(^|[^a-z])max([^a-z]|$)').hasMatch(text)) return QualityMark.max;
  if (RegExp(r'hi[-_ ]?res').hasMatch(text)) return QualityMark.hiRes;
  if (RegExp(r'(^|[^a-z])dsd').hasMatch(text)) return QualityMark.dsd;
  if (text.contains('alac')) return QualityMark.alac;
  if (text.contains('flac')) {
    return RegExp(r'(?<!\d)(24|32)\s*[-_]?\s*bit').hasMatch(text)
        ? QualityMark.hiRes
        : QualityMark.flac;
  }
  if (RegExp(r'(^|[^a-z])wav([^a-z]|$)').hasMatch(text)) return QualityMark.wav;
  if (RegExp(r'aiff?').hasMatch(text)) return QualityMark.aiff;
  if (RegExp(r'(^|[^a-z])ape([^a-z]|$)').hasMatch(text)) return QualityMark.ape;
  if (RegExp(r'(^|[^a-z])wma').hasMatch(text)) return QualityMark.wma;
  if (text.contains('opus')) return QualityMark.opus;
  if (RegExp(r'ogg|vorbis').hasMatch(text)) return QualityMark.ogg;
  if (text.contains('mp3')) return QualityMark.mp3;
  if (RegExp(r'm4a').hasMatch(text) && !text.contains('aac')) {
    return QualityMark.m4a;
  }
  if (RegExp(r'aac|he-?aac').hasMatch(text)) return QualityMark.aac;
  if (RegExp(r'(?<!\d)(24|32)\s*[-_]?\s*bit').hasMatch(text)) {
    return QualityMark.hiRes;
  }
  final resolved = k.isEmpty ? inferQualityKind(id, label) : k;
  return resolved == 'lossless' ? QualityMark.lossless : QualityMark.lossy;
}

bool isLossyMark(QualityMark mark) => switch (mark) {
  QualityMark.aac ||
  QualityMark.m4a ||
  QualityMark.mp3 ||
  QualityMark.opus ||
  QualityMark.ogg ||
  QualityMark.wma ||
  QualityMark.lossy => true,
  _ => false,
};

/// What the file or decoder confirmed (codec name, sample rate, depth); the
/// provider's declaration only fills what the probe did not report.
({int? sampleRate, int? bitDepth, int? bitrateKbps, String? codec})
verifiedSpec({
  String? codec,
  int? sampleRate,
  int? bitDepth,
  int? bitrateKbps,
}) => (
  codec: codec?.trim().isEmpty ?? true ? null : codec!.trim().toLowerCase(),
  sampleRate: sampleRate != null && sampleRate > 0 ? sampleRate : null,
  bitDepth: bitDepth != null && bitDepth > 0 ? bitDepth : null,
  bitrateKbps: bitrateKbps != null && bitrateKbps > 0 ? bitrateKbps : null,
);

bool isDolbyCodec(String codec) {
  final c = codec.trim().toLowerCase();
  return const ['eac3', 'ec3', 'ac3', 'ac4', 'truehd', 'joc'].any(c.contains);
}

/// The mark of what really plays. A codec read by the decoder wins over what
/// the provider declared; tiers the probe cannot prove (Atmos, Max) are kept
/// only when the probed stream is compatible with them.
QualityMark verifiedQualityMark({
  required QualityMark declared,
  String? codec,
  int? sampleRate,
  int? bitDepth,
}) {
  final c = codec?.trim().toLowerCase() ?? '';
  if (c.isEmpty) return declared;
  final highRate = (sampleRate ?? 0) > 48000 || (bitDepth ?? 16) > 16;
  if (isDolbyCodec(c)) {
    if (declared == QualityMark.atmos || c.contains('ac4')) {
      return QualityMark.atmos;
    }
    return QualityMark.dolbyPlus;
  }
  if (c == 'flac' || c.contains('flac')) {
    if (highRate) {
      return declared == QualityMark.max || declared == QualityMark.hiRes
          ? declared
          : QualityMark.hiRes;
    }
    return QualityMark.flac;
  }
  if (c.contains('alac')) {
    return highRate ? QualityMark.hiRes : QualityMark.alac;
  }
  if (c.contains('opus')) return QualityMark.opus;
  if (c.contains('vorbis') || c == 'ogg') return QualityMark.ogg;
  if (c.contains('mp3') || c.contains('mpeg')) return QualityMark.mp3;
  if (c.contains('aac') || c.contains('mp4a')) {
    return declared == QualityMark.m4a ? declared : QualityMark.aac;
  }
  if (c.contains('wma')) return QualityMark.wma;
  if (c.contains('dsd')) return QualityMark.dsd;
  if (c.contains('wav') || c.contains('pcm')) return QualityMark.wav;
  if (c.contains('aif')) return QualityMark.aiff;
  if (c == 'ape' || c.contains('monkey')) return QualityMark.ape;
  if (isDolbyMark(declared)) {
    return QualityMark.lossy;
  }
  return declared;
}

String _khz(int hz) {
  final value = hz / 1000;
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

/// Short measurable detail of a quality: "96 kbps" for lossy, "24-bit / 96 kHz"
/// for lossless, or null when the text declares none.
String? qualityDetailFor(
  String id,
  String label, {
  int? sampleRate,
  int? bitDepth,
  int? bitrateKbps,
  bool lossy = false,
}) {
  final text = '$label $id';
  final depth = bitDepth ?? int.tryParse(_depthText.firstMatch(text)?[1] ?? '');
  final rateText = _rateText.firstMatch(text)?[1];
  final rate =
      sampleRate ??
      (rateText == null ? null : (double.parse(rateText) * 1000).round());
  if (depth != null || rate != null) {
    return [
      if (depth != null) '$depth-bit',
      if (rate != null) '${_khz(rate)} kHz',
    ].join(' / ');
  }
  final kbps =
      bitrateKbps ??
      int.tryParse(_bitrateText.firstMatch(text)?[1] ?? '') ??
      (lossy ? _lossyIdBitrate(id) : null);
  return kbps == null ? null : '$kbps kbps';
}

int? _lossyIdBitrate(String id) {
  for (final match in RegExp(r'(?<![\d.])(\d{2,3})(?![\d])').allMatches(id)) {
    final value = int.parse(match[1]!);
    if (value >= 32 && value <= 512) return value;
  }
  return null;
}

int qualityMarkOrder(QualityMark mark) => QualityMark.values.indexOf(mark);

int? bitrateOfDetail(String? detail) =>
    int.tryParse(RegExp(r'^(\d+) kbps').firstMatch(detail ?? '')?[1] ?? '');
