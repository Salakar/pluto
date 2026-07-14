import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ink-gallery-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('missing gallery cache rebuilds by scanning manifests', () async {
    final store = DocumentStore(root: root);
    await _writeManifest(store, _document('one', modifiedAtMs: 1));
    await _writeManifest(store, _document('two', modifiedAtMs: 2));
    expect(store.galleryFile.existsSync(), isFalse);

    final entries = await store.loadGallery();

    expect(entries.map((entry) => entry.id), <String>['two', 'one']);
    expect(store.galleryFile.existsSync(), isTrue);
  });

  test('corrupt gallery is quarantined then rebuilt', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 4567);
    await _writeManifest(store, _document('one', modifiedAtMs: 1));
    store.galleryFile.parent.createSync(recursive: true);
    store.galleryFile.writeAsStringSync('{not-json');

    final entries = await store.loadGallery();

    expect(entries.single.id, 'one');
    expect(File('${store.galleryFile.path}.corrupt-4567').existsSync(), isTrue);
    expect(store.galleryFile.existsSync(), isTrue);
  });

  test(
    'gallery rebuild returns scanned entries when cache write fails',
    () async {
      final fixtureStore = DocumentStore(root: root);
      await _writeManifest(fixtureStore, _document('one', modifiedAtMs: 1));
      final store = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.beforeTemporaryWrite &&
              target.path.endsWith('/gallery.json')) {
            throw const _CacheWriteFailure();
          }
        },
      );

      final entries = await store.loadGallery();

      expect(entries.single.id, 'one');
      expect(store.galleryFile.existsSync(), isFalse);
    },
  );

  test('valid gallery cache preserves explicit ordering', () async {
    final store = DocumentStore(root: root);
    await _writeManifest(
      store,
      _document('older', name: 'Older', modifiedAtMs: 1),
    );
    await _writeManifest(
      store,
      _document('newer', name: 'Newer', modifiedAtMs: 9),
    );
    await store.saveGallery(<GalleryEntry>[
      GalleryEntry(id: 'older', name: 'Older', createdAtMs: 1, modifiedAtMs: 1),
      GalleryEntry(id: 'newer', name: 'Newer', createdAtMs: 2, modifiedAtMs: 9),
    ]);

    final entries = await store.loadGallery();

    expect(entries.map((entry) => entry.id), <String>['older', 'newer']);
  });

  test('forced rebuild sorts newest first with stable id tie-break', () async {
    final store = DocumentStore(root: root);
    await _writeManifest(store, _document('zebra', modifiedAtMs: 20));
    await _writeManifest(store, _document('alpha', modifiedAtMs: 20));
    await _writeManifest(store, _document('old', modifiedAtMs: 10));
    await store.saveGallery(<GalleryEntry>[
      GalleryEntry(id: 'stale', name: 'Stale', createdAtMs: 0, modifiedAtMs: 0),
    ]);

    final entries = await store.loadGallery(forceRebuild: true);

    expect(entries.map((entry) => entry.id), <String>['alpha', 'zebra', 'old']);
  });

  test('rebuild quarantines an invalid manifest and keeps valid art', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 888);
    await _writeManifest(store, _document('valid', modifiedAtMs: 1));
    final invalid = store.manifestFile('invalid');
    invalid.parent.createSync(recursive: true);
    invalid.writeAsStringSync('{}');

    final entries = await store.rebuildGallery();

    expect(entries.single.id, 'valid');
    expect(File('${invalid.path}.corrupt-888').existsSync(), isTrue);
  });

  test('gallery entry preserves unknown metadata on cache rewrite', () async {
    final store = DocumentStore(root: root);
    await _writeManifest(store, _document('one', name: 'One', modifiedAtMs: 2));
    final entry = GalleryEntry.fromJson(<String, Object?>{
      'id': 'one',
      'name': 'One',
      'createdAtMs': 1,
      'modifiedAtMs': 2,
      'futureThumbnailHash': 'abc',
    });
    await store.saveGallery(<GalleryEntry>[entry]);

    final loaded = (await store.loadGallery()).single;
    await store.saveGallery(<GalleryEntry>[loaded]);

    expect(loaded.unknownFields['futureThumbnailHash'], 'abc');
    expect(
      (await store.loadGallery()).single.toJson(),
      containsPair('futureThumbnailHash', 'abc'),
    );
  });

  test('saveDocument adds a new gallery entry at the front', () async {
    final store = DocumentStore(root: root);
    await _writeManifest(
      store,
      _document('existing', name: 'Existing', modifiedAtMs: 1),
    );
    await store.saveGallery(<GalleryEntry>[
      GalleryEntry(
        id: 'existing',
        name: 'Existing',
        createdAtMs: 1,
        modifiedAtMs: 1,
      ),
    ]);

    await store.saveDocument(
      _document('new-art', modifiedAtMs: 4),
      TileStore(),
    );

    expect((await store.loadGallery()).map((entry) => entry.id), <String>[
      'new-art',
      'existing',
    ]);
  });

  test(
    'saveDocument updates an entry without changing user ordering',
    () async {
      final store = DocumentStore(root: root);
      await _writeManifest(
        store,
        _document('first', name: 'First', modifiedAtMs: 1),
      );
      await _writeManifest(
        store,
        _document('target', name: 'Old', modifiedAtMs: 1),
      );
      await _writeManifest(
        store,
        _document('last', name: 'Last', modifiedAtMs: 1),
      );
      await store.saveGallery(<GalleryEntry>[
        GalleryEntry(
          id: 'first',
          name: 'First',
          createdAtMs: 1,
          modifiedAtMs: 1,
        ),
        GalleryEntry(
          id: 'target',
          name: 'Old',
          createdAtMs: 1,
          modifiedAtMs: 1,
        ),
        GalleryEntry(id: 'last', name: 'Last', createdAtMs: 1, modifiedAtMs: 1),
      ]);

      await store.saveDocument(
        _document('target', name: 'Updated', modifiedAtMs: 9),
        TileStore(),
      );

      final entries = await store.loadGallery();
      expect(entries.map((entry) => entry.id), <String>[
        'first',
        'target',
        'last',
      ]);
      expect(entries[1].name, 'Updated');
    },
  );

  test(
    'valid cache reconciles metadata, removals, and committed additions',
    () async {
      final store = DocumentStore(root: root);
      await _writeManifest(
        store,
        _document('first', name: 'First current', modifiedAtMs: 4),
      );
      await _writeManifest(
        store,
        _document('second', name: 'Second current', modifiedAtMs: 3),
      );
      await _writeManifest(
        store,
        _document('added', name: 'Added', modifiedAtMs: 9),
      );
      await store.saveGallery(<GalleryEntry>[
        GalleryEntry(
          id: 'second',
          name: 'stale',
          createdAtMs: 1,
          modifiedAtMs: 1,
        ),
        GalleryEntry(
          id: 'first',
          name: 'stale',
          createdAtMs: 1,
          modifiedAtMs: 1,
        ),
        GalleryEntry(
          id: 'missing',
          name: 'Missing',
          createdAtMs: 1,
          modifiedAtMs: 1,
        ),
      ]);

      final entries = await store.loadGallery();

      expect(entries.map((entry) => entry.id), <String>[
        'second',
        'first',
        'added',
      ]);
      expect(entries[0].name, 'Second current');
      expect(entries[1].name, 'First current');
    },
  );

  test(
    'committed manifest is visible after gallery cache update failure',
    () async {
      final cleanStore = DocumentStore(root: root);
      await cleanStore.saveDocument(
        _document('existing', modifiedAtMs: 1),
        TileStore(),
      );
      final failingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.beforeTemporaryWrite &&
              target.path.endsWith('/gallery.json')) {
            throw const _CacheWriteFailure();
          }
        },
      );

      await failingStore.saveDocument(
        _document('committed', modifiedAtMs: 2),
        TileStore(),
      );

      expect(
        (await cleanStore.loadGallery()).map((entry) => entry.id),
        containsAll(<String>['existing', 'committed']),
      );
    },
  );

  test(
    'indeterminate artwork recovery preserves its cached gallery entry',
    () async {
      final cleanStore = DocumentStore(root: root);
      const location = TileLocation(layerId: 'L1', key: TileKey(0, 0));
      final initialTiles = TileStore()..publish('L1', location.key, _tile(1));
      final initialDocument = await cleanStore.saveDocument(
        _document('one', modifiedAtMs: 1),
        initialTiles,
      );
      final tilePath = cleanStore.tileFile('one', location).path;
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterAtomicRename &&
              target.path == tilePath) {
            throw const _GallerySaveCrash();
          }
        },
      );
      final updatedTiles = TileStore()..publish('L1', location.key, _tile(2));

      await expectLater(
        crashingStore.saveDocument(
          initialDocument.copyWith(modifiedAtMs: 2),
          updatedTiles,
        ),
        throwsA(isA<_GallerySaveCrash>()),
      );
      final backup = File(
        '${cleanStore.artworkDirectory('one').path}/'
        '.pending-save/backups/000000.tile',
      );
      expect(backup.existsSync(), isTrue);
      backup.deleteSync();

      final entries = await cleanStore.loadGallery();

      expect(entries.map((entry) => entry.id), <String>['one']);
      final cached =
          jsonDecode(cleanStore.galleryFile.readAsStringSync())
              as Map<String, Object?>;
      expect(
        (cached['artworks']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .single['id'],
        'one',
      );
    },
  );

  test('oversized gallery cache is quarantined before being read', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 919);
    await _writeManifest(store, _document('one', modifiedAtMs: 1));
    store.galleryFile.parent.createSync(recursive: true);
    final handle = store.galleryFile.openSync(mode: FileMode.write);
    handle
      ..truncateSync(17 * 1024 * 1024)
      ..closeSync();

    final entries = await store.loadGallery();

    expect(entries.single.id, 'one');
    expect(File('${store.galleryFile.path}.corrupt-919').existsSync(), isTrue);
  });

  test(
    'concurrent different-artwork saves retain both gallery entries',
    () async {
      final store = DocumentStore(root: root);

      await Future.wait(<Future<InkDocument>>[
        store.saveDocument(_document('alpha', modifiedAtMs: 1), TileStore()),
        store.saveDocument(_document('beta', modifiedAtMs: 2), TileStore()),
      ]);

      expect(
        (await store.loadGallery()).map((entry) => entry.id).toSet(),
        <String>{'alpha', 'beta'},
      );
    },
  );

  test('duplicate gallery ids are rejected before writing', () async {
    final store = DocumentStore(root: root);
    final duplicate = GalleryEntry(
      id: 'same',
      name: 'Same',
      createdAtMs: 1,
      modifiedAtMs: 1,
    );

    await expectLater(
      store.saveGallery(<GalleryEntry>[duplicate, duplicate]),
      throwsArgumentError,
    );
    expect(store.galleryFile.existsSync(), isFalse);
  });
}

Future<void> _writeManifest(DocumentStore store, InkDocument document) async {
  final file = store.manifestFile(document.id);
  file.parent.createSync(recursive: true);
  await file.writeAsString(_json(document));
}

String _json(InkDocument document) {
  // Route through DocumentStore once would also create gallery.json, defeating
  // the rebuild tests; this is a fixture for the already-committed manifest.
  return jsonEncode(document.toJson());
}

InkDocument _document(String id, {String? name, required int modifiedAtMs}) =>
    InkDocument.blank(
      id: id,
      nowMs: 1,
      name: name ?? id,
    ).copyWith(modifiedAtMs: modifiedAtMs);

Tile _tile(int value) {
  final pixels = Uint8List(Tile.byteLength)
    ..fillRange(0, Tile.byteLength, value);
  return Tile.takeOwnership(pixels);
}

final class _CacheWriteFailure implements Exception {
  const _CacheWriteFailure();
}

final class _GallerySaveCrash implements Exception {
  const _GallerySaveCrash();
}
