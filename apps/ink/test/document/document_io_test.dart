import 'dart:async';
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
    root = Directory.systemTemp.createTempSync('ink-document-io-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test(
    'save writes the specified layout and open round-trips pixels',
    () async {
      final store = DocumentStore(root: root);
      final tiles = TileStore()
        ..publish('L1', const TileKey(2, 1), _tile(21))
        ..publish('L1', const TileKey(0, 3), _tile(3));

      final saved = await store.saveDocument(_document(), tiles);

      expect(store.manifestFile('art-1').existsSync(), isTrue);
      expect(
        store
            .tileFile(
              'art-1',
              const TileLocation(layerId: 'L1', key: TileKey(2, 1)),
            )
            .existsSync(),
        isTrue,
      );
      expect(saved.layers.single.tiles, const <TileKey>[
        TileKey(0, 3),
        TileKey(2, 1),
      ]);

      final opened = await store.openDocument('art-1');
      expect(opened, isNotNull);
      expect(opened!.issues, isEmpty);
      expect(
        opened.tiles.tile('L1', const TileKey(2, 1))!.pixels,
        orderedEquals(_tile(21).pixels),
      );
    },
  );

  test('manifest is the last authoritative document write', () async {
    final events = <(DocumentIoPoint, String)>[];
    final store = DocumentStore(
      root: root,
      interrupt: (point, target) {
        events.add((point, target.path));
      },
    );
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', const TileKey(1, 0), _tile(2));

    await store.saveDocument(_document(), tiles);

    final manifestRename = events.indexWhere(
      (event) =>
          event.$1 == DocumentIoPoint.afterAtomicRename &&
          event.$2.endsWith('/manifest.json'),
    );
    final tileRenames = <int>[
      for (var index = 0; index < events.length; index += 1)
        if (events[index].$1 == DocumentIoPoint.afterAtomicRename &&
            events[index].$2.endsWith('.tile'))
          index,
    ];
    expect(tileRenames, isNotEmpty);
    expect(tileRenames.every((index) => index < manifestRename), isTrue);
  });

  test('save refreshes manifest tile lists from sparse store truth', () async {
    final store = DocumentStore(root: root);
    final stale = _document().copyWith(
      layers: <InkLayer>[
        _document().layers.single.copyWith(
          tiles: const <TileKey>[TileKey(9, 9)],
        ),
      ],
    );
    final tiles = TileStore()..publish('L1', const TileKey(-1, 4), _tile(4));

    await store.saveDocument(stale, tiles);
    final json =
        jsonDecode(store.manifestFile('art-1').readAsStringSync())
            as Map<String, Object?>;
    final layers = json['layers']! as List<Object?>;
    final layer = layers.single! as Map<String, Object?>;

    expect(layer['tiles'], <Object?>[
      <Object?>[-1, 4],
    ]);
  });

  test(
    'manifest rewrites preserve unknown keys at every model level',
    () async {
      final store = DocumentStore(root: root);
      final base = _document();
      final document = base.copyWith(
        unknownFields: const <String, Object?>{
          'futureDocument': <String, Object?>{'enabled': true},
        },
        canvas: base.canvas.copyWith(
          unknownFields: const <String, Object?>{'futureCanvas': 7},
        ),
        layers: <InkLayer>[
          base.layers.single.copyWith(
            unknownFields: const <String, Object?>{'futureLayer': 'kept'},
          ),
        ],
        view: base.view.copyWith(
          unknownFields: const <String, Object?>{'futureView': false},
        ),
        tool: base.tool.copyWith(
          unknownFields: const <String, Object?>{
            'futureTool': <Object?>[1, 2],
          },
        ),
      );

      await store.saveDocument(document, TileStore());
      final opened = (await store.openDocument('art-1'))!;
      await store.saveDocument(opened.document, opened.tiles);
      final json =
          jsonDecode(store.manifestFile('art-1').readAsStringSync())
              as Map<String, Object?>;

      expect(json['futureDocument'], <String, Object?>{'enabled': true});
      expect((json['canvas']! as Map<String, Object?>)['futureCanvas'], 7);
      expect(
        ((json['layers']! as List<Object?>).single!
            as Map<String, Object?>)['futureLayer'],
        'kept',
      );
      expect((json['view']! as Map<String, Object?>)['futureView'], isFalse);
      expect((json['tool']! as Map<String, Object?>)['futureTool'], <Object?>[
        1,
        2,
      ]);
    },
  );

  test('dirty save skips an unchanged tile that is already durable', () async {
    final events = <String>[];
    final store = DocumentStore(
      root: root,
      interrupt: (point, target) {
        if (point == DocumentIoPoint.afterAtomicRename &&
            target.path.contains('/layers/') &&
            target.path.endsWith('.tile')) {
          events.add(target.path);
        }
      },
    );
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', const TileKey(1, 0), _tile(2));
    await store.saveDocument(_document(), tiles);
    events.clear();

    tiles.publish('L1', const TileKey(1, 0), _tile(7));
    await store.saveDocument(
      _document(modifiedAtMs: 2),
      tiles,
      dirtyTiles: const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(1, 0)),
      ],
    );

    expect(events, hasLength(1));
    expect(events.single, endsWith('/1_0.tile'));
  });

  test('dirty save repairs a referenced tile missing from disk', () async {
    final store = DocumentStore(root: root);
    final location = const TileLocation(layerId: 'L1', key: TileKey(0, 0));
    final tiles = TileStore()..publish('L1', location.key, _tile(8));
    await store.saveDocument(_document(), tiles);
    store.tileFile('art-1', location).deleteSync();

    await store.saveDocument(
      _document(modifiedAtMs: 2),
      tiles,
      dirtyTiles: const <TileLocation>[],
    );

    expect(store.tileFile('art-1', location).existsSync(), isTrue);
  });

  test(
    'removed tile is unreferenced at commit then collected on open',
    () async {
      final store = DocumentStore(root: root);
      const removed = TileLocation(layerId: 'L1', key: TileKey(1, 0));
      final tiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1))
        ..publish('L1', removed.key, _tile(2));
      await store.saveDocument(_document(), tiles);
      tiles.remove('L1', removed.key);

      await store.saveDocument(
        _document(modifiedAtMs: 2),
        tiles,
        dirtyTiles: const <TileLocation>[removed],
      );
      expect(store.tileFile('art-1', removed).existsSync(), isTrue);

      final opened = (await store.openDocument('art-1'))!;
      expect(opened.tiles.tile('L1', removed.key), isNull);
      expect(store.tileFile('art-1', removed).existsSync(), isFalse);
    },
  );

  test('open garbage-collects tile-first save orphans', () async {
    final store = DocumentStore(root: root);
    final tiles = TileStore()..publish('L1', const TileKey(0, 0), _tile(1));
    await store.saveDocument(_document(), tiles);
    final orphan = store.tileFile(
      'art-1',
      const TileLocation(layerId: 'L1', key: TileKey(7, 7)),
    );
    orphan.parent.createSync(recursive: true);
    orphan.writeAsBytesSync(InkTileCodec.encodeTile(_tile(9)));

    await store.openDocument('art-1');

    expect(orphan.existsSync(), isFalse);
  });

  test('open deletes abandoned tile and manifest temporary files', () async {
    final store = DocumentStore(root: root);
    await store.saveDocument(_document(), TileStore());
    final tileTmp = File(
      '${store.artworkDirectory('art-1').path}/layers/L1/0_0.tile.tmp',
    );
    tileTmp.parent.createSync(recursive: true);
    tileTmp.writeAsStringSync('partial');
    final manifestTmp = File('${store.manifestFile('art-1').path}.tmp')
      ..writeAsStringSync('partial');

    await store.openDocument('art-1');

    expect(tileTmp.existsSync(), isFalse);
    expect(manifestTmp.existsSync(), isFalse);
  });

  test(
    'a missing referenced tile returns a partial document and issue',
    () async {
      final store = DocumentStore(root: root);
      const missing = TileLocation(layerId: 'L1', key: TileKey(0, 0));
      final tiles = TileStore()..publish('L1', missing.key, _tile(1));
      await store.saveDocument(_document(), tiles);
      store.tileFile('art-1', missing).deleteSync();

      final opened = await store.openDocument('art-1');

      expect(opened, isNotNull);
      expect(opened!.document.id, 'art-1');
      expect(opened.tiles.tile('L1', missing.key), isNull);
      expect(opened.issues.single.kind, DocumentLoadIssueKind.missingTile);
    },
  );

  test('a corrupt tile is quarantined while valid tiles still open', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 12345);
    const corrupt = TileLocation(layerId: 'L1', key: TileKey(0, 0));
    const valid = TileLocation(layerId: 'L1', key: TileKey(1, 0));
    final tiles = TileStore()
      ..publish('L1', corrupt.key, _tile(1))
      ..publish('L1', valid.key, _tile(2));
    await store.saveDocument(_document(), tiles);
    store.tileFile('art-1', corrupt).writeAsStringSync('not a tile');

    final opened = (await store.openDocument('art-1'))!;

    expect(opened.tiles.tile('L1', corrupt.key), isNull);
    expect(opened.tiles.tile('L1', valid.key), isNotNull);
    expect(opened.issues.single.kind, DocumentLoadIssueKind.corruptTile);
    expect(
      File(
        '${store.tileFile('art-1', corrupt).path}.corrupt-12345',
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'a corrupt manifest is quarantined and cannot be safely opened',
    () async {
      final store = DocumentStore(root: root, nowMilliseconds: () => 6789);
      await store.saveDocument(_document(), TileStore());
      store.manifestFile('art-1').writeAsStringSync('{broken');

      final opened = await store.openDocument('art-1');

      expect(opened, isNull);
      expect(store.manifestFile('art-1').existsSync(), isFalse);
      expect(
        File('${store.manifestFile('art-1').path}.corrupt-6789').existsSync(),
        isTrue,
      );
    },
  );

  for (final point in <DocumentIoPoint>[
    DocumentIoPoint.beforeTemporaryWrite,
    DocumentIoPoint.afterTemporaryFlush,
    DocumentIoPoint.beforeAtomicRename,
  ]) {
    test('manifest interruption at ${point.name} retains old commit', () async {
      final initialStore = DocumentStore(root: root);
      final initialTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1));
      await initialStore.saveDocument(_document(name: 'before'), initialTiles);

      final nextTiles = TileStore.from(initialTiles)
        ..publish('L1', const TileKey(1, 0), _tile(2));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (candidate, target) {
          if (candidate == point && target.path.endsWith('/manifest.json')) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(
          _document(name: 'after', modifiedAtMs: 2),
          nextTiles,
        ),
        throwsA(isA<_SimulatedCrash>()),
      );

      final recovered = (await initialStore.openDocument('art-1'))!;
      expect(recovered.document.name, 'before');
      expect(recovered.tiles.tile('L1', const TileKey(0, 0)), isNotNull);
      expect(recovered.tiles.tile('L1', const TileKey(1, 0)), isNull);
      expect(
        initialStore
            .tileFile(
              'art-1',
              const TileLocation(layerId: 'L1', key: TileKey(1, 0)),
            )
            .existsSync(),
        isFalse,
      );
    });
  }

  test(
    'tile interruption after temp flush keeps old commit and drops temp',
    () async {
      final initialStore = DocumentStore(root: root);
      final initialTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1));
      await initialStore.saveDocument(_document(name: 'before'), initialTiles);
      final nextTiles = TileStore.from(initialTiles)
        ..publish('L1', const TileKey(1, 0), _tile(2));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterTemporaryFlush &&
              target.path.endsWith('/1_0.tile')) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(
          _document(name: 'after', modifiedAtMs: 2),
          nextTiles,
        ),
        throwsA(isA<_SimulatedCrash>()),
      );

      final recovered = (await initialStore.openDocument('art-1'))!;
      expect(recovered.document.name, 'before');
      final newTile = initialStore.tileFile(
        'art-1',
        const TileLocation(layerId: 'L1', key: TileKey(1, 0)),
      );
      expect(newTile.existsSync(), isFalse);
      expect(File('${newTile.path}.tmp').existsSync(), isFalse);
    },
  );

  test(
    'tile interruption after rename leaves an orphan collected on open',
    () async {
      final initialStore = DocumentStore(root: root);
      final initialTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1));
      await initialStore.saveDocument(_document(name: 'before'), initialTiles);
      final nextTiles = TileStore.from(initialTiles)
        ..publish('L1', const TileKey(1, 0), _tile(2));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterAtomicRename &&
              target.path.endsWith('/1_0.tile')) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(
          _document(name: 'after', modifiedAtMs: 2),
          nextTiles,
        ),
        throwsA(isA<_SimulatedCrash>()),
      );
      final orphan = initialStore.tileFile(
        'art-1',
        const TileLocation(layerId: 'L1', key: TileKey(1, 0)),
      );
      expect(orphan.existsSync(), isTrue);

      final recovered = (await initialStore.openDocument('art-1'))!;
      expect(recovered.document.name, 'before');
      expect(orphan.existsSync(), isFalse);
    },
  );

  test('interruption at tile-manifest boundary collects new orphan', () async {
    final initialStore = DocumentStore(root: root);
    final initialTiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1));
    await initialStore.saveDocument(_document(name: 'before'), initialTiles);
    final nextTiles = TileStore.from(initialTiles)
      ..publish('L1', const TileKey(1, 0), _tile(2));
    final crashingStore = DocumentStore(
      root: root,
      interrupt: (point, target) {
        if (point == DocumentIoPoint.afterTileWritesBeforeManifest) {
          throw const _SimulatedCrash();
        }
      },
    );

    await expectLater(
      crashingStore.saveDocument(
        _document(name: 'after', modifiedAtMs: 2),
        nextTiles,
      ),
      throwsA(isA<_SimulatedCrash>()),
    );

    final recovered = (await initialStore.openDocument('art-1'))!;
    expect(recovered.document.name, 'before');
    expect(recovered.tiles.tile('L1', const TileKey(1, 0)), isNull);
  });

  test('interruption after manifest rename observes the new commit', () async {
    final initialStore = DocumentStore(root: root);
    await initialStore.saveDocument(_document(name: 'before'), TileStore());
    final crashingStore = DocumentStore(
      root: root,
      interrupt: (point, target) {
        if (point == DocumentIoPoint.afterAtomicRename &&
            target.path.endsWith('/manifest.json')) {
          throw const _SimulatedCrash();
        }
      },
    );

    await expectLater(
      crashingStore.saveDocument(
        _document(name: 'after', modifiedAtMs: 2),
        TileStore(),
      ),
      throwsA(isA<_SimulatedCrash>()),
    );

    expect((await initialStore.openDocument('art-1'))!.document.name, 'after');
  });

  test('interruption after manifest write observes the new commit', () async {
    final initialStore = DocumentStore(root: root);
    await initialStore.saveDocument(_document(name: 'before'), TileStore());
    final crashingStore = DocumentStore(
      root: root,
      interrupt: (point, target) {
        if (point == DocumentIoPoint.afterManifestWrite) {
          throw const _SimulatedCrash();
        }
      },
    );

    await expectLater(
      crashingStore.saveDocument(
        _document(name: 'after', modifiedAtMs: 2),
        TileStore(),
      ),
      throwsA(isA<_SimulatedCrash>()),
    );

    expect((await initialStore.openDocument('art-1'))!.document.name, 'after');
  });

  test(
    'pixel-only crash after tile rename restores old pixels and revision',
    () async {
      final cleanStore = DocumentStore(root: root);
      final firstTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1));
      final firstDocument = await cleanStore.saveDocument(
        _document(),
        firstTiles,
      );
      final oldRevision = firstDocument.toJson()['_storageRevision']! as int;
      final nextTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(2));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterAtomicRename &&
              target.path.contains('/layers/') &&
              target.path.endsWith('/0_0.tile')) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(firstDocument, nextTiles),
        throwsA(isA<_SimulatedCrash>()),
      );
      expect(
        InkTileCodec.decodeTile(
          cleanStore
              .tileFile(
                'art-1',
                const TileLocation(layerId: 'L1', key: TileKey(0, 0)),
              )
              .readAsBytesSync(),
        ).pixels.first,
        2,
      );

      final recovered = (await cleanStore.openDocument('art-1'))!;
      expect(recovered.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 1);
      expect(recovered.document.toJson()['_storageRevision'], oldRevision);
      expect(
        Directory(
          '${cleanStore.artworkDirectory('art-1').path}/.pending-save',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'pixel-only crash at tile-manifest boundary restores old pixels',
    () async {
      final cleanStore = DocumentStore(root: root);
      final firstTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(3));
      final firstDocument = await cleanStore.saveDocument(
        _document(),
        firstTiles,
      );
      final nextTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(4));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterTileWritesBeforeManifest) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(firstDocument, nextTiles),
        throwsA(isA<_SimulatedCrash>()),
      );

      final recovered = (await cleanStore.openDocument('art-1'))!;
      expect(recovered.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 3);
    },
  );

  test('pixel-only crash after manifest rename finalizes new pixels', () async {
    final cleanStore = DocumentStore(root: root);
    final firstTiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(5));
    final firstDocument = await cleanStore.saveDocument(
      _document(),
      firstTiles,
    );
    final oldRevision = firstDocument.toJson()['_storageRevision']! as int;
    final nextTiles = TileStore()..publish('L1', const TileKey(0, 0), _tile(6));
    final crashingStore = DocumentStore(
      root: root,
      interrupt: (point, target) {
        if (point == DocumentIoPoint.afterAtomicRename &&
            target.path.endsWith('/manifest.json')) {
          throw const _SimulatedCrash();
        }
      },
    );

    await expectLater(
      crashingStore.saveDocument(firstDocument, nextTiles),
      throwsA(isA<_SimulatedCrash>()),
    );

    final recovered = (await cleanStore.openDocument('art-1'))!;
    expect(recovered.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 6);
    expect(recovered.document.toJson()['_storageRevision'], oldRevision + 1);
  });

  test(
    'backup preparation interruption never changes the old commit',
    () async {
      final cleanStore = DocumentStore(root: root);
      final firstTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(7));
      final firstDocument = await cleanStore.saveDocument(
        _document(),
        firstTiles,
      );
      final nextTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(8));
      final crashingStore = DocumentStore(
        root: root,
        interrupt: (point, target) {
          if (point == DocumentIoPoint.afterAtomicRename &&
              target.path.contains('/.pending-save/backups/')) {
            throw const _SimulatedCrash();
          }
        },
      );

      await expectLater(
        crashingStore.saveDocument(firstDocument, nextTiles),
        throwsA(isA<_SimulatedCrash>()),
      );

      final recovered = (await cleanStore.openDocument('art-1'))!;
      expect(recovered.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 7);
      expect(
        Directory(
          '${cleanStore.artworkDirectory('art-1').path}/.pending-save',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('lazy open loads selected tiles then the deferred remainder', () async {
    final store = DocumentStore(root: root);
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', const TileKey(1, 0), _tile(2))
      ..publish('L1', const TileKey(2, 0), _tile(3));
    await store.saveDocument(_document(), tiles);

    final opened = (await store.openDocument(
      'art-1',
      initialTileSelector: (document) => const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(2, 0)),
      ],
    ))!;

    expect(opened.tiles.tileCount, 1);
    expect(opened.tiles.tile('L1', const TileKey(2, 0)), isNotNull);
    expect(opened.remainingTileCount, 2);
    expect(await opened.loadNext(count: 1), 1);
    expect(opened.tiles.tileCount, 2);
    expect(opened.remainingTileCount, 1);
    await opened.loadRemaining();
    expect(opened.tiles.tileCount, 3);
    expect(opened.remainingTileCount, 0);
    expect(opened.issues, isEmpty);
  });

  test(
    'dirty save from lazy store preserves deferred offscreen tiles',
    () async {
      final store = DocumentStore(root: root);
      final tiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1))
        ..publish('L1', const TileKey(1, 0), _tile(2));
      await store.saveDocument(_document(), tiles);
      final opened = (await store.openDocument(
        'art-1',
        initialTiles: const <TileLocation>[
          TileLocation(layerId: 'L1', key: TileKey(0, 0)),
        ],
      ))!;
      opened.tiles.publish('L1', const TileKey(0, 0), _tile(9));

      await store.saveDocument(
        opened.document,
        opened.tiles,
        dirtyTiles: const <TileLocation>[
          TileLocation(layerId: 'L1', key: TileKey(0, 0)),
        ],
      );

      final reopened = (await store.openDocument('art-1'))!;
      expect(reopened.tiles.tileCount, 2);
      expect(reopened.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 9);
      expect(reopened.tiles.tile('L1', const TileKey(1, 0))!.pixels.first, 2);
    },
  );

  test(
    'dirty deletion from lazy store removes only the requested tile',
    () async {
      final store = DocumentStore(root: root);
      final tiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(1))
        ..publish('L1', const TileKey(1, 0), _tile(2));
      await store.saveDocument(_document(), tiles);
      final opened = (await store.openDocument(
        'art-1',
        initialTiles: const <TileLocation>[
          TileLocation(layerId: 'L1', key: TileKey(0, 0)),
        ],
      ))!;
      opened.tiles.remove('L1', const TileKey(0, 0));

      await store.saveDocument(
        opened.document,
        opened.tiles,
        dirtyTiles: const <TileLocation>[
          TileLocation(layerId: 'L1', key: TileKey(0, 0)),
        ],
      );

      final reopened = (await store.openDocument('art-1'))!;
      expect(reopened.tiles.tile('L1', const TileKey(0, 0)), isNull);
      expect(reopened.tiles.tile('L1', const TileKey(1, 0)), isNotNull);
    },
  );

  test('dirty save prunes a missing deferred tile reference', () async {
    final store = DocumentStore(root: root);
    const deferred = TileLocation(layerId: 'L1', key: TileKey(1, 0));
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', deferred.key, _tile(2));
    await store.saveDocument(_document(), tiles);
    store.tileFile('art-1', deferred).deleteSync();
    final opened = (await store.openDocument(
      'art-1',
      initialTiles: const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(0, 0)),
      ],
    ))!;
    expect(opened.remainingTileCount, 1);
    opened.tiles.publish('L1', const TileKey(0, 0), _tile(9));

    final saved = await store.saveDocument(
      opened.document,
      opened.tiles,
      dirtyTiles: const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(0, 0)),
      ],
    );

    expect(saved.layers.single.tiles, const <TileKey>[TileKey(0, 0)]);
    final reopened = (await store.openDocument('art-1'))!;
    expect(reopened.issues, isEmpty);
    expect(reopened.tiles.tileCount, 1);
    expect(reopened.tiles.tile('L1', deferred.key), isNull);
  });

  test('dirty save prunes a quarantined deferred tile reference', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 5757);
    const deferred = TileLocation(layerId: 'L1', key: TileKey(1, 0));
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', deferred.key, _tile(2));
    await store.saveDocument(_document(), tiles);
    final corruptFile = store.tileFile('art-1', deferred)
      ..writeAsStringSync('corrupt');
    final opened = (await store.openDocument(
      'art-1',
      initialTiles: const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(0, 0)),
      ],
    ))!;
    await opened.loadRemaining();
    expect(opened.issues.single.kind, DocumentLoadIssueKind.corruptTile);
    expect(corruptFile.existsSync(), isFalse);
    expect(File('${corruptFile.path}.corrupt-5757').existsSync(), isTrue);
    opened.tiles.publish('L1', const TileKey(0, 0), _tile(9));

    final saved = await store.saveDocument(
      opened.document,
      opened.tiles,
      dirtyTiles: const <TileLocation>[
        TileLocation(layerId: 'L1', key: TileKey(0, 0)),
      ],
    );

    expect(saved.layers.single.tiles, const <TileKey>[TileKey(0, 0)]);
    final reopened = (await store.openDocument('art-1'))!;
    expect(reopened.issues, isEmpty);
    expect(reopened.tiles.tileCount, 1);
    expect(reopened.tiles.tile('L1', deferred.key), isNull);
  });

  test('oversized encoded tile is quarantined before allocation', () async {
    final store = DocumentStore(root: root, nowMilliseconds: () => 444);
    const location = TileLocation(layerId: 'L1', key: TileKey(0, 0));
    final tiles = TileStore()..publish('L1', location.key, _tile(1));
    await store.saveDocument(_document(), tiles);
    final file = store.tileFile('art-1', location);
    final handle = file.openSync(mode: FileMode.write);
    handle
      ..truncateSync(InkTileCodec.maxEncodedLength + 1)
      ..closeSync();

    final opened = (await store.openDocument('art-1'))!;

    expect(opened.tiles.tileCount, 0);
    expect(opened.issues.single.kind, DocumentLoadIssueKind.corruptTile);
    expect(File('${file.path}.corrupt-444').existsSync(), isTrue);
  });

  test('per-call async codec seams run tile work concurrently', () async {
    final store = DocumentStore(root: root);
    final tiles = TileStore()
      ..publish('L1', const TileKey(0, 0), _tile(1))
      ..publish('L1', const TileKey(1, 0), _tile(2))
      ..publish('L1', const TileKey(2, 0), _tile(3));
    var activeEncoders = 0;
    var maxEncoders = 0;
    await store.saveDocument(
      _document(),
      tiles,
      tileEncoder: (tile) async {
        activeEncoders += 1;
        if (activeEncoders > maxEncoders) {
          maxEncoders = activeEncoders;
        }
        await Future<void>.delayed(Duration.zero);
        final encoded = InkTileCodec.encodeTile(tile);
        activeEncoders -= 1;
        return encoded;
      },
    );
    var activeDecoders = 0;
    var maxDecoders = 0;

    final opened = await store.openDocument(
      'art-1',
      tileDecoder: (encoded) async {
        activeDecoders += 1;
        if (activeDecoders > maxDecoders) {
          maxDecoders = activeDecoders;
        }
        await Future<void>.delayed(Duration.zero);
        final tile = InkTileCodec.decodeTile(encoded);
        activeDecoders -= 1;
        return tile;
      },
    );

    expect(opened!.tiles.tileCount, 3);
    expect(maxEncoders, greaterThan(1));
    expect(maxDecoders, greaterThan(1));
  });

  test(
    'save encodes the immutable invocation-time TileStore snapshot',
    () async {
      final store = DocumentStore(root: root);
      final tiles = TileStore()..publish('L1', const TileKey(0, 0), _tile(11));
      final encoderStarted = Completer<void>();
      final releaseEncoder = Completer<void>();

      final save = store.saveDocument(
        _document(),
        tiles,
        tileEncoder: (tile) async {
          encoderStarted.complete();
          await releaseEncoder.future;
          return InkTileCodec.encodeTile(tile);
        },
      );
      await encoderStarted.future;
      tiles.publish('L1', const TileKey(0, 0), _tile(22));
      releaseEncoder.complete();
      await save;

      final opened = (await store.openDocument('art-1'))!;
      expect(opened.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 11);
    },
  );

  test(
    'overlapping saves serialize into one complete final generation',
    () async {
      final store = DocumentStore(root: root);
      final firstTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(31));
      final secondTiles = TileStore()
        ..publish('L1', const TileKey(0, 0), _tile(42));
      final firstEncoderStarted = Completer<void>();
      final releaseFirstEncoder = Completer<void>();

      final firstSave = store.saveDocument(
        _document(name: 'first'),
        firstTiles,
        tileEncoder: (tile) async {
          firstEncoderStarted.complete();
          await releaseFirstEncoder.future;
          return InkTileCodec.encodeTile(tile);
        },
      );
      await firstEncoderStarted.future;
      final secondSave = store.saveDocument(
        _document(name: 'second', modifiedAtMs: 2),
        secondTiles,
      );
      releaseFirstEncoder.complete();
      await Future.wait(<Future<InkDocument>>[firstSave, secondSave]);

      final opened = (await store.openDocument('art-1'))!;
      expect(opened.document.name, 'second');
      expect(opened.tiles.tile('L1', const TileKey(0, 0))!.pixels.first, 42);
      expect(
        Directory(
          '${store.artworkDirectory('art-1').path}/.pending-save',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('unsafe artwork and layer identifiers cannot escape the root', () async {
    final store = DocumentStore(root: root);
    expect(() => store.artworkDirectory('../escape'), throwsFormatException);
    final unsafe = _document().copyWith(
      layers: <InkLayer>[InkLayer(id: '../L1', name: 'unsafe')],
      activeLayerId: '../L1',
    );
    await expectLater(
      store.saveDocument(unsafe, TileStore()),
      throwsFormatException,
    );
  });
}

InkDocument _document({String name = 'drawing', int modifiedAtMs = 1}) =>
    InkDocument.blank(
      id: 'art-1',
      nowMs: 1,
      name: name,
    ).copyWith(modifiedAtMs: modifiedAtMs);

Tile _tile(int value) {
  final pixels = Uint8List(Tile.byteLength)
    ..fillRange(0, Tile.byteLength, value);
  return Tile.takeOwnership(pixels);
}

final class _SimulatedCrash implements Exception {
  const _SimulatedCrash();
}
