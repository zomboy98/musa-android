import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

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

  void finishLast({String? path}) {
    final last = state.items.last;
    state = state.copyWith(
      items: [
        ...state.items.take(state.items.length - 1),
        last.copyWith(
          status: path == null
              ? DownloadStatus.failed
              : DownloadStatus.completed,
          filePath: path,
        ),
      ],
    );
  }
}

class _History extends DownloadHistoryNotifier {
  final removed = <String>[];

  @override
  DownloadHistoryState build() => DownloadHistoryState(items: const []);

  @override
  Future<void> removeFromHistory(String id) async => removed.add(id);
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

  Future<String?> replace({String? finishWith, bool fail = false}) async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final result = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    queue.finishLast(path: fail ? null : finishWith);
    return result;
  }

  test('a finished download replaces the previous file and its row', () async {
    final path = await replace(finishWith: fresh.path);
    expect(path, fresh.path);
    expect(previous.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(history.removed, ['old-row']);
  });

  test('a failed download keeps the previous file and its row', () async {
    final path = await replace(fail: true);
    expect(path, isNull);
    expect(previous.existsSync(), isTrue);
    expect(history.removed, isEmpty);
  });

  test('the previous file stays when playback refuses the new one', () async {
    final queue = container.read(downloadQueueProvider.notifier) as _Queue;
    final result = queue.replaceTrackQuality(
      _track,
      'tidal',
      'HIGH',
      previousPath: previous.path,
      previousHistoryId: 'old-row',
      onReady: (_) async => false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    queue.finishLast(path: fresh.path);
    expect(await result, isNull);
    expect(previous.existsSync(), isTrue);
    expect(history.removed, isEmpty);
  });

  test('the replacement can be requested again and again', () async {
    final second = File('${dir.path}/song.mp3')..writeAsStringSync('third');
    expect(await replace(finishWith: fresh.path), fresh.path);
    previous = fresh;
    expect(await replace(finishWith: second.path), second.path);
    expect(File('${dir.path}/song.flac').existsSync(), isFalse);
    expect(fresh.existsSync(), isFalse);
    expect(second.existsSync(), isTrue);
  });
}
