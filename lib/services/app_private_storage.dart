import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:mornye/constants/storage_defaults.dart';

String _canonicalAndroidPath(String path) => path
    .trim()
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'/+$'), '')
    .replaceFirst(RegExp(r'^/data/data/'), '/data/user/0/');

/// Whether [path] is [root] itself or lives inside it. `/data/data/<app>` and
/// `/data/user/0/<app>` are two spellings of the same private directory.
bool isPathInsideAppRoot(String path, String root) {
  final candidate = _canonicalAndroidPath(path);
  final base = _canonicalAndroidPath(root);
  if (candidate.isEmpty || base.isEmpty) return false;
  return candidate == base || candidate.startsWith('$base/');
}

/// Whether [path] sits in storage that only this app can see and that is
/// deleted with it.
bool isAppPrivateStoragePath(String path, Iterable<String> privateRoots) =>
    privateRoots.any((root) => isPathInsideAppRoot(path, root));

/// Whether [path] is exactly one of the private download folders.
bool isAppPrivateDownloadFolder(String path, Iterable<String> folders) {
  final candidate = _canonicalAndroidPath(path);
  if (candidate.isEmpty) return false;
  return folders.any((folder) => _canonicalAndroidPath(folder) == candidate);
}

/// The private storage of the app on Android; empty elsewhere.
class AppPrivateStorage {
  const AppPrivateStorage({
    this.documentsDirectory = _platformDocumentsDirectory,
    this.externalDirectory = _platformExternalDirectory,
  });

  final Future<String?> Function() documentsDirectory;
  final Future<String?> Function() externalDirectory;

  static Future<String?> _platformDocumentsDirectory() async {
    if (!Platform.isAndroid) return null;
    return (await getApplicationDocumentsDirectory()).path;
  }

  static Future<String?> _platformExternalDirectory() async {
    if (!Platform.isAndroid) return null;
    return (await getExternalStorageDirectory())?.path;
  }

  /// Roots under which everything is private: the data directory and the
  /// app-specific folder of external storage.
  Future<List<String>> roots() async {
    final roots = <String>[];
    try {
      final documents = await documentsDirectory();
      if (documents != null && documents.isNotEmpty) {
        roots.add(Directory(documents).parent.path);
      }
    } catch (_) {}
    try {
      final external = await externalDirectory();
      if (external != null && external.isNotEmpty) {
        roots.add(Directory(external).parent.path);
      }
    } catch (_) {}
    return roots;
  }

  /// The `MUSA` folders inside private storage that earlier versions used
  /// as a download destination.
  Future<List<String>> downloadFolders() async {
    final folders = <String>[];
    try {
      final documents = await documentsDirectory();
      if (documents != null && documents.isNotEmpty) {
        folders.add('$documents/$defaultDownloadFolderName');
      }
    } catch (_) {}
    try {
      final external = await externalDirectory();
      if (external != null && external.isNotEmpty) {
        folders.add('$external/$defaultDownloadFolderName');
      }
    } catch (_) {}
    return folders;
  }
}

class DefaultDownloadDirectory {
  const DefaultDownloadDirectory(
    this.directory, {
    required this.privateFallback,
  });

  final Directory directory;

  /// True when the shared default could not be used and [directory] is
  /// private app storage that stands in until access is granted.
  final bool privateFallback;
}

/// Picks the folder for downloads when the user chose none: the shared
/// `Music/MUSA` when it is writable, otherwise a private stand-in. The
/// stand-in is never persisted as a chosen folder.
Future<DefaultDownloadDirectory> resolveDefaultDownloadDirectory({
  required Future<Directory?> Function() sharedDefault,
  required Future<Directory> Function() privateDefault,
  required Future<bool> Function(Directory directory) isWritable,
}) async {
  try {
    final shared = await sharedDefault();
    if (shared != null && await isWritable(shared)) {
      return DefaultDownloadDirectory(shared, privateFallback: false);
    }
  } catch (_) {}
  return DefaultDownloadDirectory(
    await privateDefault(),
    privateFallback: true,
  );
}

/// Whether the queue must ask for access to all files before it starts.
bool shouldHoldQueueForStorageAccess({
  required bool isAndroid,
  required bool safMode,
  required bool networkOnly,
  required bool customFolder,
  required bool granted,
  required bool answered,
}) {
  if (!isAndroid || safMode || networkOnly || customFolder) return false;
  return !granted && !answered;
}
