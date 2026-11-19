import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Backend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<T>(method, arguments);
}

class _Settings extends FixedSettingsNotifier {
  _Settings(super.initial);
  @override
  Future<void> ensureLoaded() async {}
}

Map<String, dynamic> _json(
  String id, {
  bool skip = false,
  bool home = false,
  bool related = false,
  bool search = true,
}) => {
  'id': id,
  'name': id,
  'version': '1',
  'status': 'loaded',
  'enabled': true,
  'has_metadata_provider': true,
  'skip_metadata_enrichment': skip,
  'search_behavior': {'enabled': search},
  'capabilities': {'homeFeed': home, 'relatedTracks': related},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late List<Map<String, dynamic>> installed;
  late List<String> nativeMetadata;
  late ProviderContainer container;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sources-priority-');
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = _Backend();
    nativeMetadata = [];
    installed = [
      _json('spotify-web', skip: true, home: true, related: true),
      _json('apple-music', home: true, related: true),
      _json('deezer', related: true),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'loadExtensionsFromDir':
          return {
            'loaded': [for (final e in installed) e['id']],
            'errors': <String>[],
          };
        case 'getInstalledExtensions':
          return jsonEncode(installed);
        case 'getProviderPriority':
          return '[]';
        case 'getMetadataProviderPriority':
          return jsonEncode(nativeMetadata);
        case 'setMetadataProviderPriority':
          nativeMetadata = (jsonDecode(args['priority'] as String) as List)
              .cast<String>();
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    RustFfiBackend.debugShared = null;
    debugDesktopPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> start(
    Map<String, Object> prefs, {
    AppSettings settings = const AppSettings(),
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => _Settings(settings))],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionProvider.notifier)
        .initialize(
          p.join(root.path, 'extensions'),
          p.join(root.path, 'data'),
          masterKey: base64Encode(List.filled(32, 1)),
        );
  }

  Future<List<String>> stored() async {
    final prefs = await SharedPreferences.getInstance();
    return (jsonDecode(prefs.getString('metadata_provider_priority')!) as List)
        .cast<String>();
  }

  test('without a saved list the computed music order is used', () async {
    await start({});
    const expected = ['deezer', 'apple-music', 'spotify-web'];
    expect(
      container.read(extensionProvider).metadataProviderPriority,
      expected,
    );
    expect(await stored(), expected);
    expect(nativeMetadata, expected);
    expect(
      (await container.read(extensionProvider.notifier).recommendedOrderFlags())
          .metadata,
      isTrue,
    );
  });

  test('search and Home follow the first music source', () async {
    await start({});
    expect(container.read(settingsProvider).searchProvider, 'deezer');
    await container
        .read(extensionProvider.notifier)
        .setMetadataProviderPriority(['apple-music', 'deezer', 'spotify-web']);
    expect(container.read(settingsProvider).searchProvider, 'apple-music');
    expect(
      (await container.read(extensionProvider.notifier).recommendedOrderFlags())
          .metadata,
      isFalse,
    );
  });

  test('a list saved by the user is kept as it is', () async {
    const mine = ['spotify-web', 'deezer', 'apple-music'];
    await start({
      'metadata_provider_priority': jsonEncode(mine),
      'metadata_provider_priority_auto': false,
      'sources_unified_v1': true,
    });
    expect(container.read(extensionProvider).metadataProviderPriority, mine);
    expect(container.read(settingsProvider).searchProvider, 'spotify-web');
  });

  test('migration: the old search provider becomes the first entry', () async {
    await start({
      'metadata_provider_priority': jsonEncode([
        'deezer',
        'apple-music',
        'spotify-web',
      ]),
    }, settings: const AppSettings(searchProvider: 'apple-music'));
    expect(await stored(), ['apple-music', 'deezer', 'spotify-web']);
    expect(container.read(settingsProvider).searchProvider, 'apple-music');
  });

  test('reset goes back to the computed order', () async {
    await start({
      'metadata_provider_priority': jsonEncode([
        'spotify-web',
        'apple-music',
        'deezer',
      ]),
      'metadata_provider_priority_auto': false,
      'sources_unified_v1': true,
    });
    final notifier = container.read(extensionProvider.notifier);
    await notifier.resetMetadataProviderPriorityToRecommended();
    expect(container.read(extensionProvider).metadataProviderPriority, [
      'deezer',
      'apple-music',
      'spotify-web',
    ]);
    expect(container.read(settingsProvider).searchProvider, 'deezer');
    expect((await notifier.recommendedOrderFlags()).metadata, isTrue);
  });

  test(
    'a new complement is placed by what it declares while the order is automatic',
    () async {
      installed.add(_json('fresh', home: true, related: true));
      await start({
        'metadata_provider_priority': jsonEncode([
          'deezer',
          'apple-music',
          'spotify-web',
        ]),
        'metadata_provider_priority_auto': true,
        'sources_unified_v1': true,
      });
      expect(container.read(extensionProvider).metadataProviderPriority, [
        'deezer',
        'apple-music',
        'fresh',
        'spotify-web',
      ]);
    },
  );
}
