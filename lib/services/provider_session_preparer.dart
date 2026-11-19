import 'dart:async';

import 'package:mornye/services/platform_bridge.dart';

/// Resultado de un intento de sesión en segundo plano, sin datos sensibles.
enum ProviderSessionOutcome {
  /// El proveedor ya tiene sesión vigente (o se renovó antes de expirar).
  ready,

  /// La verificación de fondo obtuvo sesión nueva.
  granted,

  /// No se pudo (sin conexión, proveedor caído, challenge no completado).
  failed,

  /// Otro panel de verificación está ocupado: se reintenta en la próxima pasada.
  busy,

  /// Sin sesión que preparar (proveedor sin sesión firmada, bloqueado, etc.).
  skipped,
}

/// Planificador de fondo de sesiones de proveedores.
///
/// Es el ÚNICO lugar que decide cuándo verificar una sesión: la búsqueda, la
/// reproducción y la navegación solo consultan estado. Reglas:
///  * serial y en orden de prioridad (el proveedor por defecto primero), con una
///    pausa corta entre proveedores para no saturar servidores;
///  * si hay sesión vigente no hace nada; renueva sin challenge SOLO antes de
///    que expire (lo decide el renovador nativo, aquí solo se le consulta);
///  * si no hay sesión o ya expiró, pide una sesión nueva mediante el mecanismo
///    existente de verificación (la página se autoverifica en el WebView
///    invisible; nada se muestra ni se pregunta);
///  * no automatiza ni sortea el challenge: solo delega en [verify].
///  * al reanudar la app reintenta únicamente lo que falte o esté por expirar,
///    con un intervalo mínimo entre pasadas (sin ráfagas).
class ProviderSessionPreparer {
  ProviderSessionPreparer({
    required this.renew,
    required this.verify,
    required this.canRun,
    this.delay = _defaultDelay,
    DateTime Function()? now,
    this.betweenProviders = const Duration(seconds: 2),
    this.renewalWindow = const Duration(minutes: 30),
    this.failureCooldown = const Duration(minutes: 2),
    this.minPassInterval = const Duration(seconds: 20),
    this.onOutcome,
    this.onStatus,
    this.onPass,
    this.unavailableRecheck = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now;

  /// Consulta silenciosa de la sesión existente (renueva solo si vence pronto).
  final Future<SessionRenewalResult?> Function(String id) renew;

  /// Obtiene sesión nueva con el mecanismo existente. Debe respetar [cancelled].
  final Future<ProviderSessionOutcome> Function(
    String id,
    Future<void> cancelled,
  )
  verify;

  /// Falso cuando la app no está en primer plano (el WebView embebido solo
  /// funciona con MainActivity visible).
  final bool Function() canRun;
  final Future<void> Function(Duration) delay;
  final DateTime Function() _now;
  final Duration betweenProviders;
  final Duration renewalWindow;
  final Duration failureCooldown;
  final Duration minPassInterval;
  final void Function(String id, ProviderSessionOutcome outcome)? onOutcome;
  final void Function(
    String id,
    SessionRenewalStatus? status,
    bool renewFailed,
  )?
  onStatus;
  final void Function(String event, int providers)? onPass;
  final Duration unavailableRecheck;

  static Future<void> _defaultDelay(Duration d) => Future<void>.delayed(d);

  final Map<String, DateTime> _validUntil = {};
  final Map<String, DateTime> _lastFailure = {};
  final Map<String, DateTime> _recheckAt = {};
  Future<void>? _inFlight;
  Completer<void>? _cancel;
  DateTime? _lastPassStart;
  int _generation = 0;

  /// Vencimiento conocido de la sesión de [id] (null si no se conoce).
  DateTime? knownExpiry(String id) => _validUntil[id];

  bool get running => _inFlight != null;

  /// Cancela la pasada en curso (p. ej. al pasar a segundo plano).
  void stop() {
    _generation++;
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Pasada serial sobre [orderedIds]. No lanza. Si ya hay una en curso, se une
  /// a ella; [force] omite el intervalo mínimo entre pasadas.
  Future<void> run(List<String> orderedIds, {bool force = false}) {
    final current = _inFlight;
    if (current != null) {
      onPass?.call('joined', orderedIds.length);
      return current;
    }
    final last = _lastPassStart;
    if (!force && last != null && _now().difference(last) < minPassInterval) {
      onPass?.call('skipped_interval', orderedIds.length);
      return Future<void>.value();
    }
    _lastPassStart = _now();
    onPass?.call('started', orderedIds.length);
    final future = _run(List.of(orderedIds), ++_generation).whenComplete(() {
      _inFlight = null;
      _cancel = null;
    });
    _inFlight = future;
    return future;
  }

  bool _fresh(String id) {
    final expiry = _validUntil[id];
    return expiry != null && expiry.isAfter(_now().add(renewalWindow));
  }

  Future<void> _run(List<String> ids, int generation) async {
    final cancel = Completer<void>();
    _cancel = cancel;
    var first = true;
    for (final id in ids) {
      if (_generation != generation) {
        onPass?.call('cancelled', ids.length);
        return;
      }
      if (!canRun()) {
        onPass?.call('not_runnable', ids.length);
        return;
      }
      // Sesión vigente y lejos de vencer: no se toca (sin consultas inútiles).
      if (_fresh(id)) continue;
      final failedAt = _lastFailure[id];
      if (failedAt != null && _now().difference(failedAt) < failureCooldown) {
        continue;
      }
      if (!first) {
        await delay(betweenProviders);
        if (_generation != generation) {
          onPass?.call('cancelled', ids.length);
          return;
        }
        if (!canRun()) {
          onPass?.call('not_runnable', ids.length);
          return;
        }
      }
      first = false;
      final outcome = await _prepare(id, cancel.future);
      if (_generation != generation) {
        onPass?.call('cancelled', ids.length);
        return;
      }
      onOutcome?.call(id, outcome);
      if (outcome == ProviderSessionOutcome.busy) {
        onPass?.call('busy', ids.length);
        return;
      }
    }
    onPass?.call('finished', ids.length);
  }

  Future<ProviderSessionOutcome> _prepare(
    String id,
    Future<void> cancelled,
  ) async {
    SessionRenewalResult? result;
    try {
      result = await renew(id);
    } catch (_) {
      onStatus?.call(id, null, true);
      _lastFailure[id] = _now();
      return ProviderSessionOutcome.failed;
    }
    onStatus?.call(id, result?.status, false);
    if (result?.status != SessionRenewalStatus.unavailable) {
      _recheckAt.remove(id);
    }
    switch (result?.status) {
      case SessionRenewalStatus.validUntil:
      case SessionRenewalStatus.refreshed:
        final expiry = DateTime.tryParse(result?.expiresAt ?? '');
        if (expiry != null && expiry.isAfter(_now())) {
          _validUntil[id] = expiry;
          return ProviderSessionOutcome.ready;
        }
        // Vencimiento ilegible o ya pasado: equivale a no tener sesión.
        _validUntil.remove(id);
      case SessionRenewalStatus.missing:
      case SessionRenewalStatus.invalid:
      case SessionRenewalStatus.blocked:
        // Sin sesión o expirada: se pide una nueva (nunca renovar sin challenge).
        _validUntil.remove(id);
      case SessionRenewalStatus.unavailable:
        _recheckAt[id] = _now().add(unavailableRecheck);
        return ProviderSessionOutcome.skipped;
      case SessionRenewalStatus.disabled:
      case SessionRenewalStatus.notApplicable:
      case null:
        return ProviderSessionOutcome.skipped;
    }
    ProviderSessionOutcome outcome;
    try {
      outcome = await verify(id, cancelled);
    } catch (_) {
      outcome = ProviderSessionOutcome.failed;
    }
    if (outcome == ProviderSessionOutcome.failed) {
      _lastFailure[id] = _now();
    } else if (outcome == ProviderSessionOutcome.granted) {
      _lastFailure.remove(id);
      // Aprende el vencimiento real sin abrir nada (solo consulta/renueva).
      try {
        final after = await renew(id);
        final expiry = DateTime.tryParse(after?.expiresAt ?? '');
        if (expiry != null && expiry.isAfter(_now())) _validUntil[id] = expiry;
      } catch (_) {
        // Se aprenderá en la próxima pasada.
      }
    }
    return outcome;
  }

  /// Próximo instante en que conviene reconsultar (renovar antes de expirar), o
  /// null si no hay sesiones con vencimiento conocido.
  DateTime? nextDue() {
    DateTime? next;
    for (final expiry in _validUntil.values) {
      final due = expiry.subtract(renewalWindow);
      if (next == null || due.isBefore(next)) next = due;
    }
    for (final due in _recheckAt.values) {
      if (next == null || due.isBefore(next)) next = due;
    }
    return next;
  }

  void forget(String id) {
    _validUntil.remove(id);
    _lastFailure.remove(id);
    _recheckAt.remove(id);
  }
}

/// Proveedores de reproducción en línea: no llevan sesión firmada que preparar.
const _providersWithoutSessionPreparation = {
  'soundcloud',
  'youtube',
  'ytmusic-spotiflac',
};

/// Orden de preparación: proveedor por defecto, luego la prioridad configurada
/// y al final el resto. Solo extensiones activas y cargadas con descarga (o el
/// proveedor de búsqueda actual).
List<String> orderedSessionProviders({
  required String defaultService,
  required Iterable<String> priority,
  required Iterable<({String id, bool enabled, bool loaded, bool download})>
  extensions,
  String? searchProvider,
}) {
  final eligible = <String, String>{};
  final search = (searchProvider ?? '').trim().toLowerCase();
  for (final e in extensions) {
    final id = e.id.trim();
    final key = id.toLowerCase();
    if (id.isEmpty ||
        !e.enabled ||
        !e.loaded ||
        _providersWithoutSessionPreparation.contains(key)) {
      continue;
    }
    if (e.download || key == search) eligible.putIfAbsent(key, () => id);
  }
  final ordered = <String>[];
  final seen = <String>{};
  for (final id in [defaultService, ...priority, ...eligible.values]) {
    final key = id.trim().toLowerCase();
    final canonical = eligible[key];
    if (canonical != null && seen.add(key)) ordered.add(canonical);
  }
  return ordered;
}
