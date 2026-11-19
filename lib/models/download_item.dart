import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/track.dart';

part 'download_item.g.dart';

const Object _downloadItemUnset = Object();

enum DownloadOriginKind {
  /// The album itself was downloaded.
  album,

  /// Part of a playlist or of the favorites list.
  playlist,

  /// A song downloaded on its own, including automatic saves.
  track,
}

/// What the listener asked to download: it decides whether the finished
/// files may create their own album entry in the library. Stored as `album`,
/// `track`, `playlist` or `playlist:<id>`.
class DownloadOrigin {
  const DownloadOrigin._(this.kind, [this.collectionId]);

  final DownloadOriginKind kind;

  /// The library playlist the songs belong to, when it is known.
  final String? collectionId;

  static const album = DownloadOrigin._(DownloadOriginKind.album);
  static const playlist = DownloadOrigin._(DownloadOriginKind.playlist);
  static const track = DownloadOrigin._(DownloadOriginKind.track);

  static DownloadOrigin playlistOf(String? id) => id == null || id.isEmpty
      ? playlist
      : DownloadOrigin._(DownloadOriginKind.playlist, id);

  static String? encode(DownloadOrigin? origin) => switch (origin) {
    null => null,
    DownloadOrigin(kind: DownloadOriginKind.album) => 'album',
    DownloadOrigin(kind: DownloadOriginKind.track) => 'track',
    DownloadOrigin(:final collectionId) =>
      collectionId == null ? 'playlist' : 'playlist:$collectionId',
  };

  /// Unknown or missing values read as no origin.
  static DownloadOrigin? decode(Object? value) {
    if (value is! String) return null;
    if (value == 'album') return album;
    if (value == 'track') return track;
    if (value == 'playlist') return playlist;
    if (value.startsWith('playlist:')) {
      return playlistOf(value.substring('playlist:'.length));
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadOrigin &&
      other.kind == kind &&
      other.collectionId == collectionId;

  @override
  int get hashCode => Object.hash(kind, collectionId);
}

/// The origin of a request that did not state one: a named list is a
/// playlist, several songs without a list are an album, one song is a track.
DownloadOrigin defaultDownloadOrigin({
  required String? playlistName,
  required bool multipleTracks,
}) {
  if (playlistName != null && playlistName.trim().isNotEmpty) {
    return DownloadOrigin.playlist;
  }
  return multipleTracks ? DownloadOrigin.album : DownloadOrigin.track;
}

/// Tracks that share playlist naming and album-artist normalization rules.
class DownloadQueueBatch {
  final List<Track> tracks;
  final String? playlistName;
  final List<int?>? playlistPositions;
  final DownloadOrigin? origin;

  const DownloadQueueBatch({
    required this.tracks,
    this.playlistName,
    this.playlistPositions,
    this.origin,
  });
}

enum DownloadStatus {
  queued,
  downloading,
  finalizing,
  completed,
  failed,
  skipped,
}

enum DownloadErrorType {
  unknown,
  workerFailed,
  emptyResult,
  decryptFailed,
  conversionFailed,
  libraryAddFailed,
  networkTransferFailed,
  notFound('No matching track found for this download'),
  rateLimit,
  network,
  permission,
  verificationRequired,
  subscriptionRequired('Provider subscription required'),
  expiredStream(
    'Provider stream request failed; a refreshed stream may be available',
  ),
  httpError('Provider HTTP request failed'),
  integrityFailed('Provider download failed integrity validation'),
  authenticationError('Provider authentication failed'),
  providerReauthRequired('Reconnect the provider account'),
  providerUnavailable('Provider is unavailable'),
  fileError('Provider could not write the download'),
  ispBlocked('Provider access may be blocked by the network'),
  notImplemented('Provider does not implement this download operation'),
  invalidUrl('Provider download URL is invalid'),
  providerError('Provider request failed'),
  qualityUnavailable('Requested quality unavailable from this provider'),
  transientNetwork('Provider network request failed'),
  timeout('The provider request timed out. Try again later.');

  bool get isNetworkFailure =>
      this == network || this == transientNetwork || this == timeout;

  const DownloadErrorType([this.providerMessage]);

  final String? providerMessage;
}

@JsonSerializable()
class DownloadItem {
  final String id;
  final Track track;
  final String service;
  final DownloadStatus status;
  final double progress;
  final double speedMBps;
  final int bytesReceived;
  final int bytesTotal; // Total bytes when the server provides content length
  final String? filePath;
  final String? error;
  @JsonKey(unknownEnumValue: DownloadErrorType.unknown)
  final DownloadErrorType? errorType;
  final String preparationStage;
  final DateTime createdAt;
  final String? qualityOverride;
  final String? playlistName;
  final int? playlistPosition; // 1-based position in the source playlist
  final bool fromBatch;
  final bool preserveQualityVariant;
  final String networkDownloadFolder;
  @JsonKey(fromJson: DownloadOrigin.decode, toJson: DownloadOrigin.encode)
  final DownloadOrigin? origin;

  const DownloadItem({
    required this.id,
    required this.track,
    required this.service,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.speedMBps = 0.0,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.filePath,
    this.error,
    this.errorType,
    this.preparationStage = '',
    required this.createdAt,
    this.qualityOverride,
    this.playlistName,
    this.playlistPosition,
    this.fromBatch = false,
    this.preserveQualityVariant = false,
    this.networkDownloadFolder = '',
    this.origin,
  });

  DownloadItem copyWith({
    String? id,
    Track? track,
    String? service,
    DownloadStatus? status,
    double? progress,
    double? speedMBps,
    int? bytesReceived,
    int? bytesTotal,
    Object? filePath = _downloadItemUnset,
    Object? error = _downloadItemUnset,
    Object? errorType = _downloadItemUnset,
    String? preparationStage,
    DateTime? createdAt,
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    bool? fromBatch,
    bool? preserveQualityVariant,
    String? networkDownloadFolder,
    DownloadOrigin? origin,
  }) {
    return DownloadItem(
      id: id ?? this.id,
      track: track ?? this.track,
      service: service ?? this.service,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      speedMBps: speedMBps ?? this.speedMBps,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      filePath: identical(filePath, _downloadItemUnset)
          ? this.filePath
          : filePath as String?,
      error: identical(error, _downloadItemUnset)
          ? this.error
          : error as String?,
      errorType: identical(errorType, _downloadItemUnset)
          ? this.errorType
          : errorType as DownloadErrorType?,
      preparationStage: preparationStage ?? this.preparationStage,
      createdAt: createdAt ?? this.createdAt,
      qualityOverride: qualityOverride ?? this.qualityOverride,
      playlistName: playlistName ?? this.playlistName,
      playlistPosition: playlistPosition ?? this.playlistPosition,
      fromBatch: fromBatch ?? this.fromBatch,
      preserveQualityVariant:
          preserveQualityVariant ?? this.preserveQualityVariant,
      networkDownloadFolder:
          networkDownloadFolder ?? this.networkDownloadFolder,
      origin: origin ?? this.origin,
    );
  }

  String get errorMessage {
    if (error == null) return '';

    return switch (errorType) {
      DownloadErrorType.rateLimit =>
        'Service rate limit reached. Wait before retrying.',
      DownloadErrorType.network => 'Connection failed, check your internet',
      DownloadErrorType.permission =>
        'Cannot write to folder, check storage permission',
      DownloadErrorType.verificationRequired =>
        'Verification required. Open the add-on and complete the security check.',
      _ => errorType?.providerMessage ?? error ?? 'An error occurred',
    };
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) =>
      _$DownloadItemFromJson(json);
  Map<String, dynamic> toJson() => _$DownloadItemToJson(this);
}
