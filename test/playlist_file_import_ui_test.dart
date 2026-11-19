import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playlist_link_import_test.dart' show FakeCollections, FakeResolver;

final class MemoryFile extends PlatformFile {
  MemoryFile(this.filename, this.content);
  final String filename;
  final String content;
  @override
  String get name => filename;
  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList(utf8.encode(content));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Picker extends FilePickerPlatform {
  Picker(this.file);
  final PlatformFile file;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => file;
}

class EmptyLibrary extends Fake implements LibraryDatabase {
  @override
  Future<List<LibraryFilePathRow>> getFilePathRows() async => [];
  @override
  Future<List<Map<String, dynamic>>> getByIds(List<String> ids) async => [];
  @override
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async => List.filled(requests.length, null);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final extension in ['csv', 'm3u8']) {
    testWidgets('$extension selection keeps ordered duplicates without download', (
      tester,
    ) async {
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = Picker(
        MemoryFile(
          'Mix.$extension',
          extension == 'csv'
              ? 'Track Name,Artist Name,Album Name\nFirst,Artist,Album\nSecond,Artist,Album\nFirst,Artist,Album\n'
              : '#EXTM3U\n#EXTINF:1,Artist - First\nfirst.mp3\n#EXTINF:1,Artist - Second\nsecond.mp3\n#EXTINF:1,Artist - First\nfirst.mp3\n',
        ),
      );
      addTearDown(() => FilePickerPlatform.instance = original);
      final collections = FakeCollections();
      final resolver = FakeResolver();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryCollectionsProvider.overrideWith(() => collections),
            linkDesktopDownloadsProvider.overrideWithValue(resolver),
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
      expect(find.text('Choose tracks'), findsOneWidget);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .map((tile) => tile.value),
        [true, true, true],
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.tracks.map((track) => track.name), [
        'First',
        'Second',
        'First',
      ]);
      expect(resolver.downloads, 0);
      collections.tracks.clear();
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
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(collections.tracks, isEmpty);
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
      await tester.tap(find.byKey(const ValueKey('import_track_0')));
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.tracks.map((track) => track.name), [
        'Second',
        'First',
      ]);
      expect(resolver.downloads, 0);
    });
  }
  testWidgets(
    'small screen with enlarged text supports selection and cancellation',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final collections = FakeCollections();
      final resolver = FakeResolver();
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = Picker(
        MemoryFile(
          'Mix.csv',
          'Track Name,Artist Name,Album Name\nOne,Artist,Album\nTwo,Artist,Album\nOne,Artist,Album\n',
        ),
      );
      addTearDown(() => FilePickerPlatform.instance = original);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryCollectionsProvider.overrideWith(() => collections),
            linkDesktopDownloadsProvider.overrideWithValue(resolver),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
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
      Future<void> showSelection() async {
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
        expect(find.text('Choose tracks'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await showSelection();
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('import_track_0')),
        100,
        scrollable: scrollable,
      );
      await tester.tap(find.byKey(const ValueKey('import_track_0')));
      await tester.scrollUntilVisible(
        find.text('Import'),
        -100,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(collections.tracks.map((track) => track.name), ['Two', 'One']);
      expect(tester.takeException(), isNull);
      collections.tracks.clear();
      await showSelection();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(collections.tracks, isEmpty);
      expect(resolver.downloads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
