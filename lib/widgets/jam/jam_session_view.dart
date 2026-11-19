import 'package:flutter/material.dart';

import '../../services/jam/jam_coordinator.dart';
import '../../services/jam/jam_queue.dart';

/// Observes an existing coordinator without owning its lifecycle.
class JamCoordinatorView extends StatelessWidget {
  const JamCoordinatorView({
    super.key,
    required this.coordinator,
    this.trackTitle,
    this.strings = const JamViewStrings(),
  });

  final JamCoordinator coordinator;
  final String? Function(String trackId)? trackTitle;
  final JamViewStrings strings;

  @override
  Widget build(BuildContext context) => StreamBuilder<JamQueue>(
    key: ObjectKey(coordinator),
    stream: coordinator.events,
    initialData: coordinator.snapshot,
    builder: (context, state) => JamSessionView(
      snapshot: state.data ?? coordinator.snapshot,
      role: JamRole.host,
      trackTitle: trackTitle,
      error: state.hasError ? state.error.toString() : null,
      strings: strings,
    ),
  );
}

/// Read-only presentation of an authoritative Jam snapshot.
///
/// This widget does not establish a connection or control playback. The caller
/// must provide an authenticated role, if known, and any resolved track names.
class JamSessionView extends StatelessWidget {
  const JamSessionView({
    super.key,
    required this.snapshot,
    this.role,
    this.trackTitle,
    this.error,
    this.strings = const JamViewStrings(),
  });

  final JamQueue snapshot;
  final JamRole? role;
  final String? Function(String trackId)? trackTitle;
  final String? error;
  final JamViewStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final roleLabel = switch (role) {
      JamRole.host => strings.host,
      JamRole.guest => strings.guest,
      null => strings.unknownRole,
    };
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(strings.title, style: text.headlineSmall),
        const SizedBox(height: 8),
        Text(strings.localOnly, style: text.bodyMedium),
        if (error != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              '${strings.error}: $error',
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _InfoRow(label: strings.role, value: roleLabel),
        _InfoRow(
          label: strings.guestPermissions,
          value: snapshot.guestEditingEnabled
              ? strings.guestsCanEdit
              : strings.guestsCanAdd,
        ),
        _InfoRow(label: strings.contributions, value: strings.unavailable),
        const SizedBox(height: 24),
        Text(strings.queue, style: text.titleLarge),
        const SizedBox(height: 8),
        if (snapshot.entries.isEmpty)
          Text(strings.emptyQueue, style: text.bodyMedium)
        else
          for (var i = 0; i < snapshot.entries.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Text('${i + 1}', style: text.labelLarge),
              title: Text(
                trackTitle?.call(snapshot.entries[i].trackId) ??
                    snapshot.entries[i].trackId,
              ),
            ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Wrap(
      spacing: 8,
      children: [
        Text('$label:', style: Theme.of(context).textTheme.labelLarge),
        Text(value),
      ],
    ),
  );
}

/// Override with localized strings when the view is integrated into the app.
class JamViewStrings {
  const JamViewStrings({
    this.title = 'Jam session',
    this.localOnly = 'Local session',
    this.role = 'Role',
    this.host = 'Host',
    this.guest = 'Guest',
    this.unknownRole = 'Unknown',
    this.guestPermissions = 'Guest permissions',
    this.guestsCanEdit = 'Add, reorder and remove tracks',
    this.guestsCanAdd = 'Add tracks',
    this.contributions = 'Track contributions',
    this.unavailable = 'Not available',
    this.queue = 'Queue',
    this.emptyQueue = 'The queue is empty.',
    this.error = 'Error',
  });
  final String title;
  final String localOnly;
  final String role;
  final String host;
  final String guest;
  final String unknownRole;
  final String guestPermissions;
  final String guestsCanEdit;
  final String guestsCanAdd;
  final String contributions;
  final String unavailable;
  final String queue;
  final String emptyQueue;
  final String error;
}
