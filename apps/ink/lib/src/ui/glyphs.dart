import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../engine/brush_engine.dart';
import '../engine/brush_presets.dart';

const double _glyphGrid = 32;
const Size _brushProofSize = Size(152, 56);

/// Every drawn Ink mark required by the editor and gallery specifications.
enum InkGlyph {
  /// Six-dot bench drag handle.
  benchGrip,

  /// Paired chevrons used to fold the bench.
  collapseChevrons,

  /// Drawing nib.
  markDraw,

  /// Pixel or brush eraser.
  markErase,

  /// Dashed selection loop.
  markSelect,

  /// Selection transform handles.
  markTransform,

  /// Tipping fill bucket.
  markFill,

  /// Primitive shape tool.
  markShape,

  /// Serif text-tool letter.
  markText,

  /// Color-picker pipette.
  markPicker,

  /// Ruler and guide axis.
  markGuides,

  /// Crop corner brackets.
  markCrop,

  /// Framed reference image.
  markReference,

  /// Three offset layer plates.
  markLayers,

  /// Current-color ring.
  markColor,

  /// Three-rule menu.
  markMenu,

  /// Undo transport arrow.
  markUndo,

  /// Redo transport arrow.
  markRedo,

  /// Three falling drying rules.
  markDrying,

  /// Heavy-artwork weight.
  markHeavy,

  /// Trash action.
  markTrash,

  /// Duplicate action.
  markDuplicate,

  /// Merge active layer downward.
  markMergeDown,

  /// Visible-layer eye.
  markEyeOpen,

  /// Hidden-layer eye.
  markEyeClosed,

  /// Locked-layer state.
  markLock,

  /// Unlocked-layer state.
  markUnlock,

  /// Pinned reference layer.
  markPin,

  /// Horizontal flip action.
  markFlipH,

  /// Vertical flip action.
  markFlipV,

  /// Aspect-ratio constraint.
  markAspect,

  /// Geometry snap state.
  markSnap,

  /// Artwork or reference import.
  markImport,

  /// Export completed successfully.
  markCheck,
}

/// Stable code-name access for diagnostics and semantics.
extension InkGlyphCodeName on InkGlyph {
  /// The specification code name for this mark.
  String get codeName => name;
}

/// Draws one drafting-bench mark without relying on an icon font.
///
/// Geometry is authored on a 32-unit whole-number grid and scaled into the
/// shortest side of the supplied canvas. [currentColor] affects only
/// [InkGlyph.markColor]; every other mark stays monochrome.
final class InkGlyphPainter extends CustomPainter {
  /// Creates a painter for one Ink mark.
  const InkGlyphPainter({
    required this.glyph,
    this.color = const Color(0xFF111111),
    this.currentColor,
    this.strokeWidth = 2,
  });

  /// Mark to draw.
  final InkGlyph glyph;

  /// Monochrome stroke and detail color.
  final Color color;

  /// Optional selected color used by [InkGlyph.markColor].
  final Color? currentColor;

  /// Stroke width in logical pixels.
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double side = math.min(size.width, size.height);
    final double scale = side / _glyphGrid;
    final double requestedStroke = strokeWidth.isFinite
        ? math.max(1, strokeWidth)
        : 2;
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..strokeWidth = requestedStroke / scale
      ..isAntiAlias = false;
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(scale);
    switch (glyph) {
      case InkGlyph.benchGrip:
        _paintGrip(canvas, fill);
      case InkGlyph.collapseChevrons:
        _paintChevrons(canvas, stroke);
      case InkGlyph.markDraw:
        _paintDraw(canvas, stroke, fill);
      case InkGlyph.markErase:
        _paintErase(canvas, stroke);
      case InkGlyph.markSelect:
        _paintSelect(canvas, stroke);
      case InkGlyph.markTransform:
        _paintTransform(canvas, stroke, fill);
      case InkGlyph.markFill:
        _paintFill(canvas, stroke, fill);
      case InkGlyph.markShape:
        _paintShape(canvas, stroke);
      case InkGlyph.markText:
        _paintText(canvas, stroke);
      case InkGlyph.markPicker:
        _paintPicker(canvas, stroke, fill);
      case InkGlyph.markGuides:
        _paintGuides(canvas, stroke);
      case InkGlyph.markCrop:
        _paintCrop(canvas, stroke);
      case InkGlyph.markReference:
        _paintReference(canvas, stroke, fill);
      case InkGlyph.markLayers:
        _paintLayers(canvas, stroke);
      case InkGlyph.markColor:
        _paintColor(
          canvas,
          stroke,
          currentColor ?? color,
          requestedStroke / scale,
        );
      case InkGlyph.markMenu:
        _paintMenu(canvas, stroke);
      case InkGlyph.markUndo:
        _paintTransport(canvas, stroke, undo: true);
      case InkGlyph.markRedo:
        _paintTransport(canvas, stroke, undo: false);
      case InkGlyph.markDrying:
        _paintDrying(canvas, stroke);
      case InkGlyph.markHeavy:
        _paintHeavy(canvas, stroke);
      case InkGlyph.markTrash:
        _paintTrash(canvas, stroke);
      case InkGlyph.markDuplicate:
        _paintDuplicate(canvas, stroke);
      case InkGlyph.markMergeDown:
        _paintMergeDown(canvas, stroke);
      case InkGlyph.markEyeOpen:
        _paintEye(canvas, stroke, fill, closed: false);
      case InkGlyph.markEyeClosed:
        _paintEye(canvas, stroke, fill, closed: true);
      case InkGlyph.markLock:
        _paintLock(canvas, stroke, fill, open: false);
      case InkGlyph.markUnlock:
        _paintLock(canvas, stroke, fill, open: true);
      case InkGlyph.markPin:
        _paintPin(canvas, stroke);
      case InkGlyph.markFlipH:
        _paintFlip(canvas, stroke, horizontal: true);
      case InkGlyph.markFlipV:
        _paintFlip(canvas, stroke, horizontal: false);
      case InkGlyph.markAspect:
        _paintAspect(canvas, stroke);
      case InkGlyph.markSnap:
        _paintSnap(canvas, stroke, fill);
      case InkGlyph.markImport:
        _paintImport(canvas, stroke);
      case InkGlyph.markCheck:
        _paintCheck(canvas, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(InkGlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph ||
      color != oldDelegate.color ||
      currentColor != oldDelegate.currentColor ||
      strokeWidth != oldDelegate.strokeWidth;
}

/// The sixteen drawing-brush mini proofs required by the bench.
enum InkBrushMini {
  /// Fineliner proof.
  fineliner,

  /// Technical pen proof.
  technical,

  /// Ballpoint proof.
  ballpoint,

  /// Fountain pen proof.
  fountain,

  /// Calligraphy nib proof.
  calligraphy,

  /// Brush pen proof.
  brushpen,

  /// HB pencil proof.
  pencilhb,

  /// 6B pencil proof.
  pencil6b,

  /// Mechanical pencil proof.
  mechanical,

  /// Charcoal proof.
  charcoal,

  /// Marker proof.
  marker,

  /// Highlighter proof.
  highlighter,

  /// Spray proof.
  spray,

  /// Stipple proof.
  stipple,

  /// Hatcher proof.
  hatcher,

  /// Tone-shader proof.
  toneshader,
}

/// Stable brush identifier access for mini-proof consumers.
extension InkBrushMiniId on InkBrushMini {
  /// Brush identifier represented by this proof.
  String get brushId => name;
}

/// Paints a deterministic miniature through the production brush stamper.
///
/// Plans contain resolved [BrushSpec] impressions and are cached per brush.
/// Painting is synchronous and does not decode images, touch files, or spawn
/// isolates, so the painter is safe in widget and golden fake-async zones.
final class BrushMiniPainter extends CustomPainter {
  /// Creates a production-backed proof stroke for [brush].
  const BrushMiniPainter({
    required this.brush,
    this.color = const Color(0xFF111111),
  });

  /// Brush proof to paint.
  final InkBrushMini brush;

  /// Proof color.
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final _BrushProofPlan plan = _brushProofPlan(brush);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(
      size.width / _brushProofSize.width,
      size.height / _brushProofSize.height,
    );
    final List<ResolvedBrushStamp> capped = <ResolvedBrushStamp>[
      for (final ResolvedBrushStamp stamp in plan.stamps)
        if (stamp.maxOverlapSteps > 0) stamp,
    ];
    if (capped.isNotEmpty) {
      _paintCappedBrushStamps(canvas, plan.spec, capped, color);
    }
    for (final ResolvedBrushStamp stamp in plan.stamps) {
      if (stamp.maxOverlapSteps == 0) {
        _paintBrushStamp(canvas, stamp, color);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrushMiniPainter oldDelegate) =>
      brush != oldDelegate.brush || color != oldDelegate.color;
}

void _paintGrip(Canvas canvas, Paint fill) {
  for (final double y in <double>[9, 16, 23]) {
    canvas.drawCircle(Offset(12, y), 1.5, fill);
    canvas.drawCircle(Offset(20, y), 1.5, fill);
  }
}

void _paintChevrons(Canvas canvas, Paint paint) {
  _polyline(canvas, paint, const <Offset>[
    Offset(7, 8),
    Offset(16, 15),
    Offset(25, 8),
  ]);
  _polyline(canvas, paint, const <Offset>[
    Offset(7, 17),
    Offset(16, 24),
    Offset(25, 17),
  ]);
}

void _paintDraw(Canvas canvas, Paint stroke, Paint fill) {
  final Path nib = Path()
    ..moveTo(16, 3)
    ..lineTo(27, 14)
    ..lineTo(19, 27)
    ..lineTo(13, 27)
    ..lineTo(5, 14)
    ..close();
  canvas.drawPath(nib, stroke);
  canvas.drawLine(const Offset(16, 3), const Offset(16, 17), stroke);
  canvas.drawLine(const Offset(16, 17), const Offset(13, 27), stroke);
  canvas.drawCircle(const Offset(16, 16), 2, fill);
}

void _paintErase(Canvas canvas, Paint paint) {
  final Path body = Path()
    ..moveTo(5, 20)
    ..lineTo(16, 5)
    ..lineTo(28, 14)
    ..lineTo(18, 27)
    ..lineTo(10, 27)
    ..close();
  canvas.drawPath(body, paint);
  canvas.drawLine(const Offset(10, 14), const Offset(23, 23), paint);
  canvas.drawLine(const Offset(9, 28), const Offset(27, 28), paint);
}

void _paintSelect(Canvas canvas, Paint paint) {
  const Rect loop = Rect.fromLTRB(5, 5, 27, 24);
  for (var index = 0; index < 10; index += 1) {
    canvas.drawArc(loop, index * math.pi / 5, math.pi / 10, false, paint);
  }
  final Path tail = Path()
    ..moveTo(22, 21)
    ..quadraticBezierTo(28, 23, 26, 28)
    ..quadraticBezierTo(23, 30, 21, 27);
  canvas.drawPath(tail, paint);
}

void _paintTransform(Canvas canvas, Paint stroke, Paint fill) {
  const Rect box = Rect.fromLTRB(7, 8, 25, 26);
  canvas.drawRect(box, stroke);
  for (final double x in <double>[7, 16, 25]) {
    for (final double y in <double>[8, 17, 26]) {
      if (x == 16 && y == 17) {
        continue;
      }
      canvas.drawRect(
        Rect.fromCenter(center: Offset(x, y), width: 3, height: 3),
        fill,
      );
    }
  }
  canvas.drawLine(const Offset(16, 8), const Offset(16, 5), stroke);
  canvas.drawCircle(const Offset(16, 3.5), 1.5, stroke);
}

void _paintFill(Canvas canvas, Paint stroke, Paint fill) {
  final Path bucket = Path()
    ..moveTo(6, 12)
    ..lineTo(15, 5)
    ..lineTo(26, 16)
    ..lineTo(15, 27)
    ..lineTo(5, 17)
    ..close();
  canvas.drawPath(bucket, stroke);
  canvas.drawLine(const Offset(10, 9), const Offset(22, 21), stroke);
  final Path drop = Path()
    ..moveTo(27, 20)
    ..quadraticBezierTo(31, 25, 27, 29)
    ..quadraticBezierTo(23, 25, 27, 20)
    ..close();
  canvas.drawPath(drop, fill);
}

void _paintShape(Canvas canvas, Paint paint) {
  canvas.drawRect(const Rect.fromLTRB(4, 5, 18, 19), paint);
  canvas.drawCircle(const Offset(21, 20), 7, paint);
  canvas.drawLine(const Offset(8, 27), const Offset(27, 6), paint);
}

void _paintText(Canvas canvas, Paint paint) {
  canvas.drawLine(const Offset(5, 5), const Offset(27, 5), paint);
  canvas.drawLine(const Offset(8, 8), const Offset(8, 5), paint);
  canvas.drawLine(const Offset(24, 8), const Offset(24, 5), paint);
  canvas.drawLine(const Offset(16, 5), const Offset(16, 27), paint);
  canvas.drawLine(const Offset(10, 27), const Offset(22, 27), paint);
}

void _paintPicker(Canvas canvas, Paint stroke, Paint fill) {
  canvas.drawCircle(const Offset(23, 9), 5, stroke);
  final Path body = Path()
    ..moveTo(19, 12)
    ..lineTo(23, 16)
    ..lineTo(10, 29)
    ..lineTo(5, 29)
    ..lineTo(5, 24)
    ..close();
  canvas.drawPath(body, stroke);
  canvas.drawLine(const Offset(17, 14), const Offset(21, 18), stroke);
  canvas.drawCircle(const Offset(5, 29), 1.5, fill);
}

void _paintGuides(Canvas canvas, Paint paint) {
  _dashedLine(
    canvas,
    paint,
    from: const Offset(16, 3),
    to: const Offset(16, 19),
    dash: 3,
    gap: 2,
  );
  canvas.drawRect(const Rect.fromLTRB(4, 20, 28, 28), paint);
  for (final double x in <double>[8, 12, 16, 20, 24]) {
    canvas.drawLine(Offset(x, 20), Offset(x, x == 16 ? 26 : 24), paint);
  }
  canvas.drawLine(const Offset(12, 7), const Offset(16, 3), paint);
  canvas.drawLine(const Offset(20, 7), const Offset(16, 3), paint);
}

void _paintCrop(Canvas canvas, Paint paint) {
  canvas.drawLine(const Offset(10, 4), const Offset(10, 22), paint);
  canvas.drawLine(const Offset(4, 10), const Offset(22, 10), paint);
  canvas.drawLine(const Offset(22, 10), const Offset(22, 28), paint);
  canvas.drawLine(const Offset(10, 22), const Offset(28, 22), paint);
}

void _paintReference(Canvas canvas, Paint stroke, Paint fill) {
  canvas.drawRect(const Rect.fromLTRB(4, 5, 28, 27), stroke);
  canvas.drawCircle(const Offset(22, 11), 2, fill);
  final Path landscape = Path()
    ..moveTo(5, 24)
    ..lineTo(11, 16)
    ..lineTo(16, 21)
    ..lineTo(20, 17)
    ..lineTo(27, 24);
  canvas.drawPath(landscape, stroke);
}

void _paintLayers(Canvas canvas, Paint paint) {
  final Path top = Path()
    ..moveTo(16, 4)
    ..lineTo(28, 10)
    ..lineTo(16, 16)
    ..lineTo(4, 10)
    ..close();
  canvas.drawPath(top, paint);
  _polyline(canvas, paint, const <Offset>[
    Offset(4, 16),
    Offset(16, 22),
    Offset(28, 16),
  ]);
  _polyline(canvas, paint, const <Offset>[
    Offset(4, 22),
    Offset(16, 28),
    Offset(28, 22),
  ]);
}

void _paintColor(
  Canvas canvas,
  Paint outline,
  Color currentColor,
  double outlineWidth,
) {
  final Paint ring = Paint()
    ..color = currentColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = 7
    ..isAntiAlias = false;
  canvas.drawCircle(const Offset(16, 16), 9.5, ring);
  canvas.drawCircle(const Offset(16, 16), 13, outline);
  final Paint inner = Paint()
    ..color = outline.color
    ..style = PaintingStyle.stroke
    ..strokeWidth = outlineWidth
    ..isAntiAlias = false;
  canvas.drawCircle(const Offset(16, 16), 6, inner);
}

void _paintMenu(Canvas canvas, Paint paint) {
  canvas.drawLine(const Offset(5, 8), const Offset(27, 8), paint);
  canvas.drawLine(const Offset(5, 16), const Offset(23, 16), paint);
  canvas.drawLine(const Offset(5, 24), const Offset(27, 24), paint);
}

void _paintTransport(Canvas canvas, Paint paint, {required bool undo}) {
  canvas.save();
  if (!undo) {
    canvas.translate(_glyphGrid, 0);
    canvas.scale(-1, 1);
  }
  final Path arrow = Path()
    ..moveTo(7, 12)
    ..cubicTo(12, 5, 24, 6, 27, 14)
    ..cubicTo(30, 22, 23, 27, 16, 26);
  canvas.drawPath(arrow, paint);
  _polyline(canvas, paint, const <Offset>[
    Offset(13, 12),
    Offset(7, 12),
    Offset(8, 6),
  ]);
  canvas.restore();
}

void _paintDrying(Canvas canvas, Paint paint) {
  for (var index = 0; index < 3; index += 1) {
    final double x = 8 + index * 8;
    final double top = 4 + index * 3;
    final double bottom = 20 + index * 3;
    canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    _polyline(canvas, paint, <Offset>[
      Offset(x - 2, bottom - 2),
      Offset(x, bottom),
      Offset(x + 2, bottom - 2),
    ]);
  }
}

void _paintHeavy(Canvas canvas, Paint paint) {
  final Path handle = Path()
    ..moveTo(11, 11)
    ..lineTo(11, 8)
    ..quadraticBezierTo(11, 3, 16, 3)
    ..quadraticBezierTo(21, 3, 21, 8)
    ..lineTo(21, 11);
  canvas.drawPath(handle, paint);
  final Path body = Path()
    ..moveTo(9, 10)
    ..lineTo(23, 10)
    ..lineTo(28, 28)
    ..lineTo(4, 28)
    ..close();
  canvas.drawPath(body, paint);
  canvas.drawLine(const Offset(10, 17), const Offset(22, 17), paint);
}

void _paintTrash(Canvas canvas, Paint paint) {
  canvas.drawLine(const Offset(5, 8), const Offset(27, 8), paint);
  canvas.drawLine(const Offset(11, 4), const Offset(21, 4), paint);
  canvas.drawLine(const Offset(13, 4), const Offset(13, 8), paint);
  canvas.drawLine(const Offset(19, 4), const Offset(19, 8), paint);
  canvas.drawRect(const Rect.fromLTRB(8, 11, 24, 28), paint);
  canvas.drawLine(const Offset(13, 15), const Offset(13, 24), paint);
  canvas.drawLine(const Offset(19, 15), const Offset(19, 24), paint);
}

void _paintDuplicate(Canvas canvas, Paint paint) {
  canvas.drawRect(const Rect.fromLTRB(4, 4, 22, 22), paint);
  canvas.drawRect(const Rect.fromLTRB(10, 10, 28, 28), paint);
}

void _paintMergeDown(Canvas canvas, Paint paint) {
  canvas.drawRect(const Rect.fromLTRB(5, 4, 27, 10), paint);
  canvas.drawRect(const Rect.fromLTRB(5, 22, 27, 28), paint);
  canvas.drawLine(const Offset(16, 11), const Offset(16, 20), paint);
  _polyline(canvas, paint, const <Offset>[
    Offset(11, 16),
    Offset(16, 21),
    Offset(21, 16),
  ]);
}

void _paintEye(
  Canvas canvas,
  Paint stroke,
  Paint fill, {
  required bool closed,
}) {
  if (closed) {
    final Path lid = Path()
      ..moveTo(4, 18)
      ..quadraticBezierTo(16, 7, 28, 18);
    canvas.drawPath(lid, stroke);
    canvas.drawLine(const Offset(8, 20), const Offset(6, 24), stroke);
    canvas.drawLine(const Offset(16, 21), const Offset(16, 26), stroke);
    canvas.drawLine(const Offset(24, 20), const Offset(26, 24), stroke);
    return;
  }
  final Path eye = Path()
    ..moveTo(3, 16)
    ..quadraticBezierTo(16, 4, 29, 16)
    ..quadraticBezierTo(16, 28, 3, 16)
    ..close();
  canvas.drawPath(eye, stroke);
  canvas.drawCircle(const Offset(16, 16), 3, fill);
}

void _paintLock(Canvas canvas, Paint stroke, Paint fill, {required bool open}) {
  canvas.drawRect(const Rect.fromLTRB(7, 14, 25, 29), stroke);
  final Path shackle = Path();
  if (open) {
    shackle
      ..moveTo(12, 14)
      ..lineTo(12, 10)
      ..quadraticBezierTo(12, 4, 18, 4)
      ..quadraticBezierTo(24, 4, 24, 9);
  } else {
    shackle
      ..moveTo(11, 14)
      ..lineTo(11, 10)
      ..quadraticBezierTo(11, 4, 16, 4)
      ..quadraticBezierTo(21, 4, 21, 10)
      ..lineTo(21, 14);
  }
  canvas.drawPath(shackle, stroke);
  canvas.drawCircle(const Offset(16, 20), 2, fill);
  canvas.drawLine(const Offset(16, 21), const Offset(16, 25), stroke);
}

void _paintPin(Canvas canvas, Paint paint) {
  final Path head = Path()
    ..moveTo(10, 4)
    ..lineTo(27, 13)
    ..lineTo(23, 17)
    ..lineTo(18, 15)
    ..lineTo(14, 19)
    ..lineTo(6, 11)
    ..lineTo(10, 7)
    ..close();
  canvas.drawPath(head, paint);
  canvas.drawLine(const Offset(15, 16), const Offset(5, 27), paint);
}

void _paintFlip(Canvas canvas, Paint paint, {required bool horizontal}) {
  if (horizontal) {
    _dashedLine(
      canvas,
      paint,
      from: const Offset(16, 3),
      to: const Offset(16, 29),
      dash: 3,
      gap: 2,
    );
    final Path left = Path()
      ..moveTo(4, 16)
      ..lineTo(13, 7)
      ..lineTo(13, 25)
      ..close();
    final Path right = Path()
      ..moveTo(28, 16)
      ..lineTo(19, 7)
      ..lineTo(19, 25)
      ..close();
    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
    return;
  }
  _dashedLine(
    canvas,
    paint,
    from: const Offset(3, 16),
    to: const Offset(29, 16),
    dash: 3,
    gap: 2,
  );
  final Path top = Path()
    ..moveTo(16, 4)
    ..lineTo(7, 13)
    ..lineTo(25, 13)
    ..close();
  final Path bottom = Path()
    ..moveTo(16, 28)
    ..lineTo(7, 19)
    ..lineTo(25, 19)
    ..close();
  canvas.drawPath(top, paint);
  canvas.drawPath(bottom, paint);
}

void _paintAspect(Canvas canvas, Paint paint) {
  canvas.drawRect(const Rect.fromLTRB(4, 7, 28, 25), paint);
  canvas.drawLine(const Offset(8, 21), const Offset(24, 11), paint);
  _polyline(canvas, paint, const <Offset>[
    Offset(8, 15),
    Offset(8, 21),
    Offset(14, 21),
  ]);
  _polyline(canvas, paint, const <Offset>[
    Offset(18, 11),
    Offset(24, 11),
    Offset(24, 17),
  ]);
}

void _paintSnap(Canvas canvas, Paint stroke, Paint fill) {
  final Path magnet = Path()
    ..moveTo(6, 5)
    ..lineTo(6, 18)
    ..quadraticBezierTo(6, 28, 16, 28)
    ..quadraticBezierTo(26, 28, 26, 18)
    ..lineTo(26, 5);
  canvas.drawPath(magnet, stroke);
  canvas.drawRect(const Rect.fromLTRB(4, 4, 10, 10), fill);
  canvas.drawRect(const Rect.fromLTRB(22, 4, 28, 10), fill);
}

void _paintImport(Canvas canvas, Paint paint) {
  canvas.drawLine(const Offset(5, 22), const Offset(5, 28), paint);
  canvas.drawLine(const Offset(5, 28), const Offset(27, 28), paint);
  canvas.drawLine(const Offset(27, 28), const Offset(27, 22), paint);
  canvas.drawLine(const Offset(16, 3), const Offset(16, 21), paint);
  _polyline(canvas, paint, const <Offset>[
    Offset(9, 15),
    Offset(16, 22),
    Offset(23, 15),
  ]);
}

void _paintCheck(Canvas canvas, Paint paint) {
  _polyline(canvas, paint, const <Offset>[
    Offset(5, 17),
    Offset(13, 25),
    Offset(28, 7),
  ]);
}

void _polyline(Canvas canvas, Paint paint, List<Offset> points) {
  final Path path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final Offset point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  canvas.drawPath(path, paint);
}

void _dashedLine(
  Canvas canvas,
  Paint paint, {
  required Offset from,
  required Offset to,
  required double dash,
  required double gap,
}) {
  final Offset delta = to - from;
  final double distance = delta.distance;
  if (distance == 0) {
    return;
  }
  final Offset direction = delta / distance;
  var cursor = 0.0;
  while (cursor < distance) {
    final double end = math.min(distance, cursor + dash);
    canvas.drawLine(from + direction * cursor, from + direction * end, paint);
    cursor += dash + gap;
  }
}

final class _BrushProofPlan {
  const _BrushProofPlan({required this.spec, required this.stamps});

  final BrushSpec spec;
  final List<ResolvedBrushStamp> stamps;
}

final Map<InkBrushMini, _BrushProofPlan> _brushProofPlans =
    <InkBrushMini, _BrushProofPlan>{};

_BrushProofPlan _brushProofPlan(InkBrushMini brush) {
  return _brushProofPlans.putIfAbsent(brush, () {
    final BrushSpec spec = drawingBrushesById[brush.brushId]!;
    final RecordingBrushStampTarget target = RecordingBrushStampTarget();
    final BrushEngine engine = BrushEngine(
      spec: spec,
      target: target,
      seed: _proofSeed(spec.id),
      colorArgb: 0xff000000,
      size: spec.sizeDefault,
    );
    engine.stampAlong(_brushProofPoints());
    engine.finalize();
    return _BrushProofPlan(spec: spec, stamps: target.stamps);
  });
}

Iterable<BrushPoint> _brushProofPoints() sync* {
  const int count = 25;
  for (var index = 0; index < count; index += 1) {
    final double t = index / (count - 1);
    yield BrushPoint(
      point: Offset(
        8 + 136 * t,
        _brushProofSize.height / 2 + math.sin(t * math.pi * 2) * 9,
      ),
      pressure: 0.2 + t * 0.75,
      tilt: 0.1 + t * 0.7,
      timestamp: Duration(microseconds: index * 5000),
    );
  }
}

int _proofSeed(String brushId) {
  var hash = 0x811c9dc5;
  for (final int unit in brushId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

void _paintCappedBrushStamps(
  Canvas canvas,
  BrushSpec spec,
  List<ResolvedBrushStamp> stamps,
  Color color,
) {
  final int width = _brushProofSize.width.ceil();
  final int height = _brushProofSize.height.ceil();
  final StrokeCoverageMask coverageMask = StrokeCoverageMask.forBrush(
    spec,
    width: width,
    height: height,
  );
  final List<double> alpha = List<double>.filled(width * height, 0);
  for (final ResolvedBrushStamp stamp in stamps) {
    final Rect bounds = stamp.bounds;
    final int top = math.max(0, bounds.top.floor());
    final int bottom = math.min(height, bounds.bottom.ceil());
    final int left = math.max(0, bounds.left.floor());
    final int right = math.min(width, bounds.right.ceil());
    for (var y = top; y < bottom; y += 1) {
      for (var x = left; x < right; x += 1) {
        if (!_brushStampContains(stamp, Offset(x + 0.5, y + 0.5))) {
          continue;
        }
        final double accepted = coverageMask.takeCoverage(x, y, 1);
        if (accepted == 0) {
          continue;
        }
        final int index = y * width + x;
        final double source = (stamp.flow * accepted).clamp(0.0, 1.0);
        alpha[index] = source + alpha[index] * (1 - source);
      }
    }
  }
  final Paint pixel = Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = false;
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final int value = (color.a * 255 * alpha[y * width + x]).round().clamp(
        0,
        255,
      );
      if (value == 0) {
        continue;
      }
      pixel.color = color.withValues(alpha: value / 255);
      canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), pixel);
    }
  }
}

void _paintBrushStamp(Canvas canvas, ResolvedBrushStamp stamp, Color color) {
  final ResolvedBrushGrain? grain = stamp.grain;
  if (grain != null) {
    _paintGrainedBrushStamp(canvas, stamp, grain, color);
    return;
  }
  final double alpha = (color.a * stamp.flow).clamp(0.0, 1.0);
  if (alpha == 0) {
    return;
  }
  canvas.save();
  canvas.translate(stamp.center.dx, stamp.center.dy);
  canvas.rotate(stamp.angleRadians);
  final Rect bounds = Rect.fromCenter(
    center: Offset.zero,
    width: stamp.diameterX,
    height: stamp.diameterY,
  );
  final Paint paint = Paint()
    ..color = color.withValues(alpha: alpha)
    ..style = PaintingStyle.fill
    ..isAntiAlias = stamp.nibKind != NibKind.chisel;
  if (stamp.nibKind == NibKind.chisel) {
    canvas.drawRect(bounds, paint);
  } else {
    canvas.drawOval(bounds, paint);
  }
  canvas.restore();
}

void _paintGrainedBrushStamp(
  Canvas canvas,
  ResolvedBrushStamp stamp,
  ResolvedBrushGrain grain,
  Color color,
) {
  final Paint pixel = Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = false;
  final Rect bounds = stamp.bounds;
  for (var y = bounds.top.floor(); y < bounds.bottom.ceil(); y += 1) {
    for (var x = bounds.left.floor(); x < bounds.right.ceil(); x += 1) {
      final Offset point = Offset(x + 0.5, y + 0.5);
      if (!_brushStampContains(stamp, point)) {
        continue;
      }
      final double coverage =
          stamp.flow * grain.coverageAt(point, stampCenter: stamp.center);
      final double alpha = (color.a * coverage).clamp(0.0, 1.0);
      if (alpha == 0) {
        continue;
      }
      pixel.color = color.withValues(alpha: alpha);
      canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), pixel);
    }
  }
}

bool _brushStampContains(ResolvedBrushStamp stamp, Offset point) {
  final Offset delta = point - stamp.center;
  final double cosine = math.cos(stamp.angleRadians);
  final double sine = math.sin(stamp.angleRadians);
  final double localX = delta.dx * cosine + delta.dy * sine;
  final double localY = -delta.dx * sine + delta.dy * cosine;
  final double radiusX = stamp.diameterX / 2;
  final double radiusY = stamp.diameterY / 2;
  if (stamp.nibKind == NibKind.chisel) {
    return localX.abs() <= radiusX && localY.abs() <= radiusY;
  }
  return localX * localX / (radiusX * radiusX) +
          localY * localY / (radiusY * radiusY) <=
      1;
}
