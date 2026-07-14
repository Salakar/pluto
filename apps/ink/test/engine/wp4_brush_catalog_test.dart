import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('WP4 full brush catalog', () {
    test('contains exactly sixteen drawing brushes in binding order', () {
      expect(drawingBrushes.map((BrushSpec brush) => brush.id), <String>[
        'fineliner',
        'technical',
        'ballpoint',
        'fountain',
        'calligraphy',
        'brushpen',
        'pencilhb',
        'pencil6b',
        'mechanical',
        'charcoal',
        'marker',
        'highlighter',
        'spray',
        'stipple',
        'hatcher',
        'toneshader',
      ]);
      expect(drawingBrushesById.length, 16);
    });

    test('keeps the pixel eraser separate from drawing brushes', () {
      expect(drawingBrushes, isNot(contains(eraserPixelBrush)));
      expect(brushesById, hasLength(17));
      expect(brushById('eraserpixel'), same(eraserPixelBrush));
      expect(() => brushById('missing'), throwsArgumentError);
    });

    test('every baked pattern has a named catalog consumer', () {
      final ids = drawingBrushes.map((BrushSpec brush) => brush.id).toSet();
      expect(bakedBrushPatternConsumers.keys, <String>[
        'paperTooth',
        'charcoalStrata',
        'hatch45',
        'crosshatch',
        'dotScreen60lpi',
      ]);
      for (final consumers in bakedBrushPatternConsumers.values) {
        expect(consumers, isNotEmpty);
        expect(consumers, everyElement(isIn(ids)));
      }
      expect(bakedBrushPatternConsumers.containsKey('grainCanvas'), isFalse);
      expect(bakedBrushPatternConsumers.containsKey('bayer4'), isFalse);
      expect(bakedBrushPatternConsumers.containsKey('bayer8'), isFalse);
    });

    test('fountain row binds pressure, tilt width, and tail taper', () {
      expect(
        (
          fountainBrush.sizeMin,
          fountainBrush.sizeMax,
          fountainBrush.sizeDefault,
        ),
        (2, 10, 5),
      );
      expect(fountainBrush.pressureSize.gamma, 1.6);
      expect(fountainBrush.pressureSize.map(0), 0.5);
      expect(fountainBrush.pressureSize.map(1), 1.4);
      expect(fountainBrush.tilt!.sizeMultiplier(1), 1.2);
      expect(fountainBrush.taper.tailLength, greaterThan(0));
    });

    test('calligraphy row is a fixed forty-degree chisel', () {
      expect(calligraphyBrush.kind, BrushClass.vectorPen);
      expect(calligraphyBrush.nib.kind, NibKind.chisel);
      expect(calligraphyBrush.nib.angleDegrees, 40);
      expect(
        (
          calligraphyBrush.sizeMin,
          calligraphyBrush.sizeMax,
          calligraphyBrush.sizeDefault,
        ),
        (4, 24, 12),
      );
    });

    test('six-B row caps tilt squash and deepens fixed paper tooth', () {
      expect(pencil6bBrush.preview, PreviewStyle.outline);
      expect(pencil6bBrush.nib.kind, NibKind.ellipse);
      expect(pencil6bBrush.tilt!.squash(1), 3.5);
      expect(pencil6bBrush.grain!.patternId, 'paperTooth');
      expect(pencil6bBrush.grain!.depth, 0.8);
      expect(pencil6bBrush.quantizeLevels, 4);
    });

    test('mechanical row fixes output to lattice level eighteen', () {
      expect(mechanicalBrush.kind, BrushClass.vectorPen);
      expect(mechanicalBrush.fixedLatticeLevel, 18);
      expect(mechanicalBrush.quantizeLevels, 1);
      expect(mechanicalBrush.pressureSize.map(0), 1);
      expect(mechanicalBrush.pressureSize.map(1), 1);
    });

    test('charcoal row consumes strata and exposes broken texture edge', () {
      expect(charcoalBrush.nib.kind, NibKind.texture);
      expect(charcoalBrush.nib.maskId, 'charcoalStrata');
      expect(charcoalBrush.grain!.patternId, 'charcoalStrata');
      expect(charcoalBrush.grain!.depth, 1);
      expect(charcoalBrush.jitter, greaterThan(0));
      expect(charcoalBrush.quantizeLevels, 6);
    });

    test('marker and highlighter carry their different overlap caps', () {
      expect(markerBrush.blend.kind, BrushBlend.multiply);
      expect(markerBrush.maxOverlapSteps, 2);
      expect(highlighterBrush.blend.kind, BrushBlend.multiply);
      expect(highlighterBrush.maxOverlapSteps, 1);
      expect(highlighterBrush.minimumLumaLevel, 12);
      expect(
        highlighterColorsArgb.map(argbLumaLatticeLevel),
        everyElement(greaterThanOrEqualTo(12)),
      );
    });

    test('particle rows bind seeded count spread and legal dot sizes', () {
      expect(sprayBrush.kind, BrushClass.particle);
      expect(sprayBrush.nib.particleCount, greaterThan(0));
      expect(sprayBrush.nib.particleSpread, greaterThan(0));
      expect(
        (sprayBrush.nib.particleSizeMin, sprayBrush.nib.particleSizeMax),
        (1, 2),
      );
      expect(stippleBrush.kind, BrushClass.particle);
      expect(stippleBrush.nib.maskId, 'dotScreen60lpi');
      expect(
        (stippleBrush.nib.particleSizeMin, stippleBrush.nib.particleSizeMax),
        (1, 3),
      );
    });

    test('hatcher lays opaque primary hatch and tone shader uses shade', () {
      expect(hatcherBrush.grain!.patternId, 'hatch45');
      expect(hatcherBrush.patternDensitySteps, 4);
      expect(hatcherBrush.blend.kind, BrushBlend.opaque);
      expect(toneshaderBrush.blend.kind, BrushBlend.shade);
      expect(toneshaderBrush.blend.shadeDirection, ShadeDirection.darker);

      final lighter = toneshaderBrush.withShadeDirection(
        ShadeDirection.lighter,
      );
      expect(lighter.id, 'toneshader');
      expect(lighter.blend.shadeDirection, ShadeDirection.lighter);
      expect(toneshaderBrush.blend.shadeDirection, ShadeDirection.darker);
      expect(
        () => finelinerBrush.withShadeDirection(ShadeDirection.lighter),
        throwsStateError,
      );
    });
  });
}
