import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/verification_contract.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/failure_cause.dart';

class VerificationTarget {
  const VerificationTarget({this.extensionId, this.name});

  final String? extensionId;
  final String? name;
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

VerificationTarget resolveVerificationTarget(
  WidgetRef ref, {
  String? extensionId,
  bool playback = true,
}) {
  var id = _clean(extensionId);
  if (playback) {
    Track? track;
    try {
      track = ref.read(musicPlayerRuntimeProvider).handler?.currentCatalogTrack;
    } catch (_) {}
    final block = catalogPlayback.verificationBlock.value;
    if (id == null &&
        block != null &&
        (track == null || catalogPlayback.key(track) == block.trackKey)) {
      id = _clean(block.extensionId);
    }
    if (id == null && track != null) {
      id = _clean(catalogPlayback.playingRequest(track)?.service);
    }
  }
  if (id == null) {
    try {
      id = _clean(ref.read(settingsProvider).defaultService);
    } catch (_) {}
  }
  String? name;
  if (id != null) {
    try {
      name = ref
          .read(extensionProvider)
          .extensions
          .where((ext) => ext.id.toLowerCase() == id!.toLowerCase())
          .map((ext) => ext.displayName.isNotEmpty ? ext.displayName : ext.name)
          .where((value) => value.trim().isNotEmpty)
          .firstOrNull;
    } catch (_) {}
  }
  return VerificationTarget(extensionId: id, name: name);
}

void openVerificationProviders() {
  final navigator = AppNavigationService.rootNavigatorKey.currentState;
  navigator?.push(
    MaterialPageRoute<void>(builder: (_) => const ExtensionsPage()),
  );
}

Future<void> startVerification(
  WidgetRef ref,
  VerificationTarget target, {
  VerificationOperation kind = VerificationOperation.track,
  FutureOr<void> Function()? resume,
}) async {
  final id = target.extensionId;
  if (id == null) {
    openVerificationProviders();
    return;
  }
  final facade = ref.read(interimVerificationFacadeProvider);
  final operation = facade.begin(
    extensionId: id,
    providerName: target.name ?? id,
    kind: kind,
    resume: resume ?? () {},
  );
  final outcome = await facade.verifyAndResume(operation.operationId);
  if (outcome != VerificationOutcome.resumed) {
    facade.release(operation.operationId);
  }
  if (target.name == null &&
      (outcome == VerificationOutcome.failed ||
          outcome == VerificationOutcome.expired)) {
    openVerificationProviders();
  }
}

Future<void> startPlaybackVerification(
  WidgetRef ref,
  VerificationTarget target,
  int? queueIndex,
) {
  final handler = ref.read(musicPlayerRuntimeProvider).handler;
  return startVerification(
    ref,
    target,
    resume: () {
      if (queueIndex != null) unawaited(handler?.skipToQueueItem(queueIndex));
    },
  );
}

String verificationActionLabel(
  BuildContext context,
  VerificationTarget target,
) => target.name == null
    ? context.l10n.verificationNoticeProviderAction
    : context.l10n.verificationNoticeAction;

/// Notice content whose whole surface starts the verification.
class VerificationNoticeBody extends StatefulWidget {
  const VerificationNoticeBody({
    super.key,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onVerify,
    this.actionColor,
  });

  final Color? actionColor;
  final String title;
  final String detail;
  final String actionLabel;
  final Future<void> Function() onVerify;

  @override
  State<VerificationNoticeBody> createState() => _VerificationNoticeBodyState();
}

class _VerificationNoticeBodyState extends State<VerificationNoticeBody> {
  bool _opening = false;

  Future<void> _run() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.onVerify();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final actionColor =
        widget.actionColor ??
        (context.isMornye
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.inversePrimary);
    return Semantics(
      liveRegion: true,
      child: InkWell(
        onTap: _opening ? null : _run,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title),
              const SizedBox(height: 4),
              Text(widget.detail, style: base.copyWith(fontSize: 13)),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _opening
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(context.l10n.verificationNoticeOpening),
                          ],
                        ),
                      )
                    : TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: actionColor,
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _run,
                        child: Text(widget.actionLabel),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stays over the player controls while the current song is blocked by a
/// pending verification, so a dismissed notice can always be reopened.
class PendingVerificationChip extends ConsumerStatefulWidget {
  const PendingVerificationChip({super.key});

  @override
  ConsumerState<PendingVerificationChip> createState() =>
      _PendingVerificationChipState();
}

class _PendingVerificationChipState
    extends ConsumerState<PendingVerificationChip> {
  bool _opening = false;

  Future<void> _run(VerificationTarget target, int? queueIndex) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await startPlaybackVerification(ref, target, queueIndex);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (message, queueIndex) = ref.watch(
      playbackStateProvider.select(
        (state) => (state.value?.errorMessage, state.value?.queueIndex),
      ),
    );
    if (message == null ||
        failureCauseForPlaybackError(message) !=
            FailureCause.verificationRequired) {
      return const SizedBox.shrink();
    }
    ref.watch(extensionProvider);
    final target = resolveVerificationTarget(ref);
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final label = target.name == null
        ? l10n.verificationChipLabel
        : l10n.verificationChipProviderLabel(target.name!);
    final action = _opening
        ? l10n.verificationNoticeOpening
        : verificationActionLabel(context, target);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Material(
        color: colors.secondaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          label: '$label. $action',
          excludeSemantics: true,
          child: InkWell(
            onTap: _opening ? null : () => _run(target, queueIndex),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: colors.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_opening)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    if (_opening) const SizedBox(width: 8),
                    Text(
                      action,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Search failure card whose action starts the provider verification.
class SearchVerificationCard extends ConsumerStatefulWidget {
  const SearchVerificationCard({
    super.key,
    required this.extensionId,
    required this.onResumed,
  });

  final String? extensionId;
  final VoidCallback onResumed;

  @override
  ConsumerState<SearchVerificationCard> createState() =>
      _SearchVerificationCardState();
}

class _SearchVerificationCardState
    extends ConsumerState<SearchVerificationCard> {
  @override
  Widget build(BuildContext context) {
    ref.watch(extensionProvider);
    final target = resolveVerificationTarget(
      ref,
      extensionId: widget.extensionId,
      playback: false,
    );
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final name = target.name;
    return Card(
      elevation: 0,
      color: colors.errorContainer,
      child: DefaultTextStyle(
        style: Theme.of(
          context,
        ).textTheme.bodyMedium!.copyWith(color: colors.onErrorContainer),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: VerificationNoticeBody(
            title: l10n.errorSearchVerification,
            detail: name == null
                ? l10n.verificationNoticeSearchGenericBody
                : l10n.verificationNoticeSearchBody(name),
            actionLabel: verificationActionLabel(context, target),
            actionColor: colors.onErrorContainer,
            onVerify: () => startVerification(
              ref,
              target,
              kind: VerificationOperation.other,
              resume: widget.onResumed,
            ),
          ),
        ),
      ),
    );
  }
}
