import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/cover_collage_backdrop.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settled_blur.dart';

List<String> _files(int n) => [for (var i = 0; i < n; i++) 'file:///x/$i.png'];

Future<void> _pump(
  WidgetTester tester,
  List<String> sources, {
  Size size = const Size(360, 800),
  bool highContrast = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, highContrast: highContrast),
        child: Scaffold(
          body: SizedBox(
            width: size.width,
            height: size.height * 0.7,
            child: CoverCollageBackdrop(sources: sources),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('deduplica y rellena la rejilla', () {
    expect(collageGridTiles([null, '', ' ']).tiles, isEmpty);
    expect(collageGridTiles(['a']).tiles, ['a']);
    expect(collageGridTiles(['a', 'a', 'b']).tiles, ['a', 'b', 'a', 'b']);
    expect(collageGridTiles(['a', 'b', 'c']).tiles, ['a', 'b', 'c', 'a']);
    expect(collageGridTiles(['a', 'b', 'c', 'd', 'e']).columns, 2);
    final nine = collageGridTiles([for (var i = 0; i < 20; i++) 'u${i % 12}']);
    expect(nine.columns, 3);
    expect(nine.tiles.toSet().length, 9);
  });

  test('altura limitada por ancho y por el alto del viewport', () {
    expect(collageHeaderHeight(const Size(360, 800)), 360);
    expect(collageHeaderHeight(const Size(412, 915)), 412);
    expect(collageHeaderHeight(const Size(360, 600)), closeTo(276, 0.001));
    expect(collageHeaderHeight(const Size(800, 360)), closeTo(144, 0.001));
  });

  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets('la rejilla cubre el ancho completo en $size', (tester) async {
      await _pump(tester, _files(9), size: size);
      final grid = find.byKey(const ValueKey('collage_backdrop_grid'));
      expect(tester.getSize(grid).width, size.width);
      expect(tester.getTopLeft(grid).dx, 0);
      expect(tester.getSize(grid).height, size.width);
      expect(find.byType(PlayerArtwork), findsNWidgets(18));
    });
  }

  testWidgets('hay degradado inferior y resplandor borroso', (tester) async {
    await _pump(tester, _files(9));
    expect(find.byKey(const ValueKey('collage_backdrop_fade')), findsOneWidget);
    expect(find.byType(SettledBlur), findsOneWidget);
  });

  testWidgets('con alto contraste no hay blur', (tester) async {
    await _pump(tester, _files(9), highContrast: true);
    expect(find.byType(SettledBlur), findsNothing);
    expect(find.byKey(const ValueKey('collage_backdrop_glow')), findsNothing);
    expect(find.byType(PlayerArtwork), findsNWidgets(9));
  });

  testWidgets('pocas portadas rellenan la rejilla y sin portadas hay icono', (
    tester,
  ) async {
    await _pump(tester, _files(2));
    expect(find.byType(PlayerArtwork), findsNWidgets(8));
    await _pump(tester, const []);
    expect(find.byType(PlayerArtwork), findsNothing);
    expect(find.byIcon(Icons.queue_music), findsWidgets);
  });
}
