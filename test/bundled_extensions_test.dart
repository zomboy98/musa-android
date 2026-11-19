import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/bundled_extensions.dart';

class TestBundle extends CachingAssetBundle {
  TestBundle(this.bytes, {this.corrupt = false, this.upgrade = false});
  final Uint8List bytes;
  final bool corrupt;
  final bool upgrade;
  @override
  Future<ByteData> load(String key) async {
    final value = key.endsWith('manifest.json')
        ? utf8.encode(
            jsonEncode({
              'extensions': [
                {
                  'id': 'example',
                  'file': 'example.sflx',
                  'version': '1',
                  if (upgrade) 'upgrade': true,
                  'sha256': corrupt
                      ? 'invalid'
                      : sha256.convert(bytes).toString(),
                },
              ],
            }),
          )
        : bytes;
    return ByteData.sublistView(Uint8List.fromList(value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp());
  tearDown(() async => dir.delete(recursive: true));

  test(
    'bundles the verified Amazon, Deezer and Tidal official releases',
    () async {
      const releases = {
        'amzn.sflx': (
          'amazon',
          '2.3.19',
          '5177325613ad65b9475aa02e8befb651b68a324d465f04869f2906f5f59044ec',
        ),
        'deezer.sflx': (
          'deezer',
          '1.3.11',
          '298c44d77e04f5b29609eb2068153f23e418b9055c44b219ac5db9888e0e5c34',
        ),
        'tidal-web.sflx': (
          'tidal-web',
          '1.2.14',
          '0f23f034b2f38e72d07abccb974eb7d39cf409c5659735e5745380ffe2816094',
        ),
      };
      final manifest =
          jsonDecode(
                await File(
                  'assets/bundled_extensions/manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final entries = (manifest['extensions'] as List)
          .cast<Map<String, dynamic>>();
      for (final MapEntry(key: file, value: (id, version, digest))
          in releases.entries) {
        final entry = entries.singleWhere((entry) => entry['id'] == id);
        expect(entry, containsPair('file', file));
        expect(entry, containsPair('version', version));
        expect(entry, containsPair('sha256', digest));
        final bytes = await File(
          'assets/bundled_extensions/$file',
        ).readAsBytes();
        expect(sha256.convert(bytes).toString(), digest);
      }
    },
  );

  test(
    'packaged official extensions retain hashes, identities and licenses',
    () async {
      final manifest =
          jsonDecode(
                await File(
                  'assets/bundled_extensions/manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final ids = <String>{};
      for (final entry
          in (manifest['extensions'] as List).cast<Map<String, dynamic>>()) {
        final bytes = await File(
          'assets/bundled_extensions/${entry['file']}',
        ).readAsBytes();
        expect(sha256.convert(bytes).toString(), entry['sha256']);
        expect(ids.add(entry['id'] as String), isTrue);
        final archive = ZipDecoder().decodeBytes(bytes);
        final license = archive.findFile('LICENSE');
        expect(license, isNotNull, reason: entry['id'] as String);
        expect(license!.content, isNotEmpty);
        final packageManifest =
            jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
                as Map<String, dynamic>;
        expect(packageManifest['name'], entry['id']);
        expect(packageManifest['version'], entry['version']);
        if (entry['id'] == 'apple-music') {
          final settings = (packageManifest['settings'] as List).cast<Map>();
          expect(
            settings.singleWhere((s) => s['key'] == 'mediaUserToken')['secret'],
            isTrue,
          );
        }
      }
      expect(ids, hasLength(13));
    },
  );

  test('does not reinstall an attempted package after removal', () async {
    var installs = 0;
    Future<void> run() => bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {},
      bundle: TestBundle(Uint8List.fromList([1])),
      install: (path, id) async {
        installs++;
      },
      report: (_) {},
    );
    await run();
    await run();
    expect(installs, 1);
  });

  test('rejects damaged bytes before installation and can retry', () async {
    var installs = 0;
    final errors = <String>[];
    Future<void> run(bool corrupt) => bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {},
      bundle: TestBundle(Uint8List.fromList([1]), corrupt: corrupt),
      install: (path, id) async {
        installs++;
      },
      report: errors.add,
    );
    await run(true);
    expect(installs, 0);
    expect(errors, hasLength(1));
    await run(false);
    expect(installs, 1);
  });

  test('explicit install can restore a deliberately removed package', () async {
    final marker = File('${dir.path}/.bundled-extension-attempts/example');
    await marker.parent.create(recursive: true);
    await marker.writeAsString('done');
    var installs = 0;
    await bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {},
      includePreviouslyRemoved: true,
      bundle: TestBundle(Uint8List.fromList([1])),
      install: (_, _) async {
        installs++;
      },
      report: (_) {},
    );
    expect(installs, 1);
    expect(await marker.readAsString(), 'done');
  });

  test(
    'explicit install preserves disabled and unknown registered packages',
    () async {
      for (final status in ['disabled', 'loaded', 'unknown']) {
        await bootstrapBundledExtensions(
          dataDir: dir.path,
          installedStatuses: {'example': status},
          includePreviouslyRemoved: true,
          bundle: TestBundle(Uint8List.fromList([1])),
          install: (_, _) async =>
              fail('Must not replace a registered package'),
          report: (_) {},
        );
      }
    },
  );

  test(
    'completed error package remains visible and is never replaced',
    () async {
      final marker = File('${dir.path}/.bundled-extension-attempts/example');
      await marker.parent.create(recursive: true);
      await marker.writeAsString('done');
      final errors = <String>[];
      await bootstrapBundledExtensions(
        dataDir: dir.path,
        installedStatuses: {'example': 'error'},
        includePreviouslyRemoved: true,
        bundle: TestBundle(Uint8List.fromList([1])),
        install: (_, _) async => fail('Must not replace an error package'),
        report: errors.add,
      );
      expect(errors, hasLength(1));
    },
  );

  test('flagged package upgrades once when the version differs', () async {
    var installs = 0;
    Future<void> run(String installed) => bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {'example': 'loaded'},
      installedVersions: {'example': installed},
      bundle: TestBundle(Uint8List.fromList([1]), upgrade: true),
      install: (_, _) async {
        installs++;
      },
      report: (_) {},
    );
    await run('0');
    await run('0');
    expect(installs, 1);
    await run('1');
    expect(installs, 1);
  });

  test(
    'flagged package upgrades even when an earlier install left a done marker',
    () async {
      final markerDir = Directory('${dir.path}/.bundled-extension-attempts')
        ..createSync(recursive: true);
      File('${markerDir.path}/example').writeAsStringSync('done');
      var installs = 0;
      await bootstrapBundledExtensions(
        dataDir: dir.path,
        installedStatuses: {'example': 'loaded'},
        installedVersions: {'example': '0'},
        bundle: TestBundle(Uint8List.fromList([1]), upgrade: true),
        install: (_, _) async {
          installs++;
        },
        report: (_) {},
      );
      expect(installs, 1);
    },
  );

  test('failed native attempt is retried automatically', () async {
    var installs = 0;
    Future<void> run() => bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {},
      bundle: TestBundle(Uint8List.fromList([1])),
      install: (path, id) async {
        installs++;
        throw StateError('incompatible');
      },
      report: (_) {},
    );
    await run();
    await run();
    expect(installs, 2);
  });

  test('registered error remains pending without replacing it', () async {
    final marker = File('${dir.path}/.bundled-extension-attempts/example');
    await marker.parent.create(recursive: true);
    await marker.writeAsString('pending');
    final errors = <String>[];
    var installs = 0;
    await bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {'example': 'error'},
      bundle: TestBundle(Uint8List.fromList([1])),
      install: (path, id) async {
        installs++;
      },
      report: errors.add,
    );
    expect(installs, 0);
    expect(await marker.readAsString(), 'pending');
    expect(errors, hasLength(1));
  });

  test('failed upgrade is retried on the next start', () async {
    var installs = 0;
    final lines = <String>[];
    Future<void> run({required bool fail}) => bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {'example': 'loaded'},
      installedVersions: {'example': '0'},
      bundle: TestBundle(Uint8List.fromList([1]), upgrade: true),
      install: (_, _) async {
        installs++;
        if (fail) throw StateError('validation failed');
      },
      report: (_) {},
      log: lines.add,
    );
    await run(fail: true);
    await run(fail: false);
    await run(fail: false);
    expect(installs, 2);
    expect(lines[0], contains('result=failed:'));
    expect(lines[0], contains('validation failed'));
    expect(
      lines[1],
      'bundled: id=example installed=0 bundled=1 upgrade=true result=upgraded',
    );
  });

  test('an installed version that is newer is not replaced', () async {
    var installs = 0;
    final lines = <String>[];
    await bootstrapBundledExtensions(
      dataDir: dir.path,
      installedStatuses: {'example': 'loaded'},
      installedVersions: {'example': '1.0.1'},
      bundle: TestBundle(Uint8List.fromList([1]), upgrade: true),
      install: (_, _) async {
        installs++;
      },
      report: (_) {},
      log: lines.add,
    );
    expect(installs, 0);
    expect(lines.single, contains('result=skipped'));
  });

  test('upgrade-only mode leaves missing packages alone', () async {
    var installs = 0;
    final lines = <String>[];
    Future<void> run(Map<String, String> statuses) =>
        bootstrapBundledExtensions(
          dataDir: dir.path,
          installedStatuses: statuses,
          installedVersions: {if (statuses.isNotEmpty) 'example': '0'},
          installMissing: false,
          bundle: TestBundle(Uint8List.fromList([1]), upgrade: true),
          install: (_, _) async {
            installs++;
          },
          report: (_) {},
          log: lines.add,
        );
    await run({});
    expect(installs, 0);
    expect(lines.single, contains('installed=none'));
    await run({'example': 'loaded'});
    expect(installs, 1);
  });

  test('bundled versions compare numerically', () {
    expect(bundledVersionIsNewer('1.4.16', '1.4.17'), isTrue);
    expect(bundledVersionIsNewer('1.4.9', '1.4.10'), isTrue);
    expect(bundledVersionIsNewer('1.4.17', '1.4.17'), isFalse);
    expect(bundledVersionIsNewer('2.0', '1.9.9'), isFalse);
    expect(bundledVersionIsNewer(null, '1'), isTrue);
  });

  test('every bundled extension in the shipped manifest is upgradeable', () {
    final manifest =
        jsonDecode(
              File(
                'assets/bundled_extensions/manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final entries = (manifest['extensions'] as List)
        .cast<Map<String, dynamic>>();
    expect(entries, isNotEmpty);
    for (final entry in entries) {
      expect(
        entry['upgrade'],
        isTrue,
        reason: '${entry['id']} must set "upgrade": true',
      );
    }
  });
}
