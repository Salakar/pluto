import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';

void main() {
  group('marker and highlighter overlap caps', () {
    test('pure coverage transition admits only remaining steps', () {
      final first = capStrokeCoverage(
        accumulated: 1.6,
        incoming: 0.75,
        maximumSteps: 2,
      );
      final full = capStrokeCoverage(
        accumulated: first.accumulated,
        incoming: 1,
        maximumSteps: 2,
      );

      expect(first.accepted, closeTo(0.4, 1e-12));
      expect(first.accumulated, 2);
      expect(full.accepted, 0);
      expect(full.accumulated, 2);
    });

    test('marker takes two overlap steps and ignores a third', () {
      final mask = StrokeCoverageMask.forBrush(
        markerBrush,
        width: 1,
        height: 1,
      );
      const white = 0xffffffff;
      const black = 0xff000000;
      final first = _composite(
        markerBrush,
        mask,
        destination: white,
        source: black,
      );
      final second = _composite(
        markerBrush,
        mask,
        destination: first,
        source: black,
      );
      final third = _composite(
        markerBrush,
        mask,
        destination: second,
        source: black,
      );

      expect(argbLumaLatticeLevel(first), lessThan(30));
      expect(
        argbLumaLatticeLevel(second),
        lessThan(argbLumaLatticeLevel(first)),
      );
      expect(third, second);
      expect(mask.coverageAt(0, 0), 2);
    });

    test('partial marker edges accumulate without exceeding two', () {
      final mask = StrokeCoverageMask.forBrush(
        markerBrush,
        width: 1,
        height: 1,
      );

      for (var pass = 0; pass < 10; pass += 1) {
        mask.takeCoverage(0, 0, 0.3);
      }

      expect(mask.coverageAt(0, 0), closeTo(2, 1e-12));
      expect(mask.takeCoverage(0, 0, 0.5), 0);
    });

    test('highlighter accepts one overlap step only', () {
      final mask = StrokeCoverageMask.forBrush(
        highlighterBrush,
        width: 1,
        height: 1,
      );
      final first = _composite(
        highlighterBrush,
        mask,
        destination: 0xffffffff,
        source: defaultHighlighterColorArgb,
      );
      final second = _composite(
        highlighterBrush,
        mask,
        destination: first,
        source: defaultHighlighterColorArgb,
      );

      expect(first, isNot(0xffffffff));
      expect(second, first);
      expect(mask.coverageAt(0, 0), 1);
    });

    test('highlighter rejects arbitrary colors in favor of its sub-row', () {
      expect(
        resolveBrushColor(highlighterBrush, 0xffff0000),
        defaultHighlighterColorArgb,
      );
      for (final color in highlighterColorsArgb) {
        expect(resolveBrushColor(highlighterBrush, color), color);
      }
      expect(resolveBrushColor(markerBrush, 0xffff0000), 0xffff0000);
    });

    test(
      'highlighter cannot darken a light destination below level twelve',
      () {
        final channel = latticeLevelToSrgbChannel(12);
        final destination = 0xff000000 | channel << 16 | channel << 8 | channel;
        final mask = StrokeCoverageMask.forBrush(
          highlighterBrush,
          width: 1,
          height: 1,
        );
        final result = _composite(
          highlighterBrush,
          mask,
          destination: destination,
          source: defaultHighlighterColorArgb,
        );

        expect(argbLumaLatticeLevel(result), greaterThanOrEqualTo(12));
      },
    );

    test('highlighter leaves already-dark destinations unchanged', () {
      final channel = latticeLevelToSrgbChannel(5);
      final destination = 0xff000000 | channel << 16 | channel << 8 | channel;
      final mask = StrokeCoverageMask.forBrush(
        highlighterBrush,
        width: 1,
        height: 1,
      );

      expect(
        _composite(
          highlighterBrush,
          mask,
          destination: destination,
          source: defaultHighlighterColorArgb,
        ),
        destination,
      );
    });

    test('coverage masks are document aligned and ignore outside pixels', () {
      final mask = StrokeCoverageMask(
        width: 2,
        height: 3,
        maximumSteps: 2,
        originX: 10,
        originY: -4,
      );

      expect(mask.takeCoverage(10, -4, 1), 1);
      expect(mask.coverageAt(10, -4), 1);
      expect(mask.takeCoverage(9, -4, 1), 0);
      expect(mask.takeCoverage(12, -4, 1), 0);
    });
  });
}

int _composite(
  BrushSpec brush,
  StrokeCoverageMask mask, {
  required int destination,
  required int source,
}) => compositeCappedOverlapPixel(
  brush: brush,
  coverageMask: mask,
  documentX: 0,
  documentY: 0,
  destinationArgb: destination,
  requestedSourceArgb: source,
  coverage: 1,
);
