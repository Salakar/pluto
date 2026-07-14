import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  group('TileKey', () {
    test('file names round-trip signed coordinates', () {
      const key = TileKey(-12, 34);

      expect(key.fileName, '-12_34.tile');
      expect(TileKey.fromFileName(key.fileName), key);
      expect(TileKey.tryFromFileName('0_0.tile'), const TileKey(0, 0));
    });

    test('invalid file names are rejected without accepting paths', () {
      for (final value in [
        '1_2',
        '1-2.tile',
        '1_2.png',
        '../1_2.tile',
        '1_2.tile.tmp',
      ]) {
        expect(TileKey.tryFromFileName(value), isNull, reason: value);
        expect(
          () => TileKey.fromFileName(value),
          throwsA(isA<FormatException>()),
          reason: value,
        );
      }
    });

    test('keys and locations sort deterministically', () {
      final keys = [
        const TileKey(2, 0),
        const TileKey(-1, 4),
        const TileKey(2, -1),
        const TileKey(-1, 3),
      ]..sort();
      final locations = [
        const TileLocation(layerId: 'z', key: TileKey(0, 0)),
        const TileLocation(layerId: 'a', key: TileKey(3, 0)),
        const TileLocation(layerId: 'a', key: TileKey(2, 8)),
      ]..sort();

      expect(keys, [
        const TileKey(-1, 3),
        const TileKey(-1, 4),
        const TileKey(2, -1),
        const TileKey(2, 0),
      ]);
      expect(locations.map((location) => location.toString()), [
        'TileLocation(a, TileKey(2, 8))',
        'TileLocation(a, TileKey(3, 0))',
        'TileLocation(z, TileKey(0, 0))',
      ]);
    });
  });

  group('Tile', () {
    test('requires exactly 256 by 256 RGBA8888 bytes', () {
      expect(Tile.edge, 256);
      expect(Tile.bytesPerPixel, 4);
      expect(Tile.byteLength, 256 * 256 * 4);
      expect(() => Tile(Uint8List(Tile.byteLength - 1)), throwsArgumentError);
      expect(() => Tile(Uint8List(Tile.byteLength + 1)), throwsArgumentError);
    });

    test('default construction copies source and publishes immutable view', () {
      final source = Uint8List(Tile.byteLength)
        ..[0] = 8
        ..[3] = 255;
      final tile = Tile(source);
      source[0] = 99;

      expect(tile.pixels[0], 8);
      expect(tile.pixels[3], 255);
      expect(() => tile.pixels[0] = 5, throwsUnsupportedError);
    });

    test('mutableCopy is independent COW input', () {
      final tile = _tile(17);
      final next = tile.mutableCopy()..[0] = 23;

      expect(tile.pixels[0], 17);
      expect(next[0], 23);
      expect(identical(tile.pixels, next), isFalse);
    });

    test('transparency checks alpha rather than RGB payload', () {
      final hiddenRgb = Uint8List(Tile.byteLength)
        ..[0] = 255
        ..[1] = 100
        ..[2] = 50;
      final visible = Uint8List.fromList(hiddenRgb)..[3] = 1;

      expect(Tile.takeOwnership(hiddenRgb).isTransparent, isTrue);
      expect(Tile.takeOwnership(visible).isTransparent, isFalse);
    });
  });

  group('TileStore', () {
    test('is sparse and treats absent coordinates as transparent', () {
      final store = TileStore();

      expect(store.tile('missing', const TileKey(9, 9)), isNull);
      expect(store.occupiedKeys('missing'), isEmpty);
      expect(store.tileCount, 0);
      expect(store.bytesHeld, 0);
      expect(store.layerIds, isEmpty);
      store.verifyInvariants();
    });

    test('COW publish returns before-ref and does not mutate old pixels', () {
      final store = TileStore();
      const key = TileKey(1, 2);
      final first = _tile(10);
      final changedPixels = first.mutableCopy()..[0] = 20;
      final second = Tile.takeOwnership(changedPixels);

      expect(store.publish('layer', key, first), isNull);
      final before = store.publish('layer', key, second);

      expect(identical(before, first), isTrue);
      expect(identical(store.tile('layer', key), second), isTrue);
      expect(first.pixels[0], 10);
      expect(second.pixels[0], 20);
      store.verifyInvariants();
    });

    test('publishAll returns null and non-null before refs atomically', () {
      final changes = <TileStoreMemoryUsage>[];
      final store = TileStore(onMemoryChanged: changes.add);
      const existingKey = TileKey(0, 0);
      const newKey = TileKey(1, 0);
      final existing = _tile(1);
      final replacement = _tile(2);
      final added = _tile(3);
      store.publish('layer', existingKey, existing);
      changes.clear();

      final before = store.publishAll('layer', {
        existingKey: replacement,
        newKey: added,
      });

      expect(identical(before[existingKey], existing), isTrue);
      expect(before[newKey], isNull);
      expect(changes, hasLength(1));
      expect(changes.single.tileCount, 2);
      expect(store.tileCount, 2);
      store.verifyInvariants();
    });

    test('occupied keys are sorted immutable snapshots', () {
      final store = TileStore()
        ..publish('layer', const TileKey(3, 1), _tile(1))
        ..publish('layer', const TileKey(0, 4), _tile(2))
        ..publish('layer', const TileKey(0, 2), _tile(3));

      final keys = store.occupiedKeys('layer');
      store.publish('layer', const TileKey(-1, 0), _tile(4));

      expect(keys, [
        const TileKey(0, 2),
        const TileKey(0, 4),
        const TileKey(3, 1),
      ]);
      expect(keys, isNot(contains(const TileKey(-1, 0))));
      expect(
        () => (keys as List<TileKey>).add(const TileKey(9, 9)),
        throwsUnsupportedError,
      );
    });

    test('memory accounting counts shared tile buffers only once', () {
      final store = TileStore();
      final shared = _tile(7);
      store
        ..publish('a', const TileKey(0, 0), shared)
        ..publish('a', const TileKey(1, 0), shared)
        ..publish('b', const TileKey(0, 0), shared);

      expect(store.tileCount, 3);
      expect(store.uniqueTileCount, 1);
      expect(store.bytesHeld, Tile.byteLength);
      expect(store.bytesHeldForLayer('a'), Tile.byteLength * 2);
      expect(
        store.memoryUsage,
        TileStoreMemoryUsage(
          layerCount: 2,
          tileCount: 3,
          uniqueTileCount: 1,
          bytesHeld: Tile.byteLength,
        ),
      );
      store.verifyInvariants();
    });

    test('removing one shared reference keeps bytes until its final use', () {
      final store = TileStore();
      final shared = _tile(7);
      store
        ..publish('a', const TileKey(0, 0), shared)
        ..publish('b', const TileKey(0, 0), shared);

      expect(identical(store.remove('a', const TileKey(0, 0)), shared), isTrue);
      expect(store.bytesHeld, Tile.byteLength);
      store.remove('b', const TileKey(0, 0));
      expect(store.bytesHeld, 0);
      store.verifyInvariants();
    });

    test('replace, clear, and remove layer return immutable before maps', () {
      final store = TileStore()
        ..publish('layer', const TileKey(0, 0), _tile(1));
      final replacement = _tile(2);

      final beforeReplace = store.replaceLayer('layer', {
        const TileKey(2, 2): replacement,
      });
      expect(beforeReplace.keys, [const TileKey(0, 0)]);
      expect(() => beforeReplace.clear(), throwsUnsupportedError);
      final beforeClear = store.clearLayer('layer');
      expect(identical(beforeClear[const TileKey(2, 2)], replacement), isTrue);
      expect(store.containsLayer('layer'), isTrue);
      expect(store.occupiedKeys('layer'), isEmpty);
      expect(store.removeLayer('layer'), isEmpty);
      expect(store.containsLayer('layer'), isFalse);
      store.verifyInvariants();
    });

    test('fork has independent maps while sharing immutable tile refs', () {
      final original = TileStore();
      final shared = _tile(8);
      original.publish('layer', const TileKey(0, 0), shared);

      final fork = original.fork();

      expect(
        identical(fork.tile('layer', const TileKey(0, 0)), shared),
        isTrue,
      );
      fork.publish('layer', const TileKey(1, 0), _tile(9));
      original.remove('layer', const TileKey(0, 0));
      expect(original.tileCount, 0);
      expect(fork.tileCount, 2);
      expect(fork.tile('layer', const TileKey(0, 0))?.pixels[0], 8);
      original.verifyInvariants();
      fork.verifyInvariants();
    });

    test('explicit eviction removes only requested occupied locations', () {
      final store = TileStore()
        ..publish('b', const TileKey(0, 0), _tile(1))
        ..publish('a', const TileKey(2, 0), _tile(2))
        ..publish('a', const TileKey(1, 0), _tile(3));
      expect(store.locations.map((location) => location.toString()), [
        'TileLocation(a, TileKey(1, 0))',
        'TileLocation(a, TileKey(2, 0))',
        'TileLocation(b, TileKey(0, 0))',
      ]);

      final evicted = store.evictAll(const [
        TileLocation(layerId: 'a', key: TileKey(1, 0)),
        TileLocation(layerId: 'missing', key: TileKey(9, 9)),
      ]);

      expect(evicted.keys, [
        const TileLocation(layerId: 'a', key: TileKey(1, 0)),
      ]);
      expect(store.tileCount, 2);
      expect(store.tile('a', const TileKey(2, 0)), isNotNull);
      expect(store.tile('b', const TileKey(0, 0)), isNotNull);
      store.verifyInvariants();
    });

    test('memory hook ignores identical republish and absent eviction', () {
      final usages = <TileStoreMemoryUsage>[];
      final store = TileStore(onMemoryChanged: usages.add);
      final tile = _tile(1);
      store.publish('layer', const TileKey(0, 0), tile);
      usages.clear();

      expect(
        identical(store.publish('layer', const TileKey(0, 0), tile), tile),
        isTrue,
      );
      expect(store.evict('layer', const TileKey(9, 9)), isNull);
      expect(usages, isEmpty);
    });

    test('ensureLayer and clear account for empty represented layers', () {
      final usages = <TileStoreMemoryUsage>[];
      final store = TileStore(onMemoryChanged: usages.add);

      expect(store.ensureLayer('empty'), isTrue);
      expect(store.ensureLayer('empty'), isFalse);
      expect(store.layerIds, ['empty']);
      expect(store.memoryUsage.layerCount, 1);
      expect(usages, hasLength(1));

      store.clear();
      expect(store.layerIds, isEmpty);
      expect(store.memoryUsage.layerCount, 0);
      expect(usages, hasLength(2));
      store.verifyInvariants();
    });
  });
}

Tile _tile(int marker) {
  final pixels = Uint8List(Tile.byteLength)
    ..[0] = marker
    ..[3] = 255;
  return Tile.takeOwnership(pixels);
}
