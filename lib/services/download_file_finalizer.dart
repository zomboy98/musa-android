import 'dart:io';

import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';

typedef DecryptDownloadFile =
    Future<String?> Function({
      required String inputPath,
      required DownloadDecryptionDescriptor descriptor,
      required bool deleteOriginal,
      Future<void> Function(String)? prepareOutput,
    });

enum DownloadDecryptionFailure { safAccess, decrypt, safWrite }

class DownloadDecryptionOutcome {
  const DownloadDecryptionOutcome(this.path, {this.fileName, this.failure});
  final String? path;
  final String? fileName;
  final DownloadDecryptionFailure? failure;
}

/// Owns audio transforms and their optional-failure policy. Queue state,
/// settings, track enrichment and platform storage stay at the call boundary.
class DownloadFileFinalizer {
  const DownloadFileFinalizer({
    required this.decryptFile,
    required this.probeCodec,
    this.probeProperties = FFmpegProbe.audioProperties,
    required this.repairAc4,
    required this.replaceSafFile,
    required this.warn,
    required this.info,
    this.readDocumentStat = PlatformBridge.safStat,
  });

  final DecryptDownloadFile decryptFile;
  final Future<String?> Function(String) probeCodec;
  final Future<PrimaryAudioProperties> Function(String) probeProperties;
  final Future<void> Function(String path, String encryptedPath) repairAc4;
  final ReplaceSafDownloadFile replaceSafFile;
  final void Function(String) warn;
  final void Function(String) info;
  final Future<Map<String, dynamic>> Function(String) readDocumentStat;

  Future<String> _normalizeIsoBmffPath(
    String path,
    DownloadResult result,
  ) async {
    if (!_isMp4Container(path)) return path;
    final codec = await probeCodec(path);
    final extension = isoBmffAudioExtensionForCodec(
      codec ?? result.reportedFormat,
    );
    if (path.toLowerCase().endsWith(extension)) return path;
    final targetPath = path.replaceFirst(
      RegExp(r'\.(?:m4a|mp4)$', caseSensitive: false),
      extension,
    );
    if (targetPath == path) return path;
    try {
      if (await File(targetPath).exists()) {
        warn(
          'Cannot normalize ISO-BMFF audio extension; target already exists: $targetPath',
        );
        return path;
      }
      return (await File(path).rename(targetPath)).path;
    } catch (e) {
      warn('Failed to normalize ISO-BMFF audio extension for $path: $e');
      return path;
    }
  }

  Future<void> _repair(String path, String encryptedPath) async {
    if (!_isMp4Container(path)) return;
    try {
      await repairAc4(path, encryptedPath);
    } catch (e) {
      warn('AC-4 container repair skipped: $e');
    }
  }

  Future<DownloadDecryptionOutcome> decrypt({
    required DownloadResult result,
    required String filePath,
    required bool useSaf,
    String? treeUri,
    required String relativeDir,
    required String baseName,
    required String extensionFallback,
    required bool repairContainer,
    void Function(String strategy)? onStart,
  }) async {
    if (result.alreadyExists) return DownloadDecryptionOutcome(filePath);
    final descriptor = result.decryption;
    if (descriptor == null) {
      return DownloadDecryptionOutcome(filePath);
    }
    onStart?.call(descriptor.normalizedStrategy);
    if (useSaf && isContentUri(filePath)) {
      if (treeUri == null || treeUri.isEmpty) {
        return const DownloadDecryptionOutcome(
          null,
          failure: DownloadDecryptionFailure.safAccess,
        );
      }
      DownloadDecryptionFailure? failure;
      var started = false;
      String? fileName;
      final uri = await replaceSafFile(
        uri: filePath,
        treeUri: treeUri,
        relativeDir: relativeDir,
        op: (tempPath, addCleanup) async {
          started = true;
          final decrypted = await decryptFile(
            inputPath: tempPath,
            descriptor: descriptor,
            deleteOriginal: false,
          );
          if (decrypted == null) {
            failure = DownloadDecryptionFailure.decrypt;
            return null;
          }
          addCleanup(decrypted);
          final normalized = await _normalizeIsoBmffPath(decrypted, result);
          if (normalized != decrypted) addCleanup(normalized);
          if (repairContainer) await _repair(normalized, tempPath);
          final dotIndex = normalized.lastIndexOf('.');
          final extension = dotIndex >= 0
              ? normalized.substring(dotIndex).toLowerCase()
              : extensionFallback;
          const allowed = {'.flac', '.m4a', '.mp4', '.mp3', '.opus'};
          fileName =
              '$baseName${allowed.contains(extension) ? extension : extensionFallback}';
          return (normalized, fileName!);
        },
      );
      return DownloadDecryptionOutcome(
        uri,
        fileName: uri == null ? null : fileName,
        failure: uri == null
            ? failure ??
                  (started
                      ? DownloadDecryptionFailure.safWrite
                      : DownloadDecryptionFailure.safAccess)
            : null,
      );
    }
    final decrypted = await decryptFile(
      inputPath: filePath,
      descriptor: descriptor,
      deleteOriginal: true,
      // Repair before the encrypted source is removed by atomic promotion.
      prepareOutput: repairContainer ? (path) => _repair(path, filePath) : null,
    );
    return DownloadDecryptionOutcome(
      decrypted == null ? null : await _normalizeIsoBmffPath(decrypted, result),
      failure: decrypted == null ? DownloadDecryptionFailure.decrypt : null,
    );
  }
}

/// Reads the document's display name instead of treating an opaque ID as a name.
Future<String> downloadSourceFileName(
  String filePath, {
  Future<Map<String, dynamic>> Function(String) readDocumentStat =
      PlatformBridge.safStat,
}) async {
  if (!isContentUri(filePath)) return File(filePath).uri.pathSegments.last;
  bool usable(String? name) =>
      name != null &&
      name.trim().isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !RegExp(r'[/\\\x00]').hasMatch(name);
  try {
    final stat = await readDocumentStat(filePath);
    final name = stat['display_name'] as String?;
    if (stat['exists'] != false && usable(name)) return name!;
  } catch (_) {
    // Older hosts may omit display_name; only the external-storage provider
    // defines document IDs as volume:path. Other providers use opaque IDs.
  }
  final uri = Uri.parse(filePath);
  if (uri.host == 'com.android.externalstorage.documents') {
    final parts = uri.pathSegments;
    final document = parts.indexOf('document');
    if (document >= 0 && document + 1 < parts.length) {
      final id = parts[document + 1];
      final colon = id.indexOf(':');
      if (colon >= 0) {
        final name = id.substring(colon + 1).split('/').last;
        if (usable(name)) return name;
      }
    }
  }
  throw const FormatException('Document filename is unavailable');
}

bool _isMp4Container(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.m4a') || lower.endsWith('.mp4');
}
