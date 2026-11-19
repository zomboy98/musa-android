import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/quality_mark.dart';

const qualityGold = Color(0xFFE0B04A);

const double minQualityTextSize = 11;

class QualityMarkText {
  const QualityMarkText(this.name, this.first, [this.second]);

  final String name;
  final String first;
  final String? second;
}

/// Name and two small description lines of each mark. A measured [detail]
/// (bitrate, depth and rate) replaces the generic second line.
QualityMarkText qualityMarkText(
  BuildContext context,
  QualityMark mark, {
  String? detail,
}) {
  final l10n = context.l10n;
  QualityMarkText pick(String name, String first, [String? second]) =>
      QualityMarkText(name, first, detail ?? second);
  QualityMarkText fixed(String name, String first, String second) =>
      QualityMarkText(name, first, second);
  return switch (mark) {
    QualityMark.atmos => QualityMarkText(
      'ATMOS',
      'Dolby Atmos',
      l10n.qualityFormatSpatial,
    ),
    QualityMark.dolbyPlus => QualityMarkText(
      'DD+',
      'Dolby Digital Plus',
      l10n.qualityFormatSurround,
    ),
    QualityMark.max => pick('MAX', 'Hi-Res', 'FLAC'),
    QualityMark.hiRes => pick('HI-RES', 'Hi-Res', 'Audio'),
    QualityMark.dsd => pick('DSD', 'Direct Stream', 'Digital'),
    QualityMark.lossless => pick(
      l10n.qualityFormatLossless.toUpperCase(),
      'Audio',
      'Lossless',
    ),
    QualityMark.flac => fixed('FLAC', 'Free Lossless', 'Audio Codec'),
    QualityMark.alac => fixed('ALAC', 'Apple Lossless', 'Audio Codec'),
    QualityMark.wav => fixed('WAV', 'Waveform', 'Audio File'),
    QualityMark.aiff => fixed('AIFF', 'Audio Interchange', 'File Format'),
    QualityMark.ape => fixed("APE", "Monkey's Audio", 'Lossless'),
    QualityMark.aac => pick('AAC', 'Advanced', 'Audio Coding'),
    QualityMark.m4a => pick('M4A', 'MPEG-4', 'Audio'),
    QualityMark.mp3 => pick('MP3', 'MPEG Layer III', 'Audio'),
    QualityMark.opus => pick('OPUS', 'Opus', 'Interactive Audio'),
    QualityMark.ogg => pick('OGG', 'Ogg Vorbis', 'Audio'),
    QualityMark.wma => pick('WMA', 'Windows Media', 'Audio'),
    QualityMark.lossy => pick(
      l10n.qualityFormatLossy.toUpperCase(),
      l10n.qualityFormatLossy,
      'Audio',
    ),
  };
}

/// Vector glyph of one format, drawn on a square of side [size].
class QualityMarkIcon extends StatelessWidget {
  const QualityMarkIcon({
    super.key,
    required this.mark,
    this.size = 24,
    this.color,
  });

  final QualityMark mark;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: QualityMarkPainter(mark, fg)),
    );
  }
}

/// Icon, thin rule, big format name, thin rule and two small lines: the form
/// of the timeline row. Text follows the system scale up to 1.3x and never
/// drops below 11 px; [compact] keeps only the icon and the name for narrow
/// rows.
class QualityMarkLockup extends StatelessWidget {
  const QualityMarkLockup({
    super.key,
    required this.mark,
    this.detail,
    this.size = 26,
    this.color,
    this.compact = false,
  });

  final QualityMark mark;
  final String? detail;
  final double size;
  final Color? color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    final text = qualityMarkText(context, mark, detail: detail);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final rule = Container(
      width: 1,
      height: size * 0.82,
      margin: EdgeInsets.symmetric(horizontal: size * 0.3),
      color: fg.withValues(alpha: 0.55),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        QualityMarkIcon(mark: mark, size: size, color: fg),
        rule,
        Flexible(
          child: Text(
            text.name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            textScaler: scaler,
            style: TextStyle(
              color: fg,
              fontSize: math.max(
                minQualityTextSize,
                size * (text.name.length > 5 ? 0.62 : 0.84),
              ),
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: size * 0.02,
            ),
          ),
        ),
        if (!compact) ...[
          rule,
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in [text.first, ?text.second])
                  Text(
                    line,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    textScaler: scaler,
                    style: TextStyle(
                      color: fg,
                      fontSize: math.max(minQualityTextSize, size * 0.37),
                      height: 1.15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class QualityMarkPainter extends CustomPainter {
  const QualityMarkPainter(this.mark, this.color);

  final QualityMark mark;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide;
    canvas.save();
    canvas.scale(u);
    final w = 0.075;
    Paint stroke([Color? c, double? width]) => Paint()
      ..color = c ?? color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width ?? w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    Paint fill([Color? c]) => Paint()
      ..color = c ?? color
      ..isAntiAlias = true;
    switch (mark) {
      case QualityMark.atmos:
      case QualityMark.dolbyPlus:
        _atmos(canvas, fill());
      case QualityMark.max:
        _max(canvas, fill());
      case QualityMark.hiRes:
        _hiRes(canvas, stroke, fill);
      case QualityMark.dsd:
        _dsd(canvas, stroke);
      case QualityMark.lossless:
        _lossless(canvas, stroke, fill);
      case QualityMark.flac:
        _flac(canvas, fill());
      case QualityMark.alac:
        _alac(canvas);
      case QualityMark.wav:
        _wav(canvas, stroke);
      case QualityMark.aiff:
        _document(canvas, stroke);
        _note(canvas, fill(), const Offset(0.5, 0.64), stroke);
      case QualityMark.ape:
        _document(canvas, stroke);
        _bars(canvas, stroke, 0.5, 0.64, const [0.12, 0.26, 0.18], 0.09);
      case QualityMark.aac:
        _aac(canvas, stroke, fill);
      case QualityMark.m4a:
        _m4a(canvas, stroke, fill);
      case QualityMark.mp3:
        _mp3(canvas, stroke, fill);
      case QualityMark.opus:
        _opus(canvas, stroke, fill);
      case QualityMark.ogg:
        _ogg(canvas);
      case QualityMark.wma:
        _wma(canvas, fill);
      case QualityMark.lossy:
        _lossy(canvas, stroke);
    }
    canvas.restore();
  }

  void _atmos(Canvas canvas, Paint fill) {
    const top = 0.2;
    const bottom = 0.8;
    const r = 0.36;
    const gap = 0.035;
    final left = Path()
      ..moveTo(0.5 - gap, top)
      ..lineTo(0.5 - gap - 0.2, top)
      ..arcToPoint(
        const Offset(0.5 - gap - 0.2, bottom),
        radius: const Radius.circular(r),
        clockwise: false,
      )
      ..lineTo(0.5 - gap, bottom)
      ..close();
    final right = Path()
      ..moveTo(0.5 + gap, top)
      ..lineTo(0.5 + gap + 0.2, top)
      ..arcToPoint(
        const Offset(0.5 + gap + 0.2, bottom),
        radius: const Radius.circular(r),
      )
      ..lineTo(0.5 + gap, bottom)
      ..close();
    canvas.drawPath(left, fill);
    canvas.drawPath(right, fill);
  }

  void _max(Canvas canvas, Paint fill) {
    canvas.saveLayer(Offset.zero & const Size(1, 1), Paint());
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.06, 0.14, 0.88, 0.72),
        const Radius.circular(0.16),
      ),
      fill,
    );
    final cut = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.085
      ..strokeCap = StrokeCap.round;
    const heights = [0.16, 0.28, 0.4, 0.28, 0.16];
    for (var i = 0; i < heights.length; i++) {
      final x = 0.26 + i * 0.12;
      canvas.drawLine(
        Offset(x, 0.5 - heights[i] / 2),
        Offset(x, 0.5 + heights[i] / 2),
        cut,
      );
    }
    canvas.restore();
  }

  void _hiRes(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    const c = Offset(0.5, 0.5);
    canvas.drawCircle(c, 0.44, fill(qualityGold.withValues(alpha: 0.2)));
    canvas.drawCircle(c, 0.44, stroke(qualityGold, 0.07));
    canvas.drawCircle(
      c,
      0.34,
      stroke(qualityGold.withValues(alpha: 0.55), 0.03),
    );
    _bars(
      canvas,
      ([c2, w2]) => stroke(qualityGold, w2),
      0.5,
      0.5,
      const [0.18, 0.34, 0.5, 0.34, 0.18],
      0.075,
      colored: true,
    );
  }

  void _bars(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    double cx,
    double cy,
    List<double> heights,
    double step, {
    bool colored = false,
  }) {
    final paint = stroke(null, 0.05);
    final start = cx - (heights.length - 1) * step / 2;
    for (var i = 0; i < heights.length; i++) {
      final x = start + i * step;
      canvas.drawLine(
        Offset(x, cy - heights[i] / 2),
        Offset(x, cy + heights[i] / 2),
        paint,
      );
    }
  }

  void _dsd(Canvas canvas, Paint Function([Color?, double?]) stroke) {
    final a = Path()
      ..moveTo(0.06, 0.62)
      ..cubicTo(0.28, 0.2, 0.46, 0.2, 0.62, 0.52)
      ..cubicTo(0.74, 0.74, 0.86, 0.64, 0.94, 0.4);
    final b = Path()
      ..moveTo(0.06, 0.8)
      ..cubicTo(0.28, 0.4, 0.46, 0.42, 0.62, 0.72)
      ..cubicTo(0.74, 0.92, 0.86, 0.84, 0.94, 0.62);
    canvas.drawPath(a, stroke(null, 0.1));
    canvas.drawPath(b, stroke(color.withValues(alpha: 0.55), 0.08));
  }

  void _lossless(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    const c = Offset(0.5, 0.5);
    const r = 0.44;
    final diamond = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(diamond, fill(color.withValues(alpha: 0.14)));
    canvas.drawPath(diamond, stroke(null, 0.07));
    _bars(canvas, stroke, 0.5, 0.5, const [0.2, 0.36, 0.2], 0.11);
  }

  void _flac(Canvas canvas, Paint fill) {
    const counts = [1, 2, 2, 3, 3];
    for (var row = 0; row < counts.length; row++) {
      for (var col = 0; col < counts[row]; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0.1 + col * 0.29, 0.1 + row * 0.18, 0.24, 0.12),
            const Radius.circular(0.03),
          ),
          fill,
        );
      }
    }
  }

  void _alac(Canvas canvas) {
    const heights = [0.3, 0.52, 0.8, 0.52, 0.3];
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [color, color.withValues(alpha: 0.35)],
    ).createShader(const Rect.fromLTWH(0, 0.1, 1, 0.8));
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < heights.length; i++) {
      final x = 0.14 + i * 0.18;
      canvas.drawLine(
        Offset(x, 0.5 - heights[i] / 2),
        Offset(x, 0.5 + heights[i] / 2),
        paint,
      );
    }
  }

  void _wav(Canvas canvas, Paint Function([Color?, double?]) stroke) {
    const points = [
      Offset(0.04, 0.5),
      Offset(0.2, 0.5),
      Offset(0.28, 0.24),
      Offset(0.37, 0.78),
      Offset(0.46, 0.1),
      Offset(0.56, 0.9),
      Offset(0.65, 0.3),
      Offset(0.73, 0.62),
      Offset(0.8, 0.5),
      Offset(0.96, 0.5),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, stroke(null, 0.06));
  }

  void _document(Canvas canvas, Paint Function([Color?, double?]) stroke) {
    final outline = Path()
      ..moveTo(0.2, 0.08)
      ..lineTo(0.6, 0.08)
      ..lineTo(0.82, 0.3)
      ..lineTo(0.82, 0.92)
      ..lineTo(0.2, 0.92)
      ..close();
    final fold = Path()
      ..moveTo(0.6, 0.08)
      ..lineTo(0.6, 0.3)
      ..lineTo(0.82, 0.3);
    canvas.drawPath(outline, stroke(null, 0.065));
    canvas.drawPath(fold, stroke(null, 0.065));
  }

  void _note(
    Canvas canvas,
    Paint fill,
    Offset centre,
    Paint Function([Color?, double?]) stroke,
  ) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centre.dx - 0.06, centre.dy + 0.1),
        width: 0.17,
        height: 0.13,
      ),
      fill,
    );
    final stem = Path()
      ..moveTo(centre.dx + 0.02, centre.dy + 0.08)
      ..lineTo(centre.dx + 0.02, centre.dy - 0.18)
      ..quadraticBezierTo(
        centre.dx + 0.1,
        centre.dy - 0.14,
        centre.dx + 0.1,
        centre.dy - 0.02,
      );
    canvas.drawPath(stem, stroke(null, 0.05));
  }

  void _aac(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    const centre = Offset(0.74, 0.5);
    for (final r in const [0.18, 0.34, 0.5]) {
      final rect = Rect.fromCircle(center: centre, radius: r);
      final path = Path()..addArc(rect, math.pi * 0.72, math.pi * 0.56);
      canvas.drawPath(path, stroke(null, 0.08));
    }
    canvas.drawCircle(centre, 0.07, fill());
  }

  void _m4a(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8),
        const Radius.circular(0.2),
      ),
      stroke(null, 0.07),
    );
    _note(canvas, fill(), const Offset(0.5, 0.5), stroke);
  }

  void _mp3(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    canvas.drawCircle(const Offset(0.5, 0.5), 0.42, stroke(null, 0.07));
    final tri = Path()
      ..moveTo(0.4, 0.3)
      ..lineTo(0.4, 0.7)
      ..lineTo(0.7, 0.5)
      ..close();
    canvas.drawPath(tri, fill());
    canvas.drawPath(tri, stroke(null, 0.03));
  }

  void _opus(
    Canvas canvas,
    Paint Function([Color?, double?]) stroke,
    Paint Function([Color?]) fill,
  ) {
    const centre = Offset(0.5, 0.5);
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: 0.4),
      -math.pi * 0.28,
      math.pi * 1.72,
      false,
      stroke(null, 0.09),
    );
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: 0.22),
      math.pi * 0.6,
      math.pi * 1.5,
      false,
      stroke(null, 0.08),
    );
    canvas.drawCircle(centre, 0.07, fill());
  }

  void _ogg(Canvas canvas) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'ogg',
        style: TextStyle(
          color: color,
          fontSize: 0.62,
          fontWeight: FontWeight.w900,
          height: 1,
          letterSpacing: -0.02,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((1 - painter.width) / 2, (1 - painter.height) / 2),
    );
  }

  void _wma(Canvas canvas, Paint Function([Color?]) fill) {
    final panes = <List<Offset>>[
      const [
        Offset(0.06, 0.2),
        Offset(0.46, 0.12),
        Offset(0.46, 0.46),
        Offset(0.06, 0.5),
      ],
      const [
        Offset(0.53, 0.11),
        Offset(0.94, 0.03),
        Offset(0.94, 0.43),
        Offset(0.53, 0.46),
      ],
      const [
        Offset(0.06, 0.56),
        Offset(0.46, 0.52),
        Offset(0.46, 0.86),
        Offset(0.06, 0.92),
      ],
      const [
        Offset(0.53, 0.52),
        Offset(0.94, 0.49),
        Offset(0.94, 0.95),
        Offset(0.53, 0.89),
      ],
    ];
    for (final pane in panes) {
      final path = Path()..moveTo(pane.first.dx, pane.first.dy);
      for (final p in pane.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path..close(), fill());
    }
  }

  void _lossy(Canvas canvas, Paint Function([Color?, double?]) stroke) {
    const centre = Offset(0.5, 0.5);
    const r = 0.42;
    const dashes = 12;
    const step = math.pi * 2 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: r),
        i * step,
        step * 0.58,
        false,
        stroke(color.withValues(alpha: 0.75), 0.065),
      );
    }
    _bars(canvas, stroke, 0.5, 0.5, const [0.3, 0.22, 0.14], 0.12);
  }

  @override
  bool shouldRepaint(QualityMarkPainter old) =>
      old.mark != mark || old.color != color;
}
