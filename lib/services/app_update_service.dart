import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/constants/api_endpoints.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/constants/app_version.dart';
import 'package:mornye/services/native_file_hash.dart';
import 'package:mornye/utils/logger.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('AppUpdate');

final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

/// A build published in `latest.json`, already validated.
class AppUpdateOffer {
  const AppUpdateOffer({
    required this.label,
    required this.version,
    required this.build,
    required this.channel,
    required this.notes,
    required this.apkUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.publishedAt,
  });

  /// Public name shown to people, e.g. `v0.9 beta 3`.
  final String label;
  final String version;
  final int build;
  final String channel;
  final String notes;
  final Uri apkUrl;
  final String sha256;
  final int sizeBytes;
  final String publishedAt;
}

/// Public label for the `etiqueta` field: `0.9 beta 3` reads `v0.9 beta 3`.
String appUpdateLabel(String etiqueta) {
  final formatted = formatPublicLabel(etiqueta.trim());
  return formatted.startsWith('v') || formatted.startsWith('V')
      ? formatted
      : 'v$formatted';
}

/// Validates the manifest; anything unexpected returns null.
AppUpdateOffer? parseAppUpdateManifest(String body) {
  try {
    if (body.length > 64 * 1024) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final etiqueta = decoded['etiqueta'];
    final build = decoded['build'];
    final sha = decoded['sha256'];
    final size = decoded['size_bytes'];
    final apk = decoded['apk_url'];
    if (etiqueta is! String ||
        etiqueta.trim().isEmpty ||
        etiqueta.length > 64) {
      return null;
    }
    if (build is! int || build <= 0) return null;
    if (size is! int || size <= 0) return null;
    if (sha is! String) return null;
    final digest = sha.trim().toLowerCase();
    if (!_sha256Pattern.hasMatch(digest)) return null;
    if (apk is! String) return null;
    final uri = Uri.tryParse(apk);
    if (uri == null || !isAllowedAppUpdateApkUrl(uri)) return null;
    String text(Object? value, int max) {
      final trimmed = value is String ? value.trim() : '';
      return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
    }

    return AppUpdateOffer(
      label: appUpdateLabel(etiqueta),
      version: text(decoded['version'], 32),
      build: build,
      channel: text(decoded['canal'], 32),
      notes: text(decoded['notes'], 4000),
      apkUrl: uri,
      sha256: digest,
      sizeBytes: size,
      publishedAt: text(decoded['published_at'], 32),
    );
  } on Object {
    return null;
  }
}

/// The APK may only come from MUSA's own release repository or site.
bool isAllowedAppUpdateApkUrl(Uri uri) {
  if (uri.scheme != 'https' || uri.hasPort && uri.port != 443) return false;
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.host == AppUpdateEndpoints.host) return true;
  return uri.host == AppUpdateEndpoints.releaseHost &&
      uri.path.startsWith(AppUpdateEndpoints.releasePathPrefix);
}

enum AppUpdateStatus { available, upToDate, snoozed, unavailable }

class AppUpdateCheck {
  const AppUpdateCheck(this.status, [this.offer]);
  final AppUpdateStatus status;
  final AppUpdateOffer? offer;
}

enum AppUpdateFailure {
  network,
  hashMismatch,
  insufficientSpace,
  incomplete,
  cancelled,
  permissionRequired,
  installerUnavailable,
  generic,
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.failure, [this.detail]);
  final AppUpdateFailure failure;
  final String? detail;

  @override
  String toString() =>
      'AppUpdateException($failure${detail == null ? '' : ': $detail'})';
}

class AppUpdateCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// What the service needs from the Android package.
abstract class AppUpdatePlatform {
  bool get isAndroid;
  Future<int?> installedBuild();
  Future<bool> canInstallPackages();
  Future<void> openInstallPermissionSettings();
  Future<int?> freeBytes(String path);
  Future<Directory> updateDirectory();
  Future<bool> openInstaller(String path);
}

class MethodChannelAppUpdatePlatform implements AppUpdatePlatform {
  const MethodChannelAppUpdatePlatform();

  static const _channel = MethodChannel('musa/app_update');

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  Future<int?> installedBuild() async {
    try {
      return await _channel.invokeMethod<int>('installedBuild');
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> openInstallPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  @override
  Future<int?> freeBytes(String path) async {
    try {
      final free = await _channel.invokeMethod<int>('freeBytes', {
        'path': path,
      });
      return free == null || free < 0 ? null : free;
    } on Object {
      return null;
    }
  }

  @override
  Future<Directory> updateDirectory() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}updates');
  }

  @override
  Future<bool> openInstaller(String path) async {
    final result = await OpenFilex.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  }
}

typedef FileHasher = Future<String> Function(String path);

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    AppUpdatePlatform platform = const MethodChannelAppUpdatePlatform(),
    FileHasher hashFile = hashFileSha256,
    DateTime Function()? now,
    Uri? manifestUrl,
    bool? enabled,
  }) : _client = client,
       _platform = platform,
       _hashFile = hashFile,
       _now = now ?? DateTime.now,
       _manifestUrl = manifestUrl ?? Uri.parse(AppUpdateEndpoints.latestUrl),
       _enabled = enabled ?? AppInfo.selfUpdatesEnabled;

  static const snoozeDuration = Duration(hours: 24);
  static const _snoozeBuildKey = 'app_update_snoozed_build';
  static const _snoozeUntilKey = 'app_update_snoozed_until_ms';
  static const _requestTimeout = Duration(seconds: 15);
  static const _streamIdleTimeout = Duration(seconds: 60);
  static const _spaceMargin = 32 * 1024 * 1024;

  final http.Client? _client;
  final AppUpdatePlatform _platform;
  final FileHasher _hashFile;
  final DateTime Function() _now;
  final Uri _manifestUrl;
  final bool _enabled;

  Future<AppUpdateCheck> checkForUpdate({bool ignoreSnooze = false}) async {
    const unavailable = AppUpdateCheck(AppUpdateStatus.unavailable);
    if (!_enabled || !_platform.isAndroid) return unavailable;
    if (_manifestUrl.scheme != 'https' ||
        _manifestUrl.host != AppUpdateEndpoints.host) {
      return unavailable;
    }
    final installed = await _platform.installedBuild();
    if (installed == null) return unavailable;

    final owned = _client == null;
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(_manifestUrl, headers: const {'Accept': 'application/json'})
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return unavailable;
      final offer = parseAppUpdateManifest(utf8.decode(response.bodyBytes));
      if (offer == null) return unavailable;
      if (offer.build <= installed) {
        return const AppUpdateCheck(AppUpdateStatus.upToDate);
      }
      if (!ignoreSnooze && await isSnoozed(offer.build)) {
        return AppUpdateCheck(AppUpdateStatus.snoozed, offer);
      }
      return AppUpdateCheck(AppUpdateStatus.available, offer);
    } on Object catch (error) {
      _log.w('Update check failed: $error');
      return unavailable;
    } finally {
      if (owned) client.close();
    }
  }

  Future<bool> isSnoozed(int build) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_snoozeBuildKey) != build) return false;
      final until = prefs.getInt(_snoozeUntilKey) ?? 0;
      return _now().millisecondsSinceEpoch < until;
    } on Object {
      return false;
    }
  }

  Future<void> snooze(int build) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_snoozeBuildKey, build);
      await prefs.setInt(
        _snoozeUntilKey,
        _now().add(snoozeDuration).millisecondsSinceEpoch,
      );
    } on Object catch (error) {
      _log.w('Could not remember the postponed update: $error');
    }
  }

  Future<bool> canInstallPackages() => _platform.canInstallPackages();

  Future<void> openInstallPermissionSettings() =>
      _platform.openInstallPermissionSettings();

  /// Downloads the APK and verifies size and SHA-256. A file that fails either
  /// check is deleted and never returned.
  Future<File> download(
    AppUpdateOffer offer, {
    void Function(int received, int total)? onProgress,
    AppUpdateCancelToken? cancel,
  }) async {
    final directory = await _platform.updateDirectory();
    await directory.create(recursive: true);
    await _clearOldFiles(directory);

    final free = await _platform.freeBytes(directory.path);
    if (free != null && free < offer.sizeBytes + _spaceMargin) {
      throw const AppUpdateException(AppUpdateFailure.insufficientSpace);
    }

    final target = File(
      '${directory.path}${Platform.pathSeparator}musa-${offer.build}.apk',
    );
    final part = File('${target.path}.part');
    final owned = _client == null;
    final client = _client ?? http.Client();
    IOSink? sink;
    try {
      final response = await client
          .send(http.Request('GET', offer.apkUrl))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw AppUpdateException(
          AppUpdateFailure.network,
          'HTTP ${response.statusCode}',
        );
      }
      sink = part.openWrite();
      var received = 0;
      onProgress?.call(0, offer.sizeBytes);
      await for (final chunk in response.stream.timeout(_streamIdleTimeout)) {
        if (cancel?.isCancelled ?? false) {
          throw const AppUpdateException(AppUpdateFailure.cancelled);
        }
        sink.add(chunk);
        received += chunk.length;
        if (received > offer.sizeBytes) {
          throw const AppUpdateException(AppUpdateFailure.incomplete);
        }
        onProgress?.call(received, offer.sizeBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancel?.isCancelled ?? false) {
        throw const AppUpdateException(AppUpdateFailure.cancelled);
      }
      if (received != offer.sizeBytes) {
        throw const AppUpdateException(AppUpdateFailure.incomplete);
      }
      final actual = (await _hashFile(part.path)).toLowerCase();
      if (actual != offer.sha256) {
        throw const AppUpdateException(AppUpdateFailure.hashMismatch);
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      return target;
    } on AppUpdateException {
      await _discard(sink, part);
      rethrow;
    } on TimeoutException catch (error) {
      await _discard(sink, part);
      throw AppUpdateException(AppUpdateFailure.network, '$error');
    } on SocketException catch (error) {
      await _discard(sink, part);
      throw AppUpdateException(AppUpdateFailure.network, '$error');
    } on http.ClientException catch (error) {
      await _discard(sink, part);
      throw AppUpdateException(AppUpdateFailure.network, '$error');
    } on FileSystemException catch (error) {
      await _discard(sink, part);
      final full = (error.osError?.errorCode ?? 0) == 28;
      throw AppUpdateException(
        full ? AppUpdateFailure.insufficientSpace : AppUpdateFailure.generic,
        '$error',
      );
    } on Object catch (error) {
      await _discard(sink, part);
      throw AppUpdateException(AppUpdateFailure.generic, '$error');
    } finally {
      if (owned) client.close();
    }
  }

  /// Hands a verified APK to the system installer.
  Future<void> install(File apk) async {
    if (!await _platform.canInstallPackages()) {
      throw const AppUpdateException(AppUpdateFailure.permissionRequired);
    }
    if (!await _platform.openInstaller(apk.path)) {
      throw const AppUpdateException(AppUpdateFailure.installerUnavailable);
    }
  }

  Future<void> _discard(IOSink? sink, File part) async {
    try {
      await sink?.close();
    } on Object {
      // The partial file is removed below regardless.
    }
    try {
      if (await part.exists()) await part.delete();
    } on Object catch (error) {
      _log.w('Could not remove partial update: $error');
    }
  }

  Future<void> _clearOldFiles(Directory directory) async {
    try {
      await for (final entry in directory.list()) {
        if (entry is File &&
            (entry.path.endsWith('.apk') || entry.path.endsWith('.part'))) {
          await entry.delete();
        }
      }
    } on Object catch (error) {
      _log.w('Could not clear old update files: $error');
    }
  }
}
