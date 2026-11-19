import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/download_quality_options.dart';

part 'settings.g.dart';

/// 'default' (a card) or 'fullscreen' once chosen, else empty for the app
/// style's own ([AppSettings.playerCoverStyleFor]).
String playerCoverStyleFromJson(Object? value) =>
    value == 'default' || value == 'fullscreen' ? value as String : '';

/// Horizontal alignment of lyric text, as in a word processor.
enum LyricsTextAlign { left, center, right, justify }

/// Alignment for the lyric views that lay lines out by singer by default:
/// [auto] keeps that layout and the rest override it.
enum LyricsViewAlign {
  auto,
  left,
  center,
  right,
  justify;

  LyricsTextAlign? get explicit => switch (this) {
    auto => null,
    left => LyricsTextAlign.left,
    center => LyricsTextAlign.center,
    right => LyricsTextAlign.right,
    justify => LyricsTextAlign.justify,
  };
}

LyricsTextAlign playerLyricsPreviewAlignFromJson(Object? value) {
  for (final align in LyricsTextAlign.values) {
    if (align.name == value) return align;
  }
  return LyricsTextAlign.right;
}

LyricsViewAlign lyricsViewAlignFromJson(Object? value) {
  for (final align in LyricsViewAlign.values) {
    if (align.name == value) return align;
  }
  return LyricsViewAlign.auto;
}

String lyricsAlignToJson(Enum value) => value.name;

/// Pre-amp applied on top of ReplayGain during playback, in whole dB.
/// -7 dB targets -25 LUFS from the -18 LUFS tag reference.
double playbackNormalizationPreampFromJson(Object? value) =>
    value is num && value.isFinite
    ? value.toDouble().roundToDouble().clamp(-15, 6)
    : 0;

String playbackNormalizationModeFromJson(Object? value) =>
    value == 'album' ? 'album' : 'track';

double musicHapticsLevelFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0, 1) : 0.5;

/// Sort choices offered by the Library, in display order.
const librarySortModes = [
  'manual',
  'latest',
  'oldest',
  'size-desc',
  'size-asc',
  'a-z',
  'z-a',
  'artist-asc',
  'artist-desc',
  'album-asc',
  'album-desc',
  'release-newest',
  'release-oldest',
  'genre-asc',
  'genre-desc',
];

String librarySortModeFromJson(Object? value) =>
    value is String && librarySortModes.contains(value) ? value : 'latest';

/// Provider IDs are case-insensitive. Prefer an already-normalized key if
/// older settings contain conflicting variants; otherwise use sorted order.
Map<String, String> normalizeDownloadQualityByProvider(
  Map<String, String> values,
) {
  final keys = values.keys.toList()..sort();
  final result = <String, String>{};
  for (final key in keys) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) continue;
    if (!result.containsKey(normalized) || key == normalized) {
      result[normalized] = values[key]!;
    }
  }
  return result;
}

Map<String, String> downloadQualitiesFromJson(Object? value) =>
    normalizeDownloadQualityByProvider(
      value is Map
          ? {
              for (final entry in value.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : const {},
    );

class DownloadQualitySource {
  final String provider;
  final String id;
  final String kind;
  final String label;
  const DownloadQualitySource({
    required this.provider,
    required this.id,
    required this.kind,
    required this.label,
  });
  Map<String, dynamic> toJson() => {
    'provider': provider,
    'id': id,
    'kind': kind,
    'label': label,
  };
}

Map<String, DownloadQualitySource> downloadQualitySourcesFromJson(
  Object? value,
) {
  final result = <String, DownloadQualitySource>{};
  if (value is! Map) return result;
  for (final entry in value.entries) {
    final data = entry.value;
    if (entry.key is! String || data is! Map) continue;
    final provider = data['provider'];
    final id = data['id'];
    final kind = data['kind'];
    final label = data['label'];
    final key = (entry.key as String).trim().toLowerCase();
    if (provider is! String ||
        provider.trim().toLowerCase() != key ||
        key.isEmpty ||
        id is! String ||
        manifestQualityId(id).isEmpty ||
        kind is! String ||
        label is! String)
      continue;
    result[key] = DownloadQualitySource(
      provider: provider,
      id: id,
      kind: kind,
      label: label,
    );
  }
  return result;
}

/// Settings saved before version 2 stored 'LOSSLESS' as the streaming default;
/// it becomes the automatic light mode once. Kept here (not in the generated
/// file) so regenerating with build_runner does not lose it.
Object? _readPlaybackQuality(Map<dynamic, dynamic> json, String key) {
  final version = (json['playbackQualityVersion'] as num?)?.toInt() ?? 1;
  final value = json[key];
  return version < 2 && value == 'LOSSLESS' ? 'auto_light' : value;
}

/// Whatever was stored, a loaded setting is already migrated.
Object? _readPlaybackQualityVersion(Map<dynamic, dynamic> json, String key) =>
    2;

Object? _readPlaybackPrefetchCount(Map<dynamic, dynamic> json, String key) {
  final version = (json['playbackPrefetchVersion'] as num?)?.toInt() ?? 1;
  final value = (json[key] as num?)?.toInt();
  if (version < 3) {
    return value == null || value == 1 || value == 2 ? 3 : value;
  }
  return value;
}

Object? _readPlaybackPrefetchVersion(Map<dynamic, dynamic> json, String key) =>
    3;

Object? _readDuplicatesSkipped(Map<dynamic, dynamic> json, String key) => true;

Object? _readQualityVariantsOff(Map<dynamic, dynamic> json, String key) =>
    false;

Object? _readStrictQualityOff(Map<dynamic, dynamic> json, String key) => false;

@JsonSerializable(explicitToJson: true)
class AppSettings {
  static const String homeFeedProviderOff = '__off__';
  static const String libraryQualityLabelBitrate = 'bitrate';
  static const String libraryQualityLabelFileFormat = 'file_format';
  static const String libraryQualityLabelBitDepthOnly = 'bit_depth_only';
  static const String libraryQualityLabelBitDepth = 'bit_depth';
  static const String libraryQualityLabelBitDepthBitrate = 'bit_depth_bitrate';

  final String defaultService;
  // Retained for compatibility with saved settings; it does not gate playback.
  final bool playbackProviderConfirmed;
  final String audioQuality;
  @JsonKey(fromJson: downloadQualitiesFromJson)
  final Map<String, String> downloadQualityByProvider;
  @JsonKey(fromJson: downloadQualitySourcesFromJson)
  final Map<String, DownloadQualitySource> downloadQualitySourceByProvider;

  DownloadQualitySource? downloadQualitySourceFor(
    String provider,
    String quality,
  ) {
    final key = provider.trim().toLowerCase();
    final source = downloadQualitySourceByProvider[key];
    final saved = downloadQualityByProvider[key];
    if (source == null ||
        saved == null ||
        manifestQualityId(quality).isEmpty ||
        source.provider.trim().toLowerCase() != key ||
        manifestQualityId(source.id) != manifestQualityId(quality) ||
        manifestQualityId(saved) != manifestQualityId(quality))
      return null;
    return source;
  }

  @JsonKey(readValue: _readPlaybackQuality)
  final String playbackQuality;

  /// 2 once the old 'LOSSLESS' streaming default was migrated to the
  /// automatic light mode; stored so the migration runs a single time.
  @JsonKey(readValue: _readPlaybackQualityVersion)
  final int playbackQualityVersion;
  final String playbackCacheBitrate;
  @JsonKey(readValue: _readPlaybackPrefetchCount)
  final int playbackPrefetchCount;
  @JsonKey(readValue: _readPlaybackPrefetchVersion)
  final int playbackPrefetchVersion;
  final String filenameFormat;
  final String downloadDirectory;
  final String networkDownloadFolder;
  final String networkDownloadLabel;
  final String downloadDirectoryBookmark;
  final String storageMode; // 'app' or 'saf'
  final String downloadTreeUri; // SAF persistable tree URI
  final bool autoFallback;
  final bool embedMetadata;

  /// Maximum width or height of remotely fetched artwork before embedding.
  /// Zero preserves the provider's original image.
  final int embeddedCoverMaxDimension;
  final String
  artistTagMode; // 'joined', 'split_vorbis' (Vorbis formats), or 'primary'
  final MetadataSeparators metadataSeparators;
  final bool embedLyrics;
  final bool embedReplayGain;
  // Apply ReplayGain/R128 tags as volume normalization in the built-in player.
  final bool playbackNormalization;
  @JsonKey(fromJson: playbackNormalizationPreampFromJson)
  final double playbackNormalizationPreamp;
  @JsonKey(fromJson: playbackNormalizationModeFromJson)
  final String playbackNormalizationMode; // 'track' or 'album'
  final bool playOnHeadphonesConnected;
  // Start the next song the moment one ends; AutoMix replaces it while on.
  final bool gaplessPlayback;
  final bool avoidBluetoothPops;
  final bool autoMix;
  @JsonKey(fromJson: autoMixDurationFromJson)
  final int autoMixDuration;
  @JsonKey(unknownEnumValue: AutoMixEffect.auto)
  final AutoMixEffect autoMixEffect;
  @JsonKey(fromJson: autoMixSpeedFromJson)
  final double autoMixSpeed;
  @JsonKey(fromJson: autoMixPitchFromJson)
  final double autoMixPitch;
  final bool autoMixEcho;
  final bool autoMixLowPass;
  AutoMixOptions get autoMixOptions => AutoMixOptions(
    durationSeconds: autoMixDuration,
    effect: autoMixEffect,
    speed: autoMixSpeed,
    pitchSemitones: autoMixPitch,
    echo: autoMixEcho,
    lowPass: autoMixLowPass,
  );
  final bool discordRichPresenceEnabled;
  final bool usbBitPerfect;
  final bool usbDirect;
  final bool usbDsdOverPcm;
  final bool usbAllowFixedVolume;
  final bool dapExclusive;

  /// Desktop: take the output device for the music player alone, bypassing
  /// the system mixer (WASAPI exclusive on Windows, hog mode on macOS, an
  /// ALSA `hw:` device on Linux). AutoMix and previews stay off while it is
  /// on.
  final bool exclusiveOutput;

  /// Linux: the ALSA device [exclusiveOutput] opens, as an mpv device name
  /// (`alsa/hw:CARD=…,DEV=…`). Empty picks the first card.
  final String exclusiveOutputDevice;
  final bool autoplay;
  final bool autoplayPersonalization;

  /// Analyze how each Library song sounds, on this device, so Autoplay picks
  /// songs that sound like the session. Off until turned on: decoding songs
  /// is heavy on low-end phones.
  final bool songAnalysis;

  /// Android: analyze the Library only while charging. The song playing is
  /// analyzed either way.
  final bool songAnalysisOnlyWhileCharging;
  final bool musicHaptics;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsSensitivity;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsStrength;
  @JsonKey(fromJson: playerCoverStyleFromJson)
  final String playerCoverStyle; // 'default' (card), 'fullscreen' or ''
  final bool landscapeLyricsArtwork;
  final bool playerLyricsPreviewHidden;
  @JsonKey(
    fromJson: playerLyricsPreviewAlignFromJson,
    toJson: lyricsAlignToJson,
  )
  final LyricsTextAlign playerLyricsPreviewAlign;
  @JsonKey(fromJson: lyricsViewAlignFromJson, toJson: lyricsAlignToJson)
  final LyricsViewAlign lyricsAlign;
  final bool lyricsLineHintShown;
  final bool autoHideLyricsControls;
  // Material: idle lyrics shrink the player to a slim bar, not hide it.
  final bool compactPlayer;
  final bool isFirstLaunch;
  final bool checkForUpdates;
  final String updateChannel;
  final String folderOrganization;
  final String folderPathTemplate;
  final bool createPlaylistFolder;
  final bool useAlbumArtistForFolders;
  final bool usePrimaryArtistOnly; // Strip featured artists from folder name
  final bool filterContributingArtistsInAlbumArtist;
  final String historyViewMode;
  final String historyFilterMode;
  @JsonKey(fromJson: librarySortModeFromJson)
  final String historySortMode;

  /// Library view opened when switching to the Library tab:
  /// 'last' (keep last used), 'all', 'albums', 'singles', or 'playlists'.
  final String defaultLibraryView;

  /// Library badge text: measured bitrate, file format, bit depth,
  /// bit depth/sample rate, or the combined bit depth/bitrate label.
  final String libraryQualityLabelMode;
  final bool autoDownloadSavedTracks;
  final bool enableLogging;
  final bool useExtensionProviders;
  final List<String>? downloadFallbackExtensionIds;
  final String? searchProvider;
  final bool searchProviderPinned;
  final String defaultSearchTab;

  /// Country of the regional tie-break of search results: `auto` (device
  /// country), `none` (global) or an ISO 3166-1 alpha-2 code.
  final String searchRegion;

  /// Whether search results use what the user follows and plays, on this
  /// device only, to break ties between equal text matches.
  final bool personalizeSearchResults;

  /// Search results on wide screens: 'list' keeps the phone rows, 'grid'
  /// shows cover grids and shelves.
  final String searchViewMode;
  final String? homeFeedProvider;
  final bool separateSingles;
  final String singleFilenameFormat;
  final String albumFolderStructure;
  @JsonKey(includeFromJson: false, includeToJson: false)
  final bool showExtensionStore;

  /// Shared-element (Hero) flights, e.g. the mini player artwork expanding
  /// into the full player. Off skips the flights entirely.
  final bool heroAnimationsEnabled;

  /// Forces the shell's backdrop blur on even when the startup runtime
  /// profile disabled it for this device tier. Off means "follow the
  /// device default".
  final bool forceBackdropBlur;
  final String
  extensionVerificationBrowserMode; // 'external_first' or 'in_app_first'
  final String locale;
  final String lyricsMode;
  final bool keepScreenOnLyrics;
  final bool motionArtworkEnabled;
  final bool canvasMobileDataEnabled;
  final bool spotifyCanvasEnabled;
  final bool playerAdaptiveFullBleed;
  final bool videoMobileDataEnabled;
  final bool listeningStatisticsEnabled;
  // Re-download a Hi-Res request at LOSSLESS when the file measures as fake.
  final bool redownloadFakeHiRes;
  final bool
  useAllFilesAccess; // Android 13+ only: enable MANAGE_EXTERNAL_STORAGE
  final bool autoExportFailedDownloads;
  final String
  downloadNetworkMode; // 'any' = WiFi + Mobile, 'wifi_only' = WiFi only
  final bool
  networkCompatibilityMode; // Try HTTP + allow invalid TLS cert for API requests
  final bool
  allowLocalNetwork; // Allow requests to private/local network targets (local proxy / custom DNS)
  final String
  songLinkRegion; // SongLink userCountry region code used for platform lookup
  final bool nativeDownloadWorkerEnabled; // Android service-owned worker
  final int
  concurrentDownloads; // Max simultaneous downloads in the Dart queue (1-3)

  final bool localLibraryEnabled;
  final String localLibraryPath;
  final String
  localLibraryBookmark; // Base64-encoded iOS security-scoped bookmark
  final bool localLibraryShowDuplicates;
  final String
  localLibraryAutoScan; // Auto-scan mode: 'off', 'on_open', 'daily', 'weekly'

  final bool hasCompletedTutorial;

  /// Version of the terms and privacy policy the person accepted; 0 when none.
  final int acceptedLegalVersion;

  /// ISO-8601 moment of that acceptance, empty when none.
  final String acceptedLegalAt;

  /// Anonymous usage counters; on unless the person turns them off.
  final bool analyticsEnabled;

  /// The last `AppInfo.whatsNewRelease` tour shown or skipped. New installs
  /// mark the current one at setup, so only updates show the tour.
  final String whatsNewSeen;

  final List<String> lyricsProviders;
  final bool
  lyricsIncludeTranslationNetease; // Append translated lyrics (Netease)
  final bool
  lyricsIncludeRomanizationNetease; // Append romanized lyrics (Netease)
  final bool
  lyricsMultiPersonWordByWord; // Enable v1/v2 + [bg:] tags for Apple/QQ syllable lyrics
  final bool
  lyricsAppleElrcWordSync; // Preserve Apple Music inline word timestamps for eLRC-capable players
  final String
  musixmatchLanguage; // Optional ISO language code for Musixmatch localized lyrics

  /// AI lyrics translation. The API key lives in secure storage, never here.
  final String lyricsAiProvider;

  /// API root of a custom OpenAI-compatible server.
  final String lyricsAiBaseUrl;

  /// Empty uses the provider's default model.
  final String lyricsAiModel;

  /// BCP-47 target language; empty follows the app language.
  final String lyricsTranslationLanguage;

  /// Optional guidance added to the translation prompt.
  final String lyricsAiInstruction;

  /// Translate lyrics without a translation as they open.
  final bool lyricsAutoTranslate;

  /// Ask the translation for a romanization of lines written outside the
  /// Latin alphabet.
  final bool lyricsAiRomanize;

  /// Align AI translations and readings to sung words instead of whole lines.
  final bool lyricsAiWordSync;

  @JsonKey(readValue: _readDuplicatesSkipped)
  final bool deduplicateDownloads;
  @JsonKey(readValue: _readQualityVariantsOff)
  final bool allowQualityVariants;

  /// "Only this quality": a download never relays to another quality class
  /// or to another provider's equivalent tier. Off by default.
  @JsonKey(readValue: _readStrictQualityOff)
  final bool strictDownloadQuality;
  final bool saveDownloadHistory;

  final String playerMode;
  final bool playerShowPronunciation;
  final bool playerBlurInactiveLyrics;
  final bool playerShowTranslation;

  /// Whether the phone Now Playing screen shows its volume slider.
  final bool playerShowVolume;

  /// Cold-start welcome video (or its fade for the other launcher icons).
  final bool startupAnimation;

  /// Plays the welcome video's audio. Off by default: the video is muted.
  final bool startupSound;

  const AppSettings({
    this.defaultService = '',
    this.playbackProviderConfirmed = false,
    // Empty means "best available": no provider-specific tier is assumed.
    this.audioQuality = '',
    this.downloadQualityByProvider = const {},
    this.downloadQualitySourceByProvider = const {},
    this.playbackQuality = 'opus',
    this.playbackQualityVersion = 2,
    this.playbackCacheBitrate = '128k',
    this.playbackPrefetchCount = 3,
    this.playbackPrefetchVersion = 3,
    this.filenameFormat = '{track:02} - {title}',
    this.downloadDirectory = '',
    this.networkDownloadFolder = '',
    this.networkDownloadLabel = '',
    this.downloadDirectoryBookmark = '',
    this.storageMode = 'app',
    this.downloadTreeUri = '',
    this.autoFallback = true,
    this.embedMetadata = true,
    this.embeddedCoverMaxDimension = 0,
    this.artistTagMode = artistTagModeJoined,
    this.metadataSeparators = const MetadataSeparators(),
    this.embedLyrics = true,
    this.embedReplayGain = false,
    this.playbackNormalization = false,
    this.playbackNormalizationPreamp = 0,
    this.playbackNormalizationMode = 'track',
    this.playOnHeadphonesConnected = false,
    this.gaplessPlayback = true,
    this.avoidBluetoothPops = true,
    this.autoMix = false,
    this.autoMixDuration = 0,
    this.autoMixEffect = AutoMixEffect.auto,
    this.autoMixSpeed = 1,
    this.autoMixPitch = 0,
    this.autoMixEcho = false,
    this.autoMixLowPass = false,
    this.discordRichPresenceEnabled = false,
    this.usbBitPerfect = false,
    this.usbDirect = false,
    this.usbDsdOverPcm = false,
    this.usbAllowFixedVolume = false,
    this.dapExclusive = false,
    this.exclusiveOutput = false,
    this.exclusiveOutputDevice = '',
    this.autoplay = false,
    this.autoplayPersonalization = true,
    this.songAnalysis = false,
    this.songAnalysisOnlyWhileCharging = true,
    this.musicHaptics = false,
    this.musicHapticsSensitivity = 0.5,
    this.musicHapticsStrength = 0.5,
    this.playerCoverStyle = '',
    this.landscapeLyricsArtwork = false,
    this.playerLyricsPreviewHidden = false,
    this.playerLyricsPreviewAlign = LyricsTextAlign.right,
    this.lyricsAlign = LyricsViewAlign.auto,
    this.lyricsLineHintShown = false,
    this.autoHideLyricsControls = true,
    this.compactPlayer = false,
    this.isFirstLaunch = true,
    this.checkForUpdates = true,
    this.updateChannel = 'stable',
    this.folderOrganization = 'none',
    this.folderPathTemplate = '{artist}/{album}',
    this.createPlaylistFolder = false,
    this.useAlbumArtistForFolders = true,
    this.usePrimaryArtistOnly = false,
    this.filterContributingArtistsInAlbumArtist = false,
    this.historyViewMode = 'grid',
    this.historyFilterMode = 'all',
    this.historySortMode = 'latest',
    this.defaultLibraryView = 'last',
    this.libraryQualityLabelMode = AppSettings.libraryQualityLabelBitDepthOnly,
    this.autoDownloadSavedTracks = false,
    this.enableLogging = false,
    this.useExtensionProviders = true,
    this.downloadFallbackExtensionIds,
    this.searchProvider,
    this.searchProviderPinned = false,
    this.defaultSearchTab = 'all',
    this.searchRegion = 'auto',
    this.personalizeSearchResults = true,
    this.searchViewMode = 'list',
    this.homeFeedProvider = homeFeedProviderOff,
    this.separateSingles = true,
    this.singleFilenameFormat = '{title}',
    this.albumFolderStructure = 'artist_album_singles',
    this.showExtensionStore = false,
    this.heroAnimationsEnabled = true,
    this.forceBackdropBlur = false,
    this.extensionVerificationBrowserMode = 'in_app_first',
    this.locale = 'system',
    this.lyricsMode = 'embed',
    this.keepScreenOnLyrics = true,
    this.motionArtworkEnabled = true,
    this.canvasMobileDataEnabled = false,
    this.spotifyCanvasEnabled = true,
    this.playerAdaptiveFullBleed = true,
    this.videoMobileDataEnabled = false,
    this.listeningStatisticsEnabled = true,
    this.redownloadFakeHiRes = false,
    this.useAllFilesAccess = false,
    this.autoExportFailedDownloads = false,
    this.downloadNetworkMode = 'any',
    this.networkCompatibilityMode = false,
    this.allowLocalNetwork = false,
    this.songLinkRegion = 'US',
    this.nativeDownloadWorkerEnabled = false,
    this.concurrentDownloads = 1,
    this.localLibraryEnabled = false,
    this.localLibraryPath = '',
    this.localLibraryBookmark = '',
    this.localLibraryShowDuplicates = true,
    this.localLibraryAutoScan = 'off',
    this.hasCompletedTutorial = false,
    this.acceptedLegalVersion = 0,
    this.acceptedLegalAt = '',
    this.analyticsEnabled = true,
    this.whatsNewSeen = '',
    this.lyricsProviders = const [
      'apple_music',
      'lrcred',
      'mornye_lyrics',
      'lyricsplus',
      'lrclib',
    ],
    this.lyricsIncludeTranslationNetease = false,
    this.lyricsIncludeRomanizationNetease = false,
    this.lyricsMultiPersonWordByWord = true,
    this.lyricsAppleElrcWordSync = true,
    this.musixmatchLanguage = '',
    this.lyricsAiProvider = 'openai',
    this.lyricsAiBaseUrl = '',
    this.lyricsAiModel = '',
    this.lyricsTranslationLanguage = '',
    this.lyricsAiInstruction = '',
    this.lyricsAutoTranslate = false,
    this.lyricsAiRomanize = true,
    this.lyricsAiWordSync = false,
    this.deduplicateDownloads = true,
    this.allowQualityVariants = false,
    this.strictDownloadQuality = false,
    this.saveDownloadHistory = true,
    this.playerMode = 'internal',
    this.playerShowPronunciation = true,
    this.playerBlurInactiveLyrics = true,
    this.playerShowTranslation = true,
    this.playerShowVolume = true,
    this.startupAnimation = true,
    this.startupSound = false,
  });

  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, dynamic> get lyricsFetchOptions => {
    'include_translation_netease': lyricsIncludeTranslationNetease,
    'include_romanization_netease': lyricsIncludeRomanizationNetease,
    'multi_person_word_by_word': lyricsMultiPersonWordByWord,
    'apple_elrc_word_sync': lyricsAppleElrcWordSync,
    'musixmatch_language': musixmatchLanguage,
  };

  /// The cover art style the player shows: the one chosen, else the app
  /// style's own, full screen in Material and a card in Mornye.
  String playerCoverStyleFor({required bool mornye}) =>
      playerCoverStyle.isNotEmpty
      ? playerCoverStyle
      : mornye
      ? 'default'
      : 'fullscreen';

  AppSettings copyWith({
    String? defaultService,
    bool? playbackProviderConfirmed,
    String? audioQuality,
    Map<String, String>? downloadQualityByProvider,
    Map<String, DownloadQualitySource>? downloadQualitySourceByProvider,
    String? playbackQuality,
    int? playbackQualityVersion,
    String? playbackCacheBitrate,
    int? playbackPrefetchCount,
    int? playbackPrefetchVersion,
    String? filenameFormat,
    String? downloadDirectory,
    String? networkDownloadFolder,
    String? networkDownloadLabel,
    String? downloadDirectoryBookmark,
    String? storageMode,
    String? downloadTreeUri,
    bool? autoFallback,
    bool? embedMetadata,
    int? embeddedCoverMaxDimension,
    String? artistTagMode,
    MetadataSeparators? metadataSeparators,
    bool? embedLyrics,
    bool? embedReplayGain,
    bool? playbackNormalization,
    double? playbackNormalizationPreamp,
    String? playbackNormalizationMode,
    bool? playOnHeadphonesConnected,
    bool? gaplessPlayback,
    bool? avoidBluetoothPops,
    bool? autoMix,
    int? autoMixDuration,
    AutoMixEffect? autoMixEffect,
    double? autoMixSpeed,
    double? autoMixPitch,
    bool? autoMixEcho,
    bool? autoMixLowPass,
    bool? discordRichPresenceEnabled,
    bool? usbBitPerfect,
    bool? usbDirect,
    bool? usbDsdOverPcm,
    bool? usbAllowFixedVolume,
    bool? dapExclusive,
    bool? exclusiveOutput,
    String? exclusiveOutputDevice,
    bool? autoplay,
    bool? autoplayPersonalization,
    bool? songAnalysis,
    bool? songAnalysisOnlyWhileCharging,
    bool? musicHaptics,
    double? musicHapticsSensitivity,
    double? musicHapticsStrength,
    String? playerCoverStyle,
    bool? landscapeLyricsArtwork,
    bool? playerLyricsPreviewHidden,
    LyricsTextAlign? playerLyricsPreviewAlign,
    LyricsViewAlign? lyricsAlign,
    bool? lyricsLineHintShown,
    bool? autoHideLyricsControls,
    bool? compactPlayer,
    bool? isFirstLaunch,
    bool? checkForUpdates,
    String? updateChannel,
    String? folderOrganization,
    String? folderPathTemplate,
    bool? createPlaylistFolder,
    bool? useAlbumArtistForFolders,
    bool? usePrimaryArtistOnly,
    bool? filterContributingArtistsInAlbumArtist,
    String? historyViewMode,
    String? historyFilterMode,
    String? historySortMode,
    String? defaultLibraryView,
    String? libraryQualityLabelMode,
    bool? autoDownloadSavedTracks,
    bool? enableLogging,
    bool? useExtensionProviders,
    List<String>? downloadFallbackExtensionIds,
    bool clearDownloadFallbackExtensionIds = false,
    String? searchProvider,
    bool? searchProviderPinned,
    bool clearSearchProvider = false,
    String? defaultSearchTab,
    String? searchRegion,
    bool? personalizeSearchResults,
    String? searchViewMode,
    String? homeFeedProvider,
    bool clearHomeFeedProvider = false,
    bool? separateSingles,
    String? singleFilenameFormat,
    String? albumFolderStructure,
    bool? showExtensionStore,
    bool? heroAnimationsEnabled,
    bool? forceBackdropBlur,
    String? extensionVerificationBrowserMode,
    String? locale,
    String? lyricsMode,
    bool? keepScreenOnLyrics,
    bool? motionArtworkEnabled,
    bool? canvasMobileDataEnabled,
    bool? spotifyCanvasEnabled,
    bool? playerAdaptiveFullBleed,
    bool? videoMobileDataEnabled,
    bool? listeningStatisticsEnabled,
    bool? redownloadFakeHiRes,
    bool? useAllFilesAccess,
    bool? autoExportFailedDownloads,
    String? downloadNetworkMode,
    bool? networkCompatibilityMode,
    bool? allowLocalNetwork,
    String? songLinkRegion,
    bool? nativeDownloadWorkerEnabled,
    int? concurrentDownloads,
    bool? localLibraryEnabled,
    String? localLibraryPath,
    String? localLibraryBookmark,
    bool? localLibraryShowDuplicates,
    String? localLibraryAutoScan,
    bool? hasCompletedTutorial,
    int? acceptedLegalVersion,
    String? acceptedLegalAt,
    bool? analyticsEnabled,
    String? whatsNewSeen,
    List<String>? lyricsProviders,
    bool? lyricsIncludeTranslationNetease,
    bool? lyricsIncludeRomanizationNetease,
    bool? lyricsMultiPersonWordByWord,
    bool? lyricsAppleElrcWordSync,
    String? musixmatchLanguage,
    String? lyricsAiProvider,
    String? lyricsAiBaseUrl,
    String? lyricsAiModel,
    String? lyricsTranslationLanguage,
    String? lyricsAiInstruction,
    bool? lyricsAutoTranslate,
    bool? lyricsAiRomanize,
    bool? lyricsAiWordSync,
    bool? deduplicateDownloads,
    bool? allowQualityVariants,
    bool? strictDownloadQuality,
    bool? saveDownloadHistory,
    String? playerMode,
    bool? playerShowPronunciation,
    bool? playerBlurInactiveLyrics,
    bool? playerShowTranslation,
    bool? playerShowVolume,
    bool? startupAnimation,
    bool? startupSound,
  }) {
    return AppSettings(
      defaultService: defaultService ?? this.defaultService,
      playbackProviderConfirmed:
          playbackProviderConfirmed ?? this.playbackProviderConfirmed,
      audioQuality: audioQuality ?? this.audioQuality,
      downloadQualityByProvider:
          downloadQualityByProvider ?? this.downloadQualityByProvider,
      downloadQualitySourceByProvider:
          downloadQualitySourceByProvider ??
          this.downloadQualitySourceByProvider,
      playbackQuality: playbackQuality ?? this.playbackQuality,
      playbackQualityVersion:
          playbackQualityVersion ?? this.playbackQualityVersion,
      playbackCacheBitrate: playbackCacheBitrate ?? this.playbackCacheBitrate,
      playbackPrefetchCount:
          playbackPrefetchCount ?? this.playbackPrefetchCount,
      playbackPrefetchVersion:
          playbackPrefetchVersion ?? this.playbackPrefetchVersion,
      filenameFormat: filenameFormat ?? this.filenameFormat,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      networkDownloadFolder:
          networkDownloadFolder ?? this.networkDownloadFolder,
      networkDownloadLabel: networkDownloadLabel ?? this.networkDownloadLabel,
      downloadDirectoryBookmark:
          downloadDirectoryBookmark ?? this.downloadDirectoryBookmark,
      storageMode: storageMode ?? this.storageMode,
      downloadTreeUri: downloadTreeUri ?? this.downloadTreeUri,
      autoFallback: autoFallback ?? this.autoFallback,
      embedMetadata: embedMetadata ?? this.embedMetadata,
      embeddedCoverMaxDimension:
          embeddedCoverMaxDimension ?? this.embeddedCoverMaxDimension,
      artistTagMode: artistTagMode ?? this.artistTagMode,
      metadataSeparators: metadataSeparators ?? this.metadataSeparators,
      embedLyrics: embedLyrics ?? this.embedLyrics,
      embedReplayGain: embedReplayGain ?? this.embedReplayGain,
      playbackNormalization:
          playbackNormalization ?? this.playbackNormalization,
      playbackNormalizationPreamp:
          playbackNormalizationPreamp ?? this.playbackNormalizationPreamp,
      playbackNormalizationMode:
          playbackNormalizationMode ?? this.playbackNormalizationMode,
      playOnHeadphonesConnected:
          playOnHeadphonesConnected ?? this.playOnHeadphonesConnected,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      avoidBluetoothPops: avoidBluetoothPops ?? this.avoidBluetoothPops,
      autoMix: autoMix ?? this.autoMix,
      autoMixDuration: autoMixDuration ?? this.autoMixDuration,
      autoMixEffect: autoMixEffect ?? this.autoMixEffect,
      autoMixSpeed: autoMixSpeed ?? this.autoMixSpeed,
      autoMixPitch: autoMixPitch ?? this.autoMixPitch,
      autoMixEcho: autoMixEcho ?? this.autoMixEcho,
      autoMixLowPass: autoMixLowPass ?? this.autoMixLowPass,
      discordRichPresenceEnabled:
          discordRichPresenceEnabled ?? this.discordRichPresenceEnabled,
      usbBitPerfect: usbBitPerfect ?? this.usbBitPerfect,
      usbDirect: usbDirect ?? this.usbDirect,
      usbDsdOverPcm: usbDsdOverPcm ?? this.usbDsdOverPcm,
      usbAllowFixedVolume: usbAllowFixedVolume ?? this.usbAllowFixedVolume,
      dapExclusive: dapExclusive ?? this.dapExclusive,
      exclusiveOutput: exclusiveOutput ?? this.exclusiveOutput,
      exclusiveOutputDevice:
          exclusiveOutputDevice ?? this.exclusiveOutputDevice,
      autoplay: autoplay ?? this.autoplay,
      autoplayPersonalization:
          autoplayPersonalization ?? this.autoplayPersonalization,
      songAnalysis: songAnalysis ?? this.songAnalysis,
      songAnalysisOnlyWhileCharging:
          songAnalysisOnlyWhileCharging ?? this.songAnalysisOnlyWhileCharging,
      musicHaptics: musicHaptics ?? this.musicHaptics,
      musicHapticsSensitivity:
          musicHapticsSensitivity ?? this.musicHapticsSensitivity,
      musicHapticsStrength: musicHapticsStrength ?? this.musicHapticsStrength,
      playerCoverStyle: playerCoverStyle ?? this.playerCoverStyle,
      landscapeLyricsArtwork:
          landscapeLyricsArtwork ?? this.landscapeLyricsArtwork,
      playerLyricsPreviewHidden:
          playerLyricsPreviewHidden ?? this.playerLyricsPreviewHidden,
      playerLyricsPreviewAlign:
          playerLyricsPreviewAlign ?? this.playerLyricsPreviewAlign,
      lyricsAlign: lyricsAlign ?? this.lyricsAlign,
      lyricsLineHintShown: lyricsLineHintShown ?? this.lyricsLineHintShown,
      autoHideLyricsControls:
          autoHideLyricsControls ?? this.autoHideLyricsControls,
      compactPlayer: compactPlayer ?? this.compactPlayer,
      isFirstLaunch: isFirstLaunch ?? this.isFirstLaunch,
      checkForUpdates: checkForUpdates ?? this.checkForUpdates,
      updateChannel: updateChannel ?? this.updateChannel,
      folderOrganization: folderOrganization ?? this.folderOrganization,
      folderPathTemplate: folderPathTemplate ?? this.folderPathTemplate,
      createPlaylistFolder: createPlaylistFolder ?? this.createPlaylistFolder,
      useAlbumArtistForFolders:
          useAlbumArtistForFolders ?? this.useAlbumArtistForFolders,
      usePrimaryArtistOnly: usePrimaryArtistOnly ?? this.usePrimaryArtistOnly,
      filterContributingArtistsInAlbumArtist:
          filterContributingArtistsInAlbumArtist ??
          this.filterContributingArtistsInAlbumArtist,
      historyViewMode: historyViewMode ?? this.historyViewMode,
      historyFilterMode: historyFilterMode ?? this.historyFilterMode,
      historySortMode: historySortMode ?? this.historySortMode,
      defaultLibraryView: defaultLibraryView ?? this.defaultLibraryView,
      libraryQualityLabelMode:
          libraryQualityLabelMode ?? this.libraryQualityLabelMode,
      autoDownloadSavedTracks:
          autoDownloadSavedTracks ?? this.autoDownloadSavedTracks,
      enableLogging: enableLogging ?? this.enableLogging,
      useExtensionProviders:
          useExtensionProviders ?? this.useExtensionProviders,
      downloadFallbackExtensionIds: clearDownloadFallbackExtensionIds
          ? null
          : (downloadFallbackExtensionIds ?? this.downloadFallbackExtensionIds),
      searchProvider: clearSearchProvider
          ? null
          : (searchProvider ?? this.searchProvider),
      searchProviderPinned: clearSearchProvider
          ? false
          : (searchProviderPinned ?? this.searchProviderPinned),
      defaultSearchTab: defaultSearchTab ?? this.defaultSearchTab,
      searchRegion: searchRegion ?? this.searchRegion,
      personalizeSearchResults:
          personalizeSearchResults ?? this.personalizeSearchResults,
      searchViewMode: searchViewMode ?? this.searchViewMode,
      homeFeedProvider: clearHomeFeedProvider
          ? null
          : (homeFeedProvider ?? this.homeFeedProvider),
      separateSingles: separateSingles ?? this.separateSingles,
      singleFilenameFormat: singleFilenameFormat ?? this.singleFilenameFormat,
      albumFolderStructure: albumFolderStructure ?? this.albumFolderStructure,
      showExtensionStore: showExtensionStore ?? this.showExtensionStore,
      heroAnimationsEnabled:
          heroAnimationsEnabled ?? this.heroAnimationsEnabled,
      forceBackdropBlur: forceBackdropBlur ?? this.forceBackdropBlur,
      extensionVerificationBrowserMode:
          extensionVerificationBrowserMode ??
          this.extensionVerificationBrowserMode,
      locale: locale ?? this.locale,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      keepScreenOnLyrics: keepScreenOnLyrics ?? this.keepScreenOnLyrics,
      motionArtworkEnabled: motionArtworkEnabled ?? this.motionArtworkEnabled,
      canvasMobileDataEnabled:
          canvasMobileDataEnabled ?? this.canvasMobileDataEnabled,
      spotifyCanvasEnabled: spotifyCanvasEnabled ?? this.spotifyCanvasEnabled,
      playerAdaptiveFullBleed:
          playerAdaptiveFullBleed ?? this.playerAdaptiveFullBleed,
      videoMobileDataEnabled:
          videoMobileDataEnabled ?? this.videoMobileDataEnabled,
      listeningStatisticsEnabled:
          listeningStatisticsEnabled ?? this.listeningStatisticsEnabled,
      redownloadFakeHiRes: redownloadFakeHiRes ?? this.redownloadFakeHiRes,
      useAllFilesAccess: useAllFilesAccess ?? this.useAllFilesAccess,
      autoExportFailedDownloads:
          autoExportFailedDownloads ?? this.autoExportFailedDownloads,
      downloadNetworkMode: downloadNetworkMode ?? this.downloadNetworkMode,
      networkCompatibilityMode:
          networkCompatibilityMode ?? this.networkCompatibilityMode,
      allowLocalNetwork: allowLocalNetwork ?? this.allowLocalNetwork,
      songLinkRegion: songLinkRegion ?? this.songLinkRegion,
      nativeDownloadWorkerEnabled:
          nativeDownloadWorkerEnabled ?? this.nativeDownloadWorkerEnabled,
      concurrentDownloads: concurrentDownloads ?? this.concurrentDownloads,
      localLibraryEnabled: localLibraryEnabled ?? this.localLibraryEnabled,
      localLibraryPath: localLibraryPath ?? this.localLibraryPath,
      localLibraryBookmark: localLibraryBookmark ?? this.localLibraryBookmark,
      localLibraryShowDuplicates:
          localLibraryShowDuplicates ?? this.localLibraryShowDuplicates,
      localLibraryAutoScan: localLibraryAutoScan ?? this.localLibraryAutoScan,
      hasCompletedTutorial: hasCompletedTutorial ?? this.hasCompletedTutorial,
      acceptedLegalVersion: acceptedLegalVersion ?? this.acceptedLegalVersion,
      acceptedLegalAt: acceptedLegalAt ?? this.acceptedLegalAt,
      analyticsEnabled: analyticsEnabled ?? this.analyticsEnabled,
      whatsNewSeen: whatsNewSeen ?? this.whatsNewSeen,
      lyricsProviders: lyricsProviders ?? this.lyricsProviders,
      lyricsIncludeTranslationNetease:
          lyricsIncludeTranslationNetease ??
          this.lyricsIncludeTranslationNetease,
      lyricsIncludeRomanizationNetease:
          lyricsIncludeRomanizationNetease ??
          this.lyricsIncludeRomanizationNetease,
      lyricsMultiPersonWordByWord:
          lyricsMultiPersonWordByWord ?? this.lyricsMultiPersonWordByWord,
      lyricsAppleElrcWordSync:
          lyricsAppleElrcWordSync ?? this.lyricsAppleElrcWordSync,
      musixmatchLanguage: musixmatchLanguage ?? this.musixmatchLanguage,
      lyricsAiProvider: lyricsAiProvider ?? this.lyricsAiProvider,
      lyricsAiBaseUrl: lyricsAiBaseUrl ?? this.lyricsAiBaseUrl,
      lyricsAiModel: lyricsAiModel ?? this.lyricsAiModel,
      lyricsTranslationLanguage:
          lyricsTranslationLanguage ?? this.lyricsTranslationLanguage,
      lyricsAiInstruction: lyricsAiInstruction ?? this.lyricsAiInstruction,
      lyricsAutoTranslate: lyricsAutoTranslate ?? this.lyricsAutoTranslate,
      lyricsAiRomanize: lyricsAiRomanize ?? this.lyricsAiRomanize,
      lyricsAiWordSync: lyricsAiWordSync ?? this.lyricsAiWordSync,
      deduplicateDownloads: deduplicateDownloads ?? this.deduplicateDownloads,
      allowQualityVariants: allowQualityVariants ?? this.allowQualityVariants,
      strictDownloadQuality:
          strictDownloadQuality ?? this.strictDownloadQuality,
      saveDownloadHistory: saveDownloadHistory ?? this.saveDownloadHistory,
      playerMode: playerMode ?? this.playerMode,
      playerShowPronunciation:
          playerShowPronunciation ?? this.playerShowPronunciation,
      playerBlurInactiveLyrics:
          playerBlurInactiveLyrics ?? this.playerBlurInactiveLyrics,
      playerShowTranslation:
          playerShowTranslation ?? this.playerShowTranslation,
      playerShowVolume: playerShowVolume ?? this.playerShowVolume,
      startupAnimation: startupAnimation ?? this.startupAnimation,
      startupSound: startupSound ?? this.startupSound,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final settings = _$AppSettingsFromJson(json);
    if (!settings.lyricsProviders.contains('spotiflac_lyrics')) {
      return settings;
    }
    return settings.copyWith(
      lyricsProviders: {
        for (final provider in settings.lyricsProviders)
          provider == 'spotiflac_lyrics' ? 'mornye_lyrics' : provider,
      }.toList(),
    );
  }
  Map<String, dynamic> toJson() => _$AppSettingsToJson(this);
}
