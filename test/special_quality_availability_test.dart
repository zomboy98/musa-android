import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/l10n/app_localizations_es.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _options = [
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(id: 'DOLBY_ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
];

Track _track({String? modes, String? isrc, String? source, String id = 't1'}) =>
    Track(
      id: id,
      name: 'n',
      artistName: 'a',
      albumName: 'b',
      duration: 100,
      audioModes: modes,
      isrc: isrc,
      source: source,
    );

class _Clock {
  DateTime now = DateTime.utc(2026, 11, 15);
  DateTime call() => now;
}

SpecialQualityAvailability _offline({
  _Clock? clock,
  Directory? dir,
  Future<Map<String, dynamic>> Function(String, String, String)? load,
  bool probe = false,
}) => SpecialQualityAvailability(
  clock: clock?.call,
  directory: dir == null ? null : () async => dir,
  loadMetadata: load ?? (_, _, _) async => throw StateError('offline'),
  probeEnabled: probe,
);

Map<String, Object> _lease({
  String codec = 'flac',
  bool fallback = false,
  String provider = 'tidal',
}) => {
  'output_codec': codec,
  'provider': provider,
  'quality_fallback_used': fallback,
};

bool _offered(
  SpecialQualityAvailability registry,
  Track track, {
  String service = 'tidal-web',
}) => buildTrackQualityChoices(
  options: _options,
  track: track,
  service: service,
  availability: registry,
).firstWhere((c) => c.id == 'DOLBY_ATMOS').available;

void main() {
  group('downloads', () {
    test('an explicit spatial choice never relays down to another class', () {
      for (final id in ['DOLBY_ATMOS', 'ac4', 'eac3', 'ATMOS']) {
        expect(
          downloadQualityRelayAllowed(strict: false, qualityOverride: id),
          isFalse,
        );
      }
      expect(
        downloadQualityRelayAllowed(strict: false, qualityOverride: 'LOSSLESS'),
        isTrue,
      );
      expect(downloadQualityRelayAllowed(strict: false), isTrue);
      expect(downloadQualityRelayAllowed(strict: true), isFalse);
    });

    test('a bulk download that came back as Opus only marks the attempt', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567');
      r.recordPlayback(
        track: t,
        requestedService: 'amzn',
        requestedQuality: 'ac4',
        metadata: _lease(codec: 'opus', provider: 'amazon'),
      );
      expect(r.atmosStatus(t, 'amzn'), SpecialQualityStatus.unknown);
      expect(r.attemptFailed(t, 'amzn', 'ac4'), isTrue);
    });
  });
  group('policy', () {
    test('stereo-only modes hide atmos, atmos modes show it', () {
      final r = _offline();
      expect(_offered(r, _track(modes: 'STEREO')), isFalse);
      expect(_offered(r, _track(modes: 'DOLBY_ATMOS')), isTrue);
      expect(_offered(r, _track(modes: 'STEREO,DOLBY_ATMOS')), isTrue);
    });

    test('unknown is hidden', () {
      final r = _offline();
      expect(
        r.atmosStatus(_track(), 'tidal-web'),
        SpecialQualityStatus.unknown,
      );
      expect(_offered(r, _track()), isFalse);
    });

    test(
      'markUnavailable keeps atmos away even if the catalog declares it',
      () {
        final r = _offline();
        final t = _track(modes: 'DOLBY_ATMOS', isrc: 'USABC1234567');
        expect(_offered(r, t), isTrue);
        r.markUnavailable(t, 'tidal-web');
        expect(_offered(r, t), isFalse);
        expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.unavailable);
      },
    );

    test('a fallback to another quality never hides atmos', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567', modes: 'DOLBY_ATMOS');
      r.recordPlayback(
        track: t,
        requestedService: 'tidal-web',
        requestedQuality: 'DOLBY_ATMOS',
        metadata: _lease(fallback: true),
      );
      expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.confirmed);
      expect(_offered(r, t), isTrue);
      expect(r.attemptFailed(t, 'tidal-web', 'DOLBY_ATMOS'), isTrue);
      expect(r.attemptFailed(t, 'tidal-web', 'LOSSLESS'), isFalse);
    });

    test('a transient failure does not rule atmos out', () {
      final r = _offline();
      final t = _track(modes: 'DOLBY_ATMOS');
      r.recordPlayback(
        track: t,
        requestedService: 'tidal-web',
        requestedQuality: 'DOLBY_ATMOS',
        metadata: _lease(fallback: true, provider: 'qobuz'),
        failureWasUnavailability: false,
      );
      expect(_offered(r, t), isTrue);
    });

    test('a verified E-AC-3 file confirms atmos for that song', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567', modes: 'STEREO');
      expect(_offered(r, t), isFalse);
      r.recordPlayback(
        track: t,
        requestedService: 'tidal-web',
        requestedQuality: 'DOLBY_ATMOS',
        metadata: _lease(codec: 'eac3'),
      );
      expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.confirmed);
      expect(_offered(r, t), isTrue);
    });

    test('amazon codec choices are judged per provider', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567');
      r.recordPlayback(
        track: t,
        requestedService: 'amzn',
        requestedQuality: 'ac4',
        metadata: _lease(codec: 'ac4', provider: 'amazon'),
      );
      expect(r.atmosStatus(t, 'amazon'), SpecialQualityStatus.confirmed);
      expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.unknown);
    });

    test('metadata of another provider says nothing about this one', () {
      final r = _offline();
      final t = _track(modes: 'DOLBY_ATMOS', source: 'tidal-web');
      expect(r.atmosStatus(t, 'amzn'), SpecialQualityStatus.unknown);
    });

    test('the song being played keeps its own option', () {
      final r = _offline();
      final choices = buildTrackQualityChoices(
        options: _options,
        currentId: 'DOLBY_ATMOS',
        track: _track(),
        service: 'tidal-web',
        availability: r,
      );
      expect(
        choices.firstWhere((c) => c.id == 'DOLBY_ATMOS').available,
        isTrue,
      );
    });
  });

  group('ttl', () {
    test('unavailable lasts 30 days, confirmed 90', () {
      final clock = _Clock();
      final r = _offline(clock: clock);
      final bad = _track(isrc: 'AAAAAAAAAAAA');
      final good = _track(isrc: 'BBBBBBBBBBBB');
      r.markUnavailable(bad, 'tidal-web');
      r.markConfirmed(good, 'tidal-web');
      clock.now = clock.now.add(const Duration(days: 29));
      expect(r.atmosStatus(bad, 'tidal-web'), SpecialQualityStatus.unavailable);
      clock.now = clock.now.add(const Duration(days: 2));
      expect(r.atmosStatus(bad, 'tidal-web'), SpecialQualityStatus.unknown);
      expect(r.atmosStatus(good, 'tidal-web'), SpecialQualityStatus.confirmed);
      clock.now = clock.now.add(const Duration(days: 60));
      expect(r.atmosStatus(good, 'tidal-web'), SpecialQualityStatus.unknown);
    });
  });

  group('failed attempts', () {
    final providers = [
      (service: 'tidal-web', options: _options),
      (service: 'amazon', options: _options),
    ];

    List<String> listed(SpecialQualityAvailability registry, Track track) => [
      for (final c in mergeProviderQualityChoices(
        providers,
        track: track,
        availability: registry,
        keepProviderTwins: true,
      ))
        '${c.service}/${c.id}',
    ];

    test('after a failed switch the format is still listed and marked', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567');
      final before = listed(r, t);
      expect(before, contains('tidal-web/DOLBY_ATMOS'));
      expect(before, contains('amazon/DOLBY_ATMOS'));
      for (final service in ['tidal-web', 'amazon']) {
        r.noteAttemptFailed(t, service, 'DOLBY_ATMOS');
        r.noteAttemptFailed(t, service, 'LOSSLESS');
      }
      final after = mergeProviderQualityChoices(
        providers,
        track: t,
        availability: r,
        keepProviderTwins: true,
      );
      expect([for (final c in after) '${c.service}/${c.id}'], before);
      expect(after.every((c) => c.available && c.failedLast), isTrue);
    });

    test(
      'a download failure that says quality unavailable does not hide it',
      () {
        final r = _offline();
        final t = _track(isrc: 'USABC1234567');
        r.recordPlayback(
          track: t,
          requestedService: 'amazon',
          requestedQuality: 'DOLBY_ATMOS',
          metadata: _lease(codec: 'opus', provider: 'amazon'),
        );
        expect(listed(r, t), contains('amazon/DOLBY_ATMOS'));
      },
    );

    test('a later success clears the mark', () {
      final r = _offline();
      final t = _track(isrc: 'USABC1234567');
      r.noteAttemptFailed(t, 'amazon', 'DOLBY_ATMOS');
      r.clearAttemptFailure(t, 'amazon', 'DOLBY_ATMOS');
      expect(r.attemptFailed(t, 'amazon', 'DOLBY_ATMOS'), isFalse);
    });

    test('rules already hidden by catalog data are still reported', () {
      final r = _offline();
      final t = _track(
        isrc: 'USABC1234567',
        modes: 'STEREO',
        source: 'tidal-web',
      );
      final hidden = <String>[];
      mergeProviderQualityChoices(
        providers,
        track: t,
        availability: r,
        keepProviderTwins: true,
        onRuledOut: (service, id) => hidden.add('$service/$id'),
      );
      expect(hidden, ['tidal-web/DOLBY_ATMOS']);
    });
  });

  group('persistence', () {
    test(
      'an unavailable verdict saved by a failed attempt is ignored',
      () async {
        final dir = await Directory.systemTemp.createTemp('availability');
        addTearDown(() => dir.delete(recursive: true));
        final clock = _Clock();
        final t = _track(isrc: 'AAAAAAAAAAAA');
        File('${dir.path}/special_quality_availability.json').writeAsStringSync(
          '{"tidal|AAAAAAAAAAAA":{"atmos":"unavailable","checkedAt":'
          '"${clock.now.toIso8601String()}"}}',
        );
        final r = _offline(clock: clock, dir: dir);
        await r.ensureLoaded();
        expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.unknown);
      },
    );

    test('saves and reads back from disk, dropping expired entries', () async {
      final dir = await Directory.systemTemp.createTemp('availability');
      addTearDown(() => dir.delete(recursive: true));
      final clock = _Clock();
      final first = _offline(clock: clock, dir: dir);
      final bad = _track(isrc: 'AAAAAAAAAAAA');
      final good = _track(isrc: 'BBBBBBBBBBBB');
      first.markUnavailable(bad, 'tidal-web');
      first.markConfirmed(good, 'amzn');
      await first.flush();

      final second = _offline(clock: clock, dir: dir);
      await second.ensureLoaded();
      expect(
        second.atmosStatus(bad, 'tidal-web'),
        SpecialQualityStatus.unavailable,
      );
      expect(second.atmosStatus(good, 'amzn'), SpecialQualityStatus.confirmed);

      clock.now = clock.now.add(const Duration(days: 40));
      final third = _offline(clock: clock, dir: dir);
      await third.ensureLoaded();
      expect(third.atmosStatus(bad, 'tidal-web'), SpecialQualityStatus.unknown);
      expect(third.atmosStatus(good, 'amzn'), SpecialQualityStatus.confirmed);
    });
  });

  group('probe', () {
    test(
      'shows checking, then confirms when the catalog lists atmos',
      () async {
        final gate = Completer<Map<String, dynamic>>();
        final calls = <String>[];
        final r = _offline(
          probe: true,
          load: (provider, type, id) {
            calls.add('$provider/$type/$id');
            return gate.future;
          },
        );
        final t = _track(id: '77');
        final choice = buildTrackQualityChoices(
          options: _options,
          track: t,
          service: 'tidal-web',
          availability: r,
        ).firstWhere((c) => c.id == 'DOLBY_ATMOS');
        expect(choice.checking, isTrue);
        await pumpEventQueue();
        expect(calls, ['tidal-web/track/77']);
        gate.complete({
          'track': {'id': '77', 'audio_modes': 'DOLBY_ATMOS'},
        });
        await pumpEventQueue();
        expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.confirmed);
        expect(_offered(r, t), isTrue);
      },
    );

    test(
      'tidal and amazon answering without atmos both conclude negative',
      () async {
        final r = _offline(
          probe: true,
          load: (_, _, id) async => {
            'track': {'id': id, 'name': 'x', 'audio_modes': ''},
          },
        );
        final tidal = _track(id: '1');
        final amazon = _track(id: 'B0001');
        r.atmosStatus(tidal, 'tidal-web');
        r.atmosStatus(amazon, 'amzn');
        await pumpEventQueue();
        expect(
          r.atmosStatus(tidal, 'tidal-web'),
          SpecialQualityStatus.unavailable,
        );
        expect(r.atmosStatus(amazon, 'amzn'), SpecialQualityStatus.unconfirmed);
      },
    );

    test('an answer about another track proves nothing', () async {
      final r = _offline(
        probe: true,
        load: (_, _, _) async => {
          'track': {'id': '999', 'name': 'other', 'audio_modes': ''},
        },
      );
      final t = _track(id: '1');
      r.atmosStatus(t, 'tidal-web');
      await pumpEventQueue();
      expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.unknown);
    });

    List<TrackQualityChoice> onRequest(
      SpecialQualityAvailability r,
      Track t,
      String service,
    ) => buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
      track: t,
      service: service,
      availability: r,
      spatialOnRequest: true,
    );

    test(
      'a finished lookup without atmos keeps the row offered on request',
      () async {
        final r = _offline(
          probe: true,
          load: (_, _, id) async => {
            'track': {'id': id, 'name': 'x', 'audio_modes': ''},
          },
        );
        final t = _track(id: 'B0001', source: 'amazon');
        final during = onRequest(r, t, 'amazon');
        final row = during.firstWhere((c) => c.id == 'DOLBY_ATMOS');
        expect(row.available, isTrue);
        expect(row.checking, isTrue);
        await pumpEventQueue();
        final after = onRequest(r, t, 'amazon');
        expect(
          after.firstWhere((c) => c.id == 'DOLBY_ATMOS').available,
          isTrue,
        );
        expect(after.firstWhere((c) => c.id == 'LOSSLESS').available, isTrue);
      },
    );

    test(
      'a lookup that could not run leaves atmos offered unconfirmed',
      () async {
        final r = _offline(probe: true);
        final t = _track(id: 'B0002', source: 'amazon');
        onRequest(r, t, 'amazon');
        await pumpEventQueue();
        final row = onRequest(
          r,
          t,
          'amazon',
        ).firstWhere((c) => c.id == 'DOLBY_ATMOS');
        expect(row.available, isTrue);
        expect(row.checking, isFalse);
      },
    );

    test('a confirming lookup keeps the row offered', () async {
      final r = _offline(
        probe: true,
        load: (_, _, id) async => {
          'track': {'id': id, 'audio_modes': 'STEREO,DOLBY_ATMOS'},
        },
      );
      final t = _track(id: 'B0003', source: 'amazon');
      onRequest(r, t, 'amazon');
      await pumpEventQueue();
      final row = onRequest(
        r,
        t,
        'amazon',
      ).firstWhere((c) => c.id == 'DOLBY_ATMOS');
      expect(row.available, isTrue);
      expect(row.checking, isFalse);
    });

    test('a failed ac4 download does not hide a row never probed negative', () {
      final r = _offline();
      final t = _track(id: 'B0004', source: 'amazon', isrc: 'USABC1234567');
      r.noteAttemptFailed(t, 'amazon', 'DOLBY_ATMOS');
      final row = onRequest(
        r,
        t,
        'amazon',
      ).firstWhere((c) => c.id == 'DOLBY_ATMOS');
      expect(row.available, isTrue);
      expect(row.failedLast, isTrue);
    });

    test('the unavailable spatial notice is plain Spanish', () {
      expect(
        AppLocalizationsEs().qualityPickerSwitchSpatialUnavailable('Atmos'),
        'Atmos no está disponible para esta canción',
      );
    });

    test('a slow lookup never blocks and ends hidden', () async {
      final r = _offline(
        probe: true,
        load: (_, _, _) => Completer<Map<String, dynamic>>().future,
      );
      final t = _track(id: '5');
      expect(r.atmosStatus(t, 'tidal-web'), SpecialQualityStatus.checking);
    });
  });

  group('selector', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Widget host(List<TrackQualityChoice> choices, List<String> picked) =>
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_SelectorSettings.new),
            lowEndDeviceProvider.overrideWithValue(false),
            backdropBlurEnabledProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  height: 48,
                  child: TrackQualitySelector(
                    currentFormat: QualityBadgeFormat.flac,
                    currentLabel: 'FLAC 16-bit',
                    lockup: true,
                    choices: choices,
                    onSelected: (c) => picked.add(c.id),
                    onShowInfo: () {},
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('a checking atmos cell is dimmed and does nothing', (
      tester,
    ) async {
      final r = _offline(
        probe: true,
        load: (_, _, _) => Completer<Map<String, dynamic>>().future,
      );
      final picked = <String>[];
      final choices = buildTrackQualityChoices(
        options: _options,
        currentId: 'LOSSLESS',
        track: _track(id: '9'),
        service: 'tidal-web',
        availability: r,
      );
      await tester.pumpWidget(host(choices, picked));
      await tester.tap(find.byType(TrackQualitySelector));
      await tester.pumpAndSettle();
      expect(find.text('Comprobando…'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('quality-choice-DOLBY_ATMOS')),
      );
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
    });

    testWidgets('a ruled-out atmos has no cell', (tester) async {
      final r = _offline();
      final choices = buildTrackQualityChoices(
        options: _options,
        currentId: 'LOSSLESS',
        track: _track(modes: 'STEREO'),
        service: 'tidal-web',
        availability: r,
      );
      await tester.pumpWidget(host(choices, <String>[]));
      await tester.tap(find.byType(TrackQualitySelector));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quality-choice-DOLBY_ATMOS')),
        findsNothing,
      );
      expect(find.text('Comprobando…'), findsNothing);
    });
  });
}

class _SelectorSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}
