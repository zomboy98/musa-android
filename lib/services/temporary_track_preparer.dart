import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/ac4_structure.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/utils/playable_audio_format.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;

/// Downloads into [directory] using an authorized provider, returning its file.
/// Implementations must not publish to the permanent queue or history.
typedef TemporaryTrackDownload =
    Future<File> Function(Directory directory, String transferId);
typedef TemporaryTrackCancel = Future<void> Function(String transferId);
typedef TemporaryTrackCodec = Future<String?> Function(String path);

const temporaryTrackNotFoundReason = 'provider track not found';
const temporaryProviderUnavailableReason = 'provider unavailable';

class TemporaryTrackException implements Exception {
  const TemporaryTrackException(this.reason);
  final String reason;
  @override
  String toString() => 'TemporaryTrackException: $reason';
}

class TemporaryVerificationRequired extends TemporaryTrackException {
  const TemporaryVerificationRequired(this.extensionId)
    : super('provider intervention required');
  final String extensionId;
}

class _VerificationRequired extends TemporaryTrackException {
  const _VerificationRequired(this.extensionId)
    : super('provider intervention required');
  final String extensionId;
}

/// A private staging result. The caller owns it and must dispose it after the
/// store has copied it. Concurrent requests for one id share this same result.
class PreparedTemporaryTrack {
  PreparedTemporaryTrack._(
    this.file,
    this._directory,
    this._marker,
    this.qualityMetadata,
  );
  final Map<String, Object> qualityMetadata;
  final File file;
  final Directory _directory;
  final RandomAccessFile _marker;
  bool _disposed = false;
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _marker.unlock();
    await _marker.close();
    TemporaryTrackPreparer._ownedDirectories.remove(
      p.normalize(p.absolute(_directory.path)),
    );
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}

/// Isolated preparation only; storage retention and playback are separate.
class TemporaryTrackPreparer {
  TemporaryTrackPreparer({
    required this.stagingRoot,
    required this.download,
    required this.cancelDownload,
    this.bitrateKbps = 128,
    TemporaryTrackCodec? codec,
    TemporaryTrackCodec? container,
    Future<bool> Function(String)? validate,
    // Internal platform adapter; callers use [TemporaryTrackPreparer.platform].
    // ignore: library_private_types_in_public_api
    Future<File> Function(String, File, Directory, _Preparation)? finalize,
    Future<void> Function(int)? cancelSession,
    Future<({int id, Future<FFmpegSessionResult> completed})> Function(
      List<String>,
    )?
    startSession,
    void Function(String)? clearPending,
    Map<String, Object> Function(String)? takeQualityMetadata,
    BugLog? bugLog,
    this.timeout = const Duration(minutes: 5),
    Future<void> Function(String)? createQuarantineMarker,
    Future<bool> Function(String, Future<void>)? verify,
    Duration Function()? monotonicNow,
    ProviderRequestGate? gate,
  }) : _codec = codec ?? FFmpegProbe.audioCodec,
       _gate = gate,
       _container = container ?? _probeContainer,
       _injectedProbe = codec != null || container != null,
       _verify = verify,
       _monotonicNow = monotonicNow ?? _elapsed,
       _validate = validate,
       _finalize = finalize,
       _cancelSession = cancelSession ?? FFmpegExecution.cancel,
       _startSession = startSession ?? FFmpegExecution.start,
       _clearPending = clearPending,
       _takeQualityMetadata = takeQualityMetadata,
       _createQuarantineMarker =
           createQuarantineMarker ?? _writeQuarantineMarker,
       _bugLog = bugLog ?? BugLog.instance;

  factory TemporaryTrackPreparer.platform({
    required Directory stagingRoot,
    required DownloadRequestPayload Function(Directory, String) payload,
    int bitrateKbps = 128,
    Future<String> Function(String)? acquireDirectory,
    Future<void> Function(String)? releaseDirectory,
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)? transfer,
    TemporaryTrackCancel? cancelTransfer,
    TemporaryTrackCodec? codec,
    TemporaryTrackCodec? container,
    Future<bool> Function(String)? validate,
    Future<Map<String, dynamic>> Function(String, String)? repairAc4,
    void Function(String)? diagnostic,
    BugLog? bugLog,
    Future<({int id, Future<FFmpegSessionResult> completed})> Function(
      List<String>,
    )?
    startFinalization,
    Future<void> Function(int)? cancelFinalization,
    Duration timeout = const Duration(minutes: 5),
    Future<void> Function(String)? createQuarantineMarker,
    Future<bool> Function(String, Future<void>)? verify,
    Duration Function()? monotonicNow,
    ProviderRequestGate? gate,
  }) {
    final pending = <String, DownloadResult>{};
    final qualityMetadata = <String, Map<String, Object>>{};
    return TemporaryTrackPreparer(
      stagingRoot: stagingRoot,
      bitrateKbps: bitrateKbps,
      container: container,
      timeout: timeout,
      monotonicNow: monotonicNow,
      createQuarantineMarker: createQuarantineMarker,
      bugLog: bugLog,
      verify: verify,
      gate: gate,
      download: (directory, transferId) async {
        final request = payload(directory, transferId);
        if (p.normalize(p.absolute(request.outputDir)) !=
                p.normalize(p.absolute(directory.path)) ||
            request.itemId != transferId ||
            request.storageMode != 'app' ||
            request.safTreeUri.isNotEmpty) {
          throw const TemporaryTrackException('invalid temporary request');
        }
        try {
          (diagnostic ?? _logDiagnostic)(_requestDiagnostic(request));
        } catch (_) {}
        final token =
            await (acquireDirectory ?? PlatformBridge.acquireDownloadDirectory)(
              directory.path,
            );
        try {
          final result = DownloadResult.fromMap(
            await (transfer ?? PlatformBridge.downloadTemporary)(request),
          );
          final filePath = result.filePath;
          final usableResult =
              result.success && filePath != null && filePath.isNotEmpty;
          final hasDecryptionMetadata =
              result['decryption'] != null || result['decryption_key'] != null;
          final invalidStructured =
              usableResult &&
              result['decryption'] != null &&
              DownloadDecryptionDescriptor.fromDownloadResult({
                    'decryption': result['decryption'],
                  }) ==
                  null;
          final invalidLegacy =
              usableResult &&
              result['decryption_key'] != null &&
              DownloadDecryptionDescriptor.fromDownloadResult({
                    'decryption_key': result['decryption_key'],
                  }) ==
                  null;
          final descriptor = result.decryption;
          final safeDescriptor =
              descriptor != null &&
              descriptor.normalizedStrategy == 'ffmpeg.mov_key' &&
              RegExp(r'^[a-zA-Z0-9+/=_-]+$').hasMatch(descriptor.key) &&
              (descriptor.inputFormat == null ||
                  descriptor.inputFormat == '' ||
                  descriptor.inputFormat == 'mov') &&
              (descriptor.normalizedOutputExtension == null ||
                  const {
                    '.flac',
                    '.m4a',
                    '.mp4',
                    '.mp3',
                    '.opus',
                  }.contains(descriptor.normalizedOutputExtension));
          final rejected =
              usableResult &&
              hasDecryptionMetadata &&
              (invalidStructured ||
                  invalidLegacy ||
                  !safeDescriptor ||
                  (!result.nativeFinalized && result.alreadyExists));
          ProviderCooldown.instance.noteAttempts(result['provider_attempts']);
          final errorType = BugLog.temporaryErrorType(result['error_type']);
          final failureReason = rejected
              ? 'encrypted output unsupported'
              : providerFailureReasonFor(errorType);
          final message =
              'stage=provider_result '
              'error_type=$errorType '
              'reason=${!usableResult || rejected ? BugLog.temporaryReason(failureReason) : 'none'} '
              'requested_service=${_safeService(request.service)} '
              'requested_provider=${_safeService(request.downloadProvider)} '
              'result_service=${_safeService(result['service'])} '
              'success=${result.success} '
              'native_finalized=${_safeBoolean(result['native_finalized'])} '
              'structured_metadata=${result['decryption'] != null} '
              'legacy_metadata=${result['decryption_key'] != null} '
              'invalid_structured=$invalidStructured invalid_legacy=$invalidLegacy '
              'metadata_rejected=$rejected '
              'message_kind=${_messageKind(result['error_message'] ?? result['error'])} '
              'attempts=${BugLog.sanitizeProviderAttemptDetails(result['provider_attempts']).join(';')}';
          try {
            (diagnostic ?? _logDiagnostic)(message);
          } catch (_) {
            // Diagnostics must never affect preparation.
          }
          if (!usableResult || rejected) {
            final stage = switch (errorType) {
              _ when rejected => TemporaryPipelineStage.finalization,
              'not_found' => TemporaryPipelineStage.matching,
              'quality_unavailable' => TemporaryPipelineStage.quality,
              'verification_required' => TemporaryPipelineStage.verification,
              'provider_unavailable' ||
              'auth' ||
              'authentication_error' ||
              'provider_auth_failed' ||
              'request_auth_invalid' ||
              'provider_reauth_required' => TemporaryPipelineStage.provider,
              _ => TemporaryPipelineStage.download,
            };
            final provider = BugLog.temporaryProvider(result['service']);
            (bugLog ?? BugLog.instance).recordTemporaryPipelineOutcome(
              stage,
              errorType == 'verification_required' && !rejected
                  ? TemporaryPipelineOutcome.required
                  : TemporaryPipelineOutcome.failed,
              provider: provider,
            );
            try {
              unawaited(
                (bugLog ?? BugLog.instance)
                    .recordTemporaryProviderFailure(
                      requestedService: _safeService(request.service),
                      requestedProvider: _safeService(request.downloadProvider),
                      resultService: _safeService(result['service']),
                      finalized: _safeBoolean(result['native_finalized']),
                      success: result.success,
                      metadataChecked: usableResult,
                      structured: result['decryption'] != null,
                      legacy: result['decryption_key'] != null,
                      invalidStructured: invalidStructured,
                      invalidLegacy: invalidLegacy,
                      rejected: rejected,
                      errorType: errorType,
                      reason: failureReason,
                    )
                    .catchError((Object _) {}),
              );
            } catch (_) {
              // Failure reporting must not change the transfer outcome.
            }
          }
          if (!usableResult) {
            if (errorType == 'verification_required') {
              final id = result['service']?.toString().trim() ?? '';
              if (id.isNotEmpty) throw _VerificationRequired(id);
            }
            throw TemporaryTrackException(failureReason);
          }
          if (rejected) {
            throw const TemporaryTrackException('encrypted output unsupported');
          }
          if (hasDecryptionMetadata && !result.nativeFinalized) {
            pending[transferId] = result;
          }
          qualityMetadata[transferId] = result.qualityMetadata;
          return File(filePath);
        } finally {
          await (releaseDirectory ?? PlatformBridge.releaseDownloadDirectory)(
            token,
          );
        }
      },
      cancelDownload: cancelTransfer ?? PlatformBridge.cancelDownload,
      codec: codec,
      validate: validate,
      finalize: (id, input, directory, task) async {
        final result = pending.remove(id);
        if (result == null) return input;
        // Android's vendored bridge filters sensitive logs before forwarding.
        // iOS has no equivalent verified isolation yet.
        if (startFinalization == null &&
            !isDesktopPlatform &&
            !Platform.isAndroid) {
          throw const TemporaryTrackException(
            'private finalization unavailable',
          );
        }
        final finalizationDir = await directory.createTemp('finalization-');
        final safeInput = File(p.join(finalizationDir.path, 'source.bin'));
        await input.copy(safeInput.path);
        _checkCancelled(task);
        final finalizer = DownloadFileFinalizer(
          decryptFile:
              ({
                required inputPath,
                required descriptor,
                required deleteOriginal,
                prepareOutput,
              }) => FFmpegDecryption.decrypt(
                inputPath: inputPath,
                descriptor: descriptor,
                deleteOriginal: deleteOriginal,
                prepareOutput: prepareOutput,
                redactErrors: true,
                executeArguments: (args) async {
                  _checkCancelled(task);
                  // The existing FFmpeg operation passes the key in argv.
                  final session =
                      await (startFinalization ?? FFmpegExecution.start)(args);
                  task.ffmpegSessionId = session.id;
                  try {
                    if (task.cancelled) {
                      _cancelWithoutWaiting(
                        cancelFinalization ?? FFmpegExecution.cancel,
                        session.id,
                      );
                    }
                    final completed = await session.completed;
                    return FFmpegResult(
                      success: completed.success,
                      returnCode: completed.returnCode ?? -1,
                      output: '',
                    );
                  } finally {
                    task.ffmpegSessionId = null;
                  }
                },
              ),
          probeCodec: (_) async => null,
          repairAc4: (_, _) async {},
          replaceSafFile:
              ({
                required uri,
                required treeUri,
                required relativeDir,
                required op,
                bool avoidOverwrite = false,
                String preservedSuffix = '',
                String? collisionCleanFileName,
                String? collisionVariantFileName,
                void Function(String)? onPublishedFileName,
              }) async => null,
          warn: (_) {},
          info: (_) {},
        );
        final outcome = await finalizer.decrypt(
          result: result,
          filePath: safeInput.path,
          useSaf: false,
          relativeDir: '',
          baseName: 'encrypted-source',
          extensionFallback: '.flac',
          repairContainer: false,
        );
        _checkCancelled(task);
        if (outcome.failure != null || outcome.path == null) {
          throw const TemporaryTrackException('finalization failed');
        }
        final actual = await File(outcome.path!).resolveSymbolicLinks();
        if (!p.isWithin(await directory.resolveSymbolicLinks(), actual)) {
          throw const TemporaryTrackException('invalid finalization output');
        }
        // The provider's original encrypted file remains available until the
        // output is validated and the staging directory is disposed.
        // Probe the decrypted stream before invoking the AC-4-specific adapter.
        final extension = p.extension(actual).toLowerCase();
        if ((extension == '.m4a' || extension == '.mp4') &&
            (await (codec ?? FFmpegProbe.audioCodec)(actual))?.toLowerCase() ==
                'ac4') {
          _checkCancelled(task);
          final repaired = await (repairAc4 ?? PlatformBridge.ensureAC4Config)(
            actual,
            input.path,
          );
          if (repaired['success'] != true) {
            throw const TemporaryTrackException('AC-4 repair failed');
          }
          _checkCancelled(task);
        }
        return File(actual);
      },
      cancelSession: cancelFinalization,
      clearPending: (id) {
        pending.remove(id);
        qualityMetadata.remove(id);
      },
      takeQualityMetadata: (id) => qualityMetadata.remove(id) ?? {},
    );
  }

  static void _logDiagnostic(String message) {
    developer.log(message, name: 'temporary_track');
    if (kDebugMode) debugPrint('[temporary_track] $message');
  }

  static String _requestDiagnostic(DownloadRequestPayload request) {
    String presence(String value) => value.trim().isEmpty ? 'empty' : 'present';
    final isrc = request.isrc.trim().toUpperCase();
    final isrcShape = isrc.isEmpty
        ? 'empty'
        : RegExp(r'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$').hasMatch(isrc)
        ? 'compact12'
        : isrc.contains('-') || isrc.contains(' ')
        ? 'hyphenated'
        : 'other';
    final artists = request.artistName
        .split(RegExp(r'[,;&]'))
        .where((part) => part.trim().isNotEmpty)
        .length;
    final seconds = request.durationMs > 0 ? request.durationMs ~/ 1000 : 0;
    return 'stage=request '
        'source=${_safeService(request.source)} '
        'service=${_safeService(request.service)} '
        'provider_track_id=${presence(request.providerTrackId)} '
        'deezer_id=${presence(request.deezerId)} '
        'tidal_id=${presence(request.tidalId)} '
        'qobuz_id=${presence(request.qobuzId)} '
        'spotify_id=${presence(request.spotifyId)} '
        'isrc=$isrcShape '
        'title_annotated=${request.trackName.contains('(') || request.trackName.contains('[')} '
        'artists=$artists '
        'duration_s=$seconds '
        'use_fallback=${request.useFallback}';
  }

  static String _messageKind(Object? value) {
    final text = value is String ? value.toLowerCase() : '';
    if (text.isEmpty) return 'none';
    if (text.contains('stream resolution timeout')) return 'resolution_timeout';
    if (text.contains('download timeout')) return 'download_timeout';
    if (text.contains('verification') || text.contains('captcha')) {
      return 'verification';
    }
    if (text.contains('session')) return 'session';
    if (text.contains('ticket')) return 'ticket';
    if (text.contains('429')) return 'http_429';
    if (text.contains('404')) return 'http_404';
    if (text.contains('403')) return 'http_403';
    if (text.contains('502') || text.contains('503')) return 'http_5xx';
    if (text.contains('timeout') || text.contains('timed out'))
      return 'timeout';
    return 'other';
  }

  static String _safeService(Object? value) {
    if (value is! String) return 'unknown';
    switch (value.toLowerCase()) {
      case 'spotify':
      case 'tidal':
      case 'qobuz':
      case 'deezer':
      case 'youtube':
      case 'soundcloud':
        return value.toLowerCase();
      default:
        return 'unknown';
    }
  }

  static String _safeBoolean(Object? value) => switch (value) {
    true => 'true',
    false => 'false',
    null => 'absent',
    _ => 'invalid',
  };

  final Directory stagingRoot;
  final int bitrateKbps;
  static final _clock = Stopwatch()..start();
  static Duration _elapsed() => _clock.elapsed;

  final Duration timeout;
  final ProviderRequestGate? _gate;
  final Duration Function() _monotonicNow;
  final Future<void> Function(String) _createQuarantineMarker;
  final TemporaryTrackDownload download;
  final TemporaryTrackCancel cancelDownload;
  final Future<bool> Function(String, Future<void>)? _verify;
  final TemporaryTrackCodec _codec;
  final TemporaryTrackCodec _container;
  final bool _injectedProbe;

  static Future<String?> _probeContainer(String path) async {
    try {
      final info = await FFmpegExecution.mediaInformation(path);
      final formats =
          info?.getFormat()?.toLowerCase().split(',') ?? const <String>[];
      if (formats.contains('mp4')) {
        final file = await File(path).open();
        try {
          final header = await file.read(12);
          if (header.length < 12 ||
              String.fromCharCodes(header.sublist(4, 8)) != 'ftyp') {
            return 'mov';
          }
          return String.fromCharCodes(header.sublist(8, 12)) == 'qt  '
              ? 'mov'
              : 'mp4';
        } finally {
          await file.close();
        }
      }
      for (final format in formats) {
        final name = format.trim();
        if (name.isNotEmpty) return name;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  final Future<bool> Function(String)? _validate;
  final Future<File> Function(String, File, Directory, _Preparation)? _finalize;
  final Future<void> Function(int) _cancelSession;
  final Future<({int id, Future<FFmpegSessionResult> completed})> Function(
    List<String>,
  )
  _startSession;
  final void Function(String)? _clearPending;
  final Map<String, Object> Function(String)? _takeQualityMetadata;
  final BugLog _bugLog;
  final Map<String, _Preparation> _active = {};
  static final Set<String> _ownedDirectories = {};
  int _serial = 0;

  /// Removes abandoned directories created by this protocol. Call at startup,
  /// before preparing tracks. Unmarked legacy directories are left untouched.
  Future<void> recoverAbandoned() async {
    await _withRootLock(() async {
      await for (final entry in stagingRoot.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('track-')) {
          continue;
        }
        if (_ownedDirectories.contains(p.normalize(p.absolute(entry.path)))) {
          continue;
        }
        // A desktop FFmpeg child can outlive its parent process. A quarantine
        // left after restart has no reliable proof that the child has stopped.
        if (await File(p.join(entry.path, '.temporary-quarantine')).exists()) {
          continue;
        }
        final marker = File(p.join(entry.path, '.temporary-track-lock'));
        if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final handle = await marker.open(mode: FileMode.append);
        var locked = false;
        try {
          try {
            await handle.lock(FileLock.exclusive);
            locked = true;
          } on FileSystemException {
            continue;
          }
        } finally {
          if (locked) await handle.unlock();
          await handle.close();
        }
        if (locked) await entry.delete(recursive: true);
      }
    });
  }

  Future<T> _withRootLock<T>(Future<T> Function() action) async {
    await stagingRoot.create(recursive: true);
    final handle = await File(
      p.join(stagingRoot.path, '.temporary-root-lock'),
    ).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      return await action();
    } finally {
      await handle.unlock();
      await handle.close();
    }
  }

  ProviderRequestGate get _providerGate =>
      _gate ?? ProviderRequestGate.instance;

  void promote(String id) {
    final task = _active[id];
    if (task == null) return;
    task.priority = ProviderRequestPriority.foreground;
    task.turn?.promote(ProviderRequestPriority.foreground);
  }

  Future<File> _gatedDownload(_Preparation task, Directory directory) async {
    try {
      return await _providerGate.run<File>(
        () => download(directory, task.transferId),
        priority: task.priority,
        cancelled: task.cancelledSignal.future,
        maxTurn: timeout + const Duration(seconds: 15),
        onTimeout: () => cancelDownload(task.transferId),
        onRequested: (turn) => task.turn = turn,
      );
    } on ProviderRequestCancelled {
      throw const TemporaryTrackException('cancelled');
    } on ProviderTurnTimeout {
      throw const TemporaryTrackException('provider timed out');
    } finally {
      task.turn = null;
    }
  }

  Future<PreparedTemporaryTrack> prepare(
    String id, {
    ProviderRequestPriority priority = ProviderRequestPriority.foreground,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    final existing = _active[id];
    if (existing != null) {
      if (priority == ProviderRequestPriority.foreground) promote(id);
      return existing.future;
    }
    final task = _Preparation(
      'temporary-${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
    )..priority = priority;
    _active[id] = task;
    final visible = Completer<PreparedTemporaryTrack>();
    task.future = visible.future;
    var activeDeadline = _monotonicNow() + timeout;
    void expire(String reason) {
      if (!visible.isCompleted && !task.cancelled) {
        visible.completeError(TemporaryTrackException(reason));
        unawaited(cancel(id).catchError((Object _) {}));
      }
    }

    var timer = Timer(timeout, () => expire('preparation timed out'));
    Future<bool> withVerificationBudget(Future<bool> Function() verify) async {
      final verificationStarted = _monotonicNow();
      final remaining = activeDeadline - verificationStarted;
      timer.cancel();
      if (remaining <= Duration.zero) {
        expire('preparation timed out');
        return false;
      }

      const verificationTimeout = Duration(minutes: 3);
      timer = Timer(
        verificationTimeout,
        () => expire('verification timed out'),
      );
      try {
        final accepted = await verify();
        if (_monotonicNow() - verificationStarted >= verificationTimeout) {
          expire('verification timed out');
          return false;
        }
        return accepted;
      } finally {
        timer.cancel();
        if (!task.cancelled) {
          activeDeadline = _monotonicNow() + remaining;
          timer = Timer(remaining, () => expire('preparation timed out'));
        }
      }
    }

    Timer? cancelTimer;
    task.cancelledSignal.future.then((_) {
      cancelTimer = Timer(const Duration(seconds: 2), () {
        if (!visible.isCompleted) {
          visible.completeError(const TemporaryTrackException('cancelled'));
        }
      });
    });
    // The internal operation retains its staging lock until every native call
    // actually returns. A timeout only releases the caller, never that lock.
    _run(task, withVerificationBudget)
        .then(
          (result) async {
            // A completion may be dispatched before an already-due timer.
            if (_monotonicNow() >= activeDeadline) {
              expire('preparation timed out');
            }
            if (task.cancelled && !visible.isCompleted) {
              visible.completeError(const TemporaryTrackException('cancelled'));
            }
            if (visible.isCompleted) {
              await result.dispose();
            } else {
              visible.complete(result);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!visible.isCompleted) visible.completeError(error, stack);
          },
        )
        .whenComplete(() {
          timer.cancel();
          cancelTimer?.cancel();
          if (identical(_active[id], task)) _active.remove(id);
        });
    return task.future;
  }

  /// Cancels the shared transfer for every caller waiting on this id.
  Future<void> cancel(String id) async {
    final task = _active[id];
    if (task == null || task.cancelled) return;
    task.cancelled = true;
    task.cancelledSignal.complete();
    final sessionId = task.ffmpegSessionId;
    try {
      await Future.wait([
        Future<void>.sync(() => cancelDownload(task.transferId)),
        if (sessionId != null)
          Future<void>.sync(() => _cancelSession(sessionId)),
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Cancellation is best effort. Never include native error details: they
      // can contain provider information. _run retains ownership until the
      // underlying operation actually finishes.
      _logDiagnostic('stage=cancel result=failed_or_timed_out');
    }
  }

  static Future<void> _writeQuarantineMarker(String path) async {
    await File(path).writeAsString('', flush: true);
  }

  Future<PreparedTemporaryTrack> _run(
    _Preparation task,
    Future<bool> Function(Future<bool> Function()) withVerificationBudget,
  ) async {
    Directory? dir;
    RandomAccessFile? marker;
    var stage = TemporaryPipelineStage.fileAccess;
    Object? provider;
    var afterGrant = false;
    void report(TemporaryPipelineOutcome outcome) => _bugLog
        .recordTemporaryPipelineOutcome(stage, outcome, provider: provider);
    try {
      await _withRootLock(() async {
        dir = await stagingRoot.createTemp('track-');
        // Persist protection before starting any download or native process.
        // If this fails, no process capable of outliving us has been started.
        await _createQuarantineMarker(
          p.join(dir!.path, '.temporary-quarantine'),
        );
        _ownedDirectories.add(p.normalize(p.absolute(dir!.path)));
        marker = await File(
          p.join(dir!.path, '.temporary-track-lock'),
        ).open(mode: FileMode.append);
        await marker!.lock(FileLock.exclusive);
      });
      final workingDirectory = dir!;
      _checkCancelled(task);
      stage = TemporaryPipelineStage.download;
      File input;
      try {
        input = await _gatedDownload(task, workingDirectory);
      } on _VerificationRequired catch (error) {
        _checkCancelled(task);
        stage = TemporaryPipelineStage.verification;
        provider = error.extensionId;
        final verify = _verify;
        var verified = false;
        if (verify != null) {
          try {
            verified = await withVerificationBudget(
              () => verify(error.extensionId, task.cancelledSignal.future),
            );
          } catch (_) {
            // Browser failures must not expose provider or callback details.
          }
        }
        _checkCancelled(task);
        if (!verified) {
          report(TemporaryPipelineOutcome.failed);
          throw TemporaryVerificationRequired(error.extensionId);
        }
        _checkCancelled(task);
        report(TemporaryPipelineOutcome.accepted);
        afterGrant = true;
        provider = null;
        stage = TemporaryPipelineStage.download;
        input = await _gatedDownload(task, workingDirectory);
      }
      _checkCancelled(task);
      final qualityMetadata = _takeQualityMetadata?.call(task.transferId) ?? {};
      provider = qualityMetadata['provider'];
      if (afterGrant) report(TemporaryPipelineOutcome.completed);
      stage = TemporaryPipelineStage.fileAccess;
      // A provider must only return its own private staging file.
      final root = await workingDirectory.resolveSymbolicLinks();
      final actual = await input.resolveSymbolicLinks();
      if (!p.isWithin(root, actual) ||
          !await input.exists() ||
          await input.length() == 0) {
        throw const TemporaryTrackException('invalid provider output');
      }
      stage = TemporaryPipelineStage.finalization;
      input =
          await (_finalize?.call(
                task.transferId,
                input,
                workingDirectory,
                task,
              ) ??
              Future.value(input));
      _checkCancelled(task);
      final outputDir = await workingDirectory.createTemp('output-');
      var copied = File(p.join(outputDir.path, 'source.bin'));
      await input.copy(copied.path);
      _checkCancelled(task);
      if (afterGrant) report(TemporaryPipelineOutcome.completed);
      stage = TemporaryPipelineStage.fileAccess;
      if (await copied.length() == 0 ||
          await sha256.bind(input.openRead()).first !=
              await sha256.bind(copied.openRead()).first) {
        _checkCancelled(task);
        throw const TemporaryTrackException('invalid temporary copy');
      }
      _checkCancelled(task);
      final forced = _injectedProbe ? null : await _localDemuxer(copied);
      final probe = forced == null
          ? null
          : await _restrictedProbe(task, copied.path, forced);
      final codec = forced == null
          ? (await _codec(copied.path))?.toLowerCase()
          : probe;
      _checkCancelled(task);
      if (codec == null || codec.isEmpty) {
        throw const TemporaryTrackException('audio stream not identified');
      }
      var container = forced ?? (await _container(copied.path))?.toLowerCase();
      _checkCancelled(task);
      if (codec == 'flac' && container == 'mp4') {
        // Lossless DASH delivers FLAC inside fragmented MP4; the player needs
        // a plain FLAC stream, so copy the audio packets into one.
        final remuxed = File(p.join(outputDir.path, 'remuxed.flac'));
        final remuxOk = await _runFfmpeg(task, [
          '-v',
          'error',
          '-protocol_whitelist',
          'file',
          '-i',
          copied.path,
          '-map',
          '0:a:0',
          '-c:a',
          'copy',
          '-f',
          'flac',
          remuxed.path,
          '-y',
        ]);
        _checkCancelled(task);
        if (!remuxOk ||
            !await remuxed.exists() ||
            await remuxed.length() == 0) {
          throw const TemporaryTrackException('flac remux failed');
        }
        await copied.delete();
        copied = remuxed;
        container = 'flac';
      }
      final extension = playableAudioExtension(codec, container);
      if (extension == null) {
        throw const TemporaryTrackException('unsupported audio format');
      }
      final validated =
          await (_validate?.call(copied.path) ??
              (codec == 'ac4'
                  ? Ac4StructureCheck.isValid(copied.path)
                  : _runFfmpeg(task, _validateArguments(copied.path, forced))));
      _checkCancelled(task);
      if (!validated) {
        throw const TemporaryTrackException('invalid audio output');
      }
      final output = await copied.rename(
        p.join(outputDir.path, 'prepared$extension'),
      );
      await File(
        p.join(workingDirectory.path, '.temporary-quarantine'),
      ).delete();
      final result =
          PreparedTemporaryTrack._(output, workingDirectory, marker!, {
            ...qualityMetadata,
            'output_codec': codec,
            'output_decode_validated': true,
            'output_container': container!,
          });
      if (afterGrant) report(TemporaryPipelineOutcome.completed);
      marker = null;
      dir = null;
      return result;
    } on TemporaryTrackException catch (error) {
      if (task.cancelled && afterGrant) {
        report(TemporaryPipelineOutcome.cancelled);
      }
      if (!task.cancelled && !providerResultReasons.contains(error.reason)) {
        report(TemporaryPipelineOutcome.failed);
        _logDiagnostic(
          'stage=preparation reason=${BugLog.temporaryReason(error.reason)}',
        );
        unawaited(_bugLog.recordPreparationFailure(reason: error.reason));
      }
      rethrow;
    } catch (_) {
      if (!task.cancelled || afterGrant) {
        report(
          task.cancelled
              ? TemporaryPipelineOutcome.cancelled
              : TemporaryPipelineOutcome.failed,
        );
      }
      if (!task.cancelled) {
        _logDiagnostic('stage=preparation reason=preparation_failed');
        unawaited(
          _bugLog.recordPreparationFailure(reason: 'preparation failed'),
        );
      }
      // Never expose provider errors, URLs or credentials to callers or logs.
      throw TemporaryTrackException(
        task.cancelled ? 'cancelled' : 'preparation failed',
      );
    } finally {
      _clearPending?.call(task.transferId);
      if (marker != null) {
        await marker!.unlock();
        await marker!.close();
      }
      if (dir != null) {
        _ownedDirectories.remove(p.normalize(p.absolute(dir!.path)));
      }
      final cleanupDir = dir;
      if (cleanupDir != null && await cleanupDir.exists()) {
        await cleanupDir.delete(recursive: true);
      }
    }
  }

  static void _checkCancelled(_Preparation task) {
    if (task.cancelled) throw const TemporaryTrackException('cancelled');
  }

  static List<String> _validateArguments(String input, String? forced) => [
    '-v',
    'error',
    '-xerror',
    if (forced != null) ...[
      '-protocol_whitelist',
      'file',
      '-format_whitelist',
      forced,
      '-f',
      forced,
    ],
    '-i',
    input,
    '-map',
    '0:a:0',
    '-f',
    'null',
    '-',
  ];

  static Future<String?> _localDemuxer(File file) async {
    final handle = await file.open();
    try {
      final header = await handle.read(12);
      if (header.length >= 12 &&
          String.fromCharCodes(header.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(header.sublist(8, 12)) == 'WAVE')
        return 'wav';
      if (header.length >= 4 &&
          String.fromCharCodes(header.sublist(0, 4)) == 'OggS')
        return 'ogg';
      return null;
    } finally {
      await handle.close();
    }
  }

  Future<String?> _restrictedProbe(
    _Preparation task,
    String path,
    String demuxer,
  ) async {
    final args = [
      '-v',
      'error',
      '-protocol_whitelist',
      'file',
      '-format_whitelist',
      demuxer,
      '-f',
      demuxer,
      '-show_streams',
      '-print_format',
      'json',
      '-i',
      path,
    ];
    final ({int id, Future<FFmpegSessionResult> completed}) session;
    if (isDesktopPlatform) {
      session = await DesktopFFmpegRunner.shared.startProbe(args);
    } else {
      final done = Completer<FFmpegSessionResult>();
      final probe = await FFprobeKit.executeWithArgumentsAsync(args, (
        session,
      ) async {
        final code = (await session.getReturnCode())?.getValue();
        final output = await session.getOutput() ?? '';
        if (!done.isCompleted)
          done.complete(
            FFmpegSessionResult(returnCode: code, logs: () async => output),
          );
      });
      final id = probe.getSessionId();
      if (id == null) {
        await done.future;
        throw StateError('FFprobe session has no ID');
      }
      session = (id: id, completed: done.future);
    }
    task.ffmpegSessionId = session.id;
    try {
      if (task.cancelled) _cancelWithoutWaiting(_cancelSession, session.id);
      final result = await session.completed;
      if (!result.success) return null;
      final decoded = jsonDecode(await result.logs());
      if (decoded is! Map || decoded['streams'] is! List) return null;
      for (final stream in decoded['streams'] as List) {
        if (stream is Map &&
            stream['codec_type'] == 'audio' &&
            stream['codec_name'] is String) {
          return (stream['codec_name'] as String).toLowerCase();
        }
      }
      return null;
    } on FormatException {
      return null;
    } finally {
      task.ffmpegSessionId = null;
    }
  }

  static void _cancelWithoutWaiting(Future<void> Function(int) cancel, int id) {
    unawaited(Future<void>.sync(() => cancel(id)).catchError((Object _) {}));
  }

  Future<bool> _runFfmpeg(_Preparation task, List<String> args) async {
    _checkCancelled(task);
    final session = await _startSession(args);
    task.ffmpegSessionId = session.id;
    try {
      // Cancellation may have arrived while the session was starting.
      if (task.cancelled) _cancelWithoutWaiting(_cancelSession, session.id);
      return (await session.completed).success;
    } finally {
      task.ffmpegSessionId = null;
    }
  }
}

class _Preparation {
  _Preparation(this.transferId);
  final String transferId;
  bool cancelled = false;
  final Completer<void> cancelledSignal = Completer<void>();
  ProviderRequestPriority priority = ProviderRequestPriority.foreground;
  ProviderTurn? turn;
  int? ffmpegSessionId;
  late Future<PreparedTemporaryTrack> future;
}
