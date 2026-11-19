import 'package:mornye/models/extension.dart';

// Rust str::trim uses Unicode White_Space, which excludes U+FEFF.
const _rustWhitespace =
    r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]';
final _qualityIdPadding = RegExp('^$_rustWhitespace+|$_rustWhitespace+\$');
final _asciiUppercase = RegExp(r'[A-Z]');

String manifestQualityId(String id) => id.replaceAll(_qualityIdPadding, '');

String _qualityKey(String id) {
  final trimmed = manifestQualityId(id);
  return trimmed.replaceAllMapped(
    _asciiUppercase,
    (match) => match[0]!.toLowerCase(),
  );
}

bool sameManifestQualityId(String left, String right) =>
    _qualityKey(left) == _qualityKey(right);

/// Matches ExtensionManifest::find_quality, including first-match ordering.
QualityOption? findDownloadQualityOption(
  Iterable<QualityOption> options,
  String requested,
) {
  final key = _qualityKey(requested);
  if (key.isEmpty) return null;
  return options.where((option) => _qualityKey(option.id) == key).firstOrNull;
}

// Mirrors Rust `quality_claims`, but every depth/sample-rate token is read (not
// only the supported ones), so an unsupported or glued value such as "88.2kHz"
// or "196kHz" is a competing claim instead of being silently ignored.
const _codecNames = ['opus', 'aac', 'mp3', 'vorbis', 'flac', 'alac'];
const _losslessCodecs = {'flac', 'alac'};
final _depthClaim = RegExp(r'(?<!\d)(\d+)\s*[-_]?\s*bit');
final _sampleClaim = RegExp(r'(?<![\d.])(\d+(?:\.\d+)?)\s*[-_]?\s*(khz|hz)');
const _bitrates = {64, 96, 128, 160, 192, 256, 320};

typedef _Claims = ({
  Set<String> codecs,
  Set<int> depths,
  Set<int> samples,
  Set<int> bitrates,
});

_Claims _claims(String text) {
  final lower = text.toLowerCase();
  return (
    codecs: _codecNames.where(lower.contains).toSet(),
    depths: _depthClaim.allMatches(lower).map((m) => int.parse(m[1]!)).toSet(),
    samples: _sampleClaim.allMatches(lower).map((m) {
      final value = double.parse(m[1]!);
      return (m[2] == 'khz' ? value * 1000 : value).round();
    }).toSet(),
    bitrates: lower
        .split(RegExp(r'[^0-9]+'))
        .map(int.tryParse)
        .whereType<int>()
        .where(_bitrates.contains)
        .toSet(),
  );
}

// Rust `quality_claims_conflict` ambiguity: contradictory declarations are not
// evidence of equivalent audio, whatever the codec.
bool _ambiguous(_Claims c) =>
    c.codecs.length > 1 ||
    c.depths.length > 1 ||
    c.samples.length > 1 ||
    (c.codecs.isNotEmpty &&
        !_losslessCodecs.contains(c.codecs.first) &&
        c.bitrates.length > 1);

String? _codecClass(_Claims c) => c.codecs.length != 1
    ? null
    : _losslessCodecs.contains(c.codecs.single)
    ? 'lossless'
    : 'lossy';

// Declared kind wins; otherwise an explicit word in the id/label. A declared
// class that contradicts the codec the text names is itself a conflict.
String? _declaredClass(String kind, String text) {
  final k = kind.trim().toLowerCase();
  if (k == 'lossless' || k == 'lossy') return k;
  final lower = text.toLowerCase();
  if (lower.contains('lossless')) return 'lossless';
  if (lower.contains('lossy')) return 'lossy';
  return null;
}

bool _differs<T>(Set<T> a, Set<T> b) =>
    a.isNotEmpty && b.isNotEmpty && !(a.length == b.length && a.containsAll(b));

(String, int, int)? _signatureOf(_Claims c) {
  if (c.codecs.length != 1) return null;
  final codec = c.codecs.single;
  if (_losslessCodecs.contains(codec)) {
    const depths = {16, 24, 32};
    const rates = {44100, 48000, 96000, 192000};
    return c.depths.length == 1 &&
            c.samples.length == 1 &&
            depths.contains(c.depths.single) &&
            rates.contains(c.samples.single)
        ? (codec, c.depths.single, c.samples.single)
        : null;
  }
  return c.bitrates.length == 1 ? (codec, c.bitrates.single, 0) : null;
}

/// Strict equivalence of an obsolete requested id against a live option. True
/// only when both sides prove the same codec/bitrate (lossy) or
/// codec/depth/rate (lossless) with no contradictory claim on either side.
bool _qualityEquivalent(String requested, QualityOption option) {
  final optionText = '${option.id} ${option.label}';
  final want = _claims(requested);
  final have = _claims(optionText);
  if (_ambiguous(want) || _ambiguous(have)) return false;
  final wantClass = _declaredClass('', requested);
  final haveClass = _declaredClass(option.kind, optionText);
  final wantCodec = _codecClass(want);
  final haveCodec = _codecClass(have);
  bool clash(String? x, String? y) => x != null && y != null && x != y;
  if (clash(wantClass, wantCodec) ||
      clash(haveClass, haveCodec) ||
      clash(wantClass ?? wantCodec, haveClass ?? haveCodec)) {
    return false;
  }
  if (_differs(want.codecs, have.codecs) ||
      _differs(want.depths, have.depths) ||
      _differs(want.samples, have.samples) ||
      (wantCodec == 'lossy' &&
          haveCodec == 'lossy' &&
          _differs(want.bitrates, have.bitrates))) {
    return false;
  }
  final signature = _signatureOf(want);
  return signature != null && signature == _signatureOf(have);
}

// Mirrors Rust extension_quality_kind's spatial inference for manifests that
// predate `kind`; descriptions are excluded, as there.
bool _hasSpatialWords(String id, String label) {
  final token = manifestQualityId(id).toLowerCase();
  final text = '$token ${label.toLowerCase()}';
  return text.contains('atmos') ||
      text.contains('dolby') ||
      text.contains('surround') ||
      const {'ac4', 'ac-4', 'eac3', 'e-ac-3', 'ec-3'}.contains(token);
}

bool _optionIsSpatial(QualityOption option) {
  final kind = option.kind.trim().toLowerCase();
  if (kind == 'spatial') return true;
  if (kind == 'lossless' || kind == 'lossy') return false;
  return _hasSpatialWords(option.id, option.label);
}

QualityOption? findEquivalentDownloadQualityOption(
  Iterable<QualityOption> options,
  String requested,
) {
  // A requested string carries no declared kind and the settings store keeps
  // only the id, never the origin QualityOption; never invent one. It is
  // spatial only when the text itself says so, and spatial never equals
  // stereo or undefined (Rust quality_claims_conflict).
  final requestedSpatial = _requestedClaimsSpatial(requested);
  return options
      .where(
        (option) =>
            manifestQualityId(option.id).isNotEmpty &&
            _optionIsSpatial(option) == requestedSpatial &&
            _qualityEquivalent(requested, option),
      )
      .firstOrNull;
}

// Conservative on the request side only: "spatial" in a remembered id is a
// spatial claim even though Rust's legacy inference does not list that word.
bool _requestedClaimsSpatial(String requested) =>
    _hasSpatialWords(requested, '') ||
    requested.toLowerCase().contains('spatial');

Iterable<QualityOption> distinctDownloadQualityOptions(
  Iterable<QualityOption> options,
) sync* {
  final seen = <String>{};
  for (final option in options) {
    final key = _qualityKey(option.id);
    if (key.isNotEmpty && seen.add(key)) yield option;
  }
}

const _defaultQualityProviders = {
  'amazon',
  'deezer',
  'tidal-web',
  'qobuz-web',
  'jiosaavn',
  'ytmusic-spotiflac',
  'soundcloud',
};

bool hasDefaultDownloadQualityPolicy(String providerId) =>
    _defaultQualityProviders.contains(providerId.trim().toLowerCase());

const _highResWords = [
  'hi_res',
  'hi-res',
  'hires',
  'max',
  'studio',
  '24',
  '32',
  '96',
  '192',
];

int _claimedDepth(QualityOption option) {
  final claims = _claims('${option.id} ${option.label}');
  if (claims.depths.isNotEmpty) return claims.depths.reduce((a, b) => a > b ? a : b);
  final text = '${option.id} ${option.label}'.toLowerCase();
  return _highResWords.any(text.contains) ? 24 : 16;
}

int _lossyRank(QualityOption option) {
  final text = '${option.id} ${option.label}'.toLowerCase();
  final claims = _claims(text);
  if (claims.bitrates.isNotEmpty) {
    return claims.bitrates.reduce((a, b) => a > b ? a : b);
  }
  if (text.contains('high')) return 256;
  if (text.contains('normal') ||
      text.contains('medium') ||
      text.contains('standard')) {
    return 160;
  }
  if (text.contains('low')) return 96;
  if (text.contains('best') || text.contains('max')) return 0;
  return 128;
}

bool _isLossless(QualityOption o) {
  final kind = o.kind.trim().toLowerCase();
  if (kind == 'lossless') return true;
  if (kind == 'lossy') return false;
  final claims = _claims('${o.id} ${o.label}');
  final text = '${o.id} ${o.label}'.toLowerCase();
  return text.contains('lossless') ||
      claims.codecs.any(_losslessCodecs.contains) ||
      text.contains('flac');
}

const hiResLosslessStrength = 5000;
const losslessStrength = 4000;
const _bestAvailableLossyStrength = 256;

int _optionStrength(QualityOption option) {
  if (_isLossless(option)) {
    final text = '${option.id} ${option.label}'.toLowerCase();
    return _claimedDepth(option) > 16 || text.contains('best')
        ? hiResLosslessStrength
        : losslessStrength;
  }
  final rank = _lossyRank(option);
  return rank == 0 ? _bestAvailableLossyStrength : rank;
}

/// Strongest stereo tier a provider declares: hi-res lossless, lossless or the
/// highest lossy bitrate. Spatial tiers do not raise it; zero when nothing is
/// declared.
int downloadQualityStrength(Iterable<QualityOption> declared) {
  final options = distinctDownloadQualityOptions(declared).toList();
  final stereo = options.where((o) => !_optionIsSpatial(o)).toList();
  final pool = stereo.isEmpty ? options : stereo;
  var best = 0;
  for (final option in pool) {
    final strength = _optionStrength(option);
    if (strength > best) best = strength;
  }
  return best;
}

const spatialStrength = 6000;

/// Strongest tier a provider declares, spatial included, used to rank
/// providers by the best audio they can deliver.
int downloadQualityCeiling(Iterable<QualityOption> declared) {
  final options = distinctDownloadQualityOptions(declared).toList();
  var best = 0;
  for (final option in options) {
    final strength = _optionIsSpatial(option)
        ? spatialStrength
        : _optionStrength(option);
    if (strength > best) best = strength;
  }
  return best;
}

int downloadQualityOptionCount(Iterable<QualityOption> declared) =>
    distinctDownloadQualityOptions(declared).length;

/// MP3-equivalent quality among the declared options: the highest lossy tier
/// up to 320 kbps; else the lowest lossless one (CD); else, if every lossy
/// tier is above that range, the lowest of them. Hi-res and spatial tiers are
/// never the default unless nothing else is declared. Null only when nothing
/// is declared.
QualityOption? defaultDownloadQualityOf(Iterable<QualityOption> declared) {
  final options = distinctDownloadQualityOptions(declared).toList();
  if (options.isEmpty) return null;
  if (options.length == 1) return options.single;
  final stereo = options.where((o) => !_optionIsSpatial(o)).toList();
  final pool = stereo.isEmpty ? options : stereo;
  final lossyOptions = pool.where((o) => !_isLossless(o)).toList();
  final losslessOptions = pool.where(_isLossless).toList();
  final inRange = lossyOptions
      .where((o) => _lossyRank(o) > 0 && _lossyRank(o) <= 320)
      .toList();
  if (inRange.isNotEmpty) {
    var best = inRange.first;
    for (final option in inRange.skip(1)) {
      if (_lossyRank(option) > _lossyRank(best)) best = option;
    }
    return best;
  }
  if (losslessOptions.isNotEmpty) {
    var best = losslessOptions.first;
    for (final option in losslessOptions.skip(1)) {
      if (_claimedDepth(option) < _claimedDepth(best)) best = option;
    }
    return best;
  }
  return lossyOptions.first;
}

QualityOption? defaultDownloadQualityFor(Extension extension) =>
    defaultDownloadQualityOf(extension.qualityOptions);

/// An extension update may remove a tier, so resolve it against the live list.
QualityOption? defaultDownloadQualityOption(
  String providerId,
  Iterable<QualityOption> options,
) => hasDefaultDownloadQualityPolicy(providerId)
    ? defaultDownloadQualityOf(options)
    : null;
