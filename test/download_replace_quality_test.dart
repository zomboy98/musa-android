import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/quality_replace_result.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(isProcessing: true);
  }

  void finishLast({
    String? path,
    String? error,
    DownloadErrorType? errorType,
    bool removeAfter = false,
  }) {
    final last = state.items.last;
    updateItemStatus(
      last.id,
      path == null ? DownloadStatus.failed : DownloadStatus.completed,
      filePath: path,
      error: error,
      errorType: errorType,
    );
    if (removeAfter) removeCompletedItemForTesting(last.id);
  }
}

class _History extends DownloadHistoryNotifier {
  final removed = <String>[];

  @override
  DownloadHistoryState build() => DownloadHistoryState(items: const []);

  @override
  Future<void> removeFromHistory(String id) async => removed.add(id);

  @override
  Future<DownloadHistoryItem?> getByFilePathAsync(String filePath) async =>
      null;
}

const _track = Track(
  id: 'song',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ProviderContainer container;
  late _History history;
  late File previous;
  late File fresh;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('musa_replace_');
    previous = File('${dir.path}/song.flac')..writeAsStringSync('old');
    fresh = File('${dir.path}/song.m4a')..writeAsStringSync('new');
    history = _History();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(_Queue.new),
        downloadHistoryProvider.overrideWith(() => history),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<int?> sameDuration(String _) async => 180;

  Future<QualityReplaceResult> replace({
    String? finishWith,
    String? error,
    bool removeAfter = false,
    Future<bool> Function(String newPath)? onReady,
    Future<int?> Function(String path)? measure,
  }) async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final result = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      onReady: onReady,
      measureDuration: measure ?? sameDuration,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    queue.finishLast(path: finishWith, error: error, removeAfter: removeAfter);
    return result;
  }

  test('a finished download replaces the previous file and its row', () async {
    final result = await replace(finishWith: fresh.path);
    expect(result.path, fresh.path);
    expect(result.removedPrevious, isTrue);
    expect(previous.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(history.removed, ['old-row']);
  });

  test(
    'the new file takes the previous name instead of a quality suffix',
    () async {
      fresh.deleteSync();
      final variant = File('${dir.path}/song - 16bit-44.1kHz.flac')
        ..writeAsStringSync('new');
      final result = await replace(finishWith: variant.path);
      expect(
        result.path!.replaceAll(r'\', '/'),
        '${dir.path}/song.flac'.replaceAll(r'\', '/'),
      );
      expect(File('${dir.path}/song.flac').readAsStringSync(), 'new');
      expect(variant.existsSync(), isFalse);
      expect(
        dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
        ['song.flac'],
      );
    },
  );

  test(
    'a download that finishes and leaves the queue at once still replaces',
    () async {
      final result = await replace(finishWith: fresh.path, removeAfter: true);
      expect(result.ok, isTrue);
      expect(previous.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    },
  );

  test('a failed download keeps the previous file and says why', () async {
    final result = await replace(error: 'provider has no such format');
    expect(result.ok, isFalse);
    expect(result.failure, QualityReplaceFailure.downloadFailed);
    expect(result.detail, 'provider has no such format');
    expect(previous.existsSync(), isTrue);
    expect(history.removed, isEmpty);
  });

  test(
    'a refused playback switch still replaces the file and reports it',
    () async {
      final result = await replace(
        finishWith: fresh.path,
        onReady: (_) async => false,
      );
      expect(result.ok, isTrue);
      expect(result.switched, isFalse);
      expect(previous.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(history.removed, ['old-row']);
    },
  );

  test(
    'a playback switch that succeeds runs before the old file goes',
    () async {
      final seen = <bool>[];
      final result = await replace(
        finishWith: fresh.path,
        onReady: (path) async {
          seen.add(previous.existsSync() && File(path).existsSync());
          return true;
        },
      );
      expect(seen, [true]);
      expect(result.switched, isTrue);
      expect(previous.existsSync(), isFalse);
    },
  );

  test('a file of another duration is rejected, deleted and the previous '
      'file kept', () async {
    final result = await replace(
      finishWith: fresh.path,
      measure: (path) async => path == fresh.path ? 30 : 180,
    );
    expect(result.failure, QualityReplaceFailure.durationMismatch);
    expect(previous.existsSync(), isTrue);
    expect(fresh.existsSync(), isFalse);
    expect(history.removed, isEmpty);
  });

  test('an empty file is rejected and deleted', () async {
    fresh.writeAsBytesSync(const []);
    final result = await replace(finishWith: fresh.path);
    expect(result.failure, QualityReplaceFailure.emptyFile);
    expect(previous.existsSync(), isTrue);
    expect(fresh.existsSync(), isFalse);
  });

  test('a failed download carries its typed cause', () async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final pending = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      measureDuration: sameDuration,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    queue.finishLast(
      error: 'Requested quality unavailable from this provider',
      errorType: DownloadErrorType.qualityUnavailable,
    );
    final result = await pending;
    expect(result.failure, QualityReplaceFailure.downloadFailed);
    expect(result.errorType, DownloadErrorType.qualityUnavailable);
    expect(previous.existsSync(), isTrue);
  });

  test('the same file under another spelling of its path is not a '
      'replacement either', () async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final pending = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      measureDuration: sameDuration,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    queue.finishLast(path: Uri.file(previous.path).toString());
    expect((await pending).failure, QualityReplaceFailure.sameFile);
  });

  test('the same file coming back is not a replacement', () async {
    final result = await replace(finishWith: previous.path);
    expect(result.failure, QualityReplaceFailure.sameFile);
    expect(previous.existsSync(), isTrue);
  });

  test('the replacement can be requested again and again', () async {
    final second = File('${dir.path}/song.mp3')..writeAsStringSync('third');
    expect((await replace(finishWith: fresh.path)).path, fresh.path);
    previous = fresh;
    expect((await replace(finishWith: second.path)).path, second.path);
    expect(File('${dir.path}/song.flac').existsSync(), isFalse);
    expect(fresh.existsSync(), isFalse);
    expect(second.existsSync(), isTrue);
  });

  test(
    'cancelling a pending replacement releases it so the next one runs',
    () async {
      final queue = container.read(downloadQueueProvider.notifier) as _Queue;
      final pending = queue.replaceTrackQuality(
        _track,
        'tidal',
        'HIGH',
        previousPath: previous.path,
        previousHistoryId: 'old-row',
        measureDuration: sameDuration,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      queue.cancelTrackQualityReplacement(_track);
      final cancelled = await pending.timeout(const Duration(seconds: 2));
      expect(cancelled.failure, QualityReplaceFailure.cancelled);
      expect(previous.existsSync(), isTrue);
      final next = await replace(finishWith: fresh.path);
      expect(next.ok, isTrue);
    },
  );

  test('disposing the queue ends a pending replacement at once', () async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final pending = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      measureDuration: sameDuration,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    container.dispose();
    final result = await pending.timeout(const Duration(seconds: 2));
    expect(result.ok, isFalse);
    expect(previous.existsSync(), isTrue);
    container = ProviderContainer();
  });

  test('a replacement that never finishes times out and keeps the previous '
      'file', () async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final result = await queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      timeout: const Duration(milliseconds: 200),
      measureDuration: sameDuration,
    );
    expect(result.failure, QualityReplaceFailure.timedOut);
    expect(previous.existsSync(), isTrue);
  });
}
