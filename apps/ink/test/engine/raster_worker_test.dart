import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/engine/compositor.dart';
import 'package:paper_ink/src/engine/raster_worker.dart';

void main() {
  group('compositeDebugStrokeTile', () {
    test('opaque stroke replaces a transparent destination pixel', () {
      final stroke = Uint8List(4)
        ..[0] = 12
        ..[1] = 34
        ..[2] = 56
        ..[3] = 255;

      final result = compositeDebugStrokeTile(
        key: const TileKey(0, 0),
        beforePixels: Uint8List(Tile.byteLength),
        strokePixels: stroke,
        strokeOriginX: 10,
        strokeOriginY: 20,
        strokeWidth: 1,
        strokeHeight: 1,
      );

      final offset = (20 * Tile.edge + 10) * 4;
      expect(result.changed, isTrue);
      expect(result.pixels.sublist(offset, offset + 4), <int>[12, 34, 56, 255]);
    });

    test('partial alpha uses premultiplied source-over', () {
      final before = Uint8List(Tile.byteLength)
        ..[0] = 0
        ..[1] = 0
        ..[2] = 255
        ..[3] = 255;
      final stroke = Uint8List.fromList(<int>[128, 0, 0, 128]);

      final result = compositeDebugStrokeTile(
        key: const TileKey(0, 0),
        beforePixels: before,
        strokePixels: stroke,
        strokeOriginX: 0,
        strokeOriginY: 0,
        strokeWidth: 1,
        strokeHeight: 1,
      );

      expect(result.pixels.sublist(0, 4), <int>[128, 0, 127, 255]);
      expect(before.sublist(0, 4), <int>[0, 0, 255, 255]);
    });

    test('non-overlapping tile returns independent unchanged bytes', () {
      final before = Uint8List(Tile.byteLength)..[3] = 20;

      final result = compositeDebugStrokeTile(
        key: const TileKey(2, 2),
        beforePixels: before,
        strokePixels: Uint8List.fromList(<int>[0, 0, 0, 255]),
        strokeOriginX: 0,
        strokeOriginY: 0,
        strokeWidth: 1,
        strokeHeight: 1,
      );

      expect(result.changed, isFalse);
      expect(result.pixels, orderedEquals(before));
      expect(identical(result.pixels, before), isFalse);
    });

    test('transparent stroke does not report a change', () {
      final result = compositeDebugStrokeTile(
        key: const TileKey(0, 0),
        beforePixels: Uint8List(Tile.byteLength),
        strokePixels: Uint8List(4),
        strokeOriginX: 0,
        strokeOriginY: 0,
        strokeWidth: 1,
        strokeHeight: 1,
      );

      expect(result.changed, isFalse);
    });

    test('invalid byte lengths are rejected at the worker boundary', () {
      expect(
        () => compositeDebugStrokeTile(
          key: const TileKey(0, 0),
          beforePixels: Uint8List(4),
          strokePixels: Uint8List(4),
          strokeOriginX: 0,
          strokeOriginY: 0,
          strokeWidth: 1,
          strokeHeight: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RasterWorker', () {
    test(
      'long-lived isolate returns COW changes and identity before refs',
      () async {
        final worker = await RasterWorker.start();
        final beforePixels = Uint8List(Tile.byteLength)
          ..[0] = 3
          ..[3] = 255;
        final beforeTile = Tile.takeOwnership(beforePixels);
        final store = TileStore()
          ..publish('layer', const TileKey(0, 0), beforeTile);
        final buffer = StrokeBuffer(documentSize: const Size(512, 256))
          ..stampRound(center: const Offset(255, 50), diameter: 12);

        try {
          final result = await worker.compositeDebugStroke(
            stroke: buffer.seal(),
            tiles: store,
            layerId: 'layer',
            documentSize: const Size(512, 256),
          );

          expect(result.changedTiles.keys.toSet(), <TileKey>{
            const TileKey(0, 0),
            const TileKey(1, 0),
          });
          expect(
            identical(result.beforeTiles[const TileKey(0, 0)], beforeTile),
            isTrue,
          );
          expect(result.beforeTiles[const TileKey(1, 0)], isNull);
          expect(
            identical(store.tile('layer', const TileKey(0, 0)), beforeTile),
            isTrue,
          );
          expect(store.tile('layer', const TileKey(1, 0)), isNull);

          final leftOffset = (50 * Tile.edge + 255) * 4 + 3;
          final rightOffset = 50 * Tile.edge * 4 + 3;
          expect(
            result.changedTiles[const TileKey(0, 0)]!.pixels[leftOffset],
            greaterThan(0),
          );
          expect(
            result.changedTiles[const TileKey(1, 0)]!.pixels[rightOffset],
            greaterThan(0),
          );

          final cachePixels = await worker.compositeVisibleTiles(
            keys: <TileKey>[for (var x = 0; x < 9; x += 1) TileKey(x, 0)],
            document: InkDocument.blank(id: 'worker', nowMs: 1).copyWith(
              layers: <InkLayer>[InkLayer(id: 'layer', name: 'Layer')],
              activeLayerId: 'layer',
            ),
            tiles: store,
          );
          expect(cachePixels, hasLength(9));
          expect(cachePixels[const TileKey(0, 0)]!.sublist(0, 4), <int>[
            3,
            0,
            0,
            255,
          ]);
          expect(cachePixels[const TileKey(8, 0)], everyElement(0));
        } finally {
          await worker.dispose();
        }

        await expectLater(
          worker.compositeDebugStroke(
            stroke: StrokeBuffer().snapshot(),
            tiles: store,
            layerId: 'layer',
            documentSize: const Size(512, 256),
          ),
          throwsStateError,
        );
      },
    );

    test('empty stroke is a publish-neutral result', () async {
      final worker = await RasterWorker.start();
      try {
        final result = await worker.compositeDebugStroke(
          stroke: StrokeBuffer().snapshot(),
          tiles: TileStore(),
          layerId: 'layer',
          documentSize: const Size(256, 256),
        );

        expect(result.isEmpty, isTrue);
        expect(result.beforeTiles, isEmpty);
      } finally {
        await worker.dispose();
      }
    });
  });
}
