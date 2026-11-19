import 'package:mornye/constants/plugin_code_api.dart';

const String musaApiBaseUrl = String.fromEnvironment(
  'MUSA_API_BASE',
  defaultValue: 'https://$pluginCodeApiHost',
);

const String musaFeedbackPath = '/v1/feedback';
const String musaMetricsPath = '/v1/m';

Uri musaApiUri(String path, {String base = musaApiBaseUrl}) {
  final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return Uri.parse('$root$path');
}

String get musaApiHostLabel => Uri.parse(musaApiBaseUrl).host;

/// The only source the app consults for new builds.
class AppUpdateEndpoints {
  static const String host = 'musa.heyshin.app';
  static const String latestUrl = 'https://$host/latest.json';
  static const String releaseHost = 'github.com';
  static const String releasePathPrefix = '/zomboy98/musa-android/';
}
