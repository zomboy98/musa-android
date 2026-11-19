part of 'music_player_service.dart';

/// Changes the existing queue's transport, so notification and player controls
/// continue to use the same handler while the TV owns audio output.
class _MusicCast {
  _MusicCast(this.handler, this.output);

  final MusicPlayerHandler handler;
  final CastOutput? output;
  String? _requestedDevice;
  String? _appliedDevice;
  StreamSubscription<Map<Object?, Object?>>? _volumeSubscription;
  int? _volumeIndex;
  bool _closed = false;
  int? _changingOutputGeneration;

  bool get active => _appliedDevice != null;
  bool get localRequested => _requestedDevice == null;
  bool get changingOutput =>
      _changingOutputGeneration == handler._playRequestGeneration;

  void beginOutputChange(int generation) {
    if (_changingOutputGeneration != null ||
        _appliedDevice != _requestedDevice) {
      _changingOutputGeneration = generation;
    }
  }

  void finishOutputChange(int generation) {
    if (_changingOutputGeneration == generation) {
      _changingOutputGeneration = null;
    }
  }

  void initialize() {
    final output = this.output;
    if (output == null) return;
    output.addListener(_changed);
    _volumeSubscription = output.updates.listen((_) => _showVolume());
    unawaited(output.initialize().then((_) => _changed()));
  }

  void _changed() {
    final output = this.output;
    if (_closed || output == null || handler._disposed) return;
    final device = output.connected
        ? '${output.deviceId}/${output.host}/${output.revision}'
        : null;
    if (device == _requestedDevice) return;
    _requestedDevice = device;
    // A passive output change only records the destination while Stop owns
    // the transport. The next explicit load applies it after cancellation.
    if (handler._stopRequested) return;
    // Before preparation, the published state can still belong to the
    // previous queue occurrence. Read the requested position and intent.
    final sourceReady = handler._sourceReady;
    final state = handler.playbackState.value;
    final position =
        handler._pendingSeekPosition ??
        (sourceReady
            ? state.position
            : handler._pendingRestorePosition ?? Duration.zero);
    final loading =
        handler._switchingGeneration != 0 &&
        handler._switchingGeneration == handler._playRequestGeneration;
    // Losing the TV must never start the phone speaker unexpectedly.
    final startPaused =
        device == null ||
        handler._userPaused ||
        !(sourceReady
            ? state.playing && !handler._interruptionActive
            : loading);
    handler._pendingRestorePosition = position;
    handler._userPaused = startPaused;
    final generation = ++handler._playRequestGeneration;
    handler._newPlaybackOccurrence();
    handler._preparedPausedDeck = null;
    handler._sourceReady = false;
    handler._switchingGeneration = generation;
    _changingOutputGeneration = generation;
    unawaited(() async {
      try {
        if (handler._stopPreparation != null) {
          await handler._waitForStopPreparation();
          if (_closed || generation != handler._playRequestGeneration) return;
        }
        await handler._player.cancelPreparation();
        await handler._serializeSourceChange(() async {
          if (_closed || generation != handler._playRequestGeneration) return;
          await handler._cancelTransitions();
          if (_closed || generation != handler._playRequestGeneration) return;
          final index = handler._index;
          if (index < 0 || index >= handler._media.length) {
            await applyOutput(generation);
            return;
          }
          await handler._loadIndex(
            generation,
            handler._media[index],
            recordHistory: false,
            preserveListeningSession: true,
            startPosition: position,
            startPaused: startPaused,
          );
        });
        await handler._drainLoadingPermanentOffer(generation);
      } catch (error, stack) {
        if (generation == handler._playRequestGeneration &&
            !handler._disposed) {
          handler._reportPlaybackError(handler._player, error, stack);
        }
      } finally {
        handler._finishSourceLoad(generation);
      }
    }());
  }

  Future<void> applyOutput(int generation) async {
    if (_closed ||
        generation != handler._playRequestGeneration ||
        _appliedDevice == _requestedDevice) {
      return;
    }
    final device = _requestedDevice;
    final previous = handler._player;
    try {
      await previous.stop();
    } catch (error) {
      _log.w('Previous audio output could not stop: $error');
    }
    if (_closed ||
        generation != handler._playRequestGeneration ||
        device != _requestedDevice) {
      return;
    }
    handler._player = device != null
        ? handler._dependencies.createCastDeck(
            output!,
            () => handler.mediaItem.value,
          )
        : handler._dependencies.createDeck('music-player');
    _appliedDevice = device;
    handler._listenToPlayer(handler._player);
    await handler._disposeDeck(previous);
    handler._refreshPlaybackAutomation();
    if (device != null) {
      // iOS keeps the session for the Cast plugin's silent keep-alive, which
      // lets the app keep serving the TV in the background.
      if (!Platform.isIOS) await handler._audioSession?.setActive(false);
      _showVolume();
    } else {
      _volumeIndex = null;
      handler.androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
    }
  }

  void _showVolume() {
    if (_closed || !active) return;
    final index = ((output?.volume ?? 0) * 100).round();
    if (index == _volumeIndex) return;
    _volumeIndex = index;
    handler.androidPlaybackInfo.add(
      RemoteAndroidPlaybackInfo(
        volumeControlType: AndroidVolumeControlType.absolute,
        maxVolume: 100,
        volume: index,
      ),
    );
  }

  Future<void> setVolume(int value) async {
    if (active) {
      await output?.command('volume', {'volume': value.clamp(0, 100) / 100});
    }
  }

  Future<void> adjustVolume(AndroidVolumeDirection direction) =>
      setVolume(((output?.volume ?? 0) * 100).round() + direction.index * 5);

  Future<void> dispose() async {
    _closed = true;
    await _volumeSubscription?.cancel();
    output?.removeListener(_changed);
    if (active) {
      try {
        await output?.command('disconnect');
      } catch (error) {
        _log.w('Could not end Cast session: $error');
      }
    }
  }
}
