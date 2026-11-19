import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';

class StreamingQualityNotice {
  const StreamingQualityNotice({
    required this.requested,
    required this.actual,
    this.unavailable = true,
    this.requestedService = '',
    this.actualService = '',
    this.actualMark,
    this.needsFileFacts = false,
  });

  final String requested;
  final String actual;
  final bool unavailable;
  final String requestedService;
  final String actualService;
  final QualityMark? actualMark;
  final bool needsFileFacts;

  String get requestedLabel =>
      requestedService.isEmpty ? requested : '$requested ($requestedService)';

  String actualLabel({String? losslessName}) {
    final name = actualMark == QualityMark.lossless && losslessName != null
        ? losslessName
        : actual;
    return actualService.isEmpty ? name : '$name ($actualService)';
  }
}

String qualityNoticeMarkName(QualityMark mark) => switch (mark) {
  QualityMark.atmos => 'Dolby Atmos',
  QualityMark.dolbyPlus => 'Dolby Digital Plus',
  QualityMark.max || QualityMark.hiRes => 'Hi-Res',
  QualityMark.dsd => 'DSD',
  QualityMark.lossless => 'Lossless',
  QualityMark.flac => 'FLAC',
  QualityMark.alac => 'ALAC',
  QualityMark.wav => 'WAV',
  QualityMark.aiff => 'AIFF',
  QualityMark.ape => 'APE',
  QualityMark.aac => 'AAC',
  QualityMark.m4a => 'M4A',
  QualityMark.mp3 => 'MP3',
  QualityMark.opus => 'Opus',
  QualityMark.ogg => 'Ogg',
  QualityMark.wma => 'WMA',
  QualityMark.lossy => 'Lossy',
};

bool _carriesDepth(QualityMark mark) =>
    mark == QualityMark.hiRes ||
    mark == QualityMark.max ||
    mark == QualityMark.dsd;

bool _depthIsUnknownForCodec(String codec) {
  final c = codec.toLowerCase();
  return c.contains('flac') || c.contains('alac');
}

String? _formatName(String raw) {
  final text = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (text.isEmpty) return null;
  if (text.contains('ac4')) return 'AC-4';
  if (text.contains('eac3') || text.contains('ec3')) return 'E-AC-3';
  if (text.contains('atmos')) return 'Dolby Atmos';
  if (text.contains('alac')) return 'ALAC';
  if (text.contains('flac') ||
      text.contains('lossless') ||
      text.contains('hires')) {
    return 'FLAC';
  }
  if (text.contains('opus')) return 'Opus';
  if (text.contains('aac') || text.contains('m4a')) return 'AAC';
  if (text.contains('mp3')) return 'MP3';
  return null;
}

bool _isSpatialName(String name) =>
    name == 'AC-4' || name == 'E-AC-3' || name == 'Dolby Atmos';

StreamingQualityNotice? streamingQualityNotice({
  required String requestedQuality,
  required Map<String, Object> metadata,
  bool relayed = false,
  bool requestedUnavailable = true,
  String chosenService = '',
  int? bitDepth,
  int? sampleRate,
}) {
  final requestedId = requestedQuality.trim();
  if (requestedId.isEmpty || requestedId == autoLightStreamingQuality) {
    return null;
  }
  final requested = _formatName(requestedId);
  if (requested == null) return null;
  final codec = metadata['output_codec']?.toString() ?? '';
  final resolved = metadata['resolved_quality']?.toString() ?? '';
  final actual = _formatName(codec) ?? _formatName(resolved);
  if (actual == null || actual == requested) return null;
  final relayedNow = relayed || metadata['quality_fallback_used'] == true;
  final lostSpatial = _isSpatialName(requested) && !_isSpatialName(actual);
  if (!relayedNow && !lostSpatial) return null;
  final mark = verifiedQualityMark(
    declared: qualityMarkFor('', resolved),
    codec: codec.isEmpty ? resolved : codec,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );
  final servedService = qualityServiceShortName(
    metadata['provider']?.toString(),
  );
  final askedService = qualityServiceShortName(chosenService);
  final moved =
      askedService.isNotEmpty &&
      servedService.isNotEmpty &&
      askedService != servedService;
  final depth = _carriesDepth(mark) && bitDepth != null ? ' $bitDepth-bit' : '';
  return StreamingQualityNotice(
    requested: requested,
    actual: '${qualityNoticeMarkName(mark)}$depth',
    unavailable: requestedUnavailable || !relayedNow,
    requestedService: moved ? askedService : '',
    actualService: moved ? servedService : '',
    actualMark: mark,
    needsFileFacts:
        bitDepth == null &&
        _depthIsUnknownForCodec(codec.isEmpty ? actual : codec),
  );
}
