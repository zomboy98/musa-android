import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Whether this build ships any bundled add-on packages.
Future<bool> hasBundledExtensions({AssetBundle? bundle}) async {
  try {
    final manifest =
        jsonDecode(
              await (bundle ?? rootBundle).loadString(
                'assets/bundled_extensions/manifest.json',
              ),
            )
            as Map<String, dynamic>;
    return (manifest['extensions'] as List).isNotEmpty;
  } catch (_) {
    return false;
  }
}

List<int> _versionParts(String version) => [
  for (final part in version.split(RegExp(r'[.+-]')))
    int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
];

/// Whether [bundled] is newer than [installed]; an unknown installed version
/// counts as older.
bool bundledVersionIsNewer(String? installed, String bundled) {
  if (installed == null || installed.isEmpty) return true;
  final a = _versionParts(installed);
  final b = _versionParts(bundled);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return y > x;
  }
  return false;
}

String _short(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ');
  return text.length > 160 ? text.substring(0, 160) : text;
}

/// Install missing packages and upgrade installed ones whose bundled version
/// is newer. With [installMissing] false only installed packages are touched.
Future<void> bootstrapBundledExtensions({
  required String dataDir,
  required Map<String, String> installedStatuses,
  Map<String, String> installedVersions = const {},
  required Future<void> Function(String path, String id) install,
  required void Function(String message) report,
  void Function(String message)? log,
  AssetBundle? bundle,
  bool includePreviouslyRemoved = false,
  bool installMissing = true,
}) async {
  final assets = bundle ?? rootBundle;
  final emit = log ?? (message) => debugPrint(message);
  final manifest =
      jsonDecode(
            await assets.loadString('assets/bundled_extensions/manifest.json'),
          )
          as Map<String, dynamic>;
  final entries = (manifest['extensions'] as List).cast<Map<String, dynamic>>();
  final markerDir = Directory(p.join(dataDir, '.bundled-extension-attempts'));
  await markerDir.create(recursive: true);
  for (final entry in entries) {
    final id = entry['id'] as String;
    final file = entry['file'] as String;
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(id) ||
        !RegExp(r'^[a-z0-9-]+\.sflx$').hasMatch(file)) {
      throw const FormatException('Invalid bundled extension manifest');
    }
    final marker = File(p.join(markerDir.path, id));
    final status = installedStatuses[id.toLowerCase()];
    final version = entry['version']?.toString() ?? '';
    final installed = installedVersions[id.toLowerCase()];
    final upgradeMarker = File(p.join(markerDir.path, '$id.upgraded'));
    final needsUpgrade =
        status != null &&
        entry['upgrade'] == true &&
        version.isNotEmpty &&
        bundledVersionIsNewer(installed, version) &&
        !(await upgradeMarker.exists() &&
            await upgradeMarker.readAsString() == version);
    void line(String result) => emit(
      'bundled: id=$id installed=${installed == null || status == null ? 'none' : installed} '
      'bundled=$version upgrade=$needsUpgrade result=$result',
    );
    if (status == 'error' && !needsUpgrade) {
      report('Bundled extension $id remains installed with an error');
      line('skipped');
      continue;
    }
    if (status != null && !needsUpgrade) {
      await marker.writeAsString('done', flush: true);
      line('skipped');
      continue;
    }
    if (status == null && !installMissing) {
      line('skipped');
      continue;
    }
    if (!needsUpgrade &&
        !includePreviouslyRemoved &&
        await marker.exists() &&
        await marker.readAsString() == 'done') {
      line('skipped');
      continue;
    }
    // Verify packaged bytes before allowing the native installer to handle them.
    try {
      final data = await assets.load('assets/bundled_extensions/$file');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (sha256.convert(bytes).toString() != entry['sha256']) {
        throw StateError('SHA-256 mismatch');
      }
      if (!needsUpgrade) await marker.writeAsString('pending', flush: true);
      final scratch = await Directory.systemTemp.createTemp('mornye_bundle_');
      try {
        final package = File(p.join(scratch.path, file));
        await package.writeAsBytes(bytes, flush: true);
        await install(package.path, id);
        if (needsUpgrade) {
          await upgradeMarker.writeAsString(version, flush: true);
        }
        await marker.writeAsString('done', flush: true);
        line(needsUpgrade ? 'upgraded' : 'installed');
      } finally {
        await scratch.delete(recursive: true);
      }
    } catch (error) {
      report('Bundled extension $id: $error');
      line('failed:${_short(error)}');
    }
  }
}
