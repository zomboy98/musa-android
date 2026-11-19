import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/library_database.dart';

/// The entire filtered ID set; song models remain lazy until an action needs them.
final libraryQueryIdsLoaderProvider =
    Provider<Future<List<String>> Function(QueueLibraryDbQuery)>((ref) {
      return LibraryDatabase.instance.getQueueTrackIds;
    });
