/// Public label shown to people. It is display text only: the real
/// versionName and versionCode keep following pubspec.yaml.
const String musaPublicLabel = 'v0.9 beta 1';

/// Turns a public version such as `0.9.0-beta.2` into its label
/// (`v0.9 beta 2`); `1.0.0` reads `v1.0`. Anything else is returned as is.
String formatPublicLabel(String version) {
  final match = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
  ).firstMatch(version.trim());
  if (match == null) return version;
  final base = match.group(3) == '0'
      ? '${match.group(1)}.${match.group(2)}'
      : '${match.group(1)}.${match.group(2)}.${match.group(3)}';
  final pre = match.group(4);
  return 'v$base${pre == null ? '' : ' ${pre.replaceAll('.', ' ')}'}';
}
