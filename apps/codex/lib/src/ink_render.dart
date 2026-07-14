import 'dart:io';
import 'dart:ui' as ui;

import 'models.dart';

/// Bounding box of a stroke set, design px.
ui.Rect strokesBounds(List<InkStroke> strokes) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final stroke in strokes) {
    for (final p in stroke.points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
  }
  if (minX > maxX) {
    return ui.Rect.zero;
  }
  return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Shifts strokes so their bounding box (plus margin) starts at the origin.
List<InkStroke> normalizeStrokes(List<InkStroke> strokes, {double margin = 8}) {
  final bounds = strokesBounds(strokes);
  return [
    for (final stroke in strokes)
      InkStroke(
        width: stroke.width,
        points: [
          for (final p in stroke.points)
            InkPoint(
              p.x - bounds.left + margin,
              p.y - bounds.top + margin,
              p.pressure,
            ),
        ],
      ),
  ];
}

void paintStrokes(
  ui.Canvas canvas,
  List<InkStroke> strokes,
  ui.Color color, {
  double scale = 1,
}) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) {
      continue;
    }
    if (stroke.points.length == 1) {
      final p = stroke.points.first;
      canvas.drawCircle(
        ui.Offset(p.x * scale, p.y * scale),
        stroke.width * scale * 0.5 * (0.7 + 0.6 * p.pressure),
        ui.Paint()..color = color,
      );
      continue;
    }
    // Pressure-aware polyline: segments stroked at per-point width.
    for (var i = 0; i + 1 < stroke.points.length; i++) {
      final a = stroke.points[i];
      final b = stroke.points[i + 1];
      final width =
          stroke.width * (0.7 + 0.6 * ((a.pressure + b.pressure) / 2));
      canvas.drawLine(
        ui.Offset(a.x * scale, a.y * scale),
        ui.Offset(b.x * scale, b.y * scale),
        ui.Paint()
          ..color = color
          ..strokeWidth = width * scale
          ..strokeCap = ui.StrokeCap.round,
      );
    }
  }
}

/// Renders normalized strokes as a PNG (white page, near-black ink) for the
/// codex vision model, and writes it under [dir].
Future<String> renderStrokesPng(List<InkStroke> strokes, Directory dir) async {
  final normalized = normalizeStrokes(strokes);
  final bounds = strokesBounds(normalized);
  final width = (bounds.right + 16).ceil().clamp(64, 2048);
  final height = (bounds.bottom + 16).ceil().clamp(64, 4096);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  paintStrokes(canvas, normalized, const ui.Color(0xFF14161A));
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('could not encode handwriting PNG');
    }
    dir.createSync(recursive: true);
    final file = File(
      '${dir.path}/page-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  } finally {
    image.dispose();
  }
}
