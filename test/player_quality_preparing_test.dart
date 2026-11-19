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
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/player_quality_preparing.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {bool reduce = false}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

Widget _mark({double? Function()? real, DateTime? started}) =>
    PreparingQualityMark(
      mark: QualityMark.flac,
      started: started ?? DateTime.now(),
      label: 'FLAC',
      realProgress: real,
    );

String? _value(WidgetTester tester) => tester
    .getSemantics(
      find
          .descendant(
            of: find.byType(PreparingQualityMark),
            matching: find.byType(Semantics),
          )
          .first,
    )
    .value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the expected format fills in and never goes backwards', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    var real = 0.3;
    await tester.pumpWidget(_host(_mark(real: () => real)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_value(tester), '30 %');
    real = 0.6;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_value(tester), '60 %');
    real = 0.2;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_value(tester), '60 %');
    real = 1;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_value(tester), '95 %');
    semantics.dispose();
  });

  testWidgets('without real progress the estimate grows and stays below 100', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _mark(started: DateTime.now().subtract(const Duration(seconds: 2))),
      ),
    );
    var previous = -1;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
      final now = int.parse(_value(tester)!.replaceAll(' %', ''));
      expect(now, greaterThanOrEqualTo(previous));
      expect(now, lessThan(100));
      previous = now;
    }
    expect(previous, greaterThan(0));
  });

  testWidgets('reduced animations fill without a smooth tween', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_host(_mark(real: () => 0.5), reduce: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(_value(tester), '50 %');
    await tester.pumpWidget(_host(_mark(real: () => 0.5)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    semantics.dispose();
  });

  group('player badge', () {
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

    Future<void> pumpBadge(WidgetTester tester, {bool reduce = false}) =>
        tester.pumpWidget(
          ProviderScope(
            child: _host(
              PlayerCoverQuality(
                metadata: metadata,
                colorScheme: const ColorScheme.dark(),
                preparation: preparation,
              ),
              reduce: reduce,
            ),
          ),
        );

    Future<void> loadVerified() async {
      await metadata.load(
        const MediaItem(
          id: 'song',
          title: 'Song',
          extras: {
            'source': 'catalog:song',
            'verifiedAudioCodec': 'flac',
            'verifiedAudioSampleRate': 44100,
          },
        ),
      );
    }

    CatalogPreparation prep() => CatalogPreparation(
      key: 'song',
      service: '',
      quality: 'LOSSLESS',
      started: DateTime.now(),
    );

    testWidgets('shows the expected format while preparing, then the verified '
        'one', (tester) async {
      await loadVerified();
      preparation.value = prep();
      await pumpBadge(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreparingQualityMark), findsOneWidget);
      expect(find.byType(TrackQualitySelector), findsNothing);

      preparation.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreparingQualityMark), findsNothing);
      expect(find.byType(TrackQualitySelector), findsOneWidget);
    });

    testWidgets('a failed preparation leaves nothing half drawn', (
      tester,
    ) async {
      preparation.value = prep();
      await pumpBadge(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreparingQualityMark), findsOneWidget);

      preparation.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PreparingQualityMark), findsNothing);
      expect(find.byType(TrackQualitySelector), findsNothing);
    });

    testWidgets('reduced animations swap without a fade', (tester) async {
      await loadVerified();
      preparation.value = prep();
      await pumpBadge(tester, reduce: true);
      await tester.pump();
      preparation.value = null;
      await tester.pump();
      expect(find.byType(PreparingQualityMark), findsNothing);
      expect(find.byType(TrackQualitySelector), findsOneWidget);
    });
  });

  group('preparation state', () {
    const track = Track(
      id: 'q',
      source: 'spotify',
      name: 'Q',
      artistName: 'A',
      albumName: 'B',
      duration: 1,
    );

    Future<(CatalogPlayback, Completer<void>, Completer<void>)> build(
      Directory root, {
      required bool fail,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final started = Completer<void>();
      final finish = Completer<void>();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        resolvedPreparerFactory: (_, _, _) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            if (!started.isCompleted) started.complete();
            await finish.future;
            if (fail) throw const TemporaryTrackException('network');
            return File('${dir.path}/input').writeAsString('audio');
          },
          takeQualityMetadata: (_) => {'provider': 'A'},
          cancelDownload: (_) async {},
          codec: (_) async => 'aac',
          container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      )..resolveDownloadService = (_, _) async => 'A';
      playback.quality = 'HI_RES_LOSSLESS';
      return (playback, started, finish);
    }

    for (final fail in [false, true]) {
      test('is published while the first preparation runs and cleared when '
          'it ends (fail=$fail)', () async {
        final root = await Directory.systemTemp.createTemp('preparing-');
        addTearDown(() => root.delete(recursive: true));
        final (playback, started, finish) = await build(root, fail: fail);
        expect(playback.preparation.value, isNull);
        final run = playback
            .acquire(track, initial: true)
            .then<Object>((v) => v, onError: (Object e) => e);
        await started.future;
        final active = playback.preparation.value;
        expect(active, isNotNull);
        expect(active!.key, playback.key(track));
        expect(active.quality, 'HI_RES_LOSSLESS');
        finish.complete();
        final result = await run;
        expect(playback.preparation.value, isNull);
        if (fail) {
          expect(result, isA<CatalogPlaybackException>());
        } else {
          await (result as CatalogAudioLease).release();
        }
      });
    }

    test('a quality switch does not publish a preparation', () async {
      final root = await Directory.systemTemp.createTemp('preparing-');
      addTearDown(() => root.delete(recursive: true));
      final (playback, started, finish) = await build(root, fail: false);
      final run = playback.acquire(track);
      await started.future;
      expect(playback.preparation.value, isNull);
      finish.complete();
      await (await run).release();
    });
  });
}
