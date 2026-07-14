import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/model/gallery_model.dart';

void main() {
  group('GalleryArtworkSize', () {
    test('exposes every binding canvas preset', () {
      expect(
        GalleryArtworkSize(preset: GalleryCanvasPreset.screen).canvas.toJson(),
        containsPair('width', 954),
      );
      expect(
        GalleryArtworkSize(preset: GalleryCanvasPreset.screen2x).height,
        3392,
      );
      expect(
        GalleryArtworkSize(preset: GalleryCanvasPreset.square).width,
        2048,
      );
      expect(GalleryArtworkSize(preset: GalleryCanvasPreset.a5).height, 2480);
    });

    test('accepts a custom canvas up to 4096 square', () {
      final GalleryArtworkSize size = GalleryArtworkSize(
        preset: GalleryCanvasPreset.custom,
        customWidth: 3072,
        customHeight: 4096,
      );

      expect((size.width, size.height), (3072, 4096));
    });

    test('rejects an oversized custom canvas', () {
      expect(
        () => GalleryArtworkSize(
          preset: GalleryCanvasPreset.custom,
          customWidth: 4097,
        ),
        throwsRangeError,
      );
    });
  });

  group('GalleryModel', () {
    test('rejects duplicate seeded ids', () {
      expect(
        () => GalleryModel(entries: <GalleryEntry>[_entry('a'), _entry('a')]),
        throwsArgumentError,
      );
    });

    test('pages the new card together with persisted entries', () {
      final GalleryModel model = GalleryModel(
        entries: <GalleryEntry>[
          for (var index = 0; index < 12; index += 1) _entry('$index'),
        ],
      );

      expect(model.pageCount, 3);
      model.setPageIndex(2);
      expect(model.pageIndex, 2);
      expect(() => model.setPageIndex(3), throwsRangeError);
    });

    test(
      'open runs GC and first-run seeding before publishing snapshot',
      () async {
        final _FakeGalleryOperations operations = _FakeGalleryOperations(
          entries: <GalleryEntry>[_entry('seed')],
          trash: <GalleryTrashEntry>[
            GalleryTrashEntry(entry: _entry('trash'), trashedAtMs: 10),
          ],
        );
        final GalleryModel model = GalleryModel(operations: operations);

        await model.openGallery();

        expect(operations.calls.take(2), <String>['gc:7', 'seed']);
        expect(model.phase, GalleryPhase.ready);
        expect(model.entries.single.id, 'seed');
        expect(model.trash.single.entry.id, 'trash');
      },
    );

    test('open failure is recoverable chrome state', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations()
        ..failLoad = true;
      final GalleryModel model = GalleryModel(operations: operations);

      await model.openGallery();

      expect(model.phase, GalleryPhase.failed);
      expect(model.errorMessage, contains('try again'));
    });

    test('create inserts the new artwork at the front', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('old')],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      final GalleryEntry? result = await model.createArtwork(
        GalleryArtworkSize(preset: GalleryCanvasPreset.square),
      );

      expect(result?.id, 'created');
      expect(model.entries.first.id, 'created');
      expect(model.actionMessage, 'new artwork ready');
    });

    test('rename trims user text and replaces metadata in place', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('a', name: 'old')],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      await model.renameArtwork('a', '  harbor  ');

      expect(operations.renamedTo, 'harbor');
      expect(model.entries.single.name, 'harbor');
    });

    test('rename refuses a blank display name without persistence', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('a')],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      expect(await model.renameArtwork('a', '  '), isNull);
      expect(operations.renamedTo, isNull);
      expect(model.actionMessage, contains('cannot be empty'));
    });

    test('duplicate inserts a fresh copy first', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('a', name: 'study')],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      await model.duplicateArtwork('a');

      expect(model.entries.map((GalleryEntry item) => item.id), <String>[
        'a-copy',
        'a',
      ]);
    });

    test(
      'hold-confirmed trash removes card and publishes restore row',
      () async {
        final _FakeGalleryOperations operations = _FakeGalleryOperations(
          entries: <GalleryEntry>[_entry('a')],
        );
        final GalleryModel model = GalleryModel(operations: operations);
        await model.openGallery();

        expect(await model.trashArtwork('a'), isTrue);

        expect(model.entries, isEmpty);
        expect(model.trash.single.entry.id, 'a');
        expect(model.actionMessage, 'moved to trash');
      },
    );

    test('restore returns trash item to the gallery front', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        trash: <GalleryTrashEntry>[
          GalleryTrashEntry(entry: _entry('a'), trashedAtMs: 10),
        ],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      await model.restoreArtwork('a');

      expect(model.entries.single.id, 'a');
      expect(model.trash, isEmpty);
    });

    test('import scan publishes candidates from its injected seam', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        imports: const <GalleryImportCandidate>[
          GalleryImportCandidate(
            path: '/imports/study.inkpack',
            name: 'study.inkpack',
            kind: GalleryImportKind.inkpack,
          ),
        ],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      await model.scanImports();

      expect(model.importCandidates.single.name, 'study.inkpack');
    });

    test('valid import is inserted at the gallery front', () async {
      const GalleryImportCandidate candidate = GalleryImportCandidate(
        path: '/imports/study.inkpack',
        name: 'study.inkpack',
        kind: GalleryImportKind.inkpack,
      );
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        imports: const <GalleryImportCandidate>[candidate],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();
      await model.scanImports();

      await model.importArtwork(candidate);

      expect(model.entries.first.id, 'imported');
      expect(model.actionMessage, contains('study.inkpack'));
    });

    test('invalid import is skipped with a margin-note message', () async {
      const GalleryImportCandidate candidate = GalleryImportCandidate(
        path: '/imports/bad.inkpack',
        name: 'bad.inkpack',
        kind: GalleryImportKind.inkpack,
      );
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        imports: const <GalleryImportCandidate>[candidate],
      )..invalidImport = true;
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();
      await model.scanImports();

      expect(await model.importArtwork(candidate), isNull);
      expect(model.actionMessage, 'skipped invalid bad.inkpack');
    });

    test('export reports its staged destination', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('a')],
      );
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      expect(await model.exportArtwork('a'), isTrue);
      expect(model.actionMessage, contains('documents/exports'));
    });

    test('failed export stays in gallery and offers retry copy', () async {
      final _FakeGalleryOperations operations = _FakeGalleryOperations(
        entries: <GalleryEntry>[_entry('a')],
      )..failExport = true;
      final GalleryModel model = GalleryModel(operations: operations);
      await model.openGallery();

      expect(await model.exportArtwork('a'), isFalse);
      expect(model.entries.single.id, 'a');
      expect(model.actionMessage, 'export failed — retry');
    });
  });
}

GalleryEntry _entry(String id, {String? name}) => GalleryEntry(
  id: id,
  name: name ?? 'art $id',
  createdAtMs: 100,
  modifiedAtMs: 200,
);

final class _FakeGalleryOperations implements GalleryOperations {
  _FakeGalleryOperations({
    List<GalleryEntry> entries = const <GalleryEntry>[],
    List<GalleryTrashEntry> trash = const <GalleryTrashEntry>[],
    List<GalleryImportCandidate> imports = const <GalleryImportCandidate>[],
  }) : entries = entries.toList(),
       trash = trash.toList(),
       imports = imports.toList();

  final List<String> calls = <String>[];
  final List<GalleryEntry> entries;
  final List<GalleryTrashEntry> trash;
  final List<GalleryImportCandidate> imports;
  String? renamedTo;
  bool failLoad = false;
  bool failExport = false;
  bool invalidImport = false;

  @override
  Future<int> collectExpiredTrash(Duration maximumAge) async {
    calls.add('gc:${maximumAge.inDays}');
    return 0;
  }

  @override
  Future<GalleryEntry> createArtwork(GalleryArtworkSize size) async {
    final GalleryEntry created = _entry('created', name: 'Untitled');
    entries.insert(0, created);
    return created;
  }

  @override
  Future<GalleryEntry> duplicateArtwork(String artworkId) async {
    final GalleryEntry original = entries.firstWhere(
      (GalleryEntry item) => item.id == artworkId,
    );
    final GalleryEntry copy = _entry(
      '$artworkId-copy',
      name: '${original.name} copy',
    );
    entries.insert(0, copy);
    return copy;
  }

  @override
  Future<void> ensureFirstRunSeed() async {
    calls.add('seed');
  }

  @override
  Future<void> exportArtwork(String artworkId) async {
    if (failExport) {
      throw StateError('export failed');
    }
  }

  @override
  Future<GalleryEntry?> importArtwork(GalleryImportCandidate candidate) async {
    if (invalidImport) {
      return null;
    }
    final GalleryEntry imported = _entry('imported');
    entries.insert(0, imported);
    return imported;
  }

  @override
  Future<List<GalleryEntry>> loadEntries() async {
    if (failLoad) {
      throw StateError('load failed');
    }
    calls.add('load');
    return List<GalleryEntry>.of(entries);
  }

  @override
  Future<List<GalleryTrashEntry>> loadTrash() async {
    calls.add('trash');
    return List<GalleryTrashEntry>.of(trash);
  }

  @override
  Future<void> moveToTrash(String artworkId) async {
    final int index = entries.indexWhere(
      (GalleryEntry item) => item.id == artworkId,
    );
    final GalleryEntry moved = entries.removeAt(index);
    trash.add(GalleryTrashEntry(entry: moved, trashedAtMs: 300));
  }

  @override
  Future<GalleryEntry> renameArtwork(String artworkId, String name) async {
    renamedTo = name;
    final int index = entries.indexWhere(
      (GalleryEntry item) => item.id == artworkId,
    );
    final GalleryEntry renamed = _entry(artworkId, name: name);
    entries[index] = renamed;
    return renamed;
  }

  @override
  Future<GalleryEntry> restoreArtwork(String artworkId) async {
    final int index = trash.indexWhere(
      (GalleryTrashEntry item) => item.entry.id == artworkId,
    );
    final GalleryEntry restored = trash.removeAt(index).entry;
    entries.insert(0, restored);
    return restored;
  }

  @override
  Future<List<GalleryImportCandidate>> scanImports() async =>
      List<GalleryImportCandidate>.of(imports);
}
