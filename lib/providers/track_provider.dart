import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/services/isrc_track_lookup.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/regional_song_signal.dart';
import 'package:mornye/services/search_taste_profile.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/services/search_region.dart';
import 'package:mornye/services/search_result_classifier.dart';
import 'package:mornye/services/song_search_ranking.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';

final _log = AppLogger('TrackProvider');
/// Songs of the artist named by the text below which a search also asks the
/// provider for the artist's top tracks.
const int artistSongsWanted = 5;

const Duration localSongSignalTimeout = Duration(milliseconds: 1500);

const Duration artistTopTracksTimeout = Duration(seconds: 4);

const _extensionInitRetryTimeout = Duration(seconds: 30);

class TrackState {
  final List<Track> tracks;
  final bool isLoading;
  final String? error;
  final String? albumId;
  final String? albumName;
  final String? albumDescription;
  final String? playlistName;
  final String? playlistId;
  final String? artistId;
  final String? artistName;
  final String? coverUrl;
  final String? headerImageUrl;
  final String? headerVideoUrl;
  final String? headerLogoUrl;
  final String? artistAlbumsNext;
  final int? monthlyListeners;
  final List<ArtistAlbum>? artistAlbums;
  final List<Track>? artistTopTracks;
  final List<ArtistConcert> artistConcerts;
  final bool hasSearchText;
  final bool isShowingRecentAccess;
  final String? searchExtensionId;
  final String? selectedSearchFilter;
  final String? searchSource;

  const TrackState({
    this.tracks = const [],
    this.isLoading = false,
    this.error,
    this.albumId,
    this.albumName,
    this.albumDescription,
    this.playlistName,
    this.playlistId,
    this.artistId,
    this.artistName,
    this.coverUrl,
    this.headerImageUrl,
    this.headerVideoUrl,
    this.headerLogoUrl,
    this.artistAlbumsNext,
    this.monthlyListeners,
    this.artistAlbums,
    this.artistTopTracks,
    this.artistConcerts = const [],
    this.hasSearchText = false,
    this.isShowingRecentAccess = false,
    this.searchExtensionId,
    this.selectedSearchFilter,
    this.searchSource,
  });

  bool get hasContent => tracks.isNotEmpty || artistAlbums != null;

  TrackState copyWith({
    List<Track>? tracks,
    bool? isLoading,
    String? error,
    String? albumId,
    String? albumName,
    String? albumDescription,
    String? playlistName,
    String? playlistId,
    String? artistId,
    String? artistName,
    String? coverUrl,
    String? headerImageUrl,
    String? headerVideoUrl,
    String? headerLogoUrl,
    String? artistAlbumsNext,
    int? monthlyListeners,
    List<ArtistAlbum>? artistAlbums,
    List<Track>? artistTopTracks,
    List<ArtistConcert>? artistConcerts,
    bool? hasSearchText,
    bool? isShowingRecentAccess,
    String? searchExtensionId,
    String? selectedSearchFilter,
    bool clearSelectedSearchFilter = false,
    String? searchSource,
    bool clearSearchSource = false,
  }) {
    return TrackState(
      tracks: tracks ?? this.tracks,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      albumId: albumId ?? this.albumId,
      albumName: albumName ?? this.albumName,
      albumDescription: albumDescription ?? this.albumDescription,
      playlistName: playlistName ?? this.playlistName,
      playlistId: playlistId ?? this.playlistId,
      artistId: artistId ?? this.artistId,
      artistName: artistName ?? this.artistName,
      coverUrl: coverUrl ?? this.coverUrl,
      headerImageUrl: headerImageUrl ?? this.headerImageUrl,
      headerVideoUrl: headerVideoUrl ?? this.headerVideoUrl,
      headerLogoUrl: headerLogoUrl ?? this.headerLogoUrl,
      artistAlbumsNext: artistAlbumsNext ?? this.artistAlbumsNext,
      monthlyListeners: monthlyListeners ?? this.monthlyListeners,
      artistAlbums: artistAlbums ?? this.artistAlbums,
      artistTopTracks: artistTopTracks ?? this.artistTopTracks,
      artistConcerts: artistConcerts ?? this.artistConcerts,
      hasSearchText: hasSearchText ?? this.hasSearchText,
      isShowingRecentAccess:
          isShowingRecentAccess ?? this.isShowingRecentAccess,
      searchExtensionId: searchExtensionId ?? this.searchExtensionId,
      selectedSearchFilter: clearSelectedSearchFilter
          ? null
          : (selectedSearchFilter ?? this.selectedSearchFilter),
      searchSource: clearSearchSource
          ? null
          : (searchSource ?? this.searchSource),
    );
  }
}

class ArtistAlbum {
  final String id;
  final String name;
  final String releaseDate;
  final int totalTracks;
  final String? coverUrl;
  final String albumType;
  final String artists;
  final String? providerId;

  const ArtistAlbum({
    required this.id,
    required this.name,
    required this.releaseDate,
    required this.totalTracks,
    this.coverUrl,
    required this.albumType,
    required this.artists,
    this.providerId,
  });
}

class TrackNotifier extends Notifier<TrackState> {
  int _currentRequestId = 0;
  final RegionalRankingCache _regionalCache = RegionalRankingCache();
  ({DateTime at, SearchTasteProfile profile})? _tasteCache;

  @override
  TrackState build() {
    return const TrackState();
  }

  bool _isRequestValid(int requestId) =>
      ref.mounted && requestId == _currentRequestId;

  Future<void> fetchFromUrl(String url) async {
    final requestId = ++_currentRequestId;

    state = TrackState(isLoading: true, hasSearchText: state.hasSearchText);

    try {
      var extensionHandler = await PlatformBridge.findURLHandler(url);
      if (!_isRequestValid(requestId)) return;
      if (extensionHandler == null) {
        final extensionState = ref.read(extensionProvider);
        if (!extensionState.isInitialized && extensionState.isLoading) {
          _log.i(
            'Extension URL handlers not ready yet, waiting for initialization...',
          );
          await ref
              .read(extensionProvider.notifier)
              .waitForInitialization(timeout: _extensionInitRetryTimeout);
          if (!_isRequestValid(requestId)) return;
          extensionHandler = await PlatformBridge.findURLHandler(url);
          if (!_isRequestValid(requestId)) return;
        }
      }

      if (extensionHandler == null) {
        state = TrackState(
          isLoading: false,
          error: 'url_not_recognized',
          hasSearchText: state.hasSearchText,
        );
        return;
      }

      _log.i('Found extension URL handler: $extensionHandler');

      Map<String, dynamic>? result;
      for (int attempt = 1; attempt <= 3; attempt++) {
        result = await PlatformBridge.handleURLWithExtension(url);
        if (!_isRequestValid(requestId)) return;

        if (result != null &&
            result['type'] == 'track' &&
            result['track'] != null) {
          final trackData = result['track'] as Map<String, dynamic>;
          final name = trackData['name']?.toString() ?? '';
          if (name.isNotEmpty) {
            break;
          }
        } else if (result != null &&
            (result['type'] == 'album' || result['type'] == 'playlist')) {
          break;
        } else if (result != null && result['type'] == 'artist') {
          break;
        }

        if (attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!_isRequestValid(requestId)) return;
        }
      }

      if (result != null) {
        final type = result['type'] as String?;
        final extensionId = result['extension_id'] as String?;

        if (type == 'track' && result['track'] != null) {
          final trackData = result['track'] as Map<String, dynamic>;
          final track = Track.fromBackendMap(trackData, source: extensionId);

          if (track.name.isEmpty) {
            state = TrackState(
              isLoading: false,
              error: 'Failed to load track metadata from add-on',
            );
            return;
          }

          state = TrackState(
            tracks: [track],
            isLoading: false,
            coverUrl: track.coverUrl,
            searchExtensionId: extensionId,
          );
          return;
        } else if ((type == 'album' || type == 'playlist') &&
            result['tracks'] != null) {
          final trackList = result['tracks'] as List<dynamic>;
          final collectionName = result['name'] as String?;
          final headerVideo = type == 'album'
              ? normalizeRemoteHttpUrl(result['header_video']?.toString())
              : null;
          final tracks = trackList
              .map(
                (t) => Track.fromBackendMap(
                  t as Map<String, dynamic>,
                  source: extensionId,
                  playlistName: type == 'playlist' ? collectionName : null,
                ).copyWith(headerVideoUrl: headerVideo),
              )
              .toList();
          state = TrackState(
            tracks: tracks,
            isLoading: false,
            albumId:
                (result['album'] as Map<String, dynamic>?)?['id'] as String?,
            albumName:
                collectionName ??
                (result['album'] as Map<String, dynamic>?)?['name'] as String?,
            albumDescription: type == 'album'
                ? albumDescriptionFromMetadata(
                        result['album'] as Map<String, dynamic>?,
                      ) ??
                      albumDescriptionFromMetadata(result)
                : null,
            playlistName: type == 'playlist' ? collectionName : null,
            playlistId: type == 'playlist' ? result['id'] as String? : null,
            coverUrl: normalizeCoverReference(result['cover_url']?.toString()),
            headerVideoUrl: normalizeRemoteHttpUrl(
              result['header_video']?.toString(),
            ),
            searchExtensionId: extensionId,
          );
          return;
        } else if (type == 'artist' && result['artist'] != null) {
          final artistData = result['artist'] as Map<String, dynamic>;
          final albumsList = artistData['albums'] as List<dynamic>? ?? [];
          final albums = albumsList
              .map((a) => _parseArtistAlbum(a as Map<String, dynamic>))
              .toList();

          final topTracksList =
              artistData['top_tracks'] as List<dynamic>? ?? [];
          final topTracks = topTracksList
              .map(
                (t) => Track.fromBackendMap(
                  t as Map<String, dynamic>,
                  source: extensionId,
                ),
              )
              .toList();

          state = TrackState(
            tracks: [],
            isLoading: false,
            artistId: artistData['id'] as String?,
            artistName: artistData['name'] as String?,
            coverUrl: normalizeRemoteHttpUrl(
              (artistData['image_url'] ?? artistData['images'])?.toString(),
            ),
            headerImageUrl: normalizeRemoteHttpUrl(
              artistData['header_image']?.toString(),
            ),
            headerVideoUrl: normalizeRemoteHttpUrl(
              artistData['header_video']?.toString(),
            ),
            headerLogoUrl: normalizeRemoteHttpUrl(
              artistData['header_logo']?.toString(),
            ),
            monthlyListeners: artistData['listeners'] as int?,
            artistAlbumsNext: artistData['albums_next'] as String?,
            artistAlbums: albums,
            artistTopTracks: topTracks.isNotEmpty ? topTracks : null,
            artistConcerts: ArtistConcert.parseList(artistData['concerts']),
            searchExtensionId: extensionId,
          );
          return;
        }
      }

      state = TrackState(
        isLoading: false,
        error: 'url_not_recognized',
        hasSearchText: state.hasSearchText,
      );
    } catch (e) {
      if (!_isRequestValid(requestId)) return;
      state = TrackState(
        isLoading: false,
        error: e.toString(),
        hasSearchText: state.hasSearchText,
      );
    }
  }

  Future<bool> searchByIsrc(
    String query, {
    String? selectedFilter,
    IsrcBackendLookup? lookup,
  }) async {
    if (isrcFromSearchQuery(query) == null) return false;
    final requestId = ++_currentRequestId;
    final currentFilter = selectedFilter ?? state.selectedSearchFilter;
    state = TrackState(
      isLoading: true,
      hasSearchText: state.hasSearchText,
      isShowingRecentAccess: state.isShowingRecentAccess,
      selectedSearchFilter: currentFilter,
    );
    final track = await lookupTrackByIsrc(query, lookup: lookup);
    if (!_isRequestValid(requestId)) return true;
    if (track == null) return false;
    state = TrackState(
      tracks: [track],
      isLoading: false,
      hasSearchText: state.hasSearchText,
      isShowingRecentAccess: state.isShowingRecentAccess,
      selectedSearchFilter: currentFilter,
      searchSource: 'deezer',
    );
    return true;
  }

  Future<void> search(String query, {String? filterOverride}) async {
    final requestId = ++_currentRequestId;
    final currentFilter = filterOverride ?? state.selectedSearchFilter;
    final requestFilter = currentFilter == 'all' ? null : currentFilter;
    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);

    String? resolvedProvider;
    final explicitProvider = settings.searchProvider?.trim();
    if (explicitProvider != null && explicitProvider.isNotEmpty) {
      resolvedProvider = explicitProvider;
    } else {
      resolvedProvider = defaultSearchExtension(extensionState.extensions)?.id;
    }

    if (resolvedProvider != null &&
        resolvedProvider.isNotEmpty &&
        !extensionState.extensions.any(
          (ext) => ext.enabled && ext.id == resolvedProvider,
        ) &&
        settings.searchProvider?.trim() == resolvedProvider) {
      if (!ref
          .read(extensionProvider.notifier)
          .isProviderMissingFromPartialInventory(resolvedProvider)) {
        ref.read(settingsProvider.notifier).setSearchProvider(null);
      }
      resolvedProvider = defaultSearchExtension(extensionState.extensions)?.id;
    }

    final isEnabledExtensionProvider =
        resolvedProvider != null &&
        resolvedProvider.isNotEmpty &&
        extensionState.extensions.any(
          (ext) => ext.enabled && ext.id == resolvedProvider,
        );

    if (resolvedProvider != null &&
        resolvedProvider.isNotEmpty &&
        isEnabledExtensionProvider) {
      final resolvedFilter = requestFilter ?? 'track';
      Map<String, dynamic>? options;
      options = {'filter': resolvedFilter};
      await customSearch(
        resolvedProvider,
        query,
        options: options,
        selectedFilter: resolvedFilter,
      );
      return;
    }

    state = TrackState(
      isLoading: true,
      hasSearchText: state.hasSearchText,
      isShowingRecentAccess: state.isShowingRecentAccess,
      selectedSearchFilter: currentFilter,
    );

    try {
      final includeExtensions = settings.useExtensionProviders;

      final metadataTrackResults =
          await PlatformBridge.searchTracksWithMetadataProviders(
            query,
            limit: 20,
            includeExtensions: includeExtensions,
          );
      if (!_isRequestValid(requestId)) {
        _log.w('Search request cancelled (requestId=$requestId)');
        return;
      }

      final tracks = <Track>[];
      for (int i = 0; i < metadataTrackResults.length; i++) {
        final t = metadataTrackResults[i];
        try {
          tracks.add(Track.fromBackendMap(t));
        } catch (e) {
          _log.e('Failed to parse track[$i]: $e', e);
        }
      }

      _log.i(
        'Search completed: provider=metadata_extensions, '
        'tracks=${tracks.length}, extensions=$includeExtensions, '
        'filter=$requestFilter',
      );

      state = TrackState(
        tracks: tracks,
        isLoading: false,
        hasSearchText: state.hasSearchText,
        isShowingRecentAccess: state.isShowingRecentAccess,
        selectedSearchFilter: currentFilter,
        searchSource: resolvedProvider,
      );
    } catch (e, stackTrace) {
      if (!_isRequestValid(requestId)) return;
      _log.e('Search failed: $e', e, stackTrace);
      state = TrackState(
        isLoading: false,
        error: e.toString(),
        hasSearchText: state.hasSearchText,
        isShowingRecentAccess: state.isShowingRecentAccess,
        selectedSearchFilter: currentFilter,
      );
    }
  }

  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    final requestId = ++_currentRequestId;
    final currentFilter = selectedFilter ?? state.selectedSearchFilter;
    final keepPrevious =
        state.tracks.isNotEmpty &&
        state.error == null &&
        state.albumId == null &&
        state.playlistId == null &&
        state.artistId == null &&
        state.searchExtensionId == extensionId &&
        state.selectedSearchFilter == currentFilter;

    state = TrackState(
      tracks: keepPrevious ? state.tracks : const [],
      isLoading: true,
      hasSearchText: state.hasSearchText,
      isShowingRecentAccess: state.isShowingRecentAccess,
      searchExtensionId: keepPrevious ? state.searchExtensionId : null,
      selectedSearchFilter: currentFilter,
    );

    try {
      final tracks = await _fetchSearchTracks(
        extensionId,
        query,
        options,
        currentFilter,
      );

      if (!_isRequestValid(requestId)) {
        _log.w('Custom search request cancelled (requestId=$requestId)');
        return;
      }

      _log.i(
        'Custom search completed: extension=$extensionId, '
        'tracks=${tracks.length}',
      );

      state = TrackState(
        tracks: tracks,
        isLoading: false,
        hasSearchText: state.hasSearchText,
        isShowingRecentAccess: state.isShowingRecentAccess,
        searchExtensionId: extensionId,
        selectedSearchFilter: currentFilter,
      );
    } catch (e, stackTrace) {
      if (!_isRequestValid(requestId)) return;
      _log.e('Custom search failed: $e', e, stackTrace);
      if (allowVerificationRetry &&
          isExtensionVerificationRequired(e) &&
          extensionVerificationIsSilent) {
        // Sin sesión todavía: la búsqueda no abre ni espera verificaciones.
        // Se omite este proveedor sin mensajes; el planificador de fondo
        // obtiene la sesión y, al llegar, los resultados aparecen solos.
        _log.i('Custom search skipped: $extensionId has no session yet');
        state = TrackState(
          isLoading: false,
          hasSearchText: state.hasSearchText,
          isShowingRecentAccess: state.isShowingRecentAccess,
          searchExtensionId: extensionId,
          selectedSearchFilter: currentFilter,
        );
        unawaited(
          _retrySearchWhenSessionReady(
            requestId,
            extensionId,
            query,
            options,
            currentFilter,
          ),
        );
        return;
      }
      if (allowVerificationRetry && isExtensionVerificationRequired(e)) {
        _log.i(
          'Custom search requires verification; waiting for $extensionId grant',
        );
        state = TrackState(
          isLoading: true,
          hasSearchText: state.hasSearchText,
          isShowingRecentAccess: state.isShowingRecentAccess,
          searchExtensionId: extensionId,
          selectedSearchFilter: currentFilter,
        );
        final verified = await openVerificationAndAwaitGrant(
          extensionId,
          browserMode: ref
              .read(settingsProvider)
              .extensionVerificationBrowserMode,
        );
        if (!_isRequestValid(requestId)) return;
        if (verified) {
          _log.i(
            'Verification complete for $extensionId; retrying custom search',
          );
          await customSearch(
            extensionId,
            query,
            options: options,
            selectedFilter: currentFilter,
            allowVerificationRetry: false,
          );
          return;
        }
      }
      state = TrackState(
        isLoading: false,
        error: e.toString(),
        hasSearchText: state.hasSearchText,
        isShowingRecentAccess: state.isShowingRecentAccess,
        selectedSearchFilter: currentFilter,
      );
    }
  }

  List<Track> _parseSearchTracks(
    List<Map<String, dynamic>> results,
    String extensionId,
  ) {
    final tracks = <Track>[];
    for (int i = 0; i < results.length; i++) {
      try {
        tracks.add(Track.fromBackendMap(results[i], source: extensionId));
      } catch (e) {
        _log.e('Failed to parse custom search track[$i]: $e', e);
      }
    }
    return tracks;
  }

  /// Runs the plain query and, for providers with a title syntax, the
  /// title-targeted ones in parallel, then puts the songs whose title matches
  /// the text first. A failing extra query is ignored; the plain query's
  /// error is only raised when nothing answered.
  Future<List<Track>> _fetchSearchTracks(
    String extensionId,
    String query,
    Map<String, dynamic>? options,
    String? filter,
  ) async {
    final kind = filter == null || filter.isEmpty
        ? 'all'
        : canonicalExtensionSearchFilterId(filter);
    final wantsSongs = kind == 'all' || kind == 'track';
    final extraQueries = wantsSongs
        ? targetedSongQueries(extensionId, query)
        : const <String>[];
    final primaryOptions = extraQueries.isEmpty
        ? options
        : {...?options, 'limit': songSearchQueryLimit};

    final primary = PlatformBridge.customSearchWithExtension(
      extensionId,
      query,
      options: primaryOptions,
      cancelPrevious: true,
    );
    final signalFuture = wantsSongs && isPlainSongQuery(query)
        ? _regionalSignal(query)
        : Future<RegionalSongSignal?>.value();
    final tasteFuture = wantsSongs && isPlainSongQuery(query)
        ? _tasteProfile()
        : Future.value(SearchTasteProfile.empty);
    if (extraQueries.isEmpty) {
      final primaryTracks = _parseSearchTracks(await primary, extensionId);
      if (!wantsSongs || !isPlainSongQuery(query)) return primaryTracks;
      return await _rankSongs(
        primaryTracks,
        await _artistExtraSongs(extensionId, query, primaryTracks),
        query,
        await signalFuture,
        await tasteFuture,
      );
    }

    final extras = [
      for (final extraQuery in extraQueries)
        PlatformBridge.customSearchWithExtension(
          extensionId,
          extraQuery,
          options: const {'filter': 'track', 'limit': songSearchQueryLimit},
        ).then<List<Track>?>(
          (rows) => _parseSearchTracks(rows, extensionId),
          onError: (Object e) {
            _log.w('Targeted song search failed: $e');
            return null;
          },
        ),
    ];

    List<Track>? primaryTracks;
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      primaryTracks = _parseSearchTracks(await primary, extensionId);
    } catch (e, st) {
      primaryError = e;
      primaryStack = st;
    }
    final extraTracks = [
      for (final result in await Future.wait(extras)) ?result,
    ];
    if (primaryTracks == null && extraTracks.isEmpty) {
      Error.throwWithStackTrace(primaryError!, primaryStack!);
    }
    return await _rankSongs(
      primaryTracks ?? const [],
      [
        ...extraTracks,
        ...await _artistExtraSongs(
          extensionId,
          query,
          primaryTracks ?? const [],
        ),
      ],
      query,
      await signalFuture,
      await tasteFuture,
    );
  }

  /// Popularity of the songs in the chosen region and its neighbors, taken
  /// from Apple Music's storefront searches. Null when the region is off,
  /// Apple Music is not enabled, or nothing answered in time.
  Future<RegionalSongSignal?> _regionalSignal(String query) async {
    final region = resolveSearchRegion(
      ref.read(settingsProvider).searchRegion,
      deviceCountry: deviceCountryCode(),
    );
    if (region == null) return null;
    final enabled = ref
        .read(extensionProvider)
        .extensions
        .any(
          (ext) =>
              ext.id == regionalSignalExtensionId &&
              ext.enabled &&
              ext.hasCustomSearch,
        );
    if (!enabled) return null;
    try {
      final signal = await buildRegionalSignal(
        query: query,
        region: region,
        cache: _regionalCache,
        fetch: (country) async {
          final rows = await PlatformBridge.customSearchWithExtension(
            regionalSignalExtensionId,
            query,
            options: {
              'storefront': country,
              'rankingOnly': true,
              'limit': regionalSignalRows,
            },
          );
          return [
            for (final row in rows)
              (
                isrc: row['isrc']?.toString(),
                title: (row['name'] ?? '').toString(),
                artist: (row['artists'] ?? '').toString(),
              ),
          ];
        },
      ).timeout(regionalSignalTimeout);
      return signal.isEmpty ? null : signal;
    } catch (e) {
      _log.w('Regional signal skipped: $e');
      return null;
    }
  }

  /// What the user follows, picked and played on this device. Empty when
  /// personalization is off or there is no history.
  Future<SearchTasteProfile> _tasteProfile() async {
    if (!ref.read(settingsProvider).personalizeSearchResults) {
      return SearchTasteProfile.empty;
    }
    final cached = _tasteCache;
    if (cached != null &&
        DateTime.now().difference(cached.at) < searchTasteCacheTtl) {
      return cached.profile;
    }
    try {
      final followed = [
        for (final artist
            in ref.read(libraryCollectionsProvider).favoriteArtists)
          artist.name,
      ];
      final prefs = await SharedPreferences.getInstance();
      final picked = decodeMixPreferences(
        prefs.getString('music_preferences_v1'),
      );
      final now = DateTime.now();
      final summary = await ListeningStatisticsStore.instance
          .load(
            DateTime(now.year, now.month, now.day - searchTasteDays + 1),
            DateTime(now.year, now.month, now.day + 1),
          )
          .timeout(searchTasteTimeout);
      final profile = SearchTasteProfile(
        followedArtists: [...followed, ...picked.artists],
        playedMilliseconds: summary.artists,
        genres: picked.genres,
      );
      _tasteCache = (at: DateTime.now(), profile: profile);
      return profile;
    } catch (e) {
      _log.w('Search taste skipped: $e');
      return SearchTasteProfile.empty;
    }
  }

  /// Songs of the artist the text names when the plain results hold fewer
  /// than [artistSongsWanted] of them: the artist's top tracks, asked once
  /// through the provider's artist link, never waiting more than
  /// [artistTopTracksTimeout]. Empty when no artist result is named, the
  /// provider has no known link, or the request fails.
  Future<List<List<Track>>> _artistExtraSongs(
    String extensionId,
    String query,
    List<Track> primary,
  ) async {
    if (!isPlainSongQuery(query)) return const [];
    final artist = artistResultNamed([
      for (final track in primary)
        if (track.isArtistItem) track,
    ], query);
    if (artist == null || artist.id.isEmpty) return const [];
    final name = normalizeSearchText(artist.name);
    final known = primary.where(
      (track) =>
          !track.isCollection && songArtistParts(track.artistName).contains(name),
    );
    if (known.length >= artistSongsWanted) return const [];
    final url = switch (extensionId.trim().toLowerCase()) {
      'spotify' => 'https://open.spotify.com/artist/${artist.id}',
      'deezer' => 'https://www.deezer.com/artist/${artist.id}',
      _ => null,
    };
    if (url == null) return const [];
    try {
      final result = await PlatformBridge.handleURLWithExtension(
        url,
      ).timeout(artistTopTracksTimeout);
      final rows =
          (result?['artist'] as Map<String, dynamic>?)?['top_tracks']
              as List<dynamic>? ??
          const [];
      return [
        [
          for (final row in rows)
            if (row is Map<String, dynamic>)
              Track.fromBackendMap(row, source: extensionId),
        ],
      ];
    } catch (e) {
      _log.w('Artist top tracks for search skipped: $e');
      return const [];
    }
  }

  /// The songs of this search that are already on the device (download
  /// history, inventory or scanned library), checked in batch against local
  /// data only. Empty when nothing answers in time.
  Future<LocalSongSignal> _localSongSignal(List<Track> songs) async {
    if (songs.isEmpty) return LocalSongSignal.empty;
    try {
      return await _readLocalSongSignal(songs).timeout(localSongSignalTimeout);
    } catch (e) {
      _log.w('Local song signal skipped: $e');
      return LocalSongSignal.empty;
    }
  }

  Future<LocalSongSignal> _readLocalSongSignal(List<Track> songs) async {
    final candidates = songs.take(songSearchMergedLimit * 2).toList();
    final paths = [for (final _ in candidates) <String>{}];
    final inventory = await DownloadFileInventory.candidatePathsBatch(
      candidates,
    );
    final library = await ref
        .read(localLibraryProvider.notifier)
        .findTrackCandidatesBatch([
          for (final track in candidates)
            LocalLibraryBatchLookupRequest(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            ),
        ]);
    final history = ref.read(downloadHistoryProvider.notifier);
    for (var i = 0; i < candidates.length; i++) {
      final track = candidates[i];
      paths[i].addAll(inventory[i]);
      for (final item in library[i]) {
        if (matchesCatalogIdentity(
          track,
          isrc: item.isrc,
          title: item.trackName,
          artist: item.artistName,
          durationSeconds: item.duration,
        )) {
          paths[i].add(item.filePath);
        }
      }
    }
    final histories = await Future.wait([
      for (final track in candidates)
        history.findTrackCandidatesAsync(historyLookupForTrack(track)),
    ]);
    for (var i = 0; i < candidates.length; i++) {
      for (final item in histories[i]) {
        if (historyMatchesTrack(candidates[i], item)) {
          paths[i].add(item.filePath);
        }
      }
    }
    final presence = await ref
        .read(historyFilePresenceProvider.notifier)
        .verify([for (final set in paths) ...set]);
    return LocalSongSignal([
      for (var i = 0; i < candidates.length; i++)
        if (paths[i].any(
          (path) =>
              path.isNotEmpty &&
              !path.startsWith('network://') &&
              presence[path] == true,
        ))
          candidates[i],
    ]);
  }

  Future<List<Track>> _rankSongs(
    List<Track> primary,
    List<List<Track>> extras,
    String query,
    RegionalSongSignal? signal,
    SearchTasteProfile taste,
  ) async {
    final songs = <Track>[];
    final collections = <Track>[];
    for (final track in primary) {
      (track.isCollection ? collections : songs).add(track);
    }
    final extraSongs = [
      for (final extra in extras)
        [
          for (final track in extra)
            if (!track.isCollection) track,
        ],
    ];
    final local = !ref.read(settingsProvider).personalizeSearchResults
        ? LocalSongSignal.empty
        : await _localSongSignal([
          ...songs,
          for (final extra in extraSongs) ...extra,
        ]);
    return [
      ...mergeRankedSongs(
        [songs, ...extraSongs],
        query,
        declaredArtists: [
          for (final track in primary)
            if (track.isArtistItem) track.name,
        ],
        regionalScore: signal == null && taste.isEmpty && local.isEmpty
            ? null
            : (track) =>
                  (signal?.scoreOf(track) ?? 0) +
                  taste.scoreOf(track) +
                  local.scoreOf(track),
      ),
      ...collections,
    ];
  }

  Future<void> _retrySearchWhenSessionReady(
    int requestId,
    String extensionId,
    String query,
    Map<String, dynamic>? options,
    String? selectedFilter,
  ) async {
    try {
      // Solo consulta/une el planificador de fondo; no abre nada por sí misma.
      final notifier = ref.read(extensionProvider.notifier);
      await notifier.runBackgroundSessionPass(force: true);
      if (!ref.mounted || !_isRequestValid(requestId)) return;
      if (notifier.sessionPreparer.knownExpiry(extensionId) == null) return;
      await customSearch(
        extensionId,
        query,
        options: options,
        selectedFilter: selectedFilter,
        allowVerificationRetry: false,
      );
    } catch (error) {
      _log.w('Search retry after background session failed: $error');
    }
  }

  void clear() {
    _currentRequestId++;
    state = const TrackState();
  }

  void setSearchFilter(String? filter) {
    if (state.selectedSearchFilter == filter) return;
    state = state.copyWith(
      selectedSearchFilter: filter,
      clearSelectedSearchFilter: filter == null,
    );
  }

  void setSearchText(bool hasText) {
    if (state.hasSearchText == hasText) {
      return;
    }
    state = state.copyWith(hasSearchText: hasText);
  }

  void setShowingRecentAccess(bool showing) {
    if (state.isShowingRecentAccess == showing) {
      return;
    }
    state = state.copyWith(isShowingRecentAccess: showing);
  }

  ArtistAlbum _parseArtistAlbum(Map<String, dynamic> data) {
    return ArtistAlbum(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      releaseDate: data['release_date'] as String? ?? '',
      totalTracks: int.tryParse(data['total_tracks']?.toString() ?? '') ?? 0,
      coverUrl: normalizeCoverReference(
        (data['cover_url'] ?? data['images'])?.toString(),
      ),
      albumType: data['album_type'] as String? ?? 'album',
      artists: data['artists'] as String? ?? '',
      providerId: data['provider_id']?.toString(),
    );
  }
}

final trackProvider = NotifierProvider<TrackNotifier, TrackState>(
  TrackNotifier.new,
);
