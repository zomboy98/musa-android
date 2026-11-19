import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/sources_page.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions(this.initial);
  final ExtensionState initial;

  @override
  ExtensionState build() => initial;
}

class _Backend extends RustFfiBackend {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      const MethodChannel(
        'com.zarz.mornye/backend',
      ).invokeMethod<T>(method, arguments);
}

Extension _ext(
  String id, {
  bool audio = true,
  bool metadata = true,
  bool search = false,
  bool home = false,
}) => Extension(
  id: id,
  name: id,
  displayName: 'Name $id',
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: audio,
  hasMetadataProvider: metadata,
  searchBehavior: search ? const SearchBehavior(enabled: true) : null,
  capabilities: home ? const {'homeFeed': true} : const {},
);

Widget _app(AppSettings settings, ExtensionState state) {
  return ProviderScope(
    overrides: [
      settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
      extensionProvider.overrideWith(() => _Extensions(state)),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SourcesPage(),
    ),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final extensions = [_ext('a'), _ext('b'), _ext('c', metadata: false)];
  final state = ExtensionState(
    isInitialized: true,
    extensions: extensions,
    providerPriority: const ['b', 'a', 'c'],
    metadataProviderPriority: const ['a', 'b'],
  );

  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<List<String>> pushed;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pushed = [];
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = _Backend();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getProviderPriority':
          return jsonEncode(pushed.isEmpty ? <String>[] : pushed.last);
        case 'setProviderPriority':
          final args = call.arguments as Map;
          pushed.add(
            (jsonDecode(args['priority'] as String) as List).cast<String>(),
          );
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    RustFfiBackend.debugShared = null;
    debugDesktopPlatformOverride = null;
  });

  testWidgets('lists follow the saved order and mark the first one', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
    expect(top('source_audio_b'), lessThan(top('source_audio_a')));
    expect(top('source_audio_a'), lessThan(top('source_audio_c')));
    expect(top('source_music_a'), lessThan(top('source_music_b')));
    expect(find.byKey(const ValueKey('source_music_c')), findsNothing);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Name b'), findsNWidgets(2));
  });

  testWidgets('the first audio row has no backup switch, the rest do', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source_backup_b')), findsNothing);
    expect(find.byKey(const ValueKey('source_backup_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('source_backup_c')), findsOneWidget);
    expect(find.text('Use as backup'), findsNWidgets(2));
  });

  testWidgets('a backup switch is saved in the settings', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source_backup_a')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SourcesPage)),
    );
    expect(container.read(settingsProvider).downloadFallbackExtensionIds, [
      'b',
      'c',
    ]);
    await tester.tap(find.byKey(const ValueKey('source_backup_a')));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).downloadFallbackExtensionIds,
      isNull,
    );
  });

  testWidgets('one general switch controls trying the next one', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    expect(find.text('Try the next one if it fails'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sources_try_next')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SourcesPage)),
    );
    expect(container.read(settingsProvider).autoFallback, isFalse);
  });

  testWidgets('dragging a row saves the new audio order', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    final handle = find.descendant(
      of: find.byKey(const ValueKey('source_audio_b')),
      matching: find.byIcon(Icons.drag_handle),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var step = 0; step < 12; step++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SourcesPage)),
    );
    final saved = container.read(extensionProvider).providerPriority;
    expect(saved.first, 'a');
    expect(saved, ['a', 'c', 'b']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('provider_priority'), '["a","c","b"]');
    expect(prefs.getBool('provider_priority_auto'), isFalse);
    expect(container.read(settingsProvider).defaultService, 'a');
    expect(container.read(settingsProvider).playbackProviderConfirmed, isTrue);
    expect(pushed, [
      ['a', 'c', 'b'],
    ]);
  });

  testWidgets('the default is confirmed from here when it never was', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sources_confirm_default')),
      findsOneWidget,
    );
    expect(find.text('Use Name b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(const AppSettings(playbackProviderConfirmed: true), state),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sources_confirm_default')), findsNothing);
  });

  testWidgets('lyrics are linked once, not repeated', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(const AppSettings(), state));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sources_lyrics')), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
  });

  group('catalog and home choice', () {
    final searchable = [
      _ext('a', search: true, home: true),
      _ext('b', search: true, home: true),
      _ext('c', metadata: false),
    ];
    final searchState = ExtensionState(
      isInitialized: true,
      extensions: searchable,
      providerPriority: const ['a', 'b', 'c'],
      metadataProviderPriority: const ['a', 'b'],
    );

    testWidgets('both rows show without opening Advanced', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(const AppSettings(homeFeedProvider: null), searchState));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sources_catalog_provider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sources_home_provider')),
        findsOneWidget,
      );
      expect(find.text('Catalog and search'), findsOneWidget);
      expect(find.text('Automatic · Name a'), findsNWidgets(2));
    });

    testWidgets('picking a catalog provider saves it and Automatic clears it', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(_app(const AppSettings(), searchState));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SourcesPage)),
      );
      await tester.tap(find.byKey(const ValueKey('sources_catalog_provider')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sources_catalog_c')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sources_catalog_b')));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).searchProvider, 'b');
      expect(container.read(settingsProvider).searchProviderPinned, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sources_catalog_provider')),
          matching: find.text('Name b'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sources_catalog_provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sources_catalog_auto')));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).searchProviderPinned, isFalse);
      expect(container.read(settingsProvider).searchProvider, 'a');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sources_catalog_provider')),
          matching: find.text('Automatic · Name a'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a provider that is gone falls back to Automatic', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(
        _app(
          const AppSettings(searchProvider: 'gone', searchProviderPinned: true),
          searchState,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sources_catalog_provider')),
          matching: find.text('Automatic · Name a'),
        ),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SourcesPage)),
      );
      container.read(extensionProvider.notifier).reconcileSearchProvider();
      expect(container.read(settingsProvider).searchProviderPinned, isFalse);
      expect(container.read(settingsProvider).searchProvider, 'a');
    });

    testWidgets('a pinned provider is kept when the list order differs', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(
        _app(
          const AppSettings(searchProvider: 'b', searchProviderPinned: true),
          searchState,
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SourcesPage)),
      );
      container.read(extensionProvider.notifier).reconcileSearchProvider();
      expect(container.read(settingsProvider).searchProvider, 'b');
      expect(container.read(settingsProvider).searchProviderPinned, isTrue);
    });

    testWidgets('the Home choice is saved', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(const AppSettings(), searchState));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SourcesPage)),
      );
      await tester.tap(find.byKey(const ValueKey('sources_home_provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name b').last);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).homeFeedProvider, 'b');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sources_home_provider')),
          matching: find.text('Name b'),
        ),
        findsOneWidget,
      );
    });
  });

  group('sources page helpers', () {
    test('saved order first, new providers appended, removed ones dropped', () {
      expect(orderedSources(['b', 'gone', 'a'], ['a', 'b', 'c']), [
        'b',
        'a',
        'c',
      ]);
    });

    test('backup switches map to the saved list and back to null', () {
      const order = ['a', 'b', 'c'];
      expect(fallbackIdsAfterToggle(order, null, 'b', false), ['a', 'c']);
      expect(fallbackIdsAfterToggle(order, ['a', 'c'], 'b', true), isNull);
      expect(fallbackIdsAfterToggle(order, ['a'], 'c', true), ['a', 'c']);
    });
  });
}
