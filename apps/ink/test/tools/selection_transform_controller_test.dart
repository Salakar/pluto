import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/fill_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/tool.dart';
import 'package:paper_ink/src/tools/transform_tool.dart';

void main() {
  group('tool union and layer gate', () {
    test('canonical tool identifiers are complete and unique', () {
      expect(inkTools.map((Tool tool) => tool.id).toSet().length, 11);
      expect(
        inkTools.map((Tool tool) => tool.id),
        containsAll(<String>[
          'draw',
          'erase',
          'select',
          'transform',
          'fill',
          'shape',
          'text',
          'picker',
          'guides',
          'reference',
          'crop',
        ]),
      );
    });

    test('controller activation does not manufacture live state', () {
      final FillToolController controller = FillToolController();

      controller.activate();
      expect(controller.isActive, isTrue);
      expect(controller.hasLiveState, isFalse);

      controller.deactivate();
      expect(controller.isActive, isFalse);
    });

    test('locked layer is blocked with canonical feedback', () {
      final FillToolController controller = FillToolController();
      final ToolActionResult<_FakeCommand> result = controller
          .gateLayerAction<_FakeCommand>(
            isLayerVisible: true,
            isLayerLocked: true,
            createCommand: _FakeCommand.new,
          );

      expect(result, isA<BlockedToolAction<_FakeCommand>>());
      expect(
        (result as BlockedToolAction<_FakeCommand>).message,
        'layer locked',
      );
    });

    test(
      'hidden layer takes precedence and placement may bypass only lock',
      () {
        final FillToolController controller = FillToolController();
        final ToolActionResult<_FakeCommand> hidden = controller
            .gateLayerAction<_FakeCommand>(
              isLayerVisible: false,
              isLayerLocked: true,
              bypassLock: true,
              createCommand: _FakeCommand.new,
            );
        final ToolActionResult<_FakeCommand> placement = controller
            .gateLayerAction<_FakeCommand>(
              isLayerVisible: true,
              isLayerLocked: true,
              bypassLock: true,
              createCommand: _FakeCommand.new,
            );

        expect(
          (hidden as BlockedToolAction<_FakeCommand>).reason,
          ToolActionBlockReason.layerHidden,
        );
        expect(placement, isA<AllowedToolAction<_FakeCommand>>());
      },
    );
  });

  group('static selection mask', () {
    test('coverage lookup is offset and defensive', () {
      final List<int> source = <int>[0, 64, 128, 255];
      final SelectionMask mask = SelectionMask(
        left: 10,
        top: 20,
        width: 2,
        height: 2,
        coverage: source,
      );
      source[3] = 0;
      final Uint8List exported = mask.coverageBytes;
      exported[3] = 0;

      expect(mask.coverageAt(11, 21), 255);
      expect(mask.coverageAt(9, 20), 0);
      expect(mask.containsDocumentPoint(const Offset(11.5, 21.5)), isTrue);
    });

    test('canvas export clips negative mask origin', () {
      final SelectionMask mask = SelectionMask(
        left: -1,
        top: -1,
        width: 3,
        height: 3,
        coverage: List<int>.filled(9, 255),
      );

      expect(
        mask.toCanvasCoverage(3, 2),
        Uint8List.fromList(<int>[255, 255, 0, 255, 255, 0]),
      );
    });

    test('add unions masks in document coordinates', () {
      final SelectionMask left = SelectionMask.filledRect(
        const Rect.fromLTWH(0, 0, 2, 1),
      );
      final SelectionMask right = SelectionMask.filledRect(
        const Rect.fromLTWH(1, 0, 2, 1),
      );

      final SelectionMask combined = left.combine(
        right,
        SelectionCombineMode.add,
      );

      expect(combined.bounds, const Rect.fromLTWH(0, 0, 3, 1));
      expect(combined.coverageBytes, Uint8List.fromList(<int>[255, 255, 255]));
    });

    test('subtract removes only incoming coverage', () {
      final SelectionMask base = SelectionMask.filledRect(
        const Rect.fromLTWH(4, 5, 3, 1),
      );
      final SelectionMask hole = SelectionMask.filledRect(
        const Rect.fromLTWH(5, 5, 1, 1),
      );

      final SelectionMask combined = base.combine(
        hole,
        SelectionCombineMode.subtract,
      );

      expect(combined.coverageAt(4, 5), 255);
      expect(combined.coverageAt(5, 5), 0);
      expect(combined.coverageAt(6, 5), 255);
    });

    test('mask dimensions and coverage length are validated', () {
      expect(
        () => SelectionMask(
          left: 0,
          top: 0,
          width: 2,
          height: 2,
          coverage: const <int>[1],
        ),
        throwsArgumentError,
      );
      expect(() => SelectionMask.filledRect(Rect.zero), throwsArgumentError);
    });
  });

  group('selection lifecycle and clipboard', () {
    test('worker result honors request combine mode', () {
      final SelectionToolController controller = SelectionToolController();
      controller.applyMask(
        SelectionMask.filledRect(const Rect.fromLTWH(0, 0, 2, 2)),
      );
      controller.setOptions(
        controller.options.copyWith(combine: SelectionCombineMode.add),
      );
      final RectangleSelectionRequest request = controller.requestRectangle(
        const Rect.fromLTWH(2, 0, 2, 2),
      );

      controller.completeRequest(
        request,
        SelectionMask.filledRect(request.rect),
      );

      expect(controller.mask!.bounds, const Rect.fromLTWH(0, 0, 4, 2));
      expect(controller.pendingRequest, isNull);
    });

    test('wand request carries binding tolerance and gap close', () {
      final SelectionToolController controller = SelectionToolController(
        options: SelectionOptions(
          mode: SelectionMode.wand,
          wandTolerance: 64,
          wandGapClose: 4,
        ),
      );

      final WandSelectionRequest request = controller.requestWand(
        const Offset(3, 7),
        layerId: 'L1',
      );

      expect(request.tolerance, 64);
      expect(request.gapClose, 4);
      expect(request.layerId, 'L1');
    });

    test('tool, layer, and panel switches preserve the clipping mask', () {
      final SelectionToolController controller = SelectionToolController();
      final SelectionMask mask = SelectionMask.filledRect(
        const Rect.fromLTWH(1, 2, 3, 4),
      );
      controller.applyMask(mask);

      controller.handleToolSwitch();
      controller.handleLayerSwitch('new-layer');
      controller.handlePanelOpen();
      controller.deactivate();

      expect(controller.mask, same(mask));
      expect(controller.hasSelection, isTrue);
    });

    test('paste centers clipboard fragment and enters float state', () {
      final SelectionClipboard clipboard = SelectionClipboard();
      clipboard.write(_fragment(width: 4, height: 2));
      final SelectionToolController controller = SelectionToolController(
        clipboard: clipboard,
      );

      final SelectionFloat? floated = controller.pasteAtViewportCenter(
        viewportCenter: const Offset(100, 80),
        activeLayerId: 'L2',
      );

      expect(floated!.topLeft, const Offset(98, 79));
      expect(floated.destinationLayerId, 'L2');
      expect(controller.mask!.bounds, const Rect.fromLTWH(98, 79, 4, 2));
    });

    test('paste is disabled when the session clipboard is empty', () {
      final SelectionToolController controller = SelectionToolController();

      expect(
        controller.pasteAtViewportCenter(
          viewportCenter: Offset.zero,
          activeLayerId: 'L1',
        ),
        isNull,
      );
      expect(controller.hasLiveState, isFalse);
    });

    test('undo of float movement retains the live float', () {
      final SelectionToolController controller = SelectionToolController();
      final SelectionFloat initial = SelectionFloat(
        fragment: _fragment(),
        destinationLayerId: 'L1',
        topLeft: const Offset(10, 20),
      );
      controller.beginFloat(initial);
      controller.updateFloat(initial.copyWith(topLeft: const Offset(30, 40)));

      expect(controller.undoFloatMove(), isTrue);
      expect(controller.floatingSelection!.topLeft, const Offset(10, 20));
      expect(controller.hasLiveState, isTrue);
    });

    test('canvas tap commits only a live float', () {
      final SelectionToolController controller = SelectionToolController();
      expect(controller.handleCanvasTap(), isNull);
      controller.beginFloat(
        SelectionFloat(
          fragment: _fragment(),
          destinationLayerId: 'L1',
          topLeft: Offset.zero,
        ),
      );

      final FloatCommitCommand command = controller.handleCanvasTap()!;

      expect(command.journalKind, JournalKind.floatCommit);
      expect(controller.floatingSelection, isNull);
    });

    test('cut fills clipboard and emits a masked erase', () {
      final SelectionToolController controller = SelectionToolController();
      controller.applyMask(
        SelectionMask.filledRect(const Rect.fromLTWH(0, 0, 2, 2)),
      );
      final RgbaFragment fragment = _fragment();

      final SelectionClearCommand command = controller.cut(
        fragment,
        layerId: 'L1',
      );

      expect(controller.clipboard.fragment, same(fragment));
      expect(command.journalKind, JournalKind.erase);
      expect(controller.hasSelection, isTrue);
    });

    test(
      'deselect clears mask and any uncommitted float but not clipboard',
      () {
        final SelectionToolController controller = SelectionToolController();
        controller.applyMask(
          SelectionMask.filledRect(const Rect.fromLTWH(0, 0, 2, 2)),
        );
        controller.copy(_fragment());
        controller.beginFloat(
          SelectionFloat(
            fragment: controller.clipboard.fragment!,
            destinationLayerId: 'L1',
            topLeft: Offset.zero,
          ),
        );

        controller.deselect();

        expect(controller.hasLiveState, isFalse);
        expect(controller.clipboard.canPaste, isTrue);
      },
    );

    test('duplicate and flip actions update a live float synchronously', () {
      final SelectionToolController controller = SelectionToolController();
      controller.applyMask(
        SelectionMask.filledRect(const Rect.fromLTWH(0, 0, 2, 2)),
      );

      final SelectionFloatEditCommand duplicate = controller.duplicate(
        _fragment(),
        activeLayerId: 'L1',
      );
      final SelectionFloatEditCommand horizontal = controller
          .flipFloatHorizontal();
      final SelectionFloatEditCommand vertical = controller.flipFloatVertical();

      expect(duplicate.edit, SelectionFloatEdit.duplicate);
      expect(duplicate.floatingSelection.topLeft, const Offset(16, 16));
      expect(horizontal.floatingSelection.scaleX, -1);
      expect(vertical.floatingSelection.scaleY, -1);
    });

    test('to-new-layer keeps the mask and uses layerAdd journal kind', () {
      final SelectionToolController controller = SelectionToolController();
      controller.applyMask(
        SelectionMask.filledRect(const Rect.fromLTWH(2, 3, 4, 5)),
      );

      final SelectionToNewLayerCommand command = controller.toNewLayer(
        sourceLayerId: 'L1',
        newLayerId: 'L2',
      );

      expect(command.mask, same(controller.mask));
      expect(command.journalKind, JournalKind.layerAdd);
    });
  });

  group('transform controller', () {
    test('exposes eight resize handles plus rotate lug', () {
      expect(TransformHandle.values.length, 9);
      expect(TransformHandle.values.last, TransformHandle.rotateLug);
    });

    test('no selection targets the whole active layer', () {
      final TransformToolController controller = TransformToolController();

      final TransformSnapshot snapshot = controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(10, 20, 80, 40),
      );

      expect(snapshot.target, isA<WholeLayerTransformTarget>());
      expect(snapshot.bounds, const Rect.fromLTWH(10, 20, 80, 40));
    });

    test('active selection takes precedence over whole-layer bounds', () {
      final TransformToolController controller = TransformToolController();
      final SelectionMask mask = SelectionMask.filledRect(
        const Rect.fromLTWH(20, 30, 10, 12),
      );

      final TransformSnapshot snapshot = controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 100),
        selection: mask,
      );

      expect(snapshot.target, isA<SelectionTransformTarget>());
      expect(snapshot.bounds, mask.bounds);
    });

    test('drag uses nearest and rest uses bilinear resampling', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 50),
      );
      controller.beginHandleDrag(
        TransformHandle.bottomRight,
        const Offset(100, 50),
      );

      final TransformPreviewCommand moving = controller.updateHandleDrag(
        const Offset(200, 100),
      );
      final TransformPreviewCommand resting = controller.endDrag();

      expect(moving.snapshot.resampling, TransformResampling.nearest);
      expect(resting.snapshot.resampling, TransformResampling.bilinear);
    });

    test('default resize preserves source aspect ratio', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 50),
      );
      controller.beginHandleDrag(
        TransformHandle.bottomRight,
        const Offset(100, 50),
      );

      final Rect bounds = controller
          .updateHandleDrag(const Offset(200, 80))
          .snapshot
          .bounds;

      expect(bounds.width / bounds.height, closeTo(2, 1e-12));
    });

    test('rotate lug captures the nearest 15-degree detent', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );
      controller.beginHandleDrag(
        TransformHandle.rotateLug,
        const Offset(100, 50),
      );
      final double angle = 20 * math.pi / 180;
      final Offset pointer =
          const Offset(50, 50) + Offset(math.cos(angle), math.sin(angle)) * 50;

      final double snapped = controller
          .updateHandleDrag(pointer)
          .snapshot
          .rotationRadians;

      expect(snapped, closeTo(15 * math.pi / 180, 1e-12));
    });

    test('commit is final bilinear floatCommit and clears live state', () {
      final TransformToolController controller = TransformToolController();
      controller.begin(
        activeLayerId: 'L1',
        activeLayerBounds: const Rect.fromLTWH(0, 0, 10, 10),
      );
      controller.translateBy(const Offset(5, -2));

      final TransformCommitCommand command = controller.commit();

      expect(command.snapshot.bounds.topLeft, const Offset(5, -2));
      expect(command.snapshot.resampling, TransformResampling.bilinear);
      expect(command.journalKind, JournalKind.floatCommit);
      expect(controller.hasLiveState, isFalse);
    });

    test('flip toggles are bilinear and reset restores source transform', () {
      final TransformToolController controller = TransformToolController();
      const Rect source = Rect.fromLTWH(10, 20, 30, 40);
      controller.begin(activeLayerId: 'L1', activeLayerBounds: source);
      controller.translateBy(const Offset(8, 9));

      final TransformSnapshot horizontal = controller.flipHorizontal().snapshot;
      final TransformSnapshot vertical = controller.flipVertical().snapshot;
      final TransformSnapshot reset = controller.reset().snapshot;

      expect(horizontal.isFlippedHorizontally, isTrue);
      expect(horizontal.resampling, TransformResampling.bilinear);
      expect(vertical.isFlippedVertically, isTrue);
      expect(reset.bounds, source);
      expect(reset.rotationRadians, 0);
      expect(reset.isFlippedHorizontally, isFalse);
      expect(reset.isFlippedVertically, isFalse);
    });
  });
}

final class _FakeCommand implements ToolCommand {}

RgbaFragment _fragment({int width = 2, int height = 2}) => RgbaFragment(
  width: width,
  height: height,
  rgba: <int>[
    for (var index = 0; index < width * height; index += 1) ...<int>[
      index,
      20,
      30,
      255,
    ],
  ],
  source: FragmentSourceMetadata(
    documentId: 'doc',
    layerId: 'source-layer',
    sourceBounds: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  ),
);
