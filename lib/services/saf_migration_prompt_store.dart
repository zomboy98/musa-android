import 'dart:io';

import 'package:mornye/constants/storage_defaults.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the one-time SAF migration prompt was already shown.
class SafMigrationPromptStore {
  const SafMigrationPromptStore();

  static const _shownKey = 'saf_migration_prompt_shown';

  Future<bool> wasShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shownKey) == true;
  }

  Future<void> markShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shownKey, true);
  }

  static bool isCandidate(String storageMode, String directory) =>
      storageMode != 'saf' && directory.isNotEmpty;

  Future<bool> markShownIfNeeded(
    String directory, {
    required String storageMode,
    Future<Directory> Function() documentsDirectory =
        getApplicationDocumentsDirectory,
  }) async {
    if (await wasShown()) return false;
    if (storageMode == 'app' &&
        await _isPrivateDefault(directory, documentsDirectory)) {
      return false;
    }
    await markShown();
    return true;
  }

  Future<bool> _isPrivateDefault(
    String directory,
    Future<Directory> Function() documentsDirectory,
  ) async {
    // Normalizing ".." could hide traversal through an intermediate link.
    if (!p.isAbsolute(directory) || p.split(directory).contains('..')) {
      return false;
    }
    try {
      final documents = p.normalize((await documentsDirectory()).path);
      final expected = p.join(documents, defaultDownloadFolderName);
      if (!p.isAbsolute(documents) || p.normalize(directory) != expected) {
        return false;
      }
      if (await FileSystemEntity.type(documents, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
      final root = Directory(documents);
      final canonicalDocuments = await root.resolveSymbolicLinks();
      final destination = p.join(canonicalDocuments, defaultDownloadFolderName);
      final type = await FileSystemEntity.type(destination, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        if (!p.equals(
          await Directory(destination).resolveSymbolicLinks(),
          destination,
        )) {
          return false;
        }
      } else {
        if (type != FileSystemEntityType.notFound) return false;
        // A successful parent listing corroborates absence when stat alone
        // cannot distinguish a missing entry from an inaccessible one.
        if (await Directory(canonicalDocuments)
            .list(followLinks: false)
            .any((entry) => p.equals(entry.path, destination))) {
          return false;
        }
      }

      // Revalidate the provider path after probing the destination. These
      // path-based checks detect changes across reads but are not atomic.
      return p.equals(await root.resolveSymbolicLinks(), canonicalDocuments) &&
          await FileSystemEntity.type(documents, followLinks: false) ==
              FileSystemEntityType.directory;
    } on Exception {
      return false;
    }
  }
}
