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
