import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> row(String id, String name, String artist) => {
  'id': id,
  'name': name,
  'artists': artist,
  'album_name': 'Album',
  'duration_ms': 1000,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<({ProviderContainer container, List<Map<Object?, Object?>> calls})>
  run(
    String query, {
    required Map<String, Object? Function()> answers,
    String filter = 'track',
  }) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'customSearchWithExtension') return null;
      final args = call.arguments as Map<Object?, Object?>;
      calls.add(args);
      final answer = answers[args['query']];
      if (answer == null) return jsonEncode(<Object?>[]);
      return jsonEncode(answer());
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(trackProvider.notifier)
        .customSearch(
          'deezer',
          query,
          options: {'filter': filter},
          selectedFilter: filter,
        );
    return (container: container, calls: calls);
  }

  final general = [
    row('g1', 'Alpha', 'Mira Sol'),
    row('g2', 'Beta', 'Mira Sol'),
  ];
  final targeted = [row('t1', 'MIRA SOL', 'Otro Nombre')];

  test(
    'the song whose title is the text goes above the artist songs',
    () async {
      final result = await run(
        'mira sol',
        answers: {
          'mira sol': () => general,
          'track:"mira sol"': () => targeted,
        },
      );
      expect(result.container.read(trackProvider).tracks.map((t) => t.id), [
        't1',
        'g1',
        'g2',
      ]);
      expect(result.calls.length, 2);
      expect(result.calls.map((c) => jsonDecode(c['options'] as String)), [
        {'filter': 'track', 'limit': songLimit},
        {'filter': 'track', 'limit': songLimit},
      ]);
    },
  );

  test('a compound text adds a third, title-and-artist query', () async {
    final result = await run(
      'luz roja de mira sol',
      answers: {
        'luz roja de mira sol': () => general,
        'track:"luz roja" mira sol': () => [row('c1', 'Luz Roja', 'Mira Sol')],
      },
    );
    expect(result.calls.length, 3);
    expect(result.container.read(trackProvider).tracks.first.id, 'c1');
  });

  test('a failing targeted query does not break the search', () async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'customSearchWithExtension') return null;
      if ((call.arguments as Map<Object?, Object?>)['query'] != 'sol dos') {
        throw PlatformException(code: 'boom');
      }
      return jsonEncode(general);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(trackProvider.notifier)
        .customSearch(
          'deezer',
          'sol dos',
          options: {'filter': 'track'},
          selectedFilter: 'track',
        );
    final state = container.read(trackProvider);
    expect(state.error, isNull);
    expect(state.tracks.map((t) => t.id), ['g1', 'g2']);
  });

  test('a failing plain query still shows the targeted songs', () async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'customSearchWithExtension') return null;
      if ((call.arguments as Map<Object?, Object?>)['query'] == 'sol tres') {
        throw PlatformException(code: 'boom');
      }
      return jsonEncode(targeted);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(trackProvider.notifier)
        .customSearch(
          'deezer',
          'sol tres',
          options: {'filter': 'track'},
          selectedFilter: 'track',
        );
    final state = container.read(trackProvider);
    expect(state.error, isNull);
    expect(state.tracks.map((t) => t.id), ['t1']);
  });

  test('a provider without the syntax gets one query', () async {
    SharedPreferences.setMockInitialValues({});
    final calls = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'customSearchWithExtension') return null;
      calls.add((call.arguments as Map<Object?, Object?>)['query']);
      return jsonEncode(general);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(trackProvider.notifier)
        .customSearch(
          'other-provider',
          'sol cuatro',
          options: {'filter': 'track'},
          selectedFilter: 'track',
        );
    expect(calls, ['sol cuatro']);
  });

  test('a link is searched once and untouched', () async {
    final result = await run(
      'https://example.test/track/1',
      answers: {'https://example.test/track/1': () => general},
    );
    expect(result.calls.length, 1);
  });
}

const songLimit = 30;
