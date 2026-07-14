import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';

void main() {
  test('stroke erase omits a batch in one undoable committed result', () async {
    final InMemoryJournalStorage storage = InMemoryJournalStorage();
    final UndoJournal journal = UndoJournal(
      storage: storage,
      recipeRenderer: _additiveRenderer,
    );
    var state = _blankState();
    for (var sequence = 1; sequence <= 3; sequence += 1) {
      final JournalEntry entry = _strokeEntry(
        sequence,
        before: state.tiles.tile('ink', const TileKey(0, 0)),
      );
      final Map<TileKey, Tile?> rendered = await _additiveRenderer(
        RecipeReplayRequest(state: state, entry: entry),
      );
      state = applyJournalEntry(
        state,
        entry,
        direction: JournalDirection.forward,
        tiles: rendered,
      );
      await journal.commit(entry);
    }
    expect(state.tiles.tile('ink', const TileKey(0, 0))!.pixels.first, 6);

    final JournalDocumentState erased = await journal.replayWithoutStrokes(
      currentState: state,
      sequences: const <int>[1, 2],
    );
    final Tile erasedTile = erased.tiles.tile('ink', const TileKey(0, 0))!;
    expect(erasedTile.pixels.first, 3);

    final JournalEntry eraseEntry = JournalEntry(
      seq: journal.nextSequence,
      timestampMs: 10,
      kind: JournalKind.erase,
      layerId: 'ink',
      bounds: const JournalBounds(x: 0, y: 0, width: 1, height: 1),
      recipeCompacted: true,
      affectedKeys: const <TileKey>[TileKey(0, 0)],
      beforeTiles: <TileKey, Tile?>{
        const TileKey(0, 0): state.tiles.tile('ink', const TileKey(0, 0)),
      },
      afterTiles: <TileKey, Tile?>{const TileKey(0, 0): erasedTile},
      unknownFields: const <String, Object?>{
        'strokeEraseSequences': <int>[1, 2],
      },
    );
    await journal.commit(eraseEntry);

    expect(
      journal.entries.where((JournalEntry e) => e.kind == JournalKind.erase),
      hasLength(1),
    );
    expect(
      journal
          .strokeEraseCandidates(layerId: 'ink')
          .map((JournalEntry e) => e.seq),
      <int>[3],
    );
    final JournalStep undone = (await journal.undo(erased))!;
    expect(
      undone.state.tiles.tile('ink', const TileKey(0, 0))!.pixels.first,
      6,
    );
    final JournalStep redone = (await journal.redo(undone.state))!;
    expect(
      redone.state.tiles.tile('ink', const TileKey(0, 0))!.pixels.first,
      3,
    );
    await journal.close();
  });

  for (final JournalKind kind in <JournalKind>[
    JournalKind.fill,
    JournalKind.shape,
    JournalKind.text,
    JournalKind.floatCommit,
    JournalKind.layerClear,
    JournalKind.erase,
  ]) {
    test('${kind.name} snapshot action bounds the replayable tail', () async {
      final UndoJournal journal = UndoJournal(
        storage: InMemoryJournalStorage(),
      );
      await journal.commit(_strokeEntry(1, before: null));
      await journal.commit(_snapshotEntry(2, kind: kind));
      await journal.commit(_strokeEntry(3, before: _tile(2)));

      expect(
        journal
            .strokeEraseCandidates(layerId: 'ink')
            .map((JournalEntry entry) => entry.seq),
        <int>[3],
      );
      await journal.close();
    });
  }

  test('selection-clipped stroke bounds the replayable tail', () async {
    final UndoJournal journal = UndoJournal(storage: InMemoryJournalStorage());
    await journal.commit(_strokeEntry(1, before: null));
    await journal.commit(
      _strokeEntry(
        2,
        before: _tile(1),
        unknownFields: const <String, Object?>{'strokeSelectionClipped': true},
      ),
    );
    await journal.commit(_strokeEntry(3, before: _tile(2)));

    expect(
      journal
          .strokeEraseCandidates(layerId: 'ink')
          .map((JournalEntry entry) => entry.seq),
      <int>[3],
    );
    await journal.close();
  });

  test('historical recipe metadata bounds the replayable tail', () async {
    final UndoJournal journal = UndoJournal(storage: InMemoryJournalStorage());
    await journal.commit(_strokeEntry(1, before: null));
    await journal.commit(
      _strokeEntry(
        2,
        before: _tile(1),
        unknownFields: const <String, Object?>{'strokeReplayVersion': 0},
      ),
    );
    await journal.commit(_strokeEntry(3, before: _tile(2)));

    expect(
      journal
          .strokeEraseCandidates(layerId: 'ink')
          .map((JournalEntry entry) => entry.seq),
      <int>[3],
    );
    await journal.close();
  });

  test('recipe pixel erase does not bound the replayable tail', () async {
    final UndoJournal journal = UndoJournal(storage: InMemoryJournalStorage());
    await journal.commit(_strokeEntry(1, before: null));
    await journal.commit(
      _strokeEntry(
        2,
        before: _tile(1),
        kind: JournalKind.erase,
        brushId: 'eraserpixel',
      ),
    );
    await journal.commit(_strokeEntry(3, before: _tile(2)));

    expect(
      journal
          .strokeEraseCandidates(layerId: 'ink')
          .map((JournalEntry entry) => entry.seq),
      <int>[1, 3],
    );
    await journal.close();
  });

  test('prior stroke-erase batch does not bound later kills', () async {
    final UndoJournal journal = UndoJournal(storage: InMemoryJournalStorage());
    await journal.commit(_strokeEntry(1, before: null));
    await journal.commit(_strokeEntry(2, before: _tile(1)));
    await journal.commit(
      JournalEntry(
        seq: 3,
        timestampMs: 3,
        kind: JournalKind.erase,
        layerId: 'ink',
        recipeCompacted: true,
        affectedKeys: const <TileKey>[TileKey(0, 0)],
        beforeTiles: <TileKey, Tile?>{const TileKey(0, 0): _tile(2)},
        afterTiles: <TileKey, Tile?>{const TileKey(0, 0): _tile(1)},
        unknownFields: const <String, Object?>{
          'strokeEraseSequences': <int>[1],
        },
      ),
    );
    await journal.commit(_strokeEntry(4, before: _tile(1)));

    expect(
      journal
          .strokeEraseCandidates(layerId: 'ink')
          .map((JournalEntry entry) => entry.seq),
      <int>[2, 4],
    );
    await journal.close();
  });
}

Future<Map<TileKey, Tile?>> _additiveRenderer(
  RecipeReplayRequest request,
) async {
  final Tile? before = request.state.tiles.tile(
    request.entry.layerId!,
    const TileKey(0, 0),
  );
  final Uint8List pixels = before?.mutableCopy() ?? Uint8List(Tile.byteLength);
  pixels[0] = pixels[0] + request.entry.recipe!.seed;
  return <TileKey, Tile?>{const TileKey(0, 0): Tile.takeOwnership(pixels)};
}

JournalEntry _strokeEntry(
  int sequence, {
  required Tile? before,
  JournalKind kind = JournalKind.stroke,
  String brushId = 'fineliner',
  Map<String, Object?> unknownFields = const <String, Object?>{},
}) => JournalEntry(
  seq: sequence,
  timestampMs: sequence,
  kind: kind,
  layerId: 'ink',
  bounds: const JournalBounds(x: 0, y: 0, width: 1, height: 1),
  recipe: StrokeRecipe(
    brushId: brushId,
    colorArgb: 0xff000000,
    size: 2,
    seed: sequence,
    transform: const <double>[1, 0, 0, 1, 0, 0],
    samples: Uint8List(0),
  ),
  affectedKeys: const <TileKey>[TileKey(0, 0)],
  beforeTiles: <TileKey, Tile?>{const TileKey(0, 0): before},
  afterTiles: <TileKey, Tile?>{
    const TileKey(0, 0): _tile((before?.pixels.first ?? 0) + sequence),
  },
  unknownFields: <String, Object?>{'strokeReplayVersion': 1, ...unknownFields},
);

JournalEntry _snapshotEntry(int sequence, {required JournalKind kind}) =>
    JournalEntry(
      seq: sequence,
      timestampMs: sequence,
      kind: kind,
      layerId: 'ink',
      recipeCompacted: kind == JournalKind.erase,
      affectedKeys: const <TileKey>[TileKey(0, 0)],
      beforeTiles: <TileKey, Tile?>{const TileKey(0, 0): _tile(sequence - 1)},
      afterTiles: <TileKey, Tile?>{const TileKey(0, 0): _tile(sequence)},
    );

JournalDocumentState _blankState() => JournalDocumentState(
  tiles: TileStore(),
  layers: <InkLayer>[InkLayer(id: 'ink', name: 'Ink')],
  canvas: CanvasSpec(width: 64, height: 64),
);

Tile _tile(int value) {
  final Uint8List pixels = Uint8List(Tile.byteLength)..[0] = value;
  return Tile.takeOwnership(pixels);
}
