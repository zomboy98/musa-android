import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('AlbumQuality');

class AlbumQualityChoices extends Notifier<Map<String, String>> {
  static const storageKey = 'album_quality_choices_v1';

  Future<void> _tail = Future.value();
  Future<void> ready = Future.value();

  @override
  Map<String, String> build() {
    ready = _restore();
    return const <String, String>{};
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final stored = <String, String>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
      state = {...stored, ...state};
    } catch (error, stack) {
      _log.e('Could not read the album quality choices', error, stack);
    }
  }

  String? of(String albumKey) => state[albumKey];

  Future<bool> choose(String albumKey, String qualityId) {
    if (state[albumKey] == qualityId) return Future.value(true);
    state = {...state, albumKey: qualityId};
    final snapshot = jsonEncode(state);
    final write = _tail.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        return await prefs.setString(storageKey, snapshot);
      } catch (error, stack) {
        _log.e('Could not save the album quality choice', error, stack);
        return false;
      }
    });
    _tail = write.then<void>((_) {});
    return write;
  }
}

final albumQualityChoicesProvider =
    NotifierProvider<AlbumQualityChoices, Map<String, String>>(
      AlbumQualityChoices.new,
    );

class AlbumReplaceProgress {
  const AlbumReplaceProgress({
    required this.total,
    this.done = 0,
    this.failed = 0,
    this.running = true,
  });

  final int total;
  final int done;
  final int failed;
  final bool running;

  int get finished => done + failed;

  AlbumReplaceProgress copyWith({int? done, int? failed, bool? running}) =>
      AlbumReplaceProgress(
        total: total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        running: running ?? this.running,
      );
}

typedef TrackQualityReplace =
    Future<String?> Function(
      Track track,
      String service,
      String qualityId, {
      required String previousPath,
      required String previousHistoryId,
    });

final trackQualityReplaceProvider = Provider<TrackQualityReplace>(
  (ref) =>
      (
        track,
        service,
        qualityId, {
        required previousPath,
        required previousHistoryId,
      }) => ref
          .read(downloadQueueProvider.notifier)
          .replaceTrackQuality(
            track,
            service,
            qualityId,
            previousPath: previousPath,
            previousHistoryId: previousHistoryId,
          )
          .then((result) => result.path),
);

class AlbumQualityReplacer extends Notifier<Map<String, AlbumReplaceProgress>> {
  @override
  Map<String, AlbumReplaceProgress> build() =>
      const <String, AlbumReplaceProgress>{};

  bool isRunning(String albumKey) => state[albumKey]?.running == true;

  Future<void> replace({
    required String albumKey,
    required List<({Track track, DownloadHistoryItem item})> entries,
    required String qualityId,
  }) async {
    if (entries.isEmpty || isRunning(albumKey)) return;
    final replace = ref.read(trackQualityReplaceProvider);
    state = {...state, albumKey: AlbumReplaceProgress(total: entries.length)};
    for (final entry in entries) {
      String? path;
      try {
        path = await replace(
          entry.track,
          entry.item.service,
          qualityId,
          previousPath: entry.item.filePath,
          previousHistoryId: entry.item.id,
        );
      } catch (error, stack) {
        _log.e('Could not replace a song of the album', error, stack);
      }
      if (!ref.mounted) return;
      final current = state[albumKey]!;
      state = {
        ...state,
        albumKey: path == null
            ? current.copyWith(failed: current.failed + 1)
            : current.copyWith(done: current.done + 1),
      };
    }
    if (!ref.mounted) return;
    state = {...state, albumKey: state[albumKey]!.copyWith(running: false)};
  }
}

final albumQualityReplacerProvider =
    NotifierProvider<AlbumQualityReplacer, Map<String, AlbumReplaceProgress>>(
      AlbumQualityReplacer.new,
    );
