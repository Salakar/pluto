import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import '../document/tile_store.dart';
import 'brush_presets.dart';

const int _uint32Mask = 0xffffffff;
const double _minimumStampSpacing = 0.05;
const double _minimumTaperScale = 0.04;

/// Number of intervals in Ink's stable e-ink gray lattice.
const int grayLatticeMaxLevel = 30;

/// Exact settle-form lattice used by shade and lattice-twin rendering.
const List<int> inkShadeLatticeLevels = <int>[0, 6, 10, 14, 18, 22, 26, 30];

/// Deterministic admission threshold for an absolute (never alpha-strength) shade.
const int absoluteShadeCoverageCutoff = 128;

/// One fitted document-space point consumed by [BrushEngine].
final class BrushPoint {
  /// Creates a pressure/tilt sample at [point].
  ///
  /// [tilt] is normalized from zero for upright through one for maximum tilt.
  /// Timestamps are used only to derive deterministic document-pixel velocity.
  BrushPoint({
    required this.point,
    required this.pressure,
    required this.timestamp,
    this.tilt = 0,
  }) {
    if (!point.dx.isFinite || !point.dy.isFinite) {
      throw ArgumentError.value(point, 'point', 'must be finite');
    }
    if (!pressure.isFinite) {
      throw ArgumentError.value(pressure, 'pressure', 'must be finite');
    }
    if (!tilt.isFinite) {
      throw ArgumentError.value(tilt, 'tilt', 'must be finite');
    }
  }

  /// Fitted document-space position.
  final Offset point;

  /// Normalized stylus pressure. The engine constrains it to zero through one.
  final double pressure;

  /// Normalized stylus tilt magnitude.
  final double tilt;

  /// Monotonic input timestamp.
  final Duration timestamp;
}

/// A stable repository-owned xorshift32 generator.
///
/// Its integer operations and output conversion are deliberately specified
/// here rather than delegated to `dart:math.Random`, keeping stroke redo stable
/// across Dart SDK changes.
final class BrushRandom {
  /// Seeds a deterministic stream. A folded zero seed uses a fixed nonzero key.
  BrushRandom(int seed) : _state = _foldSeed(seed);

  int _state;

  /// Emits the next unsigned 32-bit value.
  int nextUint32() {
    var value = _state;
    value ^= (value << 13) & _uint32Mask;
    value ^= value >>> 17;
    value ^= (value << 5) & _uint32Mask;
    _state = value & _uint32Mask;
    return _state;
  }

  /// Emits a value in the half-open interval `[0, 1)`.
  double nextDouble() => nextUint32() / 0x100000000;

  /// Emits a value in the half-open interval `[-1, 1)`.
  double nextSignedUnit() => nextDouble() * 2 - 1;

  static int _foldSeed(int seed) {
    final folded = ((seed & _uint32Mask) ^ (seed >>> 32)) & _uint32Mask;
    return folded == 0 ? 0x6d2b79f5 : folded;
  }
}

/// Fully resolved grain parameters attached to one stamp.
final class ResolvedBrushGrain {
  /// Creates grain whose [depth] and origin have already been resolved.
  const ResolvedBrushGrain({
    required this.patternId,
    required this.scale,
    required this.movement,
    required this.depth,
    required this.seed,
    this.densityLevel = 1,
    this.angleRadians = 0,
  });

  /// Stable procedural or baked pattern identifier.
  final String patternId;

  /// Document pixels represented by one source-pattern pixel.
  final double scale;

  /// Whether sampling is document-fixed or stamp-relative.
  final GrainMovement movement;

  /// Coverage modulation depth from zero through one.
  final double depth;

  /// Per-stroke key used only for moving grain origins.
  final int seed;

  /// Pressure-selected pattern density, starting at one.
  final int densityLevel;

  /// Pattern rotation relative to document axes.
  final double angleRadians;

  /// Returns a coverage multiplier for [documentPoint].
  double coverageAt(Offset documentPoint, {required Offset stampCenter}) {
    final Offset origin;
    if (movement == GrainMovement.fixed) {
      origin = Offset.zero;
    } else {
      final xOffset = (seed & 0x3f).toDouble();
      final yOffset = ((seed >>> 6) & 0x3f).toDouble();
      origin = stampCenter - Offset(xOffset * scale, yOffset * scale);
    }
    final deltaX = (documentPoint.dx - origin.dx) / scale;
    final deltaY = (documentPoint.dy - origin.dy) / scale;
    final cosine = math.cos(angleRadians);
    final sine = math.sin(angleRadians);
    final x = deltaX * cosine + deltaY * sine;
    final y = -deltaX * sine + deltaY * cosine;
    final tooth = proceduralGrainValue(
      patternId,
      x,
      y,
      densityLevel: densityLevel,
    );
    return (1 - depth * (1 - tooth)).clamp(0.0, 1.0).toDouble();
  }
}

/// One target-independent nib impression emitted by [BrushEngine].
final class ResolvedBrushStamp {
  /// Creates a fully resolved stamp.
  ResolvedBrushStamp({
    required this.center,
    required this.diameterX,
    required this.diameterY,
    required this.angleRadians,
    required this.colorArgb,
    required this.flow,
    required this.blend,
    required this.grain,
    this.nibKind = NibKind.disc,
    this.textureMaskId,
    this.maxOverlapSteps = 0,
    this.minimumLumaLevel = 0,
  }) {
    if (!center.dx.isFinite || !center.dy.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    if (!diameterX.isFinite || diameterX <= 0) {
      throw ArgumentError.value(
        diameterX,
        'diameterX',
        'must be finite and positive',
      );
    }
    if (!diameterY.isFinite || diameterY <= 0) {
      throw ArgumentError.value(
        diameterY,
        'diameterY',
        'must be finite and positive',
      );
    }
    if (!angleRadians.isFinite) {
      throw ArgumentError.value(angleRadians, 'angleRadians', 'must be finite');
    }
    if (!flow.isFinite || flow < 0 || flow > 1) {
      throw RangeError.range(flow, 0, 1, 'flow');
    }
    if (maxOverlapSteps < 0) {
      throw RangeError.value(
        maxOverlapSteps,
        'maxOverlapSteps',
        'must not be negative',
      );
    }
    if (minimumLumaLevel < 0 || minimumLumaLevel > grayLatticeMaxLevel) {
      throw RangeError.range(
        minimumLumaLevel,
        0,
        grayLatticeMaxLevel,
        'minimumLumaLevel',
      );
    }
  }

  /// Document-space stamp center after lateral jitter.
  final Offset center;

  /// Resolved major-axis diameter in document pixels.
  final double diameterX;

  /// Resolved minor-axis diameter in document pixels.
  final double diameterY;

  /// Resolved nib angle in radians.
  final double angleRadians;

  /// Unpremultiplied source color in ARGB notation.
  final int colorArgb;

  /// Per-stamp coverage multiplier.
  final double flow;

  /// Brush-level composite requested by this stamp.
  final BrushBlend blend;

  /// Optional resolved grain modulation.
  final ResolvedBrushGrain? grain;

  /// Original nib family, retained for proof renderers and raster adapters.
  final NibKind nibKind;

  /// Original texture identifier when [nibKind] is [NibKind.texture].
  final String? textureMaskId;

  /// Maximum accepted per-stroke overlap steps, or zero when uncapped.
  final int maxOverlapSteps;

  /// Output luma floor on the /30 lattice.
  final int minimumLumaLevel;

  /// Conservative anti-aliased document-space bounds.
  Rect get bounds {
    final rx = diameterX / 2;
    final ry = diameterY / 2;
    final cosine = math.cos(angleRadians);
    final sine = math.sin(angleRadians);
    final double extentX;
    final double extentY;
    if (nibKind == NibKind.chisel) {
      extentX = rx * cosine.abs() + ry * sine.abs();
      extentY = rx * sine.abs() + ry * cosine.abs();
    } else {
      extentX = math.sqrt(rx * rx * cosine * cosine + ry * ry * sine * sine);
      extentY = math.sqrt(rx * rx * sine * sine + ry * ry * cosine * cosine);
    }
    return Rect.fromCenter(
      center: center,
      width: (extentX + 0.5) * 2,
      height: (extentY + 0.5) * 2,
    );
  }
}

/// Minimal raster seam implemented by a StrokeBuffer adapter.
abstract interface class BrushStampTarget {
  /// Applies [stamp] and returns the document-space damage it changed.
  Rect stamp(ResolvedBrushStamp stamp);
}

/// Pure target that records resolved stamps for math tests and proof sheets.
final class RecordingBrushStampTarget implements BrushStampTarget {
  final List<ResolvedBrushStamp> _stamps = <ResolvedBrushStamp>[];

  /// Immutable snapshot of stamps received so far.
  List<ResolvedBrushStamp> get stamps =>
      List<ResolvedBrushStamp>.unmodifiable(_stamps);

  @override
  Rect stamp(ResolvedBrushStamp stamp) {
    _stamps.add(stamp);
    return stamp.bounds;
  }

  /// Removes all recorded stamps.
  void clear() => _stamps.clear();
}

/// Stateful deterministic stamp-along-path renderer for one stroke.
///
/// Create one engine per stroke. Calls to [stampAlong] may contain any number
/// of newly fitted points; spacing residual and the previous point survive
/// chunk boundaries. [finalize] must be called once on pen-up so the held tail
/// can be emitted with its final taper.
final class BrushEngine {
  /// Creates a renderer for [spec] and [target].
  BrushEngine({
    required this.spec,
    required this.target,
    required this.seed,
    required int colorArgb,
    double? size,
  }) : colorArgb = resolveBrushColor(spec, colorArgb),
       size = _selectSize(spec, size),
       _random = BrushRandom(seed);

  /// Immutable brush tuning data.
  final BrushSpec spec;

  /// Raster or recording destination.
  final BrushStampTarget target;

  /// Seed persisted in the stroke recipe.
  final int seed;

  /// Stroke color in ARGB notation.
  final int colorArgb;

  /// Selected base diameter constrained to the preset's legal range.
  final double size;

  final BrushRandom _random;
  final ListQueue<_PendingStamp> _tail = ListQueue<_PendingStamp>();
  final Map<(int, int), List<_ParticleSite>> _stippleGrid =
      <(int, int), List<_ParticleSite>>{};
  BrushPoint? _previous;
  var _pathDistance = 0.0;
  var _distanceUntilNextStamp = 0.0;
  var _lastCandidateDistance = -1.0;
  var _lastVelocity = 0.0;
  Offset _lastDirection = const Offset(1, 0);
  var _emittedStampCount = 0;
  var _finalized = false;

  /// Total fitted path distance consumed so far.
  double get pathDistance => _pathDistance;

  /// Remaining document distance before the next regularly spaced stamp.
  double get spacingResidual => _distanceUntilNextStamp;

  /// Number of stamps delivered to [target], excluding seeded skipped flecks.
  int get emittedStampCount => _emittedStampCount;

  /// Whether [finalize] has sealed this engine.
  bool get isFinalized => _finalized;

  /// Incrementally places impressions along [points].
  ///
  /// The first point starts the stroke. Later points are linearly interpolated
  /// at the brush's pressure-sensitive spacing. Returned damage covers only
  /// stamps emitted during this call; a configured tail taper intentionally
  /// retains its newest impressions until more path or [finalize] arrives.
  Rect stampAlong(Iterable<BrushPoint> points) {
    _checkActive();
    Rect? damage;
    for (final point in points) {
      final previous = _previous;
      if (previous == null) {
        _previous = point;
        final pending = _createPending(
          point: point,
          pathDistance: 0,
          velocity: 0,
          direction: const Offset(1, 0),
        );
        _tail.addLast(pending);
        _distanceUntilNextStamp = _spacingFor(pending);
        damage = _includeDamage(damage, _flushSettledTail());
        continue;
      }

      final delta = point.point - previous.point;
      final distance = delta.distance;
      if (distance == 0) {
        _previous = point;
        continue;
      }
      final direction = delta / distance;
      final elapsedMicros =
          point.timestamp.inMicroseconds - previous.timestamp.inMicroseconds;
      final velocity = elapsedMicros <= 0
          ? 0.0
          : distance * Duration.microsecondsPerSecond / elapsedMicros;
      final segmentStart = _pathDistance;
      var consumed = 0.0;
      var remaining = distance;
      while (_distanceUntilNextStamp <= remaining + 1e-9) {
        consumed += _distanceUntilNextStamp;
        remaining = math.max(0.0, distance - consumed);
        final t = (consumed / distance).clamp(0.0, 1.0).toDouble();
        final interpolated = _interpolate(previous, point, t);
        final pending = _createPending(
          point: interpolated,
          pathDistance: segmentStart + consumed,
          velocity: velocity,
          direction: direction,
        );
        _tail.addLast(pending);
        _distanceUntilNextStamp = _spacingFor(pending);
        _pathDistance = segmentStart + consumed;
        damage = _includeDamage(damage, _flushSettledTail());
      }
      _distanceUntilNextStamp = math.max(
        0.0,
        _distanceUntilNextStamp - remaining,
      );
      _pathDistance = segmentStart + distance;
      _previous = point;
      damage = _includeDamage(damage, _flushSettledTail());
    }
    return damage ?? Rect.zero;
  }

  /// Emits the retained tail with its final taper and seals this engine.
  Rect finalize() {
    _checkActive();
    final previous = _previous;
    if (previous != null && _pathDistance - _lastCandidateDistance > 1e-9) {
      _tail.addLast(
        _createPending(
          point: previous,
          pathDistance: _pathDistance,
          velocity: _lastVelocity,
          direction: _lastDirection,
        ),
      );
    }
    _finalized = true;
    Rect? damage;
    while (_tail.isNotEmpty) {
      final pending = _tail.removeFirst();
      damage = _includeDamage(
        damage,
        _emit(pending, finalPathLength: _pathDistance),
      );
    }
    return damage ?? Rect.zero;
  }

  Rect _flushSettledTail() {
    final tailLength = spec.taper.tailLength * size;
    if (tailLength == 0) {
      Rect? damage;
      while (_tail.isNotEmpty) {
        damage = _includeDamage(damage, _emit(_tail.removeFirst()));
      }
      return damage ?? Rect.zero;
    }
    final settledThrough = _pathDistance - tailLength;
    Rect? damage;
    while (_tail.isNotEmpty &&
        _tail.first.pathDistance <= settledThrough + 1e-9) {
      damage = _includeDamage(damage, _emit(_tail.removeFirst()));
    }
    return damage ?? Rect.zero;
  }

  _PendingStamp _createPending({
    required BrushPoint point,
    required double pathDistance,
    required double velocity,
    required Offset direction,
  }) {
    final normalizedVelocity = normalizeBrushVelocity(velocity, size: size);
    final lateralUnit = spec.jitter == 0 ? 0.0 : _random.nextSignedUnit();
    final fleckUnit = spec.id == 'ballpoint' ? _random.nextDouble() : 1.0;
    _lastCandidateDistance = pathDistance;
    _lastVelocity = velocity;
    _lastDirection = direction;
    return _PendingStamp(
      point: point,
      pathDistance: pathDistance,
      normalizedVelocity: normalizedVelocity,
      direction: direction,
      lateralUnit: lateralUnit,
      skipFleck:
          spec.id == 'ballpoint' &&
          isBallpointSkipFleck(
            normalizedVelocity: normalizedVelocity,
            randomUnit: fleckUnit,
          ),
    );
  }

  double _spacingFor(_PendingStamp pending) {
    final diameter = _baseDiameter(pending);
    return math.max(_minimumStampSpacing, diameter * spec.spacing);
  }

  Rect _emit(_PendingStamp pending, {double? finalPathLength}) {
    if (pending.skipFleck) {
      return Rect.zero;
    }
    var taperScale = finalPathLength == 0
        ? 1.0
        : _headTaper(pending.pathDistance);
    if (finalPathLength != null) {
      taperScale = math.min(taperScale, _tailTaper(pending, finalPathLength));
    }
    var diameter = _baseDiameter(pending) * taperScale;
    var flow = spec.pressureFlow.map(pending.point.pressure) * taperScale;
    if (spec.velocityThins) {
      final velocityFactor = 1 - 0.08 * pending.normalizedVelocity;
      diameter *= velocityFactor;
      flow *= velocityFactor;
    }
    flow = quantizeBrushFlow(flow, spec.quantizeLevels);
    if (flow <= 0) {
      return Rect.zero;
    }

    final tilt = pending.point.tilt.clamp(0.0, 1.0).toDouble();
    final tiltMap = spec.tilt;
    final squash = tiltMap?.squash(tilt) ?? 1;
    final perpendicular = Offset(-pending.direction.dy, pending.direction.dx);
    final center =
        pending.point.point +
        perpendicular * (pending.lateralUnit * spec.jitter * diameter);
    if (spec.kind == BrushClass.particle) {
      return _emitParticles(
        pending: pending,
        center: center,
        footprintDiameter: diameter,
        density: flow,
      );
    }

    var diameterX = diameter;
    var diameterY = diameter;
    switch (spec.nib.kind) {
      case NibKind.disc:
        diameterX *= squash;
      case NibKind.ellipse:
        diameterY *= spec.nib.ratio;
        diameterX *= squash;
      case NibKind.chisel:
        if (spec.id == 'calligraphy') {
          final width = calligraphyWidthMultiplier(
            pending.direction,
            nibAngleDegrees: spec.nib.angleDegrees,
          );
          diameterX *= width;
          diameterY *= 0.15;
        } else {
          diameterY *= 0.25;
        }
        diameterX *= squash;
      case NibKind.texture:
        diameterX *= squash;
    }
    final grainSpec = spec.grain;
    final ResolvedBrushGrain? grain;
    if (grainSpec == null) {
      grain = null;
    } else {
      var depth =
          grainSpec.depth +
          grainSpec.depthPressure * pending.point.pressure.clamp(0.0, 1.0);
      if (tiltMap != null) {
        depth *= tiltMap.grainDepth(tilt);
      }
      grain = ResolvedBrushGrain(
        patternId: grainSpec.patternId,
        scale: grainSpec.scale,
        movement: grainSpec.movement,
        depth: depth.clamp(0.0, 1.0).toDouble(),
        seed: seed,
        densityLevel: resolvePatternDensityLevel(
          pending.point.pressure,
          steps: spec.patternDensitySteps,
        ),
        angleRadians: spec.id == 'hatcher'
            ? math.atan2(pending.direction.dy, pending.direction.dx)
            : 0,
      );
    }

    final stamp = ResolvedBrushStamp(
      center: center,
      diameterX: math.max(diameterX, _minimumStampSpacing),
      diameterY: math.max(diameterY, _minimumStampSpacing),
      angleRadians: spec.nib.angleDegrees * math.pi / 180,
      colorArgb: colorArgb,
      flow: flow,
      blend: spec.blend.kind,
      grain: grain,
      nibKind: spec.nib.kind,
      textureMaskId: spec.nib.maskId,
      maxOverlapSteps: spec.maxOverlapSteps,
      minimumLumaLevel: spec.minimumLumaLevel,
    );
    _emittedStampCount += 1;
    return target.stamp(stamp);
  }

  Rect _emitParticles({
    required _PendingStamp pending,
    required Offset center,
    required double footprintDiameter,
    required double density,
  }) {
    final count = resolvedParticleCount(
      spec,
      selectedSize: size,
      density: density,
    );
    if (count == 0) {
      return Rect.zero;
    }
    final pressure = pending.point.pressure.clamp(0.0, 1.0).toDouble();
    final dotDiameter = spec.id == 'stipple'
        ? spec.nib.particleSizeMin +
              (spec.nib.particleSizeMax - spec.nib.particleSizeMin) * pressure
        : 0.0;
    Rect? damage;
    for (var particle = 0; particle < count; particle += 1) {
      final diameter = spec.id == 'stipple'
          ? dotDiameter
          : spec.nib.particleSizeMin +
                (spec.nib.particleSizeMax - spec.nib.particleSizeMin) *
                    _random.nextDouble();
      final Offset? particleCenter = spec.id == 'stipple'
          ? _nextPoissonCenter(
              center,
              footprintDiameter: footprintDiameter,
              candidateDiameter: diameter,
            )
          : center + _nextGaussianOffset(footprintDiameter);
      if (particleCenter == null) {
        continue;
      }
      if (spec.id == 'stipple') {
        _rememberStipple(particleCenter, diameter);
      }
      final stamp = ResolvedBrushStamp(
        center: particleCenter,
        diameterX: diameter,
        diameterY: diameter,
        angleRadians: 0,
        colorArgb: colorArgb,
        flow: 1,
        blend: spec.blend.kind,
        grain: null,
        nibKind: NibKind.disc,
        textureMaskId: spec.nib.maskId,
        maxOverlapSteps: spec.maxOverlapSteps,
        minimumLumaLevel: spec.minimumLumaLevel,
      );
      _emittedStampCount += 1;
      damage = _includeDamage(damage, target.stamp(stamp));
    }
    return damage ?? Rect.zero;
  }

  Offset _nextGaussianOffset(double footprintDiameter) {
    final u1 = math.max(_random.nextDouble(), 1 / 0x100000000);
    final u2 = _random.nextDouble();
    final gaussianRadius = math.sqrt(-2 * math.log(u1));
    final sigma = footprintDiameter * spec.nib.particleSpread / 3;
    final radius = math.min(gaussianRadius, 3.0) * sigma;
    final angle = 2 * math.pi * u2;
    return Offset(math.cos(angle) * radius, math.sin(angle) * radius);
  }

  Offset? _nextPoissonCenter(
    Offset center, {
    required double footprintDiameter,
    required double candidateDiameter,
  }) {
    final radius = footprintDiameter * spec.nib.particleSpread;
    for (var attempt = 0; attempt < 24; attempt += 1) {
      final distance = math.sqrt(_random.nextDouble()) * radius;
      final angle = _random.nextDouble() * 2 * math.pi;
      final candidate = Offset(
        center.dx + math.cos(angle) * distance,
        center.dy + math.sin(angle) * distance,
      );
      if (_canPlaceStipple(candidate, candidateDiameter)) {
        return candidate;
      }
    }
    return null;
  }

  bool _canPlaceStipple(Offset candidate, double candidateDiameter) {
    final cell = _stippleCell(candidate);
    for (var deltaY = -2; deltaY <= 2; deltaY += 1) {
      for (var deltaX = -2; deltaX <= 2; deltaX += 1) {
        final neighbors = _stippleGrid[(cell.$1 + deltaX, cell.$2 + deltaY)];
        if (neighbors == null) {
          continue;
        }
        for (final other in neighbors) {
          final minimumDistance =
              (candidateDiameter + other.diameter) * 0.5 * 0.78;
          if ((candidate - other.center).distance < minimumDistance) {
            return false;
          }
        }
      }
    }
    return true;
  }

  void _rememberStipple(Offset center, double diameter) {
    final cell = _stippleCell(center);
    _stippleGrid
        .putIfAbsent(cell, () => <_ParticleSite>[])
        .add(_ParticleSite(center: center, diameter: diameter));
  }

  (int, int) _stippleCell(Offset center) {
    final cellSize = spec.nib.particleSizeMax * 0.78;
    return ((center.dx / cellSize).floor(), (center.dy / cellSize).floor());
  }

  double _baseDiameter(_PendingStamp pending) {
    final pressure = spec.pressureSize.map(pending.point.pressure);
    final tilt = pending.point.tilt.clamp(0.0, 1.0).toDouble();
    return size * pressure * (spec.tilt?.sizeMultiplier(tilt) ?? 1);
  }

  double _headTaper(double distance) {
    final length = spec.taper.headLength * size;
    if (length == 0) {
      return 1;
    }
    return (distance / length).clamp(_minimumTaperScale, 1.0).toDouble();
  }

  double _tailTaper(_PendingStamp pending, double finalPathLength) {
    final length = spec.taper.tailLength * size;
    if (length == 0 || finalPathLength == 0) {
      return 1;
    }
    var taper = ((finalPathLength - pending.pathDistance) / length)
        .clamp(_minimumTaperScale, 1.0)
        .toDouble();
    if (taper < 1 && spec.taper.velocityTail > 0) {
      taper *=
          1 -
          spec.taper.velocityTail * pending.normalizedVelocity * (1 - taper);
    }
    return taper.clamp(_minimumTaperScale, 1.0).toDouble();
  }

  static BrushPoint _interpolate(BrushPoint from, BrushPoint to, double t) {
    final micros =
        from.timestamp.inMicroseconds +
        ((to.timestamp.inMicroseconds - from.timestamp.inMicroseconds) * t)
            .round();
    return BrushPoint(
      point: Offset.lerp(from.point, to.point, t)!,
      pressure: from.pressure + (to.pressure - from.pressure) * t,
      tilt: from.tilt + (to.tilt - from.tilt) * t,
      timestamp: Duration(microseconds: micros),
    );
  }

  void _checkActive() {
    if (_finalized) {
      throw StateError('A finalized BrushEngine cannot accept more points.');
    }
  }

  static double _selectSize(BrushSpec spec, double? requested) {
    final selected = requested ?? spec.sizeDefault;
    if (!selected.isFinite || selected <= 0) {
      throw ArgumentError.value(
        selected,
        'size',
        'must be finite and positive',
      );
    }
    return selected.clamp(spec.sizeMin, spec.sizeMax).toDouble();
  }
}

final class _PendingStamp {
  const _PendingStamp({
    required this.point,
    required this.pathDistance,
    required this.normalizedVelocity,
    required this.direction,
    required this.lateralUnit,
    required this.skipFleck,
  });

  final BrushPoint point;
  final double pathDistance;
  final double normalizedVelocity;
  final Offset direction;
  final double lateralUnit;
  final bool skipFleck;
}

final class _ParticleSite {
  const _ParticleSite({required this.center, required this.diameter});

  final Offset center;
  final double diameter;
}

/// Normalizes document velocity against sixty selected diameters per second.
double normalizeBrushVelocity(double velocity, {required double size}) {
  if (!velocity.isFinite || velocity < 0) {
    throw ArgumentError.value(
      velocity,
      'velocity',
      'must be finite and non-negative',
    );
  }
  if (!size.isFinite || size <= 0) {
    throw ArgumentError.value(size, 'size', 'must be finite and positive');
  }
  if (velocity == 0) {
    return 0;
  }
  return velocity / (velocity + size * 60);
}

/// Whether a seeded ballpoint impression becomes a rare skip fleck.
bool isBallpointSkipFleck({
  required double normalizedVelocity,
  required double randomUnit,
}) {
  if (!normalizedVelocity.isFinite ||
      normalizedVelocity < 0 ||
      normalizedVelocity > 1) {
    throw RangeError.range(normalizedVelocity, 0, 1, 'normalizedVelocity');
  }
  if (!randomUnit.isFinite || randomUnit < 0 || randomUnit >= 1) {
    throw RangeError.range(randomUnit, 0, 1, 'randomUnit');
  }
  return randomUnit < 0.03 * normalizedVelocity;
}

/// Snaps continuous [flow] to [levels] equal coverage intervals.
double quantizeBrushFlow(double flow, int levels) {
  if (!flow.isFinite) {
    throw ArgumentError.value(flow, 'flow', 'must be finite');
  }
  if (levels < 0) {
    throw RangeError.value(levels, 'levels', 'must not be negative');
  }
  final normalized = flow.clamp(0.0, 1.0).toDouble();
  if (levels == 0) {
    return normalized;
  }
  return (normalized * levels).round() / levels;
}

/// Resolves fixed-lattice and highlighter color constraints for [spec].
int resolveBrushColor(BrushSpec spec, int requestedArgb) {
  final fixedLevel = spec.fixedLatticeLevel;
  if (fixedLevel != null) {
    final channel = latticeLevelToSrgbChannel(fixedLevel);
    return 0xff000000 | channel << 16 | channel << 8 | channel;
  }
  if (spec.id != 'highlighter') {
    return requestedArgb;
  }
  final requestedRgb = requestedArgb & 0x00ffffff;
  for (final color in highlighterColorsArgb) {
    if ((color & 0x00ffffff) == requestedRgb) {
      return color;
    }
  }
  return defaultHighlighterColorArgb;
}

/// Converts a /30 lattice level to its gamma-expanded sRGB gray channel.
int latticeLevelToSrgbChannel(int level) {
  if (level < 0 || level > grayLatticeMaxLevel) {
    throw RangeError.range(level, 0, grayLatticeMaxLevel, 'level');
  }
  if (level == 0) {
    return 0;
  }
  return (math.pow(level / grayLatticeMaxLevel, 1 / 1.8) * 255).round().clamp(
    0,
    255,
  );
}

/// Quantizes unpremultiplied sRGB [argb] luma with the binding `luma^1.8` law.
int argbLumaLatticeLevel(int argb) {
  final red = (argb >>> 16) & 0xff;
  final green = (argb >>> 8) & 0xff;
  final blue = argb & 0xff;
  final luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;
  return (math.pow(luma, 1.8) * grayLatticeMaxLevel).round().clamp(
    0,
    grayLatticeMaxLevel,
  );
}

/// Snaps a numeric /30 luma value to the nearest settle-form lattice member.
int nearestInkShadeLatticeLevel(int level) {
  if (level < 0 || level > grayLatticeMaxLevel) {
    throw RangeError.range(level, 0, grayLatticeMaxLevel, 'level');
  }
  var nearest = inkShadeLatticeLevels.first;
  var distance = (level - nearest).abs();
  for (final candidate in inkShadeLatticeLevels.skip(1)) {
    final candidateDistance = (level - candidate).abs();
    if (candidateDistance < distance) {
      nearest = candidate;
      distance = candidateDistance;
    }
  }
  return nearest;
}

/// Moves one adjacent settle-form lattice member in [direction].
int stepInkShadeLattice(int level, ShadeDirection direction) {
  final index = inkShadeLatticeLevels.indexOf(level);
  if (index < 0) {
    throw ArgumentError.value(
      level,
      'level',
      'must be a member of the Ink shade lattice',
    );
  }
  final nextIndex = direction == ShadeDirection.darker
      ? math.max(0, index - 1)
      : math.min(inkShadeLatticeLevels.length - 1, index + 1);
  return inkShadeLatticeLevels[nextIndex];
}

/// Enforces [minimumLevel] while retaining as much source hue as possible.
int clampArgbToLumaFloor(int argb, int minimumLevel) {
  if (minimumLevel < 0 || minimumLevel > grayLatticeMaxLevel) {
    throw RangeError.range(
      minimumLevel,
      0,
      grayLatticeMaxLevel,
      'minimumLevel',
    );
  }
  if (argbLumaLatticeLevel(argb) >= minimumLevel) {
    return argb;
  }
  final floorChannel = latticeLevelToSrgbChannel(minimumLevel);
  final alpha = argb & 0xff000000;
  final red = math.max((argb >>> 16) & 0xff, floorChannel);
  final green = math.max((argb >>> 8) & 0xff, floorChannel);
  final blue = math.max(argb & 0xff, floorChannel);
  return alpha | red << 16 | green << 8 | blue;
}

/// Direction-dependent chisel width from the binding's sine law.
double calligraphyWidthMultiplier(
  Offset strokeDirection, {
  required double nibAngleDegrees,
}) {
  if (!strokeDirection.dx.isFinite || !strokeDirection.dy.isFinite) {
    throw ArgumentError.value(
      strokeDirection,
      'strokeDirection',
      'must be finite',
    );
  }
  if (!nibAngleDegrees.isFinite) {
    throw ArgumentError.value(
      nibAngleDegrees,
      'nibAngleDegrees',
      'must be finite',
    );
  }
  if (strokeDirection == Offset.zero) {
    return 0.15;
  }
  final direction = math.atan2(strokeDirection.dy, strokeDirection.dx);
  final nibAngle = nibAngleDegrees * math.pi / 180;
  return math.max(0.15, math.sin(direction - nibAngle).abs());
}

/// Particle count scaled by selected footprint area and pressure density.
int resolvedParticleCount(
  BrushSpec spec, {
  required double selectedSize,
  required double density,
}) {
  if (spec.kind != BrushClass.particle || spec.nib.particleCount == 0) {
    return 0;
  }
  if (!selectedSize.isFinite || selectedSize <= 0) {
    throw ArgumentError.value(
      selectedSize,
      'selectedSize',
      'must be finite and positive',
    );
  }
  if (!density.isFinite) {
    throw ArgumentError.value(density, 'density', 'must be finite');
  }
  final normalizedDensity = density.clamp(0.0, 1.0).toDouble();
  if (normalizedDensity == 0) {
    return 0;
  }
  final areaScale = math.pow(selectedSize / spec.sizeDefault, 2).toDouble();
  return math.max(
    1,
    (spec.nib.particleCount * areaScale * normalizedDensity).round(),
  );
}

/// Maps normalized pressure to one of [steps] pattern densities.
int resolvePatternDensityLevel(double pressure, {required int steps}) {
  if (!pressure.isFinite) {
    throw ArgumentError.value(pressure, 'pressure', 'must be finite');
  }
  if (steps < 0) {
    throw RangeError.value(steps, 'steps', 'must not be negative');
  }
  if (steps <= 1) {
    return 1;
  }
  final normalized = pressure.clamp(0.0, 1.0).toDouble();
  return 1 + (normalized * (steps - 1)).round();
}

/// Samples a deterministic tileable 64 by 64 procedural grain.
double proceduralGrainValue(
  String patternId,
  double x,
  double y, {
  int densityLevel = 1,
}) {
  if (patternId.isEmpty) {
    throw ArgumentError.value(patternId, 'patternId', 'must not be empty');
  }
  if (!x.isFinite || !y.isFinite) {
    throw ArgumentError('Grain coordinates must be finite.');
  }
  if (densityLevel < 1) {
    throw RangeError.value(densityLevel, 'densityLevel', 'must be positive');
  }
  final wrappedX = x.floor() % 64;
  final wrappedY = y.floor() % 64;
  switch (patternId) {
    case 'charcoalStrata':
      final noise = _hashedPatternValue(patternId, wrappedX, wrappedY);
      final band = (wrappedY + (wrappedX ~/ 7) * 3) % 16;
      final ridge = 1 - ((band - 7.5).abs() / 7.5);
      if (noise < 0.16) {
        return 0;
      }
      return (ridge * 0.72 + noise * 0.38).clamp(0.0, 1.0).toDouble();
    case 'hatch45':
      return _hatchValue(wrappedX, wrappedY, densityLevel: densityLevel);
    case 'crosshatch':
      return math.max(
        _hatchValue(wrappedX, wrappedY, densityLevel: densityLevel),
        _hatchValue(wrappedX, -wrappedY, densityLevel: densityLevel),
      );
    case 'dotScreen60lpi':
      final level = densityLevel.clamp(1, 4);
      final spacing = <int>[12, 10, 8, 6][level - 1];
      final radius = <double>[1.2, 1.5, 1.8, 2.1][level - 1];
      final localX = (wrappedX % spacing) - spacing / 2;
      final localY = (wrappedY % spacing) - spacing / 2;
      return math.sqrt(localX * localX + localY * localY) <= radius ? 1 : 0;
    case 'paperTooth':
      return _hashedPatternValue(patternId, wrappedX, wrappedY);
    default:
      throw ArgumentError.value(
        patternId,
        'patternId',
        'is not a baked Ink brush pattern',
      );
  }
}

double _hatchValue(int x, int y, {required int densityLevel}) {
  final level = densityLevel.clamp(1, 4);
  final spacing = <int>[16, 12, 8, 6][level - 1];
  final phase = (x - y) % spacing;
  return phase <= (level >= 3 ? 1 : 0) ? 1 : 0;
}

/// Samples only the perpendicular family added by a crosshatch second pass.
double crosshatchSecondPassValue(
  double x,
  double y, {
  int densityLevel = 1,
  double angleRadians = 0,
}) {
  if (!x.isFinite || !y.isFinite || !angleRadians.isFinite) {
    throw ArgumentError('Crosshatch coordinates and angle must be finite.');
  }
  if (densityLevel < 1) {
    throw RangeError.value(densityLevel, 'densityLevel', 'must be positive');
  }
  final cosine = math.cos(angleRadians);
  final sine = math.sin(angleRadians);
  final rotatedX = (x * cosine + y * sine).floor() % 64;
  final rotatedY = (-x * sine + y * cosine).floor() % 64;
  return _hatchValue(rotatedX, -rotatedY, densityLevel: densityLevel);
}

double _hashedPatternValue(String patternId, int wrappedX, int wrappedY) {
  var patternKey = 0x811c9dc5;
  for (final codeUnit in patternId.codeUnits) {
    patternKey ^= codeUnit;
    patternKey = (patternKey * 0x01000193) & _uint32Mask;
  }
  var value =
      patternKey ^
      ((wrappedX * 0x1f123bb5) & _uint32Mask) ^
      ((wrappedY * 0x05491333) & _uint32Mask);
  value ^= value >>> 16;
  value = (value * 0x7feb352d) & _uint32Mask;
  value ^= value >>> 15;
  value = (value * 0x846ca68b) & _uint32Mask;
  value ^= value >>> 16;
  return (value & 0xffff) / 0xffff;
}

/// Pure result of admitting one coverage contribution into a capped stroke.
final class CappedCoverageDelta {
  /// Creates an immutable coverage transition.
  const CappedCoverageDelta({
    required this.accepted,
    required this.accumulated,
  });

  /// Portion of the incoming contribution that may be composited.
  final double accepted;

  /// Total accumulated coverage steps after accepting this contribution.
  final double accumulated;
}

/// Caps [incoming] coverage against [maximumSteps] without hidden state.
CappedCoverageDelta capStrokeCoverage({
  required double accumulated,
  required double incoming,
  required int maximumSteps,
}) {
  if (!accumulated.isFinite || accumulated < 0) {
    throw ArgumentError.value(
      accumulated,
      'accumulated',
      'must be finite and non-negative',
    );
  }
  if (!incoming.isFinite || incoming < 0 || incoming > 1) {
    throw RangeError.range(incoming, 0, 1, 'incoming');
  }
  if (maximumSteps <= 0) {
    throw RangeError.value(maximumSteps, 'maximumSteps', 'must be positive');
  }
  final remaining = math.max(0.0, maximumSteps - accumulated);
  final accepted = math.min(incoming, remaining);
  return CappedCoverageDelta(
    accepted: accepted,
    accumulated: accumulated + accepted,
  );
}

/// Per-stroke raster mask built on the pure [capStrokeCoverage] transition.
final class StrokeCoverageMask {
  /// Allocates an empty document-aligned mask.
  StrokeCoverageMask({
    required this.width,
    required this.height,
    required this.maximumSteps,
    this.originX = 0,
    this.originY = 0,
  }) : _coverage = Float64List(width * height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Coverage mask dimensions must be positive.');
    }
    if (maximumSteps <= 0) {
      throw RangeError.value(maximumSteps, 'maximumSteps', 'must be positive');
    }
  }

  /// Allocates the cap required by [brush].
  factory StrokeCoverageMask.forBrush(
    BrushSpec brush, {
    required int width,
    required int height,
    int originX = 0,
    int originY = 0,
  }) {
    if (brush.maxOverlapSteps <= 0) {
      throw ArgumentError.value(
        brush.id,
        'brush',
        'does not define an overlap cap',
      );
    }
    return StrokeCoverageMask(
      width: width,
      height: height,
      maximumSteps: brush.maxOverlapSteps,
      originX: originX,
      originY: originY,
    );
  }

  /// Mask width in pixels.
  final int width;

  /// Mask height in pixels.
  final int height;

  /// Maximum accumulated coverage at each pixel.
  final int maximumSteps;

  /// Left document coordinate.
  final int originX;

  /// Top document coordinate.
  final int originY;

  final Float64List _coverage;

  /// Admits coverage at a document pixel and returns only the new contribution.
  double takeCoverage(int documentX, int documentY, double incoming) {
    final index = _indexOf(documentX, documentY);
    if (index == null) {
      return 0;
    }
    final transition = capStrokeCoverage(
      accumulated: _coverage[index],
      incoming: incoming,
      maximumSteps: maximumSteps,
    );
    _coverage[index] = transition.accumulated;
    return transition.accepted;
  }

  /// Accumulated coverage at a document pixel, or zero outside the mask.
  double coverageAt(int documentX, int documentY) {
    final index = _indexOf(documentX, documentY);
    return index == null ? 0 : _coverage[index];
  }

  int? _indexOf(int documentX, int documentY) {
    final localX = documentX - originX;
    final localY = documentY - originY;
    if (localX < 0 || localX >= width || localY < 0 || localY >= height) {
      return null;
    }
    return localY * width + localX;
  }
}

/// Applies one capped marker/highlighter contribution at a document pixel.
int compositeCappedOverlapPixel({
  required BrushSpec brush,
  required StrokeCoverageMask coverageMask,
  required int documentX,
  required int documentY,
  required int destinationArgb,
  required int requestedSourceArgb,
  required double coverage,
}) {
  if (brush.maxOverlapSteps <= 0) {
    throw ArgumentError.value(
      brush.id,
      'brush',
      'does not define an overlap cap',
    );
  }
  if (coverageMask.maximumSteps != brush.maxOverlapSteps) {
    throw ArgumentError('Coverage mask cap does not match the brush preset.');
  }
  final accepted = coverageMask.takeCoverage(documentX, documentY, coverage);
  if (accepted == 0) {
    return destinationArgb;
  }
  final sourceArgb = resolveBrushColor(brush, requestedSourceArgb);
  final result = _compositeArgb(
    destinationArgb: destinationArgb,
    sourceArgb: sourceArgb,
    coverage: accepted * brush.pressureFlow.map(1),
    blend: brush.blend.kind,
  );
  if (brush.minimumLumaLevel == 0) {
    return result;
  }
  if (argbLumaLatticeLevel(destinationArgb) < brush.minimumLumaLevel) {
    return destinationArgb;
  }
  return clampArgbToLumaFloor(result, brush.minimumLumaLevel);
}

int _compositeArgb({
  required int destinationArgb,
  required int sourceArgb,
  required double coverage,
  required BrushBlend blend,
}) {
  if (!coverage.isFinite || coverage < 0 || coverage > 1) {
    throw RangeError.range(coverage, 0, 1, 'coverage');
  }
  final destinationAlpha = ((destinationArgb >>> 24) & 0xff) / 255;
  final sourceAlpha = ((sourceArgb >>> 24) & 0xff) / 255 * coverage;
  final outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha);
  if (outputAlpha == 0) {
    return 0;
  }
  int channel(int shift) {
    final destination = (destinationArgb >>> shift) & 0xff;
    final source = (sourceArgb >>> shift) & 0xff;
    final blended = switch (blend) {
      BrushBlend.multiply => destination * source / 255,
      _ => source.toDouble(),
    };
    final premultiplied =
        blended * sourceAlpha +
        destination * destinationAlpha * (1 - sourceAlpha);
    return (premultiplied / outputAlpha).round().clamp(0, 255);
  }

  final alpha = (outputAlpha * 255).round().clamp(0, 255);
  return alpha << 24 | channel(16) << 16 | channel(8) << 8 | channel(0);
}

/// Immutable stroke-down snapshot quantized to Ink's /30 luma lattice.
final class ShadeSnapshot {
  ShadeSnapshot._({
    required this.originX,
    required this.originY,
    required this.width,
    required this.height,
    required Uint8List levels,
    required Uint8List alpha,
  }) : _levels = Uint8List.fromList(levels),
       _alpha = Uint8List.fromList(alpha);

  /// Copies already-quantized [levels] and optional per-pixel [alpha].
  factory ShadeSnapshot.fromLatticeLevels({
    required int width,
    required int height,
    required Uint8List levels,
    Uint8List? alpha,
    int originX = 0,
    int originY = 0,
  }) {
    _checkRasterLength(width, height, levels.lengthInBytes, 'levels');
    if (levels.any((int level) => !inkShadeLatticeLevels.contains(level))) {
      throw RangeError(
        'Shade levels must be members of $inkShadeLatticeLevels.',
      );
    }
    final resolvedAlpha =
        alpha ?? (Uint8List(width * height)..fillRange(0, width * height, 255));
    _checkRasterLength(width, height, resolvedAlpha.lengthInBytes, 'alpha');
    return ShadeSnapshot._(
      originX: originX,
      originY: originY,
      width: width,
      height: height,
      levels: levels,
      alpha: resolvedAlpha,
    );
  }

  /// Copies premultiplied tile-style [rgba] pixels into a stroke-down snapshot.
  factory ShadeSnapshot.fromPremultipliedRgba({
    required int width,
    required int height,
    required Uint8List rgba,
    int originX = 0,
    int originY = 0,
  }) {
    if (width <= 0 || height <= 0 || rgba.lengthInBytes != width * height * 4) {
      throw ArgumentError('RGBA dimensions do not match the pixel payload.');
    }
    final levels = Uint8List(width * height);
    final alpha = Uint8List(width * height);
    for (var index = 0; index < width * height; index += 1) {
      final pixelOffset = index * 4;
      final pixelAlpha = rgba[pixelOffset + 3];
      alpha[index] = pixelAlpha;
      if (pixelAlpha == 0) {
        levels[index] = grayLatticeMaxLevel;
        continue;
      }
      final red = (rgba[pixelOffset] * 255 / pixelAlpha).round().clamp(0, 255);
      final green = (rgba[pixelOffset + 1] * 255 / pixelAlpha).round().clamp(
        0,
        255,
      );
      final blue = (rgba[pixelOffset + 2] * 255 / pixelAlpha).round().clamp(
        0,
        255,
      );
      levels[index] = nearestInkShadeLatticeLevel(
        argbLumaLatticeLevel(0xff000000 | red << 16 | green << 8 | blue),
      );
    }
    return ShadeSnapshot._(
      originX: originX,
      originY: originY,
      width: width,
      height: height,
      levels: levels,
      alpha: alpha,
    );
  }

  /// Left document coordinate of the captured region.
  final int originX;

  /// Top document coordinate of the captured region.
  final int originY;

  /// Captured width.
  final int width;

  /// Captured height.
  final int height;

  final Uint8List _levels;
  final Uint8List _alpha;

  /// Defensive copy of captured lattice levels.
  Uint8List get levels => Uint8List.fromList(_levels);

  /// Defensive copy of captured alpha values.
  Uint8List get alpha => Uint8List.fromList(_alpha);

  int? _indexOf(int documentX, int documentY) {
    final localX = documentX - originX;
    final localY = documentY - originY;
    if (localX < 0 || localX >= width || localY < 0 || localY >= height) {
      return null;
    }
    return localY * width + localX;
  }
}

/// Immutable document-aligned alpha coverage consumed by snapshot shade.
final class ShadeCoverage {
  /// Copies [alpha] so later caller mutation cannot affect shade output.
  ShadeCoverage({
    required this.width,
    required this.height,
    required Uint8List alpha,
    this.originX = 0,
    this.originY = 0,
  }) : _alpha = Uint8List.fromList(alpha) {
    _checkRasterLength(width, height, alpha.lengthInBytes, 'alpha');
  }

  /// Creates fully covered pixels.
  factory ShadeCoverage.solid({
    required int width,
    required int height,
    int originX = 0,
    int originY = 0,
  }) => ShadeCoverage(
    width: width,
    height: height,
    alpha: Uint8List(width * height)..fillRange(0, width * height, 255),
    originX: originX,
    originY: originY,
  );

  /// Coverage width.
  final int width;

  /// Coverage height.
  final int height;

  /// Left document coordinate.
  final int originX;

  /// Top document coordinate.
  final int originY;

  final Uint8List _alpha;

  /// Defensive copy of coverage alpha.
  Uint8List get alpha => Uint8List.fromList(_alpha);

  int alphaAt(int documentX, int documentY) {
    final localX = documentX - originX;
    final localY = documentY - originY;
    if (localX < 0 || localX >= width || localY < 0 || localY >= height) {
      return 0;
    }
    return _alpha[localY * width + localX];
  }
}

/// Absolute /30 levels produced by one pure snapshot shade evaluation.
final class AbsoluteShadeResult {
  AbsoluteShadeResult._({
    required this.originX,
    required this.originY,
    required this.width,
    required this.height,
    required Int8List levels,
    required Uint8List alpha,
  }) : _levels = Int8List.fromList(levels),
       _alpha = Uint8List.fromList(alpha);

  /// Sentinel used for pixels outside coverage or transparent in the snapshot.
  static const int uncoveredLevel = -1;

  /// Left document coordinate.
  final int originX;

  /// Top document coordinate.
  final int originY;

  /// Output width.
  final int width;

  /// Output height.
  final int height;

  final Int8List _levels;
  final Uint8List _alpha;

  /// Defensive copy of absolute levels, with [uncoveredLevel] holes.
  Int8List get levels => Int8List.fromList(_levels);

  /// Defensive copy of output alpha.
  Uint8List get alpha => Uint8List.fromList(_alpha);

  /// Absolute level at a document pixel, or [uncoveredLevel].
  int levelAt(int documentX, int documentY) {
    final localX = documentX - originX;
    final localY = documentY - originY;
    if (localX < 0 || localX >= width || localY < 0 || localY >= height) {
      return uncoveredLevel;
    }
    return _levels[localY * width + localX];
  }

  /// Premultiplied RGBA payload suitable for an absolute-output adapter.
  Uint8List toPremultipliedRgba() {
    final rgba = Uint8List(width * height * 4);
    for (var index = 0; index < _levels.length; index += 1) {
      final level = _levels[index];
      if (level == uncoveredLevel) {
        continue;
      }
      final alpha = _alpha[index];
      final channel = latticeLevelToSrgbChannel(level);
      final premultiplied = (channel * alpha / 255).round();
      final offset = index * 4;
      rgba[offset] = premultiplied;
      rgba[offset + 1] = premultiplied;
      rgba[offset + 2] = premultiplied;
      rgba[offset + 3] = alpha;
    }
    return rgba;
  }
}

/// Pure snapshot-only shade: no destination reads occur after this call starts.
AbsoluteShadeResult shadeSnapshot({
  required ShadeSnapshot snapshot,
  required ShadeCoverage coverage,
  required ShadeDirection direction,
}) {
  final levels = Int8List(coverage.width * coverage.height)
    ..fillRange(
      0,
      coverage.width * coverage.height,
      AbsoluteShadeResult.uncoveredLevel,
    );
  final alpha = Uint8List(coverage.width * coverage.height);
  for (var localY = 0; localY < coverage.height; localY += 1) {
    for (var localX = 0; localX < coverage.width; localX += 1) {
      final index = localY * coverage.width + localX;
      final coverageAlpha = coverage._alpha[index];
      if (coverageAlpha < absoluteShadeCoverageCutoff) {
        continue;
      }
      final documentX = coverage.originX + localX;
      final documentY = coverage.originY + localY;
      final snapshotIndex = snapshot._indexOf(documentX, documentY);
      if (snapshotIndex == null || snapshot._alpha[snapshotIndex] == 0) {
        continue;
      }
      levels[index] = stepInkShadeLattice(
        snapshot._levels[snapshotIndex],
        direction,
      );
      alpha[index] = snapshot._alpha[snapshotIndex];
    }
  }
  return AbsoluteShadeResult._(
    originX: coverage.originX,
    originY: coverage.originY,
    width: coverage.width,
    height: coverage.height,
    levels: levels,
    alpha: alpha,
  );
}

/// Hatcher second pass: crosshatch-clips the ribbon and shades existing hatch.
AbsoluteShadeResult shadeHatcherCrosshatch({
  required ShadeSnapshot snapshot,
  required ShadeCoverage existingHatchCoverage,
  required ShadeCoverage strokeRibbonCoverage,
  int densityLevel = 2,
  double angleRadians = 0,
  ShadeDirection direction = ShadeDirection.darker,
}) {
  final intersected = Uint8List(
    strokeRibbonCoverage.width * strokeRibbonCoverage.height,
  );
  for (var localY = 0; localY < strokeRibbonCoverage.height; localY += 1) {
    for (var localX = 0; localX < strokeRibbonCoverage.width; localX += 1) {
      final documentX = strokeRibbonCoverage.originX + localX;
      final documentY = strokeRibbonCoverage.originY + localY;
      final ribbon = strokeRibbonCoverage.alphaAt(documentX, documentY);
      final existing = existingHatchCoverage.alphaAt(documentX, documentY);
      if (ribbon == 0 || existing == 0) {
        continue;
      }
      final pattern = crosshatchSecondPassValue(
        documentX.toDouble(),
        documentY.toDouble(),
        densityLevel: densityLevel,
        angleRadians: angleRadians,
      );
      intersected[localY * strokeRibbonCoverage.width + localX] =
          (math.min(ribbon, existing) * pattern).round();
    }
  }
  return shadeSnapshot(
    snapshot: snapshot,
    coverage: ShadeCoverage(
      width: strokeRibbonCoverage.width,
      height: strokeRibbonCoverage.height,
      alpha: intersected,
      originX: strokeRibbonCoverage.originX,
      originY: strokeRibbonCoverage.originY,
    ),
    direction: direction,
  );
}

void _checkRasterLength(int width, int height, int length, String name) {
  if (width <= 0 || height <= 0 || length != width * height) {
    throw ArgumentError('$name dimensions do not match its pixel payload.');
  }
}

/// Changed COW tiles produced by [compositeClearMask].
final class ClearCompositeResult {
  /// Creates an immutable clear-composite result.
  ClearCompositeResult({
    required Map<TileKey, Tile?> afterTiles,
    required Map<TileKey, Tile?> beforeTiles,
  }) : afterTiles = Map<TileKey, Tile?>.unmodifiable(afterTiles),
       beforeTiles = Map<TileKey, Tile?>.unmodifiable(beforeTiles);

  /// Nullable replacement references; null removes a fully transparent tile.
  final Map<TileKey, Tile?> afterTiles;

  /// Exact immutable store references captured before compositing.
  final Map<TileKey, Tile?> beforeTiles;

  /// Whether no occupied destination pixel changed.
  bool get isEmpty => afterTiles.isEmpty;
}

/// Applies an RGBA stroke's alpha as destination-out coverage without mutation.
///
/// This is the scope-fenced pixel-eraser fallback for the current raster worker,
/// whose command supports source-over only. Only changed [candidateKeys] appear
/// in the result. A completely erased tile is represented by a null after ref.
ClearCompositeResult compositeClearMask({
  required TileStore tiles,
  required String layerId,
  required Iterable<TileKey> candidateKeys,
  required Uint8List maskPixels,
  required int maskOriginX,
  required int maskOriginY,
  required int maskWidth,
  required int maskHeight,
}) {
  if (layerId.isEmpty) {
    throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
  }
  if (maskWidth < 0 ||
      maskHeight < 0 ||
      maskPixels.lengthInBytes != maskWidth * maskHeight * 4) {
    throw ArgumentError('Mask dimensions do not match its RGBA payload.');
  }
  final after = <TileKey, Tile?>{};
  final before = <TileKey, Tile?>{};
  for (final key in candidateKeys.toSet()) {
    final beforeTile = tiles.tile(layerId, key);
    if (beforeTile == null) {
      continue;
    }
    final output = beforeTile.mutableCopy();
    final tileLeft = key.x * Tile.edge;
    final tileTop = key.y * Tile.edge;
    final left = math.max(tileLeft, maskOriginX);
    final top = math.max(tileTop, maskOriginY);
    final right = math.min(tileLeft + Tile.edge, maskOriginX + maskWidth);
    final bottom = math.min(tileTop + Tile.edge, maskOriginY + maskHeight);
    var changed = false;
    for (var documentY = top; documentY < bottom; documentY += 1) {
      for (var documentX = left; documentX < right; documentX += 1) {
        final maskOffset =
            ((documentY - maskOriginY) * maskWidth + documentX - maskOriginX) *
            4;
        final alpha = maskPixels[maskOffset + 3];
        if (alpha == 0) {
          continue;
        }
        final inverseAlpha = 255 - alpha;
        final destinationOffset =
            ((documentY - tileTop) * Tile.edge + documentX - tileLeft) * 4;
        for (var channel = 0; channel < 4; channel += 1) {
          final next =
              (output[destinationOffset + channel] * inverseAlpha + 127) ~/ 255;
          if (next != output[destinationOffset + channel]) {
            output[destinationOffset + channel] = next;
            changed = true;
          }
        }
      }
    }
    if (!changed) {
      continue;
    }
    before[key] = beforeTile;
    final next = Tile.takeOwnership(output);
    after[key] = next.isTransparent ? null : next;
  }
  return ClearCompositeResult(afterTiles: after, beforeTiles: before);
}

Rect? _includeDamage(Rect? current, Rect next) {
  if (next.isEmpty) {
    return current;
  }
  return current == null ? next : current.expandToInclude(next);
}
