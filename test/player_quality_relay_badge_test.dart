import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('insignia tras un relevo de opus a aac', () {
    late PlayerMetadataController metadata;
    late ValueNotifier<CatalogPreparation?> preparation;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      metadata = PlayerMetadataController();
      preparation = ValueNotifier(null);
    });

    tearDown(() {
      metadata.dispose();
      preparation.dispose();
    });

    testWidgets('muestra AAC, sin dos insignias a la vez a los 2 s ni 2 min', (
      tester,
    ) async {
      await metadata.load(
        const MediaItem(
          id: 'song',
          title: 'Song',
          extras: {
            'source': 'catalog:song',
            'verifiedAudioCodec': 'aac',
            'verifiedAudioSampleRate': 44100,
          },
        ),
      );
      preparation.value = CatalogPreparation(
        key: 'song',
        service: 'a',
        quality: 'opus',
        started: DateTime.now(),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: _host(
            PlayerCoverQuality(
              metadata: metadata,
              colorScheme: const ColorScheme.dark(),
              preparation: preparation,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreparingQualityMark), findsOneWidget);

      preparation.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PreparingQualityMark), findsNothing);
      expect(find.byType(TrackQualitySelector), findsOneWidget);

      for (final wait in [
        const Duration(seconds: 2),
        const Duration(minutes: 2),
      ]) {
        await tester.pump(wait);
        expect(find.byType(PreparingQualityMark), findsNothing);
        expect(find.byType(TrackQualitySelector), findsOneWidget);
        final selector = tester.widget<TrackQualitySelector>(
          find.byType(TrackQualitySelector),
        );
        expect(selector.currentMark, QualityMark.aac);
      }
    });
  });

  group('peticion servida', () {
    Future<CatalogPlayback> playbackWith(
      Directory root,
      Map<String, Object> metadata,
    ) async {
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => false,
              resolvedPreparerFactory: (_, service, _) =>
                  TemporaryTrackPreparer(
                    stagingRoot: Directory(p.join(root.path, 'staging')),
                    download: (directory, _) async => File(
                      p.join(directory.path, 'input'),
                    ).writeAsBytes([1, 2, 3]),
                    takeQualityMetadata: (_) => metadata,
                    cancelDownload: (_) async {},
                    codec: (_) async => 'aac',
                    container: (_) async => 'mp4',
                    validate: (_) async => true,
                  ),
            )
            ..defaultService = 'a'
            ..resolveDownloadService = (requested, _) async =>
                requested.isEmpty ? 'a' : requested;
      playback.resolveStreaming = (quality, service, _) async =>
          StreamingRequest(service.isEmpty ? 'a' : service, 'opus_320');
      return playback;
    }

    test('guarda el candidato servido tras un relevo', () async {
      final root = await Directory.systemTemp.createTemp('served-request-');
      addTearDown(() => root.delete(recursive: true));
      final playback = await playbackWith(root, {'provider': 'a'});
      const track = Track(
        id: 'served-track',
        source: 'spotify',
        name: 'S',
        artistName: 'A',
        albumName: 'B',
        duration: 200,
      );
      final lease = await playback.acquire(track, relay: false);
      await lease.release();
      expect(playback.playingRequest(track)?.quality, 'opus_320');
    });
  });
}
