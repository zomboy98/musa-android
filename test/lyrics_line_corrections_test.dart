import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/lyrics_corrections.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _served =
    '[00:01.00]Alpha beta gamma\n'
    '[00:05.00]Delta epsilon zeta\n'
    '[00:09.00]Eta theta iota';

MediaItem _item({String isrc = 'ZZ0000000001', String id = 'one'}) =>
    playableFromCatalogTrack(
      Track(
        id: id,
        source: 'spotify',
        name: 'Invented song',
        artistName: 'Invented artist',
        albumName: 'Invented album',
        duration: 120,
        isrc: isrc,
      ),
    ).toMediaItem();

PlayerMetadataController _controller({
  required String Function() served,
  List<MediaItem>? requests,
}) => PlayerMetadataController(
  onlineAvailable: () async => true,
  fetchOnlineLyrics: (item) async {
    requests?.add(item);
    return served();
  },
  parseLyrics: (raw) async => LyricsParser.parse(raw),
  saveOnlineLyrics: (_, _) async => fail('A catalog track has no file'),
);

Future<void> _loaded(
  PlayerMetadataController controller,
  MediaItem item,
) async {
  await controller.load(item);
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _line(PlayerMetadataController controller, int index) =>
    controller.lyrics.lines[index].text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the catalog ISRC reaches the queue item extras', () {
    expect(_item(isrc: 'zz-000-00-00001').extras?['isrc'], 'ZZ0000000001');
    expect(lyricsIsrc(_item()), 'ZZ0000000001');
  });

  test(
    'a corrected catalog line survives a reload with the same ISRC',
    () async {
      final first = _controller(served: () => _served);
      addTearDown(first.dispose);
      await _loaded(first, _item());
      expect(first.canCorrectLines, isTrue);
      await first.saveEditedLyrics(
        _served.replaceFirst('Delta epsilon zeta', 'Delta epsilon omega'),
      );
      expect(_line(first, 1), 'Delta epsilon omega');
      expect(_line(first, 0), 'Alpha beta gamma');
      expect(first.correctedLineTimesMs, {5000});

      final second = _controller(served: () => _served);
      addTearDown(second.dispose);
      await _loaded(second, _item(id: 'another-catalog-id'));
      expect(_line(second, 1), 'Delta epsilon omega');
      expect(second.staleCorrections, 0);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('lyrics_line_corrections_v1')!;
      expect(stored.contains('Alpha beta gamma'), isFalse);
    },
  );

  test(
    'a provider that changed the line leaves the correction unapplied',
    () async {
      final first = _controller(served: () => _served);
      addTearDown(first.dispose);
      await _loaded(first, _item());
      await first.correctLyricsLine(5000, 'Delta epsilon omega');

      final second = _controller(
        served: () =>
            _served.replaceFirst('Delta epsilon zeta', 'Delta epsilon eta'),
      );
      addTearDown(second.dispose);
      await _loaded(second, _item());
      expect(_line(second, 1), 'Delta epsilon eta');
      expect(second.staleCorrections, 1);
      expect(second.correctedLineTimesMs, isEmpty);
    },
  );

  test('restoring a line brings the provider text back for good', () async {
    final first = _controller(served: () => _served);
    addTearDown(first.dispose);
    await _loaded(first, _item());
    await first.correctLyricsLine(1000, 'Alpha beta omega');
    await first.correctLyricsLine(9000, 'Eta theta omega');
    expect(first.originalLineText(1000), 'Alpha beta gamma');
    await first.restoreLyricsLine(1000);
    expect(_line(first, 0), 'Alpha beta gamma');
    expect(_line(first, 2), 'Eta theta omega');

    final second = _controller(served: () => _served);
    addTearDown(second.dispose);
    await _loaded(second, _item());
    expect(_line(second, 0), 'Alpha beta gamma');
    expect(_line(second, 2), 'Eta theta omega');
  });

  test('an explicit search skips the provider cache', () async {
    final requests = <MediaItem>[];
    final controller = _controller(served: () => _served, requests: requests);
    addTearDown(controller.dispose);
    await _loaded(controller, _item());
    expect(requests.single.extras?['lyricsRefresh'], isNull);
    await controller.searchOnline();
    expect(requests.last.extras?['lyricsRefresh'], isTrue);
  });

  group('patches', () {
    test('word timing on a corrected line becomes line timing', () {
      const raw =
          '[00:01.00]<00:01.00>Alpha <00:01.50>beta\n[00:05.00]Next line';
      final patches = diffLyricsPatches(
        raw,
        '[00:01.00]Alpha omega\n[00:05.00]Next line',
      );
      final result = applyLyricsPatches(raw, patches);
      expect(result.applied, 1);
      expect(result.raw.split('\n').first, '[00:01.00]Alpha omega');
    });

    test('keys prefer the ISRC, then the catalog id, then the tags', () {
      expect(
        lyricsCorrectionKey(
          isrc: 'zz0000000001',
          catalogSource: 'spotify',
          catalogId: '1',
          artist: 'A',
          title: 'T',
          durationMs: 1000,
        ),
        'isrc:ZZ0000000001',
      );
      expect(
        lyricsCorrectionKey(
          catalogSource: 'Spotify',
          catalogId: '1',
          artist: 'A',
          title: 'T',
          durationMs: 1000,
        ),
        'catalog:spotify:1',
      );
      expect(
        lyricsCorrectionKey(artist: 'A', title: 'T', durationMs: 120400),
        'track:a|t|120',
      );
    });
  });
}
