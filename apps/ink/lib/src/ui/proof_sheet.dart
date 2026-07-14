import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../engine/brush_engine.dart';
import '../engine/brush_presets.dart';
import '../engine/stroke_pipeline.dart';

/// Motifs repeated for every brush on the deterministic tuning sheet.
enum ProofMotifKind {
  /// A smooth S-shaped stroke at medium pressure.
  sCurve,

  /// A straight stroke whose pressure rises from light to firm.
  pressureRamp,

  /// Five rays rendered with increasing normalized stylus tilt.
  tiltFan,
}

/// Synchronous seam used to turn recipe samples into resolved brush stamps.
typedef ProofStrokeRecorder =
    List<ResolvedBrushStamp> Function({
      required BrushSpec brush,
      required List<StrokeSample> samples,
      required int seed,
    });

/// Injectable pure-plan factory used by [InkProofSheet].
typedef ProofSheetPlanBuilder = ProofSheetPlan Function();

/// One recipe and its synchronously recorded settle-form stamps.
final class ProofStrokePlan {
  /// Creates an immutable proof stroke.
  ProofStrokePlan({
    required this.seed,
    required Iterable<StrokeSample> samples,
    required Iterable<ResolvedBrushStamp> stamps,
  }) : samples = List<StrokeSample>.unmodifiable(samples),
       stamps = List<ResolvedBrushStamp>.unmodifiable(stamps) {
    if (this.samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'must not be empty');
    }
  }

  /// Stable per-stroke random seed.
  final int seed;

  /// Raw recipe samples supplied to the real stroke pipeline.
  final List<StrokeSample> samples;

  /// Target-independent impressions emitted by the real brush engine.
  final List<ResolvedBrushStamp> stamps;
}

/// One named proof motif within a brush row.
final class ProofMotifPlan {
  /// Creates an immutable motif plan.
  ProofMotifPlan({
    required this.kind,
    required this.bounds,
    required this.showsClearBackdrop,
    this.shadeDirection,
    required Iterable<ProofStrokePlan> strokes,
  }) : strokes = List<ProofStrokePlan>.unmodifiable(strokes) {
    if (bounds.isEmpty || !bounds.isFinite) {
      throw ArgumentError.value(
        bounds,
        'bounds',
        'must be finite and nonempty',
      );
    }
    if (this.strokes.isEmpty) {
      throw ArgumentError.value(strokes, 'strokes', 'must not be empty');
    }
  }

  /// Motif represented by this cell.
  final ProofMotifKind kind;

  /// Absolute canvas-space cell bounds.
  final Rect bounds;

  /// Whether a gray field makes a white clear-blend stroke visible.
  final bool showsClearBackdrop;

  /// Snapshot-shade direction visualized over a fixed middle-gray field.
  final ShadeDirection? shadeDirection;

  /// One stroke for curves and ramps, or five rays for a tilt fan.
  final List<ProofStrokePlan> strokes;
}

/// One catalog brush and its complete proof row.
final class ProofBrushRowPlan {
  /// Creates an immutable proof row.
  ProofBrushRowPlan({
    required this.brush,
    required this.bounds,
    required Iterable<ProofMotifPlan> motifs,
  }) : motifs = List<ProofMotifPlan>.unmodifiable(motifs) {
    if (bounds.isEmpty || !bounds.isFinite) {
      throw ArgumentError.value(
        bounds,
        'bounds',
        'must be finite and nonempty',
      );
    }
  }

  /// Brush rendered exactly once on the proof sheet.
  final BrushSpec brush;

  /// Absolute canvas-space row bounds.
  final Rect bounds;

  /// S-curve, pressure-ramp, and tilt-fan cells in display order.
  final List<ProofMotifPlan> motifs;
}

/// Complete immutable, painter-independent proof-sheet plan.
final class ProofSheetPlan {
  /// Creates a proof sheet with a fixed logical [size].
  ProofSheetPlan({
    required this.size,
    required Iterable<ProofBrushRowPlan> rows,
  }) : rows = List<ProofBrushRowPlan>.unmodifiable(rows) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(size, 'size', 'must be finite and nonempty');
    }
    if (this.rows.isEmpty) {
      throw ArgumentError.value(rows, 'rows', 'must not be empty');
    }
  }

  /// Stable logical canvas size used by tuning goldens.
  final Size size;

  /// Brush rows in catalog order.
  final List<ProofBrushRowPlan> rows;
}

/// Legacy WP3 starter-six canvas retained for regression tests.
const Size starterProofSheetSize = Size(954, 1408);

/// Golden canvas containing all sixteen drawing brushes in two columns.
const Size fullProofSheetSize = Size(954, 1696);

/// Records one proof stroke through the production fitter and brush engine.
List<ResolvedBrushStamp> recordProofStroke({
  required BrushSpec brush,
  required List<StrokeSample> samples,
  required int seed,
}) {
  if (samples.isEmpty) {
    throw ArgumentError.value(samples, 'samples', 'must not be empty');
  }
  final RecordingBrushStampTarget target = RecordingBrushStampTarget();
  final BrushEngine engine = BrushEngine(
    spec: brush,
    target: target,
    seed: seed,
    colorArgb: 0xff000000,
  );
  final StrokePipeline pipeline = StrokePipeline(
    smoothing: brush.smoothing,
    onPath: (List<FittedStrokeSample> fitted, {required bool isFinal}) {
      engine.stampAlong(
        fitted.map(
          (FittedStrokeSample point) => BrushPoint(
            point: point.point,
            pressure: point.pressure,
            tilt: (point.tilt.distance / (math.pi / 2))
                .clamp(0.0, 1.0)
                .toDouble(),
            timestamp: point.timestamp,
          ),
        ),
      );
      if (isFinal) {
        engine.finalize();
      }
    },
  );
  pipeline.begin(samples.first);
  for (var index = 1; index < samples.length - 1; index += 1) {
    pipeline.add(samples[index]);
  }
  if (samples.length == 1) {
    pipeline.end();
  } else {
    pipeline.end(sample: samples.last);
  }
  return target.stamps;
}

/// Builds the starter-six proof plan without images, isolates, or file I/O.
ProofSheetPlan buildStarterProofSheetPlan({
  List<BrushSpec> brushes = starterBrushes,
  ProofStrokeRecorder recorder = recordProofStroke,
}) {
  return _buildProofSheetPlan(
    brushes: brushes,
    recorder: recorder,
    size: starterProofSheetSize,
    geometryForRow: _starterRowGeometry,
  );
}

/// Builds the deterministic all-sixteen tuning plan without engine async.
ProofSheetPlan buildFullProofSheetPlan({
  List<BrushSpec> brushes = drawingBrushes,
  ProofStrokeRecorder recorder = recordProofStroke,
}) {
  if (brushes.length != 16) {
    throw ArgumentError.value(
      brushes.length,
      'brushes',
      'the full proof sheet requires exactly sixteen drawing brushes',
    );
  }
  return _buildProofSheetPlan(
    brushes: brushes,
    recorder: recorder,
    size: fullProofSheetSize,
    geometryForRow: _fullRowGeometry,
  );
}

ProofSheetPlan _buildProofSheetPlan({
  required List<BrushSpec> brushes,
  required ProofStrokeRecorder recorder,
  required Size size,
  required _ProofRowGeometry Function(int rowIndex) geometryForRow,
}) {
  final Set<String> ids = <String>{};
  for (final BrushSpec brush in brushes) {
    if (!ids.add(brush.id)) {
      throw ArgumentError.value(brush.id, 'brushes', 'contains a duplicate id');
    }
  }

  final List<ProofBrushRowPlan> rows = <ProofBrushRowPlan>[];
  for (var rowIndex = 0; rowIndex < brushes.length; rowIndex += 1) {
    final BrushSpec brush = brushes[rowIndex];
    final _ProofRowGeometry geometry = geometryForRow(rowIndex);
    final Rect rowBounds = geometry.rowBounds;
    final bool showsClearBackdrop = brush.blend.kind == BrushBlend.clear;
    final ShadeDirection? shadeDirection = brush.blend.kind == BrushBlend.shade
        ? brush.blend.shadeDirection
        : null;
    final List<ProofMotifPlan> motifs = <ProofMotifPlan>[];
    for (
      var motifIndex = 0;
      motifIndex < ProofMotifKind.values.length;
      motifIndex += 1
    ) {
      final ProofMotifKind kind = ProofMotifKind.values[motifIndex];
      final Rect bounds = geometry.motifBounds[motifIndex];
      final List<List<StrokeSample>> recipes = _motifSamples(kind, bounds);
      final List<ProofStrokePlan> strokes = <ProofStrokePlan>[];
      for (
        var strokeIndex = 0;
        strokeIndex < recipes.length;
        strokeIndex += 1
      ) {
        final int seed = proofStrokeSeed(
          brush.id,
          kind,
          strokeIndex: strokeIndex,
        );
        final List<StrokeSample> samples = recipes[strokeIndex];
        strokes.add(
          ProofStrokePlan(
            seed: seed,
            samples: samples,
            stamps: recorder(brush: brush, samples: samples, seed: seed),
          ),
        );
      }
      motifs.add(
        ProofMotifPlan(
          kind: kind,
          bounds: bounds,
          showsClearBackdrop: showsClearBackdrop,
          shadeDirection: shadeDirection,
          strokes: strokes,
        ),
      );
    }
    rows.add(
      ProofBrushRowPlan(brush: brush, bounds: rowBounds, motifs: motifs),
    );
  }
  return ProofSheetPlan(size: size, rows: rows);
}

typedef _ProofRowGeometry = ({Rect rowBounds, List<Rect> motifBounds});

_ProofRowGeometry _starterRowGeometry(int rowIndex) {
  const double headerHeight = 92;
  const double rowHeight = 216;
  const double pageMargin = 24;
  const double motifTopInset = 48;
  const double motifHeight = 140;
  const double motifWidth = 244;
  const List<double> motifLefts = <double>[166, 422, 678];
  final double rowTop = headerHeight + rowHeight * rowIndex;
  return (
    rowBounds: Rect.fromLTWH(
      pageMargin,
      rowTop,
      starterProofSheetSize.width - pageMargin * 2,
      rowHeight,
    ),
    motifBounds: <Rect>[
      for (final double left in motifLefts)
        Rect.fromLTWH(left, rowTop + motifTopInset, motifWidth, motifHeight),
    ],
  );
}

_ProofRowGeometry _fullRowGeometry(int rowIndex) {
  const double pageMargin = 24;
  const double headerHeight = 104;
  const double columnGap = 18;
  const double rowHeight = 194;
  const double labelWidth = 96;
  const double motifGap = 5;
  const int rowsPerColumn = 8;
  final double columnWidth =
      (fullProofSheetSize.width - pageMargin * 2 - columnGap) / 2;
  final int column = rowIndex ~/ rowsPerColumn;
  final int row = rowIndex % rowsPerColumn;
  final double rowLeft = pageMargin + column * (columnWidth + columnGap);
  final double rowTop = headerHeight + row * rowHeight;
  final double motifWidth = (columnWidth - labelWidth - motifGap * 2) / 3;
  return (
    rowBounds: Rect.fromLTWH(rowLeft, rowTop, columnWidth, rowHeight),
    motifBounds: <Rect>[
      for (var motif = 0; motif < 3; motif += 1)
        Rect.fromLTWH(
          rowLeft + labelWidth + motif * (motifWidth + motifGap),
          rowTop + 48,
          motifWidth,
          128,
        ),
    ],
  );
}

/// Derives a stable FNV-1a seed for one proof stroke.
int proofStrokeSeed(
  String brushId,
  ProofMotifKind kind, {
  required int strokeIndex,
}) {
  if (brushId.isEmpty) {
    throw ArgumentError.value(brushId, 'brushId', 'must not be empty');
  }
  if (strokeIndex < 0) {
    throw RangeError.value(strokeIndex, 'strokeIndex', 'must not be negative');
  }
  var hash = 0x811c9dc5;
  final String key = 'ink-proof-v1:$brushId:${kind.name}:$strokeIndex';
  for (final int codeUnit in key.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Minimal app root used by the `INK_TUNE=1` bootstrap branch.
final class InkProofSheetApp extends StatelessWidget {
  /// Creates the direct proof-sheet route.
  const InkProofSheetApp({
    this.plan,
    this.planBuilder = buildFullProofSheetPlan,
    super.key,
  });

  /// Optional prebuilt plan for deterministic tests and alternate catalogs.
  final ProofSheetPlan? plan;

  /// Synchronous plan seam used when [plan] is absent.
  final ProofSheetPlanBuilder planBuilder;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: InkProofSheet(plan: plan, planBuilder: planBuilder),
  );
}

/// One-canvas brush-catalog tuning screen.
final class InkProofSheet extends StatelessWidget {
  /// Creates a proof sheet, optionally injecting an already-built pure plan.
  const InkProofSheet({
    this.plan,
    this.planBuilder = buildFullProofSheetPlan,
    super.key,
  });

  /// Optional prebuilt plan, avoiding all construction during [build].
  final ProofSheetPlan? plan;

  /// Synchronous fallback factory used when [plan] is absent.
  final ProofSheetPlanBuilder planBuilder;

  @override
  Widget build(BuildContext context) {
    final ProofSheetPlan resolvedPlan = plan ?? planBuilder();
    return ColoredBox(
      color: const Color(0xffffffff),
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: resolvedPlan.size,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: ProofSheetPainter(resolvedPlan),
                size: resolvedPlan.size,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Synchronous vector/stamp painter for a [ProofSheetPlan].
final class ProofSheetPainter extends CustomPainter {
  /// Creates a painter for [plan].
  const ProofSheetPainter(this.plan);

  /// Pure plan painted without image upload or decoding.
  final ProofSheetPlan plan;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xffffffff), BlendMode.src);
    _drawText(
      canvas,
      plan.rows.length == 16
          ? 'INK / 16 BRUSH PROOF'
          : 'INK / STARTER BRUSH PROOF',
      const Offset(24, 18),
      fontSize: 28,
      fontWeight: FontWeight.w700,
    );
    final double firstRowTop = plan.rows
        .map((ProofBrushRowPlan row) => row.bounds.top)
        .reduce(math.min);
    for (final ProofBrushRowPlan row in plan.rows.where(
      (ProofBrushRowPlan row) => row.bounds.top == firstRowTop,
    )) {
      for (var index = 0; index < row.motifs.length; index += 1) {
        _drawText(
          canvas,
          _motifLabel(row.motifs[index].kind),
          Offset(row.motifs[index].bounds.left, row.bounds.top - 32),
          fontSize: plan.rows.length == 16 ? 11 : 15,
          fontWeight: FontWeight.w700,
        );
      }
    }

    final Paint divider = Paint()
      ..color = const Color(0xffbbbbbb)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false;
    for (final ProofBrushRowPlan row in plan.rows) {
      canvas.drawLine(row.bounds.topLeft, row.bounds.topRight, divider);
      _drawText(
        canvas,
        row.brush.name,
        Offset(row.bounds.left, row.bounds.top + 17),
        fontSize: plan.rows.length == 16 ? 15 : 18,
        fontWeight: FontWeight.w700,
      );
      _drawText(
        canvas,
        row.brush.id,
        Offset(row.bounds.left, row.bounds.top + 40),
        fontSize: plan.rows.length == 16 ? 10 : 12,
        color: const Color(0xff666666),
      );
      for (final ProofMotifPlan motif in row.motifs) {
        _paintMotif(canvas, motif, divider);
      }
    }
  }

  void _paintMotif(Canvas canvas, ProofMotifPlan motif, Paint divider) {
    canvas.save();
    canvas.clipRect(motif.bounds);
    if (motif.showsClearBackdrop || motif.shadeDirection != null) {
      canvas.drawRect(
        motif.bounds,
        Paint()
          ..color = motif.showsClearBackdrop
              ? const Color(0xff777777)
              : const Color(0xff999999)
          ..style = PaintingStyle.fill,
      );
      _paintClearBackdropHatch(canvas, motif.bounds);
    }
    for (final ProofStrokePlan stroke in motif.strokes) {
      _paintStroke(
        canvas,
        stroke,
        visualizesClear: motif.showsClearBackdrop,
        shadeDirection: motif.shadeDirection,
      );
    }
    canvas.restore();
    canvas.drawRect(motif.bounds, divider);
  }

  void _paintStroke(
    Canvas canvas,
    ProofStrokePlan stroke, {
    required bool visualizesClear,
    required ShadeDirection? shadeDirection,
  }) {
    if (stroke.stamps.isEmpty) {
      return;
    }
    final int overlapCap = stroke.stamps.first.maxOverlapSteps;
    if (overlapCap > 0 &&
        stroke.stamps.every(
          (ResolvedBrushStamp stamp) => stamp.grain == null,
        )) {
      _paintCappedStroke(canvas, stroke.stamps, overlapCap: overlapCap);
      return;
    }
    for (final ResolvedBrushStamp stamp in stroke.stamps) {
      _paintStamp(
        canvas,
        stamp,
        visualizesClear: visualizesClear,
        shadeDirection: shadeDirection,
      );
    }
  }

  void _paintCappedStroke(
    Canvas canvas,
    List<ResolvedBrushStamp> stamps, {
    required int overlapCap,
  }) {
    Path? firstCoverage;
    Path? secondCoverage;
    for (final ResolvedBrushStamp stamp in stamps) {
      final Path impression = _stampOutline(stamp);
      final Path? existing = firstCoverage;
      if (existing == null) {
        firstCoverage = impression;
        continue;
      }
      if (overlapCap > 1) {
        final Path overlap = Path.combine(
          PathOperation.intersect,
          existing,
          impression,
        );
        secondCoverage = secondCoverage == null
            ? overlap
            : Path.combine(PathOperation.union, secondCoverage, overlap);
      }
      firstCoverage = Path.combine(PathOperation.union, existing, impression);
    }
    final Path? coverage = firstCoverage;
    if (coverage == null) {
      return;
    }
    final ResolvedBrushStamp sample = stamps.first;
    final int sourceAlpha = (sample.colorArgb >>> 24) & 0xff;
    final double meanFlow =
        stamps.fold<double>(0, (double sum, stamp) => sum + stamp.flow) /
        stamps.length;
    final int alpha = (sourceAlpha * meanFlow).round().clamp(0, 255);
    final Paint paint = Paint()
      ..color = Color.fromARGB(
        alpha,
        (sample.colorArgb >>> 16) & 0xff,
        (sample.colorArgb >>> 8) & 0xff,
        sample.colorArgb & 0xff,
      )
      ..blendMode = sample.blend == BrushBlend.multiply
          ? BlendMode.multiply
          : BlendMode.srcOver
      ..style = PaintingStyle.fill
      ..isAntiAlias = sample.nibKind != NibKind.chisel;
    canvas.drawPath(coverage, paint);
    if (overlapCap > 1 && secondCoverage != null) {
      canvas.drawPath(secondCoverage, paint);
    }
  }

  Path _stampOutline(ResolvedBrushStamp stamp) {
    if (stamp.nibKind == NibKind.chisel) {
      final double radiusX = stamp.diameterX / 2;
      final double radiusY = stamp.diameterY / 2;
      final double cosine = math.cos(stamp.angleRadians);
      final double sine = math.sin(stamp.angleRadians);
      final Path path = Path();
      var isFirst = true;
      for (final Offset local in <Offset>[
        Offset(-radiusX, -radiusY),
        Offset(radiusX, -radiusY),
        Offset(radiusX, radiusY),
        Offset(-radiusX, radiusY),
      ]) {
        final Offset point = Offset(
          stamp.center.dx + local.dx * cosine - local.dy * sine,
          stamp.center.dy + local.dx * sine + local.dy * cosine,
        );
        if (isFirst) {
          path.moveTo(point.dx, point.dy);
          isFirst = false;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path..close();
    }
    const int segments = 24;
    final double radiusX = stamp.diameterX / 2;
    final double radiusY = stamp.diameterY / 2;
    final double cosine = math.cos(stamp.angleRadians);
    final double sine = math.sin(stamp.angleRadians);
    final Path path = Path();
    for (var segment = 0; segment < segments; segment += 1) {
      final double angle = segment * math.pi * 2 / segments;
      final double localX = math.cos(angle) * radiusX;
      final double localY = math.sin(angle) * radiusY;
      final Offset point = Offset(
        stamp.center.dx + localX * cosine - localY * sine,
        stamp.center.dy + localX * sine + localY * cosine,
      );
      if (segment == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  void _paintStamp(
    Canvas canvas,
    ResolvedBrushStamp stamp, {
    required bool visualizesClear,
    required ShadeDirection? shadeDirection,
  }) {
    final ResolvedBrushGrain? grain = stamp.grain;
    if (grain != null) {
      _paintGrainedStamp(
        canvas,
        stamp,
        grain,
        visualizesClear: visualizesClear,
        shadeDirection: shadeDirection,
      );
      return;
    }
    final int sourceAlpha = visualizesClear
        ? 255
        : (stamp.colorArgb >>> 24) & 0xff;
    final int alpha = (sourceAlpha * stamp.flow).round().clamp(0, 255);
    if (alpha == 0) {
      return;
    }
    final Color color = visualizesClear
        ? Color.fromARGB(alpha, 255, 255, 255)
        : shadeDirection != null
        ? Color.fromARGB(
            alpha,
            shadeDirection == ShadeDirection.darker ? 70 : 220,
            shadeDirection == ShadeDirection.darker ? 70 : 220,
            shadeDirection == ShadeDirection.darker ? 70 : 220,
          )
        : Color.fromARGB(
            alpha,
            (stamp.colorArgb >>> 16) & 0xff,
            (stamp.colorArgb >>> 8) & 0xff,
            stamp.colorArgb & 0xff,
          );
    canvas.save();
    canvas.translate(stamp.center.dx, stamp.center.dy);
    canvas.rotate(stamp.angleRadians);
    final Rect stampRect = Rect.fromCenter(
      center: Offset.zero,
      width: stamp.diameterX,
      height: stamp.diameterY,
    );
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = stamp.nibKind != NibKind.chisel;
    if (stamp.nibKind == NibKind.chisel) {
      canvas.drawRect(stampRect, paint);
    } else {
      canvas.drawOval(stampRect, paint);
    }
    canvas.restore();
  }

  void _paintGrainedStamp(
    Canvas canvas,
    ResolvedBrushStamp stamp,
    ResolvedBrushGrain grain, {
    required bool visualizesClear,
    required ShadeDirection? shadeDirection,
  }) {
    final double cosine = math.cos(stamp.angleRadians);
    final double sine = math.sin(stamp.angleRadians);
    final double radiusX = stamp.diameterX / 2;
    final double radiusY = stamp.diameterY / 2;
    final Rect bounds = stamp.bounds;
    final Paint pixel = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    for (var y = bounds.top.floor(); y < bounds.bottom.ceil(); y += 1) {
      for (var x = bounds.left.floor(); x < bounds.right.ceil(); x += 1) {
        final Offset point = Offset(x + 0.5, y + 0.5);
        final Offset delta = point - stamp.center;
        final double localX = delta.dx * cosine + delta.dy * sine;
        final double localY = -delta.dx * sine + delta.dy * cosine;
        final double normalized =
            localX * localX / (radiusX * radiusX) +
            localY * localY / (radiusY * radiusY);
        if (normalized > 1) {
          continue;
        }
        final double coverage =
            stamp.flow * grain.coverageAt(point, stampCenter: stamp.center);
        final int alpha = (255 * coverage).round().clamp(0, 255);
        if (alpha == 0) {
          continue;
        }
        final int shadeGray = shadeDirection == ShadeDirection.lighter
            ? 220
            : 70;
        pixel.color = visualizesClear
            ? Color.fromARGB(alpha, 255, 255, 255)
            : shadeDirection != null
            ? Color.fromARGB(alpha, shadeGray, shadeGray, shadeGray)
            : Color.fromARGB(alpha, 0, 0, 0);
        canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), pixel);
      }
    }
  }

  void _paintClearBackdropHatch(Canvas canvas, Rect bounds) {
    final Paint hatch = Paint()
      ..color = const Color(0xff999999)
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (double x = bounds.left - bounds.height; x < bounds.right; x += 12) {
      canvas.drawLine(
        Offset(x, bounds.bottom),
        Offset(x + bounds.height, bounds.top),
        hatch,
      );
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset, {
    required double fontSize,
    FontWeight fontWeight = FontWeight.w500,
    Color color = const Color(0xff000000),
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontFamily: 'Inter',
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(ProofSheetPainter oldDelegate) =>
      !identical(oldDelegate.plan, plan);
}

List<List<StrokeSample>> _motifSamples(ProofMotifKind kind, Rect bounds) {
  switch (kind) {
    case ProofMotifKind.sCurve:
      return <List<StrokeSample>>[_sCurveSamples(bounds)];
    case ProofMotifKind.pressureRamp:
      return <List<StrokeSample>>[_pressureRampSamples(bounds)];
    case ProofMotifKind.tiltFan:
      return _tiltFanSamples(bounds);
  }
}

List<StrokeSample> _sCurveSamples(Rect bounds) {
  const int count = 33;
  final Rect pathBounds = bounds.deflate(18);
  return List<StrokeSample>.generate(count, (int index) {
    final double t = index / (count - 1);
    final double x = pathBounds.left + pathBounds.width * t;
    final double y =
        pathBounds.center.dy +
        math.sin((t - 0.5) * math.pi * 2) * pathBounds.height * 0.38;
    return StrokeSample(
      point: Offset(x, y),
      pressure: 0.68,
      tilt: Offset.zero,
      timestamp: Duration(milliseconds: index * 10),
    );
  }, growable: false);
}

List<StrokeSample> _pressureRampSamples(Rect bounds) {
  const int count = 25;
  final Rect pathBounds = bounds.deflate(18);
  return List<StrokeSample>.generate(count, (int index) {
    final double t = index / (count - 1);
    return StrokeSample(
      point: Offset(
        pathBounds.left + pathBounds.width * t,
        pathBounds.center.dy,
      ),
      pressure: 0.08 + 0.92 * t,
      tilt: Offset.zero,
      timestamp: Duration(milliseconds: index * 12),
    );
  }, growable: false);
}

List<List<StrokeSample>> _tiltFanSamples(Rect bounds) {
  const int rayCount = 5;
  const int samplesPerRay = 9;
  final Offset origin = Offset(bounds.left + 28, bounds.center.dy);
  return List<List<StrokeSample>>.generate(rayCount, (int rayIndex) {
    final double fraction = rayIndex / (rayCount - 1);
    final double angle = (-32 + 64 * fraction) * math.pi / 180;
    final Offset endpoint =
        origin + Offset(math.cos(angle), math.sin(angle)) * (bounds.width - 54);
    return List<StrokeSample>.generate(samplesPerRay, (int sampleIndex) {
      final double t = sampleIndex / (samplesPerRay - 1);
      return StrokeSample(
        point: Offset.lerp(origin, endpoint, t)!,
        pressure: 0.68,
        tilt: Offset(fraction * math.pi / 2, 0),
        timestamp: Duration(milliseconds: sampleIndex * 12),
      );
    }, growable: false);
  }, growable: false);
}

String _motifLabel(ProofMotifKind kind) => switch (kind) {
  ProofMotifKind.sCurve => 'S-CURVE',
  ProofMotifKind.pressureRamp => 'PRESSURE RAMP',
  ProofMotifKind.tiltFan => 'TILT FAN',
};
