import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/home_tab.dart';

import 'support/search_results_fixture.dart';

String _color(Color? color) =>
    color == null ? 'none' : color.toARGB32().toRadixString(16).padLeft(8, '0');

String _style(TextStyle? style) {
  if (style == null) return 'style none';
  return 'style ${style.fontFamily} ${style.fontSize} '
      '${style.fontWeight?.value} ${style.height} ${style.letterSpacing} '
      '${_color(style.color)} ${style.decoration}';
}

String _span(InlineSpan span) {
  final parts = <String>[];
  span.visitChildren((child) {
    if (child is TextSpan) {
      parts.add('${_style(child.style)} "${child.text ?? ''}"');
    } else {
      parts.add('placeholder');
    }
    return true;
  });
  return parts.join(' | ');
}

String _border(BoxBorder? border) {
  if (border == null) return 'none';
  return '${border.isUniform} ${border.top.width}:${_color(border.top.color)} '
      '${border.bottom.width}:${_color(border.bottom.color)} '
      '${border.dimensions}';
}

String _decoration(Decoration decoration) {
  if (decoration is! BoxDecoration) return '${decoration.runtimeType}';
  final gradient = decoration.gradient;
  return '${_color(decoration.color)} ${decoration.shape} '
      '${decoration.borderRadius} ${_border(decoration.border)} '
      '${gradient == null ? 'none' : gradient.colors.map(_color).join(',')} '
      '${decoration.boxShadow?.length ?? 0}';
}

/// What the Search tab paints, as text: every painting box with its global
/// rect and paint attributes, in paint order. Layout-only wrappers are left
/// out, so moving code between widgets keeps the fingerprint while any
/// change to the pixels changes it.
String _paintFingerprint(WidgetTester tester) {
  final lines = <String>[];
  String rect(RenderBox box) {
    final r = box.localToGlobal(Offset.zero) & box.size;
    return '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
        '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';
  }

  void visit(RenderObject object) {
    if (object is RenderBox && object.hasSize) {
      final description = switch (object) {
        RenderParagraph() => 'text ${_span(object.text)}',
        RenderDecoratedBox() => 'box ${_decoration(object.decoration)}',
        RenderPhysicalShape() =>
          'shape ${_color(object.color)} ${object.elevation} '
              '${object.clipper.runtimeType}',
        RenderPhysicalModel() =>
          'model ${_color(object.color)} ${object.elevation} '
              '${object.borderRadius}',
        RenderClipRRect() => 'clip ${object.borderRadius}',
        RenderClipPath() => 'path ${object.clipper.runtimeType}',
        RenderClipOval() => 'oval',
        RenderImage() => 'image',
        RenderOpacity() => 'opacity ${object.opacity}',
        RenderCustomPaint() =>
          'paint ${object.painter?.runtimeType} '
              '${object.foregroundPainter?.runtimeType}',
        _ => null,
      };
      if (description != null) lines.add('${rect(object)} $description');
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(HomeTab)));
  return lines.join('\n');
}

/// SHA-1 of each fingerprint, recorded on the base layout (commit 44cbb57b)
/// before search results gained cover grids and shelves on wide screens, with
/// every value re-recorded once the fingerprint stopped printing colors and
/// styles through Flutter's own diagnostics text, and before that the Material
/// values re-recorded when sort and view became a grouped
/// toolbar, the Material desktop value when Home took M3's 24dp window
/// margin, and the Mornye values when blue became the default accent and the
/// filter chips gained their glass press layer, then the OLED redesign opened
/// the result rows and removed the extra glass panels around filters, and
/// the Artists rows gained their placeholder and image fade.
/// A narrow layout must paint
/// exactly these.
/// A deliberate change to
/// the phone rows records new values; the failure prints the fingerprint.
const _baseFingerprints = {
  'phone Material': 'a2bd2a78e91d5d0f1c0f7febdbc67aacf3016b78',
  'phone Mornye': '755340096e3ad6617c3d0ac6760bca9f919c6410',
  'landscape phone Material': '9ba1484ccb31d66b50727e1c9ae94a8a6b96ef8e',
  'landscape phone Mornye': '58668fa833f70bc5e6c5a58c7b4e913ef92d95ed',
  'portrait tablet Material': 'e5a996883fbb0e4bce5398a4461b2e312c9b8026',
  'portrait tablet Mornye': 'd96d4768792721d3ddb9fbc91f78657b8659b08b',
  'narrow desktop window Material': 'de09e8f66ef6853dded255cd89aa21169b6a90d0',
  'narrow desktop window Mornye': 'a80f4efffd519d1779bff9f4b206f5151cdecfdd',
};

void main() {
  for (final (name, size, desktop) in [
    ('phone', const Size(430, 1400), false),
    ('landscape phone', const Size(932, 430), false),
    ('portrait tablet', const Size(800, 1280), false),
    ('narrow desktop window', const Size(820, 1400), true),
  ]) {
    for (final mornye in [false, true]) {
      final key = '$name ${mornye ? 'Mornye' : 'Material'}';
      testWidgets('Search results on a $key paint the base layout', (
        tester,
      ) async {
        await pumpSearchFixture(
          tester,
          size: size,
          mornye: mornye,
          desktop: desktop,
        );
        expect(find.text('Found track 0'), findsOneWidget);
        if (size.height > 1000) {
          expect(find.text('Found artist 0'), findsOneWidget);
          expect(
            tester.getTopLeft(find.text('Found track 0')).dy,
            lessThan(tester.getTopLeft(find.text('Found artist 0')).dy),
          );
        }
        expect(find.byType(SliverGrid), findsNothing);

        final fingerprint = _paintFingerprint(tester);
        final hash = sha1.convert(utf8.encode(fingerprint)).toString();
        final expected = _baseFingerprints[key];
        if (hash != expected) debugPrint('$key: $hash\n$fingerprint');
        expect(hash, expected);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
