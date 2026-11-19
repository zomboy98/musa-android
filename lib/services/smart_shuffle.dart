import 'dart:math';

import 'package:mornye/services/listening_signals.dart';
import 'package:mornye/services/playable_media.dart';

const smartShuffleFrozenAhead = 3;

const _favoriteBoost = 0.9;
const _trackAffinity = 0.30;
const _artistAffinity = 0.25;
const _artistAffinityCap = 0.9;
const _artistFavoriteBoost = 0.08;
const _affinityCap = 4.0;
const _skipDecay = 0.55;
const _artistSkipDecay = 0.2;

const _recentDayPenalty = 0.12;
const _recentWeekFactor = 0.8;
const _resurfaceStart = Duration(days: 30);
const _resurfaceFull = Duration(days: 90);
const _resurfaceBoost = 0.6;

const smartShuffleDiscoveryShare = 0.22;
const _discoveryMin = 0.35;
const _discoveryMax = 3.0;

const _spacingWindow = 8;
const _spacingMaxInWindow = 2;
const _spacingLookahead = 48;
const _genreLookahead = 3;
const _balanceCandidates = 6;

const _sessionSongSkip = 1.0;
const _sessionArtistSkip = 0.5;
const _sessionArtistComplete = 0.15;
const _sessionLimit = 2.5;

class SmartShuffleSession {
  final Map<String, double> _songs = {};
  final Map<String, double> _artists = {};

  bool get isEmpty => _songs.isEmpty && _artists.isEmpty;

  void clear() {
    _songs.clear();
    _artists.clear();
  }

  void skipped(PlayableMedia track) {
    final song = listeningSongKeyOf(track);
    _songs[song] = (_songs[song] ?? 0) - _sessionSongSkip;
    for (final key in listeningArtistKeys(track.artist)) {
      _artists[key] = (_artists[key] ?? 0) - _sessionArtistSkip;
    }
  }

  void completed(PlayableMedia track) {
    for (final key in listeningArtistKeys(track.artist)) {
      _artists[key] = (_artists[key] ?? 0) + _sessionArtistComplete;
    }
  }

  double factor(PlayableMedia track) {
    var exponent = _songs[listeningSongKeyOf(track)] ?? 0;
    final keys = listeningArtistKeys(track.artist);
    if (keys.isNotEmpty) {
      var artist = 0.0;
      for (final key in keys) {
        artist += _artists[key] ?? 0;
      }
      exponent += artist / keys.length;
    }
    return exp(exponent.clamp(-_sessionLimit, _sessionLimit));
  }
}

double _freshness(DateTime now, DateTime? lastPlayed) {
  if (lastPlayed == null) return 1;
  final age = now.difference(lastPlayed);
  if (age < const Duration(hours: 24)) return _recentDayPenalty;
  if (age < const Duration(days: 7)) return _recentWeekFactor;
  if (age < _resurfaceStart) return 1;
  final span = (_resurfaceFull - _resurfaceStart).inMinutes;
  final progress = ((age - _resurfaceStart).inMinutes / span).clamp(0.0, 1.0);
  return 1 + _resurfaceBoost * progress;
}

double _affinity(ListeningSignals signals, PlayableMedia track) {
  final artists = listeningArtistKeys(track.artist);
  var artistCompletions = 0.0;
  var artistSkips = 0.0;
  var artistFavorites = 0;
  for (final key in artists) {
    artistCompletions = max(artistCompletions, signals.artistCompletions(key));
    artistSkips = max(artistSkips, signals.artistSkips(key));
    artistFavorites = max(artistFavorites, signals.artistFavorites(key));
  }
  final boost =
      (signals.isFavorite(track) ? _favoriteBoost : 0) +
      _trackAffinity * log(1 + signals.recentCompletions(track)) +
      min(_artistAffinity * log(1 + artistCompletions), _artistAffinityCap) +
      _artistFavoriteBoost * min(artistFavorites, 5);
  final penalty =
      _skipDecay * min(signals.recentSkips(track), 3.0) +
      _artistSkipDecay * min(artistSkips, 5.0);
  return min(1 + boost, _affinityCap) * exp(-penalty);
}

bool _neverPlayed(ListeningSignals signals, PlayableMedia track) =>
    signals.playCount(track) <= 0 && signals.lastPlayed(track) == null;

List<double> smartShuffleWeights(
  List<PlayableMedia> tracks,
  ListeningSignals signals, {
  SmartShuffleSession? session,
}) {
  final weights = List<double>.filled(tracks.length, 1);
  final unplayed = <int>[];
  var playedTotal = 0.0;
  var unplayedAffinity = 0.0;
  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final affinity = _affinity(signals, track);
    final adaptation = session?.factor(track) ?? 1.0;
    if (_neverPlayed(signals, track)) {
      weights[i] = affinity * adaptation;
      unplayed.add(i);
      unplayedAffinity += weights[i];
    } else {
      weights[i] =
          affinity *
          _freshness(signals.now, signals.lastPlayed(track)) *
          adaptation;
      playedTotal += weights[i];
    }
  }
  if (unplayed.isNotEmpty && playedTotal > 0 && unplayedAffinity > 0) {
    final target = smartShuffleDiscoveryShare;
    final scale = (target / (1 - target) * playedTotal / unplayedAffinity)
        .clamp(_discoveryMin, _discoveryMax);
    for (final i in unplayed) {
      weights[i] *= scale;
    }
  }
  for (var i = 0; i < weights.length; i++) {
    if (!weights[i].isFinite || weights[i] < 1e-6) weights[i] = 1e-6;
  }
  return weights;
}

List<int> _weightedOrder(List<double> weights, Random random) {
  final keys = [
    for (var i = 0; i < weights.length; i++)
      log(1 - random.nextDouble()) / weights[i],
  ];
  return [for (var i = 0; i < weights.length; i++) i]..sort((a, b) {
    final byKey = keys[b].compareTo(keys[a]);
    return byKey != 0 ? byKey : a.compareTo(b);
  });
}

String? _albumKey(PlayableMedia track) {
  final id = track.albumId?.trim();
  if (id != null && id.isNotEmpty) return 'id:$id';
  final album = track.album.trim().toLowerCase();
  if (album.isEmpty) return null;
  return '$album|${track.artist.trim().toLowerCase()}';
}

Set<String> _genreTokens(PlayableMedia track) {
  final genre = track.genre?.trim().toLowerCase() ?? '';
  if (genre.isEmpty) return const {};
  return genre
      .split(RegExp(r'[\s/,;&\-]+'))
      .where((token) => token.length > 2)
      .toSet();
}

bool _genresClose(PlayableMedia a, PlayableMedia b) {
  final left = _genreTokens(a);
  final right = _genreTokens(b);
  if (left.isEmpty || right.isEmpty) return true;
  return left.intersection(right).isNotEmpty;
}

class _Spacer {
  _Spacer(this.tracks, List<PlayableMedia> context)
    : _artists = [
        for (final track in tracks) listeningArtistKeys(track.artist).toSet(),
      ],
      _albums = [for (final track in tracks) _albumKey(track)],
      _tail = [
        for (final track
            in context.length > _spacingWindow
                ? context.sublist(context.length - _spacingWindow)
                : context)
          (listeningArtistKeys(track.artist).toSet(), _albumKey(track), track),
      ];

  final List<PlayableMedia> tracks;
  final List<Set<String>> _artists;
  final List<String?> _albums;
  final List<(Set<String>, String?, PlayableMedia)> _tail;

  int _level(int index) {
    if (_tail.isEmpty) return 0;
    final artists = _artists[index];
    final album = _albums[index];
    final last = _tail.last;
    if (artists.any(last.$1.contains)) return 3;
    if (album != null && album == last.$2) return 3;
    final window = _tail.length >= _spacingWindow
        ? _tail.sublist(_tail.length - (_spacingWindow - 1))
        : _tail;
    for (final artist in artists) {
      var count = 0;
      for (final entry in window) {
        if (entry.$1.contains(artist)) count++;
      }
      if (count >= _spacingMaxInWindow) return 1;
    }
    return 0;
  }

  void place(int index) {
    _tail.add((_artists[index], _albums[index], tracks[index]));
    if (_tail.length > _spacingWindow) _tail.removeAt(0);
  }

  PlayableMedia? get previous => _tail.isEmpty ? null : _tail.last.$3;

  List<int> arrange(List<int> ordered) {
    final remaining = List<int>.of(ordered);
    final result = <int>[];
    final left = <String, int>{};
    for (final index in ordered) {
      final key = _primary(index);
      left[key] = (left[key] ?? 0) + 1;
    }
    while (remaining.isNotEmpty) {
      var pick = -1;
      var best = 4;
      final limit = min(remaining.length, _spacingLookahead);
      var considered = 0;
      var crowd = -1;
      for (var j = 0; j < limit; j++) {
        final level = _level(remaining[j]);
        if (level == 0) {
          final count = left[_primary(remaining[j])] ?? 0;
          if (count > crowd) {
            crowd = count;
            pick = j;
            best = 0;
          }
          if (++considered >= _balanceCandidates) break;
        } else if (level < best && best != 0) {
          best = level;
          pick = j;
        }
      }
      if (best > 0) {
        for (var j = limit; j < remaining.length; j++) {
          final level = _level(remaining[j]);
          if (level < best) {
            best = level;
            pick = j;
            if (level == 0) break;
          }
        }
      }
      final previous = this.previous;
      if (previous != null &&
          pick >= 0 &&
          !_genresClose(previous, tracks[remaining[pick]])) {
        final scan = min(remaining.length, pick + 1 + _genreLookahead);
        for (var j = pick + 1; j < scan; j++) {
          if (_level(remaining[j]) <= best &&
              _genresClose(previous, tracks[remaining[j]])) {
            pick = j;
            break;
          }
        }
      }
      final chosen = remaining.removeAt(pick < 0 ? 0 : pick);
      left[_primary(chosen)] = (left[_primary(chosen)] ?? 1) - 1;
      result.add(chosen);
      place(chosen);
    }
    _repair(result);
    return result;
  }

  String _primary(int index) {
    final artists = _artists[index];
    return artists.isEmpty ? '' : artists.first;
  }

  bool _touching(int a, int b) {
    if (_artists[a].any(_artists[b].contains)) return true;
    final album = _albums[a];
    return album != null && album == _albums[b];
  }

  bool _clashesAt(List<int> order, int at, int item) =>
      (at > 0 && _touching(order[at - 1], item)) ||
      (at + 1 < order.length && _touching(order[at + 1], item));

  void _repair(List<int> order) {
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 1; i < order.length; i++) {
        if (!_touching(order[i - 1], order[i])) continue;
        for (var step = 1; step < order.length; step++) {
          final j = i + step < order.length ? i + step : i - step - 1;
          if (j < 1 || j >= order.length || (j - i).abs() <= 1) continue;
          final a = order[i];
          final b = order[j];
          order[i] = b;
          order[j] = a;
          final fixed =
              !_clashesAt(order, i, order[i]) &&
              !_clashesAt(order, j, order[j]);
          if (fixed) break;
          order[i] = a;
          order[j] = b;
        }
      }
    }
  }
}

List<int> smartShuffleOrder(
  List<PlayableMedia> tracks, {
  required ListeningSignals signals,
  required Random random,
  int? first,
  SmartShuffleSession? session,
  List<PlayableMedia> context = const [],
}) {
  if (tracks.isEmpty) return const [];
  final fixed = first != null && first >= 0 && first < tracks.length
      ? first
      : null;
  final weights = smartShuffleWeights(tracks, signals, session: session);
  final pool = [
    for (var i = 0; i < tracks.length; i++)
      if (i != fixed) i,
  ];
  final ordered = _weightedOrder([for (final i in pool) weights[i]], random);
  final spacer = _Spacer(tracks, context);
  final result = <int>[];
  if (fixed != null) {
    result.add(fixed);
    spacer.place(fixed);
  }
  result.addAll(spacer.arrange([for (final k in ordered) pool[k]]));
  return result;
}

int smartShufflePick(
  List<PlayableMedia> tracks, {
  required ListeningSignals signals,
  required Random random,
  SmartShuffleSession? session,
}) {
  if (tracks.isEmpty) return -1;
  final weights = smartShuffleWeights(tracks, signals, session: session);
  return _weightedOrder(weights, random).first;
}

List<int> smartShuffleReorderFuture(
  List<PlayableMedia> queue, {
  required int currentIndex,
  required Set<int> movable,
  required ListeningSignals signals,
  required Random random,
  SmartShuffleSession? session,
  int frozenAhead = smartShuffleFrozenAhead,
}) {
  final order = [for (var i = 0; i < queue.length; i++) i];
  final fixedEnd = min(queue.length, max(0, currentIndex) + 1 + frozenAhead);
  final slots = [
    for (var i = fixedEnd; i < queue.length; i++)
      if (movable.contains(i)) i,
  ];
  if (slots.length < 2) return order;
  final pool = [for (final slot in slots) queue[slot]];
  final context = queue.sublist(max(0, fixedEnd - _spacingWindow), fixedEnd);
  final arranged = smartShuffleOrder(
    pool,
    signals: signals,
    random: random,
    session: session,
    context: context,
  );
  for (var k = 0; k < slots.length; k++) {
    order[slots[k]] = slots[arranged[k]];
  }
  return order;
}
