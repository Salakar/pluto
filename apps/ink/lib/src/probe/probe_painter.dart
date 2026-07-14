import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

const int _polylineCount = 200;
const int _circleCount = 50;

/// Deterministic full-viewport load used by the frame-timing probe.
final class ProbeLoadPainter extends CustomPainter {
  ProbeLoadPainter({required ValueListenable<int> frame})
    : _frame = frame,
      _polylines = _buildPolylines(),
      _circles = _buildCircles(),
      super(repaint: frame);

  final ValueListenable<int> _frame;
  final List<List<ui.Offset>> _polylines;
  final List<_ProbeCircle> _circles;

  static const List<ui.Color> _grays = <ui.Color>[
    ui.Color(0xFF111111),
    ui.Color(0xFF333333),
    ui.Color(0xFF555555),
    ui.Color(0xFF777777),
  ];

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
    if (size.isEmpty) {
      return;
    }

    final int frame = _frame.value;
    final double phase = (frame & 0x7) * 0.0005;
    final double scale = math.min(size.width, size.height);
    final ui.Paint linePaint = ui.Paint()
      ..isAntiAlias = true
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round;

    canvas.save();
    canvas.scale(size.width, size.height);
    canvas.translate(phase, -phase);
    for (var index = 0; index < _polylines.length; index++) {
      linePaint
        ..color = _grays[(index + frame) & 0x3]
        ..strokeWidth = (0.75 + (index % 3) * 0.35) / scale;
      canvas.drawPoints(ui.PointMode.polygon, _polylines[index], linePaint);
    }
    canvas.restore();

    final ui.Paint circlePaint = ui.Paint()
      ..isAntiAlias = true
      ..style = ui.PaintingStyle.stroke;
    for (var index = 0; index < _circles.length; index++) {
      final _ProbeCircle circle = _circles[index];
      circlePaint
        ..color = _grays[(index + frame + 1) & 0x3]
        ..strokeWidth = 0.8 + (index % 4) * 0.3;
      canvas.drawCircle(
        ui.Offset(circle.x * size.width, circle.y * size.height),
        circle.radius * scale,
        circlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(ProbeLoadPainter oldDelegate) => false;
}

List<List<ui.Offset>> _buildPolylines() {
  final math.Random random = math.Random(0x1a4b9c);
  return List<List<ui.Offset>>.generate(_polylineCount, (int index) {
    final double originX = random.nextDouble();
    final double originY = random.nextDouble();
    final List<ui.Offset> points = <ui.Offset>[];
    for (var point = 0; point < 7; point++) {
      final double x =
          (originX + point * 0.025 + random.nextDouble() * 0.08) % 1;
      final double y =
          (originY + point * 0.018 + random.nextDouble() * 0.08) % 1;
      points.add(ui.Offset(x, y));
    }
    return List<ui.Offset>.unmodifiable(points);
  }, growable: false);
}

List<_ProbeCircle> _buildCircles() {
  final math.Random random = math.Random(0x50c1e5);
  return List<_ProbeCircle>.generate(
    _circleCount,
    (int index) => _ProbeCircle(
      x: 0.05 + random.nextDouble() * 0.9,
      y: 0.05 + random.nextDouble() * 0.9,
      radius: 0.01 + random.nextDouble() * 0.055,
    ),
    growable: false,
  );
}

final class _ProbeCircle {
  const _ProbeCircle({required this.x, required this.y, required this.radius});

  final double x;
  final double y;
  final double radius;
}
