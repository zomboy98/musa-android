import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String response(String id) => jsonEncode([
    {
      'id': id,
      'name': id,
      'artist_name': 'Artist',
      'album_name': 'Album',
      'duration': 1000,
    },
  ]);

  Future<ProviderContainer> start(List<Completer<String>> requests) async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'customSearchWithExtension') return null;
      final result = Completer<String>();
      requests.add(result);
      return result.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('a refined search keeps the visible results while loading', () async {
    final requests = <Completer<String>>[];
    final container = await start(requests);
    final notifier = container.read(trackProvider.notifier);
    final first = notifier.customSearch(
      'keep-results-provider',
      'armenta',
      selectedFilter: 'artist',
    );
    await Future<void>.delayed(Duration.zero);
    requests[0].complete(response('first'));
    await first;
    expect(container.read(trackProvider).tracks.single.id, 'first');

    final second = notifier.customSearch(
      'keep-results-provider',
      'armentas',
      selectedFilter: 'artist',
    );
    await Future<void>.delayed(Duration.zero);
    final loading = container.read(trackProvider);
    expect(loading.isLoading, isTrue);
    expect(loading.tracks.single.id, 'first');

    requests[1].complete(response('second'));
    await second;
    final done = container.read(trackProvider);
    expect(done.isLoading, isFalse);
    expect(done.tracks.single.id, 'second');
  });

  test('another filter or provider starts from an empty list', () async {
    final requests = <Completer<String>>[];
    final container = await start(requests);
    final notifier = container.read(trackProvider.notifier);
    final first = notifier.customSearch(
      'other-filter-provider',
      'armenta',
      selectedFilter: 'artist',
    );
    await Future<void>.delayed(Duration.zero);
    requests[0].complete(response('first'));
    await first;

    unawaited(
      notifier.customSearch(
        'other-filter-provider',
        'armentas',
        selectedFilter: 'track',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(trackProvider).tracks, isEmpty);
    expect(container.read(trackProvider).isLoading, isTrue);
  });
}
