import 'dart:io';

import 'package:path/path.dart' as p;

/// Retire an app-created SAF attempt only after publication and writer completion.
/// The marker comes from the native adapter, not the provider. This never removes
/// files, symlinks, nested directories, or a nonempty attempt directory.
Future<bool> cleanupTransferredSafAttemptDirectory({
  required String marker,
  required String applicationSupportDirectory,
}) async {
  try {
    final directory = await _ownedAttemptDirectory(
      marker,
      applicationSupportDirectory,
    );
    if (directory == null) return false;
    await directory.delete(recursive: false);
    return true;
  } catch (_) {
    return false;
  }
}

/// A successful SAF copy does not grant ownership of its source. Only a direct
/// regular file in the adapter's owned attempt may be retired after publication.
Future<bool> deleteTransferredSafAttemptOutput({
  required String marker,
  required String applicationSupportDirectory,
  required String sourcePath,
}) async {
  try {
    if (!await isTransferredSafAttemptOutput(
      marker: marker,
      applicationSupportDirectory: applicationSupportDirectory,
      sourcePath: sourcePath,
    )) {
      return false;
    }
    await File(sourcePath).delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Validate a hook result before adopting it for further processing. A path
/// returned by a provider/hook is not an ownership capability.
Future<bool> isTransferredSafAttemptOutput({
  required String marker,
  required String applicationSupportDirectory,
  required String sourcePath,
}) async {
  try {
    final directory = await _ownedAttemptDirectory(
      marker,
      applicationSupportDirectory,
    );
    if (directory == null ||
        !p.isAbsolute(sourcePath) ||
        p.normalize(sourcePath) != sourcePath ||
        p.dirname(sourcePath) != directory.path) {
      return false;
    }
    if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    return await File(sourcePath).resolveSymbolicLinks() ==
        p.join(await directory.resolveSymbolicLinks(), p.basename(sourcePath));
  } catch (_) {
    return false;
  }
}

/// A cancelled hook never transfers its result. Neither validation failure nor
/// cancellation deletes the old input or the proposed replacement.
Future<bool> acceptTransferredSafHookOutput({
  required String marker,
  required String applicationSupportDirectory,
  required String sourcePath,
  required bool Function() shouldAbort,
}) async {
  if (shouldAbort()) return false;
  if (!await isTransferredSafAttemptOutput(
    marker: marker,
    applicationSupportDirectory: applicationSupportDirectory,
    sourcePath: sourcePath,
  )) {
    return false;
  }
  try {
    return await File(sourcePath).length() > 0 && !shouldAbort();
  } catch (_) {
    return false;
  }
}

/// Grant exactly the validated attempt for one awaited hook invocation. No scope
/// is opened for an external source, and every opened scope is released.
Future<T> withTransferredSafHookGrant<T>({
  required String marker,
  required String applicationSupportDirectory,
  required String sourcePath,
  required Future<String> Function(String) acquire,
  required Future<void> Function(String) release,
  required Future<T> Function() run,
}) async {
  if (!await isTransferredSafAttemptOutput(
    marker: marker,
    applicationSupportDirectory: applicationSupportDirectory,
    sourcePath: sourcePath,
  )) {
    throw StateError('Hook input is outside the owned SAF attempt');
  }
  final token = await acquire(marker);
  try {
    return await run();
  } finally {
    await release(token);
  }
}

Future<Directory?> _ownedAttemptDirectory(
  String marker,
  String applicationSupportDirectory,
) async {
  try {
    if (!p.isAbsolute(marker) || p.normalize(marker) != marker) return null;
    final root = Directory(
      p.join(applicationSupportDirectory, 'native-saf-attempts'),
    );
    final directory = Directory(marker);
    final name = p.basename(marker);
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(name)) {
      return null;
    }
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    // Android may give Dart an alias for filesDir while the native adapter
    // returns paths under its canonical name.
    var canonicalRoot = await root.resolveSymbolicLinks();
    final parent = p.dirname(marker);
    if (parent != root.absolute.path && parent != canonicalRoot) {
      // Android can expose both app-private paths as mount aliases. Their
      // canonical spellings can differ even when they name the same inode.
      if (!Platform.isAndroid ||
          !_isAndroidOwnerWorkspaceAlias(root.absolute.path, parent) ||
          await FileSystemEntity.type(parent, followLinks: false) !=
              FileSystemEntityType.directory ||
          !await FileSystemEntity.identical(root.path, parent)) {
        return null;
      }
      canonicalRoot = await Directory(parent).resolveSymbolicLinks();
    }
    if (await FileSystemEntity.type(marker, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    if (await directory.resolveSymbolicLinks() != p.join(canonicalRoot, name)) {
      return null;
    }
    return directory;
  } catch (_) {
    return null;
  }
}

bool _isAndroidOwnerWorkspaceAlias(String root, String candidate) {
  const userRoot = '/data/user/0/';
  const dataRoot = '/data/data/';
  for (final (from, to) in [(userRoot, dataRoot), (dataRoot, userRoot)]) {
    if (root.startsWith(from)) {
      return candidate == to + root.substring(from.length);
    }
  }
  return false;
}
