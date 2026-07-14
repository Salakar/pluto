import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/engine/raster_ops.dart' as raster;
import 'package:paper_ink/src/engine/selection_mask.dart' as engine;
import 'package:paper_ink/src/tools/fill_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart' as tool;
import 'package:paper_ink/src/tools/shape_tool.dart';
import 'package:paper_ink/src/tools/tool_engine_adapter.dart';
import 'package:paper_ink/src/tools/transform_tool.dart';

void main() {
  group('WP5 tool-to-engine adapter', () {
    test('places a document-offset mask into canvas coordinates', () {
      final tool.SelectionMask selection = tool.SelectionMask(
        left: 2,
        top: 1,
        width: 2,
        height: 2,
        coverage: const <int>[10, 20, 30, 40],
      );

      final engine.SelectionMask result = engineSelectionMask(
        selection: selection,
        canvasWidth: 5,
        canvasHeight: 4,
      );

      expect(result.coverageAt(2, 1), 10);
      expect(result.coverageAt(3, 2), 40);
      expect(result.coverageAt(1, 1), 0);
    });

    test('clips offset mask pixels that lie outside the canvas', () {
      final tool.SelectionMask selection = tool.SelectionMask(
        left: -1,
        top: -1,
        width: 2,
        height: 2,
        coverage: const <int>[1, 2, 3, 255],
      );

      final engine.SelectionMask result = engineSelectionMask(
        selection: selection,
        canvasWidth: 2,
        canvasHeight: 2,
      );

      expect(result.coverage, <int>[255, 0, 0, 0]);
    });

    test('worker mask conversion retains every coverage byte', () {
      final engine.SelectionMask source = engine.SelectionMask(
        width: 2,
        height: 2,
        coverage: Uint8List.fromList(<int>[0, 64, 128, 255]),
      );

      final tool.SelectionMask result = toolSelectionMask(source);

      expect(result.bounds, const Rect.fromLTWH(0, 0, 2, 2));
      expect(result.coverageBytes, <int>[0, 64, 128, 255]);
    });

    test('clipboard extraction is tight and multiplies mask coverage', () {
      final raster.RgbaBitmap source = raster.RgbaBitmap.fromColors(
        width: 3,
        height: 1,
        colors: <raster.RgbaColor>[
          raster.RgbaColor.fromArgb(0xffff0000),
          raster.RgbaColor.fromArgb(0xff00ff00),
          raster.RgbaColor.fromArgb(0xff0000ff),
        ],
      );
      final tool.SelectionMask selection = tool.SelectionMask(
        left: 0,
        top: 0,
        width: 3,
        height: 1,
        coverage: const <int>[0, 128, 255],
      );

      final tool.RgbaFragment fragment = extractSelectionFragment(
        source: source,
        selection: selection,
        documentId: 'doc',
        layerId: 'L1',
      );

      expect(fragment.width, 2);
      expect(fragment.source.sourceBounds, const Rect.fromLTWH(1, 0, 2, 1));
      expect(fragment.rgbaBytes, <int>[0, 128, 0, 128, 0, 0, 255, 255]);
    });

    test('clipboard float composites bilinearly and honors mirror scale', () {
      final tool.RgbaFragment fragment = tool.RgbaFragment(
        width: 2,
        height: 1,
        rgba: const <int>[255, 0, 0, 255, 0, 0, 255, 255],
        source: tool.FragmentSourceMetadata(
          documentId: 'doc',
          layerId: 'L1',
          sourceBounds: const Rect.fromLTWH(0, 0, 2, 1),
        ),
      );
      final tool.SelectionFloat floating = tool.SelectionFloat(
        fragment: fragment,
        destinationLayerId: 'L2',
        topLeft: const Offset(1, 0),
        scaleX: -1,
      );

      final raster.RgbaBitmap result = compositeSelectionFloat(
        floatingSelection: floating,
        target: raster.RgbaBitmap.transparent(width: 4, height: 1),
      );

      expect(result.colorAt(1, 0).argb, 0xff0000ff);
      expect(result.colorAt(2, 0).argb, 0xffff0000);
      expect(result.colorAt(0, 0).alpha, 0);
      expect(result.colorAt(3, 0).alpha, 0);
    });

    test('wand request executes contiguous four-way region math', () {
      final raster.RgbaColor black = raster.RgbaColor.fromArgb(0xff000000);
      final raster.RgbaColor white = raster.RgbaColor.fromArgb(0xffffffff);
      final raster.RgbaBitmap source = raster.RgbaBitmap.fromColors(
        width: 3,
        height: 2,
        colors: <raster.RgbaColor>[black, black, white, white, black, white],
      );
      final tool.WandSelectionRequest request = tool.WandSelectionRequest(
        seed: const Offset(0.5, 0.5),
        layerId: 'L1',
        tolerance: 0,
        gapClose: 0,
        combine: tool.SelectionCombineMode.replace,
      );

      final tool.SelectionMask result = executeWandSelection(
        request: request,
        source: source,
      );

      expect(result.coverageBytes, <int>[255, 255, 0, 0, 255, 0]);
    });

    test('rectangle request rasterizes its integer pixel extent', () {
      final tool.RectangleSelectionRequest request =
          tool.RectangleSelectionRequest(
            rect: const Rect.fromLTRB(1.2, 2.1, 3.8, 4.2),
            combine: tool.SelectionCombineMode.replace,
          );

      final tool.SelectionMask result = executeRectangleSelection(request);

      expect(result.bounds, const Rect.fromLTWH(1, 2, 3, 3));
      expect(result.coverageBytes, everyElement(255));
    });

    test('lasso request uses pixel-center even-odd coverage', () {
      final tool.LassoSelectionRequest request = tool.LassoSelectionRequest(
        points: const <Offset>[Offset(0, 0), Offset(4, 0), Offset(0, 4)],
        combine: tool.SelectionCombineMode.replace,
      );

      final tool.SelectionMask result = executeLassoSelection(request);

      expect(result.coverageAt(0, 0), 255);
      expect(result.coverageAt(1, 1), 255);
      expect(result.coverageAt(3, 3), 0);
      expect(result.coverageAt(2, 0), 255);
    });

    test('fill command maps solid style and active selection clip', () {
      final raster.RgbaBitmap target = raster.RgbaBitmap.solid(
        width: 3,
        height: 1,
        color: raster.RgbaColor.fromArgb(0xffffffff),
      );
      final FillCommand command = FillCommand(
        seed: const Offset(0.5, 0.5),
        activeLayerId: 'L1',
        options: FillOptions(style: SolidFillStyle(0xff000000)),
        selectionClip: tool.SelectionMask(
          left: 1,
          top: 0,
          width: 1,
          height: 1,
          coverage: const <int>[255],
        ),
      );

      final raster.RgbaBitmap result = executeFill(
        command: command,
        activeLayer: target,
      );

      expect(result.colorAt(0, 0).argb, 0xffffffff);
      expect(result.colorAt(1, 0).argb, 0xff000000);
      expect(result.colorAt(2, 0).argb, 0xffffffff);
    });

    test('composite fill option requires an explicit composite bitmap', () {
      final FillCommand command = FillCommand(
        seed: const Offset(0.5, 0.5),
        activeLayerId: 'L1',
        options: FillOptions(sampleSource: FillSampleSource.composite),
      );

      expect(
        () => executeFill(
          command: command,
          activeLayer: raster.RgbaBitmap.transparent(width: 1, height: 1),
        ),
        throwsArgumentError,
      );
    });

    test('nearest transform preview places exact pixels during drag', () {
      final raster.RgbaBitmap source = raster.RgbaBitmap.solid(
        width: 1,
        height: 1,
        color: raster.RgbaColor.fromArgb(0xffff0000),
      );
      final TransformSnapshot snapshot = TransformSnapshot(
        target: WholeLayerTransformTarget(
          layerId: 'L1',
          bounds: const Rect.fromLTWH(0, 0, 1, 1),
        ),
        bounds: const Rect.fromLTWH(2, 1, 1, 1),
        rotationRadians: 0,
        resampling: TransformResampling.nearest,
      );

      final raster.RgbaBitmap result = executeTransform(
        snapshot: snapshot,
        source: source,
        destinationWidth: 4,
        destinationHeight: 3,
      );

      expect(result.colorAt(2, 1).argb, 0xffff0000);
      expect(result.colorAt(0, 0).alpha, 0);
    });

    test('transform adapter reflects pixels around destination center', () {
      final raster.RgbaBitmap source = raster.RgbaBitmap.fromColors(
        width: 2,
        height: 1,
        colors: <raster.RgbaColor>[
          raster.RgbaColor.fromArgb(0xffff0000),
          raster.RgbaColor.fromArgb(0xff0000ff),
        ],
      );
      final TransformSnapshot snapshot = TransformSnapshot(
        target: WholeLayerTransformTarget(
          layerId: 'L1',
          bounds: const Rect.fromLTWH(0, 0, 2, 1),
        ),
        bounds: const Rect.fromLTWH(0, 0, 2, 1),
        rotationRadians: 0,
        resampling: TransformResampling.nearest,
        isFlippedHorizontally: true,
      );

      final raster.RgbaBitmap result = executeTransform(
        snapshot: snapshot,
        source: source,
        destinationWidth: 2,
        destinationHeight: 1,
      );

      expect(result.colorAt(0, 0).argb, 0xff0000ff);
      expect(result.colorAt(1, 0).argb, 0xffff0000);
    });

    test('arrow geometry becomes three disconnected brush contours', () {
      const ArrowShapeGeometry arrow = ArrowShapeGeometry(
        start: Offset(0, 0),
        end: Offset(10, 0),
        headLeft: Offset(7, -3),
        headRight: Offset(7, 3),
      );

      final List<List<Offset>> contours = shapeBrushContours(arrow);

      expect(contours, hasLength(3));
      expect(contours[0], const <Offset>[Offset(0, 0), Offset(10, 0)]);
      expect(contours[1], const <Offset>[Offset(10, 0), Offset(7, -3)]);
      expect(contours[2], const <Offset>[Offset(10, 0), Offset(7, 3)]);
    });

    test('ellipse contour is closed at a deterministic sample count', () {
      final List<Offset> contour = shapeBrushContours(
        const EllipseShapeGeometry(Rect.fromLTWH(2, 4, 10, 6)),
        ellipseSegments: 24,
      ).single;

      expect(contour, hasLength(25));
      expect(contour.first.dx, closeTo(12, 1e-10));
      expect(contour.first.dy, closeTo(7, 1e-10));
      expect(contour.last.dx, closeTo(contour.first.dx, 1e-10));
      expect(contour.last.dy, closeTo(contour.first.dy, 1e-10));
    });

    test('polygon contour repeats its first vertex for closure', () {
      final PolygonShapeGeometry polygon = PolygonShapeGeometry(const <Offset>[
        Offset(0, 0),
        Offset(4, 0),
        Offset(2, 3),
      ]);

      final List<Offset> contour = shapeBrushContours(polygon).single;

      expect(contour, hasLength(4));
      expect(contour.last, contour.first);
    });

    test('shape execution emits resolved stamps through current brush', () {
      final RecordingBrushStampTarget target = RecordingBrushStampTarget();
      final ShapeCommand command = ShapeCommand(
        geometry: const LineShapeGeometry(
          start: Offset(2, 2),
          end: Offset(20, 2),
        ),
        brush: ShapeBrushSettings(
          brushId: finelinerBrush.id,
          colorArgb: 0xff123456,
          size: 4,
          seed: 7,
        ),
      );

      final Rect damage = stampShapeThroughBrush(
        command: command,
        brush: finelinerBrush,
        target: target,
      );

      expect(damage.isEmpty, isFalse);
      expect(target.stamps, isNotEmpty);
      expect(
        target.stamps.every((stamp) => stamp.colorArgb == 0xff123456),
        isTrue,
      );
    });

    test('shape execution rejects a brush different from metadata', () {
      final ShapeCommand command = ShapeCommand(
        geometry: const LineShapeGeometry(
          start: Offset.zero,
          end: Offset(5, 5),
        ),
        brush: ShapeBrushSettings(
          brushId: 'not-fineliner',
          colorArgb: 0xff000000,
          size: 4,
          seed: 1,
        ),
      );

      expect(
        () => stampShapeThroughBrush(
          command: command,
          brush: finelinerBrush,
          target: RecordingBrushStampTarget(),
        ),
        throwsArgumentError,
      );
    });
  });
}
