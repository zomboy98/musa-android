import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/feedback/feedback_sanitizer.dart';

typedef FeedbackDeviceInfo = ({String device, String system});

class FeedbackDiagnostics {
  const FeedbackDiagnostics({
    required this.appVersion,
    required this.build,
    required this.commit,
    required this.device,
    required this.system,
    required this.locale,
    required this.quality,
    required this.provider,
    required this.log,
  });

  final String appVersion;
  final String build;
  final String commit;
  final String device;
  final String system;
  final String locale;
  final String quality;
  final String provider;
  final List<String> log;

  static const defaultLogLimit = 20;

  static Future<FeedbackDiagnostics> collect({
    required String locale,
    String quality = '',
    String provider = '',
    int logLimit = defaultLogLimit,
    BugLog? bugLog,
    Future<FeedbackDeviceInfo> Function()? deviceInfo,
  }) async {
    final info = await _safeDevice(deviceInfo ?? _readDevice);
    List<Map<String, String>> entries;
    try {
      entries = await (bugLog ?? BugLog.instance).entries();
    } catch (_) {
      entries = const [];
    }
    return FeedbackDiagnostics(
      appVersion: AppInfo.version,
      build: AppInfo.buildNumber,
      commit: AppInfo.shortGitCommit,
      device: FeedbackSanitizer.cleanLine(info.device, maxLength: 80),
      system: FeedbackSanitizer.cleanLine(info.system, maxLength: 80),
      locale: FeedbackSanitizer.cleanLine(locale, maxLength: 16),
      quality: _token(quality),
      provider: provider.isEmpty ? '' : BugLog.temporaryProvider(provider),
      log: FeedbackSanitizer.cleanLogEntries(entries, limit: logLimit),
    );
  }

  static String _token(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_.\- ]'), '').trim();
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  static Future<FeedbackDeviceInfo> _safeDevice(
    Future<FeedbackDeviceInfo> Function() read,
  ) async {
    try {
      return await read();
    } catch (_) {
      return (device: '', system: Platform.operatingSystem);
    }
  }

  static Future<FeedbackDeviceInfo> _readDevice() async {
    if (Platform.isAndroid) {
      final android = await DeviceInfoPlugin().androidInfo;
      return (
        device: '${android.manufacturer} ${android.model}',
        system:
            'Android ${android.version.release} '
            '(API ${android.version.sdkInt})',
      );
    }
    return (device: '', system: Platform.operatingSystem);
  }

  String toText() {
    final lines = <String>[
      'Version de la app: $appVersion ($build)',
      if (commit.isNotEmpty) 'Commit: $commit',
      if (device.isNotEmpty) 'Dispositivo: $device',
      if (system.isNotEmpty) 'Sistema: $system',
      if (locale.isNotEmpty) 'Idioma: $locale',
      if (quality.isNotEmpty) 'Calidad activa: $quality',
      if (provider.isNotEmpty) 'Proveedor activo: $provider',
      'Registro reciente: ${log.isEmpty ? 'sin fallos' : '${log.length} entradas'}',
      for (final line in log) '  - $line',
    ];
    return lines.join('\n');
  }
}
