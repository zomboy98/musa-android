import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

const _long = 'Un lobo canta, no es por amor el lobo de la montana';

LyricLine _line(int seconds, String text) => LyricLine(
  time: Duration(seconds: seconds),
  text: text,
);

void main() {
  for (final align in LyricsTextAlign.values) {
    testWidgets('every layer of the active line paints the same box '
        '(${align.name})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final metadata = _Metadata()
        ..value = ParsedLyrics(
          synced: true,
          wordSynced: false,
          lines: [_line(1, _long), _line(9, 'Segunda'), _line(15, 'Tercera')],
          plainText: '',
        );
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings().copyWith(playerLyricsPreviewAlign: align),
          ),
          playbackPositionProvider.overrideWith((ref) => ref.watch(_position)),
          playbackPlayingProvider.overrideWith((ref) => false),
          playbackLoadingProvider.overrideWith((ref) => false),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        metadata.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: DefaultTextStyle(
                style: const TextStyle(
                  fontSize: 17,
                  letterSpacing: 1.6,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w300,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 300,
                    child: PlayerVideoLyricsRow(
                      metadata: metadata,
                      onOpenLyrics: () {},
                      pill: const SizedBox(width: 80, height: 44),
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

      final paragraphs = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .where((p) => p.text.toPlainText() == _long)
          .toList();
      expect(paragraphs.length, 3);
      expect(paragraphs.first.size.height, greaterThan(30));
      final rects = [
        for (final p in paragraphs) p.localToGlobal(Offset.zero) & p.size,
      ];
      for (final rect in rects.skip(1)) {
        expect(rect.left, closeTo(rects.first.left, 0.01));
        expect(rect.right, closeTo(rects.first.right, 0.01));
        expect(rect.top, closeTo(rects.first.top, 0.01));
        expect(rect.height, closeTo(rects.first.height, 0.01));
      }
      for (final p in paragraphs.skip(1)) {
        expect(p.textAlign, paragraphs.first.textAlign);
        expect(p.maxLines, paragraphs.first.maxLines);
        expect(p.softWrap, paragraphs.first.softWrap);
        expect(
          p.text.style?.fontFamily,
          paragraphs.first.text.style?.fontFamily,
        );
        expect(
          p.text.style?.letterSpacing,
          paragraphs.first.text.style?.letterSpacing,
        );
      }
      for (var i = 0; i < paragraphs.length; i++) {
        final rows = paragraphs[i].getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: _long.length),
        );
        expect(rows.length, greaterThan(1));
      }
    });
  }
}
