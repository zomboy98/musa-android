import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/download_provider_order.dart';
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
  _Settings([super.initial = const AppSettings(defaultService: 'amazon')]);
  @override
  Future<void> ensureLoaded() async {}
}

const _qualities = <String, List<List<String>>>{
  'amazon': [
    ['best', 'FLAC Best Available', 'lossless'],
    ['opus', 'Opus 320kbps', 'lossy'],
    ['eac3', 'Dolby Digital Plus', 'spatial'],
    ['ac4', 'Dolby Atmos (AC-4)', 'spatial'],
  ],
  'beatport': [
    ['LOSSLESS', 'FLAC Lossless', 'lossless'],
    ['HIGH', 'AAC 256 kbps', 'lossy'],
  ],
  'deezer': [
    ['flac', 'FLAC / Hi-Res', ''],
  ],
  'jiosaavn': [
    ['AAC_320', 'AAC 320 kbps', 'lossy'],
    ['AAC_160', 'AAC 160 kbps', 'lossy'],
    ['AAC_96', 'AAC 96 kbps', 'lossy'],
    ['AAC_48', 'AAC 48 kbps', 'lossy'],
    ['AAC_12', 'AAC 12 kbps', 'lossy'],
  ],
  'qobuz-web': [
    ['HI_RES_LOSSLESS', '24-Bit Max', 'lossless'],
    ['HI_RES', '24-Bit', 'lossless'],
    ['LOSSLESS', 'Lossless', 'lossless'],
  ],
  'soundcloud': [
    ['aac_160', 'AAC up to 160kbps', ''],
  ],
  'tidal-web': [
    ['DOLBY_ATMOS', 'Dolby Atmos', 'spatial'],
    ['HI_RES_LOSSLESS', 'HiRes FLAC', 'lossless'],
    ['LOSSLESS', 'Lossless', 'lossless'],
    ['HIGH', 'High', 'lossy'],
    ['LOW', 'Low', 'lossy'],
  ],
  'ytmusic-spotiflac': [
    ['best', 'Best Audio', ''],
  ],
};

const _extraQualities = <String, List<List<String>>>{
  'atmos-new': [
    ['ATMOS', 'Dolby Atmos', 'spatial'],
  ],
};

const _alphabetical = [
  'amazon',
  'beatport',
  'deezer',
  'jiosaavn',
  'qobuz-web',
  'soundcloud',
  'tidal-web',
  'ytmusic-spotiflac',
];

const _qualityOrder = [
  'amazon',
  'tidal-web',
  'deezer',
  'qobuz-web',
  'beatport',
  'jiosaavn',
  'ytmusic-spotiflac',
  'soundcloud',
];

Map<String, dynamic> _json(String id, {bool enabled = true}) => {
  'id': id,
  'name': id,
  'version': '1',
  'status': 'loaded',
  'enabled': enabled,
  'has_download_provider': true,
  'quality_options': [
    for (final q
        in _qualities[id] ?? _extraQualities[id] ?? const <List<String>>[])
      {'id': q[0], 'label': q[1], if (q[2].isNotEmpty) 'kind': q[2]},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default order puts Amazon first, then Tidal, rest by maximum quality',
    () {
      final extensions = [
        for (final id in _alphabetical) Extension.fromJson(_json(id)),
      ];
      expect(defaultDownloadProviderOrder(extensions), _qualityOrder);
    },
  );

  test('providers without declared qualities are ordered by name', () {
    final extensions = [
      Extension.fromJson(_json('zeta')),
      Extension.fromJson(_json('alpha')),
      Extension.fromJson(_json('tidal-web')),
    ];
    expect(defaultDownloadProviderOrder(extensions), [
      'tidal-web',
      'alpha',
      'zeta',
    ]);
  });

  test('sin proveedor elegido la instalacion nueva resuelve a Amazon', () {
    final extensions = [
      for (final id in _alphabetical) Extension.fromJson(_json(id)),
    ];
    final state = ExtensionState(
      extensions: extensions,
      providerPriority: defaultDownloadProviderOrder(extensions),
    );
    expect(const AppSettings().defaultService, '');
    expect(resolveConfiguredDownloadService('', state), 'amazon');
    expect(resolveConfiguredDownloadService('tidal-web', state), 'tidal-web');
  });

  test('Amazon goes first, then Tidal, when Deezer is not installed', () {
    final extensions = [
      for (final id in ['amazon', 'qobuz-web', 'tidal-web'])
        Extension.fromJson(_json(id)),
    ];
    expect(defaultDownloadProviderOrder(extensions), [
      'amazon',
      'tidal-web',
      'qobuz-web',
    ]);
  });

  group('stored priority', () {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory root;
    late List<Map<String, dynamic>> installed;
    late List<String> nativePriority;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('download-order-');
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = _Backend();
      installed = [for (final id in _alphabetical) _json(id)];
      nativePriority = [];
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
            return jsonEncode(nativePriority);
          case 'getMetadataProviderPriority':
            return '[]';
          case 'setProviderPriority':
            nativePriority = (jsonDecode(args['priority'] as String) as List)
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

    late ProviderContainer container;

    Future<ExtensionState> start(
      Map<String, Object> prefs, {
      AppSettings? settings,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => settings == null ? _Settings() : _Settings(settings),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(extensionProvider.notifier)
          .initialize(
            p.join(root.path, 'extensions'),
            p.join(root.path, 'data'),
            masterKey: base64Encode(List.filled(32, 1)),
          );
      return container.read(extensionProvider);
    }

    Future<List<String>> storedOrder() async {
      final prefs = await SharedPreferences.getInstance();
      return (jsonDecode(prefs.getString('provider_priority')!) as List)
          .cast<String>();
    }

    test('nothing stored starts with the quality order', () async {
      final state = await start({});
      expect(state.providerPriority, _qualityOrder);
      expect(nativePriority, _qualityOrder);
      expect(await storedOrder(), _qualityOrder);
    });

    test('untouched alphabetical order moves to the quality order', () async {
      final state = await start({
        'provider_priority': jsonEncode(_alphabetical),
      });
      expect(state.providerPriority, _qualityOrder);
      expect(nativePriority, _qualityOrder);
      expect(await storedOrder(), _qualityOrder);
    });

    test('alphabetical order chosen after the migration is kept', () async {
      final state = await start({
        'provider_priority': jsonEncode(_alphabetical),
        'provider_priority_quality_order_applied': true,
      });
      expect(state.providerPriority, _alphabetical);
    });

    test('a custom order is respected', () async {
      const custom = [
        'deezer',
        'amazon',
        'beatport',
        'jiosaavn',
        'qobuz-web',
        'soundcloud',
        'tidal-web',
        'ytmusic-spotiflac',
      ];
      final state = await start({
        'provider_priority': jsonEncode(custom),
        'sources_unified_v1': true,
      });
      expect(state.providerPriority, custom);
      expect(await storedOrder(), custom);
    });

    test('a disabled provider keeps the saved order', () async {
      installed.firstWhere((e) => e['id'] == 'beatport')['enabled'] = false;
      final saved = [
        for (final id in _alphabetical)
          if (id != 'beatport') id,
      ];
      final state = await start({'provider_priority': jsonEncode(saved)});
      expect(state.providerPriority, saved);
    });

    test('a new provider is appended after a custom order', () async {
      installed.add(_json('newcomer'));
      const custom = [
        'soundcloud',
        'amazon',
        'beatport',
        'deezer',
        'jiosaavn',
        'qobuz-web',
        'tidal-web',
        'ytmusic-spotiflac',
      ];
      final state = await start({
        'provider_priority': jsonEncode(custom),
        'sources_unified_v1': true,
      });
      expect(state.providerPriority, [...custom, 'newcomer']);
    });

    test(
      'an order the app computed includes a newly installed provider',
      () async {
        installed.add(_json('atmos-new'));
        final state = await start({
          'provider_priority': jsonEncode(_qualityOrder),
          'provider_priority_auto': true,
          'sources_unified_v1': true,
        });
        expect(state.providerPriority.take(3), [
          'amazon',
          'tidal-web',
          'atmos-new',
        ]);
        expect(await storedOrder(), state.providerPriority);
      },
    );

    test('an order saved by the user is never recomputed', () async {
      installed.add(_json('atmos-new'));
      const mine = ['soundcloud', 'amazon'];
      final state = await start({
        'provider_priority': jsonEncode(mine),
        'provider_priority_auto': false,
        'sources_unified_v1': true,
      });
      expect(state.providerPriority.take(2), mine);
      expect(state.providerPriority, contains('atmos-new'));
    });

    test('the default service follows the first audio provider', () async {
      await start({
        'provider_priority': jsonEncode(['soundcloud', 'amazon']),
        'sources_unified_v1': true,
      });
      expect(container.read(settingsProvider).defaultService, 'soundcloud');
      await container.read(extensionProvider.notifier).setProviderPriority([
        'tidal-web',
        'soundcloud',
      ]);
      expect(container.read(settingsProvider).defaultService, 'tidal-web');
      expect(
        container.read(settingsProvider).playbackProviderConfirmed,
        isTrue,
      );
    });

    test(
      'saving an order marks it as personal and reset restores the computed one',
      () async {
        await start({'sources_unified_v1': true});
        final notifier = container.read(extensionProvider.notifier);
        expect((await notifier.recommendedOrderFlags()).audio, isTrue);
        await notifier.setProviderPriority(_alphabetical);
        expect((await notifier.recommendedOrderFlags()).audio, isFalse);
        expect(
          container.read(extensionProvider).providerPriority,
          _alphabetical,
        );
        await notifier.resetProviderPriorityToRecommended();
        expect((await notifier.recommendedOrderFlags()).audio, isTrue);
        expect(
          container.read(extensionProvider).providerPriority,
          _qualityOrder,
        );
        expect(container.read(settingsProvider).defaultService, 'amazon');
      },
    );

    test(
      'migration: a confirmed default service becomes the first entry',
      () async {
        final state = await start(
          {},
          settings: const AppSettings(
            defaultService: 'jiosaavn',
            playbackProviderConfirmed: true,
          ),
        );
        expect(state.providerPriority.first, 'jiosaavn');
        expect(
          state.providerPriority.skip(1),
          _qualityOrder.where((id) => id != 'jiosaavn'),
        );
        expect(container.read(settingsProvider).defaultService, 'jiosaavn');
        expect(
          (await container
                  .read(extensionProvider.notifier)
                  .recommendedOrderFlags())
              .audio,
          isFalse,
        );
      },
    );

    test(
      'migration: an unconfirmed default does not override the computed order',
      () async {
        final state = await start(
          {},
          settings: const AppSettings(defaultService: 'jiosaavn'),
        );
        expect(state.providerPriority, _qualityOrder);
        expect(container.read(settingsProvider).defaultService, 'amazon');
      },
    );

    test(
      'migration: the old default service goes first in a saved list',
      () async {
        final state = await start({
          'provider_priority': jsonEncode(_alphabetical),
        }, settings: const AppSettings(defaultService: 'qobuz-web'));
        expect(state.providerPriority.first, 'qobuz-web');
        expect(
          state.providerPriority.skip(1),
          _alphabetical.where((id) => id != 'qobuz-web'),
        );
        expect(container.read(settingsProvider).defaultService, 'qobuz-web');
      },
    );

    test('a new provider is appended after the migrated order', () async {
      installed.add(_json('newcomer'));
      final state = await start({
        'provider_priority': jsonEncode(_alphabetical),
      });
      expect(state.providerPriority, [..._qualityOrder, 'newcomer']);
    });
  });
}
