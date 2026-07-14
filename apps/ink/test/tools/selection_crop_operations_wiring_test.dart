import 'dart:ui';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/canvas_ops.dart';
import 'package:paper_ink/src/tools/crop_tool.dart';
import 'package:paper_ink/src/tools/fill_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/ui/canvas_view.dart';

void main() {
  group('selection operation command chains', () {
    test('copy paste mirrors and canvas tap produce one float commit', () {
      final SelectionToolController controller = _selectedController();
      final RgbaFragment fragment = _fragment();

      controller.copy(fragment);
      final SelectionFloat? pasted = controller.pasteAtViewportCenter(
        viewportCenter: const Offset(50, 40),
        activeLayerId: 'target-layer',
      );
      final SelectionFloatEditCommand horizontal = controller
          .flipFloatHorizontal();
      final SelectionFloatEditCommand vertical = controller.flipFloatVertical();
      final FloatCommitCommand? commit = controller.handleCanvasTap();

      expect(controller.clipboard.canPaste, isTrue);
      expect(pasted!.topLeft, const Offset(48, 39));
      expect(horizontal.edit, SelectionFloatEdit.flipHorizontal);
      expect(vertical.edit, SelectionFloatEdit.flipVertical);
      expect(commit, isNotNull);
      expect(commit!.floatingSelection.scaleX, -1);
      expect(commit.floatingSelection.scaleY, -1);
      expect(commit.floatingSelection.destinationLayerId, 'target-layer');
      expect(commit.journalKind, JournalKind.floatCommit);
      expect(controller.floatingSelection, isNull);
    });

    test('cut writes the clipboard and emits a journaled masked erase', () {
      final SelectionToolController controller = _selectedController();
      final SelectionMask mask = controller.mask!;
      final RgbaFragment fragment = _fragment();

      final SelectionClearCommand command = controller.cut(
        fragment,
        layerId: 'source-layer',
      );

      expect(controller.clipboard.fragment, same(fragment));
      expect(command.layerId, 'source-layer');
      expect(command.mask, same(mask));
      expect(command.journalKind, JournalKind.erase);
      expect(controller.mask, same(mask));
    });

    test('clear emits a journaled erase without changing the clipboard', () {
      final SelectionToolController controller = _selectedController();
      final RgbaFragment fragment = _fragment();
      controller.copy(fragment);

      final SelectionClearCommand command = controller.clear(
        layerId: 'source-layer',
      );

      expect(command.layerId, 'source-layer');
      expect(command.mask, same(controller.mask));
      expect(command.journalKind, JournalKind.erase);
      expect(controller.clipboard.fragment, same(fragment));
    });

    test('selection erase builds a valid snapshot-backed journal entry', () {
      final SelectionToolController controller = _selectedController();
      final SelectionClearCommand command = controller.clear(
        layerId: 'source-layer',
      );
      final Uint8List pixels = Uint8List(Tile.byteLength)..[3] = 255;
      final Tile before = Tile(pixels);

      final JournalEntry entry = buildToolTileJournalEntry(
        sequence: 4,
        timestampMs: 500,
        kind: command.journalKind,
        layerId: command.layerId,
        bounds: command.mask.bounds,
        beforeTiles: <TileKey, Tile?>{const TileKey(0, 0): before},
        afterTiles: <TileKey, Tile?>{const TileKey(0, 0): null},
      );

      expect(entry.kind, JournalKind.erase);
      expect(entry.recipe, isNull);
      expect(entry.recipeCompacted, isTrue);
      expect(entry.beforeTiles[const TileKey(0, 0)], same(before));
      expect(entry.afterTiles[const TileKey(0, 0)], isNull);
    });

    test('duplicate stays live until the resulting float is committed', () {
      final SelectionToolController controller = _selectedController();
      final RgbaFragment fragment = _fragment();

      final SelectionFloatEditCommand preview = controller.duplicate(
        fragment,
        activeLayerId: 'target-layer',
        offset: const Offset(12, -4),
      );
      final FloatCommitCommand? commit = controller.handleCanvasTap();

      expect(preview.edit, SelectionFloatEdit.duplicate);
      expect(preview.floatingSelection.topLeft, const Offset(20, 5));
      expect(preview.floatingSelection.destinationLayerId, 'target-layer');
      expect(commit, isNotNull);
      expect(commit!.floatingSelection, same(preview.floatingSelection));
      expect(commit.journalKind, JournalKind.floatCommit);
    });

    test('to-new-layer captures the active mask in a layerAdd command', () {
      final SelectionToolController controller = _selectedController();

      final SelectionToNewLayerCommand command = controller.toNewLayer(
        sourceLayerId: 'source-layer',
        newLayerId: 'new-layer',
      );

      expect(command.sourceLayerId, 'source-layer');
      expect(command.newLayerId, 'new-layer');
      expect(command.mask, same(controller.mask));
      expect(command.journalKind, JournalKind.layerAdd);
    });

    test('new-layer undo and redo always resolve a valid active layer', () {
      final InkLayer source = InkLayer(id: 'source-layer', name: 'Source');
      final InkLayer added = InkLayer(id: 'new-layer', name: 'Selection');
      final JournalDocumentState before = JournalDocumentState(
        tiles: TileStore()..ensureLayer(source.id),
        layers: <InkLayer>[source],
        canvas: CanvasSpec(width: 20, height: 20),
      );
      final JournalDocumentState after = JournalDocumentState(
        tiles: TileStore()
          ..ensureLayer(source.id)
          ..ensureLayer(added.id),
        layers: <InkLayer>[source, added],
        canvas: CanvasSpec(width: 20, height: 20),
      );
      final JournalEntry entry = JournalEntry(
        seq: 2,
        timestampMs: 40,
        kind: JournalKind.layerAdd,
        layerId: added.id,
        beforeState: before.structuralJson(),
        afterState: after.structuralJson(),
        unknownFields: <String, Object?>{'activeLayerBefore': source.id},
      );

      expect(
        resolveCanvasActiveLayerAfterJournalStep(
          layers: before.layers,
          currentActiveLayerId: added.id,
          entry: entry,
          forward: false,
        ),
        source.id,
      );
      expect(
        resolveCanvasActiveLayerAfterJournalStep(
          layers: after.layers,
          currentActiveLayerId: source.id,
          entry: entry,
          forward: true,
        ),
        added.id,
      );
    });

    test('fill command carries current color and active selection clip', () {
      final SelectionToolController selection = _selectedController();
      final FillToolController fill = FillToolController(
        options: FillOptions(style: SolidFillStyle(0xff336699)),
      );

      final FillCommand command = fill.tap(
        seed: selection.mask!.bounds.center,
        activeLayerId: 'source-layer',
        selectionClip: selection.mask,
      );

      expect(command.activeLayerId, 'source-layer');
      expect(command.selectionClip, same(selection.mask));
      expect(command.options.style.colorArgb, 0xff336699);
      expect(command.journalKind, JournalKind.fill);
    });

    test('empty clipboard leaves paste disabled and creates no float', () {
      final SelectionToolController controller = _selectedController();

      final SelectionFloat? pasted = controller.pasteAtViewportCenter(
        viewportCenter: const Offset(50, 40),
        activeLayerId: 'target-layer',
      );

      expect(controller.clipboard.canPaste, isFalse);
      expect(pasted, isNull);
      expect(controller.floatingSelection, isNull);
    });
  });

  group('crop draw handle and commit chain', () {
    test('each crop handle adjusts only its owned edges', () {
      final Map<CropHandle, ({Offset point, Rect expected})> cases =
          <CropHandle, ({Offset point, Rect expected})>{
            CropHandle.topLeft: (
              point: const Offset(10, 15),
              expected: const Rect.fromLTRB(10, 15, 80, 90),
            ),
            CropHandle.topCenter: (
              point: const Offset(50, 15),
              expected: const Rect.fromLTRB(20, 15, 80, 90),
            ),
            CropHandle.topRight: (
              point: const Offset(90, 15),
              expected: const Rect.fromLTRB(20, 15, 90, 90),
            ),
            CropHandle.middleLeft: (
              point: const Offset(10, 60),
              expected: const Rect.fromLTRB(10, 30, 80, 90),
            ),
            CropHandle.middleRight: (
              point: const Offset(90, 60),
              expected: const Rect.fromLTRB(20, 30, 90, 90),
            ),
            CropHandle.bottomLeft: (
              point: const Offset(10, 95),
              expected: const Rect.fromLTRB(10, 30, 80, 95),
            ),
            CropHandle.bottomCenter: (
              point: const Offset(50, 95),
              expected: const Rect.fromLTRB(20, 30, 80, 95),
            ),
            CropHandle.bottomRight: (
              point: const Offset(90, 95),
              expected: const Rect.fromLTRB(20, 30, 90, 95),
            ),
          };

      for (final MapEntry<CropHandle, ({Offset point, Rect expected})> entry
          in cases.entries) {
        final CropToolController controller = _cropControllerWithDraft();

        controller.beginHandleDrag(entry.key);
        final CropDraft draft = controller.updateHandleDrag(entry.value.point);

        expect(controller.activeHandle, entry.key, reason: entry.key.name);
        expect(draft.cropRect, entry.value.expected, reason: entry.key.name);
        controller.endHandleDrag();
        expect(controller.activeHandle, isNull, reason: entry.key.name);
      }
    });

    test('adjusted fractional crop commits rounded canvas bounds', () {
      final CropToolController controller = CropToolController();
      controller.beginDrag(
        point: const Offset(10.2, 20.2),
        artworkBounds: const Rect.fromLTWH(0, 0, 120, 140),
      );
      controller.updateDrag(const Offset(90.7, 100.7));
      controller.endDrag();
      controller.beginHandleDrag(CropHandle.topLeft);
      controller.updateHandleDrag(const Offset(15.6, 25.4));
      controller.endHandleDrag();

      final CropCommand command = controller.commit();

      expect(command.previousBounds, const Rect.fromLTWH(0, 0, 120, 140));
      expect(command.newBounds, const Rect.fromLTRB(16, 25, 91, 101));
      expect(command.exportClip, command.newBounds);
      expect(command.preservesOutsideContent, isTrue);
      expect(command.journalKind, JournalKind.canvasResize);
      expect(controller.hasLiveState, isFalse);
      expect(controller.draft, isNull);
      expect(controller.activeHandle, isNull);
    });

    test('cancel clears both the crop draft and captured handle', () {
      final CropToolController controller = _cropControllerWithDraft();
      controller.beginHandleDrag(CropHandle.bottomRight);

      controller.cancel();

      expect(controller.hasLiveState, isFalse);
      expect(controller.draft, isNull);
      expect(controller.activeHandle, isNull);
      expect(
        () => controller.updateHandleDrag(const Offset(50, 50)),
        throwsStateError,
      );
    });

    test('arbitrary crop origin produces one replayable structural entry', () {
      final TileStore tiles = _cropTileStore();
      final InkLayer layer = InkLayer(
        id: 'source-layer',
        name: 'Source',
        tiles: tiles.occupiedKeys('source-layer'),
      );
      final JournalDocumentState before = JournalDocumentState(
        tiles: tiles,
        layers: <InkLayer>[layer],
        canvas: CanvasSpec(width: 120, height: 140),
      );
      final CropCommand command = CropCommand(
        previousBounds: const Rect.fromLTWH(0, 0, 120, 140),
        newBounds: const Rect.fromLTRB(16, 25, 91, 101),
      );

      final JournaledEngineOperation operation = buildCropCanvasOperation(
        command: command,
        state: before,
        sequence: 7,
        timestampMs: 900,
      );

      expect(operation.entry.kind, JournalKind.canvasResize);
      expect(operation.entry.completeLayerSnapshots, isTrue);
      expect(operation.entry.seq, 7);
      expect(operation.state.canvas.width, 75);
      expect(operation.state.canvas.height, 76);
      expect(_alphaAt(operation.state.tiles, 'source-layer', 14, 15), 255);
      expect(
        operation.state.tiles.locations.any(
          (TileLocation location) => location.key.x < 0 || location.key.y < 0,
        ),
        isTrue,
        reason: 'pixels outside the export clip stay in sparse backing tiles',
      );

      final JournalDocumentState undone = applyJournalEntry(
        operation.state,
        operation.entry,
        direction: JournalDirection.reverse,
        layerTiles: operation.entry.beforeLayerTiles,
      );
      expect(undone.canvas.width, 120);
      expect(undone.canvas.height, 140);
      expect(_alphaAt(undone.tiles, 'source-layer', 30, 40), 255);

      final JournalDocumentState redone = applyJournalEntry(
        undone,
        operation.entry,
        direction: JournalDirection.forward,
        layerTiles: operation.entry.afterLayerTiles,
      );
      expect(redone.canvas.width, 75);
      expect(redone.canvas.height, 76);
      expect(_alphaAt(redone.tiles, 'source-layer', 14, 15), 255);
    });
  });
}

SelectionToolController _selectedController() {
  final SelectionToolController controller = SelectionToolController();
  controller.applyMask(
    SelectionMask.filledRect(const Rect.fromLTWH(8, 9, 4, 2)),
  );
  return controller;
}

CropToolController _cropControllerWithDraft() {
  final CropToolController controller = CropToolController();
  controller.beginDrag(
    point: const Offset(20, 30),
    artworkBounds: const Rect.fromLTWH(0, 0, 100, 110),
  );
  controller.updateDrag(const Offset(80, 90));
  controller.endDrag();
  return controller;
}

RgbaFragment _fragment() => RgbaFragment(
  width: 4,
  height: 2,
  rgba: List<int>.filled(4 * 2 * 4, 255),
  source: FragmentSourceMetadata(
    documentId: 'document',
    layerId: 'source-layer',
    sourceBounds: const Rect.fromLTWH(8, 9, 4, 2),
  ),
);

TileStore _cropTileStore() {
  final Uint8List pixels = Uint8List(Tile.byteLength);
  for (final Offset point in <Offset>[
    const Offset(5, 5),
    const Offset(30, 40),
  ]) {
    final int offset =
        (point.dy.toInt() * Tile.edge + point.dx.toInt()) * Tile.bytesPerPixel;
    pixels.setRange(offset, offset + 4, const <int>[255, 0, 0, 255]);
  }
  return TileStore()
    ..publish('source-layer', const TileKey(0, 0), Tile(pixels));
}

int _alphaAt(TileStore store, String layerId, int x, int y) {
  final int tileX = x >= 0
      ? x ~/ Tile.edge
      : -((-x + Tile.edge - 1) ~/ Tile.edge);
  final int tileY = y >= 0
      ? y ~/ Tile.edge
      : -((-y + Tile.edge - 1) ~/ Tile.edge);
  final Tile? tile = store.tile(layerId, TileKey(tileX, tileY));
  if (tile == null) {
    return 0;
  }
  final int localX = x - tileX * Tile.edge;
  final int localY = y - tileY * Tile.edge;
  return tile.pixels[(localY * Tile.edge + localX) * Tile.bytesPerPixel + 3];
}
