import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/symmetry.dart';
import 'package:paper_ink/src/tools/crop_tool.dart';
import 'package:paper_ink/src/tools/eyedropper_tool.dart';
import 'package:paper_ink/src/tools/fill_tool.dart';
import 'package:paper_ink/src/tools/guides_tool.dart';
import 'package:paper_ink/src/tools/reference_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/tool.dart';

void main() {
  group('radius-averaged eyedropper', () {
    test('uniform region returns the original color', () {
      final EyedropperSample sample = sampleEyedropper(
        documentPoint: const Offset(10, 10),
        radius: 5,
        samplePixel: (int x, int y) => 0xff208040,
      );

      expect(sample.averagedArgb, 0xff208040);
      expect(sample.selectedArgb, 0xff208040);
      expect(sample.sampleCount, greaterThan(1));
    });

    test('black and white average in linear RGB rather than sRGB bytes', () {
      final EyedropperSample sample = sampleEyedropper(
        documentPoint: const Offset(1, 0.5),
        radius: 1,
        samplePixel: (int x, int y) {
          if (y != 0) {
            return null;
          }
          return switch (x) {
            0 => 0xff000000,
            1 => 0xffffffff,
            _ => null,
          };
        },
      );

      expect((sample.averagedArgb >>> 16) & 0xff, closeTo(188, 1));
      expect((sample.averagedArgb >>> 8) & 0xff, closeTo(188, 1));
      expect(sample.averagedArgb & 0xff, closeTo(188, 1));
    });

    test('nearest palette color snaps inside Delta-E ten', () {
      final EyedropperSample sample = sampleEyedropper(
        documentPoint: const Offset(0.5, 0.5),
        radius: 1,
        samplePixel: (int x, int y) => 0xff224466,
        palette: const <int>[0xff244568, 0xffff0000],
      );

      expect(sample.snappedToPalette, isTrue);
      expect(sample.selectedArgb, 0xff244568);
    });

    test('palette remains unsnapped beyond the configured threshold', () {
      final EyedropperSample sample = sampleEyedropper(
        documentPoint: const Offset(0.5, 0.5),
        radius: 1,
        samplePixel: (int x, int y) => 0xff0000ff,
        palette: const <int>[0xffff0000],
        paletteSnapDeltaE: 10,
      );

      expect(sample.snappedToPalette, isFalse);
      expect(sample.selectedArgb, 0xff0000ff);
    });

    test('transparent and unavailable pixels are excluded', () {
      expect(
        () => sampleEyedropper(
          documentPoint: Offset.zero,
          radius: 5,
          samplePixel: (int x, int y) => 0x00000000,
        ),
        throwsStateError,
      );
    });

    test('Delta-E is symmetric and zero for identical colors', () {
      expect(colorDeltaE(0xff123456, 0xff123456), closeTo(0, 1e-12));
      expect(
        colorDeltaE(0xff123456, 0xffabcdef),
        closeTo(colorDeltaE(0xffabcdef, 0xff123456), 1e-12),
      );
    });

    test('loupe gray snaps midpoint ties to the exact settle lattice', () {
      final int level = eyedropperLatticeGrayLevel(0xff7a7a7a);

      expect(level, 6);
      expect(eyedropperGrayLatticeLevels, contains(level));
      expect(eyedropperLatticeGrayLevel(0xff000000), 0);
      expect(eyedropperLatticeGrayLevel(0xffffffff), 30);
    });

    test('hold controller publishes loupe then installs selected color', () {
      final EyedropperToolController controller = EyedropperToolController(
        palette: const <int>[0xff336699],
      );
      final EyedropperSample sample = controller.beginHold(
        activation: EyedropperActivation.fingerLongPress,
        documentPoint: const Offset(4, 5),
        samplePixel: (int x, int y) => 0xff336699,
      );

      expect(controller.loupeSample, same(sample));
      expect(controller.hasLiveState, isTrue);
      expect(controller.endHold(), 0xff336699);
      expect(controller.hasLiveState, isFalse);
    });
  });

  group('persistent guides and symmetry', () {
    test('symmetry axes default to artwork center', () {
      final GuidesToolController controller = GuidesToolController(
        documentSize: const Size(600, 800),
      );

      expect(controller.state.symmetry.axisX, 300);
      expect(controller.state.symmetry.axisY, 400);
      expect(controller.state.symmetry.mode, SymmetryMode.off);
    });

    test('straightedge snaps inside 24 logical pixels only', () {
      final GuidesToolController controller = GuidesToolController(
        documentSize: const Size(100, 100),
      );
      controller.setStraightedge(Offset.zero, const Offset(100, 0));

      expect(
        controller.snapPoint(const Offset(30, 12), documentToViewportScale: 1),
        const Offset(30, 0),
      );
      expect(
        controller.snapPoint(const Offset(30, 25), documentToViewportScale: 1),
        const Offset(30, 25),
      );
    });

    test('guide overlay persists across tool deactivation and escape', () {
      final GuidesToolController controller = GuidesToolController(
        documentSize: const Size(100, 100),
      );
      controller.setGrid(GridOverlayStyle.lines, spacingDpx: 32);
      controller.deactivate();
      controller.cancel();

      expect(controller.state.grid.isEnabled, isTrue);
      expect(controller.state.excludedFromExport, isTrue);
    });

    test('quad mode is brush-engine-ready and stroke-only', () {
      final GuidesToolController controller = GuidesToolController(
        documentSize: const Size(100, 100),
      );
      controller.setSymmetryMode(SymmetryMode.quad);
      controller.placeSymmetryAxes(axisX: 40, axisY: 60);

      expect(controller.state.symmetry.reflections.length, 4);
      expect(controller.state.symmetryStrokesOnly, isTrue);
      expect(controller.state.hasVisibleOverlay, isTrue);
    });

    test('grid spacing is limited to the four binding choices', () {
      expect(
        () => GridOverlay(style: GridOverlayStyle.dots, spacingDpx: 12),
        throwsArgumentError,
      );
      for (final int spacing in <int>[8, 16, 32, 64]) {
        expect(GridOverlay(spacingDpx: spacing).spacingDpx, spacing);
      }
    });
  });

  group('locked reference stack', () {
    test('import centers a locked half-opacity non-exporting layer', () {
      final ReferenceToolController controller = ReferenceToolController();
      final ReferenceAddCommand command = controller.addReference(
        layerId: 'R1',
        image: _referenceImage(),
        viewportCenter: const Offset(200, 300),
      );

      expect(command.layer.placement.topLeft, const Offset(150, 275));
      expect(command.layer.isLocked, isTrue);
      expect(command.layer.opacity, 0.5);
      expect(command.layer.excludedFromExport, isTrue);
      expect(command.journalKind, JournalKind.layerAdd);
      expect(controller.contentLayerSlotsConsumed, 0);
    });

    test('separate reference stack is capped at two slots', () {
      final ReferenceToolController controller = ReferenceToolController();
      controller.addReference(
        layerId: 'R1',
        image: _referenceImage(),
        viewportCenter: Offset.zero,
      );
      controller.commitPlacement();
      controller.addReference(
        layerId: 'R2',
        image: _referenceImage(),
        viewportCenter: Offset.zero,
      );
      controller.commitPlacement();

      expect(controller.canAddReference, isFalse);
      expect(
        () => controller.addReference(
          layerId: 'R3',
          image: _referenceImage(),
          viewportCenter: Offset.zero,
        ),
        throwsStateError,
      );
    });

    test('placement transform is the explicit lock bypass', () {
      final ReferenceToolController controller = ReferenceToolController();
      controller.addReference(
        layerId: 'R1',
        image: _referenceImage(),
        viewportCenter: Offset.zero,
      );

      final ReferencePlacementPreview preview = controller.updatePlacement(
        ReferencePlacement(
          topLeft: const Offset(10, 20),
          scale: 2,
          rotationRadians: 0.5,
          isFlippedHorizontally: true,
          isFlippedVertically: true,
        ),
      );
      final ReferencePlacementCommit commit = controller.commitPlacement();

      expect(preview.bypassesLock, isTrue);
      expect(commit.bypassesLock, isTrue);
      expect(commit.journalKind, JournalKind.layerProps);
      expect(commit.layer.placement.isFlippedHorizontally, isTrue);
      expect(commit.layer.placement.isFlippedVertically, isTrue);
      expect(controller.canModifyPixels('R1'), isFalse);
    });

    test('cancel rolls a placement preview back to its captured state', () {
      final ReferenceToolController controller = ReferenceToolController();
      controller.addReference(
        layerId: 'R1',
        image: _referenceImage(),
        viewportCenter: const Offset(50, 50),
      );
      final Offset original = controller.layers.single.placement.topLeft;
      controller.updatePlacement(
        ReferencePlacement(topLeft: const Offset(400, 500), scale: 2),
      );

      controller.cancel();

      expect(controller.layers.single.placement.topLeft, original);
      expect(controller.layers.single.placement.scale, 1);
      expect(controller.hasLiveState, isFalse);
    });

    test('reference reorder and removal stay inside reference stack', () {
      final ReferenceToolController controller = ReferenceToolController();
      controller.addReference(
        layerId: 'R1',
        image: _referenceImage(),
        viewportCenter: Offset.zero,
      );
      controller.commitPlacement();
      controller.addReference(
        layerId: 'R2',
        image: _referenceImage(),
        viewportCenter: Offset.zero,
      );
      controller.commitPlacement();

      controller.reorder('R1', 1);
      expect(
        controller.layers.map((ReferenceLayer layer) => layer.id),
        <String>['R2', 'R1'],
      );
      expect(controller.remove('R2').id, 'R2');
      expect(controller.layers.single.id, 'R1');
    });
  });

  group('crop bounds', () {
    test('fresh drag is clamped to the current artwork', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(20, 30),
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );

      final CropDraft draft = controller.updateDrag(const Offset(140, 180));

      expect(draft.cropRect, const Rect.fromLTRB(20, 30, 100, 100));
    });

    test('eight handles adjust a live crop without leaving artwork', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(10, 10),
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );
      controller.updateDrag(const Offset(80, 80));
      controller.endDrag();
      controller.beginHandleDrag(CropHandle.topLeft);

      final CropDraft draft = controller.updateHandleDrag(
        const Offset(-20, -30),
      );

      expect(CropHandle.values.length, 8);
      expect(draft.cropRect.topLeft, Offset.zero);
      expect(draft.cropRect.bottomRight, const Offset(80, 80));
    });

    test('commit journals canvasResize and preserves outside tiles', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(10, 20),
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 120),
      );
      controller.updateDrag(const Offset(80, 90));

      final CropCommand command = controller.commit();

      expect(command.previousBounds, const Rect.fromLTWH(0, 0, 100, 120));
      expect(command.newBounds, const Rect.fromLTRB(10, 20, 80, 90));
      expect(command.exportClip, command.newBounds);
      expect(command.preservesOutsideContent, isTrue);
      expect(command.journalKind, JournalKind.canvasResize);
      expect(controller.hasLiveState, isFalse);
    });

    test('empty crop cannot commit', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(10, 10),
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );

      expect(controller.commit, throwsStateError);
    });

    test('fractional live bounds commit to integer canvas pixel edges', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(10.4, 20.4),
        artworkBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );
      controller.updateDrag(const Offset(80.6, 90.6));

      final CropCommand command = controller.commit();

      expect(command.newBounds, const Rect.fromLTRB(10, 20, 81, 91));
    });
  });

  group('tool controller router', () {
    test('switches exactly one active controller and preserves selection', () {
      final SelectionToolController selection = SelectionToolController();
      final FillToolController fill = FillToolController();
      selection.applyMask(
        SelectionMask.filledRect(const Rect.fromLTWH(0, 0, 2, 2)),
      );
      final ToolControllerRouter router = ToolControllerRouter(
        controllers: <ToolControllerLifecycle>[selection, fill],
        initialToolId: 'select',
      );

      router.select('fill');

      expect(router.activeTool.id, 'fill');
      expect(fill.isActive, isTrue);
      expect(selection.isActive, isFalse);
      expect(selection.hasSelection, isTrue);
    });

    test('unknown and duplicate controller ids are rejected', () {
      final FillToolController fill = FillToolController();
      expect(
        () => ToolControllerRouter(
          controllers: <ToolControllerLifecycle>[fill],
          initialToolId: 'shape',
        ),
        throwsArgumentError,
      );
      expect(
        () => ToolControllerRouter(
          controllers: <ToolControllerLifecycle>[fill, FillToolController()],
          initialToolId: 'fill',
        ),
        throwsArgumentError,
      );
    });
  });
}

ReferenceImageDescriptor _referenceImage() => ReferenceImageDescriptor(
  sourceId: 'decoded-reference',
  pixelWidth: 100,
  pixelHeight: 50,
);
