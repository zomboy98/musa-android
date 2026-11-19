import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/provider_retry_policy.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SpecialQualityStatus { confirmed, checking, unavailable, unknown }

const _confirmedTtl = Duration(days: 90);
const _unavailableTtl = Duration(days: 30);
const _probeTimeout = Duration(seconds: 4);
const _probeQueueWait = Duration(seconds: 15);
const atmosCapableProviders = {'tidal', 'amazon'};
const _probeRetry = Duration(minutes: 2);
const _fileName = 'special_quality_availability.json';

String? normalizeAvailabilityProvider(String? raw) {
  final first = (raw ?? '')
      .trim()
      .toLowerCase()
      .split(RegExp(r'[-_.\s]'))
      .where((part) => part.isNotEmpty)
      .firstOrNull;
  if (first == null) return null;
  return first == 'amzn' ? 'amazon' : first;
}

bool isSpatialQualityId(String id) {
  final text = id.toLowerCase();
  return const ['atmos', 'eac3', 'ac4', 'spatial'].any(text.contains);
}

bool downloadQualityRelayAllowed({
  required bool strict,
  String? qualityOverride,
}) =>
    !strict &&
    !(qualityOverride != null && isSpatialQualityId(qualityOverride));

bool spatialCodecIsDolby(String? codec) =>
    codec != null && codec.trim().isNotEmpty && isDolbyCodec(codec);

class SpecialQualityAvailability extends ChangeNotifier {
  SpecialQualityAvailability({
    DateTime Function()? clock,
    Future<Directory> Function()? directory,
    Future<Map<String, dynamic>> Function(String, String, String)? loadMetadata,
    this.probeEnabled = true,
    this.retryPolicy,
    this.resolveNativeId,
    ProviderRequestGate? gate,
    ProviderCooldown? cooldown,
  }) : _gate = gate,
       _cooldown = cooldown,
       _clock = clock ?? DateTime.now,
       _directory = directory ?? getApplicationSupportDirectory,
       _loadMetadata = loadMetadata ?? PlatformBridge.getProviderMetadata;

  static final SpecialQualityAvailability instance =
      SpecialQualityAvailability();

  final DateTime Function() _clock;
  final Future<Directory> Function() _directory;
  final Future<Map<String, dynamic>> Function(String, String, String)
  _loadMetadata;
  final bool probeEnabled;
  ProviderRetryPolicy? retryPolicy;
  Future<String?> Function(Track track, String providerId)? resolveNativeId;
  final ProviderRequestGate? _gate;
  final ProviderCooldown? _cooldown;

  final Map<String, ({bool confirmed, DateTime checkedAt})> _learned = {};
  final Set<String> _probing = {};
  final Set<String> _probedWithoutProof = {};
  final Map<String, DateTime> _probeFailedAt = {};
  final Map<String, DateTime> _attemptFailedAt = {};
  Future<void>? _loading;
  Future<void> _writing = Future.value();

  Duration get confirmedTtl => _confirmedTtl;
  Duration get unavailableTtl => _unavailableTtl;

  String? _identity(Track track) {
    final isrc = (track.isrc ?? '').trim().toUpperCase();
    if (isrc.isNotEmpty) return isrc;
    final id = track.id.trim();
    return id.isEmpty ? null : 'id:$id';
  }

  List<String> _lookupKeys(Track track, String provider) {
    final isrc = (track.isrc ?? '').trim().toUpperCase();
    final id = track.id.trim();
    return [
      if (isrc.isNotEmpty) '$provider|$isrc',
      if (id.isNotEmpty) '$provider|id:$id',
    ];
  }

  String? _providerFor(Track? track, String? service) =>
      normalizeAvailabilityProvider(service) ??
      normalizeAvailabilityProvider(track?.source);

  bool _metadataBelongsTo(Track track, String provider) {
    final source = normalizeAvailabilityProvider(track.source);
    return source == null || source == provider;
  }

  bool _fresh(({bool confirmed, DateTime checkedAt}) entry) {
    final ttl = entry.confirmed ? _confirmedTtl : _unavailableTtl;
    return _clock().difference(entry.checkedAt) < ttl;
  }

  ({bool confirmed, DateTime checkedAt})? _learnedFor(
    Track track,
    String provider,
  ) {
    ({bool confirmed, DateTime checkedAt})? found;
    for (final key in _lookupKeys(track, provider)) {
      final entry = _learned[key];
      if (entry == null || !_fresh(entry)) continue;
      if (found == null || entry.checkedAt.isAfter(found.checkedAt)) {
        found = entry;
      }
    }
    return found;
  }

  bool isAtmosConfirmed(Track track, String? service) {
    final provider = _providerFor(track, service);
    final learned = provider == null ? null : _learnedFor(track, provider);
    if (learned != null) return learned.confirmed;
    final belongs = provider == null || _metadataBelongsTo(track, provider);
    return belongs && track.isDolbyAtmos;
  }

  bool _hasCrossIdentity(Track track) {
    if ((track.isrc ?? '').trim().isNotEmpty) return true;
    return track.name.trim().isNotEmpty &&
        track.artistName.trim().isNotEmpty &&
        track.duration > 0;
  }

  bool probeEligible(Track track, String? service) {
    final provider = _providerFor(track, service);
    if (provider == null || !atmosCapableProviders.contains(provider)) {
      return false;
    }
    if (_metadataBelongsTo(track, provider)) {
      return track.id.trim().isNotEmpty;
    }
    return resolveNativeId != null && _hasCrossIdentity(track);
  }

  bool providerResting(String providerId, Track track) {
    final cooldown = _cooldown ?? ProviderCooldown.instance;
    if (cooldown.isCoolingDown(providerId)) return true;
    final key = _identity(track);
    final policy = retryPolicy;
    return key != null &&
        policy != null &&
        policy.blockedFor(providerId, key) > Duration.zero;
  }

  SpecialQualityStatus atmosStatus(Track? track, String? service) {
    if (track == null) return SpecialQualityStatus.unknown;
    unawaited(ensureLoaded());
    final provider = _providerFor(track, service);
    final learned = provider == null ? null : _learnedFor(track, provider);
    if (learned != null && learned.confirmed) {
      return SpecialQualityStatus.confirmed;
    }
    if (learned != null) return SpecialQualityStatus.unavailable;
    final belongs = provider == null || _metadataBelongsTo(track, provider);
    if (belongs && track.isDolbyAtmos) return SpecialQualityStatus.confirmed;
    final modes = track.audioModes?.trim() ?? '';
    if (belongs && modes.isNotEmpty) return SpecialQualityStatus.unavailable;
    if (provider == null || !probeEnabled || !probeEligible(track, service)) {
      return SpecialQualityStatus.unknown;
    }
    final id = _identity(track);
    if (id == null) return SpecialQualityStatus.unknown;
    final probeKey = '$provider|$id';
    if (_probing.contains(probeKey)) return SpecialQualityStatus.checking;
    if (_probedWithoutProof.contains(probeKey)) {
      return SpecialQualityStatus.unknown;
    }
    final failed = _probeFailedAt[probeKey];
    if (failed != null && _clock().difference(failed) < _probeRetry) {
      return SpecialQualityStatus.unknown;
    }
    final providerId = service ?? track.source ?? provider;
    if (providerResting(providerId, track)) return SpecialQualityStatus.unknown;
    unawaited(_probe(track, providerId, provider));
    return SpecialQualityStatus.checking;
  }

  Future<Map<String, dynamic>> _gatedLoad(
    String providerId,
    String nativeId,
  ) {
    final cancel = Completer<void>();
    final timer = Timer(_probeQueueWait + _probeTimeout, () {
      if (!cancel.isCompleted) cancel.complete();
    });
    return (_gate ?? ProviderRequestGate.instance)
        .run<Map<String, dynamic>>(
          () => _loadMetadata(
            providerId,
            'track',
            nativeId,
          ).timeout(_probeTimeout),
          priority: ProviderRequestPriority.queue,
          cancelled: cancel.future,
          maxTurn: _probeTimeout + const Duration(seconds: 2),
        )
        .whenComplete(timer.cancel);
  }

  Future<void> _probe(Track track, String providerId, String provider) async {
    final id = _identity(track);
    if (id == null) return;
    final probeKey = '$provider|$id';
    if (!_probing.add(probeKey)) return;
    final policy = retryPolicy;
    var attempted = false;
    try {
      await ensureLoaded();
      var nativeId = track.id;
      if (!_metadataBelongsTo(track, provider)) {
        final resolver = resolveNativeId;
        final resolved = resolver == null
            ? null
            : await resolver(track, providerId).timeout(_probeQueueWait);
        if (resolved == null || resolved.trim().isEmpty) {
          throw StateError('no equivalent');
        }
        nativeId = resolved;
      }
      if (providerResting(providerId, track)) throw StateError('resting');
      attempted = true;
      policy?.recordAttempt(providerId, id);
      await policy?.spaceRequest(providerId);
      final response = await _gatedLoad(providerId, nativeId);
      final data = response['track'];
      if (data is! Map) throw StateError('no track');
      final modes = data['audio_modes']?.toString() ?? '';
      if (modes.toUpperCase().contains('DOLBY_ATMOS')) {
        _record(track, provider, confirmed: true);
      } else if (provider == 'tidal' &&
          _sameNativeId(data['id']?.toString(), nativeId)) {
        _record(track, provider, confirmed: false);
      } else {
        _probedWithoutProof.add(probeKey);
      }
      policy?.recordSuccess(providerId, id);
    } on Object {
      _probeFailedAt[probeKey] = _clock();
      if (attempted) policy?.recordFailure(providerId, id);
    } finally {
      _probing.remove(probeKey);
      notifyListeners();
    }
  }

  static String _nativeIdCore(String? raw) {
    final text = (raw ?? '').trim().toLowerCase();
    final cut = text.lastIndexOf(':');
    return cut < 0 ? text : text.substring(cut + 1);
  }

  bool _sameNativeId(String? answered, String asked) {
    final left = _nativeIdCore(answered);
    return left.isNotEmpty && left == _nativeIdCore(asked);
  }

  void _record(Track track, String provider, {required bool confirmed}) {
    final key = _lookupKeys(track, provider).firstOrNull;
    if (key == null) return;
    _learned[key] = (confirmed: confirmed, checkedAt: _clock());
    unawaited(_persist());
  }

  String? _attemptKey(Track track, String? service, String qualityId) {
    final provider = _providerFor(track, service);
    final identity = _identity(track);
    final quality = qualityId.trim().toLowerCase();
    if (provider == null || identity == null || quality.isEmpty) return null;
    return '$provider|$identity|$quality';
  }

  /// Remembers, for this run only, that asking [service] for [qualityId] failed
  /// last time. It never hides the format: the song can be asked again.
  void noteAttemptFailed(Track track, String? service, String qualityId) {
    final key = _attemptKey(track, service, qualityId);
    if (key == null) return;
    _attemptFailedAt[key] = _clock();
    notifyListeners();
  }

  void clearAttemptFailure(Track track, String? service, String qualityId) {
    final key = _attemptKey(track, service, qualityId);
    if (key == null || _attemptFailedAt.remove(key) == null) return;
    notifyListeners();
  }

  bool attemptFailed(Track? track, String? service, String qualityId) {
    if (track == null) return false;
    final key = _attemptKey(track, service, qualityId);
    return key != null && _attemptFailedAt.containsKey(key);
  }

  void markConfirmed(Track track, String? service) {
    final provider = _providerFor(track, service);
    if (provider == null) return;
    _record(track, provider, confirmed: true);
    notifyListeners();
  }

  void markUnavailable(Track track, String? service) {
    final provider = _providerFor(track, service);
    if (provider == null) return;
    _record(track, provider, confirmed: false);
    notifyListeners();
  }

  void recordPlayback({
    required Track track,
    required String requestedService,
    required String requestedQuality,
    required Map<String, Object> metadata,
    bool failureWasUnavailability = true,
  }) {
    final codec = metadata['output_codec']?.toString() ?? '';
    final served = normalizeAvailabilityProvider(
      metadata['provider']?.toString(),
    );
    final asked =
        normalizeAvailabilityProvider(requestedService) ??
        served ??
        normalizeAvailabilityProvider(track.source);
    if (spatialCodecIsDolby(codec)) {
      final provider = served ?? asked;
      if (provider != null) {
        _record(track, provider, confirmed: true);
        notifyListeners();
      }
      return;
    }
    if (!isSpatialQualityId(requestedQuality) || asked == null) return;
    final fellBack = metadata['quality_fallback_used'] == true;
    if ((fellBack || codec.isNotEmpty) && failureWasUnavailability) {
      noteAttemptFailed(track, asked, requestedQuality);
    }
  }

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<File> _file() async =>
      File(p.join((await _directory()).path, _fileName));

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final state = value['atmos'];
        final at = DateTime.tryParse('${value['checkedAt']}');
        if (at == null || (state != 'confirmed' && state != 'unavailable')) {
          continue;
        }
        if (state == 'unavailable' && value['proof'] != 'catalog') continue;
        final current = _learned[entry.key as String];
        if (current != null && current.checkedAt.isAfter(at)) continue;
        final item = (confirmed: state == 'confirmed', checkedAt: at);
        if (_fresh(item)) _learned[entry.key as String] = item;
      }
      notifyListeners();
    } on Object {
      return;
    }
  }

  Future<void> _persist() {
    final next = _writing.then((_) async {
      try {
        await ensureLoaded();
        final file = await _file();
        await file.parent.create(recursive: true);
        final data = {
          for (final entry in _learned.entries)
            if (_fresh(entry.value))
              entry.key: {
                'atmos': entry.value.confirmed ? 'confirmed' : 'unavailable',
                if (!entry.value.confirmed) 'proof': 'catalog',
                'checkedAt': entry.value.checkedAt.toIso8601String(),
              },
        };
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(jsonEncode(data), flush: true);
        await temp.rename(file.path);
      } on Object {
        return;
      }
    });
    _writing = next;
    return next;
  }

  Future<void> flush() => _writing;
}
