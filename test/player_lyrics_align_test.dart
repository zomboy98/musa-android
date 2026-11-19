import 'dart:convert';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/lyrics_align_picker.dart';
import 'package:mornye/widgets/lyrics_line_correction.dart';
import 'package:mornye/widgets/player_lyrics_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Metadata extends PlayerMetadataController {
  ParsedLyrics value = ParsedLyrics.empty;

  @override
  ParsedLyrics get lyrics => value;

  @override
  bool get loading => false;
}

class _Position extends Notifier<Duration> {
  @override
  Duration build() => Duration.zero;

  void move(Duration next) => state = next;
}

final _position = NotifierProvider<_Position, Duration>(_Position.new);

LyricLine _line(int seconds, String text) => LyricLine(
  time: Duration(seconds: seconds),
  text: text,
);

ParsedLyrics _synced(List<LyricLine> lines) =>
    ParsedLyrics(synced: true, wordSynced: false, lines: lines, plainText: '');

List<Override> _overrides(AppSettings settings) => [
  initialSettingsProvider.overrideWithValue(settings),
  playbackPositionProvider.overrideWith((ref) => ref.watch(_position)),
  playbackPlayingProvider.overrideWith((ref) => false),
  playbackLoadingProvider.overrideWith((ref) => false),
  playbackStateProvider.overrideWith((ref) => Stream.value(PlaybackState())),
];

const _short = 'Quiet harbor';
const _long = 'Lanterns drift over a quiet harbor';

/// Visible glyph extent per rendered row, ignoring the spaces that hang past
/// the edge at a wrap.
List<Rect> _rows(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final origin = paragraph.localToGlobal(Offset.zero);
  final text = paragraph.text.toPlainText();
  final rows = <double, Rect>{};
  for (var i = 0; i < text.length; i++) {
    if (text[i].trim().isEmpty) continue;
    for (final box in paragraph.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    )) {
      final rect = box.toRect().shift(origin);
      rows[rect.top] = rows[rect.top]?.expandToInclude(rect) ?? rect;
    }
  }
  final keys = rows.keys.toList()..sort();
  return [for (final key in keys) rows[key]!];
}

Rect _textRect(WidgetTester tester, Finder finder) =>
    _rows(tester, finder).reduce((a, b) => a.expandToInclude(b));

void main() {
  late _Metadata metadata;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    metadata = _Metadata();
    container = ProviderContainer(overrides: _overrides(const AppSettings()));
  });

  tearDown(() {
    container.dispose();
    metadata.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    LyricsTextAlign? align,
    double scale = 1,
    bool previewMenu = false,
  }) async {
    if (align != null) {
      container
          .read(settingsProvider.notifier)
          .setPlayerLyricsPreviewAlign(align);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                child: Builder(
                  builder: (context) => PlayerVideoLyricsRow(
                    metadata: metadata,
                    onOpenLyrics: () {},
                    onLongPressLine: previewMenu
                        ? (line) => showLyricsLineActions(
                            context,
                            metadata,
                            line,
                            previewAlign: true,
                          )
                        : null,
                    pill: const SizedBox(
                      key: ValueKey('pill'),
                      width: 90,
                      height: 44,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(_position.notifier).move(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  void useLines(List<LyricLine> lines) => metadata.value = _synced(lines);

  const areaLeft = 90.0 + playerLyricsPreviewPillGap;
  const areaRight = 360.0;

  testWidgets('right puts the text on the right edge, away from the pill', (
    tester,
  ) async {
    useLines([_line(1, _short), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester);
    expect(
      container.read(settingsProvider).playerLyricsPreviewAlign,
      LyricsTextAlign.right,
    );
    final rect = _textRect(tester, find.text(_short));
    expect(rect.right, closeTo(areaRight, 0.6));
    expect(rect.left - 90, greaterThanOrEqualTo(playerLyricsPreviewPillGap));
    expect(rect.left, greaterThan(areaLeft + 40));
  });

  testWidgets('center centres the text in the space beside the pill', (
    tester,
  ) async {
    useLines([_line(1, _short), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester, align: LyricsTextAlign.center);
    final rect = _textRect(tester, find.text(_short));
    expect(rect.center.dx, closeTo((areaLeft + areaRight) / 2, 1));
    expect(rect.left - 90, greaterThanOrEqualTo(playerLyricsPreviewPillGap));
  });

  testWidgets('left sticks to the margin after the pill', (tester) async {
    useLines([_line(1, _short), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester, align: LyricsTextAlign.left);
    final rect = _textRect(tester, find.text(_short));
    expect(rect.left, closeTo(areaLeft, 0.6));
    expect(areaRight - rect.right, greaterThan(40));
  });

  testWidgets('justified fills the lines but the last one stays left', (
    tester,
  ) async {
    useLines([_line(1, _long), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester, align: LyricsTextAlign.justify);
    final ordered = _rows(tester, find.text(_long));
    expect(ordered.length, greaterThanOrEqualTo(2));
    expect(ordered.first.left, closeTo(areaLeft, 0.6));
    expect(ordered.first.right, closeTo(areaRight, 0.6));
    expect(ordered.last.left, closeTo(areaLeft, 0.6));
    expect(ordered.last.right, lessThan(areaRight - 5));
  });

  testWidgets('long right-aligned lines wrap flush right', (tester) async {
    useLines([_line(1, _long), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester, align: LyricsTextAlign.right);
    final rect = _textRect(tester, find.text(_long));
    expect(rect.right, closeTo(areaRight, 0.6));
    expect(rect.left, greaterThanOrEqualTo(areaLeft - 0.6));
  });

  for (final align in LyricsTextAlign.values) {
    testWidgets('no overflow at 360x640 with 2x text (${align.name})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      useLines([_line(1, _long), _line(5, _long), _line(9, _short)]);
      await pump(tester, align: align, scale: 2);
      expect(tester.takeException(), isNull);
      container.read(_position.notifier).move(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final row = tester.getRect(find.byType(PlayerVideoLyricsRow));
      expect(row.right, lessThanOrEqualTo(360));
    });
  }

  testWidgets('the sweep advances in reading order when right or centered', (
    tester,
  ) async {
    useLines([_line(1, _long), _line(9, 'Second verse'), _line(15, 'Third')]);
    for (final align in [LyricsTextAlign.right, LyricsTextAlign.center]) {
      await pump(tester, align: align);
      final sweep = find.byWidgetPredicate(
        (w) => w is ClipPath && '${w.clipper.runtimeType}' == '_SweepClipper',
      );
      expect(sweep, findsWidgets);
      final first = sweep.first;
      final text = _textRect(tester, find.text(_long));
      Future<Rect> bounds(int ms) async {
        container.read(_position.notifier).move(Duration(milliseconds: ms));
        await tester.pump();
        return tester
            .widget<ClipPath>(first)
            .clipper!
            .getClip(tester.getSize(first))
            .getBounds();
      }

      final early = await bounds(1000 + 500);
      final mid = await bounds(1000 + 4000);
      final late = await bounds(1000 + 7500);
      expect(early.isEmpty, isFalse);
      expect(mid.height, greaterThanOrEqualTo(early.height));
      expect(late.height, greaterThan(early.height));
      expect(late.bottom, lessThanOrEqualTo(tester.getSize(first).height + 1));
      expect(text.width, lessThanOrEqualTo(areaRight - areaLeft + 0.6));
    }
  });

  testWidgets('the sweep on a single right-aligned line grows to the right', (
    tester,
  ) async {
    useLines([_line(1, _short), _line(9, 'Second verse'), _line(15, 'Third')]);
    await pump(tester, align: LyricsTextAlign.right);
    final sweep = find
        .byWidgetPredicate(
          (w) => w is ClipPath && '${w.clipper.runtimeType}' == '_SweepClipper',
        )
        .first;
    final text = _textRect(tester, find.text(_short));
    Future<Rect> bounds(int ms) async {
      container.read(_position.notifier).move(Duration(milliseconds: ms));
      await tester.pump();
      return tester
          .widget<ClipPath>(sweep)
          .clipper!
          .getClip(tester.getSize(sweep))
          .getBounds()
          .shift(tester.getTopLeft(sweep));
    }

    final early = await bounds(1000 + 1000);
    final late = await bounds(1000 + 5000);
    expect(early.right, greaterThan(text.left));
    expect(early.right, lessThan(text.right));
    expect(late.right, greaterThan(early.right));
  });

  testWidgets('the choice is saved, restored and read tolerantly', (
    tester,
  ) async {
    useLines([_line(1, _short), _line(5, 'Second verse')]);
    await pump(tester, align: LyricsTextAlign.center);
    final prefs = await SharedPreferences.getInstance();
    final saved = AppSettings.fromJson(
      jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
    );
    expect(saved.playerLyricsPreviewAlign, LyricsTextAlign.center);
    expect(const AppSettings().playerLyricsPreviewAlign, LyricsTextAlign.right);
    expect(const AppSettings().lyricsAlign, LyricsViewAlign.auto);
    expect(
      AppSettings.fromJson({}).playerLyricsPreviewAlign,
      LyricsTextAlign.right,
    );
    expect(
      AppSettings.fromJson({
        'playerLyricsPreviewAlign': 'diagonal',
        'lyricsAlign': 'diagonal',
      }).playerLyricsPreviewAlign,
      LyricsTextAlign.right,
    );
    expect(
      AppSettings.fromJson({'lyricsAlign': 'justify'}).lyricsAlign,
      LyricsViewAlign.justify,
    );
    expect(
      jsonDecode(jsonEncode(saved.toJson()))['playerLyricsPreviewAlign'],
      'center',
    );

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    container = ProviderContainer(overrides: _overrides(saved));
    await pump(tester);
    final rect = _textRect(tester, find.text(_short));
    expect(rect.center.dx, closeTo((areaLeft + areaRight) / 2, 1));
  });

  testWidgets('the long-press menu changes the alignment', (tester) async {
    useLines([_line(1, _short), _line(5, 'Second verse'), _line(9, 'Third')]);
    await pump(tester, previewMenu: true);
    expect(_textRect(tester, find.text(_short)).right, closeTo(areaRight, 0.6));

    await tester.longPressAt(tester.getCenter(find.text(_short)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-line-align')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('lyrics-align-selector')),
        matching: find.byIcon(Icons.format_align_left),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).playerLyricsPreviewAlign,
      LyricsTextAlign.left,
    );
    expect(container.read(settingsProvider).lyricsAlign, LyricsViewAlign.auto);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-line-align')), findsNothing);
    expect(_textRect(tester, find.text(_short)).left, closeTo(areaLeft, 0.6));
  });

  testWidgets(
    'the selector offers four icons and the settings sample follows',
    (tester) async {
      LyricsTextAlign? picked;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => LyricsAlignSettingFooter(
                value: picked ?? LyricsTextAlign.right,
                onChanged: (align) => setState(() => picked = align),
              ),
            ),
          ),
        ),
      );
      for (final icon in [
        Icons.format_align_left,
        Icons.format_align_center,
        Icons.format_align_right,
        Icons.format_align_justify,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
      Text sample() => tester.widget<Text>(
        find.descendant(
          of: find.byType(LyricsAlignSample),
          matching: find.byType(Text),
        ),
      );
      expect(sample().textAlign, TextAlign.end);
      await tester.tap(find.byIcon(Icons.format_align_center));
      await tester.pumpAndSettle();
      expect(picked, LyricsTextAlign.center);
      expect(sample().textAlign, TextAlign.center);
      await tester.tap(find.byIcon(Icons.format_align_justify));
      await tester.pumpAndSettle();
      expect(sample().textAlign, TextAlign.justify);
    },
  );

  test('mid-transition the outgoing line is faint and the incoming solid', () {
    for (final next in [true, false]) {
      for (final frac in [0.5, 0.55, 0.7]) {
        final outgoing = lyricsPreviewLineOpacity(-frac, next);
        final incoming = lyricsPreviewLineOpacity(1 - frac, next);
        expect(outgoing, lessThanOrEqualTo(0.35));
        expect(incoming, greaterThanOrEqualTo(0.3));
      }
      expect(lyricsPreviewLineOpacity(-0.5, next), lessThanOrEqualTo(0.35));
      expect(lyricsPreviewLineOpacity(0.5, next), greaterThanOrEqualTo(0.65));
    }
  });

  test('left and right follow the reading direction', () {
    expect(
      lyricsTextAlignFor(LyricsTextAlign.right, ui.TextDirection.ltr),
      TextAlign.end,
    );
    expect(
      lyricsTextAlignFor(LyricsTextAlign.right, ui.TextDirection.rtl),
      TextAlign.start,
    );
    expect(
      lyricsTextAlignFor(LyricsTextAlign.left, ui.TextDirection.rtl),
      TextAlign.end,
    );
    expect(
      lyricsTextAlignFor(LyricsTextAlign.justify, ui.TextDirection.ltr),
      TextAlign.justify,
    );
  });
}
