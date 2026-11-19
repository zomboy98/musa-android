import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('AppUpdateState');

enum AppUpdateStage {
  idle,
  checking,
  available,
  upToDate,
  error,
  downloading,
  readyToInstall,
  installing,
}

class AppUpdateState {
  const AppUpdateState({
    this.stage = AppUpdateStage.idle,
    this.offer,
    this.checkedAt,
    this.installedBuild,
    this.progress,
    this.checkFailed = false,
    this.bannerDismissed = false,
    this.dialogShownBuild = 0,
    this.notifiedBuild = 0,
    this.restored = false,
  });

  final AppUpdateStage stage;

  /// Last published build known, kept until this or a newer build is installed.
  final AppUpdateOffer? offer;

  /// When the last successful query finished.
  final DateTime? checkedAt;
  final int? installedBuild;

  /// 0..1 while downloading, null when not downloading.
  final double? progress;

  /// The latest query could not reach the server; [offer] is the previous one.
  final bool checkFailed;

  /// Hidden for this session only.
  final bool bannerDismissed;
  final int dialogShownBuild;
  final int notifiedBuild;
  final bool restored;

  /// Availability always comes from comparing builds, never from whether the
  /// offer was already shown.
  bool get hasOffer {
    final current = offer;
    final installed = installedBuild;
    return current != null && installed != null && current.build > installed;
  }

  bool get busy =>
      stage == AppUpdateStage.checking ||
      stage == AppUpdateStage.downloading ||
      stage == AppUpdateStage.readyToInstall ||
      stage == AppUpdateStage.installing;

  bool get showBanner => hasOffer && !bannerDismissed;

  AppUpdateState copyWith({
    AppUpdateStage? stage,
    AppUpdateOffer? offer,
    bool clearOffer = false,
    DateTime? checkedAt,
    int? installedBuild,
    double? progress,
    bool clearProgress = false,
    bool? checkFailed,
    bool? bannerDismissed,
    int? dialogShownBuild,
    int? notifiedBuild,
    bool? restored,
  }) => AppUpdateState(
    stage: stage ?? this.stage,
    offer: clearOffer ? null : offer ?? this.offer,
    checkedAt: checkedAt ?? this.checkedAt,
    installedBuild: installedBuild ?? this.installedBuild,
    progress: clearProgress ? null : progress ?? this.progress,
    checkFailed: checkFailed ?? this.checkFailed,
    bannerDismissed: bannerDismissed ?? this.bannerDismissed,
    dialogShownBuild: dialogShownBuild ?? this.dialogShownBuild,
    notifiedBuild: notifiedBuild ?? this.notifiedBuild,
    restored: restored ?? this.restored,
  );
}

final appUpdateServiceProvider = Provider<AppUpdateService>(
  (ref) => AppUpdateService(),
);

final appUpdateClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  /// Minimum gap between automatic queries (start and foreground).
  static const autoMinInterval = Duration(minutes: 15);

  /// Time since the last query before coming back to the foreground asks again.
  static const resumeMinInterval = Duration(minutes: 30);

  static const _offerKey = 'app_update_offer_v1';
  static const _checkedAtKey = 'app_update_checked_at_ms';
  static const _dialogBuildKey = 'app_update_dialog_build';
  static const _notifiedBuildKey = 'app_update_notified_build';

  late Future<void> _ready;
  DateTime? _lastAttempt;

  Future<void> get ready => _ready;

  @override
  AppUpdateState build() {
    _ready = _restore();
    return const AppUpdateState();
  }

  DateTime _now() => ref.read(appUpdateClockProvider)();

  AppUpdateService get _service => ref.read(appUpdateServiceProvider);

  Future<void> _restore() async {
    AppUpdateOffer? offer;
    DateTime? checkedAt;
    var dialogBuild = 0;
    var notifiedBuild = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_offerKey);
      if (raw != null) offer = AppUpdateOffer.fromJson(jsonDecode(raw));
      final at = prefs.getInt(_checkedAtKey);
      if (at != null) checkedAt = DateTime.fromMillisecondsSinceEpoch(at);
      dialogBuild = prefs.getInt(_dialogBuildKey) ?? 0;
      notifiedBuild = prefs.getInt(_notifiedBuildKey) ?? 0;
    } on Object catch (error) {
      _log.w('Could not restore the update state: $error');
    }
    final installed = await _service.installedBuild();
    if (!ref.mounted) return;
    final restored = state.copyWith(
      offer: offer,
      checkedAt: checkedAt,
      installedBuild: installed,
      dialogShownBuild: dialogBuild,
      notifiedBuild: notifiedBuild,
      restored: true,
    );
    state = restored.copyWith(stage: _settledStage(restored));
  }

  AppUpdateStage _settledStage(AppUpdateState value) {
    if (value.hasOffer) return AppUpdateStage.available;
    if (value.checkFailed) return AppUpdateStage.error;
    if (value.checkedAt != null && value.installedBuild != null) {
      return AppUpdateStage.upToDate;
    }
    return AppUpdateStage.idle;
  }

  /// Query when the app starts or returns to the foreground. Skipped when the
  /// last query is younger than [minAge]. Returns true when a build not known
  /// before was found.
  Future<bool> checkAutomatically({
    Duration minAge = autoMinInterval,
  }) async {
    await _ready;
    if (!ref.mounted || state.busy) return false;
    final last = _lastAttempt ?? state.checkedAt;
    if (last != null && _now().difference(last) < minAge) return false;
    return _check();
  }

  Future<bool> checkOnResume() =>
      checkAutomatically(minAge: resumeMinInterval);

  /// Always queries, whatever happened recently.
  Future<bool> checkNow() async {
    await _ready;
    if (!ref.mounted || state.busy) return false;
    return _check();
  }

  Future<bool> _check() async {
    final previous = state.offer;
    _lastAttempt = _now();
    state = state.copyWith(stage: AppUpdateStage.checking);
    final installed = await _service.installedBuild();
    final result = await _service.checkForUpdate(ignoreSnooze: true);
    if (!ref.mounted) return false;
    var next = state.copyWith(installedBuild: installed);
    switch (result.status) {
      case AppUpdateStatus.available:
      case AppUpdateStatus.snoozed:
        next = next.copyWith(
          offer: result.offer,
          checkedAt: _now(),
          checkFailed: false,
        );
        unawaited(_persistOffer(result.offer, next.checkedAt));
      case AppUpdateStatus.upToDate:
        next = next.copyWith(
          clearOffer: true,
          checkedAt: _now(),
          checkFailed: false,
        );
        unawaited(_persistOffer(null, next.checkedAt));
      case AppUpdateStatus.unavailable:
        next = next.copyWith(checkFailed: true);
    }
    state = next.copyWith(stage: _settledStage(next));
    final offer = state.offer;
    return state.hasOffer && offer != null && offer.build != previous?.build;
  }

  Future<void> _persistOffer(AppUpdateOffer? offer, DateTime? at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (offer == null) {
        await prefs.remove(_offerKey);
      } else {
        await prefs.setString(_offerKey, jsonEncode(offer.toJson()));
      }
      if (at != null) {
        await prefs.setInt(_checkedAtKey, at.millisecondsSinceEpoch);
      }
    } on Object catch (error) {
      _log.w('Could not save the update state: $error');
    }
  }

  /// Re-reads the installed build; the offer stops counting once installed.
  Future<void> refreshInstalledBuild() async {
    await _ready;
    final installed = await _service.installedBuild();
    if (!ref.mounted || installed == null) return;
    final next = state.copyWith(installedBuild: installed);
    state = state.busy ? next : next.copyWith(stage: _settledStage(next));
  }

  void dismissBanner() {
    state = state.copyWith(bannerDismissed: true);
  }

  /// The start-up dialog opens once per build.
  bool get startupDialogPending {
    final offer = state.offer;
    return state.hasOffer &&
        offer != null &&
        offer.build != state.dialogShownBuild;
  }

  /// The person has been told about the current offer (dialog or notice).
  Future<void> markOfferSeen() async {
    final offer = state.offer;
    if (offer == null) return;
    state = state.copyWith(
      dialogShownBuild: offer.build,
      notifiedBuild: offer.build,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dialogBuildKey, offer.build);
      await prefs.setInt(_notifiedBuildKey, offer.build);
    } on Object catch (error) {
      _log.w('Could not remember the announced update: $error');
    }
  }

  /// True once per build: the caller then posts the system notification.
  Future<bool> claimNotification() async {
    final offer = state.offer;
    if (!state.hasOffer ||
        offer == null ||
        offer.build == state.notifiedBuild) {
      return false;
    }
    await markOfferSeen();
    return true;
  }

  /// Download and install progress reported by the update dialog; reporting
  /// [AppUpdateStage.available] means the dialog closed.
  void reportFlow(AppUpdateStage stage, double? progress) {
    if (!ref.mounted) return;
    if (stage == AppUpdateStage.available) {
      endFlow();
      return;
    }
    state = state.copyWith(
      stage: stage,
      progress: progress,
      clearProgress: progress == null,
    );
  }

  void endFlow() {
    if (!ref.mounted) return;
    final next = state.copyWith(clearProgress: true);
    state = next.copyWith(stage: _settledStage(next));
  }
}
