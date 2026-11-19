import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS bundle name agrees with launch, test and packaging paths', () {
    final config = File(
      'macos/Runner/Configs/AppInfo.xcconfig',
    ).readAsStringSync();
    final name = RegExp(
      r'^PRODUCT_NAME = (.+)$',
      multiLine: true,
    ).firstMatch(config)!.group(1)!.trim();
    final project = File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final scheme = File(
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    ).readAsStringSync();
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(
      plist,
      matches(
        RegExp(
          '<key>CFBundleDisplayName</key>\\s*<string>${RegExp.escape(name)}</string>',
        ),
      ),
    );
    expect(project, contains('path = $name.app;'));
    final hosts = RegExp(r'TEST_HOST = "([^"]+)"').allMatches(project).toList();
    expect(hosts, hasLength(3));
    for (final host in hosts) {
      expect(host.group(1), contains('/$name.app/'));
      expect(host.group(1), endsWith('/$name'));
    }
    final appBuildables = RegExp(
      r'BuildableName = "([^"]+\.app)"',
    ).allMatches(scheme).toList();
    expect(appBuildables, isNotEmpty);
    for (final buildable in appBuildables) {
      expect(buildable.group(1), '$name.app');
    }
    for (final workflow in ['desktop', 'release']) {
      expect(
        File('.github/workflows/$workflow.yml').readAsStringSync(),
        contains('build/macos/Build/Products/Release/$name.app'),
      );
    }
    // Names can change without migrating installed data or signing identity.
    expect(config, contains('PRODUCT_BUNDLE_IDENTIFIER = com.zarz.mornye'));
    expect(
      config,
      contains('CODE_SIGN_IDENTITY = \$(MORNYE_CODE_SIGN_IDENTITY)'),
    );
  });
}
