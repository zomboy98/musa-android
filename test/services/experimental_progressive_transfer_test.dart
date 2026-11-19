import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/experimental_progressive_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/experimental_progressive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String id;
  late List<String> calls;
  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') { id = (call.arguments as Map)['attemptId'] as String; return true; }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> emit(String kind, {String? result}) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('event', {
      'attemptId': id, 'kind': kind, if (result != null) 'resultJson': result,
    }));
    await messenger.handlePlatformMessage(channel.name, data, (_) {});
  }

  test('disabled flag never invokes native channel', () async {
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    expect(await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: false), isNull);
    expect(calls, isEmpty);
    await transfer.dispose();
  });

  test('attached and completed are independent, then cancellation revokes', () async {
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    final attempt = (await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: true))!;
    await emit('attached');
    expect(await attempt.sourceAttached, isTrue);
    await emit('result', result: '{"success":true}');
    expect(await attempt.result, '{"success":true}');
    await attempt.cancel();
    await emit('fallback');
    expect(calls, ['start', 'cancel']);
    await transfer.dispose();
  });

  test('fallback and cancellation do not claim an attached source', () async {
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    final attempt = (await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: true))!;
    await emit('fallback');
    expect(await attempt.sourceAttached, isFalse);
    expect(await attempt.result, isNull);
    await attempt.cancel();
    await transfer.dispose();
  });

  test('cancellation waits for native acknowledgement and is idempotent', () async {
    final acknowledgement = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') { id = (call.arguments as Map)['attemptId'] as String; return true; }
      if (call.method == 'cancel') return acknowledgement.future;
      return null;
    });
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    final attempt = (await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: true))!;
    var finished = false;
    final first = attempt.cancel().then((value) { finished = true; return value; });
    final second = attempt.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    await emit('attached');
    expect(await attempt.sourceAttached, isFalse);
    acknowledgement.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(calls, ['start', 'cancel']);
    await transfer.dispose();
  });

  test('failure is not reported as a fallback', () async {
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    final attempt = (await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: true))!;
    final result = expectLater(attempt.result, throwsStateError);
    await emit('failed');
    await result;
    await attempt.cancel();
    await transfer.dispose();
  });

  test('retirement remains separate after result and is delivered once', () async {
    final transfer = ExperimentalProgressiveTransfer(channel: channel);
    final attempt = (await transfer.start(playerId: 'p', requestJson: '{}', enabledForTesting: true))!;
    await emit('attached'); await emit('result', result: '{"success":true}');
    expect(await attempt.result, '{"success":true}');
    final event = const StandardMethodCodec().encodeMethodCall(MethodCall('event', {
      'attemptId': id, 'kind': 'retired', 'positionMs': 1234,
    }));
    await messenger.handlePlatformMessage(channel.name, event, (_) {});
    expect(await attempt.retired, const Duration(milliseconds: 1234));
    await messenger.handlePlatformMessage(channel.name, event, (_) {});
    await transfer.dispose();
  });

  test('two owners share router; disposing one keeps the other active', () async {
    final ids = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') { ids.add((call.arguments as Map)['attemptId'] as String); return true; }
      if (call.method == 'cancel') return true;
      return null;
    });
    final first = ExperimentalProgressiveTransfer(channel: channel);
    final second = ExperimentalProgressiveTransfer(channel: channel);
    final a = (await first.start(playerId: 'a', requestJson: '{}', enabledForTesting: true))!;
    final b = (await second.start(playerId: 'b', requestJson: '{}', enabledForTesting: true))!;
    expect(ids[0], isNot(ids[1]));
    await first.dispose();
    expect(await a.sourceAttached, isFalse);
    id = ids[1];
    await emit('attached');
    expect(await b.sourceAttached, isTrue);
    await emit('result', result: '{"success":true}');
    expect(await b.result, '{"success":true}');
    await second.dispose();
  });
}
