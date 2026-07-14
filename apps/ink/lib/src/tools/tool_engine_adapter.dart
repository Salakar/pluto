import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../engine/brush_engine.dart';
import '../engine/brush_presets.dart';
import '../engine/brush_tool_hooks.dart';
import '../engine/compositor.dart';
import '../engine/raster_ops.dart' as raster;
import '../engine/selection_mask.dart' as engine;
import '../engine/symmetry.dart';
import '../engine/transform_resampler.dart' as raster;
import 'fill_tool.dart';
import 'selection_tool.dart' as tool;
import 'shape_tool.dart';
import 'transform_tool.dart';

/// Expands a document-offset tool mask into a canvas-aligned engine mask.
engine.SelectionMask engineSelectionMask({
  required tool.SelectionMask selection,
  required int canvasWidth,
  required int canvasHeight,
}) {
  if (canvasWidth <= 0 || canvasHeight <= 0) {
    throw ArgumentError.value(
      (canvasWidth, canvasHeight),
      'canvas size',
      'must be positive',
    );
  }
  final Uint8List coverage = Uint8List(canvasWidth * canvasHeight);
  final int left = math.max(0, selection.left);
  final int top = math.max(0, selection.top);
  final int right = math.min(canvasWidth, selection.left + selection.width);
  final int bottom = math.min(canvasHeight, selection.top + selection.height);
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      coverage[y * canvasWidth + x] = selection.coverageAt(x, y);
    }
  }
  return engine.SelectionMask(
    width: canvasWidth,
    height: canvasHeight,
    coverage: coverage,
  );
}

/// Converts a canvas-aligned worker result into a document-offset tool mask.
tool.SelectionMask toolSelectionMask(engine.SelectionMask selection) =>
    tool.SelectionMask(
      left: 0,
      top: 0,
      width: selection.width,
      height: selection.height,
      coverage: selection.coverage,
    );

/// Extracts a tightly bounded, selection-clipped clipboard fragment.
tool.RgbaFragment extractSelectionFragment({
  required raster.RgbaBitmap source,
  required tool.SelectionMask selection,
  required String documentId,
  required String layerId,
}) {
  final int searchLeft = math.max(0, selection.left);
  final int searchTop = math.max(0, selection.top);
  final int searchRight = math.min(
    source.width,
    selection.left + selection.width,
  );
  final int searchBottom = math.min(
    source.height,
    selection.top + selection.height,
  );
  int? left;
  int? top;
  int? right;
  int? bottom;
  for (var y = searchTop; y < searchBottom; y += 1) {
    for (var x = searchLeft; x < searchRight; x += 1) {
      if (selection.coverageAt(x, y) == 0) {
        continue;
      }
      left = left == null ? x : math.min(left, x);
      top = top == null ? y : math.min(top, y);
      right = right == null ? x + 1 : math.max(right, x + 1);
      bottom = bottom == null ? y + 1 : math.max(bottom, y + 1);
    }
  }
  if (left == null || top == null || right == null || bottom == null) {
    throw StateError('Cannot extract an empty selection.');
  }
  final int width = right - left;
  final int height = bottom - top;
  final Uint8List rgba = Uint8List(width * height * 4);
  final Uint8List sourcePixels = source.pixels;
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      final int coverage = selection.coverageAt(x, y);
      final int sourceOffset = (y * source.width + x) * 4;
      final int targetOffset = ((y - top) * width + x - left) * 4;
      for (var channel = 0; channel < 4; channel += 1) {
        rgba[targetOffset + channel] =
            (sourcePixels[sourceOffset + channel] * coverage + 127) ~/ 255;
      }
    }
  }
  final Rect bounds = Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
  return tool.RgbaFragment(
    width: width,
    height: height,
    rgba: rgba,
    source: tool.FragmentSourceMetadata(
      documentId: documentId,
      layerId: layerId,
      sourceBounds: bounds,
    ),
  );
}

/// Resamples and source-overs one floated clipboard fragment into [target].
///
/// Drag previews pass [RasterSampling.nearest]; a journaled float commit uses
/// the default bilinear quality. Negative scales mirror around the float's
/// destination center without changing its top-left placement contract.
raster.RgbaBitmap compositeSelectionFloat({
  required tool.SelectionFloat floatingSelection,
  required raster.RgbaBitmap target,
  raster.RasterSampling sampling = raster.RasterSampling.bilinear,
}) {
  final tool.SelectionFloat floating = floatingSelection;
  final raster.RgbaBitmap fragment = raster.RgbaBitmap.fromPremultipliedRgba(
    width: floating.fragment.width,
    height: floating.fragment.height,
    pixels: floating.fragment.rgbaBytes,
  );
  final double scaleX = floating.scaleX.abs();
  final double scaleY = floating.scaleY.abs();
  final double width = fragment.width * scaleX;
  final double height = fragment.height * scaleY;
  final Offset pixelCenter = Offset(
    floating.topLeft.dx + (width - 1) / 2,
    floating.topLeft.dy + (height - 1) / 2,
  );
  final raster.AffineRasterTransform placement = raster.AffineRasterTransform(
    m00: scaleX,
    m01: 0,
    m02: floating.topLeft.dx + (scaleX - 1) / 2,
    m10: 0,
    m11: scaleY,
    m12: floating.topLeft.dy + (scaleY - 1) / 2,
  );
  final raster.AffineRasterTransform reflection =
      raster.AffineRasterTransform.scale(
        floating.scaleX.isNegative ? -1 : 1,
        floating.scaleY.isNegative ? -1 : 1,
        originX: pixelCenter.dx,
        originY: pixelCenter.dy,
      );
  final raster.AffineRasterTransform rotation =
      raster.AffineRasterTransform.rotation(
        floating.rotationRadians,
        originX: pixelCenter.dx,
        originY: pixelCenter.dy,
      );
  final raster.RgbaBitmap transformed = raster.resampleTransformedRgba(
    source: fragment,
    destinationWidth: target.width,
    destinationHeight: target.height,
    sourceToDestination: placement.followedBy(reflection).followedBy(rotation),
    sampling: sampling,
  );
  return _sourceOver(transformed, target);
}

/// Builds the public stroke target used by draw and pixel erase tools.
///
/// A tool selection is applied first, then optional stroke-only symmetry
/// expands each resolved stamp through the same target. The caller keeps one
/// BrushEngine and one journal recipe, so mirror copies cannot split into
/// separate undo actions.
BrushStampTarget toolStrokeTarget({
  required StrokeBuffer buffer,
  tool.SelectionMask? selection,
  int? canvasWidth,
  int? canvasHeight,
  SymmetryConfiguration? symmetry,
}) {
  if (selection != null && (canvasWidth == null || canvasHeight == null)) {
    throw ArgumentError(
      'canvasWidth and canvasHeight are required with a selection.',
    );
  }
  final StrokeBufferBrushTarget clipped = StrokeBufferBrushTarget(
    buffer: buffer,
    selection: selection == null
        ? null
        : engineSelectionMask(
            selection: selection,
            canvasWidth: canvasWidth!,
            canvasHeight: canvasHeight!,
          ),
  );
  final SymmetryConfiguration? configuration = symmetry;
  if (configuration == null || configuration.mode == SymmetryMode.off) {
    return clipped;
  }
  return SymmetryBrushStampTarget(
    target: clipped,
    configuration: configuration,
  );
}

/// Executes a wand request through the pure contiguous-region engine.
tool.SelectionMask executeWandSelection({
  required tool.WandSelectionRequest request,
  required raster.RgbaBitmap source,
}) {
  final engine.SelectionMask selected = raster.wandRegion(
    source: source,
    seedX: request.seed.dx.floor(),
    seedY: request.seed.dy.floor(),
    tolerance: request.tolerance,
    gapClose: request.gapClose,
  );
  return toolSelectionMask(selected);
}

/// Rasterizes a rectangular request as a hard-edged document-offset mask.
tool.SelectionMask executeRectangleSelection(
  tool.RectangleSelectionRequest request,
) => tool.SelectionMask.filledRect(request.rect);

/// Rasterizes a freehand lasso with the deterministic even-odd fill rule.
tool.SelectionMask executeLassoSelection(tool.LassoSelectionRequest request) {
  final List<Offset> points = request.points;
  var left = points.first.dx;
  var top = points.first.dy;
  var right = left;
  var bottom = top;
  for (final Offset point in points.skip(1)) {
    left = math.min(left, point.dx);
    top = math.min(top, point.dy);
    right = math.max(right, point.dx);
    bottom = math.max(bottom, point.dy);
  }
  final int pixelLeft = left.floor();
  final int pixelTop = top.floor();
  final int pixelRight = right.ceil();
  final int pixelBottom = bottom.ceil();
  final int width = pixelRight - pixelLeft;
  final int height = pixelBottom - pixelTop;
  if (width <= 0 || height <= 0) {
    throw ArgumentError.value(
      points,
      'request.points',
      'must enclose a two-dimensional region',
    );
  }
  final Uint8List coverage = Uint8List(width * height);
  for (var y = pixelTop; y < pixelBottom; y += 1) {
    for (var x = pixelLeft; x < pixelRight; x += 1) {
      if (_insideEvenOdd(Offset(x + 0.5, y + 0.5), points)) {
        coverage[(y - pixelTop) * width + x - pixelLeft] = 255;
      }
    }
  }
  return tool.SelectionMask(
    left: pixelLeft,
    top: pixelTop,
    width: width,
    height: height,
    coverage: coverage,
  );
}

/// Applies a selection mask as destination-out coverage to [source].
raster.RgbaBitmap clearBitmapWithSelectionMask({
  required raster.RgbaBitmap source,
  required tool.SelectionMask selection,
}) {
  final Uint8List pixels = Uint8List.fromList(source.pixels);
  final int left = math.max(0, selection.left);
  final int top = math.max(0, selection.top);
  final int right = math.min(source.width, selection.left + selection.width);
  final int bottom = math.min(source.height, selection.top + selection.height);
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      final int inverse = 255 - selection.coverageAt(x, y);
      final int offset = (y * source.width + x) * 4;
      for (var channel = 0; channel < 4; channel += 1) {
        pixels[offset + channel] =
            (pixels[offset + channel] * inverse + 127) ~/ 255;
      }
    }
  }
  return raster.RgbaBitmap.fromPremultipliedRgba(
    width: source.width,
    height: source.height,
    pixels: pixels,
  );
}

/// Executes a typed fill command through the pure flood/fill engine.
raster.RgbaBitmap executeFill({
  required FillCommand command,
  required raster.RgbaBitmap activeLayer,
  raster.RgbaBitmap? composite,
}) {
  final raster.RgbaBitmap? sampleSource =
      switch (command.options.sampleSource) {
        FillSampleSource.activeLayer => null,
        FillSampleSource.composite =>
          composite ??
              (throw ArgumentError.notNull('composite for composite sampling')),
      };
  final tool.SelectionMask? selection = command.selectionClip;
  final engine.SelectionMask? clip = selection == null
      ? null
      : engineSelectionMask(
          selection: selection,
          canvasWidth: activeLayer.width,
          canvasHeight: activeLayer.height,
        );
  return raster.floodFill(
    target: activeLayer,
    sampleSource: sampleSource,
    seedX: command.seed.dx.floor(),
    seedY: command.seed.dy.floor(),
    tolerance: command.options.tolerance,
    gapClose: command.options.gapClose,
    grow: command.options.grow,
    fill: _engineFill(command.options.style),
    clip: clip,
  );
}

/// Resamples a transform preview or commit into a full destination raster.
raster.RgbaBitmap executeTransform({
  required TransformSnapshot snapshot,
  required raster.RgbaBitmap source,
  required int destinationWidth,
  required int destinationHeight,
}) {
  final Rect bounds = snapshot.bounds;
  final double scaleX = bounds.width / source.width;
  final double scaleY = bounds.height / source.height;
  final raster.AffineRasterTransform placement = raster.AffineRasterTransform(
    m00: scaleX,
    m01: 0,
    m02: bounds.left + (scaleX - 1) / 2,
    m10: 0,
    m11: scaleY,
    m12: bounds.top + (scaleY - 1) / 2,
  );
  final Offset destinationCenter = Offset(
    bounds.center.dx - 0.5,
    bounds.center.dy - 0.5,
  );
  final raster.AffineRasterTransform rotation =
      raster.AffineRasterTransform.rotation(
        snapshot.rotationRadians,
        originX: destinationCenter.dx,
        originY: destinationCenter.dy,
      );
  final raster.AffineRasterTransform reflection =
      raster.AffineRasterTransform.scale(
        snapshot.isFlippedHorizontally ? -1 : 1,
        snapshot.isFlippedVertically ? -1 : 1,
        originX: destinationCenter.dx,
        originY: destinationCenter.dy,
      );
  return raster.resampleTransformedRgba(
    source: source,
    destinationWidth: destinationWidth,
    destinationHeight: destinationHeight,
    sourceToDestination: placement.followedBy(reflection).followedBy(rotation),
    sampling: snapshot.resampling == TransformResampling.nearest
        ? raster.RasterSampling.nearest
        : raster.RasterSampling.bilinear,
  );
}

/// Converts vector shape metadata to independent brush-stamped contours.
///
/// Arrow heads are separate contours so the stamper never draws an accidental
/// connector between their endpoints. Closed primitives repeat their first
/// point, making closure explicit and deterministic.
List<List<Offset>> shapeBrushContours(
  ShapeGeometry geometry, {
  int ellipseSegments = 96,
}) {
  if (ellipseSegments < 12 || ellipseSegments > 512) {
    throw RangeError.range(ellipseSegments, 12, 512, 'ellipseSegments');
  }
  final List<List<Offset>> contours = switch (geometry) {
    LineShapeGeometry(:final start, :final end) => <List<Offset>>[
      <Offset>[start, end],
    ],
    ArrowShapeGeometry(
      :final start,
      :final end,
      :final headLeft,
      :final headRight,
    ) =>
      <List<Offset>>[
        <Offset>[start, end],
        <Offset>[end, headLeft],
        <Offset>[end, headRight],
      ],
    RectangleShapeGeometry(:final rect) => <List<Offset>>[
      <Offset>[
        rect.topLeft,
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
        rect.topLeft,
      ],
    ],
    EllipseShapeGeometry(:final rect) => <List<Offset>>[
      <Offset>[
        for (var index = 0; index <= ellipseSegments; index += 1)
          rect.center +
              Offset(
                math.cos(index * 2 * math.pi / ellipseSegments) *
                    rect.width /
                    2,
                math.sin(index * 2 * math.pi / ellipseSegments) *
                    rect.height /
                    2,
              ),
      ],
    ],
    PolygonShapeGeometry(:final vertices) => <List<Offset>>[
      <Offset>[...vertices, vertices.first],
    ],
  };
  return List<List<Offset>>.unmodifiable(
    contours.map<List<Offset>>(List<Offset>.unmodifiable),
  );
}

/// Stamps every contour of [command] through the resolved current brush.
///
/// All contours belong to the one [ShapeCommand] and therefore one `shape`
/// journal entry. Separate deterministic seeds prevent contour-local taper and
/// particle state from bleeding across discontinuities.
Rect stampShapeThroughBrush({
  required ShapeCommand command,
  required BrushSpec brush,
  required BrushStampTarget target,
}) {
  if (brush.id != command.brush.brushId) {
    throw ArgumentError.value(
      brush.id,
      'brush',
      'must match the command brush ${command.brush.brushId}',
    );
  }
  Rect? damage;
  final List<List<Offset>> contours = shapeBrushContours(command.geometry);
  var timestampMicros = 0;
  for (
    var contourIndex = 0;
    contourIndex < contours.length;
    contourIndex += 1
  ) {
    final BrushEngine engine = BrushEngine(
      spec: brush,
      target: target,
      seed: command.brush.seed + contourIndex,
      colorArgb: command.brush.colorArgb,
      size: command.brush.size,
    );
    final List<BrushPoint> points = <BrushPoint>[];
    for (final Offset point in contours[contourIndex]) {
      points.add(
        BrushPoint(
          point: point,
          pressure: 1,
          timestamp: Duration(microseconds: timestampMicros),
        ),
      );
      timestampMicros += 1000;
    }
    final Rect contourDamage = _unionNonEmpty(
      engine.stampAlong(points),
      engine.finalize(),
    );
    if (!contourDamage.isEmpty) {
      damage = damage == null
          ? contourDamage
          : damage.expandToInclude(contourDamage);
    }
  }
  return damage ?? Rect.zero;
}

raster.RasterFillStyle _engineFill(FillMaterial material) {
  final raster.RgbaColor color = raster.RgbaColor.fromArgb(material.colorArgb);
  return switch (material) {
    SolidFillStyle() => raster.SolidRasterFill(color),
    HatchFillStyle(:final spacing, :final angleDegrees) =>
      raster.HatchRasterFill(
        color: color,
        spacing: spacing.round().clamp(2, 64),
        direction: _hatchDirection(angleDegrees),
      ),
    DotScreenFillStyle(:final density) => raster.DotScreenRasterFill(
      color: color,
      density: 0.5,
      matrix: density == FillDotScreenDensity.bayer4
          ? raster.DotScreenMatrix.bayer4
          : raster.DotScreenMatrix.bayer8,
    ),
  };
}

raster.HatchDirection _hatchDirection(double angleDegrees) {
  final double normalized = ((angleDegrees % 180) + 180) % 180;
  if (normalized < 22.5 || normalized >= 157.5) {
    return raster.HatchDirection.horizontal;
  }
  if (normalized < 67.5) {
    return raster.HatchDirection.diagonalDown;
  }
  if (normalized < 112.5) {
    return raster.HatchDirection.vertical;
  }
  return raster.HatchDirection.diagonalUp;
}

raster.RgbaBitmap _sourceOver(
  raster.RgbaBitmap source,
  raster.RgbaBitmap destination,
) {
  if (source.width != destination.width ||
      source.height != destination.height) {
    throw ArgumentError('Source and destination bitmap sizes must match.');
  }
  final Uint8List sourcePixels = source.pixels;
  final Uint8List output = Uint8List.fromList(destination.pixels);
  for (var offset = 0; offset < output.length; offset += 4) {
    final int sourceAlpha = sourcePixels[offset + 3];
    if (sourceAlpha == 0) {
      continue;
    }
    final int inverseAlpha = 255 - sourceAlpha;
    for (var channel = 0; channel < 4; channel += 1) {
      final int value =
          sourcePixels[offset + channel] +
          (output[offset + channel] * inverseAlpha + 127) ~/ 255;
      output[offset + channel] = math.min(255, value);
    }
  }
  return raster.RgbaBitmap.fromPremultipliedRgba(
    width: destination.width,
    height: destination.height,
    pixels: output,
  );
}

Rect _unionNonEmpty(Rect first, Rect second) {
  if (first.isEmpty) {
    return second;
  }
  if (second.isEmpty) {
    return first;
  }
  return first.expandToInclude(second);
}

bool _insideEvenOdd(Offset point, List<Offset> polygon) {
  var inside = false;
  var previous = polygon.last;
  for (final Offset current in polygon) {
    final bool crossesY = (current.dy > point.dy) != (previous.dy > point.dy);
    if (crossesY) {
      final double crossingX =
          (previous.dx - current.dx) *
              (point.dy - current.dy) /
              (previous.dy - current.dy) +
          current.dx;
      if (point.dx < crossingX) {
        inside = !inside;
      }
    }
    previous = current;
  }
  return inside;
}
