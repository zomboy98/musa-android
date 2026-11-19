import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_signals.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/smart_shuffle.dart';

final _now = DateTime(2026, 11, 15, 12);

PlayableMedia _track(
  int i, {
  String? artist,
  String? album,
  String? genre,
  String? albumId,
}) => PlayableMedia(
  id: 'id-$i',
  source: '/song-$i.flac',
  title: 'Song $i',
  artist: artist ?? 'Artist $i',
  album: album ?? 'Album $i',
  albumId: albumId,
  genre: genre,
);

SnapshotListeningSignals _signals(
  List<PlayableMedia> tracks,
  Map<int, SongListening> songs, {
  Map<String, ArtistListening> artists = const {},
}) => SnapshotListeningSignals(
  now: _now,
  songs: {
    for (final entry in songs.entries)
      listeningSongKeyOf(tracks[entry.key]): entry.value,
  },
  artists: artists,
);

double _meanRank(
  List<PlayableMedia> tracks,
  ListeningSignals signals,
  Set<int> group, {
  int seeds = 120,
}) {
  var total = 0.0;
  var count = 0;
  for (var seed = 0; seed < seeds; seed++) {
    final order = smartShuffleOrder(
      tracks,
      signals: signals,
      random: Random(seed),
    );
    for (var rank = 0; rank < order.length; rank++) {
      if (group.contains(order[rank])) {
        total += rank;
        count++;
      }
    }
  }
  return total / count;
}

void main() {
  group('Aleatorio comun', () {
    test('cada permutacion posible sale con la misma frecuencia', () {
      final random = Random(11);
      final counts = <String, int>{};
      const draws = 6000;
      for (var i = 0; i < draws; i++) {
        final order = buildShuffledQueueOrder(
          mediaCount: 4,
          currentIndex: 0,
          random: random,
        );
        counts.update(order.join(), (n) => n + 1, ifAbsent: () => 1);
      }
      expect(counts.length, 6);
      for (final count in counts.values) {
        expect(count, inInclusiveRange(draws / 6 * 0.85, draws / 6 * 1.15));
      }
    });

    test('la pista actual va primero y todas salen una sola vez', () {
      for (var seed = 0; seed < 20; seed++) {
        final order = buildShuffledQueueOrder(
          mediaCount: 40,
          currentIndex: 17,
          random: Random(seed),
        );
        expect(order.first, 17);
        expect(order.toSet(), {for (var i = 0; i < 40; i++) i});
        expect(order.length, 40);
      }
    });

    test('la posicion de cada pista es uniforme', () {
      final random = Random(5);
      final positions = List.generate(6, (_) => List.filled(6, 0));
      const draws = 6000;
      for (var i = 0; i < draws; i++) {
        final order = buildShuffledQueueOrder(
          mediaCount: 6,
          currentIndex: -1,
          random: random,
        );
        for (var p = 0; p < 6; p++) {
          positions[order[p]][p]++;
        }
      }
      for (final row in positions) {
        for (final count in row) {
          expect(count, inInclusiveRange(draws / 6 * 0.85, draws / 6 * 1.15));
        }
      }
    });
  });

  group('Aleatorio inteligente', () {
    final tracks = [for (var i = 0; i < 200; i++) _track(i)];
    final neutral = {
      for (var i = 0; i < 200; i++)
        i: SongListening(
          plays: 4,
          lastPlayed: _now.subtract(const Duration(days: 14)),
        ),
    };

    test('es determinista dado el estado y la semilla', () {
      final signals = _signals(tracks, neutral);
      final a = smartShuffleOrder(tracks, signals: signals, random: Random(3));
      final b = smartShuffleOrder(tracks, signals: signals, random: Random(3));
      final c = smartShuffleOrder(tracks, signals: signals, random: Random(4));
      expect(a, b);
      expect(a, isNot(c));
      expect(a.toSet().length, 200);
    });

    test('la pista elegida va primero', () {
      final signals = _signals(tracks, neutral);
      final order = smartShuffleOrder(
        tracks,
        signals: signals,
        random: Random(1),
        first: 42,
      );
      expect(order.first, 42);
      expect(order.toSet().length, 200);
    });

    test('favoritas y completadas suben', () {
      final liked = {for (var i = 0; i < 20; i++) i * 10};
      final songs = {
        ...neutral,
        for (final i in liked)
          i: SongListening(
            plays: 12,
            completions: 6,
            favorite: i % 20 == 0,
            lastPlayed: _now.subtract(const Duration(days: 14)),
          ),
      };
      final signals = _signals(tracks, songs);
      final rest = {for (var i = 0; i < 200; i++) i}.difference(liked);
      expect(
        _meanRank(tracks, signals, liked),
        lessThan(_meanRank(tracks, signals, rest) - 20),
      );
    });

    test('las saltadas bajan', () {
      final skipped = {for (var i = 0; i < 20; i++) i * 10 + 3};
      final songs = {
        ...neutral,
        for (final i in skipped)
          i: SongListening(
            plays: 4,
            skips: 3,
            lastPlayed: _now.subtract(const Duration(days: 14)),
          ),
      };
      final signals = _signals(tracks, songs);
      final rest = {for (var i = 0; i < 200; i++) i}.difference(skipped);
      expect(
        _meanRank(tracks, signals, skipped),
        greaterThan(_meanRank(tracks, signals, rest) + 25),
      );
    });

    test('lo reciente se penaliza y lo olvidado resurge', () {
      final recent = {for (var i = 0; i < 20; i++) i * 10 + 1};
      final forgotten = {for (var i = 0; i < 20; i++) i * 10 + 2};
      final songs = {
        ...neutral,
        for (final i in recent)
          i: SongListening(
            plays: 4,
            lastPlayed: _now.subtract(const Duration(hours: 3)),
          ),
        for (final i in forgotten)
          i: SongListening(
            plays: 4,
            lastPlayed: _now.subtract(const Duration(days: 120)),
          ),
      };
      final signals = _signals(tracks, songs);
      final rest = {
        for (var i = 0; i < 200; i++) i,
      }.difference(recent).difference(forgotten);
      final restRank = _meanRank(tracks, signals, rest);
      expect(_meanRank(tracks, signals, recent), greaterThan(restRank + 40));
      expect(_meanRank(tracks, signals, forgotten), lessThan(restRank - 10));
    });

    test('la semana pasada se penaliza poco', () {
      final week = {for (var i = 0; i < 20; i++) i * 10 + 4};
      final songs = {
        ...neutral,
        for (final i in week)
          i: SongListening(
            plays: 4,
            lastPlayed: _now.subtract(const Duration(days: 3)),
          ),
      };
      final signals = _signals(tracks, songs);
      final rest = {for (var i = 0; i < 200; i++) i}.difference(week);
      final gap =
          _meanRank(tracks, signals, week) - _meanRank(tracks, signals, rest);
      expect(gap, inInclusiveRange(0, 25));
    });

    test('lo nuevo ronda el 20-25 por ciento de la sesion', () {
      final songs = {
        for (var i = 0; i < 300; i++)
          if (i % 3 != 0)
            i: SongListening(
              plays: 3 + i % 5,
              completions: 2,
              lastPlayed: _now.subtract(Duration(days: 8 + i % 40)),
            ),
      };
      final many = [for (var i = 0; i < 300; i++) _track(i)];
      final signals = _signals(many, songs);
      var unseen = 0;
      var slots = 0;
      for (var seed = 0; seed < 150; seed++) {
        final order = smartShuffleOrder(
          many,
          signals: signals,
          random: Random(seed),
        );
        for (final index in order.take(40)) {
          slots++;
          if (index % 3 == 0) unseen++;
        }
      }
      expect(unseen / slots, inInclusiveRange(0.18, 0.27));
    });

    test('el artista se separa y no se repite album seguido', () {
      final crowded = [
        for (var i = 0; i < 80; i++)
          _track(
            i,
            artist: 'Artist ${i % 8}',
            album: 'Album ${i % 20}',
            albumId: 'album-${i % 20}',
          ),
      ];
      final signals = _signals(crowded, const {});
      for (var seed = 0; seed < 25; seed++) {
        final order = smartShuffleOrder(
          crowded,
          signals: signals,
          random: Random(seed),
        );
        expect(order.toSet().length, 80);
        for (var i = 1; i < order.length; i++) {
          expect(crowded[order[i]].artist, isNot(crowded[order[i - 1]].artist));
          expect(
            crowded[order[i]].albumId,
            isNot(crowded[order[i - 1]].albumId),
          );
        }
        for (var i = 0; i + 8 <= order.length; i++) {
          final counts = <String, int>{};
          for (final index in order.sublist(i, i + 8)) {
            counts.update(
              crowded[index].artist,
              (n) => n + 1,
              ifAbsent: () => 1,
            );
          }
          expect(counts.values.every((n) => n <= 2), isTrue);
        }
      }
    });

    test('sin metadato de genero no cambia el orden ponderado', () {
      final plain = [for (var i = 0; i < 60; i++) _track(i)];
      final signals = _signals(plain, const {});
      final a = smartShuffleOrder(plain, signals: signals, random: Random(9));
      final b = smartShuffleOrder(
        [for (var i = 0; i < 60; i++) _track(i, genre: '')],
        signals: signals,
        random: Random(9),
      );
      expect(a, b);
    });

    test('con genero evita saltos bruscos cuando cuesta poco', () {
      final genres = ['rock', 'rock', 'rock', 'jazz', 'jazz', 'jazz'];
      final tagged = [
        for (var i = 0; i < 60; i++) _track(i, genre: genres[i % 6]),
      ];
      final signals = _signals(tagged, const {});
      var jumps = 0;
      var baseline = 0;
      for (var seed = 0; seed < 30; seed++) {
        final order = smartShuffleOrder(
          tagged,
          signals: signals,
          random: Random(seed),
        );
        for (var i = 1; i < order.length; i++) {
          if (tagged[order[i]].genre != tagged[order[i - 1]].genre) jumps++;
        }
        final random = [for (var i = 0; i < 60; i++) i]..shuffle(Random(seed));
        for (var i = 1; i < random.length; i++) {
          if (tagged[random[i]].genre != tagged[random[i - 1]].genre) {
            baseline++;
          }
        }
      }
      expect(jumps, lessThan(baseline * 0.8));
    });

    test('el tramo futuro se reordena sin tocar las 3 siguientes', () {
      final queue = [for (var i = 0; i < 60; i++) _track(i)];
      final signals = _signals(queue, const {});
      final order = smartShuffleReorderFuture(
        queue,
        currentIndex: 5,
        movable: {for (var i = 0; i < 60; i++) i},
        signals: signals,
        random: Random(2),
      );
      expect(order.sublist(0, 9), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(order.toSet().length, 60);
      expect(
        order.sublist(9),
        isNot(orderedEquals([for (var i = 9; i < 60; i++) i])),
      );
    });

    test('lo que no es movible conserva su lugar', () {
      final queue = [for (var i = 0; i < 30; i++) _track(i)];
      final signals = _signals(queue, const {});
      final order = smartShuffleReorderFuture(
        queue,
        currentIndex: 0,
        movable: {for (var i = 4; i < 30; i++) i}.difference({10, 11}),
        signals: signals,
        random: Random(2),
      );
      expect(order[10], 10);
      expect(order[11], 11);
      expect(order.toSet().length, 30);
    });

    test('un salto rapido baja la pista y, a la mitad, su artista', () {
      final queue = [
        for (var i = 0; i < 90; i++)
          _track(i, artist: 'Artist ${i % 9}', album: 'Album $i'),
      ];
      final signals = _signals(queue, const {});
      final skipped = queue[0];
      var songRank = 0.0;
      var artistRank = 0.0;
      var baseSong = 0.0;
      var baseArtist = 0.0;
      const seeds = 150;
      for (var seed = 0; seed < seeds; seed++) {
        final session = SmartShuffleSession()..skipped(skipped);
        final adapted = smartShuffleOrder(
          queue,
          signals: signals,
          random: Random(seed),
          session: session,
        );
        final plain = smartShuffleOrder(
          queue,
          signals: signals,
          random: Random(seed),
        );
        double rank(List<int> order, bool Function(int) test) {
          final ranks = [
            for (var r = 0; r < order.length; r++)
              if (test(order[r])) r,
          ];
          return ranks.reduce((a, b) => a + b) / ranks.length;
        }

        songRank += rank(adapted, (i) => i == 0);
        baseSong += rank(plain, (i) => i == 0);
        artistRank += rank(adapted, (i) => i != 0 && i % 9 == 0);
        baseArtist += rank(plain, (i) => i != 0 && i % 9 == 0);
      }
      final songShift = (songRank - baseSong) / seeds;
      final artistShift = (artistRank - baseArtist) / seeds;
      expect(songShift, greaterThan(15));
      expect(artistShift, greaterThan(2));
      expect(artistShift, lessThan(songShift));
    });

    test('completar sube un poco al artista', () {
      final queue = [
        for (var i = 0; i < 90; i++)
          _track(i, artist: 'Artist ${i % 9}', album: 'Album $i'),
      ];
      final signals = _signals(queue, const {});
      final session = SmartShuffleSession()..completed(queue[0]);
      final weights = smartShuffleWeights(queue, signals, session: session);
      final base = smartShuffleWeights(queue, signals);
      expect(weights[9] / base[9], inInclusiveRange(1.05, 1.3));
      expect(weights[1] / base[1], closeTo(1, 1e-9));
    });

    test('funciona solo con datos locales y sin historial', () {
      final signals = SnapshotListeningSignals(now: _now);
      final order = smartShuffleOrder(
        tracks,
        signals: signals,
        random: Random(1),
      );
      expect(order.toSet().length, tracks.length);
    });

    test('la cola elegible necesita varios albumes y artistas', () {
      final album = [
        for (var i = 0; i < 8; i++) _track(i, artist: 'A', album: 'X'),
      ];
      expect(smartShuffleEligible(album), isFalse);
      expect(
        smartShuffleEligible([for (var i = 0; i < 8; i++) _track(i)]),
        isTrue,
      );
      expect(smartShuffleEligible(const []), isFalse);
    });
  });
}
