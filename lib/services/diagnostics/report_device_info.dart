import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:mornye/constants/app_info.dart';

typedef ReportDeviceReading = ({
  String model,
  String release,
  int sdk,
  String abi,
});

class ReportDeviceInfo {
  const ReportDeviceInfo({
    required this.model,
    required this.systemRelease,
    required this.sdk,
    required this.abi,
    required this.appVersion,
    required this.locale,
  });

  final String model;
  final String systemRelease;
  final int sdk;
  final String abi;
  final String appVersion;
  final String locale;

  static String get currentAppVersion =>
      '${AppInfo.version}+${AppInfo.buildNumber}';

  int get osMajor {
    final major = int.tryParse(
      RegExp(r'^\d+').firstMatch(systemRelease)?[0] ?? '',
    );
    if (major != null && major >= 1 && major <= 99) return major;
    return sdk >= 1 && sdk <= 99 ? sdk : 1;
  }

  String toText() => [
    'MUSA: $appVersion',
    'Dispositivo: $model',
    'Android: $systemRelease (API $sdk)',
    'ABI: $abi',
    'Idioma: $locale',
  ].join('\n');

  static Future<ReportDeviceInfo> collect({
    required String locale,
    Future<ReportDeviceReading> Function()? reader,
    String? appVersion,
  }) async {
    ReportDeviceReading reading;
    try {
      reading = await (reader ?? _read)();
    } catch (_) {
      reading = (
        model: 'desconocido',
        release: Platform.operatingSystem,
        sdk: 0,
        abi: 'desconocida',
      );
    }
    return ReportDeviceInfo(
      model: _short(reading.model),
      systemRelease: _short(reading.release),
      sdk: reading.sdk,
      abi: _short(reading.abi),
      appVersion: appVersion ?? currentAppVersion,
      locale: _short(locale),
    );
  }

  static String _short(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9 ._+()-]'), '').trim();
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  static Future<ReportDeviceReading> _read() async {
    if (!Platform.isAndroid) {
      return (
        model: Platform.operatingSystem,
        release: Platform.operatingSystemVersion,
        sdk: 0,
        abi: 'n/a',
      );
    }
    final android = await DeviceInfoPlugin().androidInfo;
    return (
      model: '${android.manufacturer} ${android.model}',
      release: android.version.release,
      sdk: android.version.sdkInt,
      abi: android.supportedAbis.isEmpty
          ? 'desconocida'
          : android.supportedAbis.first,
    );
  }
}
