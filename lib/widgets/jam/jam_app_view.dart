import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:flutter/services.dart';

import '../../services/jam/jam_app_controller.dart';
import '../../services/jam/jam_invitation_codec.dart';
import '../../services/jam/jam_network_address.dart';
import '../../services/jam/jam_queue.dart';
import '../../services/playable_media.dart';

/// A session surface. The caller owns and disposes [controller].
class JamAppView extends StatefulWidget {
  const JamAppView({
    super.key,
    required this.controller,
    this.trackTitle,
    this.now,
    this.selectTrack,
    this.selectHostMedia,
  });
  final JamAppController controller;
  final String? Function(String trackId)? trackTitle;
  final DateTime Function()? now;

  /// Returns a session-shareable track ID chosen by the caller's library UI.
  final Future<String?> Function(BuildContext context)? selectTrack;
  final Future<PlayableMedia?> Function(BuildContext context)? selectHostMedia;

  @override
  State<JamAppView> createState() => _JamAppViewState();
}

class _JamAppViewState extends State<JamAppView> {
  final _address = TextEditingController();
  final _invitation = TextEditingController();
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    _invitation.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message =
              error is StateError && error.message == 'Too many pairing grants'
              ? context.l10n.jamTooManyInvitations
              : context.l10n.jamActionFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showOutcome(JamOutcome result) {
    if (result != JamOutcome.applied &&
        result != JamOutcome.duplicate &&
        mounted) {
      setState(
        () => _message = switch (result) {
          JamOutcome.conflict => context.l10n.jamQueueChanged,
          JamOutcome.forbidden => context.l10n.jamForbidden,
          JamOutcome.capacity => context.l10n.jamCapacity,
          JamOutcome.unavailable => context.l10n.jamHostLacksSong,
          JamOutcome.currentPlaying => context.l10n.jamCannotRemoveCurrent,
          _ => context.l10n.jamChangeFailed,
        },
      );
    }
  }

  Future<void> _command(Future<JamOutcome> Function() action) =>
      _run(() async => _showOutcome(await action()));

  Future<void> _remove(String occurrenceId, int revision, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.jamRemoveFromQueue),
        content: Text(context.l10n.jamRemoveConfirm(title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.dialogRemove),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _command(
        () => widget.controller.remove(
          occurrenceId: occurrenceId,
          revision: revision,
        ),
      );
    }
  }

  Future<void> _selectTrack(int revision) => _run(() async {
    final controller = widget.controller;
    final generation = controller.sessionGeneration;
    final phase = controller.phase;
    if (phase == JamAppPhase.hosting && widget.selectHostMedia != null) {
      final media = await widget.selectHostMedia!(context);
      if (media == null ||
          !mounted ||
          !identical(widget.controller, controller) ||
          controller.sessionGeneration != generation ||
          controller.phase != phase) {
        return;
      }
      _showOutcome((await controller.addHostMedia(media)).outcome);
      return;
    }
    final id = await widget.selectTrack?.call(context);
    if (id == null ||
        id.isEmpty ||
        !mounted ||
        !identical(widget.controller, controller) ||
        controller.sessionGeneration != generation ||
        controller.phase != phase) {
      return;
    }
    if (controller.snapshot?.revision != revision) {
      _showOutcome(JamOutcome.conflict);
      return;
    }
    _showOutcome(await controller.add(trackId: id, revision: revision));
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final active =
          c.phase == JamAppPhase.hosting || c.phase == JamAppPhase.connected;
      final pending =
          _busy ||
          c.phase == JamAppPhase.starting ||
          c.phase == JamAppPhase.pairing ||
          c.phase == JamAppPhase.closing;
      final snapshot = c.snapshot;
      final isHost = c.phase == JamAppPhase.hosting;
      final canEdit = isHost || (snapshot?.guestEditingEnabled ?? false);
      final colors = Theme.of(context).colorScheme;
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Jam', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          Text(
            context.l10n.jamShareQueueLocal,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          if (_message != null || c.error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _message ?? context.l10n.jamActionFailed,
                  style: TextStyle(color: colors.error),
                ),
              ),
            ),
          if (active && c.playbackError != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  context.l10n.jamPlayerSyncFailed,
                  style: TextStyle(color: colors.error),
                ),
              ),
            ),
          if (isHost && c.unavailablePlaybackOccurrences.isNotEmpty)
            Semantics(
              liveRegion: true,
              child: Text(context.l10n.jamSongsUnavailableOnHost),
            ),
          if (!active) ...[
            Text(
              context.l10n.jamCreateSession,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(context.l10n.jamEnterLocalIpv4),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              enabled: !pending,
              decoration: InputDecoration(
                labelText: context.l10n.jamLocalIpv4Label,
                hintText: '192.168.1.2',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: pending
                  ? null
                  : () {
                      final address = InternetAddress.tryParse(
                        _address.text.trim(),
                      );
                      if (address == null || !isJamAddress(address)) {
                        setState(() => _message = context.l10n.jamInvalidIpv4);
                        return;
                      }
                      _run(() => c.startHosting(address: address));
                    },
              child: Text(context.l10n.jamCreateSession),
            ),
            const SizedBox(height: 32),
            Text(
              context.l10n.jamJoinSession,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(context.l10n.jamPasteInvitation),
            const SizedBox(height: 12),
            TextField(
              controller: _invitation,
              enabled: !pending,
              maxLines: 3,
              maxLength: JamInvitationCodec.maxEncodedLength,
              decoration: InputDecoration(
                labelText: context.l10n.jamInvitation,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: pending
                  ? null
                  : () {
                      try {
                        final invitation = JamInvitationCodec.decode(
                          _invitation.text.trim(),
                        );
                        _invitation.clear();
                        _run(() => c.join(invitation));
                      } on FormatException {
                        setState(
                          () => _message = context.l10n.jamInvitationInvalid,
                        );
                      }
                    },
              child: Text(context.l10n.jamJoin),
            ),
          ] else ...[
            Text(
              isHost ? context.l10n.jamHost : context.l10n.jamGuest,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (isHost) ...[
              const SizedBox(height: 16),
              _InvitationCard(
                invitation: c.invitation,
                expiresAt: c.invitationExpiresAt,
                pending: pending,
                now: widget.now ?? DateTime.now,
                onGenerate: () => _run(() async => c.renewInvitation()),
              ),
            ],
            if (snapshot != null) ...[
              if (isHost)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.jamGuestsCanEdit),
                  value: snapshot.guestEditingEnabled,
                  onChanged: pending
                      ? null
                      : (value) => _command(() => c.setGuestEditing(value)),
                ),
              const SizedBox(height: 24),
              Text(
                context.l10n.jamQueue,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (!isHost) Text(context.l10n.jamAvailabilityNotShown),
              if (snapshot.entries.isEmpty) Text(context.l10n.jamQueueEmpty),
              for (var i = 0; i < snapshot.entries.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Text('${i + 1}'),
                  title: Text(
                    widget.trackTitle?.call(snapshot.entries[i].trackId) ??
                        snapshot.entries[i].trackId,
                  ),
                  subtitle:
                      isHost &&
                          c.unavailablePlaybackOccurrences.contains(
                            snapshot.entries[i].occurrenceId,
                          )
                      ? Text(context.l10n.jamUnavailableOnHost)
                      : snapshot.entries[i].occurrenceId ==
                            snapshot.currentOccurrenceId
                      ? Text(context.l10n.jamCurrentTrackLocked)
                      : snapshot.entries[i].occurrenceId ==
                            snapshot.pendingOccurrenceId
                      ? Text(context.l10n.jamPendingTrackLocked)
                      : null,
                  trailing: canEdit
                      ? Wrap(
                          children: [
                            IconButton(
                              tooltip: context.l10n.jamMoveUp,
                              onPressed: pending || i == 0
                                  ? null
                                  : () => _command(
                                      () => c.move(
                                        occurrenceId:
                                            snapshot.entries[i].occurrenceId,
                                        beforeOccurrenceId: snapshot
                                            .entries[i - 1]
                                            .occurrenceId,
                                        revision: snapshot.revision,
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_upward),
                            ),
                            IconButton(
                              tooltip: context.l10n.jamMoveDown,
                              onPressed:
                                  pending || i == snapshot.entries.length - 1
                                  ? null
                                  : () => _command(
                                      () => c.move(
                                        occurrenceId:
                                            snapshot.entries[i].occurrenceId,
                                        beforeOccurrenceId:
                                            i + 2 < snapshot.entries.length
                                            ? snapshot
                                                  .entries[i + 2]
                                                  .occurrenceId
                                            : null,
                                        revision: snapshot.revision,
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_downward),
                            ),
                            IconButton(
                              tooltip:
                                  snapshot.entries[i].occurrenceId ==
                                      snapshot.currentOccurrenceId
                                  ? context.l10n.jamCannotRemoveCurrentTooltip
                                  : snapshot.entries[i].occurrenceId ==
                                        snapshot.pendingOccurrenceId
                                  ? context.l10n.jamCannotRemovePendingTooltip
                                  : context.l10n.dialogRemove,
                              onPressed:
                                  pending ||
                                      snapshot.entries[i].occurrenceId ==
                                          snapshot.currentOccurrenceId ||
                                      snapshot.entries[i].occurrenceId ==
                                          snapshot.pendingOccurrenceId
                                  ? null
                                  : () => _remove(
                                      snapshot.entries[i].occurrenceId,
                                      snapshot.revision,
                                      widget.trackTitle?.call(
                                            snapshot.entries[i].trackId,
                                          ) ??
                                          snapshot.entries[i].trackId,
                                    ),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        )
                      : null,
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed:
                    pending ||
                        (widget.selectTrack == null &&
                            (!isHost || widget.selectHostMedia == null))
                    ? null
                    : () => _selectTrack(snapshot.revision),
                icon: const Icon(Icons.library_music_outlined),
                label: Text(context.l10n.jamAddToQueue),
              ),
              if (widget.selectTrack == null &&
                  (!isHost || widget.selectHostMedia == null))
                Text(context.l10n.jamPickerUnavailable),
            ],
            const SizedBox(height: 24),
            TextButton(
              onPressed: pending ? null : () => _run(c.close),
              child: Text(
                isHost
                    ? context.l10n.jamCloseSession
                    : context.l10n.jamLeaveSession,
              ),
            ),
          ],
          if (pending)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      );
    },
  );
}

class _InvitationCard extends StatefulWidget {
  const _InvitationCard({
    required this.invitation,
    required this.expiresAt,
    required this.pending,
    required this.onGenerate,
    required this.now,
  });
  final JamInvitation? invitation;
  final DateTime? expiresAt;
  final bool pending;
  final VoidCallback onGenerate;
  final DateTime Function() now;

  @override
  State<_InvitationCard> createState() => _InvitationCardState();
}

class _InvitationCardState extends State<_InvitationCard> {
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _scheduleExpiry();
  }

  @override
  void didUpdateWidget(_InvitationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt ||
        oldWidget.invitation != widget.invitation) {
      _scheduleExpiry();
    }
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    final expiry = widget.expiresAt;
    if (expiry == null) return;
    final remaining = expiry.difference(widget.now());
    if (remaining > Duration.zero) {
      _expiryTimer = Timer(remaining, () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expiry = widget.expiresAt;
    final valid =
        widget.invitation != null &&
        expiry != null &&
        widget.now().isBefore(expiry);
    final local = expiry?.toLocal();
    final time = local == null
        ? ''
        : '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.jamInvitationSingleUse),
        const SizedBox(height: 8),
        if (valid) ...[
          Text(context.l10n.jamInvitationExpires(time)),
          const SizedBox(height: 8),
          SelectableText(JamInvitationCodec.encode(widget.invitation!)),
          TextButton.icon(
            onPressed: widget.pending
                ? null
                : () async {
                    if (!widget.now().isBefore(expiry)) {
                      setState(() {});
                      return;
                    }
                    await Clipboard.setData(
                      ClipboardData(
                        text: JamInvitationCodec.encode(widget.invitation!),
                      ),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(context.l10n.jamInvitationCopied),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.copy),
            label: Text(context.l10n.jamCopyInvitation),
          ),
        ] else
          Text(context.l10n.jamInvitationExpired),
        OutlinedButton.icon(
          onPressed: widget.pending ? null : widget.onGenerate,
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.jamGenerateInvitation),
        ),
      ],
    );
  }
}
