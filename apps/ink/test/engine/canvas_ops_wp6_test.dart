import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/canvas_ops.dart';
import 'package:paper_ink/src/engine/compositor.dart';

void main() {
  group('resize canvas', () {
    test('top-left anchor leaves backing pixels fixed', () {
      final before = _oneLayerState(width: 4, height: 4, x: 1, y: 2);

      final operation = resizeCanvas(
        state: before,
        width: 7,
        height: 9,
        anchor: CanvasResizeAnchor.topLeft,
        sequence: 1,
        timestampMs: 10,
      );

      expect(operation.state.canvas.width, 7);
      expect(operation.state.canvas.height, 9);
      expect(_pixel(operation.state.tiles, 'L1', 1, 2), _red);
      expect(operation.entry.kind, JournalKind.canvasResize);
    });

    test('bottom-right anchor translates by the full dimension delta', () {
      final before = _oneLayerState(width: 4, height: 5, x: 1, y: 2);

      final operation = resizeCanvas(
        state: before,
        width: 7,
        height: 9,
        anchor: CanvasResizeAnchor.bottomRight,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 4, 6), _red);
      expect(_pixel(operation.state.tiles, 'L1', 1, 2), _clear);
    });

    test('all nine anchors map both dimension deltas explicitly', () {
      const expectedOffsets = <CanvasResizeAnchor, (int, int)>{
        CanvasResizeAnchor.topLeft: (0, 0),
        CanvasResizeAnchor.topCenter: (2, 0),
        CanvasResizeAnchor.topRight: (4, 0),
        CanvasResizeAnchor.centerLeft: (0, 3),
        CanvasResizeAnchor.center: (2, 3),
        CanvasResizeAnchor.centerRight: (4, 3),
        CanvasResizeAnchor.bottomLeft: (0, 6),
        CanvasResizeAnchor.bottomCenter: (2, 6),
        CanvasResizeAnchor.bottomRight: (4, 6),
      };
      final before = _oneLayerState(width: 10, height: 10, x: 1, y: 1);

      for (final entry in expectedOffsets.entries) {
        final operation = resizeCanvas(
          state: before,
          width: 14,
          height: 16,
          anchor: entry.key,
          sequence: 1,
          timestampMs: 0,
        );
        expect(
          _pixel(
            operation.state.tiles,
            'L1',
            1 + entry.value.$1,
            1 + entry.value.$2,
          ),
          _red,
          reason: entry.key.name,
        );
      }
    });

    test('center anchor truncates positive odd half deltas toward zero', () {
      final before = _oneLayerState(width: 4, height: 4, x: 1, y: 1);

      final operation = resizeCanvas(
        state: before,
        width: 7,
        height: 9,
        anchor: CanvasResizeAnchor.center,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 2, 3), _red);
    });

    test('center anchor truncates negative odd half deltas toward zero', () {
      final before = _oneLayerState(width: 7, height: 9, x: 3, y: 4);

      final operation = resizeCanvas(
        state: before,
        width: 4,
        height: 4,
        anchor: CanvasResizeAnchor.center,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 2, 2), _red);
    });

    test('one-pixel center deltas do not shift either direction', () {
      final before = _oneLayerState(width: 4, height: 4, x: 2, y: 2);
      final grown = resizeCanvas(
        state: before,
        width: 5,
        height: 5,
        anchor: CanvasResizeAnchor.center,
        sequence: 1,
        timestampMs: 0,
      );
      final shrunk = resizeCanvas(
        state: grown.state,
        width: 4,
        height: 4,
        anchor: CanvasResizeAnchor.center,
        sequence: 2,
        timestampMs: 0,
      );

      expect(_pixel(grown.state.tiles, 'L1', 2, 2), _red);
      expect(_pixel(shrunk.state.tiles, 'L1', 2, 2), _red);
    });

    test(
      'shrink keeps translated pixels outside bounds and regrow restores',
      () {
        final before = _oneLayerState(width: 4, height: 4, x: 0, y: 0);
        final shrunk = resizeCanvas(
          state: before,
          width: 2,
          height: 2,
          anchor: CanvasResizeAnchor.bottomRight,
          sequence: 1,
          timestampMs: 0,
        );

        expect(_pixel(shrunk.state.tiles, 'L1', -2, -2), _red);
        expect(shrunk.state.layers.single.tiles, const <TileKey>[
          TileKey(-1, -1),
        ]);

        final regrown = resizeCanvas(
          state: shrunk.state,
          width: 4,
          height: 4,
          anchor: CanvasResizeAnchor.bottomRight,
          sequence: 2,
          timestampMs: 0,
        );
        expect(_pixel(regrown.state.tiles, 'L1', 0, 0), _red);
      },
    );

    test('translation crosses a positive tile boundary deterministically', () {
      final before = _oneLayerState(width: 300, height: 20, x: 255, y: 3);

      final operation = resizeCanvas(
        state: before,
        width: 301,
        height: 20,
        anchor: CanvasResizeAnchor.centerRight,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 256, 3), _red);
      expect(operation.state.layers.single.tiles, const <TileKey>[
        TileKey(1, 0),
      ]);
    });

    test('negative backing coordinates use floor tile division', () {
      final tiles = TileStore()
        ..publish('L1', const TileKey(-1, 0), _pixelTile(255, 4, _red));
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer')],
        tiles: tiles,
      );

      final operation = resizeCanvas(
        state: before,
        width: 21,
        height: 20,
        anchor: CanvasResizeAnchor.topRight,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 0, 4), _red);
      expect(_pixel(operation.state.tiles, 'L1', -1, 4), _clear);
    });

    test('same-size resize is rejected as a journal no-op', () {
      final before = _oneLayerState(width: 4, height: 4, x: 0, y: 0);

      expect(
        () => resizeCanvas(
          state: before,
          width: 4,
          height: 4,
          anchor: CanvasResizeAnchor.center,
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test('canvas dimension validation is retained', () {
      final before = _oneLayerState(width: 4, height: 4, x: 0, y: 0);

      expect(
        () => resizeCanvas(
          state: before,
          width: 0,
          height: 4,
          anchor: CanvasResizeAnchor.topLeft,
          sequence: 1,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
    });

    test(
      'complete resize snapshots include empty layers and translated keys',
      () {
        final tiles = TileStore()
          ..publish('ink', const TileKey(0, 0), _pixelTile(0, 0, _red))
          ..ensureLayer('empty');
        final before = _state(
          width: 4,
          height: 4,
          layers: <InkLayer>[
            InkLayer(id: 'ink', name: 'Ink'),
            InkLayer(id: 'empty', name: 'Empty'),
          ],
          tiles: tiles,
        );

        final operation = resizeCanvas(
          state: before,
          width: 2,
          height: 2,
          anchor: CanvasResizeAnchor.bottomRight,
          sequence: 1,
          timestampMs: 0,
        );

        expect(operation.entry.completeLayerSnapshots, isTrue);
        expect(operation.entry.beforeLayerTiles.keys, <String>{'ink', 'empty'});
        expect(operation.entry.afterLayerTiles.keys, <String>{'ink', 'empty'});
        expect(operation.entry.beforeLayerTiles['empty'], isEmpty);
        expect(operation.entry.afterLayerTiles['ink']!.keys, const <TileKey>[
          TileKey(-1, -1),
        ]);
      },
    );

    test('resize journal undo and redo restore bounds and pixels', () async {
      final before = _oneLayerState(width: 4, height: 4, x: 0, y: 1);
      final operation = resizeCanvas(
        state: before,
        width: 2,
        height: 3,
        anchor: CanvasResizeAnchor.bottomRight,
        sequence: 1,
        timestampMs: 0,
      );

      final states = await _journalRoundTrip(before, operation);

      expect(states.undone.canvas.width, 4);
      expect(_pixel(states.undone.tiles, 'L1', 0, 1), _red);
      expect(states.redone.canvas.width, 2);
      expect(_pixel(states.redone.tiles, 'L1', -2, 0), _red);
    });
  });

  group('horizontal canvas flip', () {
    test('uses exact canvas width rather than tile-grid width', () {
      final before = _oneLayerState(width: 300, height: 20, x: 0, y: 2);

      final operation = flipCanvasHorizontally(
        state: before,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 299, 2), _red);
      expect(operation.state.layers.single.tiles, const <TileKey>[
        TileKey(1, 0),
      ]);
    });

    test('right canvas edge maps back to x zero', () {
      final before = _oneLayerState(width: 300, height: 20, x: 299, y: 2);

      final operation = flipCanvasHorizontally(
        state: before,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 0, 2), _red);
    });

    test('off-left pixels are preserved beyond the right edge', () {
      final tiles = TileStore()
        ..publish('L1', const TileKey(-1, 0), _pixelTile(254, 3, _red));
      final before = _state(
        width: 300,
        height: 20,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer')],
        tiles: tiles,
      );

      final operation = flipCanvasHorizontally(
        state: before,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 301, 3), _red);
    });

    test('off-canvas y coordinates remain unchanged', () {
      final tiles = TileStore()
        ..publish('L1', const TileKey(0, -1), _pixelTile(2, 255, _red));
      final before = _state(
        width: 10,
        height: 10,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer')],
        tiles: tiles,
      );

      final operation = flipCanvasHorizontally(
        state: before,
        sequence: 1,
        timestampMs: 0,
      );

      expect(_pixel(operation.state.tiles, 'L1', 7, -1), _red);
    });

    test('flip remains involutive for pixels preserved by shrink', () {
      final before = _oneLayerState(width: 4, height: 4, x: 0, y: 0);
      final shrunk = resizeCanvas(
        state: before,
        width: 2,
        height: 2,
        anchor: CanvasResizeAnchor.bottomRight,
        sequence: 1,
        timestampMs: 0,
      );
      final first = flipCanvasHorizontally(
        state: shrunk.state,
        sequence: 2,
        timestampMs: 0,
      );
      final second = flipCanvasHorizontally(
        state: first.state,
        sequence: 3,
        timestampMs: 0,
      );

      expect(_pixel(shrunk.state.tiles, 'L1', -2, -2), _red);
      expect(_pixel(first.state.tiles, 'L1', 3, -2), _red);
      expect(_pixel(second.state.tiles, 'L1', -2, -2), _red);
    });

    test('all-transparent source tiles are pruned', () {
      final tiles = TileStore()
        ..publish(
          'L1',
          const TileKey(0, 0),
          Tile.takeOwnership(Uint8List(Tile.byteLength)),
        );
      final before = _state(
        width: 10,
        height: 10,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer')],
        tiles: tiles,
      );

      final operation = flipCanvasHorizontally(
        state: before,
        sequence: 1,
        timestampMs: 0,
      );

      expect(operation.state.tiles.tileCountForLayer('L1'), 0);
      expect(operation.entry.beforeTiles, isEmpty);
      expect(operation.entry.afterTiles, isEmpty);
    });

    test(
      'flip journal undo and redo use the same no-snapshot transform',
      () async {
        final before = _oneLayerState(width: 300, height: 20, x: -1, y: 2);
        final operation = flipCanvasHorizontally(
          state: before,
          sequence: 1,
          timestampMs: 0,
        );

        final states = await _journalRoundTrip(before, operation);

        expect(operation.entry.kind, JournalKind.canvasFlip);
        expect(operation.entry.completeLayerSnapshots, isFalse);
        expect(_pixel(states.undone.tiles, 'L1', -1, 2), _red);
        expect(_pixel(states.redone.tiles, 'L1', 300, 2), _red);
      },
    );
  });

  group('clear layer', () {
    test('visible unlocked content clears with before tiles', () {
      final before = _oneLayerState(width: 20, height: 20, x: 2, y: 3);

      final result = clearLayer(
        state: before,
        layerId: 'L1',
        sequence: 1,
        timestampMs: 0,
      );
      final operation = _applied(result);

      expect(operation.entry.kind, JournalKind.layerClear);
      expect(operation.entry.affectedKeys, const <TileKey>[TileKey(0, 0)]);
      expect(operation.entry.beforeTiles, hasLength(1));
      expect(operation.state.tiles.tileCountForLayer('L1'), 0);
    });

    test('locked content is a typed no-op', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer', locked: true)],
        tiles: TileStore(),
      );

      final result = clearLayer(
        state: before,
        layerId: 'L1',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.isApplied, isFalse);
      expect(result.block, LayerOperationBlock.locked);
      expect(result.layerId, 'L1');
    });

    test('hidden content is a typed no-op', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer', visible: false)],
        tiles: TileStore(),
      );

      final result = clearLayer(
        state: before,
        layerId: 'L1',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.isApplied, isFalse);
      expect(result.block, LayerOperationBlock.hidden);
    });

    test('hidden takes precedence when clear target is also locked', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'L1', name: 'Layer', visible: false, locked: true),
        ],
        tiles: TileStore(),
      );

      final result = clearLayer(
        state: before,
        layerId: 'L1',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.block, LayerOperationBlock.hidden);
      expect(result.layerId, 'L1');
    });

    test('clear journal undo and redo restore then remove content', () async {
      final before = _oneLayerState(width: 20, height: 20, x: 2, y: 3);
      final operation = _applied(
        clearLayer(state: before, layerId: 'L1', sequence: 1, timestampMs: 0),
      );

      final states = await _journalRoundTrip(before, operation);

      expect(_pixel(states.undone.tiles, 'L1', 2, 3), _red);
      expect(states.redone.tiles.tileCountForLayer('L1'), 0);
    });
  });

  group('layer structure operations', () {
    test(
      'add inserts at z-index and round-trips through the journal',
      () async {
        final before = _state(
          width: 20,
          height: 20,
          layers: <InkLayer>[
            InkLayer(id: 'bottom', name: 'Bottom'),
            InkLayer(id: 'top', name: 'Top'),
          ],
          tiles: TileStore(),
        );
        final operation = addLayer(
          state: before,
          layer: InkLayer(id: 'middle', name: 'Middle'),
          index: 1,
          sequence: 1,
          timestampMs: 0,
        );

        expect(operation.entry.kind, JournalKind.layerAdd);
        expect(operation.state.layers.map((layer) => layer.id), <String>[
          'bottom',
          'middle',
          'top',
        ]);
        final states = await _journalRoundTrip(before, operation);
        expect(states.undone.layers.map((layer) => layer.id), <String>[
          'bottom',
          'top',
        ]);
        expect(states.undone.tiles.containsLayer('middle'), isFalse);
        expect(states.redone.layers.map((layer) => layer.id), <String>[
          'bottom',
          'middle',
          'top',
        ]);
        expect(states.redone.tiles.containsLayer('middle'), isTrue);
      },
    );

    test('add enforces the twelve-content-layer cap', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          for (var index = 0; index < 12; index += 1)
            InkLayer(id: 'L$index', name: 'Layer $index'),
        ],
        tiles: TileStore(),
      );

      expect(
        () => addLayer(
          state: before,
          layer: InkLayer(id: 'extra', name: 'Extra'),
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test('add rejects raster-bearing metadata without tile payload', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => addLayer(
          state: before,
          layer: InkLayer(
            id: 'L2',
            name: 'Invalid',
            tiles: const <TileKey>[TileKey(0, 0)],
          ),
          sequence: 1,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
    });

    test(
      'duplicate shares immutable COW refs and journal round-trips',
      () async {
        final tile = _pixelTile(1, 2, _red);
        final tiles = TileStore()..publish('source', const TileKey(0, 0), tile);
        final before = _state(
          width: 20,
          height: 20,
          layers: <InkLayer>[
            InkLayer(id: 'source', name: 'Source', opacity: 50),
          ],
          tiles: tiles,
        );
        final operation = duplicateLayer(
          state: before,
          sourceLayerId: 'source',
          newLayerId: 'copy',
          newName: 'Copy',
          sequence: 1,
          timestampMs: 0,
        );

        expect(operation.entry.kind, JournalKind.layerAdd);
        expect(operation.entry.completeLayerSnapshots, isTrue);
        expect(
          operation.state.tiles.tile('copy', const TileKey(0, 0)),
          same(operation.state.tiles.tile('source', const TileKey(0, 0))),
        );
        expect(operation.state.layers.last.opacity, 50);
        final states = await _journalRoundTrip(before, operation);
        expect(states.undone.layers.map((layer) => layer.id), <String>[
          'source',
        ]);
        expect(states.redone.layers.map((layer) => layer.id), <String>[
          'source',
          'copy',
        ]);
        expect(_pixel(states.redone.tiles, 'copy', 1, 2), _red);
      },
    );

    test('remove takes complete snapshots and journal round-trips', () async {
      final tiles = TileStore()
        ..publish('bottom', const TileKey(0, 0), _pixelTile(1, 1, _red))
        ..publish('top', const TileKey(0, 0), _pixelTile(2, 2, _blue));
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top'),
        ],
        tiles: tiles,
      );
      final operation = removeLayer(
        state: before,
        layerId: 'top',
        sequence: 1,
        timestampMs: 0,
      );

      expect(operation.entry.kind, JournalKind.layerRemove);
      expect(operation.entry.completeLayerSnapshots, isTrue);
      expect(operation.state.layers.map((layer) => layer.id), <String>[
        'bottom',
      ]);
      final states = await _journalRoundTrip(before, operation);
      expect(_pixel(states.undone.tiles, 'top', 2, 2), _blue);
      expect(states.redone.tiles.containsLayer('top'), isFalse);
    });

    test('remove rejects deleting the final content layer', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => removeLayer(
          state: before,
          layerId: 'L1',
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test(
      'reorder changes bottom-to-top order and journal round-trips',
      () async {
        final before = _state(
          width: 20,
          height: 20,
          layers: <InkLayer>[
            InkLayer(id: 'a', name: 'A'),
            InkLayer(id: 'b', name: 'B'),
            InkLayer(id: 'c', name: 'C'),
          ],
          tiles: TileStore(),
        );
        final operation = reorderLayer(
          state: before,
          layerId: 'a',
          index: 2,
          sequence: 1,
          timestampMs: 0,
        );

        expect(operation.entry.kind, JournalKind.layerReorder);
        expect(operation.state.layers.map((layer) => layer.id), <String>[
          'b',
          'c',
          'a',
        ]);
        final states = await _journalRoundTrip(before, operation);
        expect(states.undone.layers.map((layer) => layer.id), <String>[
          'a',
          'b',
          'c',
        ]);
        expect(states.redone.layers.map((layer) => layer.id), <String>[
          'b',
          'c',
          'a',
        ]);
      },
    );

    test('reorder rejects an out-of-range destination', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => reorderLayer(
          state: before,
          layerId: 'L1',
          index: 1,
          sequence: 1,
          timestampMs: 0,
        ),
        throwsRangeError,
      );
    });

    test('reorder rejects an unchanged z-index', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => reorderLayer(
          state: before,
          layerId: 'L1',
          index: 0,
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test(
      'property update journals rename visibility lock opacity and blend',
      () async {
        final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);
        final operation = updateLayerProperties(
          state: before,
          layerId: 'L1',
          name: 'Changed',
          visible: false,
          locked: true,
          opacity: 40,
          blend: LayerBlendMode.multiply,
          sequence: 1,
          timestampMs: 0,
        );

        final changed = operation.state.layers.single;
        expect(operation.entry.kind, JournalKind.layerProps);
        expect(changed.name, 'Changed');
        expect(changed.visible, isFalse);
        expect(changed.locked, isTrue);
        expect(changed.opacity, 40);
        expect(changed.blend, 'multiply');
        final states = await _journalRoundTrip(before, operation);
        expect(states.undone.layers.single.name, 'Layer');
        expect(states.redone.layers.single.name, 'Changed');
      },
    );

    test('property update rejects unchanged values', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => updateLayerProperties(
          state: before,
          layerId: 'L1',
          name: 'Layer',
          visible: true,
          locked: false,
          opacity: 100,
          blend: LayerBlendMode.normal,
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test('add rejects unknown forward-compatible blend identifiers', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => addLayer(
          state: before,
          layer: InkLayer(id: 'L2', name: 'Future', blend: 'screen'),
          sequence: 1,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('merge down', () {
    test('normal opacity is baked and survivor metadata is normalized', () {
      final tiles = TileStore()
        ..publish('bottom', const TileKey(0, 0), _solidPixelTile(_blue))
        ..publish('top', const TileKey(0, 0), _solidPixelTile(_red));
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', opacity: 50),
        ],
        tiles: tiles,
      );

      final operation = _applied(
        mergeLayerDown(
          state: before,
          topLayerId: 'top',
          sequence: 1,
          timestampMs: 0,
        ),
      );

      expect(operation.entry.kind, JournalKind.merge);
      expect(operation.entry.completeLayerSnapshots, isTrue);
      expect(operation.state.layers, hasLength(1));
      final survivor = operation.state.layers.single;
      expect(survivor.id, 'bottom');
      expect(survivor.name, 'Bottom');
      expect(survivor.visible, isTrue);
      expect(survivor.locked, isFalse);
      expect(survivor.opacity, 100);
      expect(survivor.blend, 'normal');
      expect(_pixel(operation.state.tiles, 'bottom', 0, 0), <int>[
        128,
        0,
        127,
        255,
      ]);
    });

    test('multiply blend uses compositor semantics', () {
      final tiles = TileStore()
        ..publish(
          'bottom',
          const TileKey(0, 0),
          _solidPixelTile(const <int>[100, 100, 100, 255]),
        )
        ..publish(
          'top',
          const TileKey(0, 0),
          _solidPixelTile(const <int>[200, 0, 0, 255]),
        );
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', blend: 'multiply'),
        ],
        tiles: tiles,
      );

      final operation = _applied(
        mergeLayerDown(
          state: before,
          topLayerId: 'top',
          sequence: 1,
          timestampMs: 0,
        ),
      );

      expect(_pixel(operation.state.tiles, 'bottom', 0, 0), <int>[
        78,
        0,
        0,
        255,
      ]);
    });

    test(
      'merge journal undo restores both layers and redo re-flattens',
      () async {
        final tiles = TileStore()
          ..publish('bottom', const TileKey(0, 0), _solidPixelTile(_blue))
          ..publish('top', const TileKey(0, 0), _solidPixelTile(_red));
        final before = _state(
          width: 20,
          height: 20,
          layers: <InkLayer>[
            InkLayer(id: 'bottom', name: 'Bottom'),
            InkLayer(id: 'top', name: 'Top'),
          ],
          tiles: tiles,
        );
        final operation = _applied(
          mergeLayerDown(
            state: before,
            topLayerId: 'top',
            sequence: 1,
            timestampMs: 0,
          ),
        );

        final states = await _journalRoundTrip(before, operation);

        expect(states.undone.layers.map((layer) => layer.id), <String>[
          'bottom',
          'top',
        ]);
        expect(_pixel(states.undone.tiles, 'top', 0, 0), _red);
        expect(states.redone.layers.map((layer) => layer.id), <String>[
          'bottom',
        ]);
        expect(_pixel(states.redone.tiles, 'bottom', 0, 0), _red);
      },
    );

    test('locked top layer produces a typed no-op', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', locked: true),
        ],
        tiles: TileStore(),
      );

      final result = mergeLayerDown(
        state: before,
        topLayerId: 'top',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.block, LayerOperationBlock.locked);
      expect(result.layerId, 'top');
    });

    test('hidden takes precedence when a source is also locked', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', visible: false, locked: true),
        ],
        tiles: TileStore(),
      );

      final result = mergeLayerDown(
        state: before,
        topLayerId: 'top',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.block, LayerOperationBlock.hidden);
      expect(result.layerId, 'top');
    });

    test('hidden lower layer produces a typed no-op', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom', visible: false),
          InkLayer(id: 'top', name: 'Top'),
        ],
        tiles: TileStore(),
      );

      final result = mergeLayerDown(
        state: before,
        topLayerId: 'top',
        sequence: 1,
        timestampMs: 0,
      );

      expect(result.block, LayerOperationBlock.hidden);
      expect(result.layerId, 'bottom');
    });

    test('bottom layer cannot merge down', () {
      final before = _oneLayerState(width: 20, height: 20, x: 0, y: 0);

      expect(
        () => mergeLayerDown(
          state: before,
          topLayerId: 'L1',
          sequence: 1,
          timestampMs: 0,
        ),
        throwsStateError,
      );
    });

    test('merge rejects unknown blend instead of treating it as normal', () {
      final before = _state(
        width: 20,
        height: 20,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', blend: 'screen'),
        ],
        tiles: TileStore(),
      );

      expect(
        () => mergeLayerDown(
          state: before,
          topLayerId: 'top',
          sequence: 1,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('layer stack compositing helper', () {
    test('omits transparent flattened tiles', () {
      final tiles = TileStore()
        ..publish(
          'layer',
          const TileKey(2, 3),
          Tile.takeOwnership(Uint8List(Tile.byteLength)),
        );

      final result = compositeLayerStack(
        layers: <InkLayer>[InkLayer(id: 'layer', name: 'Layer')],
        tiles: tiles,
      );

      expect(result, isEmpty);
      expect(
        () => result[const TileKey(0, 0)] = _solidPixelTile(_red),
        throwsUnsupportedError,
      );
    });

    test('uses only keys belonging to requested layers', () {
      final tiles = TileStore()
        ..publish('wanted', const TileKey(0, 0), _solidPixelTile(_red))
        ..publish('other', const TileKey(4, 4), _solidPixelTile(_blue));

      final result = compositeLayerStack(
        layers: <InkLayer>[InkLayer(id: 'wanted', name: 'Wanted')],
        tiles: tiles,
      );

      expect(result.keys, const <TileKey>[TileKey(0, 0)]);
    });
  });
}

const List<int> _clear = <int>[0, 0, 0, 0];
const List<int> _red = <int>[255, 0, 0, 255];
const List<int> _blue = <int>[0, 0, 255, 255];

JournalDocumentState _oneLayerState({
  required int width,
  required int height,
  required int x,
  required int y,
}) {
  final key = TileKey(_tileCoordinate(x), _tileCoordinate(y));
  final localX = x - key.x * Tile.edge;
  final localY = y - key.y * Tile.edge;
  final tiles = TileStore()
    ..publish('L1', key, _pixelTile(localX, localY, _red));
  return _state(
    width: width,
    height: height,
    layers: <InkLayer>[InkLayer(id: 'L1', name: 'Layer')],
    tiles: tiles,
  );
}

JournalDocumentState _state({
  required int width,
  required int height,
  required List<InkLayer> layers,
  required TileStore tiles,
}) => JournalDocumentState(
  tiles: tiles,
  layers: <InkLayer>[
    for (final layer in layers)
      layer.copyWith(tiles: tiles.occupiedKeys(layer.id)),
  ],
  canvas: CanvasSpec(width: width, height: height),
);

Tile _pixelTile(int x, int y, List<int> rgba) {
  final pixels = Uint8List(Tile.byteLength);
  final offset = (y * Tile.edge + x) * Tile.bytesPerPixel;
  pixels.setRange(offset, offset + Tile.bytesPerPixel, rgba);
  return Tile.takeOwnership(pixels);
}

Tile _solidPixelTile(List<int> rgba) => _pixelTile(0, 0, rgba);

List<int> _pixel(TileStore store, String layerId, int x, int y) {
  final tileX = _tileCoordinate(x);
  final tileY = _tileCoordinate(y);
  final tile = store.tile(layerId, TileKey(tileX, tileY));
  if (tile == null) {
    return _clear;
  }
  final localX = x - tileX * Tile.edge;
  final localY = y - tileY * Tile.edge;
  final offset = (localY * Tile.edge + localX) * Tile.bytesPerPixel;
  return tile.pixels.sublist(offset, offset + Tile.bytesPerPixel);
}

int _tileCoordinate(int pixel) =>
    pixel >= 0 ? pixel ~/ Tile.edge : -((-pixel + Tile.edge - 1) ~/ Tile.edge);

JournaledEngineOperation _applied(LayerOperationResult result) {
  expect(result.isApplied, isTrue);
  return result.operation!;
}

Future<({JournalDocumentState undone, JournalDocumentState redone})>
_journalRoundTrip(
  JournalDocumentState before,
  JournaledEngineOperation operation,
) async {
  final journal = UndoJournal(storage: InMemoryJournalStorage());
  await journal.commit(operation.entry);
  final undo = await journal.undo(operation.state);
  expect(undo, isNotNull);
  final redo = await journal.redo(undo!.state);
  expect(redo, isNotNull);
  return (undone: undo.state, redone: redo!.state);
}
