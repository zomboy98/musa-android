import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/settings/backup_restore_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/backup_service.dart';

import 'support/fixed_settings.dart';

final class _BackupMemoryFile extends PlatformFile {
  _BackupMemoryFile(this.bytes);
  final Uint8List bytes;

  @override
  String get name => 'backup.json';
  @override
  Uri get uri => Uri.parse('memory:backup.json');
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RestoreSettings extends FixedSettingsNotifier {
  int restores = 0;

  @override
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    restores++;
  }
}

class _BackupFilePicker extends FilePickerPlatform {
  bool opened = false;
  PlatformFile? result;

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
  }) async {
    opened = true;
    // A custom JSON/SFLB filter becomes JSON-only on Android because SFLB
    // has no system MIME mapping.
    expect(type, FileType.any);
    expect(allowedExtensions, isNull);
    return result;
  }
}

void main() {
  Future<ProviderContainer> openBackup(
    WidgetTester tester,
    Map<String, dynamic> collections,
    _RestoreSettings settings,
  ) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'magic': BackupService.magic,
          'data': {
            'settings': {'autoDownloadSavedTracks': true},
            'history': <dynamic>[],
            'collections': collections,
          },
        }),
      ),
    );
    final original = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _BackupFilePicker()
      ..result = _BackupMemoryFile(bytes);
    addTearDown(() => FilePickerPlatform.instance = original);
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(() => settings)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BackupRestorePage(),
        ),
      ),
    );
    final restore = find.text('Choose backup file');
    await tester.scrollUntilVisible(restore, 300);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    return container;
  }

  for (final malformed in <dynamic>[
    'invalid',
    [42],
    [
      {'id': 'missing fields'},
    ],
  ]) {
    testWidgets(
      'malformed saved tracks $malformed reject before any restoration',
      (tester) async {
        final settings = _RestoreSettings();
        final container = await openBackup(tester, {
          'savedLibraryTracks': malformed,
        }, settings);
        expect(
          find.text('This file is not a valid MUSA backup'),
          findsOneWidget,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(settings.restores, 0);
        expect(container.exists(downloadHistoryProvider), isFalse);
        expect(container.exists(libraryCollectionsProvider), isFalse);
        expect(container.exists(savedLibraryTracksProvider), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final count in [0, 2]) {
    testWidgets(
      'restore summary includes $count saved songs before replacement',
      (tester) async {
        final settings = _RestoreSettings();
        await openBackup(tester, {
          'savedLibraryTracks': List.generate(
            count,
            (i) => {
              'id': '$i',
              'name': 'Song',
              'artistName': 'Artist',
              'albumName': 'Album',
              'duration': 120,
            },
          ),
        }, settings);
        expect(find.text('Saved songs: $count'), findsOneWidget);
        expect(settings.restores, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'settings-only preset and empty selection update export controls',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BackupRestorePage(),
          ),
        ),
      );
      await tester.tap(find.text('Settings only'));
      await tester.pumpAndSettle();
      final switches = tester
          .widgetList<SettingsSwitchItem>(find.byType(SettingsSwitchItem))
          .toList();
      expect(switches.map((item) => item.value), [
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(switches.last.onChanged, isNull);
      switches.first.onChanged!(false);
      await tester.pumpAndSettle();
      final export = tester
          .widgetList<SettingsItem>(find.byType(SettingsItem))
          .firstWhere((item) => item.icon == Icons.ios_share);
      expect(export.onTap, isNull);
      expect(
        export.subtitle,
        'Select at least one category to create a backup.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restore does not exclude backups with an unknown MIME type', (
    tester,
  ) async {
    final original = FilePickerPlatform.instance;
    final picker = _BackupFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BackupRestorePage(),
        ),
      ),
    );
    final restore = find.text('Choose backup file');
    await tester.scrollUntilVisible(restore, 300);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(picker.opened, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
