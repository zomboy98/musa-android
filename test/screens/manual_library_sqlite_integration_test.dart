import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    defaultLibraryView: 'all',
    historyFilterMode: 'all',
    historySortMode: 'manual',
    historyViewMode: 'list',
    localLibraryEnabled: true,
    listeningStatisticsEnabled: false,
  );
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> verifyMove(
    WidgetTester tester, {
    required bool end,
    bool large = false,
  }) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('manual-queue-'),
    ))!;
    final oldFactory = databaseFactoryOrNull;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    debugDesktopPlatformOverride = false;
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = oldFactory;
      debugDesktopPlatformOverride = null;
      await root.delete(recursive: true);
    });
    await tester.runAsync(() async {
      final db = await LibraryDatabase.instance.database;
      final batch = db.batch();
      for (
        var i = 0;
        i <
            (large
                ? 305
                : end
                ? 5
                : 100);
        i++
      ) {
        batch.insert('library', {
          'id': '$i',
          'track_name': 'Track $i',
          'artist_name': 'Artist',
          'album_name': 'Album',
          'file_path': '/$i.flac',
          'scanned_at': '2026-01-01',
          'sort_added': 100 - i,
          'track_name_norm': 'track $i',
          'artist_name_norm': 'artist',
          'album_name_norm': 'album',
          'sort_genre': '',
          'sort_release': '',
        });
      }
      await batch.commit(noResult: true);
    });
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(_History.new),
          localLibraryProvider.overrideWith(_Local.new),
          downloadQueueProvider.overrideWith(_Queue.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: QueueTab(librarySection: 'all')),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.text('Track 0'), findsOneWidget);
    expect(find.text('Track 1'), findsOneWidget);
    expect(find.text('Track 3'), findsOneWidget);
    for (final name in ['Track 0', 'Track 1']) {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(name)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
    }
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Track 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    if (large) {
      expect(
        find.byKey(const ValueKey('manual_library_end_drop')),
        findsNothing,
      );
      final scrollable = find
          .ancestor(of: find.text('Track 0'), matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollable).position;
      scroll.jumpTo(scroll.maxScrollExtent * .8);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pump();
    }
    if (end) {
      expect(
        find.byKey(const ValueKey('manual_library_end_drop')),
        findsOneWidget,
      );
    }
    await gesture.moveTo(
      tester.getCenter(
        end
            ? find.byKey(const ValueKey('manual_library_end_drop'))
            : find.text('Track 3'),
      ),
    );
    await tester.pump();
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.text('Confirm move'), findsOneWidget);
    if (end)
      expect(find.textContaining('end of the entire library'), findsOneWidget);
    await tester.tap(find.text('Move').last);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    final rows = await tester.runAsync(
      () => LibraryDatabase.instance.getQueueTrackPageResult(
        QueueLibraryDbQuery(sortMode: 'manual', limit: large ? 305 : 100),
      ),
    );
    final ids = rows!.rows.map((r) => (r['item'] as Map)['id']).toList();
    expect(
      ids.length,
      large
          ? 305
          : end
          ? 5
          : 100,
    );
    expect(ids.toSet().length, ids.length);
    if (large) {
      expect(ids, [for (var i = 2; i < 305; i++) '$i', '0', '1']);
    } else {
      expect(
        ids.take(5),
        end ? ['2', '3', '4', '0', '1'] : ['2', '0', '1', '3', '4'],
      );
    }
    if (!end) expect(ids, contains('99'));
    if (!end)
      expect(
        tester.getTopLeft(find.text('Track 2')).dy,
        lessThan(tester.getTopLeft(find.text('Track 0')).dy),
      );
    await tester.pumpWidget(const SizedBox.shrink());
    final reopened = await tester.runAsync(() async {
      await LibraryDatabase.instance.close();
      return LibraryDatabase.instance.getQueueTrackPageResult(
        QueueLibraryDbQuery(sortMode: 'manual', limit: large ? 305 : 100),
      );
    });
    expect(reopened!.rows.map((r) => (r['item'] as Map)['id']).toList(), ids);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'QueueTab drag persists group in real SQLite across pages',
    (tester) => verifyMove(tester, end: false),
  );
  testWidgets(
    'QueueTab drop after the last row persists group at global end',
    (tester) => verifyMove(tester, end: true),
  );
  testWidgets(
    'QueueTab exposes global end after loading 305 rows and persists move',
    (tester) => verifyMove(tester, end: true, large: true),
  );
}
