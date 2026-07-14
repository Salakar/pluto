import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../document/tile_store.dart';

/// Minimum supported document-to-viewport scale.
const double minimumCanvasScale = 0.10;

/// Maximum supported document-to-viewport scale.
const double maximumCanvasScale = 16.0;

/// Radius of the 100 percent zoom detent.
const double unitScaleDetentRadius = 0.04;

/// Angular radius of each quarter-turn rotation detent.
const double quarterTurnDetentRadius = 5 * math.pi / 180;

/// Normalizes [radians] to the half-open range `[-pi, pi)`.
double normalizeRadians(double radians) {
  if (!radians.isFinite) {
    throw ArgumentError.value(radians, 'radians', 'must be finite');
  }
  var normalized = (radians + math.pi) % (2 * math.pi);
  if (normalized < 0) {
    normalized += 2 * math.pi;
  }
  return normalized - math.pi;
}

/// Returns the smallest signed turn from [from] to [to].
double shortestAngularDelta(double from, double to) =>
    normalizeRadians(to - from);

/// Clamps zoom and captures the exact 100 percent detent when requested.
double constrainCanvasScale(double scale, {bool snapToUnit = true}) {
  if (!scale.isFinite) {
    throw ArgumentError.value(scale, 'scale', 'must be finite');
  }
  final constrained = scale.clamp(minimumCanvasScale, maximumCanvasScale);
  if (snapToUnit && (constrained - 1).abs() < unitScaleDetentRadius) {
    return 1;
  }
  return constrained;
}

/// Captures the nearest 0/90/180/270 degree detent when within five degrees.
double snapRotationToQuarterTurn(double radians) {
  final normalized = normalizeRadians(radians);
  final step = math.pi / 2;
  final candidate = (normalized / step).round() * step;
  if (shortestAngularDelta(normalized, candidate).abs() <=
      quarterTurnDetentRadius) {
    return normalizeRadians(candidate);
  }
  return normalized;
}

/// Applies a two-dimensional homogeneous transform to [point].
Offset transformPoint(Matrix4 transform, Offset point) {
  final values = transform.storage;
  final x = values[0] * point.dx + values[4] * point.dy + values[12];
  final y = values[1] * point.dx + values[5] * point.dy + values[13];
  final w = values[3] * point.dx + values[7] * point.dy + values[15];
  if (w == 0) {
    throw StateError('The transform maps the point to infinity.');
  }
  return Offset(x / w, y / w);
}

/// Returns an inverted copy of [transform], rejecting singular matrices.
Matrix4 invertedMatrix(Matrix4 transform) {
  final inverse = Matrix4.copy(transform);
  if (inverse.invert() == 0) {
    throw StateError('The canvas transform is singular.');
  }
  return inverse;
}

/// Returns the axis-aligned bounds of [rect] after [transform].
Rect transformedBounds(Matrix4 transform, Rect rect) {
  final corners = <Offset>[
    transformPoint(transform, rect.topLeft),
    transformPoint(transform, rect.topRight),
    transformPoint(transform, rect.bottomRight),
    transformPoint(transform, rect.bottomLeft),
  ];
  return boundsOfPoints(corners);
}

/// Area of [rect] remaining inside [clipRect] after [transform].
///
/// The transformed rectangle is clipped as a convex polygon, so rotated
/// corner-only AABB overlap cannot be mistaken for visible canvas area.
double transformedRectIntersectionArea(
  Matrix4 transform,
  Rect rect,
  Rect clipRect,
) {
  if (rect.isEmpty || clipRect.isEmpty) {
    return 0;
  }
  var polygon = <Offset>[
    transformPoint(transform, rect.topLeft),
    transformPoint(transform, rect.topRight),
    transformPoint(transform, rect.bottomRight),
    transformPoint(transform, rect.bottomLeft),
  ];
  polygon = _clipPolygon(
    polygon,
    (point) => point.dx >= clipRect.left,
    (from, to) => _verticalIntersection(from, to, clipRect.left),
  );
  polygon = _clipPolygon(
    polygon,
    (point) => point.dx <= clipRect.right,
    (from, to) => _verticalIntersection(from, to, clipRect.right),
  );
  polygon = _clipPolygon(
    polygon,
    (point) => point.dy >= clipRect.top,
    (from, to) => _horizontalIntersection(from, to, clipRect.top),
  );
  polygon = _clipPolygon(
    polygon,
    (point) => point.dy <= clipRect.bottom,
    (from, to) => _horizontalIntersection(from, to, clipRect.bottom),
  );
  if (polygon.length < 3) {
    return 0;
  }
  var twiceArea = 0.0;
  for (var index = 0; index < polygon.length; index += 1) {
    final current = polygon[index];
    final next = polygon[(index + 1) % polygon.length];
    twiceArea += current.dx * next.dy - next.dx * current.dy;
  }
  return twiceArea.abs() / 2;
}

/// Returns the smallest axis-aligned rectangle containing [points].
Rect boundsOfPoints(Iterable<Offset> points) {
  final iterator = points.iterator;
  if (!iterator.moveNext()) {
    return Rect.zero;
  }
  var left = iterator.current.dx;
  var top = iterator.current.dy;
  var right = left;
  var bottom = top;
  while (iterator.moveNext()) {
    final point = iterator.current;
    left = math.min(left, point.dx);
    top = math.min(top, point.dy);
    right = math.max(right, point.dx);
    bottom = math.max(bottom, point.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Full document-space rectangle occupied by [key].
Rect tileDocumentRect(TileKey key) => Rect.fromLTWH(
  key.x * Tile.edge.toDouble(),
  key.y * Tile.edge.toDouble(),
  Tile.edge.toDouble(),
  Tile.edge.toDouble(),
);

/// Returns in-canvas tile coordinates intersecting [documentRect].
List<TileKey> tileKeysCoveringRect(Rect documentRect, Size documentSize) {
  _validateSize(documentSize, 'documentSize');
  if (documentRect.isEmpty) {
    return const [];
  }
  final canvas = Offset.zero & documentSize;
  final clipped = documentRect.intersect(canvas);
  if (clipped.isEmpty) {
    return const [];
  }
  final firstX = (clipped.left / Tile.edge).floor();
  final firstY = (clipped.top / Tile.edge).floor();
  final lastX = (clipped.right / Tile.edge).ceil() - 1;
  final lastY = (clipped.bottom / Tile.edge).ceil() - 1;
  return <TileKey>[
    for (var y = firstY; y <= lastY; y += 1)
      for (var x = firstX; x <= lastX; x += 1) TileKey(x, y),
  ];
}

/// Computes the exact set of canvas tiles intersecting the viewport.
///
/// The inverse-transformed viewport is a convex quadrilateral. Candidate
/// tiles come from its bounding box and are then culled with a separating-axis
/// test, avoiding the large false-positive corners produced by rotation.
List<TileKey> visibleTileKeys({
  required Matrix4 viewMatrix,
  required Size viewportSize,
  required Size documentSize,
}) {
  _validateSize(viewportSize, 'viewportSize');
  _validateSize(documentSize, 'documentSize');
  final inverse = invertedMatrix(viewMatrix);
  final viewportPolygon = <Offset>[
    transformPoint(inverse, Offset.zero),
    transformPoint(inverse, Offset(viewportSize.width, 0)),
    transformPoint(inverse, viewportSize.bottomRight(Offset.zero)),
    transformPoint(inverse, Offset(0, viewportSize.height)),
  ];
  final candidates = tileKeysCoveringRect(
    boundsOfPoints(viewportPolygon),
    documentSize,
  );
  return <TileKey>[
    for (final key in candidates)
      if (_convexPolygonIntersectsRect(viewportPolygon, tileDocumentRect(key)))
        key,
  ];
}

bool _convexPolygonIntersectsRect(List<Offset> polygon, Rect rect) {
  final rectangle = <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];
  final axes = <Offset>[const Offset(1, 0), const Offset(0, 1)];
  for (var index = 0; index < polygon.length; index += 1) {
    final edge = polygon[(index + 1) % polygon.length] - polygon[index];
    axes.add(Offset(-edge.dy, edge.dx));
  }
  for (final axis in axes) {
    final polygonProjection = _project(polygon, axis);
    final rectangleProjection = _project(rectangle, axis);
    if (polygonProjection.$2 <= rectangleProjection.$1 ||
        rectangleProjection.$2 <= polygonProjection.$1) {
      return false;
    }
  }
  return true;
}

(double, double) _project(List<Offset> points, Offset axis) {
  var minimum = points.first.dx * axis.dx + points.first.dy * axis.dy;
  var maximum = minimum;
  for (final point in points.skip(1)) {
    final projection = point.dx * axis.dx + point.dy * axis.dy;
    minimum = math.min(minimum, projection);
    maximum = math.max(maximum, projection);
  }
  return (minimum, maximum);
}

List<Offset> _clipPolygon(
  List<Offset> input,
  bool Function(Offset point) isInside,
  Offset Function(Offset from, Offset to) intersection,
) {
  if (input.isEmpty) {
    return const <Offset>[];
  }
  final output = <Offset>[];
  var previous = input.last;
  var previousInside = isInside(previous);
  for (final current in input) {
    final currentInside = isInside(current);
    if (currentInside != previousInside) {
      output.add(intersection(previous, current));
    }
    if (currentInside) {
      output.add(current);
    }
    previous = current;
    previousInside = currentInside;
  }
  return output;
}

Offset _verticalIntersection(Offset from, Offset to, double x) {
  final fraction = (x - from.dx) / (to.dx - from.dx);
  return Offset(x, from.dy + (to.dy - from.dy) * fraction);
}

Offset _horizontalIntersection(Offset from, Offset to, double y) {
  final fraction = (y - from.dy) / (to.dy - from.dy);
  return Offset(from.dx + (to.dx - from.dx) * fraction, y);
}

void _validateSize(Size size, String name) {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    throw ArgumentError.value(size, name, 'must be finite and non-empty');
  }
}
