import 'dart:convert';

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
import 'package:mornye/widgets/player_lyrics_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Metadata extends PlayerMetadataController {
  ParsedLyrics value = ParsedLyrics.empty;
  bool busy = false;
  int reads = 0;

  void set(ParsedLyrics next, {bool loading = false}) {
    value = next;
    busy = loading;
    notifyListeners();
  }

  @override
  ParsedLyrics get lyrics {
    reads++;
    return value;
  }

  @override
  bool get loading => busy;
}

class _Position extends Notifier<Duration> {
  @override
  Duration build() => Duration.zero;

  void move(Duration next) => state = next;
}

final _position = NotifierProvider<_Position, Duration>(_Position.new);

class _Playing extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool next) => state = next;
}

final _playing = NotifierProvider<_Playing, bool>(_Playing.new);

LyricLine _line(int seconds, String text, {List<LyricWord> words = const []}) =>
    LyricLine(
      time: Duration(seconds: seconds),
      text: text,
      words: words,
    );

ParsedLyrics _synced(List<LyricLine> lines) =>
    ParsedLyrics(synced: true, wordSynced: false, lines: lines, plainText: '');

List<Override> _overrides(AppSettings settings) => [
  initialSettingsProvider.overrideWithValue(settings),
  playbackPositionProvider.overrideWith((ref) => ref.watch(_position)),
  playbackPlayingProvider.overrideWith((ref) => ref.watch(_playing)),
  playbackLoadingProvider.overrideWith((ref) => false),
  playbackStateProvider.overrideWith((ref) => Stream.value(PlaybackState())),
];

(int, int)? _customAction(SemanticsOwner owner, String label) {
  (int, int)? found;
  void visit(SemanticsNode node) {
    final ids = node.getSemanticsData().customSemanticsActionIds ?? const [];
    for (final id in ids) {
      if (CustomSemanticsAction.getAction(id)?.label == label) {
        found = (node.id, id);
      }
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root = owner.rootSemanticsNode;
  if (root != null) visit(root);
  return found;
}

void main() {
  late _Metadata metadata;
  late ProviderContainer container;
  var opened = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    metadata = _Metadata();
    opened = 0;
    container = ProviderContainer(overrides: _overrides(const AppSettings()));
  });

  tearDown(() {
    container.dispose();
    metadata.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    Widget? pill,
    bool reduce = false,
    double scale = 1,
  }) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduce,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: PlayerVideoLyricsRow(
                metadata: metadata,
                onOpenLyrics: () => opened++,
                pill:
                    pill ??
                    const SizedBox(
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
  );

  final lines = _synced([
    _line(1, 'First line'),
    _line(5, 'Second line'),
    _line(9, 'Third line'),
  ]);

  final preview = find.byKey(const ValueKey('player-lyrics-preview'));

  void move(int milliseconds) => container
      .read(_position.notifier)
      .move(Duration(milliseconds: milliseconds));

  testWidgets('shows the current line and follows the position', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(6000);
    await tester.pumpAndSettle();
    expect(find.text('Second line'), findsOneWidget);
    expect(find.text('Third line'), findsOneWidget);
    expect(find.text('First line'), findsNothing);

    move(10000);
    await tester.pumpAndSettle();
    expect(find.text('Third line'), findsOneWidget);
    expect(find.text('Second line'), findsNothing);
  });

  testWidgets('tapping opens the lyrics and is at least as tall as the pill', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
      greaterThanOrEqualTo(
        tester.getSize(find.byKey(const ValueKey('pill'))).height,
      ),
    );
    expect(
      tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
      lessThan(52),
    );
    expect(find.bySemanticsLabel('Open lyrics'), findsOneWidget);
    await tester.tap(preview);
    expect(opened, 1);
  });

  testWidgets('without synced lyrics it adds nothing and keeps the height', (
    tester,
  ) async {
    await pump(tester);
    final empty = tester.getSize(find.byType(PlayerVideoLyricsRow));
    expect(preview, findsNothing);

    metadata.set(
      const ParsedLyrics(
        synced: false,
        wordSynced: false,
        lines: [],
        plainText: 'Only plain text',
      ),
    );
    await tester.pump();
    expect(find.text('Only plain text'), findsNothing);
    expect(preview, findsNothing);

    metadata.set(lines);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlayerVideoLyricsRow)), empty);
  });

  testWidgets('sits right of the video pill and fills the width without it', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final pill = tester.getRect(find.byKey(const ValueKey('pill')));
    final withPill = tester.getRect(preview);
    expect(withPill.left - pill.right, greaterThanOrEqualTo(12));
    expect(withPill.right, closeTo(360, 0.01));

    await pump(tester, pill: const SizedBox.shrink(key: ValueKey('pill')));
    await tester.pumpAndSettle();
    expect(tester.getRect(preview).left, closeTo(0, 0.01));
    expect(tester.getRect(preview).right, closeTo(360, 0.01));
  });

  test('the sweep follows timed words and falls back to the line span', () {
    const words = [
      LyricWord(time: Duration(seconds: 1), text: 'Hello '),
      LyricWord(time: Duration(seconds: 2), text: 'big '),
      LyricWord(time: Duration(seconds: 3), text: 'world'),
    ];
    final line = _line(1, 'Hello big world', words: words);
    expect(lyricsLineProgress(line, null, Duration.zero), 0);
    expect(
      lyricsLineProgress(line, null, const Duration(milliseconds: 1500)),
      closeTo(3 / 15, 0.001),
    );
    expect(
      lyricsLineProgress(line, null, const Duration(milliseconds: 2500)),
      closeTo(8 / 15, 0.001),
    );
    expect(lyricsLineProgress(line, null, const Duration(seconds: 9)), 1);
    expect(
      lyricsLineProgress(
        _line(2, 'Plain'),
        const Duration(seconds: 6),
        const Duration(seconds: 4),
      ),
      closeTo(0.5, 0.001),
    );
  });

  testWidgets('a long line shows whole over several rows without ellipsis', (
    tester,
  ) async {
    const long = 'Una frase inventada que antes se cortaba';
    metadata.value = _synced([
      _line(1, long),
      _line(
        5,
        'Otra frase inventada, igual de larga que la primera para partirse',
      ),
      _line(9, 'Corta'),
    ]);
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final text = find.text(long);
    expect(text, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(
      paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: long.length),
          )
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(find.textContaining('…'), findsNothing);
    final lyrics = tester.getRect(preview);
    expect(tester.getRect(text).left, closeTo(lyrics.left, 0.01));
    expect(tester.getRect(text).right, lessThanOrEqualTo(lyrics.right + 0.01));
    expect(
      tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
      greaterThan(44),
    );
    expect(
      tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
      lessThanOrEqualTo(playerLyricsPreviewMaxHeight),
    );
  });

  testWidgets('a very long line stops at the safety cap with an ellipsis', (
    tester,
  ) async {
    final huge = List.filled(40, 'palabra').join(' ');
    metadata.value = _synced([_line(1, huge), _line(5, huge)]);
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(find.text(huge));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(
      tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
      lessThanOrEqualTo(playerLyricsPreviewMaxHeight),
    );
    expect(find.text(huge), findsOneWidget);
  });

  testWidgets('the row height eases to the new line instead of jumping', (
    tester,
  ) async {
    const long =
        'Otra frase inventada, igual de larga que la primera para partirse '
        'en dos renglones completos';
    metadata.value = _synced([
      _line(1, 'Corta'),
      _line(5, long),
      _line(9, 'Final'),
    ]);
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final rowSize = find.byType(PlayerVideoLyricsRow);
    final before = tester.getSize(rowSize).height;
    move(6000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final middle = tester.getSize(rowSize).height;
    await tester.pumpAndSettle();
    final after = tester.getSize(rowSize).height;
    expect(after, greaterThan(before));
    expect(middle, inInclusiveRange(before, after));
    expect(middle, isNot(after));
  });

  testWidgets('no overflow on a small screen with large system text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const long =
        'Una frase inventada bastante larga que antes se cortaba '
        'con puntos suspensivos';
    metadata.value = _synced([_line(1, long), _line(5, long), _line(9, long)]);
    for (final scale in [1.0, 2.0]) {
      await pump(tester, scale: scale);
      move(2000);
      await tester.pumpAndSettle();
      move(6000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(PlayerVideoLyricsRow)).height,
        lessThanOrEqualTo(playerLyricsPreviewMaxHeight),
      );
    }
  });

  testWidgets('a line change slides and fades instead of cutting', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final first = find.text('First line');
    final before = tester.getTopLeft(first).dy;
    move(6000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(first, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(before));
    final fading = tester.widget<Opacity>(
      find.ancestor(of: first, matching: find.byType(Opacity)).first,
    );
    expect(fading.opacity, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(first, findsNothing);
  });

  testWidgets('with animations removed the line cuts straight over', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester, reduce: true);
    move(2000);
    await tester.pump();
    move(6000);
    await tester.pump();
    expect(find.text('First line'), findsNothing);
    expect(find.text('Second line'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('keeps pace between position reports while playing', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(4600);
    container.read(_playing.notifier).set(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('First line'), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Second line'), findsOneWidget);
    container.read(_playing.notifier).set(false);
    await tester.pumpAndSettle();
  });

  testWidgets('line changes do not rebuild the host of the preview', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final reads = metadata.reads;
    for (final seconds in [3, 5, 7, 9, 10]) {
      move(seconds * 1000);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(metadata.reads, reads);
  });

  testWidgets('dragging right hides the pill and left shows it again', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final shown = tester.getRect(preview);

    await tester.drag(preview, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(preview), shown);
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isFalse);

    await tester.drag(preview, const Offset(170, 0));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isTrue);
    final hidden = tester.getRect(preview);
    expect(hidden.left, greaterThan(shown.left + 100));
    expect(360 - hidden.left, closeTo(playerLyricsPreviewHandleWidth, 1));

    await tester.tapAt(const Offset(347, 24));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isFalse);
    expect(tester.getRect(preview), shown);

    await tester.drag(preview, const Offset(170, 0));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(347, 24), const Offset(-170, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(preview), shown);
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isFalse);
    await tester.tap(preview);
    expect(opened, 1);
  });

  testWidgets('hiding goes out and back without animations too', (
    tester,
  ) async {
    metadata.value = lines;
    await pump(tester, reduce: true);
    move(2000);
    await tester.pump();
    await tester.drag(preview, const Offset(150, 0));
    await tester.pump();
    expect(
      360 - tester.getRect(preview).left,
      closeTo(playerLyricsPreviewHandleWidth, 1),
    );
  });

  testWidgets('the hidden choice is saved and restored', (tester) async {
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    await tester.drag(preview, const Offset(150, 0));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    final saved = AppSettings.fromJson(
      jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
    );
    expect(saved.playerLyricsPreviewHidden, isTrue);
    expect(const AppSettings().playerLyricsPreviewHidden, isFalse);
    expect(AppSettings.fromJson({}).playerLyricsPreviewHidden, isFalse);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    container = ProviderContainer(overrides: _overrides(saved));
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    expect(
      360 - tester.getRect(preview).left,
      closeTo(playerLyricsPreviewHandleWidth, 1),
    );
  });

  testWidgets('hide and show are offered as semantic actions', (tester) async {
    final semantics = tester.ensureSemantics();
    metadata.value = lines;
    await pump(tester);
    move(2000);
    await tester.pumpAndSettle();
    final owner = tester.getSemantics(find.byType(Scaffold)).owner!;
    var action = _customAction(owner, 'Hide lyrics');
    expect(action, isNotNull);
    owner.performAction(action!.$1, SemanticsAction.customAction, action.$2);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isTrue);
    expect(find.bySemanticsLabel('Show lyrics'), findsOneWidget);
    action = _customAction(owner, 'Show lyrics');
    expect(action, isNotNull);
    owner.performAction(action!.$1, SemanticsAction.customAction, action.$2);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isFalse);
    semantics.dispose();
  });
}
