import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/engine/compositor.dart';

void main() {
  const key0 = TileKey(0, 0);
  const key1 = TileKey(1, 0);
  const key2 = TileKey(2, 0);

  group('visible-layer compositing', () {
    test('normal source-over flattens premultiplied RGBA', () {
      final tiles = TileStore()
        ..publish('bottom', key0, _pixelTile(0, 0, 255, 255))
        ..publish('top', key0, _pixelTile(128, 0, 0, 128));
      final output = compositeVisibleTile(
        key: key0,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top'),
        ],
        tiles: tiles,
      );

      expect(output.sublist(0, 4), <int>[128, 0, 127, 255]);
    });

    test('layer opacity scales premultiplied color and alpha together', () {
      final tiles = TileStore()
        ..publish('top', key0, _pixelTile(255, 0, 0, 255));
      final output = compositeVisibleTile(
        key: key0,
        layers: <InkLayer>[InkLayer(id: 'top', name: 'Top', opacity: 50)],
        tiles: tiles,
      );

      expect(output.sublist(0, 4), <int>[128, 0, 0, 128]);
    });

    test('multiply uses premultiplied source-over blend math', () {
      final tiles = TileStore()
        ..publish('bottom', key0, _pixelTile(100, 100, 100, 255))
        ..publish('top', key0, _pixelTile(200, 0, 0, 255));
      final output = compositeVisibleTile(
        key: key0,
        layers: <InkLayer>[
          InkLayer(id: 'bottom', name: 'Bottom'),
          InkLayer(id: 'top', name: 'Top', blend: 'multiply'),
        ],
        tiles: tiles,
      );

      expect(output.sublist(0, 4), <int>[78, 0, 0, 255]);
    });

    test('hidden and zero-opacity layers contribute nothing', () {
      final tiles = TileStore()
        ..publish('hidden', key0, _pixelTile(255, 0, 0, 255))
        ..publish('zero', key0, _pixelTile(0, 255, 0, 255));
      final output = compositeVisibleTile(
        key: key0,
        layers: <InkLayer>[
          InkLayer(id: 'hidden', name: 'Hidden', visible: false),
          InkLayer(id: 'zero', name: 'Zero', opacity: 0),
        ],
        tiles: tiles,
      );

      expect(output, everyElement(0));
    });

    test('absent tiles are transparent rather than paper-colored', () {
      final output = compositeVisibleTile(
        key: key0,
        layers: <InkLayer>[InkLayer(id: 'layer', name: 'Layer')],
        tiles: TileStore(),
      );

      expect(output.length, Tile.byteLength);
      expect(output, everyElement(0));
    });
  });

  group('CompositeTileCache', () {
    test('caches pixels without uploading when requested', () async {
      final tiles = TileStore()
        ..publish('layer', key0, _pixelTile(1, 2, 3, 255));
      final cache = CompositeTileCache();

      final first = await cache.ensureTile(
        key: key0,
        document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
        tiles: tiles,
        uploadImage: false,
      );
      final second = await cache.ensureTile(
        key: key0,
        document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
        tiles: tiles,
        uploadImage: false,
      );

      expect(identical(first, second), isTrue);
      expect(first.image, isNull);
      expect(first.documentRect, const Rect.fromLTWH(0, 0, 256, 256));
      expect(() => first.pixels[0] = 9, throwsUnsupportedError);
      cache.dispose();
    });

    test('concurrent ensures share one in-flight image upload', () async {
      var uploads = 0;
      final release = Completer<ui.Image>();
      final cache = CompositeTileCache(
        imageUploader: (pixels, width, height) {
          uploads += 1;
          return release.future;
        },
      );
      final document = _document(<InkLayer>[
        InkLayer(id: 'layer', name: 'Layer'),
      ]);
      final tiles = TileStore()
        ..publish('layer', key0, _pixelTile(1, 2, 3, 255));

      final first = cache.ensureTile(
        key: key0,
        document: document,
        tiles: tiles,
      );
      final second = cache.ensureTile(
        key: key0,
        document: document,
        tiles: tiles,
      );
      release.complete(_blankImage(Tile.edge, Tile.edge));
      final results = await Future.wait(<Future<CompositeTile>>[first, second]);

      expect(uploads, 1);
      expect(identical(results.first, results.last), isTrue);
      expect(results.first.image, isNotNull);
      cache.dispose();
    });

    test('published tile identity invalidates only its coordinate', () async {
      final layer = InkLayer(id: 'layer', name: 'Layer');
      final document = _document(<InkLayer>[layer]);
      final tiles = TileStore()
        ..publish('layer', key0, _pixelTile(1, 0, 0, 255))
        ..publish('layer', key1, _pixelTile(2, 0, 0, 255));
      final cache = CompositeTileCache();
      final old0 = await cache.ensureTile(
        key: key0,
        document: document,
        tiles: tiles,
        uploadImage: false,
      );
      final old1 = await cache.ensureTile(
        key: key1,
        document: document,
        tiles: tiles,
        uploadImage: false,
      );

      tiles.publish('layer', key0, _pixelTile(9, 0, 0, 255));
      final next0 = await cache.ensureTile(
        key: key0,
        document: document,
        tiles: tiles,
        uploadImage: false,
      );

      expect(identical(next0, old0), isFalse);
      expect(identical(cache.lookup(key1), old1), isTrue);
      expect(next0.pixels[0], 9);
      cache.dispose();
    });

    test('layer-property signature invalidates the whole cache', () async {
      final tiles = TileStore()
        ..publish('layer', key0, _pixelTile(20, 0, 0, 255))
        ..publish('layer', key1, _pixelTile(30, 0, 0, 255));
      final cache = CompositeTileCache();
      final firstDocument = _document(<InkLayer>[
        InkLayer(id: 'layer', name: 'Layer'),
      ]);
      await cache.ensureTiles(
        keys: const <TileKey>[key0, key1],
        document: firstDocument,
        tiles: tiles,
        uploadImages: false,
      );

      await cache.ensureTile(
        key: key0,
        document: _document(<InkLayer>[
          InkLayer(id: 'layer', name: 'Layer', opacity: 50),
        ]),
        tiles: tiles,
        uploadImage: false,
      );

      expect(cache.keys, const <TileKey>[key0]);
      expect(cache.lookup(key0)!.pixels[0], 10);
      cache.dispose();
    });

    test('explicit invalidation is tile granular', () async {
      final document = _document(<InkLayer>[
        InkLayer(id: 'layer', name: 'Layer'),
      ]);
      final cache = CompositeTileCache();
      await cache.ensureTiles(
        keys: const <TileKey>[key0, key1],
        document: document,
        tiles: TileStore(),
        uploadImages: false,
      );

      expect(cache.invalidate(key0), isTrue);
      expect(cache.invalidate(key0), isFalse);
      expect(cache.keys, const <TileKey>[key1]);
      cache.dispose();
    });

    test('capacity eviction is least-recently used', () async {
      final document = _document(<InkLayer>[
        InkLayer(id: 'layer', name: 'Layer'),
      ]);
      final cache = CompositeTileCache(maxEntries: 2);
      await cache.ensureTiles(
        keys: const <TileKey>[key0, key1],
        document: document,
        tiles: TileStore(),
        uploadImages: false,
      );
      cache.lookup(key0);
      await cache.ensureTile(
        key: key2,
        document: document,
        tiles: TileStore(),
        uploadImage: false,
      );

      expect(cache.keys, const <TileKey>[key0, key2]);
      cache.dispose();
    });

    test(
      'default capacity retains every tile of a maximum-size viewport',
      () async {
        final document = _document(<InkLayer>[
          InkLayer(id: 'layer', name: 'Layer'),
        ]);
        final cache = CompositeTileCache(batchBuilder: _transparentBatch);
        final keys = <TileKey>[
          for (var y = 0; y < 16; y += 1)
            for (var x = 0; x < 16; x += 1) TileKey(x, y),
        ];

        await cache.ensureTiles(
          keys: keys,
          document: document,
          tiles: TileStore(),
          uploadImages: false,
        );

        expect(cache.length, 256);
        expect(cache.keys.toSet(), keys.toSet());
        cache.dispose();
      },
    );

    test('more than eight rebuilds delegate through the worker seam', () async {
      var calls = 0;
      final requestedBatches = <List<TileKey>>[];
      final cache = CompositeTileCache(
        batchBuilder:
            ({required keys, required document, required tiles}) async {
              calls += 1;
              requestedBatches.add(keys);
              return <TileKey, Uint8List>{
                for (final key in keys) key: Uint8List(Tile.byteLength),
              };
            },
      );
      final keys = <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)];

      await cache.ensureTiles(
        keys: keys,
        document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
        tiles: TileStore(),
        uploadImages: false,
      );

      expect(calls, 1);
      expect(requestedBatches.single, keys);
      cache.dispose();
    });

    test(
      'worker results revalidate tile refs published during the await',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final cache = CompositeTileCache(
          batchBuilder:
              ({required keys, required document, required tiles}) async {
                entered.complete();
                await release.future;
                return <TileKey, Uint8List>{
                  for (final key in keys) key: Uint8List(Tile.byteLength),
                };
              },
        );
        final store = TileStore();
        final keys = <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)];
        final pending = cache.ensureTiles(
          keys: keys,
          document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
          tiles: store,
          uploadImages: false,
        );
        await entered.future;

        store.publish('layer', key0, _pixelTile(77, 0, 0, 255));
        release.complete();
        final result = await pending;

        expect(result.first.pixels.sublist(0, 4), <int>[77, 0, 0, 255]);
        expect(cache.lookup(key0)!.pixels[0], 77);
        cache.dispose();
      },
    );

    test('dispose during a worker await cannot repopulate the cache', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final cache = CompositeTileCache(
        batchBuilder:
            ({required keys, required document, required tiles}) async {
              entered.complete();
              await release.future;
              return <TileKey, Uint8List>{
                for (final key in keys) key: Uint8List(Tile.byteLength),
              };
            },
      );
      final pending = cache.ensureTiles(
        keys: <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)],
        document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
        tiles: TileStore(),
        uploadImages: false,
      );
      await entered.future;

      cache.dispose();
      release.complete();

      await expectLater(pending, throwsStateError);
      expect(cache.length, 0);
    });

    test('newer layer properties supersede an older worker response', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final cache = CompositeTileCache(
        batchBuilder:
            ({required keys, required document, required tiles}) async {
              entered.complete();
              await release.future;
              return <TileKey, Uint8List>{
                for (final key in keys) key: Uint8List(Tile.byteLength),
              };
            },
      );
      final store = TileStore()
        ..publish('layer', key0, _pixelTile(100, 0, 0, 255));
      final pending = cache.ensureTiles(
        keys: <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)],
        document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
        tiles: store,
        uploadImages: false,
      );
      await entered.future;

      final newer = await cache.ensureTile(
        key: key0,
        document: _document(<InkLayer>[
          InkLayer(id: 'layer', name: 'Layer', opacity: 50),
        ]),
        tiles: store,
        uploadImage: false,
      );
      release.complete();

      await expectLater(pending, throwsStateError);
      expect(identical(cache.lookup(key0), newer), isTrue);
      expect(newer.pixels[0], 50);
      cache.dispose();
    });

    test('large rebuild without a worker seam fails fast', () async {
      final cache = CompositeTileCache();
      final keys = <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)];

      await expectLater(
        cache.ensureTiles(
          keys: keys,
          document: _document(<InkLayer>[InkLayer(id: 'layer', name: 'Layer')]),
          tiles: TileStore(),
          uploadImages: false,
        ),
        throwsStateError,
      );
      cache.dispose();
    });

    test(
      'viewport eviction supports an optional one-tile pan margin',
      () async {
        final document = _document(<InkLayer>[
          InkLayer(id: 'layer', name: 'Layer'),
        ]);
        final cache = CompositeTileCache();
        await cache.ensureTiles(
          keys: const <TileKey>[key0, key1, key2],
          document: document,
          tiles: TileStore(),
          uploadImages: false,
        );

        expect(
          cache.evictOutsideViewport(const <TileKey>[key0], marginTiles: 1),
          1,
        );
        expect(cache.keys.toSet(), <TileKey>{key0, key1});
        expect(cache.evictOutsideViewport(const <TileKey>[key0]), 1);
        expect(cache.keys, const <TileKey>[key0]);
        cache.dispose();
      },
    );

    test('disposed cache rejects later use', () {
      final cache = CompositeTileCache()..dispose();

      expect(() => cache.lookup(key0), throwsStateError);
    });
  });

  group('debug StrokeBuffer and overlay data', () {
    test('scratch allocation grows on 256-pixel boundaries', () {
      final buffer = StrokeBuffer();

      buffer.stampRound(center: const Offset(10, 10), diameter: 8);
      expect(buffer.bounds, const Rect.fromLTWH(0, 0, 256, 256));
      buffer.stampRound(center: const Offset(260, 10), diameter: 8);
      expect(buffer.bounds, const Rect.fromLTWH(0, 0, 512, 256));
      expect(buffer.isEmpty, isFalse);
    });

    test('document bounds clip a stamp at the canvas edge', () {
      final buffer = StrokeBuffer(documentSize: const Size(100, 100));

      final changed = buffer.stampRound(center: Offset.zero, diameter: 20);

      expect(changed.left, 0);
      expect(changed.top, 0);
      expect(changed.right, closeTo(10.5, 1e-9));
      expect(changed.bottom, closeTo(10.5, 1e-9));
    });

    test('sealing returns immutable bytes and forbids more stamps', () {
      final buffer = StrokeBuffer()
        ..stampRound(center: const Offset(10, 10), diameter: 8);

      final snapshot = buffer.seal();

      expect(snapshot.isEmpty, isFalse);
      expect(() => snapshot.pixels[0] = 1, throwsUnsupportedError);
      expect(
        () => buffer.stampRound(center: const Offset(20, 20)),
        throwsStateError,
      );
    });

    test('debug line stamper fills a continuous center run', () {
      final buffer = StrokeBuffer();
      const stamper = DebugRoundStamper(width: 6, spacingFactor: 0.3);
      stamper.stamp(buffer, const Offset(10, 10));
      stamper.stampSegment(buffer, const Offset(10, 10), const Offset(40, 10));
      final snapshot = buffer.snapshot();

      for (var x = 10; x <= 40; x += 1) {
        final offset = (10 * snapshot.width + x) * 4 + 3;
        expect(snapshot.pixels[offset], greaterThan(0), reason: 'x=$x');
      }
    });

    test('threshold preview emits only opaque pure black pixels', () {
      final input = Uint8List.fromList(<int>[
        50,
        20,
        10,
        127,
        100,
        80,
        60,
        128,
      ]);

      expect(
        thresholdStrokePixels(input, alphaCutoff: 0.5),
        orderedEquals(<int>[0, 0, 0, 0, 0, 0, 0, 255]),
      );
    });

    test('threshold region copies only integer-aligned dirty bounds', () {
      final buffer = StrokeBuffer()
        ..stampRound(center: const Offset(10, 10), diameter: 8);
      final snapshot = buffer.snapshot();

      final region = thresholdStrokeRegion(
        snapshot,
        const Rect.fromLTRB(8.2, 9.1, 11.4, 12.2),
        alphaCutoff: 0.1,
      );

      expect(region.bounds, const Rect.fromLTWH(8, 9, 4, 4));
      expect(region.width, 4);
      expect(region.height, 4);
      expect(region.pixels.length, 4 * 4 * 4);
      expect(region.pixels, contains(255));
    });

    test(
      'live preview bytes scale with dirty bounds, not scratch allocation',
      () {
        final buffer = StrokeBuffer()
          ..stampRound(center: const Offset(10, 10), diameter: 8);
        final dirty = buffer.stampRound(
          center: const Offset(1000, 1000),
          diameter: 8,
        );

        final region = buffer.thresholdedRegion(dirty, alphaCutoff: 0.1);

        expect(buffer.pixels.length, 1024 * 1024 * 4);
        expect(region.width, 10);
        expect(region.height, 10);
        expect(region.pixels.length, 10 * 10 * 4);
      },
    );

    test(
      'overlay retains separately uploaded changed subrect patches',
      () async {
        final uploadedSizes = <(int, int)>[];
        final overlay = StrokeOverlay(
          imageUploader: (pixels, width, height) async {
            uploadedSizes.add((width, height));
            return _blankImage(width, height);
          },
        );
        final buffer = StrokeBuffer();
        final firstDirty = buffer.stampRound(
          center: const Offset(10, 10),
          diameter: 8,
        );
        await overlay.refreshBuffer(buffer, changedBounds: firstDirty);
        final secondDirty = buffer.stampRound(
          center: const Offset(200, 10),
          diameter: 8,
        );
        await overlay.refreshBuffer(buffer, changedBounds: secondDirty);

        expect(overlay.patchCount, 2);
        expect(uploadedSizes, const <(int, int)>[(10, 10), (10, 10)]);
        expect(overlay.bounds.left, 5);
        expect(overlay.bounds.right, 205);

        overlay.clear();
        expect(overlay.patchCount, 0);
        expect(overlay.hasImage, isFalse);
        overlay.dispose();
      },
    );

    test(
      'overlay periodically consolidates patches within each tile',
      () async {
        final uploadedSizes = <(int, int)>[];
        final overlay = StrokeOverlay(
          maxPatchesPerTile: 3,
          imageUploader: (pixels, width, height) async {
            uploadedSizes.add((width, height));
            return _blankImage(width, height);
          },
        );
        final buffer = StrokeBuffer();

        for (var x = 10.0; x <= 50; x += 10) {
          final dirty = buffer.stampRound(center: Offset(x, 10), diameter: 8);
          await overlay.refreshBuffer(buffer, changedBounds: dirty);
        }

        expect(overlay.patchCount, lessThanOrEqualTo(3));
        expect(uploadedSizes, contains(const (256, 256)));
        overlay.dispose();
      },
    );
  });
}

InkDocument _document(List<InkLayer> layers) => InkDocument.blank(
  id: 'test',
  nowMs: 1,
).copyWith(layers: layers, activeLayerId: layers.first.id);

Tile _pixelTile(int red, int green, int blue, int alpha) {
  final pixels = Uint8List(Tile.byteLength)
    ..[0] = red
    ..[1] = green
    ..[2] = blue
    ..[3] = alpha;
  return Tile.takeOwnership(pixels);
}

ui.Image _blankImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff000000),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

Future<Map<TileKey, Uint8List>> _transparentBatch({
  required List<TileKey> keys,
  required InkDocument document,
  required TileStore tiles,
}) async => <TileKey, Uint8List>{
  for (final key in keys) key: Uint8List(Tile.byteLength),
};
