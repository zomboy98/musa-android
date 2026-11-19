import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/bundled_extensions.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all included packages load in the real native extension engine', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await support.createTemp('bundled-native-test-');
    final sources = await Directory('${root.path}/sources').create();
    final data = await Directory('${root.path}/data').create();
    addTearDown(() async {
      await PlatformBridge.cleanupExtensions();
      await root.delete(recursive: true);
    });
    expect(
      (await PlatformBridge.getBackendImplementations())['extensions'],
      'rust',
    );
    await PlatformBridge.initExtensionSystem(
      sources.path,
      data.path,
      masterKey: base64Encode(List.filled(32, 7)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
    );
    final manifest =
        jsonDecode(
              await rootBundle.loadString(
                'assets/bundled_extensions/manifest.json',
              ),
            )
            as Map<String, dynamic>;
    final expected = (manifest['extensions'] as List)
        .cast<Map<String, dynamic>>()
        .map((entry) => entry['id'] as String)
        .toSet();
    final errors = <String>[];
    await bootstrapBundledExtensions(
      dataDir: data.path,
      installedStatuses: {},
      install: (path, id) async {
        await PlatformBridge.loadExtensionFromPath(path);
        final installed = await PlatformBridge.getInstalledExtensions();
        expect(
          installed.singleWhere((entry) => entry['id'] == id)['status'],
          'loaded',
        );
      },
      report: errors.add,
    );
    final installed = await PlatformBridge.getInstalledExtensions();
    binding.reportData = {
      'engine': 'rust',
      'extensions': installed
          .map(
            (entry) => {
              'id': entry['id'],
              'status': entry['status'],
              'enabled': entry['enabled'],
              'error': entry['error_message'],
            },
          )
          .toList(),
      'bootstrap_errors': errors,
    };
    // Printed even on failure so a partial native install remains diagnosable.
    debugPrint('BUNDLED_NATIVE_REPORT ${jsonEncode(binding.reportData)}');
    expect(errors, isEmpty);
    expect(installed.map((entry) => entry['id']).toSet(), expected);
    expect(installed.every((entry) => entry['status'] == 'loaded'), isTrue);
    final results = await PlatformBridge.customSearchWithExtension(
      'deezer',
      'Daft Punk',
      options: {'filter': 'artist'},
    ).timeout(const Duration(seconds: 45));
    expect(results, isNotEmpty);
    binding.reportData = {
      ...?binding.reportData,
      'live_search_provider': 'deezer',
      'live_search_count': results.length,
      'live_search_sample': results
          .take(2)
          .map(
            (result) => {
              'id': result['id'],
              'name': result['name'] ?? result['title'],
            },
          )
          .toList(),
    };
    debugPrint(
      'BUNDLED_NATIVE_SEARCH ${jsonEncode({'provider': 'deezer', 'count': results.length, 'sample': binding.reportData?['live_search_sample']})}',
    );
  });
}
