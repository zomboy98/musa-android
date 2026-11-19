import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/services/apple_animated_artwork.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/bundled_extensions.dart';
import 'package:mornye/services/spotify_canvas_lookup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('manifest.json')) {
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode('{"extensions": []}')),
      );
    }
    throw StateError('no asset $key');
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _Backend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;
}

const _track = Track(
  id: 'local-1',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty manifest means no bundled add-ons', () async {
    expect(await hasBundledExtensions(bundle: _EmptyBundle()), isFalse);
  });

  test(
    'startup with an empty manifest installs nothing and stays quiet',
    () async {
      final dir = await Directory.systemTemp.createTemp('musa_public_');
      addTearDown(() => dir.delete(recursive: true));
      final reports = <String>[];
      var installs = 0;
      await bootstrapBundledExtensions(
        dataDir: dir.path,
        installedStatuses: const {},
        install: (_, _) async => installs++,
        report: reports.add,
        log: (_) {},
        bundle: _EmptyBundle(),
      );
      expect(installs, 0);
      expect(reports, isEmpty);
    },
  );

  test('without add-ons the lookups do nothing and log nothing', () async {
    final dir = await Directory.systemTemp.createTemp('musa_public_');
    addTearDown(() => dir.delete(recursive: true));
    final logs = <String>[];
    var calls = 0;
    final apple = AppleAnimatedArtworkLookup(
      handleUrl: (_) async {
        calls++;
        return null;
      },
      directory: () async => dir,
      log: logs.add,
      installed: () => false,
    );
    final result = await apple.lookup(_track);
    expect(result.outcome, AnimatedArtworkOutcome.unmatched);
    final canvas = SpotifyCanvasLookup(
      search: (_) async {
        calls++;
        return const [];
      },
      handleUrl: (_) async {
        calls++;
        return null;
      },
      directory: () async => dir,
      log: logs.add,
      installed: () => false,
    );
    expect(await canvas.lookup(_track), isNull);
    expect(calls, 0);
    expect(logs, isEmpty);
  });

  testWidgets('Sources offers the three ways to add an add-on when empty', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    RustFfiBackend.debugShared = _Backend();
    addTearDown(() => RustFfiBackend.debugShared = null);
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => FixedSettingsNotifier()),
          extensionProvider.overrideWith(_Extensions.new),
        ],
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SourcesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Añadir complemento'), findsOneWidget);
    expect(find.byKey(const Key('sources-add-code')), findsOneWidget);
    expect(find.byKey(const Key('sources-add-file')), findsOneWidget);
    expect(find.byKey(const Key('sources-add-repo')), findsOneWidget);
    expect(find.text('Código'), findsOneWidget);
    expect(find.text('Archivo'), findsOneWidget);
    expect(find.text('Repositorio'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
