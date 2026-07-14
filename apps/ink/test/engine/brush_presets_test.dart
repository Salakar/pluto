import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('BrushSpec parameter model', () {
    test('keeps the complete binding enum vocabulary', () {
      expect(BrushClass.values.map((BrushClass value) => value.name), <String>[
        'vectorPen',
        'stamp',
        'particle',
        'pattern',
      ]);
      expect(
        PreviewStyle.values.map((PreviewStyle value) => value.name),
        <String>['solid', 'outline'],
      );
      expect(BrushBlend.values.map((BrushBlend value) => value.name), <String>[
        'opaque',
        'buildup',
        'multiply',
        'clear',
        'shade',
      ]);
    });

    test('pressure map follows the exact gamma formula', () {
      const PressureMap map = PressureMap(gamma: 2.2, lo: 0.75, hi: 1);

      expect(map.map(0), 0.75);
      expect(map.map(1), 1);
      expect(map.map(0.5), closeTo(0.75 + 0.25 * math.pow(0.5, 2.2), 1e-12));
    });

    test(
      'pressure map clamps normalized input and rejects non-finite input',
      () {
        const PressureMap map = PressureMap(gamma: 1, lo: 0.25, hi: 1);

        expect(map.map(-1), 0.25);
        expect(map.map(2), 1);
        expect(() => map.map(double.nan), throwsArgumentError);
        expect(() => map.map(double.infinity), throwsArgumentError);
      },
    );

    test('per-parameter curve composes after a global pressure preset', () {
      const PressureMap global = PressureMap(gamma: 2, lo: 0, hi: 1);
      const PressureMap size = PressureMap(gamma: 1, lo: 0.5, hi: 1);

      expect(size.map(global.map(0.5)), closeTo(0.625, 1e-12));
    });

    test('tilt map covers size, grain depth, and squash', () {
      const TiltMap map = TiltMap(
        gamma: 1,
        sizeLo: 1,
        sizeHi: 1.2,
        grainDepthLo: 0.5,
        grainDepthHi: 1,
        squashLo: 1,
        squashHi: 3.5,
      );

      expect(map.sizeMultiplier(0.5), closeTo(1.1, 1e-12));
      expect(map.grainDepth(0.5), closeTo(0.75, 1e-12));
      expect(map.squash(0.5), closeTo(2.25, 1e-12));
    });

    test('nib model represents every binding shape', () {
      const NibShape disc = NibShape.disc();
      const NibShape ellipse = NibShape.ellipse(angleDegrees: 40, ratio: 0.5);
      const NibShape chisel = NibShape.chisel(angleDegrees: 90);
      const NibShape texture = NibShape.texture(
        maskId: 'dots',
        particleCount: 10,
        particleSpread: 0.8,
      );

      expect(disc.kind, NibKind.disc);
      expect(ellipse.kind, NibKind.ellipse);
      expect(ellipse.ratio, 0.5);
      expect(chisel.kind, NibKind.chisel);
      expect(chisel.angleDegrees, 90);
      expect(texture.kind, NibKind.texture);
      expect(texture.maskId, 'dots');
      expect(texture.particleCount, 10);
      expect(texture.particleSpread, 0.8);
    });

    test('shade remains representable without a WP3 implementation', () {
      const BlendBehavior darker = BlendBehavior.shade(ShadeDirection.darker);

      expect(darker.kind, BrushBlend.shade);
      expect(darker.shadeDirection, ShadeDirection.darker);
      expect(darker.isClear, isFalse);
    });

    test('catalog collections are immutable const data', () {
      expect(() => starterBrushes.add(finelinerBrush), throwsUnsupportedError);
      expect(
        () => starterBrushesById['extra'] = finelinerBrush,
        throwsUnsupportedError,
      );
    });
  });

  group('starter brush catalog', () {
    test('contains exactly the six stable ids in proof-sheet order', () {
      expect(starterBrushes.map((BrushSpec brush) => brush.id), <String>[
        'fineliner',
        'technical',
        'ballpoint',
        'brushpen',
        'pencilhb',
        'eraserpixel',
      ]);
      expect(starterBrushesById.length, starterBrushes.length);
    });

    test('lookup returns catalog identities and rejects unknown ids', () {
      for (final BrushSpec brush in starterBrushes) {
        expect(identical(starterBrushById(brush.id), brush), isTrue);
      }
      expect(() => starterBrushById('charcoal'), throwsArgumentError);
    });

    test('every starter carries every shared pure-data invariant', () {
      for (final BrushSpec brush in starterBrushes) {
        expect(brush.id, brush.id.toLowerCase());
        expect(brush.sizeMin, greaterThan(0));
        expect(
          brush.sizeDefault,
          inInclusiveRange(brush.sizeMin, brush.sizeMax),
        );
        expect(brush.spacing, greaterThan(0));
        expect(brush.jitter, greaterThanOrEqualTo(0));
        expect(brush.nib.kind, NibKind.disc);
        expect(brush.preview, PreviewStyle.solid);
        expect(brush.previewAlphaCutoff, inExclusiveRange(0, 1.0000001));
      }
    });

    test('fineliner matches the binding default pen row', () {
      const BrushSpec brush = finelinerBrush;

      expect(brush.kind, BrushClass.vectorPen);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (1.5, 8, 3));
      expect(brush.smoothing, 0.7);
      expect(brush.pressureSize.map(0), 1);
      expect(brush.pressureSize.map(1), 1);
      expect(brush.taper, same(TaperSpec.none));
      expect(brush.velocityThins, isFalse);
      expect(brush.quantizeLevels, 0);
    });

    test('technical matches constant zero-taper stabilization row', () {
      const BrushSpec brush = technicalBrush;

      expect(brush.kind, BrushClass.vectorPen);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (1, 4, 2));
      expect(brush.smoothing, 0.85);
      expect(brush.pressureSize.map(0), 1);
      expect(brush.pressureSize.map(1), 1);
      expect(brush.taper.headLength, 0);
      expect(brush.taper.tailLength, 0);
      expect(brush.taper.velocityTail, 0);
    });

    test('ballpoint matches pressure and velocity binding behavior', () {
      const BrushSpec brush = ballpointBrush;

      expect(brush.kind, BrushClass.vectorPen);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (2, 6, 3));
      expect(brush.pressureSize.gamma, 2.2);
      expect(brush.pressureSize.lo, 0.75);
      expect(brush.pressureSize.hi, 1);
      expect(brush.pressureSize.map(0.5), closeTo(0.8044094102, 1e-10));
      expect(brush.velocityThins, isTrue);
    });

    test('brushpen matches disc spacing and pressure-size row', () {
      const BrushSpec brush = brushpenBrush;

      expect(brush.kind, BrushClass.stamp);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (4, 28, 10));
      expect(brush.nib.kind, NibKind.disc);
      expect(brush.spacing, 0.12);
      expect(brush.spacing * brush.sizeDefault, closeTo(1.2, 1e-12));
      expect(brush.pressureSize.gamma, 1.4);
      expect(brush.pressureSize.lo, 0.25);
      expect(brush.pressureSize.hi, 1);
      expect(brush.pressureFlow.map(0), lessThan(brush.pressureFlow.map(1)));
      expect(brush.taper.velocityTail, greaterThan(0));
    });

    test('pencilhb matches fixed paper-tooth quantized row', () {
      const BrushSpec brush = pencilHbBrush;

      expect(brush.kind, BrushClass.stamp);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (2, 10, 4));
      expect(brush.grain, isNotNull);
      expect(brush.grain!.patternId, 'paperTooth');
      expect(brush.grain!.movement, GrainMovement.fixed);
      expect(brush.grain!.depth, 0.5);
      expect(brush.pressureFlow.gamma, 1.8);
      expect(brush.quantizeLevels, 4);
      expect(brush.tilt, isNull);
    });

    test('eraserpixel matches clear hard-disc pressure row', () {
      const BrushSpec brush = eraserPixelBrush;

      expect(brush.kind, BrushClass.stamp);
      expect((brush.sizeMin, brush.sizeMax, brush.sizeDefault), (4, 64, 16));
      expect(brush.nib.kind, NibKind.disc);
      expect(brush.blend.kind, BrushBlend.clear);
      expect(brush.blend.isClear, isTrue);
      expect(brush.pressureSize.gamma, 1);
      expect(brush.pressureSize.lo, 0.6);
      expect(brush.pressureSize.hi, 1);
      expect(brush.pressureSize.map(0.5), closeTo(0.8, 1e-12));
      expect(brush.preview, PreviewStyle.solid);
    });

    test('only pencilhb quantizes and only eraserpixel clears', () {
      expect(
        starterBrushes
            .where((BrushSpec brush) => brush.quantizeLevels != 0)
            .map((BrushSpec brush) => brush.id),
        <String>['pencilhb'],
      );
      expect(
        starterBrushes
            .where((BrushSpec brush) => brush.blend.isClear)
            .map((BrushSpec brush) => brush.id),
        <String>['eraserpixel'],
      );
    });
  });
}
