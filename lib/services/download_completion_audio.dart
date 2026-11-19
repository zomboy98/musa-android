import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/int_utils.dart';

typedef DownloadCompletionAudio = ({
  String quality,
  int? bitDepth,
  int? sampleRate,
  int? bitrate,
  String? format,
  Map<String, dynamic>? metadata,
});

/// Resolves the audio actually written, reusing metadata read before SAF
/// publication. Provider result fields can describe a requested target, so
/// only metadata read from the final file is treated as measured audio.
Future<DownloadCompletionAudio> resolveDownloadCompletionAudio({
  required Map<String, dynamic> result,
  required String filePath,
  String? fileName,
  required String quality,
  Map<String, dynamic>? metadata,
  required Future<Map<String, dynamic>> Function(String) readMetadata,
  required void Function(String) debug,
}) async {
  int? bitDepth;
  int? sampleRate;
  String? format;
  int? bitrate;
  quality = '';
  final lowerPath = filePath.toLowerCase();
  if (isContentUri(filePath) ||
      const [
        '.flac',
        '.m4a',
        '.mp4',
        '.aac',
        '.mp3',
        '.opus',
        '.ogg',
        '.wav',
        '.aif',
        '.aiff',
        '.alac',
      ].any(lowerPath.endsWith)) {
    try {
      final probed = metadata != null && metadata['error'] == null
          ? metadata
          : await readMetadata(filePath);
      if (probed['error'] == null) {
        metadata = probed;
        final rawCodec = probed['audio_codec']?.toString().trim().toLowerCase();
        final codec = const {'ogg', 'm4a', 'mp4'}.contains(rawCodec)
            ? null
            : normalizeAudioFormatValue(rawCodec);
        final rawFormat = probed['format']?.toString().trim().toLowerCase();
        final containerOnly =
            const {'ogg', 'm4a', 'mp4'}.contains(rawFormat) ||
            const {'ogg', 'm4a', 'mp4'}.contains(rawCodec);
        format =
            codec ??
            (containerOnly ? null : detectedAudioFormatFromMetadata(probed));
        bitDepth = readPositiveInt(probed['bit_depth']);
        sampleRate = readPositiveInt(probed['sample_rate']);
        bitrate = readPositiveBitrateKbps(
          probed['bitrate'] ?? probed['bit_rate'],
        );
        if (codec == null &&
            (containerOnly ||
                lowerPath.endsWith('.ogg') ||
                lowerPath.endsWith('.m4a') ||
                lowerPath.endsWith('.mp4'))) {
          // A container alone does not establish a codec or lossless quality.
          bitDepth = null;
          sampleRate = null;
        }
      }
    } catch (error) {
      debug('Final audio metadata probe failed for $filePath: $error');
    }
  }

  final isLossy =
      isLossyAudioFormat(format) ||
      lowerPath.endsWith('.mp3') ||
      lowerPath.endsWith('.opus');
  if (isLossy) {
    bitDepth = null;
    sampleRate = null;
  }

  // A path extension alone is not a verified codec or quality.
  final hasAudioEvidence =
      format != null ||
      bitDepth != null ||
      sampleRate != null ||
      bitrate != null;
  if (hasAudioEvidence) {
    quality =
        resolveDisplayQuality(
          filePath: null,
          detectedFormat: format,
          bitDepth: bitDepth,
          sampleRate: sampleRate,
          bitrateKbps: bitrate,
        ) ??
        '';
  }

  return (
    quality: quality,
    bitDepth: bitDepth,
    sampleRate: sampleRate,
    bitrate: bitrate,
    format: format,
    metadata: metadata,
  );
}
