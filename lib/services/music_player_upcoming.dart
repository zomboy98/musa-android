part of 'music_player_service.dart';

/// Prepares the streaming songs queued right after the current one while it
/// plays, so reaching them does not wait on a provider.
class _MusicUpcoming {
  _MusicUpcoming(this.handler);

  /// Queue positions after the current one that are looked at; more than the
  /// songs kept ready, so a song that fails does not shorten the window.
  static const window = maxPrefetchWindow + 3;

  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  final MusicPlayerHandler handler;

  late final UpcomingPrefetcher prefetcher = UpcomingPrefetcher(
    prepare: handler._catalogPlayback.prefetch,
    cancel: handler._catalogPlayback.cancel,
    isStreamingOnly: (track) async =>
        !await handler._catalogPlayback.hasLocalCopy(track),
    network: currentPrefetchNetwork,
    key: handler._catalogPlayback.key,
    gap: DownloadQueuePacing.providerGap,
    providerWait: () => ProviderCooldown.instance.remaining(
      handler._catalogPlayback.defaultService,
    ),
    trackWait: (track) {
      final catalog = handler._catalogPlayback;
      return catalog.retryPolicy?.blockedFor(
            catalog.defaultService,
            catalog.key(track),
          ) ??
          Duration.zero;
    },
  );

  /// A song is being asked for: nothing else may compete with its preparation.
  void requested(PlayableMedia media) {
    prefetcher.hold(target: media.isCatalog ? media.catalogTrack : null);
  }

  void refresh() {
    if (handler._disposed) return;
    final count = handler._settings.playbackPrefetchCount.clamp(
      0,
      UpcomingPrefetcher.maxCount,
    );
    prefetcher.count = count;
    final catalog = handler._catalogPlayback;
    catalog.defaultService = handler._settings.defaultService;
    catalog.providerConfirmed = handler._settings.playbackProviderConfirmed;
    catalog.quality = handler._settings.playbackQuality;
    catalog.useExtensions = handler._settings.useExtensionProviders;
    catalog.useFallback = handler._settings.autoFallback;
    final index = handler._index;
    final media = handler._media;
    if (index < 0 || index >= media.length) return;
    if (!handler._sourceReady) return;
    final current = media[index].catalogTrack;
    final upcoming = <Track>[];
    if (count > 0 && !handler._cast.active) {
      final indexes = prefetchUpcomingIndexes(
        index: index,
        length: media.length,
        lookahead: window,
        repeatAll: handler._repeatMode == AudioServiceRepeatMode.all,
        repeatOne: handler._repeatMode == AudioServiceRepeatMode.one,
        shuffle: handler._shuffle,
      );
      for (final i in indexes) {
        final track = media[i].isCatalog ? media[i].catalogTrack : null;
        if (track != null) upcoming.add(track);
      }
    }
    catalog.prefetchRetention = count;
    _watchConnectivity();
    prefetcher.schedule(upcoming, current: current, index: index);
  }

  void _watchConnectivity() {
    if (_connectivity != null) return;
    try {
      _connectivity = Connectivity().onConnectivityChanged.listen(
        (_) => prefetcher.networkChanged(),
        onError: (Object _) {},
      );
    } catch (_) {}
  }

  void playingChanged({required bool playing, required bool failed}) {
    prefetcher.setPaused(handler._sourceReady && !playing && !failed);
  }

  void stop() {
    unawaited(_connectivity?.cancel());
    _connectivity = null;
    prefetcher.stop();
  }
}
