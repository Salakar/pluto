import 'dart:math' as math;
import 'dart:ui';

import 'tool.dart';

/// Binding hold duration before live geometry is perfected.
const Duration shapePerfectHold = Duration(milliseconds: 350);

/// Geometric shape offered by the contextual dock.
enum ShapeKind {
  /// Straight segment.
  line,

  /// Segment with a stamped arrow head.
  arrow,

  /// Axis-aligned rectangle.
  rectangle,

  /// Axis-aligned ellipse or near-perfect circle.
  ellipse,

  /// Regular N-sided polygon fitted to the drag bounds.
  polygon,
}

/// Immutable shape-dock options.
final class ShapeOptions {
  /// Creates validated shape options.
  factory ShapeOptions({
    ShapeKind kind = ShapeKind.line,
    int polygonSides = 5,
    bool fromCenter = false,
    bool lockAspect = false,
  }) {
    if (polygonSides < 3 || polygonSides > 64) {
      throw RangeError.range(polygonSides, 3, 64, 'polygonSides');
    }
    return ShapeOptions._(
      kind: kind,
      polygonSides: polygonSides,
      fromCenter: fromCenter,
      lockAspect: lockAspect,
    );
  }

  const ShapeOptions._({
    required this.kind,
    required this.polygonSides,
    required this.fromCenter,
    required this.lockAspect,
  });

  /// Shape fitted by a drag.
  final ShapeKind kind;

  /// Vertex count used by [ShapeKind.polygon].
  final int polygonSides;

  /// Whether the first drag point is the center of a closed shape.
  final bool fromCenter;

  /// Whether closed-shape width and height stay equal.
  final bool lockAspect;

  /// Returns a validated copy with selected fields replaced.
  ShapeOptions copyWith({
    ShapeKind? kind,
    int? polygonSides,
    bool? fromCenter,
    bool? lockAspect,
  }) => ShapeOptions(
    kind: kind ?? this.kind,
    polygonSides: polygonSides ?? this.polygonSides,
    fromCenter: fromCenter ?? this.fromCenter,
    lockAspect: lockAspect ?? this.lockAspect,
  );
}

/// Current brush snapshot used to stamp shape geometry.
final class ShapeBrushSettings {
  /// Creates validated deterministic brush settings.
  ShapeBrushSettings({
    required this.brushId,
    required this.colorArgb,
    required this.size,
    required this.seed,
  }) {
    if (brushId.isEmpty) {
      throw ArgumentError.value(brushId, 'brushId', 'must not be empty');
    }
    if (colorArgb < 0 || colorArgb > 0xffffffff) {
      throw RangeError.range(colorArgb, 0, 0xffffffff, 'colorArgb');
    }
    if (!size.isFinite || size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be finite and positive');
    }
    if (seed < 0) {
      throw ArgumentError.value(seed, 'seed', 'must be non-negative');
    }
  }

  /// Stable current brush preset identifier.
  final String brushId;

  /// Current ARGB color.
  final int colorArgb;

  /// Current brush diameter in document pixels.
  final double size;

  /// Deterministic stamp-stream seed.
  final int seed;
}

/// Closed union of fitted shape geometry.
sealed class ShapeGeometry {
  const ShapeGeometry();

  /// Axis-aligned document-space repaint bounds.
  Rect get bounds;
}

/// Fitted line geometry.
final class LineShapeGeometry extends ShapeGeometry {
  /// Creates a line segment.
  const LineShapeGeometry({required this.start, required this.end});

  /// Segment start.
  final Offset start;

  /// Segment end.
  final Offset end;

  @override
  Rect get bounds => Rect.fromPoints(start, end);
}

/// Fitted arrow geometry including its two head strokes.
final class ArrowShapeGeometry extends ShapeGeometry {
  /// Creates arrow geometry.
  const ArrowShapeGeometry({
    required this.start,
    required this.end,
    required this.headLeft,
    required this.headRight,
  });

  /// Shaft start.
  final Offset start;

  /// Shaft tip.
  final Offset end;

  /// End of the left head segment.
  final Offset headLeft;

  /// End of the right head segment.
  final Offset headRight;

  @override
  Rect get bounds {
    final double left = math.min(
      math.min(start.dx, end.dx),
      math.min(headLeft.dx, headRight.dx),
    );
    final double top = math.min(
      math.min(start.dy, end.dy),
      math.min(headLeft.dy, headRight.dy),
    );
    final double right = math.max(
      math.max(start.dx, end.dx),
      math.max(headLeft.dx, headRight.dx),
    );
    final double bottom = math.max(
      math.max(start.dy, end.dy),
      math.max(headLeft.dy, headRight.dy),
    );
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

/// Fitted rectangle geometry.
final class RectangleShapeGeometry extends ShapeGeometry {
  /// Creates rectangle geometry.
  const RectangleShapeGeometry(this.rect);

  /// Rectangle stamped through the brush.
  final Rect rect;

  @override
  Rect get bounds => rect;
}

/// Fitted ellipse geometry.
final class EllipseShapeGeometry extends ShapeGeometry {
  /// Creates ellipse geometry.
  const EllipseShapeGeometry(this.rect);

  /// Ellipse bounding rectangle.
  final Rect rect;

  /// Whether the fitted result is a mathematical circle.
  bool get isCircle => (rect.width - rect.height).abs() < 1e-9;

  @override
  Rect get bounds => rect;
}

/// Fitted polygon geometry.
final class PolygonShapeGeometry extends ShapeGeometry {
  /// Creates immutable polygon geometry.
  PolygonShapeGeometry(Iterable<Offset> vertices)
    : vertices = List<Offset>.unmodifiable(vertices) {
    if (this.vertices.length < 3) {
      throw ArgumentError.value(vertices, 'vertices', 'must contain 3 or more');
    }
  }

  /// Regular polygon vertices in winding order.
  final List<Offset> vertices;

  @override
  Rect get bounds {
    var left = vertices.first.dx;
    var top = vertices.first.dy;
    var right = left;
    var bottom = top;
    for (final Offset point in vertices.skip(1)) {
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

/// Immutable live shape presentation.
final class ShapeDraft {
  /// Creates a live shape presentation.
  const ShapeDraft({
    required this.geometry,
    required this.brush,
    required this.isPerfected,
  });

  /// Current fitted geometry.
  final ShapeGeometry geometry;

  /// Brush snapshot used for preview and commit.
  final ShapeBrushSettings brush;

  /// Whether the 350 ms hold-to-perfect detent has fired.
  final bool isPerfected;
}

/// Final shape journal command, stamped through [brush].
final class ShapeCommand implements JournaledToolCommand {
  /// Creates a final shape command.
  const ShapeCommand({required this.geometry, required this.brush});

  /// Vector metadata retained for the journal recipe.
  final ShapeGeometry geometry;

  /// Brush snapshot that rasterizes the vector geometry.
  final ShapeBrushSettings brush;

  /// This command uses the normal brush stamper rather than a separate pen.
  bool get stampsThroughCurrentBrush => true;

  @override
  JournalKind get journalKind => JournalKind.shape;
}

/// Fits one shape from [start] to [end].
ShapeGeometry fitShape({
  required Offset start,
  required Offset end,
  required ShapeOptions options,
  bool perfected = false,
}) {
  _requireFiniteOffset(start, 'start');
  _requireFiniteOffset(end, 'end');
  return switch (options.kind) {
    ShapeKind.line => LineShapeGeometry(
      start: start,
      end: perfected ? _snapLineEnd(start, end) : end,
    ),
    ShapeKind.arrow => _fitArrow(
      start,
      perfected ? _snapLineEnd(start, end) : end,
    ),
    ShapeKind.rectangle => RectangleShapeGeometry(
      _fitClosedBounds(
        start,
        end,
        fromCenter: options.fromCenter,
        forceSquare: options.lockAspect,
      ),
    ),
    ShapeKind.ellipse => EllipseShapeGeometry(
      _fitClosedBounds(
        start,
        end,
        fromCenter: options.fromCenter,
        forceSquare:
            options.lockAspect || (perfected && _isNearCircle(start, end)),
      ),
    ),
    ShapeKind.polygon => _fitPolygon(start, end, options),
  };
}

/// Timer-free live-drag and hold-to-perfect controller.
final class ShapeToolController extends ToolController<ShapeToolKind> {
  /// Creates a shape controller.
  ShapeToolController({ShapeOptions? options})
    : _options = options ?? ShapeOptions(),
      super(const ShapeToolKind());

  ShapeOptions _options;
  Offset? _start;
  Offset? _end;
  Duration? _lastTimestamp;
  Duration? _lastMotionAt;
  ShapeBrushSettings? _brush;
  bool _perfected = false;

  /// Current shape options.
  ShapeOptions get options => _options;

  /// Current fitted draft, if a drag is live.
  ShapeDraft? get draft {
    final Offset? start = _start;
    final Offset? end = _end;
    final ShapeBrushSettings? brush = _brush;
    if (start == null || end == null || brush == null) {
      return null;
    }
    return ShapeDraft(
      geometry: fitShape(
        start: start,
        end: end,
        options: _options,
        perfected: _perfected,
      ),
      brush: brush,
      isPerfected: _perfected,
    );
  }

  @override
  bool get hasLiveState => _start != null;

  /// Replaces contextual-dock shape options.
  void setOptions(ShapeOptions value) {
    _options = value;
  }

  /// Begins a live shape drag at an explicit monotonic timestamp.
  void begin({
    required Offset point,
    required Duration timestamp,
    required ShapeBrushSettings brush,
  }) {
    _requireFiniteOffset(point, 'point');
    _requireTimestamp(timestamp, null);
    _start = point;
    _end = point;
    _lastTimestamp = timestamp;
    _lastMotionAt = timestamp;
    _brush = brush;
    _perfected = false;
  }

  /// Moves the live endpoint and resets the hold detector when it changes.
  ShapeDraft update(Offset point, Duration timestamp) {
    _requireFiniteOffset(point, 'point');
    _requireTimestamp(timestamp, _lastTimestamp);
    if (_start == null || _end == null || _brush == null) {
      throw StateError('No shape drag is active.');
    }
    if (point != _end) {
      _end = point;
      _lastMotionAt = timestamp;
      _perfected = false;
    }
    _lastTimestamp = timestamp;
    _captureHold(timestamp);
    return draft!;
  }

  /// Advances the explicit hold clock without moving the pointer.
  ShapeDraft holdThrough(Duration timestamp) {
    _requireTimestamp(timestamp, _lastTimestamp);
    if (_start == null || _brush == null) {
      throw StateError('No shape drag is active.');
    }
    _lastTimestamp = timestamp;
    _captureHold(timestamp);
    return draft!;
  }

  /// Engages the same perfect-geometry detent exposed by the pointer hold.
  ShapeDraft perfect() {
    if (_start == null || _end == null || _brush == null) {
      throw StateError('No shape drag is active.');
    }
    _perfected = true;
    return draft!;
  }

  /// Commits the current vector metadata and brush snapshot.
  ShapeCommand finish(Duration timestamp) {
    final ShapeDraft current = holdThrough(timestamp);
    if (_isDegenerateShape(current.geometry)) {
      throw StateError('Cannot commit an empty shape.');
    }
    final ShapeCommand command = ShapeCommand(
      geometry: current.geometry,
      brush: current.brush,
    );
    _clear();
    return command;
  }

  void _captureHold(Duration timestamp) {
    final Duration? lastMotionAt = _lastMotionAt;
    if (lastMotionAt != null && timestamp - lastMotionAt >= shapePerfectHold) {
      _perfected = true;
    }
  }

  @override
  void cancel() {
    _clear();
  }

  void _clear() {
    _start = null;
    _end = null;
    _lastTimestamp = null;
    _lastMotionAt = null;
    _brush = null;
    _perfected = false;
  }
}

bool _isDegenerateShape(ShapeGeometry geometry) => switch (geometry) {
  final LineShapeGeometry line => line.start == line.end,
  final ArrowShapeGeometry arrow => arrow.start == arrow.end,
  final RectangleShapeGeometry rectangle => rectangle.rect.isEmpty,
  final EllipseShapeGeometry ellipse => ellipse.rect.isEmpty,
  final PolygonShapeGeometry polygon => polygon.bounds.isEmpty,
};

Offset _snapLineEnd(Offset start, Offset end) {
  final Offset delta = end - start;
  final double length = delta.distance;
  if (length == 0) {
    return end;
  }
  const double step = math.pi / 12;
  final double angle = math.atan2(delta.dy, delta.dx);
  final double snapped = (angle / step).round() * step;
  return start + Offset(math.cos(snapped), math.sin(snapped)) * length;
}

ArrowShapeGeometry _fitArrow(Offset start, Offset end) {
  final Offset delta = end - start;
  final double length = delta.distance;
  if (length == 0) {
    return ArrowShapeGeometry(
      start: start,
      end: end,
      headLeft: end,
      headRight: end,
    );
  }
  final double shaftAngle = math.atan2(delta.dy, delta.dx);
  final double headLength = math.min(24, math.max(4, length * 0.25));
  const double spread = math.pi / 6;
  final Offset headLeft =
      end -
      Offset(math.cos(shaftAngle - spread), math.sin(shaftAngle - spread)) *
          headLength;
  final Offset headRight =
      end -
      Offset(math.cos(shaftAngle + spread), math.sin(shaftAngle + spread)) *
          headLength;
  return ArrowShapeGeometry(
    start: start,
    end: end,
    headLeft: headLeft,
    headRight: headRight,
  );
}

Rect _fitClosedBounds(
  Offset start,
  Offset end, {
  required bool fromCenter,
  required bool forceSquare,
}) {
  var delta = end - start;
  if (forceSquare) {
    final double extent = math.max(delta.dx.abs(), delta.dy.abs());
    delta = Offset(
      delta.dx.isNegative ? -extent : extent,
      delta.dy.isNegative ? -extent : extent,
    );
  }
  if (fromCenter) {
    return Rect.fromPoints(start - delta, start + delta);
  }
  return Rect.fromPoints(start, start + delta);
}

bool _isNearCircle(Offset start, Offset end) {
  final double width = (end.dx - start.dx).abs();
  final double height = (end.dy - start.dy).abs();
  final double maximum = math.max(width, height);
  return maximum != 0 && (width - height).abs() / maximum <= 0.08;
}

PolygonShapeGeometry _fitPolygon(
  Offset start,
  Offset end,
  ShapeOptions options,
) {
  final Rect bounds = _fitClosedBounds(
    start,
    end,
    fromCenter: options.fromCenter,
    forceSquare: options.lockAspect,
  );
  final Offset center = bounds.center;
  final double radiusX = bounds.width / 2;
  final double radiusY = bounds.height / 2;
  return PolygonShapeGeometry(<Offset>[
    for (var index = 0; index < options.polygonSides; index += 1)
      center +
          Offset(
            math.cos(
                  -math.pi / 2 + 2 * math.pi * index / options.polygonSides,
                ) *
                radiusX,
            math.sin(
                  -math.pi / 2 + 2 * math.pi * index / options.polygonSides,
                ) *
                radiusY,
          ),
  ]);
}

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireTimestamp(Duration value, Duration? previous) {
  if (value.isNegative || (previous != null && value < previous)) {
    throw ArgumentError.value(
      value,
      'timestamp',
      'must be non-negative and monotonic',
    );
  }
}
