import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Pure queue rules. Identity and roles must be established by the caller.
enum JamRole { host, guest }

class JamEntry {
  const JamEntry({required this.occurrenceId, required this.trackId});
  final String occurrenceId;
  final String trackId;
}

sealed class JamCommand {
  const JamCommand(this.commandId, this.actorId, this.expectedRevision);
  final String commandId;
  final String actorId;
  final int expectedRevision;

  Object get fingerprint;
}

class AddJamEntry extends JamCommand {
  const AddJamEntry(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    this.occurrenceId,
    this.trackId,
  );
  final String occurrenceId;
  final String trackId;
  @override
  Object get fingerprint =>
      ('add', actorId, expectedRevision, occurrenceId, trackId);
}

class MoveJamEntry extends JamCommand {
  /// Moves [occurrenceId] immediately before [beforeOccurrenceId], or to the end.
  const MoveJamEntry(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    this.occurrenceId,
    this.beforeOccurrenceId,
  );
  final String occurrenceId;
  final String? beforeOccurrenceId;
  @override
  Object get fingerprint =>
      ('move', actorId, expectedRevision, occurrenceId, beforeOccurrenceId);
}

class RemoveJamEntry extends JamCommand {
  const RemoveJamEntry(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    this.occurrenceId,
  );
  final String occurrenceId;
  @override
  Object get fingerprint => ('remove', actorId, expectedRevision, occurrenceId);
}

/// Host-local atomic queue edit. This command is not part of the wire protocol.
class ReplaceHostJamEntries extends JamCommand {
  ReplaceHostJamEntries(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    List<JamEntry> entries,
  ) : entries = List.unmodifiable(entries);

  final List<JamEntry> entries;
  @override
  Object get fingerprint => (
    'replaceHostEntries',
    actorId,
    expectedRevision,
    sha256
        .convert(
          utf8.encode(
            jsonEncode(
              entries.map((e) => [e.occurrenceId, e.trackId]).toList(),
            ),
          ),
        )
        .toString(),
  );
}

/// Only the host may change whether guests can reorder and remove entries.
class SetGuestEditing extends JamCommand {
  const SetGuestEditing(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    this.enabled,
  );
  final bool enabled;
  @override
  Object get fingerprint =>
      ('guestEditing', actorId, expectedRevision, enabled);
}

/// Membership changes require an authenticated host and consume a revision.
class SetJamGuest extends JamCommand {
  const SetJamGuest(
    super.commandId,
    super.actorId,
    super.expectedRevision,
    this.guestId,
    this.present,
  );
  final String guestId;
  final bool present;
  @override
  Object get fingerprint =>
      ('guest', actorId, expectedRevision, guestId, present);
}

enum JamOutcome {
  applied,
  duplicate,
  conflict,
  forbidden,
  invalid,
  capacity,
  currentPlaying,
  unavailable,
}

class JamResult {
  const JamResult(this.state, this.outcome);
  final JamQueue state;
  final JamOutcome outcome;
}

/// Immutable snapshot, including accepted command IDs for safe retries.
class JamQueue {
  static const maxEntries = 1000;
  static const maxParticipants = 32;
  static const maxAcceptedCommands = 10000;
  JamQueue({
    required String hostId,
    Map<String, JamRole> participants = const {},
    this.guestEditingEnabled = true,
  }) : assert(hostId != ''),
       _roles = Map.unmodifiable({...participants, hostId: JamRole.host}),
       _hostId = hostId,
       revision = 0,
       currentOccurrenceId = null,
       pendingOccurrenceId = null,
       entries = const [],
       _accepted = const {},
       _guestAccepted = 0,
       _hostAccepted = 0 {
    if (hostId.isEmpty ||
        hostId.length > 256 ||
        _roles.length > maxParticipants ||
        participants.entries.any(
          (e) =>
              e.key.isEmpty ||
              e.key.length > 256 ||
              (e.value == JamRole.host && e.key != hostId),
        )) {
      throw ArgumentError('Exactly one nonempty host identity is required');
    }
  }

  JamQueue._(
    this._hostId,
    this._roles,
    this.revision,
    this.entries,
    this._accepted,
    this.guestEditingEnabled,
    this._guestAccepted,
    this._hostAccepted,
    this.currentOccurrenceId,
    this.pendingOccurrenceId,
  );

  final String _hostId;
  final Map<String, JamRole> _roles;
  final int revision;
  final String? currentOccurrenceId;
  final String? pendingOccurrenceId;
  final List<JamEntry> entries;
  final Map<String, Object> _accepted;
  // Separate budgets prevent guest commands from exhausting host control.
  // Both budgets remain bounded; retry IDs are never evicted in a session.
  final int _guestAccepted;
  final int _hostAccepted;
  final bool guestEditingEnabled;

  /// Checks an accepted command without changing state. Used by the local
  /// host before context-dependent validation so retries remain idempotent.
  JamOutcome? acceptedOutcome(JamCommand command) {
    final old = _accepted[command.commandId];
    if (old == null) return null;
    if (command is ReplaceHostJamEntries &&
        (command.entries.length > maxEntries ||
            command.entries.any(
              (e) => e.occurrenceId.length > 256 || e.trackId.length > 256,
            ))) {
      return JamOutcome.invalid;
    }
    return old == command.fingerprint
        ? JamOutcome.duplicate
        : JamOutcome.invalid;
  }

  /// Local host capability, outside the retry ledger. This operation is
  /// idempotent with respect to membership and cannot exhaust the ledger.
  /// It must never be exposed as an unauthenticated network command.
  JamResult revokeGuest({
    required String authenticatedActorId,
    required String guestId,
  }) {
    if (authenticatedActorId != _hostId) {
      return JamResult(this, JamOutcome.forbidden);
    }
    if (_roles[guestId] != JamRole.guest) {
      return JamResult(this, JamOutcome.invalid);
    }
    final roles = Map<String, JamRole>.of(_roles)..remove(guestId);
    return JamResult(
      JamQueue._(
        _hostId,
        Map.unmodifiable(roles),
        revision + 1,
        entries,
        _accepted,
        guestEditingEnabled,
        _guestAccepted,
        _hostAccepted,
        currentOccurrenceId,
        pendingOccurrenceId,
      ),
      JamOutcome.applied,
    );
  }

  /// Records host playback in the same revision stream as queue edits.
  JamResult setCurrentOccurrence(String? occurrenceId) =>
      setPlaybackOccurrences(currentOccurrenceId: occurrenceId);

  JamResult setPlaybackOccurrences({
    required String? currentOccurrenceId,
    String? pendingOccurrenceId,
  }) {
    bool exists(String? id) =>
        id == null || entries.any((e) => e.occurrenceId == id);
    if (!exists(currentOccurrenceId) || !exists(pendingOccurrenceId)) {
      return JamResult(this, JamOutcome.invalid);
    }
    if (currentOccurrenceId == this.currentOccurrenceId &&
        pendingOccurrenceId == this.pendingOccurrenceId) {
      return JamResult(this, JamOutcome.duplicate);
    }
    return JamResult(
      JamQueue._(
        _hostId,
        _roles,
        revision + 1,
        entries,
        _accepted,
        guestEditingEnabled,
        _guestAccepted,
        _hostAccepted,
        currentOccurrenceId,
        pendingOccurrenceId,
      ),
      JamOutcome.applied,
    );
  }

  JamResult apply(JamCommand command) {
    final role = _roles[command.actorId];
    if (role == null) {
      return JamResult(this, JamOutcome.forbidden);
    }
    if (command.commandId.isEmpty || command.commandId.length > 256) {
      return JamResult(this, JamOutcome.invalid);
    }
    // Bound the input before calculating a retry fingerprint, including when
    // a caller reuses an accepted command ID with a different payload.
    if (command is ReplaceHostJamEntries) {
      if (command.entries.length > maxEntries) {
        return JamResult(this, JamOutcome.capacity);
      }
      if (command.entries.any(
        (e) => e.occurrenceId.length > 256 || e.trackId.length > 256,
      )) {
        return JamResult(this, JamOutcome.invalid);
      }
    }
    final old = _accepted[command.commandId];
    if (old != null) {
      return JamResult(
        this,
        old == command.fingerprint ? JamOutcome.duplicate : JamOutcome.invalid,
      );
    }
    if (role == JamRole.guest &&
        (command is ReplaceHostJamEntries ||
            command is SetGuestEditing ||
            command is SetJamGuest ||
            (!guestEditingEnabled && command is! AddJamEntry))) {
      return JamResult(this, JamOutcome.forbidden);
    }
    if (command.expectedRevision != revision) {
      return JamResult(this, JamOutcome.conflict);
    }
    if ((role == JamRole.guest ? _guestAccepted : _hostAccepted) >=
        maxAcceptedCommands) {
      return JamResult(this, JamOutcome.capacity);
    }
    final next = List<JamEntry>.of(entries);
    final nextRoles = Map<String, JamRole>.of(_roles);
    var nextGuestEditing = guestEditingEnabled;
    switch (command) {
      case ReplaceHostJamEntries():
        if (command.entries.length > maxEntries) {
          return JamResult(this, JamOutcome.capacity);
        }
        final seen = <String>{};
        final existing = {
          for (final entry in entries) entry.occurrenceId: entry.trackId,
        };
        for (final entry in command.entries) {
          if (entry.occurrenceId.isEmpty ||
              entry.occurrenceId.length > 256 ||
              entry.trackId.isEmpty ||
              entry.trackId.length > 256 ||
              !seen.add(entry.occurrenceId) ||
              (existing.containsKey(entry.occurrenceId) &&
                  existing[entry.occurrenceId] != entry.trackId)) {
            return JamResult(this, JamOutcome.invalid);
          }
        }
        if ((currentOccurrenceId != null &&
                !seen.contains(currentOccurrenceId)) ||
            (pendingOccurrenceId != null &&
                !seen.contains(pendingOccurrenceId))) {
          return JamResult(this, JamOutcome.currentPlaying);
        }
        next
          ..clear()
          ..addAll(command.entries);
      case AddJamEntry():
        if (next.length >= maxEntries) {
          return JamResult(this, JamOutcome.capacity);
        }
        if (command.occurrenceId.isEmpty ||
            command.trackId.isEmpty ||
            command.occurrenceId.length > 256 ||
            command.trackId.length > 256 ||
            next.any((e) => e.occurrenceId == command.occurrenceId)) {
          return JamResult(this, JamOutcome.invalid);
        }
        next.add(
          JamEntry(
            occurrenceId: command.occurrenceId,
            trackId: command.trackId,
          ),
        );
      case MoveJamEntry():
        final index = next.indexWhere(
          (e) => e.occurrenceId == command.occurrenceId,
        );
        if (index < 0 ||
            command.beforeOccurrenceId == command.occurrenceId ||
            (command.beforeOccurrenceId != null &&
                !next.any(
                  (e) => e.occurrenceId == command.beforeOccurrenceId,
                ))) {
          return JamResult(this, JamOutcome.invalid);
        }
        final entry = next.removeAt(index);
        final destination = command.beforeOccurrenceId == null
            ? next.length
            : next.indexWhere(
                (e) => e.occurrenceId == command.beforeOccurrenceId,
              );
        next.insert(destination, entry);
      case RemoveJamEntry():
        if (command.occurrenceId == currentOccurrenceId ||
            command.occurrenceId == pendingOccurrenceId) {
          return JamResult(this, JamOutcome.currentPlaying);
        }
        final index = next.indexWhere(
          (e) => e.occurrenceId == command.occurrenceId,
        );
        if (index < 0) return JamResult(this, JamOutcome.invalid);
        next.removeAt(index);
      case SetGuestEditing():
        nextGuestEditing = command.enabled;
      case SetJamGuest():
        if (command.guestId.isEmpty ||
            command.guestId.length > 256 ||
            command.guestId == _hostId) {
          return JamResult(this, JamOutcome.invalid);
        }
        if (command.present) {
          if (!nextRoles.containsKey(command.guestId) &&
              nextRoles.length >= maxParticipants) {
            return JamResult(this, JamOutcome.capacity);
          }
          nextRoles[command.guestId] = JamRole.guest;
        } else {
          if (!nextRoles.containsKey(command.guestId)) {
            return JamResult(this, JamOutcome.invalid);
          }
          nextRoles.remove(command.guestId);
        }
    }
    return JamResult(
      JamQueue._(
        _hostId,
        Map.unmodifiable(nextRoles),
        revision + 1,
        List.unmodifiable(next),
        Map.unmodifiable({
          ..._accepted,
          command.commandId: command.fingerprint,
        }),
        nextGuestEditing,
        _guestAccepted + (role == JamRole.guest ? 1 : 0),
        _hostAccepted + (role == JamRole.host ? 1 : 0),
        currentOccurrenceId,
        pendingOccurrenceId,
      ),
      JamOutcome.applied,
    );
  }
}
