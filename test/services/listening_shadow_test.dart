import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_shadow.dart';

void main() {
  test('serializes events and applies the preceding snapshot', () async {
    final calls = <Map<String, dynamic>>[];
    final first = Completer<Map<String, dynamic>>();
    final shadow = ListeningShadow(
      run: (request) {
        calls.add(request);
        if (calls.length == 1) return first.future;
        return Future.value({
          'version': 2,
          'state': request['state'],
          'batches': [],
        });
      },
    );
    shadow.submit({'type': 'reset'});
    shadow.submit({'type': 'enabled', 'value': false});
    expect(calls.length, 1);
    final state = Map<String, dynamic>.from(calls.first['state'] as Map);
    state['enabled'] = false;
    first.complete({'version': 2, 'state': state, 'batches': []});
    await shadow.drain();
    expect(calls.length, 2);
    expect(calls[1]['state']['enabled'], false);
    expect(calls[1]['events'][0]['type'], 'enabled');
  });

  test('divergence disables the observer permanently', () async {
    final shadow = ListeningShadow(
      run: (request) async => {
        'version': 2,
        'state': request['state'],
        'batches': [[]],
      },
    );
    shadow.submit(
      {'type': 'advance', 'segments': []},
      expected: [
        {'day': '2026-01-01', 'track': '1', 'milliseconds': 1, 'plays': 0},
      ],
    );
    await shadow.drain();
    expect(shadow.active, false);
  });

  test(
    'timeout and late response cannot revive an invalidated observer',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final shadow = ListeningShadow(
        run: (_) => pending.future,
        timeout: const Duration(milliseconds: 10),
      );
      shadow.submit({'type': 'reset'});
      await shadow.drain();
      expect(shadow.active, false);
      pending.complete({'version': 2, 'state': {}, 'batches': []});
      await Future<void>.delayed(Duration.zero);
      expect(shadow.active, false);
    },
  );

  test('saturation invalidates the observer without throwing', () async {
    final pending = Completer<Map<String, dynamic>>();
    final shadow = ListeningShadow(
      run: (_) => pending.future,
      maxQueuedEvents: 1,
    );
    shadow.submit({'type': 'reset'});
    shadow.submit({'type': 'reset'});
    shadow.submit({'type': 'reset'});
    expect(shadow.active, false);
    pending.complete({'version': 2, 'state': {}, 'batches': []});
    await shadow.drain();
  });

  test('copies queued events and ignores a reply after invalidation', () async {
    final pending = Completer<Map<String, dynamic>>();
    final calls = <Map<String, dynamic>>[];
    final shadow = ListeningShadow(
      run: (request) {
        calls.add(request);
        return pending.future;
      },
    );
    shadow.submit({'type': 'reset'});
    final event = <String, dynamic>{'type': 'enabled', 'value': false};
    shadow.submit(event);
    event['value'] = true;
    final state = Map<String, dynamic>.from(calls.first['state'] as Map);
    pending.complete({'version': 2, 'state': state, 'batches': []});
    await shadow.drain();
    expect(calls[1]['events'][0]['value'], false);
    shadow.invalidate();
    shadow.submit({'type': 'reset'});
    expect(shadow.active, false);
    expect(calls.length, 2);
  });

  test('synchronous runner exceptions never escape', () async {
    final shadow = ListeningShadow(run: (_) => throw StateError('private'));
    expect(() => shadow.submit({'type': 'reset'}), returnsNormally);
    await shadow.drain();
    expect(shadow.active, false);
  });

  test('byte and segment limits disable without invoking the runner', () {
    var calls = 0;
    final bytes = ListeningShadow(
      run: (_) async {
        calls++;
        return {};
      },
      maxQueuedBytes: 10,
    );
    bytes.submit({'type': 'reset'});
    expect(bytes.active, false);
    final segments = ListeningShadow(
      run: (_) async {
        calls++;
        return {};
      },
      maxSegments: 1,
    );
    segments.submit({
      'type': 'advance',
      'segments': [{}, {}],
    }, expected: []);
    expect(segments.active, false);
    expect(calls, 0);
  });

  test(
    'compares delta values independent of JSON object field order',
    () async {
      final shadow = ListeningShadow(
        run: (request) async => {
          'version': 2,
          'state': request['state'],
          'batches': [
            [
              {
                'plays': 0,
                'milliseconds': 1,
                'track': '1',
                'day': '2026-01-01',
              },
            ],
          ],
        },
      );
      shadow.submit(
        {
          'type': 'advance',
          'segments': [
            {'day': '2026-01-01', 'milliseconds': 1},
          ],
        },
        expected: [
          {'day': '2026-01-01', 'track': '1', 'milliseconds': 1, 'plays': 0},
        ],
      );
      await shadow.drain();
      expect(shadow.active, true);
    },
  );

  test('rejects malformed or unreachable snapshots', () async {
    for (final change in <Map<String, dynamic>>[
      {'version': 2},
      {'session_ms': -1},
      {'session_ms': 30000},
      {'counted': true},
      {'track': 'é' * 513},
      {'track': 2},
      {'track': null, 'session_ms': 1},
    ]) {
      final shadow = ListeningShadow(
        run: (request) async {
          final state = Map<String, dynamic>.from(request['state'] as Map)
            ..addAll(change);
          return {'version': 2, 'state': state, 'batches': []};
        },
      );
      shadow.submit({'type': 'reset'});
      await shadow.drain();
      expect(shadow.active, false, reason: '$change');
    }
  });

  test('hard native segment cap applies even with a larger configured cap', () {
    var calls = 0;
    final shadow = ListeningShadow(
      maxSegments: 10000,
      run: (_) async {
        calls++;
        return {};
      },
    );
    shadow.submit({
      'type': 'advance',
      'segments': List.filled(4097, {}),
    }, expected: []);
    expect(shadow.active, false);
    expect(calls, 0);
  });

  test('non-integer expected delta is rejected', () async {
    final shadow = ListeningShadow(
      run: (request) async => {
        'version': 2,
        'state': request['state'],
        'batches': [
          [
            {'day': 'd', 'track': '1', 'milliseconds': 1, 'plays': 0},
          ],
        ],
      },
    );
    shadow.submit(
      {'type': 'advance', 'segments': []},
      expected: [
        {'day': 'd', 'track': '1', 'milliseconds': 1.0, 'plays': 0},
      ],
    );
    await shadow.drain();
    expect(shadow.active, false);
  });

  test(
    'rejects oversized strings and unexpected nested data before driver',
    () {
      var calls = 0;
      for (final event in <Map<String, dynamic>>[
        {
          'type': 'update',
          'track': 'x' * 1000000,
          'playing': true,
          'ended': false,
        },
        {
          'type': 'reset',
          'metadata': {'path': 'secret'},
        },
        {
          'type': 'advance',
          'segments': [
            {
              'day': ['nested'],
              'milliseconds': 1,
            },
          ],
        },
      ]) {
        final shadow = ListeningShadow(
          run: (_) async {
            calls++;
            return {};
          },
        );
        shadow.submit(event, expected: event['type'] == 'advance' ? [] : null);
        expect(shadow.active, false);
      }
      expect(calls, 0);
    },
  );

  test('rejects numeric protocol versions represented as doubles', () async {
    for (final stateVersion in [false, true]) {
      final shadow = ListeningShadow(
        run: (request) async {
          final state = Map<String, dynamic>.from(request['state'] as Map);
          if (stateVersion) state['version'] = 1.0;
          return {
            'version': stateVersion ? 2 : 2.0,
            'state': state,
            'batches': [],
          };
        },
      );
      shadow.submit({'type': 'reset'});
      await shadow.drain();
      expect(shadow.active, false);
    }
  });

  test('rejects excessive aggregate payload before running', () {
    var calls = 0;
    final shadow = ListeningShadow(
      run: (_) async {
        calls++;
        return {};
      },
    );
    shadow.submit({
      'type': 'advance',
      'segments': List.generate(
        2000,
        (_) => {'day': 'd' * 32, 'milliseconds': 1},
      ),
    }, expected: []);
    expect(shadow.active, false);
    expect(calls, 0);
  });
}
