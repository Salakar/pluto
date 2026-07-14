import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('snapshot-only shade blend', () {
    test('darker writes the adjacent settle-form lattice member', () {
      final result = shadeSnapshot(
        snapshot: _levels(<int>[0, 6, 14, 30]),
        coverage: ShadeCoverage.solid(width: 4, height: 1),
        direction: ShadeDirection.darker,
      );

      expect(result.levels, <int>[0, 0, 10, 26]);
    });

    test('lighter writes the adjacent member and clamps at paper white', () {
      final result = shadeSnapshot(
        snapshot: _levels(<int>[0, 6, 26, 30]),
        coverage: ShadeCoverage.solid(width: 4, height: 1),
        direction: ShadeDirection.lighter,
      );

      expect(result.levels, <int>[6, 10, 30, 30]);
    });

    test('explicit snapshots reject non-member numeric /30 levels', () {
      expect(
        () => ShadeSnapshot.fromLatticeLevels(
          width: 1,
          height: 1,
          levels: Uint8List.fromList(<int>[12]),
        ),
        throwsRangeError,
      );
      expect(nearestInkShadeLatticeLevel(12), 10);
      expect(stepInkShadeLattice(14, ShadeDirection.darker), 10);
      expect(stepInkShadeLattice(14, ShadeDirection.lighter), 18);
    });

    test('zero coverage and transparent snapshot pixels stay uncovered', () {
      final result = shadeSnapshot(
        snapshot: ShadeSnapshot.fromLatticeLevels(
          width: 3,
          height: 1,
          levels: Uint8List.fromList(<int>[10, 14, 18]),
          alpha: Uint8List.fromList(<int>[255, 0, 255]),
        ),
        coverage: ShadeCoverage(
          width: 3,
          height: 1,
          alpha: Uint8List.fromList(<int>[255, 255, 127]),
        ),
        direction: ShadeDirection.darker,
      );

      expect(result.levels, <int>[6, -1, -1]);
      expect(result.alpha, <int>[255, 0, 0]);
    });

    test('stroke-down snapshot defensively copies its source arrays', () {
      final sourceLevels = Uint8List.fromList(<int>[10, 22]);
      final sourceAlpha = Uint8List.fromList(<int>[255, 255]);
      final snapshot = ShadeSnapshot.fromLatticeLevels(
        width: 2,
        height: 1,
        levels: sourceLevels,
        alpha: sourceAlpha,
      );
      sourceLevels.setAll(0, <int>[30, 30]);
      sourceAlpha.fillRange(0, 2, 0);

      final result = shadeSnapshot(
        snapshot: snapshot,
        coverage: ShadeCoverage.solid(width: 2, height: 1),
        direction: ShadeDirection.darker,
      );

      expect(result.levels, <int>[6, 18]);
      expect(result.alpha, <int>[255, 255]);
    });

    test('coverage defensively copies and cannot read live destination', () {
      final sourceCoverage = Uint8List.fromList(<int>[255, 255]);
      final coverage = ShadeCoverage(
        width: 2,
        height: 1,
        alpha: sourceCoverage,
      );
      final snapshot = _levels(<int>[14, 22]);
      sourceCoverage.fillRange(0, 2, 0);

      final first = shadeSnapshot(
        snapshot: snapshot,
        coverage: coverage,
        direction: ShadeDirection.darker,
      );
      final editedOutput = first.levels..fillRange(0, 2, 30);
      final second = shadeSnapshot(
        snapshot: snapshot,
        coverage: coverage,
        direction: ShadeDirection.darker,
      );

      expect(editedOutput, <int>[30, 30]);
      expect(second.levels, <int>[10, 18]);
    });

    test('premultiplied RGBA snapshot quantizes luma power 1.8', () {
      final snapshot = ShadeSnapshot.fromPremultipliedRgba(
        width: 3,
        height: 1,
        rgba: Uint8List.fromList(<int>[
          0,
          0,
          0,
          255,
          128,
          128,
          128,
          255,
          255,
          255,
          255,
          255,
        ]),
      );

      expect(snapshot.levels, <int>[0, 10, 30]);
    });

    test(
      'absolute result preserves destination alpha instead of shade alpha',
      () {
        final result = shadeSnapshot(
          snapshot: _levels(<int>[6, 30]),
          coverage: ShadeCoverage(
            width: 2,
            height: 1,
            alpha: Uint8List.fromList(<int>[255, 128]),
          ),
          direction: ShadeDirection.darker,
        );
        final rgba = result.toPremultipliedRgba();

        expect(rgba.sublist(0, 4), <int>[0, 0, 0, 255]);
        expect(rgba[7], 255);
        expect(rgba[4], latticeLevelToSrgbChannel(26));
        expect(rgba[4], rgba[5]);
        expect(rgba[5], rgba[6]);
      },
    );

    test('coverage and snapshot align by document coordinate', () {
      final snapshot = ShadeSnapshot.fromLatticeLevels(
        width: 2,
        height: 2,
        levels: Uint8List.fromList(<int>[6, 10, 14, 18]),
        originX: 5,
        originY: 7,
      );
      final result = shadeSnapshot(
        snapshot: snapshot,
        coverage: ShadeCoverage.solid(
          width: 2,
          height: 1,
          originX: 6,
          originY: 8,
        ),
        direction: ShadeDirection.lighter,
      );

      expect(result.levelAt(6, 8), 22);
      expect(result.levelAt(7, 8), AbsoluteShadeResult.uncoveredLevel);
      expect(result.levelAt(5, 7), AbsoluteShadeResult.uncoveredLevel);
    });

    test('hatcher crosshatch shades only existing hatch intersections', () {
      const width = 32;
      const height = 32;
      final existing = Uint8List(width * height);
      var firstFamilyOnly = -1;
      var crossing = -1;
      for (var y = 0; y < height; y += 1) {
        for (var x = 0; x < width; x += 1) {
          final index = y * width + x;
          final primary = proceduralGrainValue(
            'hatch45',
            x.toDouble(),
            y.toDouble(),
            densityLevel: 2,
          );
          final opposite = crosshatchSecondPassValue(
            x.toDouble(),
            y.toDouble(),
            densityLevel: 2,
          );
          if (primary > 0) {
            existing[index] = 255;
            if (opposite == 0 && firstFamilyOnly < 0) {
              firstFamilyOnly = index;
            } else if (opposite > 0 && crossing < 0) {
              crossing = index;
            }
          }
        }
      }
      final snapshot = ShadeSnapshot.fromLatticeLevels(
        width: width,
        height: height,
        levels: Uint8List(width * height)..fillRange(0, width * height, 18),
      );
      final result = shadeHatcherCrosshatch(
        snapshot: snapshot,
        existingHatchCoverage: ShadeCoverage(
          width: width,
          height: height,
          alpha: existing,
        ),
        strokeRibbonCoverage: ShadeCoverage.solid(width: width, height: height),
        densityLevel: 2,
      );

      expect(firstFamilyOnly, greaterThanOrEqualTo(0));
      expect(crossing, greaterThanOrEqualTo(0));
      expect(
        result.levels[firstFamilyOnly],
        AbsoluteShadeResult.uncoveredLevel,
      );
      expect(result.levels[crossing], 14);
      expect(result.levels, contains(14));
    });

    test('hatcher crosshatch never shades outside existing hatch', () {
      final result = shadeHatcherCrosshatch(
        snapshot: _levels(List<int>.filled(64, 18), width: 8),
        existingHatchCoverage: ShadeCoverage(
          width: 8,
          height: 8,
          alpha: Uint8List(64),
        ),
        strokeRibbonCoverage: ShadeCoverage.solid(width: 8, height: 8),
      );

      expect(result.levels, everyElement(AbsoluteShadeResult.uncoveredLevel));
    });

    test(
      'tone shader records coverage stamps without a live destination read',
      () {
        final target = RecordingBrushStampTarget();
        final engine = BrushEngine(
          spec: toneshaderBrush,
          target: target,
          seed: 4,
          colorArgb: 0xff000000,
        );

        engine.stampAlong(<BrushPoint>[
          BrushPoint(point: Offset.zero, pressure: 1, timestamp: Duration.zero),
        ]);
        engine.finalize();

        expect(target.stamps, hasLength(1));
        expect(target.stamps.single.blend, BrushBlend.shade);
      },
    );
  });
}

ShadeSnapshot _levels(List<int> values, {int? width}) =>
    ShadeSnapshot.fromLatticeLevels(
      width: width ?? values.length,
      height: values.length ~/ (width ?? values.length),
      levels: Uint8List.fromList(values),
    );
