import 'dart:math' as math;

/// Stroke-only symmetry modes supported by WP5.
enum SymmetryMode { off, vertical, horizontal, quad }

/// Framework-independent document-space point.
final class SymmetryPoint {
  SymmetryPoint(this.x, this.y) {
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError.value((x, y), 'point', 'must be finite');
    }
  }

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SymmetryPoint && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'SymmetryPoint($x, $y)';
}

/// One identity/reflection transform emitted by [SymmetryConfiguration].
final class SymmetryReflection {
  const SymmetryReflection._({
    required this.acrossVerticalAxis,
    required this.acrossHorizontalAxis,
    required this.axisX,
    required this.axisY,
  });

  final bool acrossVerticalAxis;
  final bool acrossHorizontalAxis;
  final double axisX;
  final double axisY;

  /// Whether this is the unchanged source copy.
  bool get isIdentity => !acrossVerticalAxis && !acrossHorizontalAxis;

  /// Reflects [point] around the configured axes.
  SymmetryPoint applyToPoint(SymmetryPoint point) => SymmetryPoint(
    acrossVerticalAxis ? 2 * axisX - point.x : point.x,
    acrossHorizontalAxis ? 2 * axisY - point.y : point.y,
  );

  /// Reflects a direction vector. Axis position does not affect vectors.
  SymmetryPoint applyToVector(SymmetryPoint vector) => SymmetryPoint(
    acrossVerticalAxis ? -vector.x : vector.x,
    acrossHorizontalAxis ? -vector.y : vector.y,
  );

  /// Reflects a nib/direction angle and normalizes it to `[-pi, pi)`.
  double applyToAngle(double radians) {
    if (!radians.isFinite) {
      throw ArgumentError.value(radians, 'radians', 'must be finite');
    }
    final x = acrossVerticalAxis ? -math.cos(radians) : math.cos(radians);
    final y = acrossHorizontalAxis ? -math.sin(radians) : math.sin(radians);
    return _normalizeRadians(math.atan2(y, x));
  }
}

/// Persistent axes that expand each brush stamp into mirrored copies.
final class SymmetryConfiguration {
  SymmetryConfiguration({
    required this.mode,
    required this.axisX,
    required this.axisY,
  }) {
    if (!axisX.isFinite) {
      throw ArgumentError.value(axisX, 'axisX', 'must be finite');
    }
    if (!axisY.isFinite) {
      throw ArgumentError.value(axisY, 'axisY', 'must be finite');
    }
  }

  factory SymmetryConfiguration.off() =>
      SymmetryConfiguration(mode: SymmetryMode.off, axisX: 0, axisY: 0);

  final SymmetryMode mode;
  final double axisX;
  final double axisY;

  /// Candidate transforms in deterministic journal order: original, vertical,
  /// horizontal, then the double reflection for quad mode.
  List<SymmetryReflection> get reflections {
    final identity = SymmetryReflection._(
      acrossVerticalAxis: false,
      acrossHorizontalAxis: false,
      axisX: axisX,
      axisY: axisY,
    );
    final vertical = SymmetryReflection._(
      acrossVerticalAxis: true,
      acrossHorizontalAxis: false,
      axisX: axisX,
      axisY: axisY,
    );
    final horizontal = SymmetryReflection._(
      acrossVerticalAxis: false,
      acrossHorizontalAxis: true,
      axisX: axisX,
      axisY: axisY,
    );
    final both = SymmetryReflection._(
      acrossVerticalAxis: true,
      acrossHorizontalAxis: true,
      axisX: axisX,
      axisY: axisY,
    );
    return switch (mode) {
      SymmetryMode.off => <SymmetryReflection>[identity],
      SymmetryMode.vertical => <SymmetryReflection>[identity, vertical],
      SymmetryMode.horizontal => <SymmetryReflection>[identity, horizontal],
      SymmetryMode.quad => <SymmetryReflection>[
        identity,
        vertical,
        horizontal,
        both,
      ],
    };
  }

  /// Mirrors [point] and removes coincident axis copies.
  List<SymmetryPoint> mirrorPoint(
    SymmetryPoint point, {
    double epsilon = 1e-9,
  }) {
    _checkEpsilon(epsilon);
    final result = <SymmetryPoint>[];
    for (final reflection in reflections) {
      final candidate = reflection.applyToPoint(point);
      if (!_containsNear(result, candidate, epsilon)) {
        result.add(candidate);
      }
    }
    return List<SymmetryPoint>.unmodifiable(result);
  }
}

/// Generic brush-engine hook that mirrors resolved stamp-like values.
///
/// The caller supplies coordinate access and a copy operation, keeping this
/// math independent of `dart:ui` and existing brush APIs. Copies coincident on
/// an axis are deduplicated by center; the unchanged source always wins.
final class SymmetryMirrorHook<T> {
  SymmetryMirrorHook({
    required this.configuration,
    required this.xOf,
    required this.yOf,
    required this.reflectedCopy,
    this.epsilon = 1e-9,
  }) {
    _checkEpsilon(epsilon);
  }

  final SymmetryConfiguration configuration;
  final double Function(T value) xOf;
  final double Function(T value) yOf;
  final T Function(T value, SymmetryReflection reflection) reflectedCopy;
  final double epsilon;

  /// Returns the source and every distinct mirror in journal-stable order.
  List<T> expand(T source) {
    final sourceX = xOf(source);
    final sourceY = yOf(source);
    if (!sourceX.isFinite || !sourceY.isFinite) {
      throw ArgumentError.value(
        (sourceX, sourceY),
        'source coordinate',
        'must be finite',
      );
    }
    final result = <T>[];
    final centers = <SymmetryPoint>[];
    for (final reflection in configuration.reflections) {
      final center = reflection.applyToPoint(SymmetryPoint(sourceX, sourceY));
      if (_containsNear(centers, center, epsilon)) {
        continue;
      }
      centers.add(center);
      result.add(
        reflection.isIdentity ? source : reflectedCopy(source, reflection),
      );
    }
    return List<T>.unmodifiable(result);
  }

  /// Expands a stream while preserving each source value's copy grouping.
  List<T> expandAll(Iterable<T> source) =>
      List<T>.unmodifiable(<T>[for (final value in source) ...expand(value)]);
}

bool _containsNear(
  List<SymmetryPoint> points,
  SymmetryPoint candidate,
  double epsilon,
) {
  for (final point in points) {
    if ((point.x - candidate.x).abs() <= epsilon &&
        (point.y - candidate.y).abs() <= epsilon) {
      return true;
    }
  }
  return false;
}

double _normalizeRadians(double radians) {
  var normalized = (radians + math.pi) % (2 * math.pi);
  if (normalized < 0) {
    normalized += 2 * math.pi;
  }
  return normalized - math.pi;
}

void _checkEpsilon(double epsilon) {
  if (!epsilon.isFinite || epsilon < 0) {
    throw ArgumentError.value(
      epsilon,
      'epsilon',
      'must be finite and non-negative',
    );
  }
}
