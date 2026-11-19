import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_player_service.dart'
    show MusicPlayerHandler;
import 'package:mornye/services/playable_media.dart';

import 'jam_playback.dart';

/// Projects Jam onto the host's local handler, never onto a Link remote.
class RuntimeJamPlaybackPort
    implements JamPlaybackPort<PlayableMedia>, JamPlaybackLifecycle {
  RuntimeJamPlaybackPort(
    this.runtime, {
    this.initialQueueRevision,
    this.initialCurrentIndex,
    this.initialCurrentOccurrenceId,
  });

  final MusicPlayerRuntime runtime;
  MusicPlayerHandler? _handler;
  final int? initialQueueRevision;
  final int? initialCurrentIndex;
  final String? initialCurrentOccurrenceId;
  bool _initialized = false;

  @override
  Future<void> reconcileQueue(
    List<JamPlaybackEntry<PlayableMedia>> entries,
  ) async {
    final handler = runtime.handler;
    if (handler == null) throw StateError('Local player is not initialized');
    if (_handler != null && !identical(_handler, handler)) {
      throw StateError('Local player changed during Jam');
    }
    _handler = handler;
    await handler.reconcileJamQueue(
      [
        for (final entry in entries)
          (occurrenceId: entry.occurrenceId, media: entry.track),
      ],
      expectedQueueRevision: _initialized ? null : initialQueueRevision,
      expectedCurrentIndex: _initialized ? null : initialCurrentIndex,
      initialCurrentOccurrenceId: _initialized
          ? null
          : initialCurrentOccurrenceId,
    );
    _initialized = true;
  }

  @override
  Future<void> closeJamPlayback() async {
    _handler?.endJamQueue();
    _handler = null;
  }
}
