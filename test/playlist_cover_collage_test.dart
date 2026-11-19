import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mornye/widgets/playlist_cover_collage.dart';
import 'package:mornye/widgets/app_icon.dart';

void main() {
  test('selects up to four distinct nonempty covers in order', () {
    expect(playlistCollageSources([null, '', '  ']), isEmpty);
    expect(playlistCollageSources(['a']), ['a']);
    expect(playlistCollageSources(['a', 'a', 'b']), ['a', 'b']);
    expect(playlistCollageSources(['a', 'b', 'c', 'd', 'e']), [
      'a',
      'b',
      'c',
      'd',
    ]);
  });

  testWidgets('renders rectangular local artwork and falls back when missing', (
    tester,
  ) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('collage-art-'),
    );
    final directory = dir!;
    addTearDown(() async {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Windows may briefly retain the image file after the test runner exits.
      }
    });
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 40, 20),
      Paint()..color = Colors.red,
    );
    final picture = recorder.endRecording();
    final file = File('${directory.path}/rect.png');
    await tester.runAsync(() async {
      final bitmap = await picture.toImage(40, 20);
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 40);
      expect(frame.image.height, 20);
      frame.image.dispose();
      codec.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 100,
          height: 100,
          child: PlaylistCoverCollage(sources: [file.uri.toString()]),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<FileImage>());
    expect(image.fit, BoxFit.cover);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 100,
          height: 100,
          child: PlaylistCoverCollage(
            sources: ['${directory.path}/missing.png'],
          ),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
