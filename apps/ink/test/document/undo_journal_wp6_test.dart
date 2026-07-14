import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/canvas_ops.dart';

void main() {
  group('WP6 canvasFlip replay wiring', () {
    test('forward and reverse preserve off-canvas x and y', () {
      final before = _stateWithPixel(width: 10, height: 10, x: -2, y: -1);
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 0,
        kind: JournalKind.canvasFlip,
      );

      final forward = applyJournalEntry(
        before,
        entry,
        direction: JournalDirection.forward,
      );
      final reverse = applyJournalEntry(
        forward,
        entry,
        direction: JournalDirection.reverse,
      );

      expect(_alphaAt(forward.tiles, 11, -1), 255);
      expect(_alphaAt(reverse.tiles, -2, -1), 255);
      expect(reverse.layers.single.tiles, const <TileKey>[TileKey(-1, -1)]);
    });

    test('flip after shrink keeps cropped backing pixels', () {
      final original = _stateWithPixel(width: 4, height: 4, x: 0, y: 0);
      final shrunk = resizeCanvas(
        state: original,
        width: 2,
        height: 2,
        anchor: CanvasResizeAnchor.bottomRight,
        sequence: 1,
        timestampMs: 0,
      );
      final flipped = applyJournalEntry(
        shrunk.state,
        JournalEntry(seq: 2, timestampMs: 0, kind: JournalKind.canvasFlip),
        direction: JournalDirection.forward,
      );

      expect(_alphaAt(shrunk.state.tiles, -2, -2), 255);
      expect(_alphaAt(flipped.tiles, 3, -2), 255);
    });

    test('flip replay prunes explicitly stored transparent tiles', () {
      final store = TileStore()
        ..publish(
          'L1',
          const TileKey(0, 0),
          Tile.takeOwnership(Uint8List(Tile.byteLength)),
        );
      final state = _state(width: 10, height: 10, tiles: store);

      final result = applyJournalEntry(
        state,
        JournalEntry(seq: 1, timestampMs: 0, kind: JournalKind.canvasFlip),
        direction: JournalDirection.forward,
      );

      expect(result.tiles.tileCount, 0);
      expect(result.layers.single.tiles, isEmpty);
    });

    test('no-snapshot flip entry JSON round-trips', () {
      final entry = JournalEntry(
        seq: 8,
        timestampMs: 9,
        kind: JournalKind.canvasFlip,
      );

      final decoded = JournalEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson()))! as Map<String, Object?>,
      );

      expect(decoded.kind, JournalKind.canvasFlip);
      expect(decoded.beforeReferences, isEmpty);
      expect(decoded.afterReferences, isEmpty);
      expect(decoded.completeLayerSnapshots, isFalse);
    });

    test(
      'durably reopened flip still undoes and redoes off-canvas pixels',
      () async {
        final storage = InMemoryJournalStorage();
        final before = _stateWithPixel(width: 10, height: 10, x: -2, y: -1);
        final operation = flipCanvasHorizontally(
          state: before,
          sequence: 1,
          timestampMs: 0,
        );
        await UndoJournal(storage: storage).commit(operation.entry);

        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final undo = await reopened.undo(operation.state);
        final redo = await reopened.redo(undo!.state);

        expect(_alphaAt(undo.state.tiles, -2, -1), 255);
        expect(_alphaAt(redo!.state.tiles, 11, -1), 255);
      },
    );
  });

  group('WP6 durable structural snapshots', () {
    test(
      'canvasResize references every layer including an empty layer',
      () async {
        final tiles = TileStore()
          ..publish('ink', const TileKey(0, 0), _pixelTile(0, 0))
          ..ensureLayer('empty');
        final before = JournalDocumentState(
          tiles: tiles,
          layers: <InkLayer>[
            InkLayer(
              id: 'ink',
              name: 'Ink',
              tiles: const <TileKey>[TileKey(0, 0)],
            ),
            InkLayer(id: 'empty', name: 'Empty'),
          ],
          canvas: CanvasSpec(width: 4, height: 4),
        );
        final operation = resizeCanvas(
          state: before,
          width: 2,
          height: 2,
          anchor: CanvasResizeAnchor.bottomRight,
          sequence: 1,
          timestampMs: 0,
        );
        final storage = InMemoryJournalStorage();
        await UndoJournal(storage: storage).commit(operation.entry);

        final json =
            jsonDecode(storage.durableLines.single)! as Map<String, Object?>;
        final beforeLayers = json['beforeLayers']! as Map<String, Object?>;
        final afterLayers = json['afterLayers']! as Map<String, Object?>;
        expect(beforeLayers.keys, <String>{'ink', 'empty'});
        expect(afterLayers.keys, <String>{'ink', 'empty'});
        expect(beforeLayers['empty'], isEmpty);
        expect(afterLayers['empty'], isEmpty);
      },
    );

    test(
      'reopened canvasResize restores exact shrink crop on undo redo',
      () async {
        final before = _stateWithPixel(width: 4, height: 4, x: 0, y: 1);
        final operation = resizeCanvas(
          state: before,
          width: 2,
          height: 3,
          anchor: CanvasResizeAnchor.bottomRight,
          sequence: 1,
          timestampMs: 0,
        );
        final storage = InMemoryJournalStorage();
        await UndoJournal(storage: storage).commit(operation.entry);

        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final undo = await reopened.undo(operation.state);
        final redo = await reopened.redo(undo!.state);

        expect(undo.state.canvas.width, 4);
        expect(_alphaAt(undo.state.tiles, 0, 1), 255);
        expect(redo!.state.canvas.width, 2);
        expect(_alphaAt(redo.state.tiles, -2, 0), 255);
      },
    );

    test('reopened layerClear restores its durable before tile', () async {
      final before = _stateWithPixel(width: 10, height: 10, x: 2, y: 3);
      final operation = clearLayer(
        state: before,
        layerId: 'L1',
        sequence: 1,
        timestampMs: 0,
      ).operation!;
      final storage = InMemoryJournalStorage();
      await UndoJournal(storage: storage).commit(operation.entry);

      final reopened = await UndoJournal.open(storage: storage.crashClone());
      final undo = await reopened.undo(operation.state);
      final redo = await reopened.redo(undo!.state);

      expect(_alphaAt(undo.state.tiles, 2, 3), 255);
      expect(redo!.state.tiles.tileCountForLayer('L1'), 0);
    });
  });
}

JournalDocumentState _stateWithPixel({
  required int width,
  required int height,
  required int x,
  required int y,
}) {
  final tileX = _tileCoordinate(x);
  final tileY = _tileCoordinate(y);
  final localX = x - tileX * Tile.edge;
  final localY = y - tileY * Tile.edge;
  final store = TileStore()
    ..publish('L1', TileKey(tileX, tileY), _pixelTile(localX, localY));
  return _state(width: width, height: height, tiles: store);
}

JournalDocumentState _state({
  required int width,
  required int height,
  required TileStore tiles,
}) => JournalDocumentState(
  tiles: tiles,
  layers: <InkLayer>[
    InkLayer(id: 'L1', name: 'Layer', tiles: tiles.occupiedKeys('L1')),
  ],
  canvas: CanvasSpec(width: width, height: height),
);

Tile _pixelTile(int x, int y) {
  final pixels = Uint8List(Tile.byteLength);
  final offset = (y * Tile.edge + x) * Tile.bytesPerPixel;
  pixels.setRange(offset, offset + Tile.bytesPerPixel, const <int>[
    255,
    0,
    0,
    255,
  ]);
  return Tile.takeOwnership(pixels);
}

int _alphaAt(TileStore tiles, int x, int y) {
  final tileX = _tileCoordinate(x);
  final tileY = _tileCoordinate(y);
  final tile = tiles.tile('L1', TileKey(tileX, tileY));
  if (tile == null) {
    return 0;
  }
  final localX = x - tileX * Tile.edge;
  final localY = y - tileY * Tile.edge;
  return tile.pixels[(localY * Tile.edge + localX) * Tile.bytesPerPixel + 3];
}

int _tileCoordinate(int pixel) =>
    pixel >= 0 ? pixel ~/ Tile.edge : -((-pixel + Tile.edge - 1) ~/ Tile.edge);
