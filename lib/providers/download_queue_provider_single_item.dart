// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

class _DownloadQualityUnavailable implements Exception {
  @override
  String toString() =>
      'Select a download quality for this provider in settings';
}

extension _SingleItemDownload on DownloadQueueNotifier {
  Future<String?> _runPostProcessingHooks(
    String filePath,
    Track track,
    String itemId,
  ) async {
    // Extension hooks can modify the file in place, including its audio.
    // Downloaded audio must remain as delivered by the provider.
    return null;
  }

  Future<void> _downloadSingleItem(DownloadItem item) async {
    final finished = Completer<void>();
    final attempt = finished.future;
    _activeDownloadAttempts[item.id] = attempt;
    try {
      if (_failForProviderCooldown(item)) return;
      await _DownloadRun(this, item)._run();
    } finally {
      _activeDownloadAttempts.remove(item.id);
      finished.complete();
    }
  }
}

/// One download attempt for a single queue item.
///
/// The stage order is enrich -> resolve output -> resolve identifiers ->
/// download -> decrypt/convert/embed -> publish. `n` owns shared queue state.
class _DownloadRun {
  _DownloadRun(this.n, this.item);

  final DownloadQueueNotifier n;

  DownloadItem item;
  bool pausedDuringThisRun = false;
  String _failureStage = 'unknown';

  late AppSettings settings;
  bool get metadataEmbeddingEnabled => settings.embedMetadata;
  late Track trackToDownload;
  String? resolvedAlbumArtist;
  late String quality;
  late String safOutputExt;
  late String effectiveFilenameFormat;
  bool effectiveSafMode = false;
  String effectiveOutputDir = '';
  String? appOutputDir;
  String? customFolderPath;
  String? safFileName;
  bool qualityVariantCollisionOnly = false;
  String? safBaseName;
  String? finalSafFileName;

  late ExtensionState extensionState;
  late bool selectedExtensionDownloadProvider;
  late bool shouldSkipExtensionSongLinkPrelookup;
  late bool shouldSkipMetadataEnrichment;
  late bool useExtensions;
  bool usingUnavailableProviderFallback = false;
  bool qualityFromSavedPreference = false;

  String? deezerTrackId;
  String? genre;
  String? label;
  String? copyright;

  late DownloadResult result;

  String? filePath;
  bool wasExisting = false;
  String actualQuality = '';
  String? resultOutputExt;
  bool shouldPreserveNativeM4a = false;
  bool forceContainerConversion = false;

  /// Filled by the SAF embed op from the local temp so the final quality
  /// probe doesn't have to copy the published file back out of SAF.
  Map<String, dynamic>? probedFinalMetadata;
  bool externalLrcWritten = false;
  final Map<String, String> _directoryScopes = {};
  bool fakeHiResChecked = false;
  bool get isNetworkDownload => item.networkDownloadFolder.isNotEmpty;
  String networkRelativeDir = '';
  String? fakeHiResOriginalPath;

  Future<void> _run() async {
    final normalizedService = n._normalizeQueuedService(item.service);
    if (normalizedService != item.service) {
      item = item.copyWith(service: normalizedService);
      n.state = n.state.copyWith(
        items: [
          for (final existing in n.state.items)
            if (existing.id == item.id) item else existing,
        ],
        currentDownload: n.state.currentDownload?.id == item.id
            ? item
            : n.state.currentDownload,
      );
      n._saveQueueToStorage();
    }

    _log.d('Processing download');

    final currentItem = n._findItemById(item.id) ?? item;
    if (n._isLocallyCancelled(item.id, item: currentItem)) {
      _log.i('Download was cancelled before start, skipping');
      return;
    }

    if (n._isPausePending(item.id)) {
      pausedDuringThisRun = true;
      n._requeueItemForPause(item.id);
      _log.i('Download is pause-pending before start, skipping');
      await n._finishPausedDownload(item.id);
      return;
    }

    settings = n.ref.read(settingsProvider);
    if (!isNetworkDownload && !_canDownloadWithConfiguredProvider()) {
      _recordUnavailableProvider();
      return;
    }

    n.state = n.state.copyWith(currentDownload: item);

    n.updateItemStatus(item.id, DownloadStatus.downloading);

    try {
      trackToDownload = item.track;

      if (isNetworkDownload) {
        final prepared = await NetworkDownloadStaging.instance.read(item.id);
        if (await _shouldAbort('during network staging lookup')) return;
        if (prepared != null) {
          trackToDownload = Track.fromJson(
            Map<String, dynamic>.from(prepared['track'] as Map),
          );
          result = DownloadResult.fromMap(
            Map<String, dynamic>.from(prepared['result'] as Map),
          );
          filePath = prepared['localPath'] as String;
          actualQuality = prepared['quality'] as String;
          externalLrcWritten = prepared['externalLrcWritten'] == true;
          networkRelativeDir = prepared['relativeDir'] as String;
          await _persistCompletionAndNotify();
          return;
        }
        if (!_canDownloadWithConfiguredProvider()) {
          _recordUnavailableProvider();
          return;
        }
      }

      if (!await _enrichDeezerTrackIfNeeded()) return;

      trackToDownload = await n._resolveDownloadAlbumCredit(
        trackToDownload,
        settings,
      );
      if (await _shouldAbort('during album metadata lookup')) return;

      resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
        trackToDownload,
        settings,
      );
      _failureStage = 'preparing_output';
      await _resolveOutputTarget();
      if (await _shouldAbort('during output preparation')) return;
      // Without a concrete tier the relay asks each provider for its best
      // one; only "only this quality" needs the user to pick first.
      if (settings.strictDownloadQuality &&
          usingUnavailableProviderFallback &&
          manifestQualityId(quality).isEmpty) {
        n._recordFailedDownload(
          item.id,
          error: 'Select a download quality for this provider in settings',
          errorType: DownloadErrorType.qualityUnavailable,
        );
        return;
      }
      _failureStage = 'unknown';
      _resolveExtensionFlags();
      if (!await _resolveTrackIdentifiers()) return;

      // Genre/label/copyright are only consumed at embed time (the payload
      // copy is just echoed back in the response), so this lookup overlaps
      // with the download instead of delaying its start; it is awaited right
      // after the download returns.
      final extendedMetadataFuture = shouldSkipMetadataEnrichment
          ? Future<DownloadExtendedMetadata?>.value(null)
          : n._metadataResolver
                .loadExtendedMetadataForDeezerId(deezerTrackId)
                .catchError((Object e) {
                  _log.w('Extended metadata lookup failed');
                  return null;
                });

      if (await _shouldAbort('before native download start')) {
        return;
      }

      if (!await _downloadAndMaybeFallback()) return;

      final extendedMetadata = await extendedMetadataFuture;
      if (extendedMetadata != null) {
        genre = extendedMetadata.genre;
        label = extendedMetadata.label;
        copyright = extendedMetadata.copyright;
      }

      final resultFilePath = result.filePath;
      final resultFileToCleanup = (resultFilePath != null && result.success)
          ? resultFilePath
          : null;
      if (await _shouldAbort(
        'after result',
        retainedArtifact: resultFileToCleanup,
      )) {
        return;
      }

      if (result.success) {
        _failureStage = Platform.isAndroid ? 'android_finalizing' : 'unknown';
        final resolvedDirectory = result.resolvedSafDirectory;
        if (effectiveSafMode && resolvedDirectory != null) {
          effectiveOutputDir = n._sanitizeSafRelativeDir(resolvedDirectory);
          _log.d('Resolved output directory');
        }
        if (!await _handleDownloadSuccess()) return;
      } else {
        if (!await _handleBackendFailure()) return;
      }

      n._downloadCount++;
      // The HTTP pool expires idle connections itself. Keep warm connections
      // for the next track; network changes/errors and queue teardown still
      // recycle the pool when needed.
    } catch (e) {
      await _handleRunException(e);
    } finally {
      if (isNetworkDownload &&
          n.ref.mounted &&
          n._findItemById(item.id) == null) {
        try {
          await NetworkDownloadStaging.instance.discard(item.id);
        } catch (_) {
          _log.w('Could not remove dismissed network staging');
        }
      }
      for (final token in _directoryScopes.values) {
        try {
          await PlatformBridge.releaseDownloadDirectory(token);
        } catch (_) {
          _log.w('Failed to release output directory scope');
        }
      }
      _directoryScopes.clear();
      if (pausedDuringThisRun) {
        await n._finishPausedDownload(item.id);
      }
    }
  }

  /// Shared guard for every checkpoint in the pipeline: an item that vanished
  /// from the queue or was flagged locally-cancelled aborts immediately; a
  /// pause-pending item re-queues instead. An abort is not a producer termination
  /// acknowledgement. Retain artifacts; neither a provider path nor cancellation
  /// grants permission to delete a library file or an active producer's output.
  Future<bool> _shouldAbort(String stage, {String? retainedArtifact}) async {
    if (!n.ref.mounted) return true;
    final current = n._findItemById(item.id);
    if (current == null || n._isLocallyCancelled(item.id, item: current)) {
      _log.i('Download was cancelled $stage, skipping');
      if (retainedArtifact != null)
        _log.d(
          'Retaining finalization artifact without producer acknowledgement',
        );
      return true;
    }
    if (n._isPausePending(item.id)) {
      pausedDuringThisRun = true;
      if (retainedArtifact != null)
        _log.d(
          'Retaining finalization artifact without producer acknowledgement',
        );
      n._requeueItemForPause(item.id);
      _log.i('Download pause requested $stage, re-queueing');
      return true;
    }
    return false;
  }

  Future<bool> _enrichDeezerTrackIfNeeded() async {
    trackToDownload = await n._metadataResolver.prepareSourceTrack(
      trackToDownload,
    );
    return !await _shouldAbort('during metadata enrichment');
  }

  bool _canDownloadWithConfiguredProvider() {
    if (n._hasActiveDownloadProvider(item.service)) return true;
    if (!settings.useExtensionProviders || !settings.autoFallback) return false;

    final extensions = n.ref.read(extensionProvider).extensions;
    final requested = item.service.trim().toLowerCase();
    if (extensions.any(
      (ext) => ext.id.toLowerCase() == requested && ext.stopProviderFallback,
    )) {
      return false;
    }

    final allowed = settings.downloadFallbackExtensionIds;
    usingUnavailableProviderFallback = extensions.any(
      (ext) =>
          ext.enabled &&
          ext.hasDownloadProvider &&
          ext.status != 'error' &&
          (allowed == null || allowed.contains(ext.id)),
    );
    // Keep the requested service and let Rust enforce the fallback policy.
    return usingUnavailableProviderFallback;
  }

  void _recordUnavailableProvider() {
    n._recordFailedDownload(
      item.id,
      error: 'Download provider is no longer available',
      errorType: DownloadErrorType.providerUnavailable,
      diagnosticErrorType: 'provider_unavailable',
      countInSession: isNetworkDownload,
    );
  }

  String _unavailableProviderQuality(String requestedQuality) {
    final service = item.service.toLowerCase();
    final preferred =
        item.qualityOverride != null && item.qualityOverride != 'DEFAULT'
        ? requestedQuality
        : service == settings.defaultService.toLowerCase()
        ? n.state.audioQuality
        : n._rememberedDownloadQuality(settings, item.service) ?? '';
    final concrete = manifestQualityId(preferred);
    if (concrete.isNotEmpty && !sameManifestQualityId(concrete, 'DEFAULT')) {
      return concrete;
    }

    final provider = n.ref
        .read(extensionProvider)
        .extensions
        .where(
          (ext) => ext.hasDownloadProvider && ext.id.toLowerCase() == service,
        )
        .firstOrNull;
    return provider == null
        ? ''
        : defaultDownloadQualityOption(
                provider.id,
                provider.qualityOptions,
              )?.id ??
              '';
  }

  Future<void> _resolveOutputTarget() async {
    final preferredQuality =
        item.service.toLowerCase() == settings.defaultService.toLowerCase()
        ? n.state.audioQuality
        : n._rememberedDownloadQuality(settings, item.service) ??
              (n._downloadProviderHasQualityOptions(item.service)
                  ? ''
                  : n.state.audioQuality);
    final useSourceDefault =
        item.qualityOverride == null || item.qualityOverride == 'DEFAULT';
    final requestedQuality = useSourceDefault
        ? preferredQuality
        : item.qualityOverride!;
    final resolvedQuality = n._resolveDeclaredDownloadQuality(
      item.service,
      requestedQuality,
      useSourceDefault: useSourceDefault,
      allowProviderFallback:
          n._itemUsesFallback(item) && settings.useExtensionProviders,
      strict: settings.strictDownloadQuality,
    );
    // Only "only this quality" stops before asking the backend: otherwise the
    // relay decides, after every provider and quality class was tried.
    if (settings.strictDownloadQuality &&
        !isNetworkDownload &&
        !usingUnavailableProviderFallback &&
        resolvedQuality == null) {
      throw _DownloadQualityUnavailable();
    }
    quality = usingUnavailableProviderFallback
        ? _unavailableProviderQuality(requestedQuality)
        : resolvedQuality ?? requestedQuality;
    qualityFromSavedPreference =
        useSourceDefault &&
        quality == requestedQuality &&
        n._rememberedDownloadQuality(settings, item.service) ==
            requestedQuality;
    customFolderPath = await n._resolveCustomFolderPath(
      trackToDownload,
      item,
      settings,
      quality,
    );
    if (!n.ref.mounted) return;
    final isSafMode = !isNetworkDownload && n._isSafMode(settings);
    final relativeOutputDir = isSafMode || isNetworkDownload
        ? n._buildRelativeOutputDir(
            trackToDownload,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          )
        : '';
    networkRelativeDir = relativeOutputDir;
    final initialOutputDir = isNetworkDownload
        ? (await NetworkDownloadStaging.instance.workDirectory(item.id)).path
        : isSafMode
        ? relativeOutputDir
        : await n._buildOutputDir(
            trackToDownload,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          );
    if (!n.ref.mounted) return;
    effectiveOutputDir = isSafMode
        ? n._sanitizeSafRelativeDir(initialOutputDir)
        : initialOutputDir;
    effectiveSafMode = isSafMode;

    safOutputExt = n._determineOutputExt(quality, item.service);
    final baseFilenameFormat = n._shouldTreatAsSingleRelease(trackToDownload)
        ? n.state.singleFilenameFormat
        : n.state.filenameFormat;
    effectiveFilenameFormat = n._filenameFormatForItem(
      item,
      baseFilenameFormat,
    );
    qualityVariantCollisionOnly =
        item.preserveQualityVariant &&
        !_explicitQualityFilenameTokenPattern.hasMatch(baseFilenameFormat);
    if (isSafMode) {
      final builtSafFileName = await n._buildSafFileNameForItem(
        item,
        trackToDownload,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
      safFileName = builtSafFileName;
      safBaseName = builtSafFileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    }
    finalSafFileName = safFileName;
  }

  void _resolveExtensionFlags() {
    extensionState = n.ref.read(extensionProvider);
    selectedExtensionDownloadProvider =
        settings.useExtensionProviders &&
        extensionState.extensions.any(
          (e) =>
              e.enabled &&
              e.hasDownloadProvider &&
              e.id.toLowerCase() == item.service.toLowerCase(),
        );
    final trackSource = (trackToDownload.source ?? '').trim().toLowerCase();
    shouldSkipExtensionSongLinkPrelookup =
        trackSource.isNotEmpty &&
        extensionState.extensions.any(
          (e) =>
              e.enabled &&
              e.hasMetadataProvider &&
              e.id.toLowerCase() == trackSource,
        );
    shouldSkipMetadataEnrichment =
        DownloadMetadataResolver.shouldSkipMetadataEnrichment(
          extensionState,
          trackToDownload.source,
          item.service,
        );
    final hasActiveExtensions = extensionState.extensions.any((e) => e.enabled);
    useExtensions = settings.useExtensionProviders && hasActiveExtensions;
  }

  Future<bool> _resolveTrackIdentifiers() async {
    if (shouldSkipMetadataEnrichment) {
      deezerTrackId = DownloadMetadataResolver.knownDeezerTrackId(
        trackToDownload,
      );
      _log.d('Skipping cross-provider metadata enrichment');
      return true;
    }
    deezerTrackId = await n._metadataResolver.resolveDeezerIdFromKnownOrIsrc(
      trackToDownload,
      item.id,
      lookupContext: 'ISRC',
    );
    if (await _shouldAbort('during Deezer ISRC lookup')) {
      return false;
    }

    // For tidal:/qobuz: tracks without ISRC, resolve ISRC from provider
    // API directly (faster than SongLink and avoids rate limits).
    final providerResolved = await n._metadataResolver
        .resolveDeezerIdViaProviderIfNeeded(
          trackToDownload,
          deezerTrackId,
          item.id,
          extensionState: extensionState,
        );
    trackToDownload = providerResolved.track;
    deezerTrackId = providerResolved.deezerTrackId;
    if (await _shouldAbort('during provider ISRC resolution')) {
      return false;
    }

    if (!selectedExtensionDownloadProvider &&
        deezerTrackId == null &&
        !shouldSkipExtensionSongLinkPrelookup &&
        trackToDownload.id.isNotEmpty &&
        !trackToDownload.id.startsWith('deezer:') &&
        !trackToDownload.id.startsWith('extension:') &&
        !trackToDownload.id.startsWith('tidal:') &&
        !trackToDownload.id.startsWith('qobuz:')) {
      final spotifyLookup = await n._metadataResolver
          .resolveSpotifyTrackViaDeezer(trackToDownload);
      trackToDownload = spotifyLookup.track;
      deezerTrackId ??= spotifyLookup.deezerTrackId;

      if (await _shouldAbort('during SongLink availability lookup')) {
        return false;
      }
    } else if (selectedExtensionDownloadProvider && deezerTrackId == null) {
      _log.d(
        'Skipping Flutter SongLink Deezer prelookup for extension provider',
      );
    } else if (shouldSkipExtensionSongLinkPrelookup && deezerTrackId == null) {
      _log.d(
        'Skipping Flutter SongLink Deezer prelookup for extension-sourced track; backend metadata enrichment will resolve identifiers first',
      );
    }
    return true;
  }

  Future<DownloadResult?> _invokeDownload({
    required bool useSaf,
    required String outputDir,
  }) async {
    if (!n.ref.mounted) return null;
    _failureStage = 'preparing_output';
    final outputExt = safOutputExt;
    final shouldUseExtensions = useExtensions;
    final shouldUseFallback = n._itemUsesFallback(item);

    if (shouldUseExtensions) {
      _log.d('Using extension providers for download');
      _log.d(
        item.qualityOverride != null
            ? 'Using download quality override'
            : 'Using configured download quality',
      );
    } else if (shouldUseFallback) {
      _log.d('Using auto-fallback mode');
      _log.d(
        item.qualityOverride != null
            ? 'Using download quality override'
            : 'Using configured download quality',
      );
    }

    if (!useSaf) {
      await n._ensureDirExists(outputDir, label: 'Output folder');
      if (!n.ref.mounted) return null;
      if (!_directoryScopes.containsKey(outputDir)) {
        _directoryScopes[outputDir] =
            await PlatformBridge.acquireDownloadDirectory(outputDir);
      }
    }

    if (!n.ref.mounted) return null;
    _log.d('Prepared output directory');

    final payload = n._buildDownloadRequestPayload(
      track: trackToDownload,
      item: item,
      settings: settings,
      extensionState: extensionState,
      quality: quality,
      qualityFromSavedPreference: qualityFromSavedPreference,
      filenameFormat: effectiveFilenameFormat,
      outputDir: outputDir,
      outputExt: outputExt,
      useSaf: useSaf,
      safFileName: safFileName,
      deezerTrackId: deezerTrackId,
      genre: genre,
      label: label,
      copyright: copyright,
      stageSafForDeferredPublish: useSaf,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );

    _failureStage = 'backend_download';
    final turnCancelled = Completer<void>();
    n._providerTurnWaits[item.id] = turnCancelled;
    var aborted = false;
    try {
      final outcome = await ProviderRequestGate.instance
          .run<Map<String, dynamic>>(
            () async {
              if (await _shouldAbort('before the provider turn')) {
                aborted = true;
                return const <String, dynamic>{};
              }
              return PlatformBridge.downloadByStrategy(
                payload: payload,
                useExtensions: shouldUseExtensions,
                useFallback: shouldUseFallback,
              );
            },
            priority: ProviderRequestPriority.queue,
            cancelled: turnCancelled.future,
            maxTurn: DownloadQueueNotifier.providerTurnLimit,
            onTimeout: () => PlatformBridge.cancelDownload(item.id),
          );
      if (aborted) return null;
      return DownloadResult.fromMap(outcome);
    } on ProviderRequestCancelled {
      await _shouldAbort('while waiting for the provider turn');
      return null;
    } on ProviderTurnTimeout {
      _log.w('Provider turn exceeded its time limit');
      return DownloadResult.fromMap({
        'success': false,
        'error': 'Provider request timed out',
        'error_type': 'timeout',
      });
    } finally {
      if (identical(n._providerTurnWaits[item.id], turnCancelled)) {
        n._providerTurnWaits.remove(item.id);
      }
    }
  }

  void _learnSpecialQuality(DownloadResult outcome) {
    if (!isSpatialQualityId(quality)) return;
    final registry = SpecialQualityAvailability.instance;
    if (outcome.success) {
      registry.recordPlayback(
        track: trackToDownload,
        requestedService: item.service,
        requestedQuality: quality,
        metadata: {
          ...outcome.qualityMetadata,
          if (outcome.audioCodec != null) 'output_codec': outcome.audioCodec!,
        },
      );
      return;
    }
    if (outcome['error_type']?.toString() == 'quality_unavailable') {
      registry.noteAttemptFailed(trackToDownload, item.service, quality);
    }
  }

  Future<bool> _downloadAndMaybeFallback() async {
    final initialResult = await _invokeDownload(
      useSaf: effectiveSafMode,
      outputDir: effectiveOutputDir,
    );

    if (!n.ref.mounted || initialResult == null) return false;
    result = initialResult;
    _learnSpecialQuality(initialResult);

    if (!isNetworkDownload &&
        !result.success &&
        isStorageWriteFailure(
          errorType: result['error_type']?.toString(),
          errorMessage: (result['error'] ?? result['message'])?.toString(),
        )) {
      if (n._isLocallyCancelled(item.id)) {
        _log.i('Download was cancelled before storage fallback, skipping');
        return false;
      }
      if (storageWriteRecoveryFor(useSaf: effectiveSafMode) ==
          StorageWriteRecovery.requestSafAccess) {
        _log.w(
          'SAF write failed; preserving the selected destination for reauthorization',
        );
        result = DownloadResult.fromMap({
          ...result,
          'success': false,
          'error': safPermissionLostErrorMessage,
          'error_type': 'permission',
          'diagnostic_cause': null,
        });
        return true;
      }
      _log.w('Storage write failed, retrying with a writable app folder');
      try {
        final fallbackRoot = await n._activateAppFolderStorageFallback(
          failedOutputDir: effectiveSafMode ? null : effectiveOutputDir,
        );
        if (!n.ref.mounted || fallbackRoot == null) return false;
        final fallbackDir =
            appOutputDir ??
            await n._buildOutputDir(
              trackToDownload,
              settings,
              customFolderPath: customFolderPath,
              playlistName: item.playlistName,
            );
        appOutputDir = fallbackDir;
        final fallbackResult = await _invokeDownload(
          useSaf: false,
          outputDir: fallbackDir,
        );
        if (!n.ref.mounted || fallbackResult == null) return false;
        result = fallbackResult;
        if (fallbackResult.success) {
          effectiveSafMode = false;
          effectiveOutputDir = fallbackDir;
          finalSafFileName = null;
        }
      } catch (_) {
        if (!n.ref.mounted) return false;
        _log.w('App-folder storage fallback failed');
      }
    }
    return true;
  }

  Future<bool> _handleDownloadSuccess() async {
    void stageCompleted(String stage) {
      _log.d('Finalization stage completed: $stage');
    }

    filePath = result.filePath;
    final reportedFileName = result.fileName;
    if (effectiveSafMode &&
        reportedFileName != null &&
        reportedFileName.isNotEmpty) {
      finalSafFileName = reportedFileName;
    }

    wasExisting = result.alreadyExists;
    _log.i(wasExisting ? 'Reused existing download' : 'Download completed');

    final actualBitDepth = result.actualBitDepth;
    final actualSampleRate = result.actualSampleRate;
    actualQuality = _fetchedQualityId(result) ?? quality;

    if (actualBitDepth != null && actualBitDepth > 0) {
      final sampleRateKHz = actualSampleRate != null && actualSampleRate > 0
          ? (actualSampleRate / 1000).toStringAsFixed(
              actualSampleRate % 1000 == 0 ? 0 : 1,
            )
          : '?';
      actualQuality = '$actualBitDepth-bit/${sampleRateKHz}kHz';
      _log.i('Recorded measured audio quality');
    }

    final actualService =
        result.service?.toLowerCase() ?? item.service.toLowerCase();
    resultOutputExt = result.outputExtension(path: filePath);
    final resultAudioFormat = normalizeAudioFormatValue(result.audioCodec);
    final resultIsKnownLossyAudio =
        isLossyAudioFormat(resultAudioFormat) &&
        !isInconclusiveAudioCodec(resultAudioFormat);
    forceContainerConversion =
        result.requiresContainerConversion ||
        (!resultIsKnownLossyAudio &&
            n._shouldRequestContainerConversion(actualService, safOutputExt));
    final preferredOutputExt = n._extensionPreferredOutputExt(actualService);
    shouldPreserveNativeM4a =
        // M4A/MP4 may contain FLAC. A requested FLAC output must reach the
        // codec probe even if the extension did not ask for conversion.
        safOutputExt != '.flac' &&
        !forceContainerConversion &&
        (resultOutputExt == '.m4a' ||
            resultOutputExt == '.mp4' ||
            preferredOutputExt == '.m4a' ||
            preferredOutputExt == '.mp4' ||
            n._extensionPreservesNativeOutputExt(actualService, '.m4a') ||
            n._extensionPreservesNativeOutputExt(actualService, '.mp4'));
    final requestTrack = trackToDownload;
    trackToDownload = buildTrackForMetadataEmbedding(
      trackToDownload,
      result,
      resolvedAlbumArtist,
    );
    if (!await _decryptIfNeeded()) {
      return false;
    }
    stageCompleted('decrypt');
    await _applyFormatHandling(actualService);
    stageCompleted('format and metadata');

    final originalHiResPath = fakeHiResOriginalPath;
    if (originalHiResPath != null &&
        (filePath == null ||
            !await HiResCheckService.replacementPreservesAudio(
              originalHiResPath,
              filePath!,
            ))) {
      throw StateError(
        'Lossless replacement does not preserve the original audio',
      );
    }

    if (await _shouldAbort('during finalization', retainedArtifact: filePath)) {
      return false;
    }

    // At most once per run: the LOSSLESS replacement is not checked again.
    if (!fakeHiResChecked) {
      fakeHiResChecked = true;
      switch (await _replaceFakeHiResIfNeeded(requestTrack)) {
        case _FakeHiResOutcome.completed:
          return true;
        case _FakeHiResOutcome.aborted:
          return false;
        case _FakeHiResOutcome.kept:
          break;
      }
    }

    final deferredSafPublish =
        effectiveSafMode &&
        result.deferredSafPublish &&
        filePath != null &&
        !isContentUri(filePath!);
    if (!deferredSafPublish) {
      await _recoverSafUriIfNeeded();
    }
    stageCompleted('resolve storage');

    final hookInput = filePath;
    if (hookInput != null) {
      final supportDirectory = deferredSafPublish
          ? await getApplicationSupportDirectory()
          : null;
      if (!n.ref.mounted) return false;

      Future<String?> runHook() => n.ref.mounted
          ? n._runPostProcessingHooks(hookInput, trackToDownload, item.id)
          : Future<String?>.value(null);
      final postProcessedPath = deferredSafPublish
          ? await withTransferredSafHookGrant<String?>(
              marker: result['saf_owned_attempt_dir']?.toString() ?? '',
              applicationSupportDirectory: supportDirectory!.path,
              sourcePath: hookInput,
              acquire: PlatformBridge.acquireDownloadDirectory,
              release: PlatformBridge.releaseDownloadDirectory,
              run: runHook,
            )
          : await runHook();
      if (!n.ref.mounted) return false;
      if (postProcessedPath != null && postProcessedPath.isNotEmpty) {
        if (deferredSafPublish && postProcessedPath != hookInput) {
          if (!await acceptTransferredSafHookOutput(
            marker: result['saf_owned_attempt_dir']?.toString() ?? '',
            applicationSupportDirectory: supportDirectory!.path,
            sourcePath: postProcessedPath,
            shouldAbort: () {
              if (!n.ref.mounted) return true;
              final current = n._findItemById(item.id);
              return current == null ||
                  n._isLocallyCancelled(item.id, item: current) ||
                  n._isPausePending(item.id);
            },
          )) {
            if (await _shouldAbort(
              'during post-processing',
              retainedArtifact: hookInput,
            ))
              return false;
            throw StateError(
              'Post-processing output is outside the owned SAF attempt',
            );
          }
          final output = File(postProcessedPath);
          if (!await output.exists() || await output.length() <= 0) {
            throw StateError('Post-processing output missing or empty');
          }
          // Retain the old input until producer lifetime is acknowledged. A
          // post-processing response alone does not authorize deleting it.
        }
        filePath = postProcessedPath;
        result.filePath = postProcessedPath;
      }
      if (await _shouldAbort(
        'during post-processing',
        retainedArtifact: wasExisting ? null : filePath,
      )) {
        return false;
      }
    }

    // Verify extension output keeps the original PCM.
    if (originalHiResPath != null &&
        (filePath == null ||
            !await HiResCheckService.replacementPreservesAudio(
              originalHiResPath,
              filePath!,
            ))) {
      throw StateError(
        'Finalized replacement no longer preserves the original audio',
      );
    }

    stageCompleted('extension hooks');

    final variantInput = filePath;
    if (variantInput != null && item.preserveQualityVariant) {
      final variantOutcome = await n._finalizeQualityVariantFilename(
        item: item,
        result: result,
        filePath: variantInput,
        storageMode: effectiveSafMode ? 'saf' : 'app',
        downloadTreeUri: settings.downloadTreeUri,
        safRelativeDir: effectiveOutputDir,
        fileName: finalSafFileName ?? safFileName,
        collisionOnly: qualityVariantCollisionOnly,
      );
      filePath = variantOutcome.filePath;
      if (variantOutcome.fileName != null) {
        finalSafFileName = variantOutcome.fileName;
      }
      if (variantOutcome.metadata != null) {
        probedFinalMetadata = variantOutcome.metadata;
      }
    }
    stageCompleted('quality filename');

    if (normalizeOptionalString(filePath) == null) {
      throw StateError(
        'Download backend reported success without a final file path',
      );
    }

    if (await _shouldAbort(
      'before publishing finalized audio',
      retainedArtifact: wasExisting ? null : filePath,
    )) {
      return false;
    }

    if (deferredSafPublish && !await _publishDeferredSafOutputOnce()) {
      throw StateError('Failed to publish deferred SAF output');
    }
    stageCompleted('publish audio');

    final lrcTarget = filePath;
    if (lrcTarget != null &&
        (!wasExisting || (effectiveSafMode && isContentUri(lrcTarget)))) {
      externalLrcWritten = await n._saveExternalLrc(
        result: result,
        settings: settings,
        extensionState: extensionState,
        track: trackToDownload,
        service: item.service,
        filePath: lrcTarget,
        storageMode: effectiveSafMode ? 'saf' : 'app',
        downloadTreeUri: settings.downloadTreeUri,
        safRelativeDir: effectiveOutputDir,
        resolveBaseName: () async {
          final currentFinalName = finalSafFileName;
          return currentFinalName != null
              ? currentFinalName.replaceFirst(RegExp(r'\.[^.]+$'), '')
              : safBaseName ??
                    await PlatformBridge.sanitizeFilename(
                      '${trackToDownload.artistName} - ${trackToDownload.name}',
                    );
        },
        onFetchError: (e) => _log.w('Failed to fetch lyrics for external LRC'),
      );
    }

    final rgPath = filePath;
    stageCompleted('external lyrics');
    if (wasExisting &&
        rgPath != null &&
        !isNetworkDownload &&
        settings.embedReplayGain) {
      // A retry after history persistence failed may reuse the finished file.
      // retryItem purges the old scan, and normal metadata embedding is skipped
      // for existing files, so recover the measurement for this attempt.
      try {
        final scan = await ReplayGainService.scanAndApplyToFile(rgPath);
        if (scan != null) {
          n._storeTrackReplayGainForAlbum(trackToDownload, rgPath, scan);
        }
      } catch (_) {
        _log.w('Could not recover ReplayGain for existing download');
      }
    }
    // Album ReplayGain: update the accumulator path to the final file
    // location.  For SAF downloads the metadata was embedded on a temp
    // copy, so the stored path still points there.  Replace it with the
    // actual output path (SAF content URI or local path) so the later
    // album-gain writer targets the correct file.
    if (rgPath != null && !isNetworkDownload) {
      n._updateAlbumRgFilePath(trackToDownload, rgPath);
    }
    await _persistCompletionAndNotify(onStageCompleted: stageCompleted);
    stageCompleted('completion cleanup');
    return true;
  }

  Future<bool> _decryptIfNeeded() async {
    final path = filePath;
    final descriptor = result.decryption;
    if (wasExisting || descriptor == null || path == null) {
      return true;
    }
    _log.i('Decrypting encrypted stream');
    n.updateItemStatus(item.id, DownloadStatus.finalizing, progress: 0.9);

    final isSafSource = effectiveSafMode && isContentUri(path);
    final decryptOutcome = await n._fileFinalizer.decrypt(
      result: result,
      filePath: path,
      useSaf: effectiveSafMode,
      treeUri: settings.downloadTreeUri,
      relativeDir: effectiveOutputDir,
      baseName: safBaseName ?? 'track',
      extensionFallback: '.flac',
      repairContainer: true,
    );
    if (decryptOutcome.path == null) {
      final errorMsg = switch (decryptOutcome.failure) {
        DownloadDecryptionFailure.safAccess =>
          'Failed to access encrypted SAF file',
        DownloadDecryptionFailure.safWrite =>
          'Failed to write decrypted file to storage',
        _ => 'Failed to decrypt encrypted stream',
      };
      n._recordFailedDownload(
        item.id,
        error: errorMsg,
        errorType: DownloadErrorType.decryptFailed,
        diagnosticStage: _failureStage,
        countInSession: false,
      );
      return false;
    }
    filePath = decryptOutcome.path;
    if (decryptOutcome.fileName != null) {
      finalSafFileName = decryptOutcome.fileName;
    }
    _log.i(
      isSafSource ? 'SAF decryption completed' : 'Local decryption completed',
    );
    return true;
  }

  Future<void> _applyFormatHandling(String actualService) async {
    final path = filePath;
    if (path == null) return;
    final isContentUriPath = isContentUri(path);
    final mimeType = isContentUriPath ? await n._getSafMimeType(path) : null;
    final isM4aFile =
        (path.endsWith('.m4a') ||
        path.endsWith('.mp4') ||
        resultOutputExt == '.m4a' ||
        resultOutputExt == '.mp4' ||
        (mimeType != null && mimeType.contains('mp4')));
    final isFlacFile =
        (path.endsWith('.flac') ||
        resultOutputExt == '.flac' ||
        (mimeType != null && mimeType.contains('flac')));
    final shouldForceDashSafM4aHandling =
        !wasExisting &&
        isContentUriPath &&
        effectiveSafMode &&
        n._downloadProviderReplacesLegacyProvider(actualService, 'tidal') &&
        path.endsWith('.flac') &&
        (mimeType == null || mimeType.contains('flac'));

    if (shouldForceDashSafM4aHandling) {
      _log.w(
        'SAF file is labeled FLAC but backend returned an M4A stream; converting it back to FLAC.',
      );
    }

    if (isM4aFile || shouldForceDashSafM4aHandling) {
      if (isContentUriPath && effectiveSafMode) {
        if (shouldPreserveNativeM4a) {
          await _preserveSafNativeM4a(path);
        } else {
          await _convertSafM4aToFlac(path);
        }
      } else {
        if (shouldPreserveNativeM4a) {
          await _preserveLocalNativeM4a(path);
        } else {
          await _convertLocalM4aToFlac(path);
        }
      }
    } else if (metadataEmbeddingEnabled &&
        isContentUriPath &&
        effectiveSafMode &&
        !isM4aFile &&
        !wasExisting) {
      await _embedSafNonM4a(path);
    } else if (metadataEmbeddingEnabled &&
        !isContentUriPath &&
        isFlacFile &&
        !wasExisting) {
      await _embedLocalFlac(path);
    } else if (metadataEmbeddingEnabled &&
        !isContentUriPath &&
        !isFlacFile &&
        !isM4aFile &&
        !wasExisting) {
      final isOpus =
          path.toLowerCase().endsWith('.opus') ||
          path.toLowerCase().endsWith('.ogg') ||
          resultOutputExt == '.opus' ||
          resultOutputExt == '.ogg';
      final isMp3 =
          path.toLowerCase().endsWith('.mp3') || resultOutputExt == '.mp3';
      if (isOpus || isMp3) {
        await _embedFinalMetadata(
          path,
          format: isOpus ? 'opus' : 'mp3',
          writeExternalLrc: false,
        );
      }
    }
  }

  void _markFinalOutputAsFlac() {
    final path = filePath;
    String? name;
    if (path != null) {
      name = finalizedAudioFileName(
        fileName: effectiveSafMode
            ? (finalSafFileName ?? safFileName ?? result.fileName ?? 'track')
            : File(path).uri.pathSegments.last,
        localPath: path,
        fallbackExtension: '.flac',
      );
      if (effectiveSafMode) finalSafFileName = name;
    }
    result.markFlacContainer(path: path, name: name);
    resultOutputExt = '.flac';
  }

  Future<bool> _publishDeferredSafOutputOnce() async {
    final localPath = filePath;
    if (localPath == null || isContentUri(localPath)) return true;
    final localFile = File(localPath);
    if (!await localFile.exists()) return false;
    final localSize = await localFile.length();
    if (localSize <= 0) return false;
    _log.d('Publishing finalized SAF output');

    var finalName =
        normalizeOptionalString(finalSafFileName) ??
        normalizeOptionalString(result['file_name']?.toString()) ??
        normalizeOptionalString(safFileName) ??
        (localFile.uri.pathSegments.isEmpty
            ? 'track$safOutputExt'
            : localFile.uri.pathSegments.last);
    finalName = finalizedAudioFileName(
      fileName: finalName,
      localPath: localPath,
      fallbackExtension:
          result.outputExtension(path: localPath) ?? safOutputExt,
    );
    final localExt = finalName.substring(finalName.lastIndexOf('.'));

    final measured = probedFinalMetadata;
    final qualityLabel = buildQualityVariantFilenameLabel(
      detectedFormat:
          normalizeAudioFormatValue(
            measured?['audio_codec']?.toString() ??
                measured?['format']?.toString(),
          ) ??
          normalizeAudioFormatValue(
            result['audio_codec']?.toString() ?? result['format']?.toString(),
          ),
      bitDepth: readPositiveInt(
        measured?['bit_depth'] ?? result['actual_bit_depth'],
      ),
      sampleRate: readPositiveInt(
        measured?['sample_rate'] ?? result['actual_sample_rate'],
      ),
      bitrateKbps: readPositiveBitrateKbps(
        measured?['bitrate'] ??
            measured?['bit_rate'] ??
            result['bitrate'] ??
            result['actual_bitrate'],
      ),
      measuredQuality: actualQuality,
    );

    String? publishedUri;
    String? publishedName;
    var alreadyExists = false;
    if (item.preserveQualityVariant && qualityVariantCollisionOnly) {
      final logicalName = finalizedAudioFileName(
        fileName: safFileName ?? finalName,
        localPath: localPath,
        fallbackExtension: localExt,
      );
      final stagingLabel = qualityVariantStagingLabel(item.id);
      final cleanName = removeQualityVariantStagingLabel(
        fileName: logicalName,
        stagingLabel: stagingLabel,
      );
      final variantName = qualityLabel == null
          ? finalName
          : applyQualityVariantFilenameLabel(
              fileName: logicalName,
              stagingLabel: stagingLabel,
              qualityLabel: qualityLabel,
            );
      final published = await n._writeTempToSafCollisionAware(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        cleanFileName: cleanName,
        variantFileName: variantName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
        preservedSuffix: qualityLabel ?? '',
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
    } else if (item.preserveQualityVariant) {
      final published = await n._writeTempToSafUnique(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        fileName: finalName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
        preservedSuffix: qualityLabel ?? '',
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
    } else {
      final published = await n._writeTempToSafIfAbsent(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        fileName: finalName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
      alreadyExists = published?.alreadyExists == true;
    }
    if (publishedUri == null || publishedName == null) return false;

    // Only successful publication reaches this point. Cancellation/failure must
    // retain staging until the producer has really stopped.
    final ownedAttempt = result['saf_owned_attempt_dir']?.toString() ?? '';
    if (ownedAttempt.isNotEmpty && Platform.isAndroid) {
      try {
        final support = await getApplicationSupportDirectory();
        await deleteTransferredSafAttemptOutput(
          marker: ownedAttempt,
          applicationSupportDirectory: support.path,
          sourcePath: localPath,
        );
        final cleaned = await cleanupTransferredSafAttemptDirectory(
          marker: ownedAttempt,
          applicationSupportDirectory: support.path,
        );
        if (cleaned) {
          result.remove('saf_owned_attempt_dir');
        } else {
          _log.d('Retaining nonempty or unavailable SAF attempt directory');
        }
      } catch (_) {
        _log.d('Retaining SAF attempt directory after cleanup failure');
      }
    }
    filePath = publishedUri;
    finalSafFileName = publishedName;
    wasExisting = alreadyExists;
    result['file_path'] = publishedUri;
    result['file_name'] = publishedName;
    result['saf_deferred_published'] = true;
    if (alreadyExists) {
      result['already_exists'] = true;
      result['message'] = 'File already exists';
    }
    _log.i('Published finalized SAF output once');
    return true;
  }

  Future<void> _preserveSafNativeM4a(String currentFilePath) async {
    // Preserve explicitly requested M4A/MP4 output, including spatial audio.
    _log.d('M4A/MP4 file detected (SAF), preserving native container...');
    final preserveExt =
        currentFilePath.toLowerCase().endsWith('.mp4') ||
            resultOutputExt == '.mp4'
        ? '.mp4'
        : '.m4a';
    final newFileName = '${safBaseName ?? 'track'}$preserveExt';
    var opStarted = false;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, _) async {
          opStarted = true;
          if (metadataEmbeddingEnabled) {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.99,
            );
            await _embedFinalMetadata(
              tempPath,
              format: 'm4a',
              writeExternalLrc: false,
            );
          }
          return (tempPath, newFileName);
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = newFileName;
      } else if (opStarted) {
        _log.w('Failed to write M4A to SAF, keeping original');
      }
    } catch (_) {
      _log.w('SAF native M4A handling failed');
    }
  }

  Future<void> _convertSafM4aToFlac(String currentFilePath) async {
    _log.d('M4A file detected (SAF), converting to FLAC...');
    String? branch;
    String? producedFileName;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, addCleanup) async {
          final length = await File(tempPath).length();
          if (length < 1024) {
            _log.w('Temp M4A is too small (<1KB), skipping conversion');
            branch = 'skip';
            return null;
          }
          final codec = await FFmpegProbe.audioCodec(tempPath);
          final isAlreadyNativeFlac =
              codec == 'flac' && await FFmpegProbe.isNativeFlacFile(tempPath);
          final shouldAttemptConversion = codec?.trim().toLowerCase() == 'flac';
          if (!shouldAttemptConversion) {
            _log.d('Preserving native container without FLAC conversion');
            branch = 'preserve';
            final preserveExt = resultOutputExt == '.mp4' ? '.mp4' : '.m4a';
            final newFileName = '${safBaseName ?? 'track'}$preserveExt';
            producedFileName = newFileName;
            if (metadataEmbeddingEnabled) {
              await _embedFinalMetadata(
                tempPath,
                format: 'm4a',
                writeExternalLrc: false,
              );
            }
            return (tempPath, newFileName);
          } else if (isAlreadyNativeFlac) {
            _log.d(
              'Native FLAC payload detected in SAF temp file; '
              'publishing as FLAC and embedding metadata.',
            );
            branch = 'nativeFlac';
            await _embedFinalMetadata(
              tempPath,
              format: 'flac',
              writeExternalLrc: false,
            );

            final newFileName = '${safBaseName ?? 'track'}.flac';
            producedFileName = newFileName;
            return (tempPath, newFileName);
          } else {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.95,
            );
            final flacPath = await FFmpegConversion.convertM4aToFlac(
              tempPath,
              sourceCodec: codec,
              preserveAudio: true,
            );
            if (flacPath == null) {
              _log.w('FFmpeg conversion returned null, keeping M4A file');
              branch = 'convertFailed';
              return null;
            }
            addCleanup(flacPath);
            _log.d('Converted temporary output to FLAC');
            _log.d('Embedding metadata and cover to converted FLAC...');
            await _embedFinalMetadata(
              flacPath,
              format: 'flac',
              writeExternalLrc: false,
            );

            final newFileName = '${safBaseName ?? 'track'}.flac';
            branch = 'convert';
            producedFileName = newFileName;
            return (flacPath, newFileName);
          }
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = producedFileName;
        if (branch == 'nativeFlac' || branch == 'convert') {
          _markFinalOutputAsFlac();
        }
      } else if (branch == 'nativeFlac') {
        _log.w('Failed to write native FLAC to SAF');
      } else if (branch == 'convert') {
        _log.w('Failed to write FLAC to SAF, keeping M4A');
      }
    } catch (_) {
      _log.w('SAF M4A to FLAC conversion failed');
    }
  }

  Future<void> _preserveLocalNativeM4a(String currentFilePath) async {
    _log.d('M4A/MP4 file detected, preserving native container...');

    try {
      var targetPath = currentFilePath;
      final file = File(targetPath);
      if (!await file.exists()) {
        _log.w('Downloaded file is unavailable during container handling');
      } else {
        if (!(targetPath.toLowerCase().endsWith('.m4a') ||
            targetPath.toLowerCase().endsWith('.mp4'))) {
          final extension = resultOutputExt == '.mp4' ? '.mp4' : '.m4a';
          final renamedPath = targetPath.replaceAll(
            RegExp(r'\.[^.]+$'),
            extension,
          );
          var finalRenamedPath = renamedPath == targetPath
              ? '$targetPath$extension'
              : renamedPath;
          final stem = finalRenamedPath.substring(
            0,
            finalRenamedPath.length - extension.length,
          );
          var suffix = 2;
          while (await File(finalRenamedPath).exists()) {
            finalRenamedPath = '$stem (${suffix++})$extension';
          }
          await file.rename(finalRenamedPath);
          targetPath = finalRenamedPath;
        }
        filePath = targetPath;

        if (metadataEmbeddingEnabled) {
          n.updateItemStatus(
            item.id,
            DownloadStatus.finalizing,
            progress: 0.99,
          );
          await _embedFinalMetadata(targetPath, format: 'm4a');
        }
      }
    } catch (_) {
      _log.w('Native M4A handling failed');
    }
  }

  Future<void> _convertLocalM4aToFlac(String currentFilePath) async {
    _log.d('M4A file detected, attempting conversion to FLAC...');

    try {
      final file = File(currentFilePath);
      if (!await file.exists()) {
        _log.w('Downloaded file is unavailable during container handling');
      } else {
        final length = await file.length();
        _log.d('Checked file size before conversion');

        if (length < 1024) {
          _log.w(
            'File is too small (<1KB), skipping conversion. Download might be corrupt.',
          );
        } else {
          final codec = await FFmpegProbe.audioCodec(currentFilePath);
          final isAlreadyNativeFlac =
              codec == 'flac' &&
              await FFmpegProbe.isNativeFlacFile(currentFilePath);
          final shouldAttemptConversion = codec?.trim().toLowerCase() == 'flac';
          if (!shouldAttemptConversion) {
            _log.d('Preserving native container without FLAC conversion');
            await _preserveLocalNativeM4a(currentFilePath);
          } else if (isAlreadyNativeFlac) {
            _log.d(
              'Native FLAC payload detected; ensuring .flac '
              'extension and embedding metadata.',
            );
            final flacPath = await FFmpegConversion.ensureNativeFlacExtension(
              currentFilePath,
            );
            filePath = flacPath;

            await _embedFinalMetadata(flacPath, format: 'flac');
            _markFinalOutputAsFlac();
          } else {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.95,
            );
            final flacPath = await FFmpegConversion.convertM4aToFlac(
              currentFilePath,
              sourceCodec: codec,
              preserveAudio: true,
            );

            if (flacPath != null) {
              filePath = flacPath;
              _markFinalOutputAsFlac();
              _log.d('Converted output to FLAC');

              _log.d('Embedding metadata and cover to converted FLAC...');
              await _embedFinalMetadata(flacPath, format: 'flac');
            } else {
              _log.w('FFmpeg conversion returned null, keeping M4A file');
            }
          }
        }
      }
    } catch (_) {
      _log.w('FFmpeg conversion failed; keeping M4A file');
    }
  }

  Future<void> _embedSafNonM4a(String currentFilePath) async {
    final isOpusFile =
        currentFilePath.endsWith('.opus') ||
        currentFilePath.endsWith('.ogg') ||
        resultOutputExt == '.opus' ||
        resultOutputExt == '.ogg';
    final isMp3File =
        currentFilePath.endsWith('.mp3') || resultOutputExt == '.mp3';
    final (ext, formatName) = isOpusFile
        ? (resultOutputExt == '.ogg' ? '.ogg' : '.opus', 'Opus')
        : isMp3File
        ? ('.mp3', 'MP3')
        : ('.flac', 'FLAC');
    // MP3 takes precedence for the embed format when both checks match.
    final embedFormat = isMp3File
        ? 'mp3'
        : isOpusFile
        ? 'opus'
        : 'flac';
    _log.d(
      'SAF $formatName detected, embedding metadata and cover via temp file...',
    );
    final newFileName = '${safBaseName ?? 'track'}$ext';
    var opStarted = false;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, _) async {
          opStarted = true;
          n.updateItemStatus(
            item.id,
            DownloadStatus.finalizing,
            progress: 0.99,
          );

          // writeExternalLrc: false — tempPath lives in the cache dir,
          // so a sidecar .lrc written next to it would be orphaned;
          // the SAF .lrc is written by _saveExternalLrc after publish,
          // reusing the LRC fetched here via result['lyrics_lrc'].
          final fetchedLrc = await _embedFinalMetadata(
            tempPath,
            format: embedFormat,
            writeExternalLrc: false,
          );
          final existingLrc = result['lyrics_lrc'] as String?;
          if ((existingLrc == null || existingLrc.isEmpty) &&
              fetchedLrc != null &&
              fetchedLrc.isNotEmpty) {
            result['lyrics_lrc'] = fetchedLrc;
          }

          // Probe quality from the local temp now: the same probe on
          // the published content:// URI would copy the whole file
          // out of SAF again just to read a few header bytes.
          try {
            probedFinalMetadata = await PlatformBridge.readFileMetadata(
              tempPath,
            );
          } catch (_) {}

          return (tempPath, newFileName);
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = newFileName;
        _log.d('SAF $formatName metadata embedding completed');
      } else if (opStarted) {
        _log.w('Failed to write metadata-updated $formatName back to SAF');
      }
    } catch (e) {
      _log.w('SAF $formatName metadata embedding failed');
    }
  }

  Future<void> _embedLocalFlac(String currentFilePath) async {
    _log.d('Local FLAC detected, embedding metadata and cover...');
    try {
      n.updateItemStatus(item.id, DownloadStatus.finalizing, progress: 0.99);

      await _embedFinalMetadata(
        currentFilePath,
        format: 'flac',
        writeExternalLrc: false,
      );
      _log.d('Local FLAC metadata embedding completed');
    } catch (_) {
      _log.w('Local FLAC metadata embedding failed');
    }
  }

  /// Final metadata embed shared by every publish branch. Backend-provided
  /// genre/label/copyright win over the Deezer extended-metadata lookup.
  Future<String?> _embedFinalMetadata(
    String path, {
    required String format,
    bool writeExternalLrc = false,
  }) async {
    final track = buildTrackForMetadataEmbedding(
      trackToDownload,
      result,
      resolvedAlbumArtist,
    );
    final lrcContent = await n._embedMetadataToFile(
      path,
      track,
      format: format,
      genre: (result['genre'] as String?) ?? genre,
      label: (result['label'] as String?) ?? label,
      copyright: result['copyright'] as String?,
      comment: result['comment'] as String?,
      lyricsLrc: result['lyrics_lrc'] as String?,
      downloadService: item.service,
      writeExternalLrc: writeExternalLrc,
    );
    if (lrcContent != null && lrcContent.isNotEmpty) {
      result['lyrics_lrc'] = lrcContent;
    }
    return lrcContent;
  }

  Future<void> _recoverSafUriIfNeeded() async {
    final path = filePath;
    if (!effectiveSafMode ||
        path == null ||
        path.isEmpty ||
        isContentUri(path) ||
        settings.downloadTreeUri.isEmpty) {
      return;
    }
    final fallbackName = (finalSafFileName ?? safFileName ?? '').trim();
    if (fallbackName.isNotEmpty) {
      try {
        final resolved = await PlatformBridge.resolveSafFile(
          treeUri: settings.downloadTreeUri,
          relativeDir: effectiveOutputDir,
          fileName: fallbackName,
        );
        final resolvedUri = (resolved['uri'] as String? ?? '').trim();
        final resolvedRelativeDir = (resolved['relative_dir'] as String? ?? '')
            .trim();
        if (resolvedUri.isNotEmpty && isContentUri(resolvedUri)) {
          _log.d('Recovered SAF URI from transient path');
          filePath = resolvedUri;
          finalSafFileName = fallbackName;
          if (resolvedRelativeDir.isNotEmpty) {
            effectiveOutputDir = resolvedRelativeDir;
          }
        } else {
          _log.w('Failed to recover SAF URI');
        }
      } catch (_) {
        _log.w('SAF URI recovery failed');
      }
    } else {
      _log.w('SAF download returned a non-URI path without filename metadata');
    }
  }

  Future<void> _persistCompletionAndNotify({
    void Function(String)? onStageCompleted,
  }) async {
    if (!n.ref.mounted) return;
    final path = filePath;
    final historyNotifier = n.ref.read(downloadHistoryProvider.notifier);
    final existingInHistory = path == null
        ? null
        : await historyNotifier.getByFilePathAsync(path);

    if (!n.ref.mounted) return;
    if (wasExisting && existingInHistory != null) {
      _log.i(
        'Track file already exists in library; refreshing its history metadata',
      );
    }

    if (path != null) {
      var historyFilePath = path;
      final audio = await resolveDownloadCompletionAudio(
        result: result,
        filePath: path,
        fileName: finalSafFileName,
        quality: actualQuality,
        metadata: probedFinalMetadata,
        readMetadata: PlatformBridge.readFileMetadata,
        debug: _log.d,
      );
      actualQuality = audio.quality;
      probedFinalMetadata = audio.metadata;
      final backendGenre = result['genre'] as String?;
      final backendLabel = result['label'] as String?;
      final backendCopyright = result['copyright'] as String?;
      final effectiveGenre =
          normalizeOptionalString(backendGenre) ??
          normalizeOptionalString(genre) ??
          normalizeOptionalString(existingInHistory?.genre);
      final effectiveLabel =
          normalizeOptionalString(backendLabel) ??
          normalizeOptionalString(label) ??
          normalizeOptionalString(existingInHistory?.label);
      final effectiveCopyright =
          normalizeOptionalString(backendCopyright) ??
          normalizeOptionalString(copyright) ??
          normalizeOptionalString(existingInHistory?.copyright);

      final lyricsAvailability = await n._resolveFinalLyricsAvailability(
        filePath: historyFilePath,
        probedMetadata: probedFinalMetadata,
        externalLrcWritten: externalLrcWritten,
      );
      if (!n.ref.mounted) return;
      onStageCompleted?.call('final metadata and lyrics probe');

      if (isNetworkDownload) {
        final staging = NetworkDownloadStaging.instance;
        await staging.prepareCompletion(
          id: item.id,
          localPath: path,
          folder: item.networkDownloadFolder,
          relativeDir: networkRelativeDir,
          quality: actualQuality,
          track: trackToDownload.toJson(),
          externalLrcWritten: externalLrcWritten,
          result: result,
        );
        if (!n.ref.mounted) return;
        void checkpoint() {
          if (!n.ref.mounted ||
              n._findItemById(item.id) == null ||
              n._isLocallyCancelled(item.id) ||
              n._isPausePending(item.id)) {
            throw StateError('Network upload interrupted');
          }
        }

        n.updateItemStatus(
          item.id,
          DownloadStatus.finalizing,
          progress: 0.99,
          preparationStage: 'network_upload',
        );
        var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
        historyFilePath = await staging.publish(
          item.id,
          checkpoint: checkpoint,
          progress: (sent, total) {
            if (!n.ref.mounted) return;
            final now = DateTime.now();
            if (sent != total &&
                now.difference(lastProgress).inMilliseconds < 250) {
              return;
            }
            lastProgress = now;
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.99,
              preparationStage: 'network_upload',
              bytesReceived: sent,
              bytesTotal: total,
            );
          },
        );
        onStageCompleted?.call('network upload');
      }

      if (!n.ref.mounted) return;
      await n._saveDownloadedMotionArtwork(
        n.ref,
        item,
        trackToDownload,
        result,
      );
      if (!n.ref.mounted) return;
      onStageCompleted?.call('optional motion artwork');
      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          await DownloadFileInventory.record(item.track, historyFilePath);
          // History still owns Riverpod state. If disposal occurs here,
          // keep the durable inventory entry and leave the queue unpublished.
          if (!n.ref.mounted || !settings.saveDownloadHistory) return;
          await n.ref
              .read(downloadHistoryProvider.notifier)
              .addToHistory(
                n._historyItemFromResult(
                  item: item,
                  trackToDownload: trackToDownload,
                  result: result,
                  filePath: historyFilePath,
                  quality: actualQuality,
                  useSaf: effectiveSafMode,
                  downloadTreeUri: settings.downloadTreeUri,
                  safRelativeDir: effectiveOutputDir,
                  safFileName: finalSafFileName ?? safFileName,
                  bitDepth: audio.bitDepth,
                  sampleRate: audio.sampleRate,
                  bitrate: audio.bitrate,
                  format: audio.format,
                  genre: effectiveGenre,
                  label: effectiveLabel,
                  copyright: effectiveCopyright,
                  hasLyrics: lyricsAvailability.hasLyrics,
                  lyricsMetadataScanVersion: lyricsAvailability.scanVersion,
                  hasReplayGain: lyricsAvailability.hasReplayGain,
                  replayGainMetadataScanVersion:
                      lyricsAvailability.replayGainScanVersion,
                ),
                preserveTrackVariant: item.preserveQualityVariant,
                origin: n._resolvedOrigin(item),
              );
        },
        publish: () {
          if (!n.ref.mounted) return;
          n._completedInSession++;
          n.updateItemStatus(
            item.id,
            DownloadStatus.completed,
            progress: 1.0,
            filePath: historyFilePath,
          );
        },
      );
      if (!n.ref.mounted) return;
      onStageCompleted?.call('durable history and completed state');
      // Only durable completions can unblock an album. Checking while this
      // item is still finalizing makes the final track block its own album.
      if (!isNetworkDownload) {
        await n._checkAndWriteAlbumReplayGain(trackToDownload);
      }
      if (!n.ref.mounted) return;
      onStageCompleted?.call('album ReplayGain');
      try {
        await n._notificationService.showDownloadComplete(
          trackName: item.track.name,
          artistName: item.track.artistName,
          completedCount: n._completedInSession,
          totalCount: n._totalQueuedAtStart,
          alreadyInLibrary: wasExisting,
        );
      } catch (e) {
        // Audio and history are already committed. A notification failure
        // must not roll back a valid replacement or its persisted history.
        _log.w('Download completed but notification failed');
      }
      onStageCompleted?.call('completion notification');
      if (isNetworkDownload) {
        n._purgeAlbumRgEntry(trackToDownload);
        try {
          await NetworkDownloadStaging.instance.discard(item.id);
        } catch (_) {
          _log.w('Could not clean uploaded network staging');
        }
      }
      if (n.ref.mounted) n._removeCompletedItem(item.id);
    }
  }

  Future<bool> _handleBackendFailure() async {
    if (await _shouldAbort('after backend failure')) {
      return false;
    }

    final failure = result.failure!;
    final errorMsg = failure.retryMessage;
    ProviderCooldown.instance.noteAttempts(result['provider_attempts']);
    if (failure.cancelled) {
      if (n._isPausePending(item.id)) {
        pausedDuringThisRun = true;
        n._requeueItemForPause(item.id);
        _log.i('Download was paused by backend cancellation, re-queueing');
      } else {
        _log.i('Download was cancelled by backend, skipping error handling');
        n.updateItemStatus(item.id, DownloadStatus.skipped);
      }
      return false;
    }

    final errorType = n._classifyBackendDownloadFailure(
      failure.backendType,
      failure.message,
    );

    if (errorType == DownloadErrorType.verificationRequired) {
      await n._handleVerificationRequiredDownload(
        item,
        errorMsg,
        failure.service,
      );
      return false;
    }
    if (errorType == DownloadErrorType.rateLimit &&
        await n._handleRateLimitedDownload(
          item,
          errorMsg,
          failure.service ?? item.service,
        )) {
      return false;
    }

    if (!n.ref.mounted) return false;
    n._recordFailedDownload(
      item.id,
      error: errorMsg,
      errorType: errorType,
      diagnosticStage: 'backend_download',
      diagnosticErrorType: failure.backendType,
      diagnosticCause: result['diagnostic_cause'],
      // Provider reported for the retained failure; not the full fallback history.
      diagnosticProvider: result['service'],
      diagnosticProviderAttempts: result['provider_attempts'],
    );

    try {
      await PlatformBridge.cleanupConnections();
    } catch (_) {
      _log.w('Post-failure connection cleanup failed');
    }
    return true;
  }

  Future<void> _handleRunException(Object e) async {
    if (await _shouldAbort('after exception')) {
      return;
    }

    if (e is _DownloadQualityUnavailable) {
      n._recordFailedDownload(
        item.id,
        error: e.toString(),
        errorType: DownloadErrorType.qualityUnavailable,
        diagnosticStage: _failureStage,
      );
      return;
    }

    if (isNetworkDownload) {
      n._recordFailedDownload(
        item.id,
        error: 'Network download failed. Retry keeps prepared audio: $e',
        errorType: DownloadErrorType.networkTransferFailed,
        diagnosticStage: _failureStage,
      );
      return;
    }

    String errorMsg = e.toString();
    DownloadErrorType errorType = DownloadErrorType.unknown;

    if (isStorageWriteFailure(errorMessage: errorMsg) &&
        storageWriteRecoveryFor(useSaf: n._isSafMode(settings)) ==
            StorageWriteRecovery.requestSafAccess) {
      errorMsg = safPermissionLostErrorMessage;
      errorType = DownloadErrorType.permission;
    } else if (isStorageWriteFailure(errorMessage: errorMsg)) {
      try {
        final fallbackRoot = await n._activateAppFolderStorageFallback(
          failedOutputDir: effectiveOutputDir.isNotEmpty
              ? effectiveOutputDir
              : n.state.outputDir,
        );
        if (!n.ref.mounted || fallbackRoot == null) return;
        n.updateItemStatus(item.id, DownloadStatus.queued, progress: 0.0);
        _log.w('Storage recovered; re-queued download in the app folder');
        return;
      } catch (_) {
        if (!n.ref.mounted) return;
        _log.w('Could not recover storage exception with app-folder fallback');
      }
    }

    if (errorType == DownloadErrorType.permission) {
      // Keep the explicit SAF reauthorization error selected above.
    } else if (errorMsg.contains('could not find Deezer equivalent') ||
        errorMsg.contains('track not found on Deezer')) {
      errorMsg = 'Track not found on Deezer (Metadata Unavailable)';
      errorType = DownloadErrorType.notFound;
    } else {
      errorType = n._downloadErrorTypeFromMessage(errorMsg);
    }

    if (errorType == DownloadErrorType.verificationRequired) {
      await n._handleVerificationRequiredDownload(item, errorMsg, item.service);
      return;
    }
    if (errorType == DownloadErrorType.rateLimit &&
        await n._handleRateLimitedDownload(item, errorMsg, item.service)) {
      return;
    }

    if (!n.ref.mounted) return;
    n._recordFailedDownload(
      item.id,
      error: errorMsg,
      errorType: errorType,
      diagnosticStage: _failureStage,
    );

    try {
      await PlatformBridge.cleanupConnections();
    } catch (_) {
      _log.w('Post-exception connection cleanup failed');
    }
  }
}
