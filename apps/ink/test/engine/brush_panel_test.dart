import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/panels/brush_panel.dart';

void main() {
  group('brush panel authored layout', () {
    test('header consumes slack without changing sixteen 80-dpx rows', () {
      expect(brushPanelHeaderDesignHeight, 80);
      expect(brushPanelRowDesignHeight, 80);
      expect(brushPanelBrushCount, 16);
      expect(
        brushPanelDesignHeight -
            brushPanelHeaderDesignHeight -
            brushPanelBrushCount * brushPanelRowDesignHeight,
        112 + 80 + 56,
        reason: 'option row + tune footer + remaining fixed-layout slack',
      );
    });
  });

  group('brush mini proof plan', () {
    test('records every drawing brush synchronously through the stamper', () {
      final List<BrushMiniProofPlan> plans = drawingBrushes
          .map(buildBrushMiniProofPlan)
          .toList(growable: false);

      expect(plans, hasLength(brushPanelBrushCount));
      expect(
        plans.map((BrushMiniProofPlan plan) => plan.brush.id),
        orderedEquals(drawingBrushes.map((BrushSpec brush) => brush.id)),
      );
      expect(
        plans.every((BrushMiniProofPlan plan) => plan.stamps.isNotEmpty),
        isTrue,
      );
    });

    test('uses stable distinct per-brush seeds and caches identical plans', () {
      final List<BrushMiniProofPlan> plans = drawingBrushes
          .map(buildBrushMiniProofPlan)
          .toList(growable: false);

      expect(
        plans.map((BrushMiniProofPlan plan) => plan.seed).toSet(),
        hasLength(brushPanelBrushCount),
      );
      for (var index = 0; index < drawingBrushes.length; index++) {
        expect(
          buildBrushMiniProofPlan(drawingBrushes[index]),
          same(plans[index]),
        );
      }
    });

    test('constrains requested sizes to the BrushSpec range', () {
      final BrushMiniProofPlan below = buildBrushMiniProofPlan(
        finelinerBrush,
        size: 0,
      );
      final BrushMiniProofPlan above = buildBrushMiniProofPlan(
        finelinerBrush,
        size: 1000,
      );

      expect(below.selectedSize, finelinerBrush.sizeDefault);
      expect(above.selectedSize, finelinerBrush.sizeMax);
    });

    test('exposes immutable recorded stamps', () {
      final BrushMiniProofPlan plan = buildBrushMiniProofPlan(fountainBrush);

      expect(() => plan.stamps.add(plan.stamps.first), throwsUnsupportedError);
    });

    test(
      'resolves chisel proofs as crisp rectangles and other nibs as ovals',
      () {
        final ResolvedBrushStamp calligraphy = buildBrushMiniProofPlan(
          calligraphyBrush,
        ).stamps.first;
        final ResolvedBrushStamp marker = buildBrushMiniProofPlan(
          markerBrush,
        ).stamps.first;
        final ResolvedBrushStamp highlighter = buildBrushMiniProofPlan(
          highlighterBrush,
        ).stamps.first;
        final ResolvedBrushStamp fineliner = buildBrushMiniProofPlan(
          finelinerBrush,
        ).stamps.first;
        final ResolvedBrushStamp charcoal = buildBrushMiniProofPlan(
          charcoalBrush,
        ).stamps.first;

        expect(
          brushMiniProofShapeFor(calligraphy),
          BrushMiniProofShape.chiselRectangle,
        );
        expect(
          brushMiniProofShapeFor(marker),
          BrushMiniProofShape.chiselRectangle,
        );
        expect(
          brushMiniProofShapeFor(highlighter),
          BrushMiniProofShape.chiselRectangle,
        );
        expect(brushMiniProofShapeFor(fineliner), BrushMiniProofShape.oval);
        expect(brushMiniProofShapeFor(charcoal), BrushMiniProofShape.oval);
        expect(charcoal.grain, isNotNull);
      },
    );

    test('rotated chisel corners survive capped rectangular coverage', () {
      final ResolvedBrushStamp rectangle = _geometryStamp(
        nibKind: NibKind.chisel,
      );
      final ResolvedBrushStamp oval = _geometryStamp(nibKind: NibKind.ellipse);
      final double localX = rectangle.diameterX * 0.49;
      final double localY = rectangle.diameterY * 0.49;
      final Offset corner =
          rectangle.center +
          Offset(
            localX * math.cos(rectangle.angleRadians) -
                localY * math.sin(rectangle.angleRadians),
            localX * math.sin(rectangle.angleRadians) +
                localY * math.cos(rectangle.angleRadians),
          );

      expect(brushMiniProofStampContains(rectangle, corner), isTrue);
      expect(brushMiniProofStampBounds(rectangle).contains(corner), isTrue);
      expect(brushMiniProofStampContains(oval, corner), isFalse);
      expect(
        brushMiniProofStampContains(rectangle, const Offset(40, 40)),
        isFalse,
      );
    });
  });

  group('brush panel typed options', () {
    test('defaults match the visible four-notch controls', () {
      const BrushPanelOptions options = BrushPanelOptions();

      expect(options.toneShaderDirection, ShadeDirection.darker);
      expect(options.hatcherMode, HatcherStrokeMode.hatch);
      expect(options.particleDensityFor('spray'), 2);
      expect(options.particleDensityFor('stipple'), 2);
      expect(options.grainFor('pencilhb'), 1);
      expect(options.grainFor('pencil6b'), 2);
      expect(options.grainFor('charcoal'), 3);
    });

    test('copyWith changes one typed option without disturbing the rest', () {
      const BrushPanelOptions original = BrushPanelOptions();
      final BrushPanelOptions changed = original.copyWith(
        toneShaderDirection: ShadeDirection.lighter,
        hatcherMode: HatcherStrokeMode.crosshatch,
        sprayDensity: 0,
      );

      expect(changed.toneShaderDirection, ShadeDirection.lighter);
      expect(changed.hatcherMode, HatcherStrokeMode.crosshatch);
      expect(changed.sprayDensity, 0);
      expect(changed.stippleDensity, original.stippleDensity);
      expect(changed.charcoalGrain, original.charcoalGrain);
    });

    test('brush-specific accessors reject unrelated brush ids', () {
      const BrushPanelOptions options = BrushPanelOptions();

      expect(() => options.particleDensityFor('marker'), throwsArgumentError);
      expect(() => options.grainFor('spray'), throwsArgumentError);
    });

    test('four-notch option constructors reject out-of-range values', () {
      expect(() => BrushPanelOptions(sprayDensity: -1), throwsAssertionError);
      expect(() => BrushPanelOptions(charcoalGrain: 4), throwsAssertionError);
    });
  });

  group('brush panel size metadata', () {
    test('uses compact mono-friendly whole and fractional labels', () {
      expect(brushPanelSizeLabel(3), '3 dpx');
      expect(brushPanelSizeLabel(1.5), '1.5 dpx');
      expect(brushPanelSizeLabel(2.0000001), '2 dpx');
    });

    test('rejects invalid displayed sizes', () {
      expect(() => brushPanelSizeLabel(0), throwsArgumentError);
      expect(() => brushPanelSizeLabel(double.nan), throwsArgumentError);
    });
  });
}

ResolvedBrushStamp _geometryStamp({required NibKind nibKind}) {
  return ResolvedBrushStamp(
    center: const Offset(12, 9),
    diameterX: 10,
    diameterY: 4,
    angleRadians: math.pi / 4,
    colorArgb: 0xff000000,
    flow: 0.5,
    blend: BrushBlend.multiply,
    grain: null,
    nibKind: nibKind,
    maxOverlapSteps: nibKind == NibKind.chisel ? 2 : 0,
  );
}
