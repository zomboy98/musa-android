import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/gyroscope_tilt_source.dart';

void main() {
  test('converts lists to offsets and clamps to -1..1', () async {
    final controller = StreamController<dynamic>();
    final source = GyroscopeTiltSource(streamFactory: () => controller.stream);
    final values = <Offset>[];
    final sub = source.changes.listen(values.add);
    controller.add(<double>[0.5, -0.25]);
    controller.add(<double>[3, -7]);
    controller.add(<int>[1, 0]);
    controller.add('basura');
    controller.add(<double>[double.nan, 0]);
    controller.add(<double>[0.1]);
    await Future<void>.delayed(Duration.zero);
    expect(values, const [Offset(0.5, -0.25), Offset(1, -1), Offset(1, 0)]);
    await sub.cancel();
    await controller.close();
  });

  test('subscribes to the platform only while someone listens', () async {
    var listens = 0;
    var cancels = 0;
    final controller = StreamController<dynamic>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    final source = GyroscopeTiltSource(streamFactory: () => controller.stream);
    expect(listens, 0);
    final sub = source.changes.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(listens, 1);
    expect(source.isActive, isTrue);
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(cancels, 1);
    expect(source.isActive, isFalse);
    final again = source.changes.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(listens, 2);
    await again.cancel();
    await controller.close();
  });

  test('an unavailable error ends the stream cleanly', () async {
    final controller = StreamController<dynamic>();
    final source = GyroscopeTiltSource(streamFactory: () => controller.stream);
    final values = <Offset>[];
    var done = false;
    var errored = false;
    source.changes.listen(
      values.add,
      onError: (Object _) => errored = true,
      onDone: () => done = true,
    );
    controller.addError(PlatformException(code: 'unavailable'));
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
    expect(errored, isFalse);
    expect(values, isEmpty);
    expect(source.isActive, isFalse);
    await controller.close();
  });

  test('a factory that throws ends the stream without leaking', () async {
    final source = GyroscopeTiltSource(
      streamFactory: () => throw MissingPluginException(),
    );
    var done = false;
    source.changes.listen((_) {}, onDone: () => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });
}
