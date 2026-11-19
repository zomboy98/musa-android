import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_runtime.dart' show UnplayableSong;
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/verification_prompts.dart';

/// Records the precise local request for which the shell opened setup.
final playbackSetupNoticeProvider = Provider<PlaybackSetupNotice>(
  (ref) => PlaybackSetupNotice(),
);

class PlaybackSetupNotice {
  Object? handler;
  int? generation;
  String? message;

  void clear() {
    handler = null;
    generation = null;
    message = null;
  }
}

/// Receives transient playback feedback across all foreground app routes.
class PlaybackFeedback extends ConsumerStatefulWidget {
  const PlaybackFeedback({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlaybackFeedback> createState() => _PlaybackFeedbackState();
}

class _PlaybackFeedbackState extends ConsumerState<PlaybackFeedback> {
  StreamSubscription<void>? _subscription;
  StreamSubscription<UnplayableSong>? _unplayableSubscription;
  int _subscriptionRevision = 0;
  late final AppLifecycleListener _lifecycle;
  Timer? _errorTimer;
  Timer? _errorExpiry;
  VoidCallback? _pendingError;

  static const _errorDelay = Duration(milliseconds: 350);
  static const _errorLifetime = Duration(seconds: 30);

  void _clearPendingError() {
    _errorTimer?.cancel();
    _errorTimer = null;
    _errorExpiry?.cancel();
    _errorExpiry = null;
    _pendingError = null;
  }

  void _dismissError() {
    _clearPendingError();
    _errorNotice?.dismiss();
    _errorNotice = null;
  }

  void _showPendingError() {
    if (mounted &&
        _errorTimer == null &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _pendingError?.call();
    }
  }

  AppSnackBarDismissal? _errorNotice;

  /// Names the format of the song playback stopped on; that failure needs
  /// no other notice while it shows.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _formatNotice;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _showPendingError);
    ref.listenManual(activeRemotePlaybackProvider, (previous, remote) {
      if (!identical(previous, remote)) _dismissError();
    });
    ref.listenManual(
      currentMediaItemProvider.select((item) => item.value?.id),
      (_, _) => _dismissError(),
    );
    ref.listenManual(
      playbackStateProvider.select(
        (state) => (state.value?.errorMessage, state.value?.queueIndex),
      ),
      (previous, current) {
        if (!mounted) return;
        _dismissError();
        final (message, queueIndex) = current;
        if (message == null ||
            (message == previous?.$1 && queueIndex == previous?.$2) ||
            message == '$catalogFailurePrefix$failureReasonCancelled') {
          return;
        }

        final remote = ref.read(activeRemotePlaybackProvider);
        final itemId = ref.read(currentMediaItemProvider).value?.id;
        final handler = ref.read(musicPlayerRuntimeProvider).handler;
        final generation = handler?.playbackRequestGeneration;
        final age = Stopwatch()..start();
        final persistent =
            failureCauseForPlaybackError(message) ==
            FailureCause.verificationRequired;
        bool isCurrentError() {
          if (!mounted ||
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed) {
            return false;
          }
          final playback = ref.read(playbackStateProvider).value;
          final currentHandler = ref.read(musicPlayerRuntimeProvider).handler;
          final currentRemote = ref.read(activeRemotePlaybackProvider);
          if ((!persistent && age.elapsed >= _errorLifetime) ||
              _formatNotice != null ||
              playback?.errorMessage != message ||
              playback?.queueIndex != queueIndex ||
              !identical(remote, currentRemote) ||
              ref.read(currentMediaItemProvider).value?.id != itemId ||
              (remote == null &&
                  (!identical(handler, currentHandler) ||
                      generation !=
                          currentHandler?.playbackRequestGeneration))) {
            return false;
          }
          final handled = ref.read(playbackSetupNoticeProvider);
          return !(remote == null &&
              handler != null &&
              identical(handled.handler, handler) &&
              handled.generation == generation &&
              handled.message == message);
        }

        _pendingError = () {
          _clearPendingError();
          if (!isCurrentError()) return;
          final failureCause = failureCauseForPlaybackError(message);
          final dismissal = _errorNotice = AppSnackBarDismissal(
            canShow: isCurrentError,
          );
          final VerificationTarget? target = persistent
              ? resolveVerificationTarget(ref)
              : null;
          final l10n = context.l10n;
          final notice = showAppSnackBar(
            context,
            dismissal: dismissal,
            duration: persistent
                ? const Duration(hours: 1)
                : const Duration(seconds: 3),
            content: target != null
                ? VerificationNoticeBody(
                    title: target.name == null
                        ? l10n.verificationNoticeGenericTitle
                        : l10n.playbackVerificationRequiredProvider(
                            target.name!,
                          ),
                    detail: target.name == null
                        ? l10n.verificationNoticeGenericBody
                        : l10n.verificationNoticeProviderBody(target.name!),
                    actionLabel: verificationActionLabel(context, target),
                    onVerify: () =>
                        startPlaybackVerification(ref, target, queueIndex),
                  )
                : Text(
                    failureCause != null
                        ? failureMessage(l10n, failureCause)
                        : l10n.snackbarCannotOpenFile(
                            context.friendlyError(message),
                          ),
                  ),
          );
          if (!persistent) {
            _errorExpiry = Timer(_errorLifetime - age.elapsed, _dismissError);
          }
          unawaited(
            notice.closed.then((_) {
              if (identical(_errorNotice, dismissal)) {
                _clearPendingError();
                _errorNotice = null;
              }
            }),
          );
        };

        // Wait for rapid track changes, then hold the current error until the
        // app returns from the verification browser or the notice expires.
        _errorTimer = Timer(_errorDelay, () {
          _errorTimer = null;
          _showPendingError();
        });
        if (!persistent) {
          _errorExpiry = Timer(_errorLifetime, _clearPendingError);
        }
      },
    );
    ref.listenManual(musicPlayerRuntimeProvider, (previous, runtime) {
      if (previous != null &&
          !identical(previous.handler, runtime.handler) &&
          ref.read(activeRemotePlaybackProvider) == null) {
        _dismissError();
      }
      final revision = ++_subscriptionRevision;
      unawaited(_subscription?.cancel());
      _subscription = runtime.mutedPlaybackEvents.listen((_) {
        if (!mounted ||
            revision != _subscriptionRevision ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarPlaybackMuted),
        );
      });
      unawaited(_unplayableSubscription?.cancel());
      _unplayableSubscription = runtime.unplayableSongs.listen((song) {
        if (!mounted ||
            revision != _subscriptionRevision ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        _dismissError();
        final l10n = context.l10n;
        final notice = showAppSnackBar(
          context,
          content: Text(
            song.skipped
                ? l10n.snackbarPlaybackFormatUnsupportedSkipped(song.format)
                : l10n.snackbarPlaybackFormatUnsupported(song.format),
          ),
        );
        // A skipped song leaves no error; the next one may report its own.
        _formatNotice = song.skipped ? null : notice;
        unawaited(
          notice.closed.then((_) {
            if (identical(_formatNotice, notice)) _formatNotice = null;
          }),
        );
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _subscriptionRevision++;
    _lifecycle.dispose();
    _clearPendingError();
    final notice = _errorNotice;
    _errorNotice = null;
    if (notice != null) scheduleMicrotask(notice.dismiss);
    unawaited(_subscription?.cancel());
    unawaited(_unplayableSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
