import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('WP4 resolved brush mechanics', () {
    test('fountain tilt adds exactly twenty-percent width at full tilt', () {
      final upright = _renderDot(fountainBrush, pressure: 1, tilt: 0);
      final tilted = _renderDot(fountainBrush, pressure: 1, tilt: 1);

      expect(tilted.diameterX / upright.diameterX, closeTo(1.2, 1e-12));
      expect(tilted.diameterY / upright.diameterY, closeTo(1.2, 1e-12));
    });

    test('fountain pressure follows its half-to-1.4 gamma range', () {
      final low = _renderDot(fountainBrush, pressure: 0);
      final high = _renderDot(fountainBrush, pressure: 1);

      expect(low.diameterX, closeTo(2.5, 1e-12));
      expect(high.diameterX, closeTo(7, 1e-12));
    });

    test('calligraphy sine law clamps parallel and peaks perpendicular', () {
      final parallel = Offset(
        math.cos(40 * math.pi / 180),
        math.sin(40 * math.pi / 180),
      );
      final perpendicular = Offset(
        math.cos(130 * math.pi / 180),
        math.sin(130 * math.pi / 180),
      );

      expect(
        calligraphyWidthMultiplier(parallel, nibAngleDegrees: 40),
        closeTo(0.15, 1e-12),
      );
      expect(
        calligraphyWidthMultiplier(perpendicular, nibAngleDegrees: 40),
        closeTo(1, 1e-12),
      );
    });

    test('calligraphy engine resolves direction-dependent chisel width', () {
      final parallel = _renderDirectedLine(calligraphyBrush, degrees: 40);
      final perpendicular = _renderDirectedLine(calligraphyBrush, degrees: 130);

      expect(parallel.diameterX, closeTo(1.8, 1e-8));
      expect(perpendicular.diameterX, closeTo(12, 1e-8));
      expect(parallel.diameterY, closeTo(1.8, 1e-8));
    });

    test('rotated chisel bounds include rectangular nib corners', () {
      final stamp = ResolvedBrushStamp(
        center: Offset.zero,
        diameterX: 10,
        diameterY: 4,
        angleRadians: math.pi / 4,
        colorArgb: 0xff000000,
        flow: 1,
        blend: BrushBlend.opaque,
        grain: null,
        nibKind: NibKind.chisel,
      );
      final cornerExtent = (5 + 2) * math.sqrt(0.5);

      expect(stamp.bounds.width, closeTo((cornerExtent + 0.5) * 2, 1e-12));
      expect(stamp.bounds.height, closeTo((cornerExtent + 0.5) * 2, 1e-12));
    });

    test('six-B tilt squashes no farther than 3.5 and deepens grain', () {
      final upright = _renderDot(pencil6bBrush, pressure: 1, tilt: 0);
      final tilted = _renderDot(pencil6bBrush, pressure: 1, tilt: 1);

      expect(upright.diameterX, 8);
      expect(upright.diameterY, 8);
      expect(tilted.diameterX, 28);
      expect(tilted.diameterY, 8);
      expect(upright.grain!.depth, closeTo(0.48, 1e-12));
      expect(tilted.grain!.depth, closeTo(0.8, 1e-12));
    });

    test('mechanical ignores requested color and emits lattice level 18', () {
      final stamp = _renderDot(
        mechanicalBrush,
        pressure: 0.2,
        colorArgb: 0xffff0000,
      );

      expect(argbLumaLatticeLevel(stamp.colorArgb), 18);
      expect((stamp.colorArgb >>> 16) & 0xff, stamp.colorArgb & 0xff);
      expect(stamp.diameterX, 2);
    });

    test('charcoal strata is tileable, torn, and not flat', () {
      final values = <double>[
        for (var y = 0; y < 64; y += 1)
          for (var x = 0; x < 64; x += 1)
            proceduralGrainValue('charcoalStrata', x.toDouble(), y.toDouble()),
      ];

      expect(values, contains(0));
      expect(values.toSet().length, greaterThan(100));
      expect(
        proceduralGrainValue('charcoalStrata', 7, 19),
        proceduralGrainValue('charcoalStrata', 71, 83),
      );
    });

    test('particle count scales with selected-size squared', () {
      final normal = resolvedParticleCount(
        sprayBrush,
        selectedSize: 28,
        density: 1,
      );
      final doubleSize = resolvedParticleCount(
        sprayBrush,
        selectedSize: 56,
        density: 1,
      );
      final halfDensity = resolvedParticleCount(
        sprayBrush,
        selectedSize: 28,
        density: 0.5,
      );

      expect(normal, 20);
      expect(doubleSize, normal * 4);
      expect(halfDensity, normal ~/ 2);
    });

    test('spray repeats exactly for a stroke seed', () {
      final first = _renderParticles(sprayBrush, seed: 91, pressure: 1);
      final again = _renderParticles(sprayBrush, seed: 91, pressure: 1);
      final other = _renderParticles(sprayBrush, seed: 92, pressure: 1);

      expect(
        first.map((ResolvedBrushStamp stamp) => stamp.center),
        again.map((ResolvedBrushStamp stamp) => stamp.center),
      );
      expect(
        first.map((ResolvedBrushStamp stamp) => stamp.center),
        isNot(other.map((ResolvedBrushStamp stamp) => stamp.center)),
      );
      expect(first, hasLength(20));
    });

    test(
      'spray emits one-to-two-pixel dots inside bounded Gaussian spread',
      () {
        final stamps = _renderParticles(sprayBrush, seed: 123, pressure: 1);

        expect(
          stamps.map((ResolvedBrushStamp stamp) => stamp.diameterX),
          everyElement(inInclusiveRange(1, 2)),
        );
        expect(
          stamps.map((ResolvedBrushStamp stamp) => stamp.center.distance),
          everyElement(lessThanOrEqualTo(28 * sprayBrush.nib.particleSpread)),
        );
      },
    );

    test('stipple pressure maps dot diameter from one to three pixels', () {
      final light = _renderParticles(stippleBrush, seed: 7, pressure: 0);
      final heavy = _renderParticles(stippleBrush, seed: 7, pressure: 1);

      expect(
        light.map((ResolvedBrushStamp stamp) => stamp.diameterX),
        everyElement(1),
      );
      expect(
        heavy.map((ResolvedBrushStamp stamp) => stamp.diameterX),
        everyElement(3),
      );
    });

    test('stipple dots are Poisson-spaced within each impression', () {
      final stamps = _renderParticles(stippleBrush, seed: 77, pressure: 1);
      var nearest = double.infinity;
      for (var a = 0; a < stamps.length; a += 1) {
        for (var b = a + 1; b < stamps.length; b += 1) {
          nearest = math.min(
            nearest,
            (stamps[a].center - stamps[b].center).distance,
          );
        }
      }

      expect(nearest, greaterThanOrEqualTo(3 * 0.78 - 1e-12));
    });

    test('stipple Poisson spacing survives adjacent path emitters', () {
      final stamps = _renderParticleLine(stippleBrush, seed: 78, pressure: 1);
      var nearest = double.infinity;
      for (var a = 0; a < stamps.length; a += 1) {
        for (var b = a + 1; b < stamps.length; b += 1) {
          nearest = math.min(
            nearest,
            (stamps[a].center - stamps[b].center).distance,
          );
        }
      }

      expect(stamps.length, greaterThan(stippleBrush.nib.particleCount));
      expect(nearest, greaterThanOrEqualTo(3 * 0.78 - 1e-12));
    });

    test('stipple spacing accounts for neighboring variable dot radii', () {
      final stamps = _renderVariablePressureStipple(seed: 79);

      expect(
        stamps.map((ResolvedBrushStamp stamp) => stamp.diameterX),
        contains(3),
      );
      expect(
        stamps.map((ResolvedBrushStamp stamp) => stamp.diameterX),
        contains(1),
      );
      for (var a = 0; a < stamps.length; a += 1) {
        for (var b = a + 1; b < stamps.length; b += 1) {
          final minimum =
              (stamps[a].diameterX + stamps[b].diameterX) * 0.5 * 0.78;
          expect(
            (stamps[a].center - stamps[b].center).distance,
            greaterThanOrEqualTo(minimum - 1e-12),
          );
        }
      }
    });

    test('hatcher pressure chooses density one through four', () {
      final low = _renderDot(hatcherBrush, pressure: 0);
      final middle = _renderDot(hatcherBrush, pressure: 0.5);
      final high = _renderDot(hatcherBrush, pressure: 1);

      expect(low.grain!.densityLevel, 1);
      expect(middle.grain!.densityLevel, 3);
      expect(high.grain!.densityLevel, 4);
      expect(high.blend, BrushBlend.opaque);
    });

    test('hatcher pattern rotates to follow stroke direction', () {
      final horizontal = _renderDirectedLine(hatcherBrush, degrees: 0);
      final vertical = _renderDirectedLine(hatcherBrush, degrees: 90);

      expect(horizontal.grain!.angleRadians, closeTo(0, 1e-12));
      expect(vertical.grain!.angleRadians, closeTo(math.pi / 2, 1e-8));
    });

    test('hatch and dot patterns become denser in higher steps', () {
      int occupied(String id, int density) => <double>[
        for (var y = 0; y < 64; y += 1)
          for (var x = 0; x < 64; x += 1)
            proceduralGrainValue(
              id,
              x.toDouble(),
              y.toDouble(),
              densityLevel: density,
            ),
      ].where((double value) => value > 0).length;

      expect(occupied('hatch45', 4), greaterThan(occupied('hatch45', 1)));
      expect(
        occupied('dotScreen60lpi', 4),
        greaterThan(occupied('dotScreen60lpi', 1)),
      );
      expect(occupied('crosshatch', 2), greaterThan(0));
    });

    test(
      'unknown baked pattern identifiers fail instead of silently hashing',
      () {
        expect(
          () => proceduralGrainValue('unownedPattern', 0, 0),
          throwsArgumentError,
        );
      },
    );
  });
}

ResolvedBrushStamp _renderDot(
  BrushSpec spec, {
  required double pressure,
  double tilt = 0,
  int colorArgb = 0xff123456,
}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: 17,
    colorArgb: colorArgb,
  );
  engine.stampAlong(<BrushPoint>[
    BrushPoint(
      point: Offset.zero,
      pressure: pressure,
      tilt: tilt,
      timestamp: Duration.zero,
    ),
  ]);
  engine.finalize();
  return target.stamps.single;
}

ResolvedBrushStamp _renderDirectedLine(
  BrushSpec spec, {
  required double degrees,
}) {
  final angle = degrees * math.pi / 180;
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: 17,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[
    BrushPoint(point: Offset.zero, pressure: 1, timestamp: Duration.zero),
    BrushPoint(
      point: Offset(math.cos(angle) * 30, math.sin(angle) * 30),
      pressure: 1,
      timestamp: const Duration(milliseconds: 30),
    ),
  ]);
  engine.finalize();
  return target.stamps.last;
}

List<ResolvedBrushStamp> _renderParticles(
  BrushSpec spec, {
  required int seed,
  required double pressure,
}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: seed,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[
    BrushPoint(
      point: Offset.zero,
      pressure: pressure,
      timestamp: Duration.zero,
    ),
  ]);
  engine.finalize();
  return target.stamps;
}

List<ResolvedBrushStamp> _renderParticleLine(
  BrushSpec spec, {
  required int seed,
  required double pressure,
}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: spec,
    target: target,
    seed: seed,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[
    BrushPoint(
      point: Offset.zero,
      pressure: pressure,
      timestamp: Duration.zero,
    ),
    BrushPoint(
      point: const Offset(30, 0),
      pressure: pressure,
      timestamp: const Duration(milliseconds: 30),
    ),
  ]);
  engine.finalize();
  return target.stamps;
}

List<ResolvedBrushStamp> _renderVariablePressureStipple({required int seed}) {
  final target = RecordingBrushStampTarget();
  final engine = BrushEngine(
    spec: stippleBrush,
    target: target,
    seed: seed,
    colorArgb: 0xff123456,
  );
  engine.stampAlong(<BrushPoint>[
    BrushPoint(point: Offset.zero, pressure: 1, timestamp: Duration.zero),
    BrushPoint(
      point: const Offset(30, 0),
      pressure: 0,
      timestamp: const Duration(milliseconds: 30),
    ),
  ]);
  engine.finalize();
  return target.stamps;
}
