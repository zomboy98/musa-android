import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/downloaded_format_mark.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixed_settings.dart';

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

const _albumTrack = Track(
  id: 'album-from-search-1',
  name: 'SANA SANA',
  artistName: 'Chuyin',
  albumName: 'Los Locos Nunca Mueren',
  duration: 180,
  isrc: 'ESABC2400011',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('removable-mark-');
    final previous = databaseFactoryOrNull;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previous;
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // A just-closed database file may stay locked for a moment on Windows.
      }
    });
  });

  Future<String> scannedFile() async {
    final path = '${root.path}/11 - SANA SANA.m4a';
    await File(path).writeAsBytes([1, 2, 3]);
    await LibraryDatabase.instance.upsertBatchExcludingHistory([
      LocalLibraryItem(
        id: 'scan-1',
        trackName: 'SANA SANA',
        artistName: 'Chuyin',
        albumName: 'Los Locos Nunca Mueren',
        filePath: path,
        scannedAt: DateTime(2026),
        duration: 180,
      ).toJson(),
    ], sourceId: LocalLibraryItem.legacySourceId);
    return path;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the grey mark asks first and then deletes the file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final path = (await tester.runAsync(scannedFile))!;
    final container = ProviderContainer(
      overrides: [
        localLibraryProvider.overrideWith(_Library.new),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(
              localLibraryEnabled: true,
              localLibraryShowDuplicates: true,
            ),
          ),
        ),
        downloadQueueProvider.overrideWith(DownloadQueueNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TrackListTile(
              track: _albumTrack,
              isInHistory: false,
              clickableArtist: false,
              onDownload: ({bool forceQualityPicker = false}) {},
              leading: const SizedBox(width: 32, child: Text('1')),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    final mark = find.byType(DownloadedFormatMark);
    expect(mark, findsOneWidget);
    await tester.tap(mark);
    await tester.pumpAndSettle();
    expect(find.byType(AppAlertDialog), findsOneWidget);
    expect(File(path).existsSync(), isTrue);

    await tester.tap(
      find
          .descendant(
            of: find.byType(AppAlertDialog),
            matching: find.byType(AppDialogAction),
          )
          .last,
    );
    await settle(tester);

    expect(File(path).existsSync(), isFalse);
    expect(find.byType(DownloadedFormatMark), findsNothing);
  });
}
