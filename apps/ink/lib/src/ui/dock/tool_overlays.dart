import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Synchronous, non-animated outline for the active selection mask.
///
/// The caller retains ownership of [outline] and must not mutate it after the
/// widget is built. Rectangular, lasso, and wand contours all share this one
/// painter so the marquee remains visually stable across tool switches.
final class SelectionMaskOverlay extends StatelessWidget {
  /// Creates an overlay for an arbitrary selection contour.
  const SelectionMaskOverlay({
    required this.outline,
    this.color = const Color(0xff000000),
    this.strokeWidth = 1,
    this.dashLength = 8,
    this.gapLength = 6,
    super.key,
  });

  /// Creates an overlay for an axis-aligned rectangular selection.
  factory SelectionMaskOverlay.rect({
    required Rect bounds,
    Color color = const Color(0xff000000),
    double strokeWidth = 1,
    double dashLength = 8,
    double gapLength = 6,
    Key? key,
  }) {
    return SelectionMaskOverlay(
      key: key,
      outline: Path()..addRect(bounds),
      color: color,
      strokeWidth: strokeWidth,
      dashLength: dashLength,
      gapLength: gapLength,
    );
  }

  /// Closed path describing the active mask boundary.
  final Path outline;

  /// Marquee ink color.
  final Color color;

  /// Logical stroke width of the static outline.
  final double strokeWidth;

  /// Logical length of every painted dash.
  final double dashLength;

  /// Logical empty distance between dashes.
  final double gapLength;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: SelectionOutlinePainter(
            outline: outline,
            color: color,
            strokeWidth: strokeWidth,
            dashLength: dashLength,
            gapLength: gapLength,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [SelectionMaskOverlay].
final class SelectionOutlinePainter extends CustomPainter {
  /// Creates a static dashed selection painter.
  const SelectionOutlinePainter({
    required this.outline,
    this.color = const Color(0xff000000),
    this.strokeWidth = 1,
    this.dashLength = 8,
    this.gapLength = 6,
  });

  /// Closed path describing the mask boundary.
  final Path outline;

  /// Marquee ink color.
  final Color color;

  /// Logical stroke width.
  final double strokeWidth;

  /// Logical dash length.
  final double dashLength;

  /// Logical gap length.
  final double gapLength;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    _drawDashedPath(
      canvas,
      outline,
      paint,
      dashLength: dashLength,
      gapLength: gapLength,
    );
  }

  @override
  bool shouldRepaint(SelectionOutlinePainter oldDelegate) {
    return !identical(oldDelegate.outline, outline) ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.gapLength != gapLength;
  }
}

/// Synchronous transform frame with eight handles and one rotation lug.
final class TransformOverlay extends StatelessWidget {
  /// Creates a transform overlay around [bounds].
  const TransformOverlay({
    required this.bounds,
    this.color = const Color(0xff000000),
    this.handleVisualSize = 12,
    this.rotationLugDistance = 42,
    this.strokeWidth = 2,
    super.key,
  });

  /// Axis-aligned live transform bounds in overlay coordinates.
  final Rect bounds;

  /// Frame and handle color.
  final Color color;

  /// Painted handle size. The host supplies the larger pen hit regions.
  final double handleVisualSize;

  /// Distance from the top edge to the rotation lug center.
  final double rotationLugDistance;

  /// Frame rule width.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: TransformHandlesPainter(
            bounds: bounds,
            color: color,
            handleVisualSize: handleVisualSize,
            rotationLugDistance: rotationLugDistance,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [TransformOverlay].
final class TransformHandlesPainter extends CustomPainter {
  /// Creates an eight-handle transform frame.
  const TransformHandlesPainter({
    required this.bounds,
    this.color = const Color(0xff000000),
    this.handleVisualSize = 12,
    this.rotationLugDistance = 42,
    this.strokeWidth = 2,
  });

  /// Axis-aligned live transform bounds.
  final Rect bounds;

  /// Frame and handle color.
  final Color color;

  /// Painted square handle size.
  final double handleVisualSize;

  /// Top-edge distance of the rotation control.
  final double rotationLugDistance;

  /// Frame rule width.
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    final Paint paper = Paint()
      ..color = const Color(0xffffffff)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    canvas.drawRect(bounds, stroke);

    final List<Offset> handles = <Offset>[
      bounds.topLeft,
      bounds.topCenter,
      bounds.topRight,
      bounds.centerLeft,
      bounds.centerRight,
      bounds.bottomLeft,
      bounds.bottomCenter,
      bounds.bottomRight,
    ];
    for (final Offset center in handles) {
      final Rect handle = Rect.fromCenter(
        center: center,
        width: handleVisualSize,
        height: handleVisualSize,
      );
      canvas.drawRect(handle, paper);
      canvas.drawRect(handle, stroke);
    }

    final Offset lugCenter = Offset(
      bounds.center.dx,
      bounds.top - rotationLugDistance,
    );
    canvas.drawLine(bounds.topCenter, lugCenter, stroke);
    canvas.drawCircle(lugCenter, handleVisualSize * 0.72, paper);
    canvas.drawCircle(lugCenter, handleVisualSize * 0.72, stroke);
    for (var tick = 0; tick < 4; tick += 1) {
      final double angle = tick * math.pi / 2;
      final Offset inner =
          lugCenter +
          Offset(math.cos(angle), math.sin(angle)) * handleVisualSize * 0.9;
      final Offset outer =
          lugCenter +
          Offset(math.cos(angle), math.sin(angle)) * handleVisualSize * 1.2;
      canvas.drawLine(inner, outer, stroke);
    }
  }

  @override
  bool shouldRepaint(TransformHandlesPainter oldDelegate) {
    return oldDelegate.bounds != bounds ||
        oldDelegate.color != color ||
        oldDelegate.handleVisualSize != handleVisualSize ||
        oldDelegate.rotationLugDistance != rotationLugDistance ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Live editable text block with four pen-resize handle visuals.
final class TextDraftOverlay extends StatelessWidget {
  /// Creates an overlay for one document text draft in viewport coordinates.
  const TextDraftOverlay({
    required this.bounds,
    required this.text,
    required this.color,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.resizeMode,
    super.key,
  });

  /// Axis-aligned draft bounds in viewport coordinates.
  final Rect bounds;

  /// Current keyboard text.
  final String text;

  /// Current drawing color.
  final Color color;

  /// Bundled font-family name.
  final String fontFamily;

  /// Scaled viewport font size.
  final double fontSize;

  /// Current e-ink-safe text weight.
  final FontWeight fontWeight;

  /// Whether the dock has armed corner-resize interaction.
  final bool resizeMode;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: TextDraftPainter(
            bounds: bounds,
            text: text,
            color: color,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            resizeMode: resizeMode,
          ),
        ),
      ),
    );
  }
}

/// Direct painter for [TextDraftOverlay].
final class TextDraftPainter extends CustomPainter {
  /// Creates a static editable-block presentation.
  const TextDraftPainter({
    required this.bounds,
    required this.text,
    required this.color,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.resizeMode,
  });

  /// Axis-aligned block bounds in viewport coordinates.
  final Rect bounds;

  /// Current draft text.
  final String text;

  /// Text color.
  final Color color;

  /// Font family.
  final String fontFamily;

  /// Viewport font size.
  final double fontSize;

  /// Font weight.
  final FontWeight fontWeight;

  /// Whether resize handles are currently armed.
  final bool resizeMode;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint frame = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = resizeMode ? 2 : 1
      ..isAntiAlias = false;
    final Paint paper = Paint()
      ..color = const Color(0xffffffff)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    canvas.drawRect(bounds, frame);
    for (final Offset center in <Offset>[
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      final Rect handle = Rect.fromCenter(
        center: center,
        width: 12,
        height: 12,
      );
      canvas
        ..drawRect(handle, paper)
        ..drawRect(handle, frame);
    }
    if (text.isEmpty || bounds.isEmpty) {
      return;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontFamily: fontFamily,
          fontFamilyFallback: const <String>['Arial', 'Menlo', 'sans-serif'],
          fontSize: math.max(1, fontSize),
          fontWeight: fontWeight,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bounds.width);
    canvas
      ..save()
      ..clipRect(bounds);
    painter.paint(canvas, bounds.topLeft);
    canvas.restore();
  }

  @override
  bool shouldRepaint(TextDraftPainter oldDelegate) =>
      oldDelegate.bounds != bounds ||
      oldDelegate.text != text ||
      oldDelegate.color != color ||
      oldDelegate.fontFamily != fontFamily ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.fontWeight != fontWeight ||
      oldDelegate.resizeMode != resizeMode;
}

/// Primitive preview geometry rendered while the stylus is dragging.
enum LiveShapeKind {
  /// Straight line segment.
  line,

  /// Line segment with an arrow head.
  arrow,

  /// Axis-aligned rectangle.
  rectangle,

  /// Axis-aligned ellipse.
  ellipse,

  /// Regular N-sided polygon.
  polygon,
}

/// Direct-paint live shape overlay.
final class LiveShapeOverlay extends StatelessWidget {
  /// Creates a preview between [start] and [end].
  const LiveShapeOverlay({
    required this.kind,
    required this.start,
    required this.end,
    this.polygonSides = 5,
    this.color = const Color(0xff000000),
    this.strokeWidth = 3,
    this.perfected = false,
    super.key,
  }) : assert(polygonSides >= 3);

  /// Shape family being previewed.
  final LiveShapeKind kind;

  /// Stylus-down point.
  final Offset start;

  /// Current stylus or held endpoint.
  final Offset end;

  /// Side count used for [LiveShapeKind.polygon].
  final int polygonSides;

  /// Preview ink color.
  final Color color;

  /// Preview rule width.
  final double strokeWidth;

  /// Whether hold-to-perfect has engaged.
  final bool perfected;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: LiveShapePainter(
            kind: kind,
            start: start,
            end: end,
            polygonSides: polygonSides,
            color: color,
            strokeWidth: strokeWidth,
            perfected: perfected,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [LiveShapeOverlay].
final class LiveShapePainter extends CustomPainter {
  /// Creates a synchronous live geometry painter.
  const LiveShapePainter({
    required this.kind,
    required this.start,
    required this.end,
    this.polygonSides = 5,
    this.color = const Color(0xff000000),
    this.strokeWidth = 3,
    this.perfected = false,
  }) : assert(polygonSides >= 3);

  /// Shape family.
  final LiveShapeKind kind;

  /// Stylus-down point.
  final Offset start;

  /// Current endpoint.
  final Offset end;

  /// Polygon side count.
  final int polygonSides;

  /// Preview ink color.
  final Color color;

  /// Preview rule width.
  final double strokeWidth;

  /// Whether hold-to-perfect has engaged.
  final bool perfected;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = perfected ? strokeWidth + 1 : strokeWidth
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = true;
    switch (kind) {
      case LiveShapeKind.line:
        canvas.drawLine(start, end, stroke);
      case LiveShapeKind.arrow:
        _paintArrow(canvas, stroke);
      case LiveShapeKind.rectangle:
        canvas.drawRect(Rect.fromPoints(start, end), stroke);
      case LiveShapeKind.ellipse:
        canvas.drawOval(Rect.fromPoints(start, end), stroke);
      case LiveShapeKind.polygon:
        canvas.drawPath(_polygonPath(), stroke);
    }
    _paintEndpoint(canvas, start, stroke);
    _paintEndpoint(canvas, end, stroke);
  }

  void _paintArrow(Canvas canvas, Paint stroke) {
    canvas.drawLine(start, end, stroke);
    final double angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final double length = math.min(28, (end - start).distance * 0.28);
    final Offset wingA =
        end -
        Offset(math.cos(angle - math.pi / 6), math.sin(angle - math.pi / 6)) *
            length;
    final Offset wingB =
        end -
        Offset(math.cos(angle + math.pi / 6), math.sin(angle + math.pi / 6)) *
            length;
    canvas.drawLine(end, wingA, stroke);
    canvas.drawLine(end, wingB, stroke);
  }

  Path _polygonPath() {
    final Rect bounds = Rect.fromPoints(start, end);
    final Offset center = bounds.center;
    final double radiusX = bounds.width / 2;
    final double radiusY = bounds.height / 2;
    final Path path = Path();
    for (var side = 0; side < polygonSides; side += 1) {
      final double angle = -math.pi / 2 + side * math.pi * 2 / polygonSides;
      final Offset point =
          center + Offset(math.cos(angle) * radiusX, math.sin(angle) * radiusY);
      if (side == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  void _paintEndpoint(Canvas canvas, Offset point, Paint stroke) {
    final Paint paper = Paint()
      ..color = const Color(0xffffffff)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    canvas.drawCircle(point, 5, paper);
    canvas.drawCircle(point, 5, stroke);
  }

  @override
  bool shouldRepaint(LiveShapePainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.polygonSides != polygonSides ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.perfected != perfected;
  }
}

/// Stroke symmetry overlay configured by the guides tool.
enum GuideSymmetryMode {
  /// No symmetry axes.
  off,

  /// One vertical mirror axis.
  vertical,

  /// One horizontal mirror axis.
  horizontal,

  /// Both axes, producing four stroke copies.
  quad,
}

/// Persistent straightedge, grid, and symmetry overlay.
final class GuidesSymmetryOverlay extends StatelessWidget {
  /// Creates a synchronous guides overlay.
  const GuidesSymmetryOverlay({
    this.gridSpacing,
    this.dotGrid = false,
    this.gridOrigin = Offset.zero,
    this.straightedgeStart,
    this.straightedgeEnd,
    this.symmetry = GuideSymmetryMode.off,
    this.verticalAxis,
    this.horizontalAxis,
    super.key,
  }) : assert(gridSpacing == null || gridSpacing > 0);

  /// Logical distance between grid marks, or null when the grid is off.
  final double? gridSpacing;

  /// Whether grid intersections are dots instead of lines.
  final bool dotGrid;

  /// Grid phase origin.
  final Offset gridOrigin;

  /// Optional persistent straightedge start point.
  final Offset? straightedgeStart;

  /// Optional persistent straightedge end point.
  final Offset? straightedgeEnd;

  /// Active stroke-only symmetry family.
  final GuideSymmetryMode symmetry;

  /// Logical x coordinate of the vertical mirror axis.
  final double? verticalAxis;

  /// Logical y coordinate of the horizontal mirror axis.
  final double? horizontalAxis;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: GuidesSymmetryPainter(
            gridSpacing: gridSpacing,
            dotGrid: dotGrid,
            gridOrigin: gridOrigin,
            straightedgeStart: straightedgeStart,
            straightedgeEnd: straightedgeEnd,
            symmetry: symmetry,
            verticalAxis: verticalAxis,
            horizontalAxis: horizontalAxis,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [GuidesSymmetryOverlay].
final class GuidesSymmetryPainter extends CustomPainter {
  /// Creates a persistent guide painter.
  const GuidesSymmetryPainter({
    this.gridSpacing,
    this.dotGrid = false,
    this.gridOrigin = Offset.zero,
    this.straightedgeStart,
    this.straightedgeEnd,
    this.symmetry = GuideSymmetryMode.off,
    this.verticalAxis,
    this.horizontalAxis,
  }) : assert(gridSpacing == null || gridSpacing > 0);

  /// Logical grid spacing, if enabled.
  final double? gridSpacing;

  /// Whether to draw intersection dots instead of grid lines.
  final bool dotGrid;

  /// Grid phase origin.
  final Offset gridOrigin;

  /// Optional straightedge start point.
  final Offset? straightedgeStart;

  /// Optional straightedge end point.
  final Offset? straightedgeEnd;

  /// Active symmetry axes.
  final GuideSymmetryMode symmetry;

  /// Vertical axis coordinate.
  final double? verticalAxis;

  /// Horizontal axis coordinate.
  final double? horizontalAxis;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint grid = Paint()
      ..color = const Color(0xff999999)
      ..strokeWidth = 1
      ..isAntiAlias = false;
    final double? spacing = gridSpacing;
    if (spacing != null) {
      final double firstX = _firstGridCoordinate(gridOrigin.dx, spacing);
      final double firstY = _firstGridCoordinate(gridOrigin.dy, spacing);
      if (dotGrid) {
        for (double y = firstY; y <= size.height; y += spacing) {
          for (double x = firstX; x <= size.width; x += spacing) {
            canvas.drawCircle(Offset(x, y), 1.25, grid);
          }
        }
      } else {
        for (double x = firstX; x <= size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
        }
        for (double y = firstY; y <= size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
        }
      }
    }

    final Offset? rulerStart = straightedgeStart;
    final Offset? rulerEnd = straightedgeEnd;
    if (rulerStart != null && rulerEnd != null) {
      final Paint ruler = Paint()
        ..color = const Color(0xff333333)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.square
        ..isAntiAlias = false;
      canvas.drawLine(rulerStart, rulerEnd, ruler);
      final Offset delta = rulerEnd - rulerStart;
      final double length = delta.distance;
      if (length > 0) {
        final Offset normal = Offset(-delta.dy / length, delta.dx / length);
        for (double along = 0; along <= length; along += 16) {
          final Offset base = rulerStart + delta * (along / length);
          final double tick = along % 64 == 0 ? 10 : 6;
          canvas.drawLine(base, base + normal * tick, ruler);
        }
      }
    }

    final Paint axis = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    if (symmetry == GuideSymmetryMode.vertical ||
        symmetry == GuideSymmetryMode.quad) {
      final double x = verticalAxis ?? size.width / 2;
      _drawDashedPath(
        canvas,
        Path()
          ..moveTo(x, 0)
          ..lineTo(x, size.height),
        axis,
        dashLength: 12,
        gapLength: 8,
      );
      _paintAxisBadge(canvas, Offset(x, 26), 'V');
    }
    if (symmetry == GuideSymmetryMode.horizontal ||
        symmetry == GuideSymmetryMode.quad) {
      final double y = horizontalAxis ?? size.height / 2;
      _drawDashedPath(
        canvas,
        Path()
          ..moveTo(0, y)
          ..lineTo(size.width, y),
        axis,
        dashLength: 12,
        gapLength: 8,
      );
      _paintAxisBadge(canvas, Offset(26, y), 'H');
    }
  }

  double _firstGridCoordinate(double origin, double spacing) {
    double coordinate = origin % spacing;
    if (coordinate < 0) {
      coordinate += spacing;
    }
    return coordinate;
  }

  void _paintAxisBadge(Canvas canvas, Offset center, String label) {
    const double side = 24;
    final Rect bounds = Rect.fromCenter(
      center: center,
      width: side,
      height: side,
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..color = const Color(0xffffffff)
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..color = const Color(0xff000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = false,
    );
    final TextPainter text = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xff000000),
          fontFamily: 'JetBrains Mono',
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(GuidesSymmetryPainter oldDelegate) {
    return oldDelegate.gridSpacing != gridSpacing ||
        oldDelegate.dotGrid != dotGrid ||
        oldDelegate.gridOrigin != gridOrigin ||
        oldDelegate.straightedgeStart != straightedgeStart ||
        oldDelegate.straightedgeEnd != straightedgeEnd ||
        oldDelegate.symmetry != symmetry ||
        oldDelegate.verticalAxis != verticalAxis ||
        oldDelegate.horizontalAxis != horizontalAxis;
  }
}

/// Radius-averaged eyedropper sample with a split color/lattice loupe.
final class EyedropperLoupeOverlay extends StatelessWidget {
  /// Creates a loupe attached to [sampleCenter].
  const EyedropperLoupeOverlay({
    required this.sampleCenter,
    required this.loupeCenter,
    required this.sampledColor,
    required this.todayGray,
    this.sampleRadius = 5,
    this.loupeRadius = 38,
    super.key,
  });

  /// Center of the radius-averaged source sample.
  final Offset sampleCenter;

  /// Center of the magnified split swatch.
  final Offset loupeCenter;

  /// Mean sampled color after palette snapping.
  final Color sampledColor;

  /// Current /30 presentation gray for [sampledColor].
  final Color todayGray;

  /// Logical source-sample radius.
  final double sampleRadius;

  /// Logical loupe radius.
  final double loupeRadius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: EyedropperLoupePainter(
            sampleCenter: sampleCenter,
            loupeCenter: loupeCenter,
            sampledColor: sampledColor,
            todayGray: todayGray,
            sampleRadius: sampleRadius,
            loupeRadius: loupeRadius,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [EyedropperLoupeOverlay].
final class EyedropperLoupePainter extends CustomPainter {
  /// Creates a split color/lattice loupe painter.
  const EyedropperLoupePainter({
    required this.sampleCenter,
    required this.loupeCenter,
    required this.sampledColor,
    required this.todayGray,
    this.sampleRadius = 5,
    this.loupeRadius = 38,
  });

  /// Center of the averaged source sample.
  final Offset sampleCenter;

  /// Center of the loupe.
  final Offset loupeCenter;

  /// Snapped sampled color.
  final Color sampledColor;

  /// Lattice-gray presentation value.
  final Color todayGray;

  /// Source averaging radius.
  final double sampleRadius;

  /// Loupe radius.
  final double loupeRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint ink = Paint()
      ..color = const Color(0xff000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..isAntiAlias = false;
    canvas.drawLine(sampleCenter, loupeCenter, ink);
    canvas.drawCircle(sampleCenter, sampleRadius, ink);
    canvas.drawLine(
      sampleCenter - Offset(sampleRadius + 5, 0),
      sampleCenter + Offset(sampleRadius + 5, 0),
      ink,
    );
    canvas.drawLine(
      sampleCenter - Offset(0, sampleRadius + 5),
      sampleCenter + Offset(0, sampleRadius + 5),
      ink,
    );

    canvas.drawCircle(
      loupeCenter,
      loupeRadius,
      Paint()
        ..color = sampledColor
        ..isAntiAlias = false,
    );
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        loupeCenter.dx,
        loupeCenter.dy - loupeRadius,
        loupeCenter.dx + loupeRadius,
        loupeCenter.dy + loupeRadius,
      ),
    );
    canvas.drawCircle(
      loupeCenter,
      loupeRadius,
      Paint()
        ..color = todayGray
        ..isAntiAlias = false,
    );
    canvas.restore();
    canvas.drawCircle(loupeCenter, loupeRadius, ink..strokeWidth = 4);
    canvas.drawLine(
      Offset(loupeCenter.dx, loupeCenter.dy - loupeRadius),
      Offset(loupeCenter.dx, loupeCenter.dy + loupeRadius),
      ink..strokeWidth = 2,
    );

    final TextPainter colorLabel = _loupeLabel(
      'COLOR',
      const Color(0xffffffff),
    );
    colorLabel.paint(
      canvas,
      Offset(
        loupeCenter.dx - loupeRadius + 6,
        loupeCenter.dy - colorLabel.height / 2,
      ),
    );
    final TextPainter grayLabel = _loupeLabel('/30', const Color(0xffffffff));
    grayLabel.paint(
      canvas,
      Offset(loupeCenter.dx + 5, loupeCenter.dy - grayLabel.height / 2),
    );
  }

  TextPainter _loupeLabel(String label, Color color) {
    return TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontFamily: 'JetBrains Mono',
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(EyedropperLoupePainter oldDelegate) {
    return oldDelegate.sampleCenter != sampleCenter ||
        oldDelegate.loupeCenter != loupeCenter ||
        oldDelegate.sampledColor != sampledColor ||
        oldDelegate.todayGray != todayGray ||
        oldDelegate.sampleRadius != sampleRadius ||
        oldDelegate.loupeRadius != loupeRadius;
  }
}

/// Active crop rectangle with preserved-content veil and adjustment handles.
final class CropOverlay extends StatelessWidget {
  /// Creates a crop overlay.
  const CropOverlay({
    required this.cropRect,
    this.artworkBounds,
    this.label,
    this.color = const Color(0xff000000),
    this.outsideColor = const Color(0xffdddddd),
    this.handleVisualSize = 12,
    super.key,
  });

  /// Proposed artwork bounds in overlay coordinates.
  final Rect cropRect;

  /// Existing artwork bounds; defaults to the full painter extent.
  final Rect? artworkBounds;

  /// Optional dimension label shown inside the top-left corner.
  final String? label;

  /// Crop rule color.
  final Color color;

  /// Opaque veil painted over preserved out-of-bounds content.
  final Color outsideColor;

  /// Painted handle size. The host supplies the larger pen hit regions.
  final double handleVisualSize;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: CropActivePainter(
            cropRect: cropRect,
            artworkBounds: artworkBounds,
            label: label,
            color: color,
            outsideColor: outsideColor,
            handleVisualSize: handleVisualSize,
          ),
        ),
      ),
    );
  }
}

/// Direct painter used by [CropOverlay].
final class CropActivePainter extends CustomPainter {
  /// Creates an active crop painter.
  const CropActivePainter({
    required this.cropRect,
    this.artworkBounds,
    this.label,
    this.color = const Color(0xff000000),
    this.outsideColor = const Color(0xffdddddd),
    this.handleVisualSize = 12,
  });

  /// Proposed artwork bounds.
  final Rect cropRect;

  /// Existing artwork bounds, or the full overlay when null.
  final Rect? artworkBounds;

  /// Optional proposed dimensions.
  final String? label;

  /// Rule color.
  final Color color;

  /// Opaque outside veil.
  final Color outsideColor;

  /// Painted square handle size.
  final double handleVisualSize;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect outer = artworkBounds ?? (Offset.zero & size);
    final Path outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRect(cropRect);
    canvas.drawPath(
      outside,
      Paint()
        ..color = outsideColor
        ..style = PaintingStyle.fill
        ..isAntiAlias = false,
    );

    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    canvas.drawRect(cropRect, stroke);
    final List<Offset> handles = <Offset>[
      cropRect.topLeft,
      cropRect.topCenter,
      cropRect.topRight,
      cropRect.centerLeft,
      cropRect.centerRight,
      cropRect.bottomLeft,
      cropRect.bottomCenter,
      cropRect.bottomRight,
    ];
    for (final Offset center in handles) {
      final Rect handle = Rect.fromCenter(
        center: center,
        width: handleVisualSize,
        height: handleVisualSize,
      );
      canvas.drawRect(
        handle,
        Paint()
          ..color = const Color(0xffffffff)
          ..isAntiAlias = false,
      );
      canvas.drawRect(handle, stroke..strokeWidth = 2);
    }

    final String? dimensionLabel = label;
    if (dimensionLabel != null && dimensionLabel.isNotEmpty) {
      final TextPainter text = TextPainter(
        text: TextSpan(
          text: dimensionLabel,
          style: TextStyle(
            color: color,
            fontFamily: 'JetBrains Mono',
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Rect plate = Rect.fromLTWH(
        cropRect.left + 8,
        cropRect.top + 8,
        text.width + 16,
        text.height + 8,
      );
      canvas.drawRect(
        plate,
        Paint()
          ..color = const Color(0xffffffff)
          ..isAntiAlias = false,
      );
      canvas.drawRect(plate, stroke..strokeWidth = 1);
      text.paint(canvas, plate.topLeft + const Offset(8, 4));
    }
  }

  @override
  bool shouldRepaint(CropActivePainter oldDelegate) {
    return oldDelegate.cropRect != cropRect ||
        oldDelegate.artworkBounds != artworkBounds ||
        oldDelegate.label != label ||
        oldDelegate.color != color ||
        oldDelegate.outsideColor != outsideColor ||
        oldDelegate.handleVisualSize != handleVisualSize;
  }
}

void _drawDashedPath(
  Canvas canvas,
  Path path,
  Paint paint, {
  required double dashLength,
  required double gapLength,
}) {
  if (dashLength <= 0 || gapLength < 0) {
    return;
  }
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    while (distance < metric.length) {
      final double end = math.min(distance + dashLength, metric.length);
      canvas.drawPath(metric.extractPath(distance, end), paint);
      distance = end + gapLength;
    }
  }
}
