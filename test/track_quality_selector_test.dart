import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/quality_badge_art.dart';
import 'package:mornye/widgets/quality_mark_art.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _options = [
  QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(
    id: 'HI_RES_LOSSLESS',
    label: 'Hi-Res 24-bit',
    kind: 'lossless',
  ),
  QualityOption(id: 'ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

Widget _scope(Widget child) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(_Settings.new),
    lowEndDeviceProvider.overrideWithValue(false),
    backdropBlurEnabledProvider.overrideWithValue(false),
  ],
  child: child,
);

Widget _host(Widget child, {double width = 320, double scale = 1}) => _scope(
  MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 640),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(height: 48, child: child),
        ),
      ),
    ),
  ),
);

TrackQualitySelector _selector(
  List<TrackQualityChoice> choices,
  List<String> picked, {
  bool replacesFile = false,
}) => TrackQualitySelector(
  currentFormat: QualityBadgeFormat.flac,
  currentLabel: 'FLAC 16-bit',
  lockup: true,
  choices: choices,
  replacesFile: replacesFile,
  onSelected: (c) => picked.add(c.id),
  onShowInfo: () {},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  streamingChoicesTests();
  duplicateChoicesTests();
  test('choices mark the current quality and rule out spatial per song', () {
    final withModes = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
      track: const Track(
        id: 't',
        name: 'n',
        artistName: 'a',
        albumName: 'b',
        duration: 1,
        audioModes: 'STEREO',
      ),
    );
    expect(withModes.where((c) => c.current).map((c) => c.id), ['LOSSLESS']);
    expect(withModes.firstWhere((c) => c.id == 'ATMOS').available, isFalse);
    expect(withModes.firstWhere((c) => c.id == 'AAC_96').available, isTrue);
    final noTrack = buildTrackQualityChoices(options: _options);
    expect(noTrack.every((c) => c.available), isTrue);
    final unknown = buildTrackQualityChoices(
      options: _options,
      availability: SpecialQualityAvailability(probeEnabled: false),
      track: const Track(
        id: 't',
        name: 'n',
        artistName: 'a',
        albumName: 'b',
        duration: 1,
      ),
    );
    expect(unknown.firstWhere((c) => c.id == 'ATMOS').available, isFalse);
    expect(qualityBadgeFormatFor('HI_RES_LOSSLESS'), QualityBadgeFormat.hiRes);
    expect(qualityBadgeFormatFor('ATMOS'), QualityBadgeFormat.spatial);
    expect(qualityBadgeFormatFor('AAC_96'), QualityBadgeFormat.aac);
  });

  testWidgets('the row shows the bare logo: no plate and no arrows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _selector(
          buildTrackQualityChoices(options: _options, currentId: 'LOSSLESS'),
          [],
        ),
      ),
    );
    expect(find.byType(QualityMarkLockup), findsOneWidget);
    expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TrackQualitySelector),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
    expect(find.text('FLAC'), findsWidgets);
    expect(find.text('Free Lossless'), findsOneWidget);
    expect(find.text('Audio Codec'), findsOneWidget);
  });

  testWidgets('the popover lists only available formats, as glass', (
    tester,
  ) async {
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
      track: const Track(
        id: 't',
        name: 'n',
        artistName: 'a',
        albumName: 'b',
        duration: 1,
        audioModes: 'STEREO',
      ),
    );
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('track-quality-panel'));
    expect(panel, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byType(QualityBadgeArt)),
      findsNWidgets(3),
    );
    expect(find.text('ATMOS'), findsNothing);
    expect(find.textContaining('96 kbps'), findsOneWidget);
    final base = tester.widget<Material>(
      find.descendant(of: panel, matching: find.byType(Material)).first,
    );
    expect(base.type, MaterialType.transparency);
  });

  testWidgets('options are compact icon-in-circle rows, one column', (
    tester,
  ) async {
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    final icons = find.byKey(const ValueKey('quality-row-icon'));
    expect(icons, findsNWidgets(4));
    for (final element in icons.evaluate()) {
      final box = element.widget as Container;
      expect((box.decoration as BoxDecoration).shape, BoxShape.circle);
      expect(tester.getSize(find.byWidget(box)).width, lessThanOrEqualTo(32));
    }
    final lefts = {
      for (final e in icons.evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dx,
    };
    expect(lefts, hasLength(1));
    Finder inPanel(String text) => find.descendant(
      of: find.byKey(const ValueKey('track-quality-panel')),
      matching: find.text(text),
    );
    expect(inPanel('Hi-Res'), findsOneWidget);
    expect(inPanel('FLAC'), findsOneWidget);
    expect(inPanel('AAC'), findsOneWidget);
    final selected = find.descendant(
      of: find.byKey(const ValueKey('quality-choice-LOSSLESS')),
      matching: find.byIcon(Icons.check_rounded),
    );
    expect(selected, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quality-choice-AAC_96')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('there is no big minimise button and Escape closes', (
    tester,
  ) async {
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-hide')), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
  });

  testWidgets('tapping outside also hides the window', (tester) async {
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(160, 4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
  });

  testWidgets('choosing a format reports it and closes the window', (
    tester,
  ) async {
    final picked = <String>[];
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(_host(_selector(choices, picked)));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-choice-ATMOS')));
    await tester.pump();
    expect(picked, ['ATMOS']);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quality-choice-ATMOS')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-choice-LOSSLESS')));
    await tester.pumpAndSettle();
    expect(picked, ['ATMOS']);
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
  });

  const manyAac = [
    QualityOption(id: 'AAC_320', label: 'AAC 320 kbps', kind: 'lossy'),
    QualityOption(id: 'AAC_256', label: 'AAC 256 kbps', kind: 'lossy'),
    QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
    QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  ];
  final panel = find.byKey(const ValueKey('track-quality-panel'));
  final aacMenu = find.byKey(const ValueKey('track-quality-group-menu'));
  final aacGroup = find.byKey(const ValueKey('quality-choice-group-aac'));

  testWidgets('several AAC collapse into one cell with a submenu', (
    tester,
  ) async {
    final picked = <String>[];
    final choices = [
      for (final c in buildTrackQualityChoices(
        options: manyAac,
        currentId: 'AAC_96',
      ))
        if (c.id == 'AAC_256')
          TrackQualityChoice(
            id: c.id,
            label: c.label,
            format: c.format,
            kind: c.kind,
            detail: c.detail,
            available: false,
          )
        else
          c,
    ];
    await tester.pumpWidget(_host(_selector(choices, picked)));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(aacGroup, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.text('AAC')),
      findsOneWidget,
    );
    expect(find.textContaining('96–320 kbps'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(aacMenu, findsNothing);
    expect(find.byKey(const ValueKey('quality-choice-AAC_320')), findsNothing);
    await tester.tap(aacGroup);
    await tester.pumpAndSettle();
    expect(aacMenu, findsOneWidget);
    expect(panel, findsOneWidget);
    expect(find.byKey(const ValueKey('quality-choice-AAC_320')), findsOne);
    expect(find.byKey(const ValueKey('quality-choice-AAC_96')), findsOne);
    expect(find.byKey(const ValueKey('quality-choice-AAC_256')), findsNothing);
    expect(
      tester.getTopLeft(find.text('AAC 320 kbps')).dy,
      lessThan(tester.getTopLeft(find.text('AAC 96 kbps')).dy),
    );
    expect(
      find.descendant(of: aacMenu, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    for (final row in ['AAC_320', 'AAC_96']) {
      expect(
        tester.getSize(find.byKey(ValueKey('quality-choice-$row'))).height,
        greaterThanOrEqualTo(44),
      );
    }
    await tester.tap(find.byKey(const ValueKey('quality-choice-AAC_320')));
    await tester.pumpAndSettle();
    expect(picked, ['AAC_320']);
    expect(panel, findsNothing);
    expect(aacMenu, findsNothing);
  });

  testWidgets('back closes the AAC submenu before the window', (tester) async {
    await tester.pumpWidget(
      _host(
        _selector(
          buildTrackQualityChoices(options: manyAac, currentId: 'LOSSLESS'),
          [],
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(aacGroup);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(aacMenu, findsNothing);
    expect(panel, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
  });

  testWidgets('a single AAC is a direct option without arrow', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        _selector(
          buildTrackQualityChoices(options: _options, currentId: 'LOSSLESS'),
          picked,
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(aacGroup, findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    await tester.tap(find.byKey(const ValueKey('quality-choice-AAC_96')));
    await tester.pumpAndSettle();
    expect(picked, ['AAC_96']);
  });

  testWidgets('without AAC there is no AAC cell', (tester) async {
    await tester.pumpWidget(
      _host(
        _selector(
          buildTrackQualityChoices(
            options: [
              for (final o in _options)
                if (o.id != 'AAC_96') o,
            ],
            currentId: 'LOSSLESS',
          ),
          [],
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(aacGroup, findsNothing);
    expect(
      find.descendant(of: panel, matching: find.text('AAC')),
      findsNothing,
    );
  });

  testWidgets('the popover scales in from the chip, unless motion is reduced', (
    tester,
  ) async {
    final choices = buildTrackQualityChoices(
      options: manyAac,
      currentId: 'LOSSLESS',
    );
    ScaleTransition scale() => tester.widget<ScaleTransition>(
      find.ancestor(of: panel, matching: find.byType(ScaleTransition)).first,
    );
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(scale().scale.value, inExclusiveRange(0.92, 1));
    await tester.pumpAndSettle();
    expect(scale().scale.value, 1);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_host(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pump();
    expect(panel, findsOneWidget);
    expect(scale().scale.value, 1);
    await tester.tap(aacGroup);
    await tester.pump();
    expect(aacMenu, findsOneWidget);
    expect(
      tester
          .widget<ScaleTransition>(
            find
                .ancestor(of: aacMenu, matching: find.byType(ScaleTransition))
                .first,
          )
          .scale
          .value,
      1,
    );
  });

  testWidgets('the requested logo starts grey and fills with the progress', (
    tester,
  ) async {
    Widget build(double progress) => _host(
      TrackQualitySelector(
        currentFormat: QualityBadgeFormat.aac,
        currentLabel: 'AAC 96 kbps',
        choices: const [],
        lockup: true,
        switching: true,
        pendingMark: QualityMark.flac,
        progress: progress,
        onSelected: (_) {},
      ),
    );
    double factor() => tester
        .widget<Align>(
          find.descendant(
            of: find.byType(ClipRect),
            matching: find.byType(Align),
          ),
        )
        .widthFactor!;
    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    expect(find.text('FLAC'), findsNWidgets(2));
    expect(factor(), closeTo(0, 0.01));
    await tester.pumpWidget(build(0.5));
    await tester.pumpAndSettle();
    expect(factor(), closeTo(0.5, 0.01));
    await tester.pumpWidget(build(1));
    await tester.pumpAndSettle();
    expect(factor(), closeTo(1, 0.01));
  });

  testWidgets('without offers the panel shows the current quality and info', (
    tester,
  ) async {
    var infoOpened = 0;
    await tester.pumpWidget(
      _host(
        TrackQualitySelector(
          currentFormat: QualityBadgeFormat.flac,
          currentLabel: 'FLAC',
          choices: const [],
          onSelected: (_) {},
          onShowInfo: () => infoOpened++,
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('track-quality-only-current')),
      findsOneWidget,
    );
    expect(find.text('FLAC'), findsWidgets);
    expect(infoOpened, 0);
    await tester.tap(find.byKey(const ValueKey('track-quality-info')));
    await tester.pumpAndSettle();
    expect(infoOpened, 1);
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
  });

  test('providers merge into one entry per format, first provider wins', () {
    final merged = mergeProviderQualityChoices(
      [
        (
          service: 'tidal',
          options: const [
            QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
            QualityOption(id: 'AAC_320', label: 'AAC 320 kbps', kind: 'lossy'),
            QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit 44.1 kHz'),
          ],
        ),
        (
          service: 'amazon',
          options: const [
            QualityOption(id: 'aac_96', label: 'AAC 96 kbps', kind: 'lossy'),
            QualityOption(id: 'FLAC_24', label: 'FLAC 24-bit 96 kHz'),
            QualityOption(id: 'mp3_320', label: 'MP3 320 kbps', kind: 'lossy'),
          ],
        ),
      ],
      currentService: 'tidal',
      currentId: 'AAC_96',
    );
    expect(merged.map((c) => c.mark), [
      QualityMark.hiRes,
      QualityMark.flac,
      QualityMark.aac,
      QualityMark.aac,
      QualityMark.mp3,
    ]);
    expect(merged.where((c) => c.current).map((c) => c.id), ['AAC_96']);
    expect(merged.firstWhere((c) => c.id == 'AAC_96').service, 'tidal');
    expect(merged.where((c) => c.detail == '96 kbps'), hasLength(1));
  });

  test('a probed codec wins over the declared tier', () {
    expect(
      verifiedQualityMark(declared: QualityMark.lossless, codec: 'flac'),
      QualityMark.flac,
    );
    expect(
      verifiedQualityMark(
        declared: QualityMark.lossless,
        codec: 'flac',
        sampleRate: 96000,
      ),
      QualityMark.hiRes,
    );
    expect(
      verifiedQualityMark(declared: QualityMark.flac, codec: 'aac'),
      QualityMark.aac,
    );
    expect(
      verifiedQualityMark(declared: QualityMark.atmos, codec: 'aac'),
      QualityMark.aac,
    );
    expect(verifiedQualityMark(declared: QualityMark.max), QualityMark.max);
    expect(qualityMarkFor('opus_128', 'Opus 128 kbps'), QualityMark.opus);
    expect(qualityDetailFor('AAC_96', 'AAC 96 kbps'), '96 kbps');
    expect(
      qualityDetailFor('', '', sampleRate: 96000, bitDepth: 24),
      '24-bit / 96 kHz',
    );
  });

  final mixed = mergeProviderQualityChoices([
    (
      service: 'tidal-web',
      options: const [
        QualityOption(id: 'LOSSLESS', label: 'Lossless', kind: 'lossless'),
        QualityOption(id: 'HIGH', label: 'High', kind: 'lossy'),
        QualityOption(id: 'LOW', label: 'Low', kind: 'lossy'),
      ],
    ),
    (
      service: 'ytmusic-spotiflac',
      options: const [
        QualityOption(id: 'opus_160', label: 'Opus 160 kbps', kind: 'lossy'),
        QualityOption(id: 'opus_64', label: 'Opus 64 kbps', kind: 'lossy'),
      ],
    ),
    (
      service: 'soundcloud',
      options: const [
        QualityOption(id: 'mp3_128', label: 'MP3 128 kbps', kind: 'lossy'),
      ],
    ),
  ]);
  final opusGroup = find.byKey(const ValueKey('quality-choice-group-opus'));
  final groupMenu = find.byKey(const ValueKey('track-quality-group-menu'));

  test('lossy options of every provider are classified by codec', () {
    expect(mixed.map((c) => (c.service, c.mark, c.detail)).toList(), [
      ('tidal-web', QualityMark.lossless, null),
      ('tidal-web', QualityMark.aac, '320 kbps'),
      ('tidal-web', QualityMark.aac, '96 kbps'),
      ('soundcloud', QualityMark.mp3, '128 kbps'),
      ('ytmusic-spotiflac', QualityMark.opus, '160 kbps'),
      ('ytmusic-spotiflac', QualityMark.opus, '64 kbps'),
    ]);
    expect(mixed.any((c) => c.mark == QualityMark.lossy), isFalse);
  });

  testWidgets('lossy codecs get their own cells, with no loose Tidal ones', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_selector(mixed, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    Finder inPanel(String text) =>
        find.descendant(of: panel, matching: find.text(text));
    Finder inPanelPart(String text) =>
        find.descendant(of: panel, matching: find.textContaining(text));
    expect(inPanel('AAC'), findsOneWidget);
    expect(inPanelPart('96–320 kbps'), findsOneWidget);
    expect(inPanel('Opus'), findsOneWidget);
    expect(inPanelPart('64–160 kbps'), findsOneWidget);
    expect(inPanel('MP3'), findsOneWidget);
    expect(inPanelPart('128 kbps'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));
    expect(find.textContaining('Con pérdida'), findsNothing);
    expect(find.textContaining('HIGH'), findsNothing);
    expect(find.textContaining('LOW'), findsNothing);
    expect(aacGroup, findsOneWidget);
    expect(opusGroup, findsOneWidget);
    expect(find.byKey(const ValueKey('quality-choice-mp3_128')), findsOne);
  });

  testWidgets('the Opus submenu lists detail without provider, best first', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_selector(mixed, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(opusGroup);
    await tester.pumpAndSettle();
    expect(groupMenu, findsOneWidget);
    expect(find.text('OPUS 160 kbps'), findsOneWidget);
    expect(find.text('OPUS 64 kbps'), findsOneWidget);
    expect(find.text('YouTube Music'), findsNothing);
    expect(
      tester.getTopLeft(find.text('OPUS 160 kbps')).dy,
      lessThan(tester.getTopLeft(find.text('OPUS 64 kbps')).dy),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('quality-choice-opus_64')))
          .height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('the Tidal AAC submenu lists each tier without the provider', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_selector(mixed, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(aacGroup);
    await tester.pumpAndSettle();
    expect(find.text('AAC 320 kbps'), findsOneWidget);
    expect(find.text('AAC 96 kbps'), findsOneWidget);
    expect(find.textContaining('Tidal'), findsNothing);
  });

  testWidgets('picking a row passes on the provider that offers it', (
    tester,
  ) async {
    final picked = <TrackQualityChoice>[];
    await tester.pumpWidget(
      _host(
        TrackQualitySelector(
          currentFormat: QualityBadgeFormat.flac,
          currentLabel: 'Lossless',
          lockup: true,
          choices: mixed,
          onSelected: picked.add,
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(opusGroup);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-choice-opus_64')));
    await tester.pumpAndSettle();
    expect(picked.single.id, 'opus_64');
    expect(picked.single.service, 'ytmusic-spotiflac');
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-choice-mp3_128')));
    await tester.pumpAndSettle();
    expect(picked.last.service, 'soundcloud');
  });

  testWidgets('unknown codecs share one generic lossy group', (tester) async {
    final unknown = mergeProviderQualityChoices([
      (
        service: 'amazon',
        options: const [
          QualityOption(id: 'std', label: 'Standard', kind: 'lossy'),
        ],
      ),
      (
        service: 'ytmusic-spotiflac',
        options: const [
          QualityOption(id: 'best', label: 'Best Audio', kind: 'lossy'),
        ],
      ),
    ]);
    await tester.pumpWidget(_host(_selector(unknown, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('quality-choice-group-lossy'));
    expect(group, findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Best Audio'), findsOneWidget);
    expect(find.text('Amazon Music'), findsNothing);
    expect(find.text('YouTube Music'), findsNothing);
  });

  for (final width in [320.0, 360.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('no overflow at $width dp and text x$scale', (tester) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final choices = buildTrackQualityChoices(
          options: _options,
          currentId: 'LOSSLESS',
        );
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: width,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _selector(choices, [], replacesFile: true),
              ),
            ),
            width: width,
            scale: scale,
          ),
        );
        await tester.tap(find.byType(TrackQualitySelector));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('track-quality-panel')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        for (final format in QualityBadgeFormat.values) {
          expect(QualityBadgeArt.widthFor(format, 22), lessThan(110));
        }
      });
    }
  }

  Widget plainHost(Widget child) => _scope(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(height: 48, child: child),
        ),
      ),
    ),
  );

  testWidgets('system back closes the window and keeps the page', (
    tester,
  ) async {
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(plainHost(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
    expect(find.byType(TrackQualitySelector), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the song closes the window and drops the choice', (
    tester,
  ) async {
    final picked = <String>[];
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    Widget build(String key) => plainHost(
      TrackQualitySelector(
        currentFormat: QualityBadgeFormat.flac,
        currentLabel: 'FLAC 16-bit',
        lockup: true,
        choices: choices,
        trackKey: key,
        onSelected: (c) => picked.add(c.id),
      ),
    );
    await tester.pumpWidget(build('a'));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
    await tester.pumpWidget(build('b'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
    expect(picked, isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('the open window updates in place', () {
    TrackQualityChoice row(
      String id,
      QualityBadgeFormat format, {
      bool checking = false,
      bool failedLast = false,
      bool current = false,
    }) => TrackQualityChoice(
      id: id,
      label: id,
      format: format,
      kind: 'lossless',
      checking: checking,
      failedLast: failedLast,
      current: current,
    );

    Widget build(
      List<TrackQualityChoice> choices, {
      String key = 'a',
      List<String>? picked,
    }) => plainHost(
      TrackQualitySelector(
        currentFormat: QualityBadgeFormat.flac,
        currentLabel: 'FLAC 16-bit',
        lockup: true,
        choices: choices,
        trackKey: key,
        onSelected: (c) => picked?.add(c.id),
      ),
    );

    final panel = find.byKey(const ValueKey('track-quality-panel'));
    final atmosRow = find.byKey(const ValueKey('quality-choice-ATMOS'));

    Future<void> open(WidgetTester tester, Widget host) async {
      await tester.pumpWidget(host);
      await tester.tap(find.byType(TrackQualitySelector));
      await tester.pumpAndSettle();
    }

    testWidgets('checking turns into its final state and the panel stays', (
      tester,
    ) async {
      await open(
        tester,
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial, checking: true),
        ]),
      );
      expect(panel, findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);
      await tester.pumpWidget(
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial),
        ]),
      );
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(atmosRow, findsOneWidget);
      expect(find.text('Checking…'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed-last mark appears without closing', (tester) async {
      await open(
        tester,
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial),
        ]),
      );
      await tester.pumpWidget(
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial, failedLast: true),
        ]),
      );
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(find.textContaining('Failed last time'), findsOneWidget);
    });

    testWidgets('a row that disappears leaves the panel open and shorter', (
      tester,
    ) async {
      await open(
        tester,
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial, checking: true),
          row('HI_RES_LOSSLESS', QualityBadgeFormat.hiRes),
        ]),
      );
      final before = tester.getSize(panel).height;
      await tester.pumpWidget(
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('HI_RES_LOSSLESS', QualityBadgeFormat.hiRes),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(atmosRow, findsNothing);
      expect(tester.getSize(panel).height, lessThan(before));
      await tester.pumpWidget(
        build([
          row('LOSSLESS', QualityBadgeFormat.flac, current: true),
          row('ATMOS', QualityBadgeFormat.spatial),
          row('HI_RES_LOSSLESS', QualityBadgeFormat.hiRes),
        ]),
      );
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(atmosRow, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('another song still closes the window', (tester) async {
      final rows = [
        row('LOSSLESS', QualityBadgeFormat.flac, current: true),
        row('ATMOS', QualityBadgeFormat.spatial, checking: true),
      ];
      await open(tester, build(rows));
      await tester.pumpWidget(build(rows, key: 'b'));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
    });

    testWidgets('the exact log sequence: checking then no atmos', (
      tester,
    ) async {
      final picked = <String>[];
      final flac = row('LOSSLESS', QualityBadgeFormat.flac, current: true);
      await open(
        tester,
        build([
          flac,
          row('ATMOS', QualityBadgeFormat.spatial, checking: true),
        ], picked: picked),
      );
      await tester.tap(atmosRow);
      await tester.pump();
      expect(picked, isEmpty);
      await tester.pumpWidget(build([flac], picked: picked));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(atmosRow, findsNothing);
      expect(picked, isEmpty);
    });
  });

  testWidgets('the window follows the badge when the screen turns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(plainHost(_selector(choices, [])));
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('track-quality-panel'));
    final before = tester.getBottomLeft(panel).dy;
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    final after = tester.getBottomLeft(panel).dy;
    expect(before, greaterThan(500));
    expect(after, lessThan(420));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a switch in progress offers to cancel it', (tester) async {
    var cancelled = 0;
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(
      plainHost(
        TrackQualitySelector(
          currentFormat: QualityBadgeFormat.flac,
          currentLabel: 'FLAC 16-bit',
          lockup: true,
          choices: choices,
          switching: true,
          onCancelSwitch: () => cancelled++,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('track-quality-cancel')));
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    expect(find.byKey(const ValueKey('track-quality-panel')), findsNothing);
  });

  testWidgets('the badge keeps a 44 dp touch area when asked', (tester) async {
    await tester.pumpWidget(
      plainHost(
        TrackQualitySelector(
          currentFormat: QualityBadgeFormat.flac,
          currentLabel: 'FLAC 16-bit',
          lockup: true,
          height: 44,
          choices: buildTrackQualityChoices(
            options: _options,
            currentId: 'LOSSLESS',
          ),
          onSelected: (_) {},
        ),
      ),
    );
    final inkWell = find.descendant(
      of: find.byType(TrackQualitySelector),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(inkWell).height, greaterThanOrEqualTo(44));
  });

  group('glass popover', () {
    final many = mergeProviderQualityChoices(
      [
        (
          service: 'tidal',
          options: const [
            QualityOption(id: 'ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
            QualityOption(
              id: 'HI_RES_LOSSLESS',
              label: 'Hi-Res 24-bit',
              kind: 'lossless',
            ),
            QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit'),
            QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
          ],
        ),
        (
          service: 'amazon',
          options: const [
            QualityOption(id: 'mp3_320', label: 'MP3 320 kbps', kind: 'lossy'),
          ],
        ),
        (
          service: 'ytmusic-spotiflac',
          options: const [
            QualityOption(
              id: 'opus_160',
              label: 'Opus 160 kbps',
              kind: 'lossy',
            ),
          ],
        ),
      ],
      currentService: 'tidal',
      currentId: 'LOSSLESS',
    );
    final panel = find.byKey(const ValueKey('track-quality-panel'));

    Future<void> open(
      WidgetTester tester, {
      Size size = const Size(390, 844),
      double scale = 1,
      Brightness brightness = Brightness.light,
      Color? background,
      GlobalKey? capture,
      List<String>? picked,
      VoidCallback? onInfo,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scope(
          MaterialApp(
            theme: MornyeTheme.build(brightness),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => RepaintBoundary(
              key: capture,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: Scaffold(
              backgroundColor: background,
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  height: 48,
                  child: TrackQualitySelector(
                    currentFormat: QualityBadgeFormat.flac,
                    currentLabel: 'FLAC 16-bit',
                    lockup: true,
                    choices: many,
                    onSelected: (c) => (picked ?? []).add(c.id),
                    onShowInfo: onInfo ?? () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TrackQualitySelector));
      await tester.pumpAndSettle();
    }

    for (final size in const [Size(360, 640), Size(411, 915), Size(800, 360)]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('stays compact and on screen at $size, text x$scale', (
          tester,
        ) async {
          await open(tester, size: size, scale: scale);
          final rect = tester.getRect(panel);
          expect(rect.width, lessThanOrEqualTo(320));
          expect(rect.width, lessThanOrEqualTo(size.width * 0.78 + 0.5));
          expect(rect.height, lessThanOrEqualTo(size.height * 0.70 + 0.5));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(tester.takeException(), isNull);
          final row = find.byKey(const ValueKey('quality-choice-LOSSLESS'));
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          final info = find.byKey(const ValueKey('track-quality-info'));
          expect(tester.getSize(info).shortestSide, greaterThanOrEqualTo(48));
        });
      }
    }

    testWidgets('the scrim does not darken the page', (tester) async {
      await open(tester);
      final scrim = find.byKey(const ValueKey('track-quality-scrim'));
      expect(
        find.descendant(of: scrim, matching: find.byType(ColoredBox)),
        findsNothing,
      );
      for (final barrier in tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      )) {
        expect(barrier.color?.a ?? 0, lessThanOrEqualTo(0.12));
      }
      final screen = tester.getSize(find.byType(Scaffold));
      expect(tester.getSize(panel).width, lessThan(screen.width * 0.8));
      expect(tester.getSize(panel).height, lessThan(screen.height * 0.5));
    });

    testWidgets('the active row is marked and a pick reports and closes', (
      tester,
    ) async {
      final picked = <String>[];
      await open(tester, picked: picked);
      final current = find.byKey(const ValueKey('quality-choice-LOSSLESS'));
      expect(
        find.descendant(
          of: current,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quality-choice-ATMOS')));
      await tester.pumpAndSettle();
      expect(picked, ['ATMOS']);
      expect(panel, findsNothing);
    });

    testWidgets('the info icon closes the popover and shows the info', (
      tester,
    ) async {
      var shown = 0;
      await open(tester, onInfo: () => shown++);
      await tester.tap(find.byKey(const ValueKey('track-quality-info')));
      await tester.pumpAndSettle();
      expect(shown, 1);
      expect(panel, findsNothing);
    });

    double contrast(Color a, Color b) {
      final l = [a.computeLuminance(), b.computeLuminance()]..sort();
      return (l.last + 0.05) / (l.first + 0.05);
    }

    Future<List<Color>> pixels(
      WidgetTester tester,
      GlobalKey capture,
      List<Offset> points,
    ) async => (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage();
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final p in points)
            Color.fromARGB(
              255,
              data.getUint8((p.dy.floor() * image.width + p.dx.floor()) * 4),
              data.getUint8(
                (p.dy.floor() * image.width + p.dx.floor()) * 4 + 1,
              ),
              data.getUint8(
                (p.dy.floor() * image.width + p.dx.floor()) * 4 + 2,
              ),
            ),
        ];
      } finally {
        image.dispose();
      }
    }))!;

    for (final brightness in Brightness.values) {
      for (final background in [Colors.white, Colors.black]) {
        testWidgets(
          'text keeps 4.5:1 over glass on $background ($brightness)',
          (tester) async {
            final original = debugDisableShadows;
            debugDisableShadows = false;
            try {
              final capture = GlobalKey();
              await open(
                tester,
                brightness: brightness,
                background: background,
                capture: capture,
              );
              final rect = tester.getRect(panel);
              final samples = await pixels(tester, capture, [
                for (final x in [rect.left + 10, rect.right - 10])
                  for (final f in [0.3, 0.55, 0.8])
                    Offset(x, rect.top + rect.height * f),
              ]);
              final fg = MornyeTheme.build(brightness).colorScheme.onSurface;
              for (final inside in samples) {
                for (final alpha in [1.0, 0.9]) {
                  final text = Color.alphaBlend(
                    fg.withValues(alpha: alpha),
                    inside,
                  );
                  expect(
                    contrast(text, inside),
                    greaterThanOrEqualTo(4.5),
                    reason: '$alpha $inside',
                  );
                }
              }
              final page = await pixels(tester, capture, [
                const Offset(8, 8),
                Offset(tester.view.physicalSize.width - 8, 8),
              ]);
              for (final color in page) {
                expect(color.r, closeTo(background.r, 0.01));
                expect(color.g, closeTo(background.g, 0.01));
              }
            } finally {
              debugDisableShadows = original;
            }
          },
        );
      }
    }
  });
}

void streamingChoicesTests() {
  Track song({String? quality, String? modes, String? source}) => Track(
    source: source,
    id: 't',
    name: 'n',
    artistName: 'a',
    albumName: 'b',
    duration: 100,
    audioQuality: quality,
    audioModes: modes,
  );
  final registry = SpecialQualityAvailability(probeEnabled: false);
  List<String> ids(Track t, {String service = 'tidal_web'}) => [
    for (final c in mergeProviderQualityChoices(
      [(service: service, options: _options)],
      track: t,
      availability: registry,
    ))
      c.id,
  ];

  test('atmos is offered unless the song is known to lack it', () {
    expect(ids(song()), contains('ATMOS'));
    expect(ids(song(modes: '')), contains('ATMOS'));
    expect(
      ids(song(modes: 'STEREO', source: 'tidal-web')),
      isNot(contains('ATMOS')),
    );
    expect(ids(song(modes: 'STEREO')), contains('ATMOS'));
    expect(ids(song(modes: 'DOLBY_ATMOS')), contains('ATMOS'));
    expect(ids(song(modes: 'STEREO,DOLBY_ATMOS')), contains('ATMOS'));
    expect(ids(song(), service: 'amazon'), contains('ATMOS'));
    expect(
      ids(song(modes: 'STEREO', source: 'amazon'), service: 'amazon'),
      isNot(contains('ATMOS')),
    );
  });

  test('an atmos file keeps its badge and its option is the current one', () {
    expect(
      verifiedQualityMark(declared: QualityMark.atmos, codec: 'eac3'),
      QualityMark.atmos,
    );
    expect(qualityMarkFor('', 'Dolby Atmos'), QualityMark.atmos);
    final merged = mergeProviderQualityChoices(
      [(service: 'tidal_web', options: _options)],
      track: song(modes: 'DOLBY_ATMOS'),
      currentMark: QualityMark.atmos,
      availability: registry,
    );
    expect(merged.where((c) => c.current).single.id, 'ATMOS');
  });

  test('a flac file marks flac, never a generic lossy option', () {
    final merged = mergeProviderQualityChoices(
      [
        (
          service: 'tidal_web',
          options: const [
            QualityOption(id: 'lossy', label: 'Lossy', kind: 'lossy'),
            QualityOption(
              id: 'LOSSLESS',
              label: 'FLAC 16-bit',
              kind: 'lossless',
            ),
          ],
        ),
      ],
      currentService: 'tidal_web',
      currentId: 'lossy',
      currentMark: QualityMark.flac,
    );
    expect(merged.where((c) => c.current).single.id, 'LOSSLESS');
  });

  test('declared tidal ceiling hides what the song does not reach', () {
    expect(ids(song(quality: 'LOSSLESS')), isNot(contains('HI_RES_LOSSLESS')));
    expect(ids(song(quality: 'LOSSLESS')), contains('LOSSLESS'));
    expect(ids(song(quality: 'HIGH')), unorderedEquals(['AAC_96', 'ATMOS']));
    expect(ids(song(quality: 'HI_RES_LOSSLESS')), contains('HI_RES_LOSSLESS'));
    expect(ids(song()), contains('HI_RES_LOSSLESS'));
    expect(
      ids(song(quality: 'LOSSLESS'), service: 'other'),
      contains('HI_RES_LOSSLESS'),
    );
  });
}

void duplicateChoicesTests() {
  Iterable<QualityOption> hiRes(String id, String label) => [
    QualityOption(id: id, label: label, kind: 'lossless'),
  ];

  test('equal options from several providers become one, preferred first', () {
    final merged = mergeProviderQualityChoices([
      (service: 'tidal-web', options: hiRes('HI_RES', 'Hi-Res 24-bit 96 kHz')),
      (service: 'amazon', options: hiRes('flac24', 'Hi-Res 24-bit 96 kHz')),
      (service: 'qobuz', options: hiRes('27', 'Hi-Res 24-bit 96 kHz')),
    ]);
    expect(merged, hasLength(1));
    expect(merged.single.service, 'tidal-web');
    expect(merged.single.detail, '24-bit / 96 kHz');
    expect(merged.single.tag, isNull);
  });

  test('an option without properties folds into one that declares them', () {
    final merged = mergeProviderQualityChoices(
      [
        (service: 'tidal-web', options: hiRes('HI_RES', 'Hi-Res Audio')),
        (service: 'amazon', options: hiRes('flac24', 'Hi-Res 24-bit')),
      ],
      currentMark: QualityMark.hiRes,
      currentDetail: '24-bit / 48 kHz',
    );
    expect(merged, hasLength(1));
    expect(merged.single.service, 'tidal-web');
    expect(merged.single.detail, '24-bit');
    expect(merged.single.current, isTrue);
  });

  test('options with another rate stay apart and show their rate', () {
    final merged = mergeProviderQualityChoices(
      [
        (service: 'tidal-web', options: hiRes('a', 'Hi-Res 24-bit 48 kHz')),
        (service: 'amazon', options: hiRes('b', 'Hi-Res 24-bit 96 kHz')),
      ],
      currentMark: QualityMark.hiRes,
      currentDetail: '24-bit / 48 kHz',
    );
    expect(merged.map((c) => c.detail).toSet(), {
      '24-bit / 48 kHz',
      '24-bit / 96 kHz',
    });
    expect(merged.every((c) => c.tag == null), isTrue);
    expect(merged.where((c) => c.current).map((c) => c.id), ['a']);
  });

  test('alike options of one provider are told apart by its name', () {
    final merged = mergeProviderQualityChoices([
      (
        service: 'tidal-web',
        options: const [
          QualityOption(id: 'LOW', label: 'Low', kind: 'lossy'),
          QualityOption(id: 'HIGH', label: 'High', kind: 'lossy'),
        ],
      ),
      (
        service: 'amazon',
        options: const [QualityOption(id: 'LOW', label: 'Low', kind: 'lossy')],
      ),
    ]);
    expect(merged, hasLength(3));
    expect(merged.where((c) => c.service == 'tidal-web').map((c) => c.mark), [
      QualityMark.aac,
      QualityMark.aac,
    ]);
    expect(merged.last.service, 'amazon');
    expect(merged.last.mark, QualityMark.lossy);
  });

  test('bare lossy options of other providers are not folded together', () {
    final merged = mergeProviderQualityChoices([
      (
        service: 'amazon',
        options: const [
          QualityOption(id: 'std', label: 'Standard', kind: 'lossy'),
        ],
      ),
      (
        service: 'ytmusic-spotiflac',
        options: const [
          QualityOption(id: 'best', label: 'Best Audio', kind: 'lossy'),
        ],
      ),
    ]);
    expect(merged.map((c) => c.service), ['amazon', 'ytmusic-spotiflac']);
    expect(merged.map((c) => c.tag), ['Amazon Music', 'YouTube Music']);
  });

  test('a generic id takes its kind from the provider fallback tier', () {
    const best = [QualityOption(id: 'best', label: 'Best Audio')];
    expect(
      withDeclaredQualityKinds(best, fallbackTier: 'low_res').single.kind,
      'lossy',
    );
    expect(withDeclaredQualityKinds(best).single.kind, '');
    expect(
      withDeclaredQualityKinds(const [
        QualityOption(id: 'x', label: 'X'),
      ], fallbackTier: 'low_res').single.kind,
      '',
    );
  });

  test('a choice equal to the playing file is recognised', () {
    final choice = mergeProviderQualityChoices([
      (service: 'tidal-web', options: hiRes('a', 'Hi-Res 24-bit 48 kHz')),
    ]).single;
    expect(
      qualityChoiceMatchesPlaying(
        choice,
        mark: QualityMark.hiRes,
        detail: '24-bit / 48 kHz',
      ),
      isTrue,
    );
    expect(
      qualityChoiceMatchesPlaying(
        choice,
        mark: QualityMark.hiRes,
        detail: '24-bit / 96 kHz',
      ),
      isFalse,
    );
    expect(
      qualityChoiceMatchesPlaying(
        choice,
        mark: QualityMark.flac,
        detail: '24-bit / 48 kHz',
      ),
      isFalse,
    );
  });

  testWidgets('tapping the playing quality reports it instead of nothing', (
    tester,
  ) async {
    final picked = <String>[];
    var told = 0;
    final choices = buildTrackQualityChoices(
      options: _options,
      currentId: 'LOSSLESS',
    );
    await tester.pumpWidget(
      _scope(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
                  onCurrentTapped: () => told++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-choice-LOSSLESS')));
    await tester.pumpAndSettle();
    expect(told, 1);
    expect(picked, isEmpty);
  });

  test('the playing file wins over a requested quality that was relayed', () {
    final providers = [
      (
        service: 'ytmusic',
        options: const [
          QualityOption(id: 'opus_160', label: 'Opus 160 kbps', kind: 'lossy'),
        ],
      ),
      (
        service: 'tidal-web',
        options: const [
          QualityOption(id: 'HIGH', label: 'High', kind: 'lossy'),
          QualityOption(id: 'LOW', label: 'Low', kind: 'lossy'),
        ],
      ),
    ];
    final merged = mergeProviderQualityChoices(
      providers,
      currentService: 'ytmusic',
      currentId: 'opus_160',
      currentMark: QualityMark.aac,
      currentDetail: '320 kbps',
    );
    final current = merged.where((c) => c.current).toList();
    expect(current, hasLength(1));
    expect(current.single.mark, QualityMark.aac);
    expect(current.single.id, 'HIGH');
    expect(merged.firstWhere((c) => c.mark == QualityMark.opus).current, false);
    final agreeing = mergeProviderQualityChoices(
      providers,
      currentService: 'ytmusic',
      currentId: 'opus_160',
      currentMark: QualityMark.opus,
    );
    expect(agreeing.where((c) => c.current).single.id, 'opus_160');
  });

  test('a failed switch keeps the real file marked, not the requested one', () {
    final providers = [
      (
        service: 'ytmusic',
        options: const [
          QualityOption(id: 'opus_160', label: 'Opus 160 kbps', kind: 'lossy'),
          QualityOption(id: 'opus_64', label: 'Opus 64 kbps', kind: 'lossy'),
          QualityOption(id: 'lossy', label: 'Lossy', kind: 'lossy'),
        ],
      ),
    ];
    final merged = mergeProviderQualityChoices(
      providers,
      currentService: 'ytmusic',
      currentId: 'opus_160',
      currentMark: QualityMark.opus,
      currentDetail: '64 kbps',
    );
    expect(merged.where((c) => c.current).single.id, 'opus_64');
    final generic = mergeProviderQualityChoices(
      providers,
      currentService: 'ytmusic',
      currentId: 'lossy',
      currentMark: QualityMark.opus,
      currentDetail: '64 kbps',
    );
    expect(generic.where((c) => c.current).single.mark, QualityMark.opus);
  });

  test('the failed switch notice stays up long enough to be read', () {
    expect(
      switchFailureDuration,
      greaterThanOrEqualTo(const Duration(seconds: 8)),
    );
  });

  test('a requested format that differs from the playing one is detected', () {
    expect(qualityRequestDiffers(QualityMark.opus, QualityMark.aac), isTrue);
    expect(
      qualityRequestDiffers(QualityMark.lossless, QualityMark.aac),
      isTrue,
    );
    expect(
      qualityRequestDiffers(QualityMark.lossless, QualityMark.flac),
      isFalse,
    );
    expect(qualityRequestDiffers(QualityMark.lossy, QualityMark.aac), isFalse);
    expect(qualityRequestDiffers(QualityMark.opus, QualityMark.opus), isFalse);
  });

  testWidgets('the window notes the requested quality that was not given', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scope(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                height: 48,
                child: TrackQualitySelector(
                  currentFormat: QualityBadgeFormat.aac,
                  currentLabel: 'AAC',
                  lockup: true,
                  choices: buildTrackQualityChoices(
                    options: _options,
                    currentId: 'AAC_96',
                  ),
                  requestedNote: 'Pedida: Opus — no disponible para esta pista',
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('track-quality-requested-note')),
      findsOneWidget,
    );
    expect(
      find.text('Pedida: Opus — no disponible para esta pista'),
      findsOneWidget,
    );
  });
}
