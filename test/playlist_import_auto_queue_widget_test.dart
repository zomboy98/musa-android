// Test doubles capture enqueues.
// ignore_for_file: avoid_public_notifier_properties
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'playlist_file_import_ui_test.dart'
    show Picker, MemoryFile, EmptyLibrary;
import 'playlist_link_import_test.dart' show FakeCollections;

class TestQueue extends DownloadQueueNotifier {
  final tracks = <Track>[];
  bool failFirst = false;
  int calls = 0;
  @override
  DownloadQueueState build() => const DownloadQueueState();
  @override
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) async {
    calls++;
    if (failFirst && calls == 1) throw StateError('queue failed');
    tracks.add(track);
    return 'queued';
  }
}

class TestExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'configured',
        'enabled': true,
        'has_download_provider': true,
      }),
    ],
  );
}

void main() {
  for (final scenario in [
    'on',
    'off',
    'failure',
    'fallback_on',
    'fallback_off',
  ]) {
    testWidgets('file import automatic queue $scenario', (tester) async {
      final settings = AppSettings(
        autoDownloadSavedTracks: scenario != 'off',
        defaultService: scenario.startsWith('fallback')
            ? 'missing'
            : 'configured',
        autoFallback: scenario != 'fallback_off',
      );
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(settings.toJson()),
      });
      final prefs = await SharedPreferences.getInstance();
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = Picker(
        MemoryFile(
          'Mix.csv',
          'Track Name,Artist Name,Album Name\nFirst,Artist,Album\nSecond,Artist,Album\nFirst,Artist,Album\n',
        ),
      );
      addTearDown(() => FilePickerPlatform.instance = original);
      final collections = FakeCollections();
      final queue = TestQueue()..failFirst = scenario == 'failure';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialSettingsProvider.overrideWithValue(
              loadBootstrapSettings(prefs),
            ),
            libraryCollectionsProvider.overrideWith(() => collections),
            extensionProvider.overrideWith(TestExtensions.new),
            downloadQueueProvider.overrideWith(() => queue),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () =>
                      importPlaylistFile(context, ref, library: EmptyLibrary()),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 && find.text('Choose tracks').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.tracks.map((t) => t.name), [
        'First',
        'Second',
        'First',
      ]);
      expect(
        queue.calls,
        scenario == 'off' || scenario == 'fallback_off' ? 0 : 2,
      );
      expect(
        queue.tracks.map((t) => t.name),
        scenario == 'on' || scenario == 'fallback_on'
            ? ['First', 'Second']
            : scenario == 'failure'
            ? ['Second']
            : <String>[],
      );
      if (scenario == 'failure') {
        final context = tester.element(find.byType(Scaffold).first);
        expect(
          find.text(context.l10n.savedTrackAutoDownloadError),
          findsOneWidget,
        );
      }
    });
  }
}
