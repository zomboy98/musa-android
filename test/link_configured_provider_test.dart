import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/download_service_picker.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(defaultService: 'missing', autoFallback: false);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'other',
        name: 'Other',
        displayName: 'Other',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

class _SelectedSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    defaultService: 'other',
    audioQuality: 'HI_RES',
    autoFallback: false,
  );
}

class _Queue extends DownloadQueueNotifier {
  String? _receivedService;
  String? _receivedQuality;
  AppSettings? _receivedSettings;
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
    _receivedService = service;
    _receivedSettings = ref.read(settingsProvider);
    return 'queued';
  }

  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) {
    _receivedService = service;
    _receivedQuality = qualityOverride;
    _receivedSettings = ref.read(settingsProvider);
    return 'queued';
  }
}

void main() {
  test('Link preserves explicit remote provider and quality', () {
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(() => queue),
      ],
    );
    addTearDown(container.dispose);
    const track = Track(
      id: '1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    expect(
      container
          .read(linkDesktopDownloadsProvider)
          .enqueue([track], service: ' remote ', quality: 'FLAC'),
      1,
    );
    expect(queue._receivedService, 'remote');
    expect(queue._receivedQuality, 'FLAC');
  });
  testWidgets('single download enqueues configured settings without a picker', (
    tester,
  ) async {
    final queue = _Queue();
    const track = Track(
      id: '1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_SelectedSettings.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => downloadSingleTrack(
                  context,
                  ref,
                  track,
                  forceQualityPicker: true,
                ),
                child: const Text('Download'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(queue._receivedService, 'other');
    expect(queue._receivedQuality, isNull);
    expect(queue._receivedSettings!.audioQuality, 'HI_RES');
    expect(queue._receivedSettings!.autoFallback, isFalse);
    expect(find.byType(DownloadServicePicker), findsNothing);
  });
  test(
    'Link does not substitute another provider when fallback is disabled',
    () {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
        ],
      );
      addTearDown(container.dispose);
      const track = Track(
        id: '1',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      expect(
        () => container.read(linkDesktopDownloadsProvider).enqueue([track]),
        throwsA(isA<LinkException>()),
      );
    },
  );
}
