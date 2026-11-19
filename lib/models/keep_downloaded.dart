// Reglas puras de "Mantener descarga activa": que descargas se borran al
// desactivar un alcance (la biblioteca general o una playlist) y cuales se
// conservan porque otro alcance con el interruptor activo aun las necesita.

/// Alcance de la biblioteca general (canciones agregadas con "+" y favoritas).
const keepLibraryScope = 'library';

const _playlistScopePrefix = 'playlist:';

/// Alcance de una playlist del usuario.
String keepPlaylistScope(String playlistId) =>
    '$_playlistScopePrefix$playlistId';

/// Id de la playlist de [scope], o null si es otro alcance.
String? keepScopePlaylistId(String scope) =>
    scope.startsWith(_playlistScopePrefix)
    ? scope.substring(_playlistScopePrefix.length)
    : null;

/// Resultado de decidir que pasa con las canciones de un alcance al apagarlo.
class KeepDownloadedPlan {
  const KeepDownloadedPlan({required this.toDelete, required this.shared});

  /// Claves de cancion cuyas descargas se pueden borrar sin romper a nadie.
  final Set<String> toDelete;

  /// Claves que otro alcance activo todavia necesita: no se borran.
  final Set<String> shared;
}

/// Cuenta de referencias: una cancion del alcance [scope] solo se borra si
/// ningun otro alcance activo (de [activeScopes]) la contiene.
KeepDownloadedPlan planKeepDownloadedRemoval({
  required String scope,
  required Set<String> activeScopes,
  required Map<String, Set<String>> keysByScope,
}) {
  final own = keysByScope[scope] ?? const <String>{};
  final needed = <String>{};
  for (final other in activeScopes) {
    if (other == scope) continue;
    needed.addAll(keysByScope[other] ?? const <String>{});
  }
  return KeepDownloadedPlan(
    toDelete: own.difference(needed),
    shared: own.intersection(needed),
  );
}

/// Vista previa para el dialogo de confirmacion al desactivar.
class KeepDownloadedPreview {
  const KeepDownloadedPreview({
    required this.scope,
    required this.deletableTracks,
    required this.deletePaths,
    required this.sharedDownloadedCount,
  });

  final String scope;

  /// Cuantas canciones perderian su archivo descargado.
  final int deletableTracks;

  /// Archivos que se borrarian (una cancion puede tener mas de uno).
  final List<String> deletePaths;

  /// Descargadas que se conservan porque otra coleccion activa las usa.
  final int sharedDownloadedCount;
}
