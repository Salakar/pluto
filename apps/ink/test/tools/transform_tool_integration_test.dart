import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/tool.dart';
import 'package:paper_ink/src/tools/transform_tool.dart';
import 'package:paper_ink/src/ui/canvas_view.dart';

void main() {
  group('TransformToolController integration', () {
    test('selection handle drag settles and commits the resized target', () {
      final TransformToolController controller = TransformToolController(
        lockAspect: false,
      );
      final SelectionMask mask = SelectionMask.filledRect(
        const Rect.fromLTWH(10, 20, 10, 10),
      );
      controller.begin(
        activeLayerId: 'layer-1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 80),
        selection: mask,
      );

      controller.beginHandleDrag(
        TransformHandle.bottomRight,
        mask.bounds.bottomRight,
      );
      final TransformPreviewCommand moving = controller.updateHandleDrag(
        const Offset(40, 40),
      );
      final TransformPreviewCommand settled = controller.endDrag();
      final TransformCommitCommand command = controller.commit();

      expect(moving.snapshot.bounds, const Rect.fromLTWH(10, 20, 30, 20));
      expect(moving.snapshot.resampling, TransformResampling.nearest);
      expect(settled.snapshot.resampling, TransformResampling.bilinear);
      expect(command.snapshot.bounds, moving.snapshot.bounds);
      expect(command.snapshot.target, isA<SelectionTransformTarget>());
      expect(
        (command.snapshot.target as SelectionTransformTarget).mask,
        same(mask),
      );
      expect(command.snapshot.resampling, TransformResampling.bilinear);
      expect(command.journalKind, JournalKind.floatCommit);
      expect(controller.activeHandle, isNull);
      expect(controller.hasLiveState, isFalse);
    });

    test('canvas-sized wand masks are trimmed before transform begin', () {
      final Uint8List coverage = Uint8List(12 * 10);
      for (var y = 4; y < 7; y += 1) {
        for (var x = 3; x < 8; x += 1) {
          coverage[y * 12 + x] = 255;
        }
      }
      final SelectionMask canvasMask = SelectionMask(
        left: 0,
        top: 0,
        width: 12,
        height: 10,
        coverage: coverage,
      );

      final SelectionMask trimmed = trimSelectionMaskForTransform(canvasMask);
      final TransformSnapshot snapshot = TransformToolController().begin(
        activeLayerId: 'layer-1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 12, 10),
        selection: trimmed,
      );

      expect(trimmed.bounds, const Rect.fromLTWH(3, 4, 5, 3));
      expect(trimmed.coverageAt(3, 4), 255);
      expect(trimmed.coverageAt(7, 6), 255);
      expect(snapshot.target.sourceBounds, trimmed.bounds);
      expect(snapshot.bounds, trimmed.bounds);
    });

    test('body drag accumulates translation before whole-layer commit', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'layer-2',
        activeLayerBounds: const Rect.fromLTWH(5, 6, 20, 10),
      );

      final TransformPreviewCommand first = controller.translateBy(
        const Offset(3, -2),
      );
      final TransformPreviewCommand second = controller.translateBy(
        const Offset(-1, 5),
      );
      controller.endDrag();
      final TransformCommitCommand command = controller.commit();

      expect(first.snapshot.bounds, const Rect.fromLTWH(8, 4, 20, 10));
      expect(second.snapshot.bounds, const Rect.fromLTWH(7, 9, 20, 10));
      expect(command.snapshot.bounds, second.snapshot.bounds);
      expect(command.snapshot.target, isA<WholeLayerTransformTarget>());
      expect(command.snapshot.target.layerId, 'layer-2');
      expect(command.snapshot.resampling, TransformResampling.bilinear);
      expect(command.journalKind, JournalKind.floatCommit);
      expect(controller.snapshot, isNull);
    });

    test('rotation handle detent is retained by the commit command', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'layer-3',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );

      controller.beginHandleDrag(
        TransformHandle.rotateLug,
        const Offset(100, 50),
      );
      controller.updateHandleDrag(const Offset(50, 0));
      controller.endDrag();
      final TransformCommitCommand command = controller.commit();

      expect(command.snapshot.bounds, const Rect.fromLTWH(0, 0, 100, 100));
      expect(command.snapshot.rotationRadians, closeTo(-math.pi / 2, 1e-12));
      expect(command.snapshot.resampling, TransformResampling.bilinear);
      expect(command.journalKind, JournalKind.floatCommit);
    });

    test('dock rotation advances by exactly fifteen degrees', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'layer-3',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );

      final TransformPreviewCommand preview = controller.rotateBy(math.pi / 12);
      final TransformCommitCommand command = controller.commit();

      expect(preview.snapshot.rotationRadians, closeTo(math.pi / 12, 1e-12));
      expect(preview.snapshot.resampling, TransformResampling.bilinear);
      expect(command.snapshot.rotationRadians, closeTo(math.pi / 12, 1e-12));
      expect(command.journalKind, JournalKind.floatCommit);
    });

    test('reset clears an active drag and commits the source transform', () {
      final TransformToolController controller = TransformToolController(
        lockAspect: false,
      );
      const Rect source = Rect.fromLTWH(10, 20, 30, 40);
      controller.begin(activeLayerId: 'layer-4', activeLayerBounds: source);
      controller.beginHandleDrag(TransformHandle.topLeft, source.topLeft);
      controller.updateHandleDrag(const Offset(5, 10));
      controller.flipHorizontal();
      controller.translateBy(const Offset(9, 7));

      final TransformPreviewCommand reset = controller.reset();
      final TransformCommitCommand command = controller.commit();

      expect(reset.snapshot.bounds, source);
      expect(reset.snapshot.rotationRadians, 0);
      expect(reset.snapshot.isFlippedHorizontally, isFalse);
      expect(reset.snapshot.isFlippedVertically, isFalse);
      expect(reset.snapshot.resampling, TransformResampling.bilinear);
      expect(controller.activeHandle, isNull);
      expect(command.snapshot.bounds, source);
      expect(command.snapshot.rotationRadians, 0);
      expect(command.snapshot.isFlippedHorizontally, isFalse);
      expect(command.snapshot.isFlippedVertically, isFalse);
      expect(command.journalKind, JournalKind.floatCommit);
    });

    test('cancel discards the live target without producing a commit', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'layer-5',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 16, 12),
      );
      controller.translateBy(const Offset(4, 8));

      controller.cancel();

      expect(controller.snapshot, isNull);
      expect(controller.activeHandle, isNull);
      expect(controller.hasLiveState, isFalse);
      expect(controller.commit, throwsStateError);
    });
  });
}
