// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppSettings _$AppSettingsFromJson(Map<String, dynamic> json) => AppSettings(
  defaultService: json['defaultService'] as String? ?? '',
  playbackProviderConfirmed:
      json['playbackProviderConfirmed'] as bool? ?? false,
  audioQuality: json['audioQuality'] as String? ?? '',
  downloadQualityByProvider: json['downloadQualityByProvider'] == null
      ? const {}
      : downloadQualitiesFromJson(json['downloadQualityByProvider']),
  downloadQualitySourceByProvider:
      json['downloadQualitySourceByProvider'] == null
      ? const {}
      : downloadQualitySourcesFromJson(json['downloadQualitySourceByProvider']),
  playbackQuality:
      _readPlaybackQuality(json, 'playbackQuality') as String? ?? 'opus',
  playbackQualityVersion:
      (_readPlaybackQualityVersion(json, 'playbackQualityVersion') as num?)
          ?.toInt() ??
      2,
  playbackCacheBitrate: json['playbackCacheBitrate'] as String? ?? '128k',
  playbackPrefetchCount:
      (_readPlaybackPrefetchCount(json, 'playbackPrefetchCount') as num?)
          ?.toInt()
          .clamp(0, 5) ??
      3,
  playbackPrefetchVersion:
      (_readPlaybackPrefetchVersion(json, 'playbackPrefetchVersion') as num?)
          ?.toInt() ??
      2,
  filenameFormat: json['filenameFormat'] as String? ?? '{track:02} - {title}',
  downloadDirectory: json['downloadDirectory'] as String? ?? '',
  networkDownloadFolder: json['networkDownloadFolder'] as String? ?? '',
  networkDownloadLabel: json['networkDownloadLabel'] as String? ?? '',
  downloadDirectoryBookmark: json['downloadDirectoryBookmark'] as String? ?? '',
  storageMode: json['storageMode'] as String? ?? 'app',
  downloadTreeUri: json['downloadTreeUri'] as String? ?? '',
  autoFallback: json['autoFallback'] as bool? ?? true,
  embedMetadata: json['embedMetadata'] as bool? ?? true,
  embeddedCoverMaxDimension:
      (json['embeddedCoverMaxDimension'] as num?)?.toInt() ?? 0,
  artistTagMode: json['artistTagMode'] as String? ?? artistTagModeJoined,
  metadataSeparators: json['metadataSeparators'] == null
      ? const MetadataSeparators()
      : MetadataSeparators.fromJson(
          json['metadataSeparators'] as Map<String, dynamic>,
        ),
  embedLyrics: json['embedLyrics'] as bool? ?? true,
  embedReplayGain: json['embedReplayGain'] as bool? ?? false,
  playbackNormalization: json['playbackNormalization'] as bool? ?? false,
  playbackNormalizationPreamp: json['playbackNormalizationPreamp'] == null
      ? 0
      : playbackNormalizationPreampFromJson(
          json['playbackNormalizationPreamp'],
        ),
  playbackNormalizationMode: json['playbackNormalizationMode'] == null
      ? 'track'
      : playbackNormalizationModeFromJson(json['playbackNormalizationMode']),
  playOnHeadphonesConnected:
      json['playOnHeadphonesConnected'] as bool? ?? false,
  gaplessPlayback: json['gaplessPlayback'] as bool? ?? true,
  avoidBluetoothPops: json['avoidBluetoothPops'] as bool? ?? true,
  autoMix: json['autoMix'] as bool? ?? false,
  autoMixDuration: json['autoMixDuration'] == null
      ? 0
      : autoMixDurationFromJson(json['autoMixDuration']),
  autoMixEffect:
      $enumDecodeNullable(
        _$AutoMixEffectEnumMap,
        json['autoMixEffect'],
        unknownValue: AutoMixEffect.auto,
      ) ??
      AutoMixEffect.auto,
  autoMixSpeed: json['autoMixSpeed'] == null
      ? 1
      : autoMixSpeedFromJson(json['autoMixSpeed']),
  autoMixPitch: json['autoMixPitch'] == null
      ? 0
      : autoMixPitchFromJson(json['autoMixPitch']),
  autoMixEcho: json['autoMixEcho'] as bool? ?? false,
  autoMixLowPass: json['autoMixLowPass'] as bool? ?? false,
  discordRichPresenceEnabled:
      json['discordRichPresenceEnabled'] as bool? ?? false,
  usbBitPerfect: json['usbBitPerfect'] as bool? ?? false,
  usbDirect: json['usbDirect'] as bool? ?? false,
  usbDsdOverPcm: json['usbDsdOverPcm'] as bool? ?? false,
  usbAllowFixedVolume: json['usbAllowFixedVolume'] as bool? ?? false,
  dapExclusive: json['dapExclusive'] as bool? ?? false,
  exclusiveOutput: json['exclusiveOutput'] as bool? ?? false,
  exclusiveOutputDevice: json['exclusiveOutputDevice'] as String? ?? '',
  autoplay: json['autoplay'] as bool? ?? false,
  autoplayPersonalization: json['autoplayPersonalization'] as bool? ?? true,
  songAnalysis: json['songAnalysis'] as bool? ?? false,
  songAnalysisOnlyWhileCharging:
      json['songAnalysisOnlyWhileCharging'] as bool? ?? true,
  musicHaptics: json['musicHaptics'] as bool? ?? false,
  musicHapticsSensitivity: json['musicHapticsSensitivity'] == null
      ? 0.5
      : musicHapticsLevelFromJson(json['musicHapticsSensitivity']),
  musicHapticsStrength: json['musicHapticsStrength'] == null
      ? 0.5
      : musicHapticsLevelFromJson(json['musicHapticsStrength']),
  playerCoverStyle: json['playerCoverStyle'] == null
      ? ''
      : playerCoverStyleFromJson(json['playerCoverStyle']),
  landscapeLyricsArtwork: json['landscapeLyricsArtwork'] as bool? ?? false,
  playerLyricsPreviewHidden:
      json['playerLyricsPreviewHidden'] as bool? ?? false,
  playerLyricsPreviewAlign: playerLyricsPreviewAlignFromJson(
    json['playerLyricsPreviewAlign'],
  ),
  lyricsAlign: lyricsViewAlignFromJson(json['lyricsAlign']),
  lyricsLineHintShown: json['lyricsLineHintShown'] as bool? ?? false,
  autoHideLyricsControls: json['autoHideLyricsControls'] as bool? ?? true,
  compactPlayer: json['compactPlayer'] as bool? ?? false,
  isFirstLaunch: json['isFirstLaunch'] as bool? ?? true,
  checkForUpdates: json['checkForUpdates'] as bool? ?? true,
  updateChannel: json['updateChannel'] as String? ?? 'stable',
  folderOrganization: json['folderOrganization'] as String? ?? 'none',
  folderPathTemplate:
      json['folderPathTemplate'] as String? ?? '{artist}/{album}',
  createPlaylistFolder: json['createPlaylistFolder'] as bool? ?? false,
  useAlbumArtistForFolders: json['useAlbumArtistForFolders'] as bool? ?? true,
  usePrimaryArtistOnly: json['usePrimaryArtistOnly'] as bool? ?? false,
  filterContributingArtistsInAlbumArtist:
      json['filterContributingArtistsInAlbumArtist'] as bool? ?? false,
  historyViewMode: json['historyViewMode'] as String? ?? 'grid',
  historyFilterMode: json['historyFilterMode'] as String? ?? 'all',
  historySortMode: json['historySortMode'] == null
      ? 'latest'
      : librarySortModeFromJson(json['historySortMode']),
  defaultLibraryView: json['defaultLibraryView'] as String? ?? 'last',
  libraryQualityLabelMode:
      json['libraryQualityLabelMode'] as String? ??
      AppSettings.libraryQualityLabelBitDepthOnly,
  autoDownloadSavedTracks: json['autoDownloadSavedTracks'] as bool? ?? false,
  enableLogging: json['enableLogging'] as bool? ?? false,
  useExtensionProviders: json['useExtensionProviders'] as bool? ?? true,
  downloadFallbackExtensionIds:
      (json['downloadFallbackExtensionIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
  searchProvider: json['searchProvider'] as String?,
  searchProviderPinned: json['searchProviderPinned'] as bool? ?? false,
  defaultSearchTab: json['defaultSearchTab'] as String? ?? 'all',
  searchRegion: json['searchRegion'] as String? ?? 'auto',
  personalizeSearchResults: json['personalizeSearchResults'] as bool? ?? true,
  searchViewMode: json['searchViewMode'] as String? ?? 'list',
  homeFeedProvider: json['homeFeedProvider'] as String?,
  separateSingles: json['separateSingles'] as bool? ?? true,
  singleFilenameFormat: json['singleFilenameFormat'] as String? ?? '{title}',
  albumFolderStructure:
      json['albumFolderStructure'] as String? ?? 'artist_album_singles',
  heroAnimationsEnabled: json['heroAnimationsEnabled'] as bool? ?? true,
  forceBackdropBlur: json['forceBackdropBlur'] as bool? ?? false,
  extensionVerificationBrowserMode:
      json['extensionVerificationBrowserMode'] as String? ?? 'in_app_first',
  locale: json['locale'] as String? ?? 'system',
  lyricsMode: json['lyricsMode'] as String? ?? 'embed',
  keepScreenOnLyrics: json['keepScreenOnLyrics'] as bool? ?? true,
  motionArtworkEnabled: json['motionArtworkEnabled'] as bool? ?? true,
  canvasMobileDataEnabled: json['canvasMobileDataEnabled'] as bool? ?? false,
  spotifyCanvasEnabled: json['spotifyCanvasEnabled'] as bool? ?? true,
  playerAdaptiveFullBleed: json['playerAdaptiveFullBleed'] as bool? ?? true,
  videoMobileDataEnabled: json['videoMobileDataEnabled'] as bool? ?? false,
  listeningStatisticsEnabled:
      json['listeningStatisticsEnabled'] as bool? ?? true,
  redownloadFakeHiRes: json['redownloadFakeHiRes'] as bool? ?? false,
  useAllFilesAccess: json['useAllFilesAccess'] as bool? ?? false,
  autoExportFailedDownloads:
      json['autoExportFailedDownloads'] as bool? ?? false,
  downloadNetworkMode: json['downloadNetworkMode'] as String? ?? 'any',
  networkCompatibilityMode: json['networkCompatibilityMode'] as bool? ?? false,
  allowLocalNetwork: json['allowLocalNetwork'] as bool? ?? false,
  songLinkRegion: json['songLinkRegion'] as String? ?? 'US',
  nativeDownloadWorkerEnabled:
      json['nativeDownloadWorkerEnabled'] as bool? ?? false,
  concurrentDownloads: (json['concurrentDownloads'] as num?)?.toInt() ?? 1,
  localLibraryEnabled: json['localLibraryEnabled'] as bool? ?? false,
  localLibraryPath: json['localLibraryPath'] as String? ?? '',
  localLibraryBookmark: json['localLibraryBookmark'] as String? ?? '',
  localLibraryShowDuplicates:
      json['localLibraryShowDuplicates'] as bool? ?? true,
  localLibraryAutoScan: json['localLibraryAutoScan'] as String? ?? 'off',
  hasCompletedTutorial: json['hasCompletedTutorial'] as bool? ?? false,
  acceptedLegalVersion: (json['acceptedLegalVersion'] as num?)?.toInt() ?? 0,
  acceptedLegalAt: json['acceptedLegalAt'] as String? ?? '',
  analyticsEnabled: json['analyticsEnabled'] as bool? ?? true,
  whatsNewSeen: json['whatsNewSeen'] as String? ?? '',
  lyricsProviders:
      (json['lyricsProviders'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const ['apple_music', 'lrcred', 'mornye_lyrics', 'lyricsplus', 'lrclib'],
  lyricsIncludeTranslationNetease:
      json['lyricsIncludeTranslationNetease'] as bool? ?? false,
  lyricsIncludeRomanizationNetease:
      json['lyricsIncludeRomanizationNetease'] as bool? ?? false,
  lyricsMultiPersonWordByWord:
      json['lyricsMultiPersonWordByWord'] as bool? ?? true,
  lyricsAppleElrcWordSync: json['lyricsAppleElrcWordSync'] as bool? ?? true,
  musixmatchLanguage: json['musixmatchLanguage'] as String? ?? '',
  lyricsAiProvider: json['lyricsAiProvider'] as String? ?? 'openai',
  lyricsAiBaseUrl: json['lyricsAiBaseUrl'] as String? ?? '',
  lyricsAiModel: json['lyricsAiModel'] as String? ?? '',
  lyricsTranslationLanguage: json['lyricsTranslationLanguage'] as String? ?? '',
  lyricsAiInstruction: json['lyricsAiInstruction'] as String? ?? '',
  lyricsAutoTranslate: json['lyricsAutoTranslate'] as bool? ?? false,
  lyricsAiRomanize: json['lyricsAiRomanize'] as bool? ?? true,
  lyricsAiWordSync: json['lyricsAiWordSync'] as bool? ?? false,
  deduplicateDownloads:
      _readDuplicatesSkipped(json, 'deduplicateDownloads') as bool? ?? true,
  allowQualityVariants:
      _readQualityVariantsOff(json, 'allowQualityVariants') as bool? ?? false,
  strictDownloadQuality:
      _readStrictQualityOff(json, 'strictDownloadQuality') as bool? ?? false,
  saveDownloadHistory: json['saveDownloadHistory'] as bool? ?? true,
  playerMode: json['playerMode'] as String? ?? 'internal',
  playerShowPronunciation: json['playerShowPronunciation'] as bool? ?? true,
  playerBlurInactiveLyrics: json['playerBlurInactiveLyrics'] as bool? ?? true,
  playerShowTranslation: json['playerShowTranslation'] as bool? ?? true,
  playerShowVolume: json['playerShowVolume'] as bool? ?? true,
  startupAnimation: json['startupAnimation'] as bool? ?? true,
  startupSound: json['startupSound'] as bool? ?? false,
);

Map<String, dynamic> _$AppSettingsToJson(
  AppSettings instance,
) => <String, dynamic>{
  'defaultService': instance.defaultService,
  'playbackProviderConfirmed': instance.playbackProviderConfirmed,
  'audioQuality': instance.audioQuality,
  'downloadQualityByProvider': instance.downloadQualityByProvider,
  'downloadQualitySourceByProvider': instance.downloadQualitySourceByProvider
      .map((k, e) => MapEntry(k, e.toJson())),
  'playbackQuality': instance.playbackQuality,
  'playbackQualityVersion': instance.playbackQualityVersion,
  'playbackCacheBitrate': instance.playbackCacheBitrate,
  'playbackPrefetchCount': instance.playbackPrefetchCount,
  'playbackPrefetchVersion': instance.playbackPrefetchVersion,
  'filenameFormat': instance.filenameFormat,
  'downloadDirectory': instance.downloadDirectory,
  'networkDownloadFolder': instance.networkDownloadFolder,
  'networkDownloadLabel': instance.networkDownloadLabel,
  'downloadDirectoryBookmark': instance.downloadDirectoryBookmark,
  'storageMode': instance.storageMode,
  'downloadTreeUri': instance.downloadTreeUri,
  'autoFallback': instance.autoFallback,
  'embedMetadata': instance.embedMetadata,
  'embeddedCoverMaxDimension': instance.embeddedCoverMaxDimension,
  'artistTagMode': instance.artistTagMode,
  'metadataSeparators': instance.metadataSeparators.toJson(),
  'embedLyrics': instance.embedLyrics,
  'embedReplayGain': instance.embedReplayGain,
  'playbackNormalization': instance.playbackNormalization,
  'playbackNormalizationPreamp': instance.playbackNormalizationPreamp,
  'playbackNormalizationMode': instance.playbackNormalizationMode,
  'playOnHeadphonesConnected': instance.playOnHeadphonesConnected,
  'gaplessPlayback': instance.gaplessPlayback,
  'avoidBluetoothPops': instance.avoidBluetoothPops,
  'autoMix': instance.autoMix,
  'autoMixDuration': instance.autoMixDuration,
  'autoMixEffect': _$AutoMixEffectEnumMap[instance.autoMixEffect]!,
  'autoMixSpeed': instance.autoMixSpeed,
  'autoMixPitch': instance.autoMixPitch,
  'autoMixEcho': instance.autoMixEcho,
  'autoMixLowPass': instance.autoMixLowPass,
  'discordRichPresenceEnabled': instance.discordRichPresenceEnabled,
  'usbBitPerfect': instance.usbBitPerfect,
  'usbDirect': instance.usbDirect,
  'usbDsdOverPcm': instance.usbDsdOverPcm,
  'usbAllowFixedVolume': instance.usbAllowFixedVolume,
  'dapExclusive': instance.dapExclusive,
  'exclusiveOutput': instance.exclusiveOutput,
  'exclusiveOutputDevice': instance.exclusiveOutputDevice,
  'autoplay': instance.autoplay,
  'autoplayPersonalization': instance.autoplayPersonalization,
  'songAnalysis': instance.songAnalysis,
  'songAnalysisOnlyWhileCharging': instance.songAnalysisOnlyWhileCharging,
  'musicHaptics': instance.musicHaptics,
  'musicHapticsSensitivity': instance.musicHapticsSensitivity,
  'musicHapticsStrength': instance.musicHapticsStrength,
  'playerCoverStyle': instance.playerCoverStyle,
  'landscapeLyricsArtwork': instance.landscapeLyricsArtwork,
  'playerLyricsPreviewHidden': instance.playerLyricsPreviewHidden,
  'playerLyricsPreviewAlign': lyricsAlignToJson(
    instance.playerLyricsPreviewAlign,
  ),
  'lyricsAlign': lyricsAlignToJson(instance.lyricsAlign),
  'lyricsLineHintShown': instance.lyricsLineHintShown,
  'autoHideLyricsControls': instance.autoHideLyricsControls,
  'compactPlayer': instance.compactPlayer,
  'isFirstLaunch': instance.isFirstLaunch,
  'checkForUpdates': instance.checkForUpdates,
  'updateChannel': instance.updateChannel,
  'folderOrganization': instance.folderOrganization,
  'folderPathTemplate': instance.folderPathTemplate,
  'createPlaylistFolder': instance.createPlaylistFolder,
  'useAlbumArtistForFolders': instance.useAlbumArtistForFolders,
  'usePrimaryArtistOnly': instance.usePrimaryArtistOnly,
  'filterContributingArtistsInAlbumArtist':
      instance.filterContributingArtistsInAlbumArtist,
  'historyViewMode': instance.historyViewMode,
  'historyFilterMode': instance.historyFilterMode,
  'historySortMode': instance.historySortMode,
  'defaultLibraryView': instance.defaultLibraryView,
  'libraryQualityLabelMode': instance.libraryQualityLabelMode,
  'autoDownloadSavedTracks': instance.autoDownloadSavedTracks,
  'enableLogging': instance.enableLogging,
  'useExtensionProviders': instance.useExtensionProviders,
  'downloadFallbackExtensionIds': instance.downloadFallbackExtensionIds,
  'searchProvider': instance.searchProvider,
  'searchProviderPinned': instance.searchProviderPinned,
  'defaultSearchTab': instance.defaultSearchTab,
  'searchRegion': instance.searchRegion,
  'personalizeSearchResults': instance.personalizeSearchResults,
  'searchViewMode': instance.searchViewMode,
  'homeFeedProvider': instance.homeFeedProvider,
  'separateSingles': instance.separateSingles,
  'singleFilenameFormat': instance.singleFilenameFormat,
  'albumFolderStructure': instance.albumFolderStructure,
  'heroAnimationsEnabled': instance.heroAnimationsEnabled,
  'forceBackdropBlur': instance.forceBackdropBlur,
  'extensionVerificationBrowserMode': instance.extensionVerificationBrowserMode,
  'locale': instance.locale,
  'lyricsMode': instance.lyricsMode,
  'keepScreenOnLyrics': instance.keepScreenOnLyrics,
  'motionArtworkEnabled': instance.motionArtworkEnabled,
  'canvasMobileDataEnabled': instance.canvasMobileDataEnabled,
  'spotifyCanvasEnabled': instance.spotifyCanvasEnabled,
  'playerAdaptiveFullBleed': instance.playerAdaptiveFullBleed,
  'videoMobileDataEnabled': instance.videoMobileDataEnabled,
  'listeningStatisticsEnabled': instance.listeningStatisticsEnabled,
  'redownloadFakeHiRes': instance.redownloadFakeHiRes,
  'useAllFilesAccess': instance.useAllFilesAccess,
  'autoExportFailedDownloads': instance.autoExportFailedDownloads,
  'downloadNetworkMode': instance.downloadNetworkMode,
  'networkCompatibilityMode': instance.networkCompatibilityMode,
  'allowLocalNetwork': instance.allowLocalNetwork,
  'songLinkRegion': instance.songLinkRegion,
  'nativeDownloadWorkerEnabled': instance.nativeDownloadWorkerEnabled,
  'concurrentDownloads': instance.concurrentDownloads,
  'localLibraryEnabled': instance.localLibraryEnabled,
  'localLibraryPath': instance.localLibraryPath,
  'localLibraryBookmark': instance.localLibraryBookmark,
  'localLibraryShowDuplicates': instance.localLibraryShowDuplicates,
  'localLibraryAutoScan': instance.localLibraryAutoScan,
  'hasCompletedTutorial': instance.hasCompletedTutorial,
  'acceptedLegalVersion': instance.acceptedLegalVersion,
  'acceptedLegalAt': instance.acceptedLegalAt,
  'analyticsEnabled': instance.analyticsEnabled,
  'whatsNewSeen': instance.whatsNewSeen,
  'lyricsProviders': instance.lyricsProviders,
  'lyricsIncludeTranslationNetease': instance.lyricsIncludeTranslationNetease,
  'lyricsIncludeRomanizationNetease': instance.lyricsIncludeRomanizationNetease,
  'lyricsMultiPersonWordByWord': instance.lyricsMultiPersonWordByWord,
  'lyricsAppleElrcWordSync': instance.lyricsAppleElrcWordSync,
  'musixmatchLanguage': instance.musixmatchLanguage,
  'lyricsAiProvider': instance.lyricsAiProvider,
  'lyricsAiBaseUrl': instance.lyricsAiBaseUrl,
  'lyricsAiModel': instance.lyricsAiModel,
  'lyricsTranslationLanguage': instance.lyricsTranslationLanguage,
  'lyricsAiInstruction': instance.lyricsAiInstruction,
  'lyricsAutoTranslate': instance.lyricsAutoTranslate,
  'lyricsAiRomanize': instance.lyricsAiRomanize,
  'lyricsAiWordSync': instance.lyricsAiWordSync,
  'deduplicateDownloads': instance.deduplicateDownloads,
  'allowQualityVariants': instance.allowQualityVariants,
  'strictDownloadQuality': instance.strictDownloadQuality,
  'saveDownloadHistory': instance.saveDownloadHistory,
  'playerMode': instance.playerMode,
  'playerShowPronunciation': instance.playerShowPronunciation,
  'playerBlurInactiveLyrics': instance.playerBlurInactiveLyrics,
  'playerShowTranslation': instance.playerShowTranslation,
  'playerShowVolume': instance.playerShowVolume,
  'startupAnimation': instance.startupAnimation,
  'startupSound': instance.startupSound,
};

const _$AutoMixEffectEnumMap = {
  AutoMixEffect.auto: 'auto',
  AutoMixEffect.crossfade: 'crossfade',
  AutoMixEffect.muffled: 'muffled',
  AutoMixEffect.echo: 'echo',
  AutoMixEffect.pitch: 'pitch',
  AutoMixEffect.custom: 'custom',
};
