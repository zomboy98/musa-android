import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/feedback/feedback_image_processor.dart';
import 'package:mornye/services/feedback/feedback_store.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Size> _size(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final size = ui.Size(
    frame.image.width.toDouble(),
    frame.image.height.toDouble(),
  );
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  testWidgets('wide photos are capped to 1600 px on the long side', (t) async {
    await t.runAsync(() async {
      final out = await FeedbackImageProcessor.shrinkToPng(
        await _png(3200, 2000),
      );
      expect(await _size(out!), const ui.Size(1600, 1000));
    });
  });

  testWidgets('tall photos are capped and small ones are kept', (t) async {
    await t.runAsync(() async {
      final tall = await FeedbackImageProcessor.shrinkToPng(
        await _png(1000, 4000),
      );
      expect(await _size(tall!), const ui.Size(400, 1600));
      final small = await FeedbackImageProcessor.shrinkToPng(
        await _png(800, 600),
      );
      expect(await _size(small!), const ui.Size(800, 600));
    });
  });

  testWidgets('prepare returns a png attachment or null for bad data', (
    t,
  ) async {
    await t.runAsync(() async {
      final ok = await FeedbackImageProcessor.prepare(
        FeedbackImage(name: 'IMG_1.jpg', bytes: await _png(10, 10)),
      );
      expect(ok!.name, 'IMG_1.png');
      expect(ok.bytes, isNotNull);
      final bad = await FeedbackImageProcessor.prepare(
        FeedbackImage(name: 'x.jpg', bytes: Uint8List.fromList([1, 2, 3])),
      );
      expect(bad, isNull);
    });
  });
}
