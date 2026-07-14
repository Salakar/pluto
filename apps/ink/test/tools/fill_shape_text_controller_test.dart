import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/fill_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/shape_tool.dart';
import 'package:paper_ink/src/tools/text_tool.dart';
import 'package:paper_ink/src/tools/tool.dart';

void main() {
  group('fill command and options', () {
    test('binding tolerance, gap-close, and grow ranges are enforced', () {
      expect(() => FillOptions(tolerance: 65), throwsRangeError);
      expect(() => FillOptions(gapClose: 5), throwsRangeError);
      expect(() => FillOptions(grow: -5), throwsRangeError);
      expect(FillOptions(tolerance: 64, gapClose: 4, grow: -4).grow, -4);
    });

    test('hatch and dot-screen materials retain deterministic parameters', () {
      final HatchFillStyle hatch = HatchFillStyle(
        colorArgb: 0xff123456,
        spacing: 12,
        angleDegrees: 30,
      );
      final DotScreenFillStyle dots = DotScreenFillStyle(
        colorArgb: 0xffabcdef,
        density: FillDotScreenDensity.bayer8,
      );

      expect(hatch.spacing, 12);
      expect(hatch.angleDegrees, 30);
      expect(dots.density, FillDotScreenDensity.bayer8);
      expect(dots.linesPerInch, 60);
    });

    test('tap snapshots options and active selection clip', () {
      final FillOptions options = FillOptions(
        tolerance: 18,
        gapClose: 2,
        grow: 3,
        sampleSource: FillSampleSource.composite,
        style: SolidFillStyle(0xff445566),
      );
      final FillToolController controller = FillToolController(
        options: options,
      );
      final SelectionMask clip = SelectionMask.filledRect(
        const Rect.fromLTWH(5, 6, 7, 8),
      );

      final FillCommand command = controller.tap(
        seed: const Offset(9, 10),
        activeLayerId: 'paint',
        selectionClip: clip,
      );

      expect(command.options, same(options));
      expect(command.selectionClip, same(clip));
      expect(command.options.sampleSource, FillSampleSource.composite);
      expect(command.usesThresholdedPreview, isTrue);
      expect(command.journalKind, JournalKind.fill);
    });

    test('option copy remains immutable and validates replacements', () {
      final FillOptions first = FillOptions(tolerance: 4);
      final FillOptions second = first.copyWith(tolerance: 12, grow: 2);

      expect(first.tolerance, 4);
      expect(first.grow, 0);
      expect(second.tolerance, 12);
      expect(second.grow, 2);
      expect(() => first.copyWith(gapClose: -1), throwsRangeError);
    });
  });

  group('shape fitting', () {
    test('perfected line snaps its angle to fifteen degrees', () {
      final double angle = 20 * math.pi / 180;
      final ShapeGeometry geometry = fitShape(
        start: Offset.zero,
        end: Offset(math.cos(angle) * 100, math.sin(angle) * 100),
        options: ShapeOptions(kind: ShapeKind.line),
        perfected: true,
      );

      final LineShapeGeometry line = geometry as LineShapeGeometry;
      expect(
        math.atan2(line.end.dy, line.end.dx),
        closeTo(15 * math.pi / 180, 1e-12),
      );
      expect(line.end.distance, closeTo(100, 1e-9));
    });

    test('perfected near-circle ellipse becomes an exact circle', () {
      final EllipseShapeGeometry ellipse =
          fitShape(
                start: Offset.zero,
                end: const Offset(100, 94),
                options: ShapeOptions(kind: ShapeKind.ellipse),
                perfected: true,
              )
              as EllipseShapeGeometry;

      expect(ellipse.isCircle, isTrue);
      expect(ellipse.rect, const Rect.fromLTWH(0, 0, 100, 100));
    });

    test('perfected ellipse outside eight percent remains elliptical', () {
      final EllipseShapeGeometry ellipse =
          fitShape(
                start: Offset.zero,
                end: const Offset(100, 80),
                options: ShapeOptions(kind: ShapeKind.ellipse),
                perfected: true,
              )
              as EllipseShapeGeometry;

      expect(ellipse.isCircle, isFalse);
      expect(ellipse.rect.size, const Size(100, 80));
    });

    test('from-center rectangle expands around its first point', () {
      final RectangleShapeGeometry rectangle =
          fitShape(
                start: const Offset(50, 50),
                end: const Offset(60, 70),
                options: ShapeOptions(
                  kind: ShapeKind.rectangle,
                  fromCenter: true,
                ),
              )
              as RectangleShapeGeometry;

      expect(rectangle.rect, const Rect.fromLTWH(40, 30, 20, 40));
    });

    test('polygon-N emits the selected number of immutable vertices', () {
      final PolygonShapeGeometry polygon =
          fitShape(
                start: Offset.zero,
                end: const Offset(100, 100),
                options: ShapeOptions(kind: ShapeKind.polygon, polygonSides: 7),
              )
              as PolygonShapeGeometry;

      expect(polygon.vertices.length, 7);
      expect(() => polygon.vertices.add(Offset.zero), throwsUnsupportedError);
    });

    test('arrow geometry includes two finite head strokes', () {
      final ArrowShapeGeometry arrow =
          fitShape(
                start: Offset.zero,
                end: const Offset(100, 0),
                options: ShapeOptions(kind: ShapeKind.arrow),
              )
              as ArrowShapeGeometry;

      expect(arrow.headLeft.dx, lessThan(arrow.end.dx));
      expect(arrow.headRight.dx, lessThan(arrow.end.dx));
      expect(arrow.headLeft.dy, isNot(equals(arrow.headRight.dy)));
    });
  });

  group('shape controller', () {
    test('hold-to-perfect fires at exactly 350 milliseconds at rest', () {
      final ShapeToolController controller = ShapeToolController(
        options: ShapeOptions(kind: ShapeKind.line),
      );
      controller.begin(
        point: Offset.zero,
        timestamp: Duration.zero,
        brush: _brush(),
      );
      controller.update(
        const Offset(100, 20),
        const Duration(milliseconds: 10),
      );

      expect(
        controller.holdThrough(const Duration(milliseconds: 359)).isPerfected,
        isFalse,
      );
      expect(
        controller.holdThrough(const Duration(milliseconds: 360)).isPerfected,
        isTrue,
      );
    });

    test('horizontal line commits despite zero-area Rect bounds', () {
      final ShapeToolController controller = ShapeToolController();
      controller.begin(
        point: Offset.zero,
        timestamp: Duration.zero,
        brush: _brush(),
      );
      controller.update(const Offset(100, 0), const Duration(milliseconds: 1));

      final ShapeCommand command = controller.finish(
        const Duration(milliseconds: 1),
      );

      expect(command.geometry, isA<LineShapeGeometry>());
      expect(command.journalKind, JournalKind.shape);
    });

    test('vertical line commits despite zero-area Rect bounds', () {
      final ShapeToolController controller = ShapeToolController();
      controller.begin(
        point: Offset.zero,
        timestamp: Duration.zero,
        brush: _brush(),
      );
      controller.update(const Offset(0, 100), const Duration(milliseconds: 1));

      expect(
        controller.finish(const Duration(milliseconds: 1)).geometry,
        isA<LineShapeGeometry>(),
      );
    });

    test('shape command retains the exact current brush snapshot', () {
      final ShapeBrushSettings brush = _brush(brushId: 'pencil6b');
      final ShapeToolController controller = ShapeToolController(
        options: ShapeOptions(kind: ShapeKind.rectangle),
      );
      controller.begin(
        point: Offset.zero,
        timestamp: Duration.zero,
        brush: brush,
      );
      controller.update(const Offset(20, 30), const Duration(milliseconds: 1));

      final ShapeCommand command = controller.finish(
        const Duration(milliseconds: 1),
      );

      expect(command.brush, same(brush));
      expect(command.stampsThroughCurrentBrush, isTrue);
    });

    test('timestamps are monotonic and cancel discards the draft', () {
      final ShapeToolController controller = ShapeToolController();
      controller.begin(
        point: Offset.zero,
        timestamp: const Duration(milliseconds: 10),
        brush: _brush(),
      );

      expect(
        () => controller.update(
          const Offset(1, 1),
          const Duration(milliseconds: 9),
        ),
        throwsArgumentError,
      );
      controller.cancel();
      expect(controller.draft, isNull);
    });
  });

  group('text block controller', () {
    test('font size and current color are validated', () {
      expect(() => TextOptions(size: 15), throwsRangeError);
      expect(() => TextOptions(size: 97), throwsRangeError);
      final TextOptions options = TextOptions(
        fontFamily: TextFontFamily.jetBrainsMono,
        size: 48,
        weight: InkTextWeight.extraBold,
        colorArgb: 0xff123456,
      );
      expect(options.fontFamily, TextFontFamily.jetBrainsMono);
      expect(options.colorArgb, 0xff123456);
    });

    test('placement captures options and supports keyboard text updates', () {
      final TextOptions options = TextOptions(colorArgb: 0xff987654);
      final TextToolController controller = TextToolController(
        options: options,
      );

      final TextBlockDraft placed = controller.place(
        point: const Offset(20, 30),
        width: 200,
      );
      final TextBlockDraft edited = controller.updateText('paper notes');

      expect(placed.options, same(options));
      expect(edited.text, 'paper notes');
      expect(edited.bounds.topLeft, const Offset(20, 30));
    });

    test('draft can be dragged and corner-resized before commit', () {
      final TextToolController controller = TextToolController();
      controller.place(point: const Offset(10, 20), width: 200, height: 80);
      controller.dragBy(const Offset(5, -5));

      final TextBlockDraft resized = controller.resize(
        TextResizeHandle.bottomRight,
        const Offset(300, 200),
      );

      expect(resized.bounds.topLeft, const Offset(15, 15));
      expect(resized.bounds.bottomRight, const Offset(300, 200));
    });

    test('low-third block computes a static keyboard-occlusion pan', () {
      expect(
        textKeyboardAutoPan(
          blockInViewport: const Rect.fromLTWH(100, 700, 200, 100),
          viewportBounds: const Rect.fromLTWH(0, 0, 600, 1000),
          keyboardTop: 600,
          margin: 16,
        ),
        const Offset(0, -216),
      );
    });

    test('visible block does not pan when keyboard opens', () {
      expect(
        textKeyboardAutoPan(
          blockInViewport: const Rect.fromLTWH(100, 100, 200, 100),
          viewportBounds: const Rect.fromLTWH(0, 0, 600, 1000),
          keyboardTop: 600,
        ),
        Offset.zero,
      );
    });

    test('commit rasterizes with typed text journal metadata', () {
      final TextToolController controller = TextToolController(
        options: TextOptions(
          fontFamily: TextFontFamily.jetBrainsMono,
          size: 40,
          weight: InkTextWeight.bold,
          colorArgb: 0xff112233,
        ),
      );
      controller.place(point: const Offset(8, 9));
      controller.updateText('hello');

      final TextCommitCommand command = controller.commit(activeLayerId: 'L1');

      expect(command.journalKind, JournalKind.text);
      expect(command.rasterizeAtCommit, isTrue);
      expect(command.metadata.fontFamily, TextFontFamily.jetBrainsMono);
      expect(command.metadata.toJson()['weight'], 700);
      expect(controller.draft, isNull);
    });

    test('undo restores the last committed block for editing', () {
      final TextToolController controller = TextToolController();
      controller.place(point: Offset.zero);
      controller.updateText('undo me');
      controller.commit(activeLayerId: 'L1');

      expect(controller.restoreLastCommitForEditing(), isTrue);
      expect(controller.draft!.text, 'undo me');
      expect(controller.dryBlockTapMessage, contains('undo to edit'));
    });

    test('empty text cannot silently commit', () {
      final TextToolController controller = TextToolController();
      controller.place(point: Offset.zero);

      expect(() => controller.commit(activeLayerId: 'L1'), throwsArgumentError);
    });
  });
}

ShapeBrushSettings _brush({String brushId = 'fineliner'}) => ShapeBrushSettings(
  brushId: brushId,
  colorArgb: 0xff123456,
  size: 4,
  seed: 42,
);
