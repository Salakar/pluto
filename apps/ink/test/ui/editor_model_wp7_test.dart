import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/canvas_ops.dart';
import 'package:paper_ink/src/model/editor_model.dart';
import 'package:paper_ink/src/ui/canvas_view.dart';

void main() {
  group('WP7 editor naming', () {
    test('artwork rename trims copy and publishes one dirty revision', () {
      final _EditorFixture fixture = _fixture(nowMilliseconds: () => 4200);
      addTearDown(fixture.dispose);
      var notifications = 0;
      fixture.model.addListener(() => notifications += 1);

      fixture.model.renameArtwork('  Field notes  ');

      expect(fixture.model.document.name, 'Field notes');
      expect(fixture.model.document.modifiedAtMs, 4200);
      expect(fixture.model.dirty, isTrue);
      expect(notifications, 1);
    });

    test('rename to the normalized current name is a notifier no-op', () {
      final _EditorFixture fixture = _fixture();
      addTearDown(fixture.dispose);
      final InkDocument before = fixture.model.document;
      var notifications = 0;
      fixture.model.addListener(() => notifications += 1);

      fixture.model.renameArtwork('  Draft  ');

      expect(fixture.model.document, same(before));
      expect(fixture.model.dirty, isFalse);
      expect(notifications, 0);
    });

    test('blank artwork names are rejected without mutation', () {
      final _EditorFixture fixture = _fixture();
      addTearDown(fixture.dispose);
      final InkDocument before = fixture.model.document;

      for (final String value in <String>['', '   ', '\n\t']) {
        expect(
          () => fixture.model.renameArtwork(value),
          throwsArgumentError,
          reason: 'value: ${value.codeUnits}',
        );
      }

      expect(fixture.model.document, same(before));
      expect(fixture.model.dirty, isFalse);
    });
  });

  group('WP7 active-layer selection', () {
    test('selects by stable id and updates the ordinal atomically', () {
      final _EditorFixture fixture = _fixture(
        layers: <InkLayer>[
          InkLayer(id: 'base', name: 'Paper'),
          InkLayer(id: 'ink', name: 'Ink'),
        ],
        activeLayerId: 'base',
      );
      addTearDown(fixture.dispose);
      var notifications = 0;
      fixture.model.addListener(() => notifications += 1);

      fixture.model.selectActiveLayer('ink');

      expect(fixture.model.activeLayer.id, 'ink');
      expect(fixture.model.activeLayerOrdinal, 2);
      expect(fixture.model.document.activeLayerId, 'ink');
      expect(fixture.model.dirty, isTrue);
      expect(notifications, 1);
    });

    test('selecting the active layer is a notifier no-op', () {
      final _EditorFixture fixture = _fixture();
      addTearDown(fixture.dispose);
      final InkDocument before = fixture.model.document;
      var notifications = 0;
      fixture.model.addListener(() => notifications += 1);

      fixture.model.selectActiveLayer('base');

      expect(fixture.model.document, same(before));
      expect(fixture.model.dirty, isFalse);
      expect(notifications, 0);
    });

    test('unknown layer ids are rejected without changing selection', () {
      final _EditorFixture fixture = _fixture();
      addTearDown(fixture.dispose);

      expect(
        () => fixture.model.selectActiveLayer('missing'),
        throwsArgumentError,
      );
      expect(fixture.model.activeLayer.id, 'base');
      expect(fixture.model.dirty, isFalse);
    });
  });

  group('WP7 journaled engine publication', () {
    test(
      'commits duplicate, preserves store identity, and shares tile identity',
      () async {
        final _EditorFixture fixture = _fixture(
          layers: <InkLayer>[
            InkLayer(id: 'base', name: 'Paper'),
            InkLayer(id: 'ink', name: 'Ink'),
          ],
          activeLayerId: 'ink',
          nowMilliseconds: () => 9000,
        );
        addTearDown(fixture.dispose);
        const TileKey key = TileKey(0, 0);
        final Tile tile = _tile(0x7f);
        fixture.tiles.publish('ink', key, tile);
        final TileStore observedStore = fixture.model.tiles;
        final JournaledEngineOperation operation = duplicateLayer(
          state: fixture.engineState,
          sourceLayerId: 'ink',
          newLayerId: 'copy',
          newName: 'Ink copy',
          sequence: fixture.journal.nextSequence,
          timestampMs: 8900,
        );
        final List<CommitPhase> phases = <CommitPhase>[];
        fixture.model.addListener(() => phases.add(fixture.model.commitPhase));

        final Future<void> pending = fixture.model.applyEngineOperation(
          operation,
          activeLayerId: 'copy',
        );
        expect(fixture.model.commitPhase, CommitPhase.compositing);
        await pending;

        expect(fixture.model.tiles, same(observedStore));
        expect(fixture.model.tiles.tile('ink', key), same(tile));
        expect(fixture.model.tiles.tile('copy', key), same(tile));
        expect(
          fixture.model.contentLayers.map((InkLayer layer) => layer.id),
          <String>['base', 'ink', 'copy'],
        );
        expect(fixture.model.activeLayer.id, 'copy');
        expect(fixture.journal.headSeq, operation.entry.seq);
        expect(fixture.journal.entries.single.kind, JournalKind.layerAdd);
        expect(fixture.model.document.journalHeadSeq, fixture.journal.headSeq);
        expect(fixture.model.document.modifiedAtMs, 9000);
        expect(fixture.model.dirty, isTrue);
        expect(phases, <CommitPhase>[
          CommitPhase.compositing,
          CommitPhase.idle,
        ]);
      },
    );

    test(
      'an added empty layer remains represented in the observed store',
      () async {
        final _EditorFixture fixture = _fixture();
        addTearDown(fixture.dispose);
        final JournaledEngineOperation operation = addLayer(
          state: fixture.engineState,
          layer: InkLayer(id: 'notes', name: 'Notes'),
          sequence: fixture.journal.nextSequence,
          timestampMs: 2000,
        );

        await fixture.model.applyEngineOperation(
          operation,
          activeLayerId: 'notes',
        );

        expect(fixture.model.tiles.containsLayer('notes'), isTrue);
        expect(
          fixture.model.tiles.layerIds,
          unorderedEquals(<String>['base', 'notes']),
        );
        expect(fixture.model.activeLayer.id, 'notes');
      },
    );

    test(
      'a removed layer is absent from document and observed store',
      () async {
        final _EditorFixture fixture = _fixture(
          layers: <InkLayer>[
            InkLayer(id: 'base', name: 'Paper'),
            InkLayer(id: 'ink', name: 'Ink'),
          ],
          activeLayerId: 'ink',
        );
        addTearDown(fixture.dispose);
        fixture.tiles.publish('ink', const TileKey(2, -1), _tile(0xff));
        final JournaledEngineOperation operation = removeLayer(
          state: fixture.engineState,
          layerId: 'ink',
          sequence: fixture.journal.nextSequence,
          timestampMs: 2100,
        );

        await fixture.model.applyEngineOperation(operation);

        expect(fixture.model.contentLayers.single.id, 'base');
        expect(fixture.model.activeLayer.id, 'base');
        expect(fixture.model.tiles.containsLayer('ink'), isFalse);
        expect(fixture.model.tiles.layerIds, <String>['base']);
      },
    );

    test(
      'layer rename is journaled while retaining active selection',
      () async {
        final _EditorFixture fixture = _fixture();
        addTearDown(fixture.dispose);
        final JournaledEngineOperation operation = updateLayerProperties(
          state: fixture.engineState,
          layerId: 'base',
          name: 'Contour notes',
          sequence: fixture.journal.nextSequence,
          timestampMs: 2200,
        );

        await fixture.model.applyEngineOperation(operation);

        expect(fixture.model.activeLayer.id, 'base');
        expect(fixture.model.activeLayer.name, 'Contour notes');
        expect(fixture.journal.entries.single.kind, JournalKind.layerProps);
      },
    );

    test(
      'invalid requested selection falls back to the resulting top layer',
      () async {
        final _EditorFixture fixture = _fixture();
        addTearDown(fixture.dispose);
        final JournaledEngineOperation operation = addLayer(
          state: fixture.engineState,
          layer: InkLayer(id: 'top', name: 'Top'),
          sequence: fixture.journal.nextSequence,
          timestampMs: 2300,
        );

        await fixture.model.applyEngineOperation(
          operation,
          activeLayerId: 'not-in-result',
        );

        expect(fixture.model.activeLayer.id, 'top');
      },
    );

    test(
      'journal failure returns commit phase to idle without publication',
      () async {
        final InMemoryJournalStorage storage = InMemoryJournalStorage();
        final UndoJournal journal = UndoJournal(
          storage: storage,
          interrupt: (JournalInterruptionPoint point) {
            if (point == JournalInterruptionPoint.afterAppend) {
              throw StateError('injected append failure');
            }
          },
        );
        final _EditorFixture fixture = _fixture(journal: journal);
        addTearDown(fixture.dispose);
        const TileKey key = TileKey(0, 0);
        final Tile originalTile = _tile(0x55);
        fixture.tiles.publish('base', key, originalTile);
        final InkDocument beforeDocument = fixture.model.document;
        final JournaledEngineOperation operation = addLayer(
          state: fixture.engineState,
          layer: InkLayer(id: 'never-published', name: 'Never published'),
          sequence: fixture.journal.nextSequence,
          timestampMs: 2400,
        );
        final List<CommitPhase> phases = <CommitPhase>[];
        fixture.model.addListener(() => phases.add(fixture.model.commitPhase));

        await expectLater(
          fixture.model.applyEngineOperation(operation),
          throwsA(isA<StateError>()),
        );

        expect(fixture.model.commitPhase, CommitPhase.idle);
        expect(fixture.model.document, same(beforeDocument));
        expect(fixture.model.tiles.tile('base', key), same(originalTile));
        expect(fixture.model.tiles.containsLayer('never-published'), isFalse);
        expect(fixture.model.dirty, isFalse);
        expect(fixture.journal.entries, isEmpty);
        expect(fixture.journal.headSeq, 0);
        expect(storage.durableLines, isEmpty);
        expect(phases, <CommitPhase>[
          CommitPhase.compositing,
          CommitPhase.idle,
        ]);
      },
    );
  });

  group('WP7 canvas history feedback', () {
    test('label table covers every durable journal kind exactly once', () {
      expect(_historyLabels.keys, unorderedEquals(JournalKind.values));
      expect(_historyLabels, hasLength(JournalKind.values.length));
    });

    for (final JournalKind kind in JournalKind.values) {
      test('${kind.name} has canonical undo and redo copy', () {
        final String label = _historyLabels[kind]!;

        expect(
          CanvasHistoryFeedback(isRedo: false, kind: kind).message,
          'undid $label',
        );
        expect(
          CanvasHistoryFeedback(isRedo: true, kind: kind).message,
          'redid $label',
        );
      });
    }
  });
}

const Map<JournalKind, String> _historyLabels = <JournalKind, String>{
  JournalKind.stroke: 'stroke',
  JournalKind.erase: 'erase',
  JournalKind.fill: 'fill',
  JournalKind.shape: 'shape',
  JournalKind.text: 'text',
  JournalKind.floatCommit: 'move',
  JournalKind.layerAdd: 'layer add',
  JournalKind.layerRemove: 'layer delete',
  JournalKind.layerReorder: 'layer reorder',
  JournalKind.layerProps: 'layer change',
  JournalKind.layerClear: 'layer clear',
  JournalKind.canvasResize: 'canvas resize',
  JournalKind.canvasFlip: 'canvas flip',
  JournalKind.merge: 'layer merge',
};

final class _EditorFixture {
  const _EditorFixture({
    required this.model,
    required this.tiles,
    required this.journal,
  });

  final EditorModel model;
  final TileStore tiles;
  final UndoJournal journal;

  JournalDocumentState get engineState => JournalDocumentState(
    tiles: tiles,
    layers: model.contentLayers,
    canvas: model.document.canvas,
  );

  void dispose() => model.dispose();
}

_EditorFixture _fixture({
  List<InkLayer>? layers,
  String? activeLayerId,
  UndoJournal? journal,
  int Function()? nowMilliseconds,
}) {
  final List<InkLayer> resolvedLayers =
      layers ?? <InkLayer>[InkLayer(id: 'base', name: 'Paper')];
  final TileStore tiles = TileStore();
  for (final InkLayer layer in resolvedLayers) {
    tiles.ensureLayer(layer.id);
  }
  final UndoJournal resolvedJournal =
      journal ?? UndoJournal(storage: InMemoryJournalStorage());
  final InkDocument document =
      InkDocument.blank(
        id: 'wp7-editor-model',
        name: 'Draft',
        nowMs: 1000,
      ).copyWith(
        layers: resolvedLayers,
        activeLayerId: activeLayerId ?? resolvedLayers.first.id,
      );
  final EditorModel model = EditorModel(
    document: document,
    tiles: tiles,
    journal: resolvedJournal,
    nowMilliseconds: nowMilliseconds,
  );
  return _EditorFixture(model: model, tiles: tiles, journal: resolvedJournal);
}

Tile _tile(int alpha) {
  final Uint8List pixels = Uint8List(Tile.byteLength);
  pixels[3] = alpha;
  return Tile.takeOwnership(pixels);
}
