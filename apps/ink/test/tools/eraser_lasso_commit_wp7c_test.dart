import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/raster_ops.dart' as raster;
import 'package:paper_ink/src/tools/eraser_tool.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/tool_engine_adapter.dart';
import 'package:paper_ink/src/ui/canvas_view.dart';

void main() {
  test('lasso erase clears only its region and commits undoably', () async {
    final LassoClearRequest command = LassoClearRequest(
      layerId: 'ink',
      vertices: <LassoPoint>[
        LassoPoint(x: 2, y: 2),
        LassoPoint(x: 6, y: 2),
        LassoPoint(x: 6, y: 6),
        LassoPoint(x: 2, y: 6),
      ],
      requestedAt: Duration.zero,
    );
    final SelectionMask mask = executeLassoSelection(
      LassoSelectionRequest(
        points: <Offset>[
          for (final LassoPoint point in command.vertices)
            Offset(point.x, point.y),
        ],
        combine: SelectionCombineMode.replace,
      ),
    );
    final raster.RgbaBitmap beforeBitmap = _opaqueBitmap();
    final raster.RgbaBitmap afterBitmap = clearBitmapWithSelectionMask(
      source: beforeBitmap,
      selection: mask,
    );

    expect(afterBitmap.pixels[(3 * 8 + 3) * 4 + 3], 0);
    expect(afterBitmap.pixels[(1 * 8 + 1) * 4 + 3], 255);

    final Tile beforeTile = _tileFromBitmap(beforeBitmap);
    final Tile afterTile = _tileFromBitmap(afterBitmap);
    final JournalEntry entry = buildToolTileJournalEntry(
      sequence: 1,
      timestampMs: 1,
      kind: command.journalKind,
      layerId: command.layerId,
      bounds: mask.bounds,
      beforeTiles: <TileKey, Tile?>{const TileKey(0, 0): beforeTile},
      afterTiles: <TileKey, Tile?>{const TileKey(0, 0): afterTile},
      metadata: const <String, Object?>{'eraserMode': 'lasso'},
    );
    final TileStore beforeStore = TileStore()
      ..publish('ink', const TileKey(0, 0), beforeTile);
    final JournalDocumentState beforeState = JournalDocumentState(
      tiles: beforeStore,
      layers: <InkLayer>[
        InkLayer(id: 'ink', name: 'Ink', tiles: const <TileKey>[TileKey(0, 0)]),
      ],
      canvas: CanvasSpec(width: 8, height: 8),
    );
    final JournalDocumentState committed = applyJournalEntry(
      beforeState,
      entry,
      direction: JournalDirection.forward,
      tiles: entry.afterTiles,
    );
    final UndoJournal journal = UndoJournal(storage: InMemoryJournalStorage());
    await journal.commit(entry);

    expect(
      committed.tiles
          .tile('ink', const TileKey(0, 0))!
          .pixels[(3 * Tile.edge + 3) * 4 + 3],
      0,
    );
    final JournalStep undone = (await journal.undo(committed))!;
    expect(
      undone.state.tiles
          .tile('ink', const TileKey(0, 0))!
          .pixels[(3 * Tile.edge + 3) * 4 + 3],
      255,
    );
    await journal.close();
  });
}

raster.RgbaBitmap _opaqueBitmap() {
  final Uint8List pixels = Uint8List(8 * 8 * 4);
  for (var offset = 0; offset < pixels.length; offset += 4) {
    pixels.setRange(offset, offset + 4, const <int>[80, 20, 10, 255]);
  }
  return raster.RgbaBitmap.fromPremultipliedRgba(
    width: 8,
    height: 8,
    pixels: pixels,
  );
}

Tile _tileFromBitmap(raster.RgbaBitmap bitmap) {
  final Uint8List pixels = Uint8List(Tile.byteLength);
  for (var y = 0; y < bitmap.height; y += 1) {
    pixels.setRange(
      y * Tile.edge * 4,
      y * Tile.edge * 4 + bitmap.width * 4,
      bitmap.pixels,
      y * bitmap.width * 4,
    );
  }
  return Tile.takeOwnership(pixels);
}
