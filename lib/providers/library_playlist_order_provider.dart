import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LibraryPlaylistOrder {
  const LibraryPlaylistOrder({this.pinned = const {}, this.played = const {}});
  final Set<String> pinned;
  final Map<String, int> played;
}

final libraryPlaylistOrderProvider =
    AsyncNotifierProvider<LibraryPlaylistOrderNotifier, LibraryPlaylistOrder>(
      LibraryPlaylistOrderNotifier.new,
    );

class LibraryPlaylistOrderNotifier extends AsyncNotifier<LibraryPlaylistOrder> {
  static const _key = 'library_playlist_order_v1';
  Future<void> _pending = Future.value();

  @override
  Future<LibraryPlaylistOrder> build() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final data =
          jsonDecode(prefs.getString(_key) ?? '{}') as Map<String, dynamic>;
      return LibraryPlaylistOrder(
        pinned: (data['pinned'] as List? ?? []).whereType<String>().toSet(),
        played: (data['played'] as Map? ?? {}).map(
          (key, value) => MapEntry(key.toString(), value is int ? value : 0),
        ),
      );
    } catch (_) {
      return const LibraryPlaylistOrder();
    }
  }

  Future<void> togglePin(String id) => _serialize(() async {
    final current = await future;
    final pinned = {...current.pinned};
    if (!pinned.add(id)) pinned.remove(id);
    await _save(LibraryPlaylistOrder(pinned: pinned, played: current.played));
  });

  Future<void> recordPlayback(String id) => _serialize(() async {
    final current = await future;
    await _save(
      LibraryPlaylistOrder(
        pinned: current.pinned,
        played: {...current.played, id: DateTime.now().millisecondsSinceEpoch},
      ),
    );
  });

  /// A download of the playlist's songs finished: the playlist counts as
  /// recently used. Writes at most once per [window] so a long download does
  /// not rewrite the preferences for every song.
  Future<void> recordDownloadActivity(
    String id, {
    Duration window = const Duration(seconds: 30),
  }) => _serialize(() async {
    final current = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = current.played[id] ?? 0;
    if (now - last < window.inMilliseconds) return;
    await _save(
      LibraryPlaylistOrder(
        pinned: current.pinned,
        played: {...current.played, id: now},
      ),
    );
  });

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> _save(LibraryPlaylistOrder value) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = await prefs.setString(
        _key,
        jsonEncode({'pinned': value.pinned.toList(), 'played': value.played}),
      );
      if (!saved) throw StateError('Could not save playlist order');
    } catch (_) {
      // The legacy preferences API updates its cache before the platform write.
      // Refresh it so later provider instances do not read the failed value.
      try {
        await prefs.reload();
      } catch (_) {}
      rethrow;
    }
    state = AsyncData(value);
  }
}
