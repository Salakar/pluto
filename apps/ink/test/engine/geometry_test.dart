import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/engine/geometry.dart';

void main() {
  group('angle and scale constraints', () {
    test('normalizes angles into the canonical half-open turn', () {
      expect(normalizeRadians(3 * math.pi), closeTo(-math.pi, 1e-12));
      expect(normalizeRadians(-3 * math.pi), closeTo(-math.pi, 1e-12));
      expect(normalizeRadians(2 * math.pi + 0.3), closeTo(0.3, 1e-12));
      expect(() => normalizeRadians(double.nan), throwsArgumentError);
    });

    test('shortest angular delta crosses the wrap boundary', () {
      final from = 179 * math.pi / 180;
      final to = -179 * math.pi / 180;

      expect(shortestAngularDelta(from, to), closeTo(2 * math.pi / 180, 1e-12));
    });

    test('scale clamps to the binding 10 through 1600 percent range', () {
      expect(constrainCanvasScale(0.001), minimumCanvasScale);
      expect(constrainCanvasScale(50), maximumCanvasScale);
      expect(constrainCanvasScale(2.5), 2.5);
      expect(() => constrainCanvasScale(double.infinity), throwsArgumentError);
    });

    test('100 percent detent uses the strict 0.04 radius', () {
      expect(constrainCanvasScale(0.961), 1);
      expect(constrainCanvasScale(1.039), 1);
      expect(constrainCanvasScale(0.96), 0.96);
      expect(constrainCanvasScale(1.04), 1.04);
      expect(constrainCanvasScale(0.98, snapToUnit: false), 0.98);
    });

    test('quarter turns capture through five degrees', () {
      for (final quarter in <double>[0, math.pi / 2, math.pi, -math.pi / 2]) {
        expect(
          shortestAngularDelta(
            snapRotationToQuarterTurn(quarter + 4.9 * math.pi / 180),
            normalizeRadians(quarter),
          ).abs(),
          lessThan(1e-12),
        );
      }
      final outside = 6 * math.pi / 180;
      expect(snapRotationToQuarterTurn(outside), closeTo(outside, 1e-12));
    });
  });

  group('matrix geometry', () {
    test('point transform round-trips through an assembled inverse', () {
      final matrix = Matrix4.identity()
        ..translateByDouble(17, -9, 0, 1)
        ..rotateZ(0.37)
        ..scaleByDouble(2.25, 2.25, 1, 1);
      const point = Offset(12.25, -7.75);

      final viewport = transformPoint(matrix, point);
      final roundTrip = transformPoint(invertedMatrix(matrix), viewport);

      expect(roundTrip.dx, closeTo(point.dx, 1e-9));
      expect(roundTrip.dy, closeTo(point.dy, 1e-9));
    });

    test('singular transforms are rejected', () {
      final singular = Matrix4.zero();

      expect(() => invertedMatrix(singular), throwsStateError);
    });

    test('transformed bounds include every rotated corner', () {
      final matrix = Matrix4.identity()..rotateZ(math.pi / 2);
      final bounds = transformedBounds(
        matrix,
        const Rect.fromLTWH(0, 0, 20, 10),
      );

      expect(bounds.left, closeTo(-10, 1e-9));
      expect(bounds.top, closeTo(0, 1e-9));
      expect(bounds.width, closeTo(10, 1e-9));
      expect(bounds.height, closeTo(20, 1e-9));
    });

    test('polygon-clipped area rejects rotated AABB corner overlap', () {
      final matrix = Matrix4.identity()
        ..translateByDouble(170, 170, 0, 1)
        ..rotateZ(math.pi / 4);

      expect(
        transformedRectIntersectionArea(
          matrix,
          const Rect.fromLTWH(0, 0, 100, 100),
          const Rect.fromLTWH(0, 0, 100, 100),
        ),
        0,
      );
    });

    test('bounds of an empty point set is empty', () {
      expect(boundsOfPoints(const <Offset>[]), Rect.zero);
    });
  });

  group('tile geometry', () {
    test('tile document rectangles are exactly 256 pixels', () {
      expect(
        tileDocumentRect(const TileKey(2, 3)),
        const Rect.fromLTWH(512, 768, 256, 256),
      );
    });

    test('covering keys do not include a merely touching next tile', () {
      expect(
        tileKeysCoveringRect(
          const Rect.fromLTWH(0, 0, 256, 256),
          const Size(1024, 1024),
        ),
        const <TileKey>[TileKey(0, 0)],
      );
    });

    test('covering keys are clipped to finite document bounds', () {
      expect(
        tileKeysCoveringRect(
          const Rect.fromLTRB(-100, -100, 600, 300),
          const Size(512, 512),
        ),
        const <TileKey>[
          TileKey(0, 0),
          TileKey(1, 0),
          TileKey(0, 1),
          TileKey(1, 1),
        ],
      );
      expect(
        tileKeysCoveringRect(
          const Rect.fromLTWH(900, 900, 10, 10),
          const Size(512, 512),
        ),
        isEmpty,
      );
    });

    test('identity viewport returns its one exact tile', () {
      expect(
        visibleTileKeys(
          viewMatrix: Matrix4.identity(),
          viewportSize: const Size(256, 256),
          documentSize: const Size(1024, 1024),
        ),
        const <TileKey>[TileKey(0, 0)],
      );
    });

    test('translated viewport returns four partially intersected tiles', () {
      final matrix = Matrix4.identity()..translateByDouble(-128, -128, 0, 1);

      expect(
        visibleTileKeys(
          viewMatrix: matrix,
          viewportSize: const Size(300, 300),
          documentSize: const Size(1024, 1024),
        ).toSet(),
        <TileKey>{
          const TileKey(0, 0),
          const TileKey(1, 0),
          const TileKey(0, 1),
          const TileKey(1, 1),
        },
      );
    });

    test('rotated viewport culls bounding-box-only corner tiles', () {
      final matrix = Matrix4.identity()
        ..translateByDouble(128, -53.0193359838, 0, 1)
        ..rotateZ(math.pi / 4);
      final visible = visibleTileKeys(
        viewMatrix: matrix,
        viewportSize: const Size(256, 256),
        documentSize: const Size(768, 768),
      );

      expect(visible, contains(const TileKey(0, 0)));
      expect(visible.length, lessThan(4));
    });
  });
}
