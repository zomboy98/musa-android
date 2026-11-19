import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/extension_session_callback.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = AppLogger('ExtensionAuthLauncher');

const extensionVerificationGrantTimeout = Duration(minutes: 3);

// Android presents pending download verification inside MUSA by default.
// The build flag permits disabling the panel if a device needs a rollback.
const embeddedExtensionVerificationEnabled = bool.fromEnvironment(
  'MUSA_EMBEDDED_VERIFICATION',
  defaultValue: true,
);

enum ExtensionVerificationStatus { authenticated, granted, failed }

class ExtensionVerificationResult {
  const ExtensionVerificationResult(
    this.status, {
    this.lookupError,
    this.interactionShown = false,
    this.panelBusy = false,
    this.panelReleased,
  });

  /// [busy] carrying the release signal of the panel request that holds the
  /// native slot, when this isolate knows it (see [panelReleased]).
  factory ExtensionVerificationResult.busyUntil(Future<void>? released) =>
      released == null
      ? busy
      : ExtensionVerificationResult(
          ExtensionVerificationStatus.failed,
          panelBusy: true,
          panelReleased: released,
        );

  /// Failure where no panel, browser or help dialog was actually presented.
  /// Callers may fall back to another provider.
  static const failed = ExtensionVerificationResult(
    ExtensionVerificationStatus.failed,
  );

  /// Failure after the user was really shown a verification surface (closed,
  /// timed out, rejected). Callers must not query another provider on their own.
  static const failedAfterInteraction = ExtensionVerificationResult(
    ExtensionVerificationStatus.failed,
    interactionShown: true,
  );

  /// The native panel refused to open because another verification panel is
  /// already pending/visible. Nothing new was shown, but the user is busy with
  /// a verification surface, so callers must not walk other providers either.
  static const busy = ExtensionVerificationResult(
    ExtensionVerificationStatus.failed,
    panelBusy: true,
  );

  final ExtensionVerificationStatus status;
  final Object? lookupError;

  /// True once a verification surface was (or may have been) presented:
  /// a panel reply reporting it was shown, a browser/help dialog handed to the
  /// user, or a panel request still unanswered when the flow stopped (timeout
  /// or cancellation while the panel may be on screen). Merely receiving an
  /// auth URI does not count.
  final bool interactionShown;

  /// See [busy].
  final bool panelBusy;

  /// Only with [panelBusy]: completes once every verification-panel `open`
  /// request this isolate had unanswered when the busy request was dispatched
  /// has been answered, and at least one of them reported a presented panel
  /// (proof it held native's single slot, which native clears before
  /// answering). A `busy` reply never counts as a release. Null when no such
  /// request can be the holder: the slot holder is unknown to this isolate,
  /// no termination signal exists, so callers must not wait or retry. If that
  /// is only learned later, the future fails instead; consume it through
  /// [awaitVerificationPanelRelease], which then reports no release.
  final Future<void>? panelReleased;

  bool get successful => status != ExtensionVerificationStatus.failed;

  /// Whether an automatic caller must stop instead of trying another
  /// provider: only failures that were invisible to the user allow fallback.
  bool get blocksProviderFallback => interactionShown || panelBusy;
}

/// Reply of the native `com.zarz.mornye/verification_panel` `open` call.
///
/// Native answers a status string once the request is settled:
/// `granted` (callback forwarded), `closed` (panel was shown and dismissed),
/// `error` (panel was shown, then failed: blocked destination, SSL, load
/// error), `busy` (another panel is pending; nothing new shown) and
/// `unavailable` (nothing was shown). Legacy booleans/null are still accepted:
/// `true` = granted, `false` = closed, `null` = unavailable. Any other value is
/// treated as [error] so an unknown reply never enables a silent fallback.
enum VerificationPanelReply {
  granted,
  closed,
  error,
  busy,
  unavailable;

  static VerificationPanelReply parse(Object? reply) => switch (reply) {
    true || 'granted' => granted,
    false || 'closed' => closed,
    'busy' => busy,
    null || 'unavailable' => unavailable,
    _ => error,
  };

  /// The panel was actually presented to the user.
  bool get shown => this == granted || this == closed || this == error;
}

bool isExtensionVerificationRequired(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('verify_required') ||
      message.contains('verification_required') ||
      message.contains('verification required') ||
      message.contains('needsverification') ||
      message.contains('needs verification') ||
      message.contains('session is not authenticated') ||
      message.contains('signed session expired');
}

Future<T> runExtensionOperationWithVerificationRetry<T>({
  required String extensionId,
  required String browserMode,
  required Future<T> Function() operation,
  Future<bool> Function()? verify,
}) async {
  try {
    return await operation();
  } catch (error) {
    if (!isExtensionVerificationRequired(error)) rethrow;

    final verified =
        await (verify ??
            () => openVerificationAndAwaitGrant(
              extensionId,
              browserMode: browserMode,
            ))();
    if (!verified) rethrow;

    return operation();
  }
}

String? extensionIdFromVerificationError(
  Object error,
  Iterable<String> knownExtensionIds,
) {
  final idsByNormalized = <String, String>{
    for (final id in knownExtensionIds)
      if (id.trim().isNotEmpty) id.trim().toLowerCase(): id.trim(),
  };
  if (idsByNormalized.isEmpty) return null;

  final message = error.toString();
  final canonicalMatch = RegExp(
    r'''extension\s+['"]([^'"]+)['"]''',
    caseSensitive: false,
  ).firstMatch(message);
  final canonicalId = canonicalMatch?.group(1)?.trim().toLowerCase();
  if (canonicalId != null && idsByNormalized.containsKey(canonicalId)) {
    return idsByNormalized[canonicalId];
  }

  final lowerMessage = message.toLowerCase();
  final orderedIds = idsByNormalized.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final normalizedId in orderedIds) {
    if (lowerMessage.contains(normalizedId)) {
      return idsByNormalized[normalizedId];
    }
  }
  return null;
}

Future<bool> openPendingExtensionVerification(
  String extensionId, {
  Object? attempt,
  String browserMode = 'in_app_first',
  void Function(Uri authUri)? onAuthUri,
  ValueChanged<String?>? onVerificationId,
  Future<void>? cancellationSignal,
  bool Function()? canLaunch,
  void Function(ExtensionVerificationResult)? onPreflightResult,
  VoidCallback? onInteractionShown,
  ValueChanged<bool>? onPanelPending,
  bool quietUnavailable = false,
}) async {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty) return false;
  // La verificación embebida es invisible y la dispara una acción del usuario
  // (o el planificador de fondo): nunca muestra avisos ni pide confirmación.
  quietUnavailable = quietUnavailable || _usesEmbeddedVerification();

  var cancelled = false;
  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => cancelled = true));
  }
  try {
    final Map<String, dynamic>? pending;
    try {
      pending =
          await _awaitVerificationStepOrCancellation<Map<String, dynamic>?>(
            PlatformBridge.getExtensionPendingAuth(normalizedExtensionId),
            cancellationSignal,
          );
    } catch (error) {
      if (!cancelled) {
        onPreflightResult?.call(
          ExtensionVerificationResult(
            ExtensionVerificationStatus.failed,
            lookupError: error,
          ),
        );
      }
      rethrow;
    }
    if (cancelled) return false;
    final authUrl = pending?['auth_url']?.toString().trim() ?? '';
    if (authUrl.isEmpty) {
      if (pending?['authenticated'] == true) {
        onPreflightResult?.call(
          const ExtensionVerificationResult(
            ExtensionVerificationStatus.authenticated,
          ),
        );
        return false;
      }
      _log.w('No pending verification challenge for $normalizedExtensionId');
      if (!quietUnavailable) {
        showExtensionVerificationUnavailable(normalizedExtensionId);
      }
      return false;
    }

    final uri = Uri.tryParse(authUrl);
    if (uri == null) return false;
    // iOS still emits the legacy payload even when its shared Rust storage
    // has a verification identifier.
    final verificationId =
        isDesktopPlatform || defaultTargetPlatform == TargetPlatform.android
        ? (pending?['verification_id'] as String?)
        : null;
    onVerificationId?.call(verificationId);
    onAuthUri?.call(uri);

    VerificationPanelReply? panelReply;
    Future<void>? busyPanelReleased;
    final launched = await _awaitVerificationStepOrCancellation(
      _launchVerificationUrl(
        uri,
        browserMode,
        cancellationSignal: cancellationSignal,
        canLaunch: canLaunch,
        embeddedVerification: true,
        onPanelPending: onPanelPending,
        onPanelBusy: (released) => busyPanelReleased = released,
        onPanelReply: (reply) {
          panelReply = reply;
          if (reply.shown) onInteractionShown?.call();
        },
      ),
      cancellationSignal,
    );

    if (launched == null) return false;
    if (cancelled || (!launched && canLaunch?.call() == false)) return false;
    // Do not open manual browser help when the native panel is dismissed.
    if (!launched && _usesEmbeddedVerification()) {
      if (panelReply == VerificationPanelReply.busy) {
        // Another panel is on screen: no message, no fallback.
        onPreflightResult?.call(
          ExtensionVerificationResult.busyUntil(busyPanelReleased),
        );
      } else if ((panelReply == VerificationPanelReply.unavailable ||
              panelReply == VerificationPanelReply.error) &&
          !quietUnavailable) {
        showExtensionVerificationUnavailable(normalizedExtensionId);
      }
      return false;
    }

    if (launched) {
      _log.i('Opened verification challenge for $normalizedExtensionId');
      // The browser/web-auth page was handed to the OS: user-visible.
      onInteractionShown?.call();
    } else {
      _log.w(
        'Could not open verification challenge for $normalizedExtensionId',
      );
      final dialogShown = await showExtensionVerificationHelpDialog(
        normalizedExtensionId,
        uri,
        browserMode: browserMode,
        immediateFailure: true,
        cancellationSignal: cancellationSignal,
        attempt: attempt,
        verificationId: verificationId,
      );
      // The manual help dialog returns false when it could not be shown.
      if (dialogShown) onInteractionShown?.call();
      return dialogShown;
    }
    return launched;
  } catch (e) {
    _log.w(
      'Failed to open verification challenge for $normalizedExtensionId: $e',
    );
    if (!cancelled && !quietUnavailable) {
      showExtensionVerificationUnavailable(normalizedExtensionId);
    }
    return false;
  }
}

void showExtensionVerificationUnavailable(String extensionId) {
  // Con verificación embebida (Android) no se muestra nada: el planificador de
  // fondo reintenta solo. Solo se registra, sin datos sensibles.
  if (_usesEmbeddedVerification()) {
    _log.i('Verification surface unavailable; retrying in background');
    return;
  }
  final context = AppNavigationService.rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(context.l10n.extensionVerificationUnavailable(extensionId)),
      duration: const Duration(seconds: 8),
    ),
  );
}

Timer? scheduleExtensionVerificationHelpDialog(
  String extensionId,
  Uri? authUri, {
  Object? attempt,
  String? verificationId,
  String browserMode = 'in_app_first',
  Duration delay = const Duration(seconds: 20),
  Future<void>? cancellationSignal,
}) {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty || authUri == null) return null;
  // El diálogo de ayuda manual solo existe donde no hay verificación embebida.
  if (_usesEmbeddedVerification()) return null;

  return Timer(delay, () {
    unawaited(
      showExtensionVerificationHelpDialog(
        normalizedExtensionId,
        authUri,
        browserMode: browserMode,
        cancellationSignal: cancellationSignal,
        attempt: attempt,
        verificationId: verificationId,
      ),
    );
  });
}

/// Opens a pending extension verification challenge and waits (up to 3
/// minutes, including pending lookup and browser launch) for its grant result,
/// returning whether it succeeded. When
/// [cancellationSignal] completes, all local waiting resources are released
/// and the method returns false without waiting for the timeout.
///
/// [awaitForeground], if given, is awaited first — passed the trimmed
/// [extensionId] — before opening the challenge; used by callers that must
/// defer verification until the app is foregrounded (launching a browser
/// from the background is blocked by the OS).
final _verificationFlows = <String, _SharedVerificationFlow>{};

class _SharedVerificationFlow {
  _SharedVerificationFlow(this.attempt);
  final Object attempt;
  final cancellation = Completer<void>();
  final waiters = <Object>{};
  late Future<ExtensionVerificationResult> result;
}

Future<bool> openVerificationAndAwaitGrant(
  String extensionId, {
  required String browserMode,
  Future<void> Function(String extensionId)? awaitForeground,
  Future<void>? cancellationSignal,
  bool Function()? canLaunch,
}) async => (await resolveExtensionVerification(
  extensionId,
  browserMode: browserMode,
  awaitForeground: awaitForeground,
  cancellationSignal: cancellationSignal,
  canLaunch: canLaunch,
)).successful;

Future<ExtensionVerificationResult> resolveExtensionVerification(
  String extensionId, {
  required String browserMode,
  bool quietUnavailable = false,
  Future<void> Function(String extensionId)? awaitForeground,
  Future<void>? cancellationSignal,
  bool Function()? canLaunch,
}) async {
  final id = extensionId.trim();
  if (id.isEmpty) return ExtensionVerificationResult.failed;
  final key = id.toLowerCase();
  var flow = _verificationFlows[key];
  if (flow == null) {
    flow = _SharedVerificationFlow(
      PlatformBridge.beginExtensionGrantAttempt(id),
    );
    _verificationFlows[key] = flow;
    flow.result = _openVerificationAndAwaitGrant(
      id,
      browserMode: browserMode,
      awaitForeground: awaitForeground,
      cancellationSignal: flow.cancellation.future,
      canLaunch: canLaunch,
      quietUnavailable: quietUnavailable,
      attempt: flow.attempt,
    );
  }
  final waiter = Object();
  flow.waiters.add(waiter);
  try {
    return await _awaitVerificationStepOrCancellation(
          flow.result,
          cancellationSignal,
        ) ??
        ExtensionVerificationResult.failed;
  } finally {
    flow.waiters.remove(waiter);
    if (flow.waiters.isEmpty && identical(_verificationFlows[key], flow)) {
      _verificationFlows.remove(key);
      PlatformBridge.endExtensionGrantAttempt(id, flow.attempt);
      if (!flow.cancellation.isCompleted) flow.cancellation.complete();
    }
  }
}

Future<ExtensionVerificationResult> _openVerificationAndAwaitGrant(
  String extensionId, {
  required Object attempt,
  required String browserMode,
  bool quietUnavailable = false,
  Future<void> Function(String extensionId)? awaitForeground,
  Future<void>? cancellationSignal,
  bool Function()? canLaunch,
}) async {
  final normalizedExtensionId = extensionId.trim();
  if (normalizedExtensionId.isEmpty) return ExtensionVerificationResult.failed;

  if (awaitForeground != null) {
    final reachedForeground = await _awaitVerificationStepOrCancellation(
      awaitForeground(normalizedExtensionId).then((_) => true),
      cancellationSignal,
    );
    if (reachedForeground != true) return ExtensionVerificationResult.failed;
  }

  final grantCompleter = Completer<ExtensionSessionGrantEvent>();
  final challengeReady = Completer<String?>();
  String? verificationId;
  late final StreamSubscription<ExtensionSessionGrantEvent> grantSub;
  grantSub = PlatformBridge.extensionSessionGrantEvents().listen((event) async {
    final expectedId = await challengeReady.future;
    if (!grantCompleter.isCompleted &&
        PlatformBridge.extensionGrantEventMatchesAttempt(
          event,
          attempt,
          extensionId: normalizedExtensionId,
          verificationId: expectedId,
        )) {
      grantCompleter.complete(event);
    }
  });

  Uri? authUri;
  // Set only when a panel/browser/help dialog was really presented; receiving
  // an auth URI is not enough.
  var interactionShown = false;
  // True while a native panel `open` request is unanswered: the panel may be
  // on screen, so stopping the flow (timeout/cancellation) at that point is
  // conservatively treated as an interaction.
  var panelPending = false;
  ExtensionVerificationResult failure() => interactionShown || panelPending
      ? ExtensionVerificationResult.failedAfterInteraction
      : ExtensionVerificationResult.failed;
  Timer? helpDialogTimer;
  final stopped = Completer<void>();
  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }

  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => stop()));
  }
  // The browser or manual-help dialog may never return. Bound the complete
  // foreground flow, not only the grant wait reached after opening the page.
  final deadline = Timer(extensionVerificationGrantTimeout, () {
    _log.w('Timed out waiting for verification grant: $normalizedExtensionId');
    stop();
  });

  try {
    ExtensionVerificationResult? preflightResult;
    final opened = await _awaitVerificationStepOrCancellation(
      openPendingExtensionVerification(
        normalizedExtensionId,
        browserMode: browserMode,
        onAuthUri: (uri) => authUri = uri,
        onVerificationId: (id) {
          verificationId = id;
          if (!challengeReady.isCompleted) challengeReady.complete(id);
        },
        cancellationSignal: stopped.future,
        canLaunch: canLaunch,
        quietUnavailable: quietUnavailable,
        onPreflightResult: (result) => preflightResult = result,
        onInteractionShown: () => interactionShown = true,
        onPanelPending: (pending) => panelPending = pending,
        attempt: attempt,
      ),
      stopped.future,
    );
    if (stopped.isCompleted) return failure();
    if (opened != true) return preflightResult ?? failure();

    helpDialogTimer = scheduleExtensionVerificationHelpDialog(
      normalizedExtensionId,
      authUri,
      browserMode: browserMode,
      cancellationSignal: stopped.future,
      attempt: attempt,
      verificationId: verificationId,
    );

    final event = await _awaitVerificationStepOrCancellation(
      grantCompleter.future,
      stopped.future,
    );
    if (event == null) {
      _log.i('Stopped waiting for verification grant: $normalizedExtensionId');
      return failure();
    }
    return event.success
        ? const ExtensionVerificationResult(ExtensionVerificationStatus.granted)
        : failure();
  } on TimeoutException {
    _log.w('Timed out waiting for verification grant: $normalizedExtensionId');
    return failure();
  } finally {
    if (!challengeReady.isCompleted) challengeReady.complete(null);
    deadline.cancel();
    helpDialogTimer?.cancel();
    stop();
    await grantSub.cancel();
  }
}

Future<T?> _awaitVerificationStepOrCancellation<T>(
  Future<T> operation,
  Future<void>? cancellationSignal,
) {
  if (cancellationSignal == null) {
    return operation.then<T?>((value) => value);
  }
  return Future.any<T?>([
    operation.then<T?>((value) => value),
    cancellationSignal.then<T?>((_) => null),
  ]);
}

Future<bool> showExtensionVerificationHelpDialog(
  String extensionId,
  Uri authUri, {
  Object? attempt,
  String? verificationId,
  String browserMode = 'in_app_first',
  bool immediateFailure = false,
  Future<void>? cancellationSignal,
}) async {
  final context = AppNavigationService.rootNavigatorKey.currentContext;
  if (context == null) {
    _log.w('Cannot show verification help dialog without root context');
    return false;
  }

  final l10n = context.l10n;
  final title = immediateFailure
      ? l10n.extensionVerificationHelpTitleManual
      : l10n.extensionVerificationHelpTitleWaiting;
  final message = immediateFailure
      ? l10n.extensionVerificationHelpMessageManual
      : l10n.extensionVerificationHelpMessageWaiting;
  final normalizedExtensionId = extensionId.trim();
  BuildContext? activeDialogContext;
  var closeRequested = false;
  void closeDialog() {
    closeRequested = true;
    final dialogContext = activeDialogContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final route = ModalRoute.of(dialogContext);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(dialogContext, rootNavigator: true);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // A newer dialog may be above this one; dismiss only our own route.
      navigator.removeRoute(route);
    }
  }

  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => closeDialog()));
  }
  var clipboardGrantInFlight = false;
  late final StreamSubscription<ExtensionSessionGrantEvent> grantSub;
  grantSub = PlatformBridge.extensionSessionGrantEvents()
      .where(
        (event) =>
            event.success &&
            PlatformBridge.extensionGrantEventMatchesAttempt(
              event,
              attempt,
              extensionId: normalizedExtensionId,
              verificationId: verificationId,
            ),
      )
      .listen((_) {
        _log.i(
          'Closing verification help dialog after $normalizedExtensionId grant',
        );
        closeDialog();
      });

  try {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        activeDialogContext = dialogContext;
        if (closeRequested) {
          WidgetsBinding.instance.addPostFrameCallback((_) => closeDialog());
        }
        final dialogL10n = dialogContext.l10n;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AppAlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      authUri.toString(),
                      maxLines: 4,
                      minLines: 1,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              ExpressiveButton(
                text: true,
                onPressed: clipboardGrantInFlight
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: Text(dialogL10n.extensionVerificationClose),
              ),
              ExpressiveButton(
                text: true,
                icon: const Icon(Icons.copy),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () {
                        Clipboard.setData(
                          ClipboardData(text: authUri.toString()),
                        );
                        ScaffoldMessenger.maybeOf(dialogContext)?.showSnackBar(
                          SnackBar(
                            content: Text(
                              dialogL10n.extensionVerificationLinkCopied,
                            ),
                          ),
                        );
                      },
                child: Text(dialogL10n.extensionVerificationCopyLink),
              ),
              ExpressiveButton(
                text: true,
                icon: clipboardGrantInFlight
                    ? const AppLoadingIndicator(size: 18, strokeWidth: 2)
                    : const Icon(Icons.content_paste),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () async {
                        setDialogState(() => clipboardGrantInFlight = true);
                        await _completeSessionGrantFromClipboard(
                          dialogContext,
                          extensionId,
                          authUri,
                          attempt,
                          verificationId,
                        );
                        if (dialogContext.mounted) {
                          setDialogState(() => clipboardGrantInFlight = false);
                        }
                      },
                child: Text(dialogL10n.extensionVerificationPasteCallback),
              ),
              ExpressiveButton(
                icon: const Icon(Icons.open_in_browser),
                onPressed: clipboardGrantInFlight
                    ? null
                    : () {
                        unawaited(
                          _launchVerificationUrl(
                            authUri,
                            browserMode,
                            cancellationSignal: cancellationSignal,
                          ),
                        );
                      },
                child: Text(dialogL10n.extensionVerificationOpenBrowser),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    activeDialogContext = null;
    await grantSub.cancel();
  }
  return true;
}

Future<void> _completeSessionGrantFromClipboard(
  BuildContext context,
  String extensionId,
  Uri verificationUri,
  Object? attempt,
  String? verificationId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final parsed = parseExtensionSessionGrantCallback(text);
    if (parsed == null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.extensionAuthCallbackMissing)),
      );
      return;
    }

    final expectedState = extensionCallbackStateFromVerificationUri(
      verificationUri,
    );
    if (expectedState == null || parsed.state != expectedState) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.extensionAuthCallbackMismatch)),
      );
      return;
    }

    final success = await PlatformBridge.completeExtensionSessionGrant(
      extensionId.trim(),
      parsed.grant,
      attempt: attempt,
      verificationId: verificationId,
    );
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          success
              ? l10n.extensionAuthVerificationCompleted
              : l10n.extensionAuthVerificationFailed,
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          l10n.extensionAuthCallbackFailed(context.friendlyError(e)),
        ),
      ),
    );
  }
}

/// Opens an extension auth/verification page using the browser preference.
/// In-app HTTPS verification on iOS uses ASWebAuthenticationSession to capture
/// the mornye:// callback even when the app's URL scheme is not registered
/// with the OS (sideload containers like LiveContainer).
Future<bool> launchExtensionAuthUrl(Uri uri, {required String browserMode}) {
  return _launchVerificationUrl(uri, browserMode);
}

Future<bool> _launchVerificationUrl(
  Uri uri,
  String browserMode, {
  Future<void>? cancellationSignal,
  bool Function()? canLaunch,
  bool embeddedVerification = false,
  ValueChanged<bool>? onPanelPending,
  ValueChanged<VerificationPanelReply>? onPanelReply,
  ValueChanged<Future<void>?>? onPanelBusy,
}) async {
  var cancelled = false;
  if (cancellationSignal != null) {
    unawaited(cancellationSignal.then((_) => cancelled = true));
  }
  if (embeddedVerification && _usesEmbeddedVerification()) {
    if (cancelled || canLaunch?.call() == false) return false;
    const channel = MethodChannel('com.zarz.mornye/verification_panel');
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    var active = true;
    if (cancellationSignal != null) {
      unawaited(
        cancellationSignal.then((_) async {
          if (!active) return;
          try {
            await channel.invokeMethod<void>('close', {'id': id});
          } on PlatformException {
            // The panel may already have finished; never log auth data.
          } on MissingPluginException {
            // The activity may already have been destroyed.
          }
        }),
      );
    }
    // Only requests still unanswered at this dispatch can hold the slot that
    // would make this one `busy` (native handles `open` in dispatch order).
    final holderCandidates = List.of(_panelOpenRequestsInFlight);
    final request = _PanelOpenRequest();
    _panelOpenRequestsInFlight.add(request);
    // From dispatch until the reply the panel may already be visible; callers
    // that stop waiting in between must assume it was shown.
    onPanelPending?.call(true);
    var reply = VerificationPanelReply.unavailable;
    try {
      reply = VerificationPanelReply.parse(
        await channel.invokeMethod<Object?>('open', {
          'id': id,
          'url': uri.toString(),
        }),
      );
    } on PlatformException {
      // The request was rejected before any activity was started.
      reply = VerificationPanelReply.unavailable;
    } on MissingPluginException {
      reply = VerificationPanelReply.unavailable;
    } finally {
      active = false;
      _panelOpenRequestsInFlight.remove(request);
      // Only a reply reporting a presented panel proves this request held the
      // native slot; `busy`/`unavailable` replies never held it.
      request.settle(heldSlot: reply.shown);
    }
    if (reply == VerificationPanelReply.busy) {
      onPanelBusy?.call(_busyPanelReleaseSignal(holderCandidates));
    }
    // Report the outcome before clearing the pending state so the
    // conservative "possibly shown" window never has a gap.
    onPanelReply?.call(reply);
    onPanelPending?.call(false);
    return reply == VerificationPanelReply.granted;
  }
  // Desktop has no in-app browser or web auth session: the system browser
  // opens the page and returns through the registered mornye:// scheme
  // (DesktopDeepLinks hands the callback to the backend).
  if (isDesktopPlatform) {
    if (cancelled || canLaunch?.call() == false) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException catch (error) {
      _log.w('Verification browser launch failed: ${error.code}');
      return false;
    }
  }

  final preferInApp = browserMode.trim().toLowerCase() == 'in_app_first';
  final firstMode = preferInApp
      ? LaunchMode.inAppBrowserView
      : LaunchMode.externalApplication;
  final fallbackMode = preferInApp
      ? LaunchMode.externalApplication
      : LaunchMode.inAppBrowserView;

  for (final mode in [firstMode, fallbackMode]) {
    if (cancelled || canLaunch?.call() == false) return false;
    if (mode == LaunchMode.inAppBrowserView &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        uri.scheme == 'https') {
      try {
        if (await PlatformBridge.startIosWebAuthSession(uri.toString())) {
          return true;
        }
        _log.w('Web auth session did not start, falling back to browser');
      } catch (e) {
        _log.w('Web auth session failed, falling back to browser: $e');
      }
      if (cancelled || canLaunch?.call() == false) return false;
    }
    try {
      if (await launchUrl(uri, mode: mode)) return true;
    } on PlatformException catch (error) {
      // Android reports some launch failures as exceptions rather than false.
      // Keep the other mode and manual verification help available in both cases.
      _log.w(
        'Verification browser launch failed (${mode.name}): ${error.code}',
      );
    }
  }
  return false;
}

// Native keeps one pending panel request and answers `busy` while it exists,
// without saying which request holds that slot. Native handles `open` calls
// in dispatch order and clears the slot before answering its holder, so the
// holder of a busy request R is either a request this isolate dispatched
// earlier and had not yet seen answered when R was dispatched, or a request
// unknown to this isolate. Only a reply reporting a presented panel proves its
// request held the slot: a `busy` reply proves nothing about ownership and
// must never count as a release (two concurrent `busy` replies behind an
// unknown holder would otherwise signal each other's "release").
final _panelOpenRequestsInFlight = <_PanelOpenRequest>{};

class _PanelOpenRequest {
  final _settled = Completer<bool>();
  bool? _heldSlot;

  /// Null while unanswered; then whether this request held the native slot.
  bool? get heldSlot => _heldSlot;

  /// Completes with [heldSlot] once native answered this request.
  Future<bool> get settled => _settled.future;

  void settle({required bool heldSlot}) {
    _heldSlot = heldSlot;
    _settled.complete(heldSlot);
  }
}

/// Thrown into a pending [ExtensionVerificationResult.panelReleased] when every
/// candidate turned out not to hold the slot: the holder is unknown and no
/// release signal exists.
class _PanelHolderUnknown implements Exception {
  const _PanelHolderUnknown();
}

/// Release signal for a `busy` reply, given the requests of this isolate that
/// were unanswered when the busy request was dispatched (the only possible
/// known holders). Once all of them are answered, the slot is free iff at
/// least one of them really held it; if none did, the holder is unknown to
/// this isolate (another engine, or nothing known at all) and there is no
/// signal: null when that is already decided, otherwise the returned future
/// fails with [_PanelHolderUnknown] (handled by
/// [awaitVerificationPanelRelease]).
Future<void>? _busyPanelReleaseSignal(List<_PanelOpenRequest> candidates) {
  if (candidates.isEmpty) return null;
  if (candidates.every((c) => c.heldSlot != null)) {
    return candidates.any((c) => c.heldSlot == true)
        ? Future<void>.value()
        : null;
  }
  final released = Completer<void>();
  unawaited(
    Future.wait([for (final c in candidates) c.settled]).then((held) {
      if (held.contains(true)) {
        released.complete();
      } else {
        released.completeError(const _PanelHolderUnknown());
      }
    }),
  );
  // Nobody may be listening when the holder turns out unknown.
  released.future.ignore();
  return released.future;
}

/// Waits, without polling, until the verification panel that made [result]
/// busy has ended (see [ExtensionVerificationResult.panelReleased]).
///
/// Returns false immediately when [result] is not a busy result with a known
/// release signal, and returns false as soon as [cancellationSignal]
/// completes or [timeout] elapses. Returns true only when the panel ended
/// first; the caller decides whether a new challenge is still wanted.
Future<bool> awaitVerificationPanelRelease(
  ExtensionVerificationResult result, {
  Future<void>? cancellationSignal,
  Duration timeout = extensionVerificationGrantTimeout,
}) async {
  final released = result.panelReleased;
  if (!result.panelBusy || released == null) return false;
  final outcome = Completer<bool>();
  var cancelled = false;
  void finish(bool value) {
    if (!outcome.isCompleted) outcome.complete(value);
  }

  // Cancellation is registered first so it wins a same-turn race.
  if (cancellationSignal != null) {
    unawaited(
      cancellationSignal.then((_) {
        cancelled = true;
        finish(false);
      }),
    );
  }
  final deadline = Timer(timeout, () => finish(false));
  // A failed signal means the holder turned out unknown: nothing was released.
  unawaited(
    released.then<void>(
      (_) => finish(true),
      onError: (Object error, StackTrace stackTrace) => finish(false),
    ),
  );
  try {
    final panelEnded = await outcome.future;
    // A cancellation that completed by now wins even when the release listener
    // ran first (e.g. the signal is derived and settles a microtask later):
    // the resumption above leaves its listener a turn to set the flag.
    return panelEnded && !cancelled;
  } finally {
    deadline.cancel();
  }
}

bool _usesEmbeddedVerification() =>
    embeddedExtensionVerificationEnabled &&
    !isDesktopPlatform &&
    defaultTargetPlatform == TargetPlatform.android;

/// True cuando la verificación es embebida e invisible (Android): ninguna
/// pantalla, diálogo ni aviso debe depender de ella y las acciones del usuario
/// (buscar, reproducir, descargar, navegar) nunca la esperan en pantalla.
bool get extensionVerificationIsSilent => _usesEmbeddedVerification();

/// Obtiene sesión para una acción que el usuario ya inició (p. ej. autocompletar
/// metadatos) en plataformas sin verificación embebida (escritorio/iOS). En
/// Android no se usa: ahí solo actúa el planificador de fondo.
Future<bool> ensureExtensionSessionForUserAction(
  String extensionId, {
  required String browserMode,
}) => openVerificationAndAwaitGrant(extensionId, browserMode: browserMode);
