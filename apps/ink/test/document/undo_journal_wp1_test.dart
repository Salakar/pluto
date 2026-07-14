import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  group('journal wire model', () {
    test('contains all fourteen binding kinds', () {
      expect(
        JournalKind.values.map((kind) => kind.name),
        orderedEquals(const [
          'stroke',
          'erase',
          'fill',
          'shape',
          'text',
          'floatCommit',
          'layerAdd',
          'layerRemove',
          'layerReorder',
          'layerProps',
          'layerClear',
          'canvasResize',
          'canvasFlip',
          'merge',
        ]),
      );
    });

    test('stroke recipe round-trips exact deterministic fields', () {
      final samples = Uint8List.fromList([0, 1, 2, 127, 255]);
      final recipe = StrokeRecipe(
        brushId: 'pencil6b',
        colorArgb: 0xff123456,
        size: 8,
        seed: 91237,
        transform: const [1, 0, 0, 1, 12, -4],
        samples: samples,
      );
      samples[0] = 99;

      expect(recipe.toJson(), {
        'brushId': 'pencil6b',
        'colorArgb': 0xff123456,
        'size': 8.0,
        'seed': 91237,
        'transform': const [1.0, 0.0, 0.0, 1.0, 12.0, -4.0],
        'samples': 'AAECf/8=',
      });
      final decoded = StrokeRecipe.fromJson(_jsonMap(recipe.toJson()));
      expect(decoded.brushId, recipe.brushId);
      expect(decoded.colorArgb, recipe.colorArgb);
      expect(decoded.size, recipe.size);
      expect(decoded.seed, recipe.seed);
      expect(decoded.transform, recipe.transform);
      expect(decoded.samples, orderedEquals([0, 1, 2, 127, 255]));
    });

    test('recipe buffers and transforms are published immutable', () {
      final recipe = _recipe(seed: 3);
      final samples = recipe.samples;
      samples[0] = 250;
      expect(recipe.samples.first, 3);
      expect(() => recipe.transform[0] = 2, throwsUnsupportedError);
    });

    test('recipe rejects invalid size and affine transform', () {
      expect(
        () => StrokeRecipe(
          brushId: 'pen',
          colorArgb: 0,
          size: 0,
          seed: 1,
          transform: const [1, 0, 0, 1, 0, 0],
          samples: Uint8List(0),
        ),
        throwsArgumentError,
      );
      expect(
        () => StrokeRecipe(
          brushId: 'pen',
          colorArgb: 0,
          size: 1,
          seed: 1,
          transform: const [1, 0, 0],
          samples: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('stroke and erase entries require recipes until compacted', () {
      expect(
        () => JournalEntry(seq: 1, timestampMs: 0, kind: JournalKind.stroke),
        throwsArgumentError,
      );
      expect(
        JournalEntry(
          seq: 1,
          timestampMs: 0,
          kind: JournalKind.erase,
          recipeCompacted: true,
        ).recipeCompacted,
        isTrue,
      );
    });

    test('entry round-trip preserves refs, state, and unknown keys', () {
      final entry = JournalEntry(
        seq: 42,
        timestampMs: 81,
        kind: JournalKind.stroke,
        layerId: 'L1',
        bounds: const JournalBounds(x: 1, y: 2, width: 3, height: 4),
        recipe: _recipe(seed: 42),
        affectedKeys: const [TileKey(0, 1), TileKey(-2, 3)],
        beforeReferences: const {'0_1': 'snapshots/$_hashA.tile', '-2_3': null},
        afterReferences: const {'0_1': 'snapshots/$_hashB.tile'},
        beforeState: const {'custom': true},
        afterState: const {'custom': false},
        unknownFields: const {'future': 9},
      );
      final decoded = JournalEntry.fromJson(_jsonMap(entry.toJson()));
      expect(decoded.seq, 42);
      expect(decoded.timestampMs, 81);
      expect(decoded.kind, JournalKind.stroke);
      expect(decoded.layerId, 'L1');
      expect(decoded.bounds, entry.bounds);
      expect(decoded.affectedKeys, entry.affectedKeys);
      expect(decoded.beforeReferences, entry.beforeReferences);
      expect(decoded.afterReferences, entry.afterReferences);
      expect(decoded.beforeState, {'custom': true});
      expect(decoded.afterState, {'custom': false});
      expect(decoded.toJson()['future'], 9);
    });

    test('bounds intersection is edge-exclusive', () {
      const bounds = JournalBounds(x: 10, y: 10, width: 5, height: 5);
      expect(
        bounds.intersects(
          const JournalBounds(x: 14, y: 14, width: 2, height: 2),
        ),
        isTrue,
      );
      expect(
        bounds.intersects(
          const JournalBounds(x: 15, y: 10, width: 2, height: 2),
        ),
        isFalse,
      );
    });
  });

  group('storage and write-ahead durability', () {
    test('in-memory append is not durable before flush', () async {
      final storage = InMemoryJournalStorage();
      await storage.appendJsonLine('{"seq":1}');
      expect(await storage.readJsonLines(), isEmpty);
      expect(await storage.crashClone().readJsonLines(), isEmpty);
      await storage.flush();
      expect(await storage.readJsonLines(), ['{"seq":1}']);
    });

    test('commit performs one append and one flush', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      await journal.commit(_fillEntry(1));
      expect(storage.appendCount, 1);
      expect(storage.flushCount, 1);
      expect(journal.headSeq, 1);
    });

    test('crash after append but before flush loses that action', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(
        storage: storage,
        interrupt: (point) {
          if (point == JournalInterruptionPoint.afterAppend) {
            throw StateError('power loss');
          }
        },
      );
      await expectLater(journal.commit(_fillEntry(1)), throwsStateError);
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      expect(reopened.entries, isEmpty);
    });

    test('crash after flush reopens the committed action', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(
        storage: storage,
        interrupt: (point) {
          if (point == JournalInterruptionPoint.afterFlush) {
            throw StateError('power loss');
          }
        },
      );
      await expectLater(journal.commit(_fillEntry(1)), throwsStateError);
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      expect(reopened.entries.map((entry) => entry.seq), [1]);
    });

    test('recover-on-open stops at the first malformed record', () async {
      final valid = jsonEncode(_fillEntry(2).toJson());
      final storage = InMemoryJournalStorage(
        durableLines: ['{', '{"type":"future"}', valid, valid],
      );
      final journal = await UndoJournal.open(storage: storage);
      expect(journal.entries, isEmpty);
      expect(storage.durableLines, isEmpty);
    });

    test('file storage rolls JSONL segments and reopens in order', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-journal-');
      addTearDown(() => temporary.delete(recursive: true));
      final storage = FileJournalStorage(root: temporary, segmentEntryLimit: 2);
      final journal = UndoJournal(storage: storage);
      for (var sequence = 1; sequence <= 5; sequence += 1) {
        await journal.commit(_fillEntry(sequence));
      }
      await journal.close();

      final files = temporary
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .toList();
      expect(files, hasLength(3));
      final reopened = await UndoJournal.open(
        storage: FileJournalStorage(root: temporary, segmentEntryLimit: 2),
      );
      expect(reopened.entries.map((entry) => entry.seq), [1, 2, 3, 4, 5]);
      await reopened.close();
    });

    test('filesystem snapshots are INKT files and content-dedupe', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-snaps-');
      addTearDown(() => temporary.delete(recursive: true));
      final storage = FileJournalStorage(
        root: temporary,
        nowMilliseconds: () => 1234,
      );
      final tile = _tile(19);
      final first = await storage.putSnapshot(tile);
      final second = await storage.putSnapshot(_tile(19));
      expect(second, first);
      expect(first, matches(RegExp(r'^snapshots/[0-9a-f]{64}\.tile$')));
      final bytes = await File('${temporary.path}/$first').readAsBytes();
      expect(bytes.take(4), [0x49, 0x4e, 0x4b, 0x54]);
      _expectTile(await storage.readSnapshot(first), tile);
      expect(await storage.listSnapshotReferences(), {first});
      await storage.close();
    });

    test('snapshot content hash matches the SHA-256 known vector', () async {
      final storage = InMemoryJournalStorage();
      final reference = await storage.putSnapshot(
        Tile.takeOwnership(Uint8List(Tile.byteLength)),
      );
      expect(
        reference,
        'snapshots/'
        '8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90'
        '.tile',
      );
    });

    test('corrupt filesystem snapshot is quarantined', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-corrupt-');
      addTearDown(() => temporary.delete(recursive: true));
      final storage = FileJournalStorage(
        root: temporary,
        nowMilliseconds: () => 1234,
      );
      final reference = await storage.putSnapshot(_tile(23));
      await File(
        '${temporary.path}/$reference',
      ).writeAsBytes(InkTileCodec.encodeTile(_tile(24)));
      expect(await storage.readSnapshot(reference), isNull);
      expect(
        File('${temporary.path}/$reference.corrupt-1234').existsSync(),
        isTrue,
      );
      await storage.close();
    });

    test('corrupt JSONL segment quarantines its dependent tail', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-segment-');
      addTearDown(() => temporary.delete(recursive: true));
      await File(
        '${temporary.path}/segment-000001.jsonl',
      ).writeAsBytes([0xff, 0xfe, 0xfd]);
      await File(
        '${temporary.path}/segment-000002.jsonl',
      ).writeAsString('${jsonEncode(_fillEntry(2).toJson())}\n');
      final journal = await UndoJournal.open(
        storage: FileJournalStorage(
          root: temporary,
          nowMilliseconds: () => 5678,
        ),
      );
      expect(journal.entries, isEmpty);
      expect(
        temporary.listSync().whereType<File>().where(
          (file) => file.path.endsWith('000001.jsonl.corrupt-5678'),
        ),
        hasLength(1),
      );
      expect(
        temporary.listSync().whereType<File>().where(
          (file) => file.path.endsWith('000002.jsonl.corrupt-5678'),
        ),
        hasLength(1),
      );
      await journal.close();
    });

    test('partial final WAL line is repaired before the next commit', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-tail-');
      addTearDown(() => temporary.delete(recursive: true));
      final first = jsonEncode(_fillEntry(1).toJson());
      await File(
        '${temporary.path}/segment-000001.jsonl',
      ).writeAsString('$first\n{"seq":');
      final journal = await UndoJournal.open(
        storage: FileJournalStorage(
          root: temporary,
          nowMilliseconds: () => 9012,
        ),
      );
      expect(journal.entries.map((entry) => entry.seq), [1]);
      await journal.commit(_fillEntry(2));
      await journal.close();
      final reopened = await UndoJournal.open(
        storage: FileJournalStorage(root: temporary),
      );
      expect(reopened.entries.map((entry) => entry.seq), [1, 2]);
      await reopened.close();
    });

    test('rewrite crash before commit marker restores old segments', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-rewrite-');
      addTearDown(() => temporary.delete(recursive: true));
      final original = FileJournalStorage(
        root: temporary,
        segmentEntryLimit: 1,
      );
      for (var sequence = 1; sequence <= 3; sequence += 1) {
        await original.appendJsonLine(
          jsonEncode(_fillEntry(sequence).toJson()),
        );
        await original.flush();
      }
      await original.close();
      final interrupted = FileJournalStorage(
        root: temporary,
        nowMilliseconds: () => 77,
        rewriteInterrupt: (point) {
          if (point == FileJournalRewritePoint.afterDescriptor) {
            throw StateError('power loss');
          }
        },
      );
      await expectLater(
        interrupted.replaceJsonLines([jsonEncode(_fillEntry(1).toJson())]),
        throwsStateError,
      );
      final reopened = await UndoJournal.open(
        storage: FileJournalStorage(root: temporary),
      );
      expect(reopened.entries.map((entry) => entry.seq), [1, 2, 3]);
      await reopened.close();
    });

    test('rewrite commit marker prevents old suffix resurrection', () async {
      final temporary = await Directory.systemTemp.createTemp('ink-rewrite-');
      addTearDown(() => temporary.delete(recursive: true));
      final original = FileJournalStorage(
        root: temporary,
        segmentEntryLimit: 1,
      );
      for (var sequence = 1; sequence <= 3; sequence += 1) {
        await original.appendJsonLine(
          jsonEncode(_fillEntry(sequence).toJson()),
        );
        await original.flush();
      }
      await original.close();
      final interrupted = FileJournalStorage(
        root: temporary,
        nowMilliseconds: () => 88,
        rewriteInterrupt: (point) {
          if (point == FileJournalRewritePoint.afterSegmentOne) {
            throw StateError('power loss');
          }
        },
      );
      await expectLater(
        interrupted.replaceJsonLines([jsonEncode(_fillEntry(1).toJson())]),
        throwsStateError,
      );
      final reopened = await UndoJournal.open(
        storage: FileJournalStorage(root: temporary),
      );
      expect(reopened.entries.map((entry) => entry.seq), [1]);
      await reopened.close();
    });
  });

  group('pure state operations and undo/redo', () {
    test('layer structural state applies forward and reverse', () {
      final before = _blankState();
      final hiddenLayer = before.layers.single.copyWith(visible: false);
      final afterState = JournalDocumentState(
        tiles: before.tiles,
        layers: [hiddenLayer],
        canvas: before.canvas,
      );
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.layerProps,
        beforeState: before.structuralJson(),
        afterState: afterState.structuralJson(),
      );
      final applied = applyJournalEntry(
        before,
        entry,
        direction: JournalDirection.forward,
      );
      expect(applied.layers.single.visible, isFalse);
      final reversed = applyJournalEntry(
        applied,
        entry,
        direction: JournalDirection.reverse,
      );
      expect(reversed.layers.single.visible, isTrue);
    });

    test(
      'final layer removal cold-undo restores its complete raster',
      () async {
        final before = _layerState({
          'L1': {const TileKey(0, 0): _tile(11)},
        });
        final after = _layerState({});
        final entry = JournalEntry(
          seq: 1,
          timestampMs: 1,
          kind: JournalKind.layerRemove,
          beforeState: before.structuralJson(),
          afterState: after.structuralJson(),
          beforeLayerTiles: _fullRaster(before),
          afterLayerTiles: const {},
          completeLayerSnapshots: true,
        );
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        final removed = applyJournalEntry(
          before,
          entry,
          direction: JournalDirection.forward,
          layerTiles: entry.afterLayerTiles,
        );
        expect(removed.tiles.layerIds, isEmpty);
        await journal.commit(entry);
        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final restored = (await reopened.undo(after))!.state;
        _expectStore(restored.tiles, before.tiles);
        expect(restored.layers.map((layer) => layer.id), ['L1']);
        final redone = (await reopened.redo(restored))!.state;
        expect(redone.tiles.layerIds, isEmpty);
      },
    );

    test(
      'merge complete snapshot cold-undo and redo are pixel exact',
      () async {
        final before = _layerState({
          'L1': {const TileKey(0, 0): _tile(12)},
          'L2': {const TileKey(0, 0): _tile(13)},
        });
        final after = _layerState({
          'L1': {const TileKey(0, 0): _tile(25)},
        });
        final entry = JournalEntry(
          seq: 1,
          timestampMs: 1,
          kind: JournalKind.merge,
          beforeState: before.structuralJson(),
          afterState: after.structuralJson(),
          beforeLayerTiles: _fullRaster(before),
          afterLayerTiles: _fullRaster(after),
          completeLayerSnapshots: true,
        );
        final storage = InMemoryJournalStorage();
        await UndoJournal(storage: storage).commit(entry);
        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final restored = (await reopened.undo(after))!.state;
        _expectStore(restored.tiles, before.tiles);
        final redone = (await reopened.redo(restored))!.state;
        _expectStore(redone.tiles, after.tiles);
      },
    );

    test('canvas resize cold round-trip carries every layer raster', () async {
      final before = _layerState({
        'L1': {const TileKey(0, 0): _tile(31)},
        'L2': {const TileKey(1, 0): _tile(32)},
      }, canvas: CanvasSpec(width: 512, height: 256));
      final after = _layerState({
        'L1': {const TileKey(0, 0): _tile(31)},
        'L2': const {},
      }, canvas: CanvasSpec(width: 256, height: 256));
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.canvasResize,
        beforeState: before.structuralJson(),
        afterState: after.structuralJson(),
        beforeLayerTiles: _fullRaster(before),
        afterLayerTiles: _fullRaster(after),
        completeLayerSnapshots: true,
      );
      final storage = InMemoryJournalStorage();
      await UndoJournal(storage: storage).commit(entry);
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      final restored = (await reopened.undo(after))!.state;
      _expectStore(restored.tiles, before.tiles);
      expect(restored.canvas.width, 512);
      final redone = (await reopened.redo(restored))!.state;
      _expectStore(redone.tiles, after.tiles);
      expect(redone.canvas.width, 256);
    });

    test('canvas flip is an exact involution across a partial edge tile', () {
      final store = TileStore();
      final left = Uint8List(Tile.byteLength);
      left.setRange(0, 4, [1, 2, 3, 255]);
      final right = Uint8List(Tile.byteLength);
      final rightOffset = 43 * Tile.bytesPerPixel;
      right.setRange(rightOffset, rightOffset + 4, [9, 8, 7, 255]);
      store
        ..publish('L1', const TileKey(0, 0), Tile.takeOwnership(left))
        ..publish('L1', const TileKey(1, 0), Tile.takeOwnership(right));
      final initial = _blankState(
        store: store,
        canvas: CanvasSpec(width: 300, height: 1),
      );
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.canvasFlip,
      );
      final flipped = applyJournalEntry(
        initial,
        entry,
        direction: JournalDirection.forward,
      );
      expect(
        flipped.tiles.tile('L1', const TileKey(1, 0))!.pixels[rightOffset],
        1,
      );
      expect(flipped.tiles.tile('L1', const TileKey(0, 0))!.pixels[0], 9);
      final restored = applyJournalEntry(
        flipped,
        entry,
        direction: JournalDirection.reverse,
      );
      _expectStore(restored.tiles, initial.tiles);
    });

    test('layer clear restores before pixels and redoes absence', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      final key = const TileKey(0, 0);
      final original = _tile(71);
      final store = TileStore()..publish('L1', key, original);
      var state = _blankState(store: store);
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.layerClear,
        layerId: 'L1',
        affectedKeys: [key],
        beforeTiles: {key: original},
      );
      state = applyJournalEntry(
        state,
        entry,
        direction: JournalDirection.forward,
      );
      await journal.commit(entry);
      expect(state.tiles.tile('L1', key), isNull);
      state = (await journal.undo(state))!.state;
      expect(state.tiles.tile('L1', key), same(original));
      state = (await journal.redo(state))!.state;
      expect(state.tiles.tile('L1', key), isNull);
    });

    test('first undo durably journals after tiles for cold redo', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      final key = const TileKey(0, 0);
      final after = _tile(44);
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.stroke,
        layerId: 'L1',
        recipe: _recipe(seed: 44),
        affectedKeys: [key],
        beforeTiles: {key: null},
      );
      var state = applyJournalEntry(
        _blankState(),
        entry,
        direction: JournalDirection.forward,
        tiles: {key: after},
      );
      await journal.commit(entry);
      state = (await journal.undo(state))!.state;
      expect(state.tiles.tile('L1', key), isNull);
      final entryLine = storage.durableLines.firstWhere(
        (line) => line.contains('"kind"'),
      );
      final decoded = _jsonMap(jsonDecode(entryLine));
      expect(_jsonMap(decoded['after']).values.single, isA<String>());

      final reopened = await UndoJournal.open(storage: storage.crashClone());
      expect(reopened.canUndo, isFalse);
      expect(reopened.canRedo, isTrue);
      state = (await reopened.undo(_blankState()))?.state ?? state;
      // Reopened journals start at their applied head; undo then redo exercises
      // the cold snapshot without relying on the old hot reference.
      state = (await reopened.redo(state))!.state;
      _expectTile(state.tiles.tile('L1', key), after);
    });

    test(
      '240 seeded random operations undo and redo pixel-identically',
      () async {
        final random = Random(0x1a2b3c);
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        final initial = _blankState();
        final palette = [
          for (var marker = 0; marker < 16; marker += 1) _tile(marker),
        ];
        var state = initial;
        for (var sequence = 1; sequence <= 240; sequence += 1) {
          final key = TileKey(random.nextInt(4), random.nextInt(3));
          final before = state.tiles.tile('L1', key);
          final Tile? after = random.nextInt(7) == 0
              ? null
              : palette[random.nextInt(palette.length)];
          final entry = JournalEntry(
            seq: sequence,
            timestampMs: sequence,
            kind: JournalKind.fill,
            layerId: 'L1',
            affectedKeys: [key],
            beforeTiles: {key: before},
            afterTiles: {key: after},
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: {key: after},
          );
          await journal.commit(entry);
          state.tiles.verifyInvariants();
        }
        final finalStore = state.tiles.fork();
        for (var count = 0; count < 240; count += 1) {
          state = (await journal.undo(state))!.state;
          state.tiles.verifyInvariants();
        }
        _expectStore(state.tiles, initial.tiles);
        for (var count = 0; count < 240; count += 1) {
          state = (await journal.redo(state))!.state;
          state.tiles.verifyInvariants();
        }
        _expectStore(state.tiles, finalStore);
      },
    );
  });

  group('recovery, checkpoints, and compaction', () {
    test(
      'mid-burst crash replays every commit and loses only in-flight work',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        var live = _blankState();
        for (var sequence = 1; sequence <= 5; sequence += 1) {
          final entry = _strokeEntry(
            sequence,
            before: live.tiles.tile('L1', const TileKey(0, 0)),
          );
          live = applyJournalEntry(
            live,
            entry,
            direction: JournalDirection.forward,
            tiles: {const TileKey(0, 0): _tile(sequence)},
          );
          await journal.commit(entry);
        }
        // This sixth stroke reached a worker buffer but never committed.
        live = applyJournalEntry(
          live,
          _strokeEntry(6, before: live.tiles.tile('L1', const TileKey(0, 0))),
          direction: JournalDirection.forward,
          tiles: {const TileKey(0, 0): _tile(6)},
        );
        expect(live.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 6);

        final reopened = await UndoJournal.open(
          storage: storage.crashClone(),
          recipeRenderer: _seedRenderer,
        );
        final recovered = await reopened.recoverFromManifest(
          manifestState: _blankState(),
          manifestHeadSeq: 0,
        );
        expect(recovered.recoveredSequences, [1, 2, 3, 4, 5]);
        expect(recovered.skippedSequences, isEmpty);
        expect(
          recovered.state.tiles.tile('L1', const TileKey(0, 0))!.pixels.first,
          5,
        );
      },
    );

    test('recovery reverses a manifest ahead of the undo cursor', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      var state = _blankState();
      final states = <JournalDocumentState>[];
      for (var sequence = 1; sequence <= 2; sequence += 1) {
        final key = TileKey(sequence, 0);
        final entry = JournalEntry(
          seq: sequence,
          timestampMs: sequence,
          kind: JournalKind.fill,
          layerId: 'L1',
          affectedKeys: [key],
          beforeTiles: {key: null},
          afterTiles: {key: _tile(sequence)},
        );
        state = applyJournalEntry(
          state,
          entry,
          direction: JournalDirection.forward,
          tiles: entry.afterTiles,
        );
        states.add(state);
        await journal.commit(entry);
      }
      await journal.undo(state);
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      final recovery = await reopened.recoverFromManifest(
        manifestState: states.last,
        manifestHeadSeq: 2,
      );
      _expectStore(recovery.state.tiles, states.first.tiles);
      expect(recovery.reversedSequences, [2]);
      expect(recovery.reconciledHeadSeq, 1);
    });

    test(
      'branch commit rebases a stale manifest through its inverse',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        var state = _blankState();
        final states = <JournalDocumentState>[];
        for (var sequence = 1; sequence <= 2; sequence += 1) {
          final key = TileKey(sequence, 0);
          final entry = JournalEntry(
            seq: sequence,
            timestampMs: sequence,
            kind: JournalKind.fill,
            layerId: 'L1',
            affectedKeys: [key],
            beforeTiles: {key: null},
            afterTiles: {key: _tile(sequence)},
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: entry.afterTiles,
          );
          states.add(state);
          await journal.commit(entry);
        }
        state = (await journal.undo(state))!.state;
        const branchKey = TileKey(3, 0);
        final branch = JournalEntry(
          seq: 3,
          timestampMs: 3,
          kind: JournalKind.fill,
          layerId: 'L1',
          affectedKeys: const [branchKey],
          beforeTiles: {branchKey: null},
          afterTiles: {branchKey: _tile(3)},
        );
        state = applyJournalEntry(
          state,
          branch,
          direction: JournalDirection.forward,
          tiles: branch.afterTiles,
        );
        await journal.commit(branch);
        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final recovery = await reopened.recoverFromManifest(
          manifestState: states.last,
          manifestHeadSeq: 2,
        );
        _expectStore(recovery.state.tiles, state.tiles);
        expect(recovery.reversedSequences, [2]);
        expect(recovery.recoveredSequences, [3]);
        expect(recovery.reconciledHeadSeq, 3);
      },
    );

    test(
      'successive branches from one base keep distinct inverse groups',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        var state = _blankState();
        Future<void> commitMarker(int sequence) async {
          final key = TileKey(sequence, 0);
          final entry = JournalEntry(
            seq: sequence,
            timestampMs: sequence,
            kind: JournalKind.fill,
            layerId: 'L1',
            affectedKeys: [key],
            beforeTiles: {key: null},
            afterTiles: {key: _tile(sequence)},
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: entry.afterTiles,
          );
          await journal.commit(entry);
        }

        await commitMarker(1);
        await commitMarker(2);
        state = (await journal.undo(state))!.state;
        await commitMarker(3);
        final manifestAtThree = state;
        state = (await journal.undo(state))!.state;
        await commitMarker(4);

        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final recovery = await reopened.recoverFromManifest(
          manifestState: manifestAtThree,
          manifestHeadSeq: 3,
        );
        _expectStore(recovery.state.tiles, state.tiles);
        expect(recovery.reversedSequences, [3]);
        expect(recovery.recoveredSequences, [4]);
      },
    );

    test(
      'missing after snapshot reconstructs pixel-identically from recipe',
      () async {
        final storage = InMemoryJournalStorage();
        final missingReference = await storage.putSnapshot(_tile(99));
        await storage.removeSnapshot(missingReference);
        final entry = JournalEntry(
          seq: 1,
          timestampMs: 1,
          kind: JournalKind.stroke,
          layerId: 'L1',
          bounds: const JournalBounds(x: 0, y: 0, width: 1, height: 1),
          recipe: _recipe(seed: 88),
          affectedKeys: const [TileKey(0, 0)],
          beforeReferences: const {'0_0': null},
          afterReferences: {'0_0': missingReference},
        );
        final journal = UndoJournal(
          storage: storage,
          recipeRenderer: _seedRenderer,
        );
        await journal.commit(entry);
        final recovered = await journal.recoverFromManifest(
          manifestState: _blankState(),
          manifestHeadSeq: 0,
        );
        _expectTile(
          recovered.state.tiles.tile('L1', const TileKey(0, 0)),
          _tile(88),
        );
      },
    );

    test(
      'missing cold before snapshot rebuilds undo from recipe tail',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(
          storage: storage,
          recipeRenderer: _seedRenderer,
        );
        var state = _blankState();
        for (var sequence = 1; sequence <= 2; sequence += 1) {
          final entry = _strokeEntry(
            sequence,
            before: state.tiles.tile('L1', const TileKey(0, 0)),
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: {const TileKey(0, 0): _tile(sequence)},
          );
          await journal.commit(entry);
        }
        final crashed = storage.crashClone();
        final reopened = await UndoJournal.open(
          storage: crashed,
          recipeRenderer: _seedRenderer,
        );
        final beforeReference = reopened.entries.last.beforeReferences.values
            .whereType<String>()
            .single;
        await crashed.removeSnapshot(beforeReference);
        final step = await reopened.undo(
          state,
          replayBaseState: _blankState(),
          replayBaseHeadSeq: 0,
        );
        _expectTile(
          step!.state.tiles.tile('L1', const TileKey(0, 0)),
          _tile(1),
        );
      },
    );

    test(
      'non-recipe raster commit rejects an absent durable after-image',
      () async {
        final journal = UndoJournal(storage: InMemoryJournalStorage());
        await expectLater(
          journal.commit(
            JournalEntry(
              seq: 1,
              timestampMs: 1,
              kind: JournalKind.fill,
              layerId: 'L1',
              affectedKeys: const [TileKey(0, 0)],
              beforeTiles: {const TileKey(0, 0): null},
            ),
          ),
          throwsStateError,
        );
      },
    );

    test('fill survives restart for both forward recovery and undo', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      final before = _tile(10);
      final after = _tile(20);
      final baseStore = TileStore()..publish('L1', const TileKey(0, 0), before);
      final base = _blankState(store: baseStore);
      final entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.fill,
        layerId: 'L1',
        affectedKeys: const [TileKey(0, 0)],
        beforeTiles: {const TileKey(0, 0): before},
        afterTiles: {const TileKey(0, 0): after},
      );
      await journal.commit(entry);
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      final recovery = await reopened.recoverFromManifest(
        manifestState: base,
        manifestHeadSeq: 0,
      );
      _expectTile(recovery.state.tiles.tile('L1', const TileKey(0, 0)), after);
      final undone = await reopened.undo(recovery.state);
      _expectTile(undone!.state.tiles.tile('L1', const TileKey(0, 0)), before);
    });

    test(
      'checkpoint 32 flattens old recipes and bounds stroke-erase tail',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage);
        var state = _blankState();
        for (var sequence = 1; sequence <= 32; sequence += 1) {
          final entry = _strokeEntry(
            sequence,
            before: state.tiles.tile('L1', const TileKey(0, 0)),
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: {const TileKey(0, 0): _tile(sequence)},
          );
          await journal.commit(entry, checkpointStore: state.tiles);
        }
        expect(journal.checkpoints['L1']!.throughSeq, 32);
        expect(journal.entries.where((entry) => entry.recipe != null), isEmpty);
        expect(journal.canStrokeErase(1), isFalse);
        expect(journal.strokeEraseCandidates(layerId: 'L1'), isEmpty);

        final entry = _strokeEntry(
          33,
          before: state.tiles.tile('L1', const TileKey(0, 0)),
        );
        state = applyJournalEntry(
          state,
          entry,
          direction: JournalDirection.forward,
          tiles: {const TileKey(0, 0): _tile(33)},
        );
        await journal.commit(entry, checkpointStore: state.tiles);
        expect(
          journal.strokeEraseCandidates(layerId: 'L1').map((item) => item.seq),
          [33],
        );
        expect(journal.canStrokeErase(33), isTrue);
      },
    );

    test(
      'stroke erase replays the live tail while omitting its target',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(
          storage: storage,
          recipeRenderer: _additiveRenderer,
        );
        final base = _blankState();
        var state = base;
        for (var sequence = 1; sequence <= 3; sequence += 1) {
          final entry = _strokeEntry(
            sequence,
            before: state.tiles.tile('L1', const TileKey(0, 0)),
          );
          final rendered = _additiveRenderer(
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
        expect(state.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 6);
        final withoutMiddle = await journal.replayWithoutStroke(
          currentState: state,
          sequence: 2,
          replayBaseState: base,
        );
        expect(
          withoutMiddle.tiles.tile('L1', const TileKey(0, 0))!.pixels.first,
          4,
        );
      },
    );

    test('recipe byte budget can checkpoint before 32 strokes', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage, recipeByteBudget: 1);
      final entry = _strokeEntry(1, before: null);
      final state = applyJournalEntry(
        _blankState(),
        entry,
        direction: JournalDirection.forward,
        tiles: {const TileKey(0, 0): _tile(1)},
      );
      await journal.commit(entry, checkpointStore: state.tiles);
      expect(journal.checkpoints['L1']!.throughSeq, 1);
      expect(journal.entries.single.recipeCompacted, isTrue);
    });

    test(
      'checkpoint snapshots recover flattened strokes after reopen',
      () async {
        final storage = InMemoryJournalStorage();
        final journal = UndoJournal(storage: storage, checkpointInterval: 2);
        var state = _blankState();
        for (var sequence = 1; sequence <= 2; sequence += 1) {
          final entry = _strokeEntry(
            sequence,
            before: state.tiles.tile('L1', const TileKey(0, 0)),
          );
          state = applyJournalEntry(
            state,
            entry,
            direction: JournalDirection.forward,
            tiles: {const TileKey(0, 0): _tile(sequence)},
          );
          await journal.commit(entry, checkpointStore: state.tiles);
        }
        final reopened = await UndoJournal.open(storage: storage.crashClone());
        final recovery = await reopened.recoverFromManifest(
          manifestState: _blankState(),
          manifestHeadSeq: 0,
        );
        expect(recovery.recoveredSequences, [1, 2]);
        _expectTile(
          recovery.state.tiles.tile('L1', const TileKey(0, 0)),
          _tile(2),
        );
      },
    );

    test('checkpoint pixels stay newer than replayed merge metadata', () async {
      final before = _layerState({
        'L1': {const TileKey(0, 0): _tile(1)},
        'L2': {const TileKey(0, 0): _tile(2)},
      });
      var state = _layerState({
        'L1': {const TileKey(0, 0): _tile(3)},
      });
      final merge = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.merge,
        beforeState: before.structuralJson(),
        afterState: state.structuralJson(),
        beforeLayerTiles: _fullRaster(before),
        afterLayerTiles: _fullRaster(state),
        completeLayerSnapshots: true,
      );
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage, checkpointInterval: 2);
      await journal.commit(merge);
      for (var sequence = 2; sequence <= 3; sequence += 1) {
        final entry = _strokeEntry(
          sequence,
          before: state.tiles.tile('L1', const TileKey(0, 0)),
        );
        state = applyJournalEntry(
          state,
          entry,
          direction: JournalDirection.forward,
          tiles: {const TileKey(0, 0): _tile(sequence + 10)},
        );
        await journal.commit(entry, checkpointStore: state.tiles);
      }
      final reopened = await UndoJournal.open(storage: storage.crashClone());
      final recovery = await reopened.recoverFromManifest(
        manifestState: before,
        manifestHeadSeq: 0,
      );
      _expectStore(recovery.state.tiles, state.tiles);
      expect(recovery.state.layers.map((layer) => layer.id), ['L1']);
    });

    test('snapshot GC retains referenced data and deletes orphans', () async {
      final storage = InMemoryJournalStorage();
      final retained = await storage.putSnapshot(_tile(1));
      final orphan = await storage.putSnapshot(_tile(2));
      final journal = UndoJournal(storage: storage);
      await journal.commit(
        JournalEntry(
          seq: 1,
          timestampMs: 1,
          kind: JournalKind.fill,
          layerId: 'L1',
          affectedKeys: const [TileKey(0, 0)],
          beforeReferences: {'0_0': retained},
          afterReferences: const {'0_0': null},
        ),
      );
      await journal.garbageCollectSnapshots();
      expect(await storage.listSnapshotReferences(), {retained});
      expect(await storage.readSnapshot(orphan), isNull);
    });

    test('identical before images dedupe when hot refs spill', () async {
      final storage = InMemoryJournalStorage();
      final journal = UndoJournal(storage: storage);
      final sharedPixels = _tile(7);
      for (var sequence = 1; sequence <= 2; sequence += 1) {
        await journal.commit(
          JournalEntry(
            seq: sequence,
            timestampMs: sequence,
            kind: JournalKind.fill,
            layerId: 'L1',
            affectedKeys: [TileKey(sequence, 0)],
            beforeTiles: {TileKey(sequence, 0): sharedPixels},
            afterTiles: {TileKey(sequence, 0): null},
          ),
        );
      }
      await journal.spillSnapshots();
      expect(storage.snapshotWriteCount, 1);
      expect(await storage.listSnapshotReferences(), hasLength(1));
      expect(journal.hotBytesHeld, 0);
    });

    test('compaction keeps depth 64 and every unmanifested entry', () async {
      final storage = InMemoryJournalStorage();
      final fixedNow = DateTime.fromMillisecondsSinceEpoch(10 * 86400000);
      final journal = UndoJournal(
        storage: storage,
        maxDepth: 64,
        now: () => fixedNow,
      );
      for (var sequence = 1; sequence <= 80; sequence += 1) {
        await journal.commit(
          JournalEntry(
            seq: sequence,
            timestampMs: fixedNow.millisecondsSinceEpoch,
            kind: JournalKind.fill,
          ),
        );
      }
      await journal.compact(manifestHeadSeq: 70);
      expect(journal.entries, hasLength(74));
      expect(journal.entries.first.seq, 7);
      expect(journal.entries.last.seq, 80);
    });

    test(
      'compaction removes autosaved entries older than seven days',
      () async {
        final storage = InMemoryJournalStorage();
        final fixedNow = DateTime.fromMillisecondsSinceEpoch(9 * 86400000);
        final journal = UndoJournal(storage: storage, now: () => fixedNow);
        await journal.commit(
          JournalEntry(seq: 1, timestampMs: 0, kind: JournalKind.fill),
        );
        await journal.commit(
          JournalEntry(
            seq: 2,
            timestampMs: fixedNow.millisecondsSinceEpoch,
            kind: JournalKind.fill,
          ),
        );
        await journal.compact(manifestHeadSeq: 2);
        expect(journal.entries.map((entry) => entry.seq), [2]);
      },
    );

    test(
      'compaction to empty preserves the sequence high-water mark',
      () async {
        final storage = InMemoryJournalStorage();
        final now = DateTime.fromMillisecondsSinceEpoch(10 * 86400000);
        final journal = UndoJournal(storage: storage, now: () => now);
        await journal.commit(
          JournalEntry(seq: 4213, timestampMs: 0, kind: JournalKind.fill),
        );
        await journal.compact(manifestHeadSeq: 4213);
        expect(journal.entries, isEmpty);
        final reopened = await UndoJournal.open(storage: storage.crashClone());
        expect(reopened.headSeq, 4213);
        expect(reopened.nextSequence, 4214);
        final recovery = await reopened.recoverFromManifest(
          manifestState: _blankState(),
          manifestHeadSeq: 4213,
        );
        expect(recovery.reconciledHeadSeq, 4213);
        await reopened.commit(
          JournalEntry(
            seq: reopened.nextSequence,
            timestampMs: now.millisecondsSinceEpoch,
            kind: JournalKind.fill,
          ),
        );
        expect(reopened.entries.single.seq, 4214);
      },
    );

    test('stroke erase excludes entries in the redo tail', () async {
      final journal = UndoJournal(storage: InMemoryJournalStorage());
      var state = _blankState();
      for (var sequence = 1; sequence <= 2; sequence += 1) {
        final entry = _strokeEntry(
          sequence,
          before: state.tiles.tile('L1', const TileKey(0, 0)),
        );
        state = applyJournalEntry(
          state,
          entry,
          direction: JournalDirection.forward,
          tiles: {const TileKey(0, 0): _tile(sequence)},
        );
        await journal.commit(entry);
      }
      state = (await journal.undo(state))!.state;
      expect(
        journal.strokeEraseCandidates(layerId: 'L1').map((entry) => entry.seq),
        [1],
      );
      expect(journal.canStrokeErase(2), isFalse);
    });

    test('recovery stops after the first unrecoverable action', () async {
      final first = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.fill,
        layerId: 'L1',
        affectedKeys: const [TileKey(0, 0)],
        beforeReferences: const {'0_0': null},
        afterReferences: const {'0_0': 'snapshots/$_hashA.tile'},
      );
      final second = _strokeEntry(2, before: null);
      final journal = await UndoJournal.open(
        storage: InMemoryJournalStorage(
          durableLines: [
            jsonEncode(first.toJson()),
            jsonEncode(second.toJson()),
          ],
        ),
        recipeRenderer: _seedRenderer,
      );
      final recovery = await journal.recoverFromManifest(
        manifestState: _blankState(),
        manifestHeadSeq: 0,
      );
      expect(recovery.recoveredSequences, isEmpty);
      expect(recovery.skippedSequences, [1, 2]);
      expect(recovery.state.tiles.tile('L1', const TileKey(0, 0)), isNull);
    });

    test('configured undo capacity cannot be less than 64', () {
      expect(
        () => UndoJournal(storage: InMemoryJournalStorage(), maxDepth: 63),
        throwsArgumentError,
      );
    });
  });
}

const String _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _hashB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

StrokeRecipe _recipe({required int seed}) => StrokeRecipe(
  brushId: 'fineliner',
  colorArgb: 0xff000000,
  size: 3,
  seed: seed,
  transform: const [1, 0, 0, 1, 0, 0],
  samples: Uint8List.fromList([seed & 0xff, 2, 3]),
);

JournalEntry _fillEntry(int sequence) =>
    JournalEntry(seq: sequence, timestampMs: sequence, kind: JournalKind.fill);

JournalEntry _strokeEntry(int sequence, {required Tile? before}) =>
    JournalEntry(
      seq: sequence,
      timestampMs: sequence,
      kind: JournalKind.stroke,
      layerId: 'L1',
      bounds: const JournalBounds(x: 0, y: 0, width: 1, height: 1),
      recipe: _recipe(seed: sequence),
      affectedKeys: const [TileKey(0, 0)],
      beforeTiles: {const TileKey(0, 0): before},
      unknownFields: const <String, Object?>{'strokeReplayVersion': 1},
    );

Map<TileKey, Tile?> _seedRenderer(RecipeReplayRequest request) => {
  const TileKey(0, 0): _tile(request.entry.recipe!.seed & 0xff),
};

Map<TileKey, Tile?> _additiveRenderer(RecipeReplayRequest request) {
  final current =
      request.state.tiles.tile('L1', const TileKey(0, 0))?.pixels.first ?? 0;
  return {
    const TileKey(0, 0): _tile((current + request.entry.recipe!.seed) & 0xff),
  };
}

JournalDocumentState _blankState({TileStore? store, CanvasSpec? canvas}) {
  final resultStore = store ?? TileStore();
  resultStore.ensureLayer('L1');
  return JournalDocumentState(
    tiles: resultStore,
    layers: [
      InkLayer(
        id: 'L1',
        name: 'Layer 1',
        tiles: resultStore.occupiedKeys('L1'),
      ),
    ],
    canvas: canvas ?? CanvasSpec(width: 512, height: 512),
  );
}

JournalDocumentState _layerState(
  Map<String, Map<TileKey, Tile>> layers, {
  CanvasSpec? canvas,
}) {
  final store = TileStore();
  for (final layer in layers.entries) {
    store.replaceLayer(layer.key, layer.value);
  }
  return JournalDocumentState(
    tiles: store,
    layers: [
      for (final layerId in layers.keys)
        InkLayer(
          id: layerId,
          name: layerId,
          tiles: store.occupiedKeys(layerId),
        ),
    ],
    canvas: canvas ?? CanvasSpec(width: 512, height: 512),
  );
}

Map<String, Map<TileKey, Tile?>> _fullRaster(JournalDocumentState state) => {
  for (final layerId in state.tiles.layerIds)
    layerId: Map<TileKey, Tile?>.of(state.tiles.layerTiles(layerId)),
};

Tile _tile(int marker) {
  final pixels = Uint8List(Tile.byteLength);
  pixels.setRange(0, 4, [marker, marker ^ 0x55, marker ^ 0xaa, 255]);
  return Tile.takeOwnership(pixels);
}

Map<String, Object?> _jsonMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

void _expectTile(Tile? actual, Tile expected) {
  expect(actual, isNotNull);
  expect(actual!.pixels, orderedEquals(expected.pixels));
}

void _expectStore(TileStore actual, TileStore expected) {
  expect(actual.layerIds, orderedEquals(expected.layerIds));
  expect(actual.locations, orderedEquals(expected.locations));
  for (final location in expected.locations) {
    _expectTile(
      actual.tile(location.layerId, location.key),
      expected.tile(location.layerId, location.key)!,
    );
  }
}
