import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_redownload_service.dart';

/// Catalog track that a scanned local file corresponds to, for offering the
/// provider qualities of a file that carries no provider ids. Null when the
/// file is not indexed or no provider match is confident.
final localFileCatalogTrackProvider = FutureProvider.autoDispose
    .family<Track?, String>((ref, filePath) async {
      final database = LibraryDatabase.instance;
      for (final id in await database.getPhysicalFileIds([filePath])) {
        final row = await database.getById(id);
        if (row == null) continue;
        final resolution = await LocalTrackRedownloadService.resolveBestMatch(
          LocalLibraryItem.fromJson(row),
          includeExtensions: true,
        );
        if (resolution.match != null) return resolution.match;
      }
      return null;
    });

/// Download history row of the file at [filePath], found by its physical
/// path keys rather than by exact text, so a row stored under another form of
/// the same path, or beyond the rows kept in memory, is still found.
final downloadHistoryForFileProvider = FutureProvider.autoDispose
    .family<DownloadHistoryItem?, String>((ref, filePath) async {
      try {
        return await ref
            .read(downloadHistoryProvider.notifier)
            .getByFilePathAsync(filePath);
      } catch (_) {
        return null;
      }
    });
