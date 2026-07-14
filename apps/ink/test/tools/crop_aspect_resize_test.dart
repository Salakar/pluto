import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/crop_tool.dart';

void main() {
  group('aspect-preserving crop handle resize', () {
    test(
      'corner handles preserve their opposite corner and stay in artwork',
      () {
        const Rect artworkBounds = Rect.fromLTWH(0, 0, 100, 110);
        final Map<CropHandle, ({Offset point, Rect expected})> cases =
            <CropHandle, ({Offset point, Rect expected})>{
              CropHandle.topLeft: (
                point: const Offset(5, 20),
                expected: const Rect.fromLTRB(5, 15, 80, 90),
              ),
              CropHandle.topRight: (
                point: const Offset(110, 20),
                expected: const Rect.fromLTRB(20, 10, 100, 90),
              ),
              CropHandle.bottomLeft: (
                point: const Offset(-10, 105),
                expected: const Rect.fromLTRB(0, 30, 80, 110),
              ),
              CropHandle.bottomRight: (
                point: const Offset(110, 120),
                expected: const Rect.fromLTRB(20, 30, 100, 110),
              ),
            };

        for (final MapEntry<CropHandle, ({Offset point, Rect expected})> entry
            in cases.entries) {
          final CropToolController controller = _controllerWithDraft(
            artworkBounds: artworkBounds,
            cropRect: const Rect.fromLTRB(20, 30, 80, 90),
          );
          controller.beginHandleDrag(entry.key);

          final CropDraft draft = controller.updateHandleDrag(
            entry.value.point,
            preserveAspect: true,
          );

          expect(draft.cropRect, entry.value.expected, reason: entry.key.name);
          expect(draft.cropRect.width / draft.cropRect.height, 1);
          _expectInside(artworkBounds, draft.cropRect);
        }
      },
    );

    test('edge handles center the perpendicular span and clamp to artwork', () {
      const Rect artworkBounds = Rect.fromLTWH(0, 0, 100, 100);
      final Map<CropHandle, ({Offset point, Rect expected})> cases =
          <CropHandle, ({Offset point, Rect expected})>{
            CropHandle.topCenter: (
              point: const Offset(50, 0),
              expected: const Rect.fromLTRB(0, 10, 100, 60),
            ),
            CropHandle.bottomCenter: (
              point: const Offset(50, 100),
              expected: const Rect.fromLTRB(0, 30, 100, 80),
            ),
            CropHandle.middleLeft: (
              point: const Offset(-20, 45),
              expected: const Rect.fromLTRB(0, 25, 80, 65),
            ),
            CropHandle.middleRight: (
              point: const Offset(120, 45),
              expected: const Rect.fromLTRB(20, 25, 100, 65),
            ),
          };

      for (final MapEntry<CropHandle, ({Offset point, Rect expected})> entry
          in cases.entries) {
        final CropToolController controller = _controllerWithDraft(
          artworkBounds: artworkBounds,
          cropRect: const Rect.fromLTRB(20, 30, 80, 60),
        );
        controller.beginHandleDrag(entry.key);

        final CropDraft draft = controller.updateHandleDrag(
          entry.value.point,
          preserveAspect: true,
        );

        expect(draft.cropRect, entry.value.expected, reason: entry.key.name);
        expect(draft.cropRect.width / draft.cropRect.height, 2);
        _expectInside(artworkBounds, draft.cropRect);
      }
    });

    test('unconstrained resize remains the default', () {
      final CropToolController controller = _controllerWithDraft(
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 100),
        cropRect: const Rect.fromLTRB(20, 30, 80, 60),
      );
      controller.beginHandleDrag(CropHandle.bottomRight);

      final CropDraft draft = controller.updateHandleDrag(const Offset(90, 95));

      expect(draft.cropRect, const Rect.fromLTRB(20, 30, 90, 95));
    });

    test('fractional aspect remains inside bounds at a limiting edge', () {
      const Rect artworkBounds = Rect.fromLTWH(0, 0, 100, 100);
      final CropToolController controller = _controllerWithDraft(
        artworkBounds: artworkBounds,
        cropRect: const Rect.fromLTRB(10, 10, 80, 40),
      );
      controller.beginHandleDrag(CropHandle.bottomRight);

      final CropDraft draft = controller.updateHandleDrag(
        const Offset(100, 100),
        preserveAspect: true,
      );

      _expectInside(artworkBounds, draft.cropRect);
      expect(
        draft.cropRect.width / draft.cropRect.height,
        closeTo(7 / 3, 1e-12),
      );
    });
  });
}

CropToolController _controllerWithDraft({
  required Rect artworkBounds,
  required Rect cropRect,
}) {
  final CropToolController controller = CropToolController();
  controller.beginDrag(point: cropRect.topLeft, artworkBounds: artworkBounds);
  controller.updateDrag(cropRect.bottomRight);
  controller.endDrag();
  return controller;
}

void _expectInside(Rect outer, Rect inner) {
  expect(inner.left, greaterThanOrEqualTo(outer.left));
  expect(inner.top, greaterThanOrEqualTo(outer.top));
  expect(inner.right, lessThanOrEqualTo(outer.right));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
}
