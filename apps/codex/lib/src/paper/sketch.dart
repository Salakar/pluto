import 'dart:math' as math;
import 'dart:ui';

import 'layout.dart';

/// The hand-drawn stroke engine, ported verbatim from paper-codex
/// `crates/paper-render/src/canvas.rs`. Everything sketchy on the page —
/// glyphs, key outlines, dividers — flows through [Sketch.strokePath], which
/// samples each segment and displaces it with a deterministic sine-hash
/// wobble so lines sit on the page like pen marks, not vectors.
///
/// All inputs are *design pixels* (954×1696 space); [Sketch] scales the
/// canvas once so geometry code matches the Rust original character for
/// character.
List<Offset> wobbleSegment(Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final steps = math.max(dx.abs(), dy.abs()).ceil().clamp(1, 4096);
  final out = <Offset>[];
  for (var step = 0; step <= steps; step++) {
    final t = step / steps;
    final wobble = math.sin(step * 12.9898 + a.dx * 0.19 + a.dy * 0.31) * 0.35;
    out.add(Offset(a.dx + dx * t + wobble, a.dy + dy * t - wobble * 0.45));
  }
  return out;
}

/// 64-bit FNV-1a over (row, col) — the per-key outline seed from
/// `keyboard.rs::seed`.
int fnvSeed(int row, int col) {
  var h = 0xcbf29ce484222325;
  for (final b in [
    row & 0xff,
    (row >> 8) & 0xff,
    (row >> 16) & 0xff,
    (row >> 24) & 0xff,
    col & 0xff,
    (col >> 8) & 0xff,
    (col >> 16) & 0xff,
    (col >> 24) & 0xff,
  ]) {
    h ^= b;
    h *= 0x100000001b3; // wraps at 64 bits on the Dart VM
  }
  return h;
}

/// SplitMix64 (`keyboard.rs::splitmix`).
int splitmix64(int z) {
  z += 0x9e3779b97f4a7c15;
  z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
  z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
  return z ^ (z >>> 31);
}

/// Deterministic jitter in [-amp, amp] for vertex [idx] of a seeded outline.
int seededWobble(int seed, int idx, int amp) {
  final v = (splitmix64(seed ^ idx) & 0xFFFFFFFF).toSigned(32);
  final n = amp * 2 + 1;
  return ((v % n) + n) % n - amp;
}

/// A canvas wrapper that paints design-pixel sketch geometry.
final class Sketch {
  Sketch(this.canvas, this.metrics);

  final Canvas canvas;
  final PageScale metrics;

  Paint _strokePaint(Color color, double thickness) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    // The Rust `dot(radius: t)` stamp reads ~2t px wide; on the panel we run
    // ~30% heavier because anti-aliased stroke edges dither away and a
    // nominal-width line reads broken. Floor keeps hairline glyphs alive.
    ..strokeWidth = thickness * 2.6 + 0.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _scaled(void Function() draw) {
    canvas.save();
    canvas.scale(metrics.scale);
    draw();
    canvas.restore();
  }

  /// Polyline of wobbled soft segments — the workhorse for every glyph.
  void strokePath(List<Offset> points, double thickness, Color color) {
    if (points.length < 2) {
      return;
    }
    final path = Path();
    var first = true;
    for (var i = 0; i + 1 < points.length; i++) {
      for (final p in wobbleSegment(points[i], points[i + 1])) {
        if (first) {
          path.moveTo(p.dx, p.dy);
          first = false;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
    }
    _scaled(() => canvas.drawPath(path, _strokePaint(color, thickness)));
  }

  /// Two wobbled passes around an ellipse (`canvas.rs::scribble_ellipse`).
  void scribbleEllipse(
    double cx,
    double cy,
    double rx,
    double ry,
    Color color,
  ) {
    for (var pass = 0; pass < 2; pass++) {
      final points = <Offset>[];
      for (var idx = 0; idx <= 40; idx++) {
        final t = idx / 40.0 * math.pi * 2;
        final wobble = math.sin((idx * 17 + pass * 9).toDouble()) * 1.4;
        points.add(
          Offset(
            cx + math.cos(t) * (rx + wobble),
            cy + math.sin(t) * (ry - wobble * 0.35),
          ),
        );
      }
      strokePath(points, 1.5, color);
    }
  }

  /// A straight hairline (ruled lines) — deliberately not wobbled.
  void line(
    double x0,
    double y0,
    double x1,
    double y1,
    double thickness,
    Color color,
  ) {
    _scaled(
      () => canvas.drawLine(
        Offset(x0, y0),
        Offset(x1, y1),
        Paint()
          ..color = color
          ..strokeWidth = thickness
          ..strokeCap = StrokeCap.butt,
      ),
    );
  }

  /// A filled dot stamp.
  void dot(double cx, double cy, double radius, Color color) {
    _scaled(
      () => canvas.drawCircle(Offset(cx, cy), radius, Paint()..color = color),
    );
  }
}
