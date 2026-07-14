import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document_io.dart';
import 'package:paper_ink/src/document/tile_store.dart';

void main() {
  group('InkTileCodec header', () {
    test('uses the exact 16-byte INKT v1 rgba8888 header', () {
      final encoded = InkTileCodec.encodePixels(
        Uint8List(2 * 3 * 4),
        width: 2,
        height: 3,
      );

      expect(encoded.sublist(0, 16), <int>[
        0x49,
        0x4e,
        0x4b,
        0x54,
        1,
        1,
        0,
        2,
        0,
        3,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
    });

    test('stores dimensions as unsigned big-endian values', () {
      final encoded = InkTileCodec.encodePixels(
        Uint8List(256 * 4),
        width: 1,
        height: 256,
      );

      expect(encoded.sublist(6, 10), <int>[0, 1, 1, 0]);
    });

    test('rejects bad magic', () {
      final encoded = _encoded2x2()..[0] = 0;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects unsupported version', () {
      final encoded = _encoded2x2()..[4] = 2;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects unsupported pixel format', () {
      final encoded = _encoded2x2()..[5] = 2;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects nonzero reserved bytes', () {
      final encoded = _encoded2x2()..[15] = 1;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects a truncated header', () {
      expect(
        () => InkTileCodec.decodePixels(Uint8List(16)),
        throwsFormatException,
      );
    });

    test('rejects zero dimensions before inflating', () {
      final encoded = _encoded2x2()
        ..[6] = 0
        ..[7] = 0;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });
  });

  group('InkTileCodec payload', () {
    test('round-trips a complete 256x256 Tile', () {
      final pixels = Uint8List.fromList(<int>[
        for (var index = 0; index < Tile.byteLength; index += 1)
          (index * 31 + 17) & 0xff,
      ]);
      final decoded = InkTileCodec.decodeTile(
        InkTileCodec.encodeTile(Tile(pixels)),
      );

      expect(decoded.pixels, orderedEquals(pixels));
    });

    test('round-trips 200 seeded random RGBA images', () {
      final random = Random(0x1a2b3c);
      for (var iteration = 0; iteration < 200; iteration += 1) {
        final width = 1 + random.nextInt(32);
        final height = 1 + random.nextInt(32);
        final pixels = Uint8List.fromList(<int>[
          for (var index = 0; index < width * height * 4; index += 1)
            random.nextInt(256),
        ]);

        final decoded = InkTileCodec.decodePixels(
          InkTileCodec.encodePixels(pixels, width: width, height: height),
        );

        expect(decoded.width, width, reason: 'iteration $iteration');
        expect(decoded.height, height, reason: 'iteration $iteration');
        expect(
          decoded.pixels,
          orderedEquals(pixels),
          reason: 'iteration $iteration',
        );
      }
    });

    test('rejects corrupt zlib data', () {
      final encoded = _encoded2x2();
      for (var index = 16; index < encoded.length; index += 1) {
        encoded[index] = 0xff;
      }
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects an inflated byte-count mismatch', () {
      final encoded = _encoded2x2()
        ..[7] = 1
        ..[9] = 1;
      expect(() => InkTileCodec.decodePixels(encoded), throwsFormatException);
    });

    test('rejects a document tile with non-256 dimensions', () {
      expect(
        () => InkTileCodec.decodeTile(_encoded2x2()),
        throwsFormatException,
      );
    });

    test('rejects an encode buffer with the wrong byte count', () {
      expect(
        () => InkTileCodec.encodePixels(Uint8List(15), width: 2, height: 2),
        throwsArgumentError,
      );
    });

    test('bounds decoded images to a single tile pixel count', () {
      expect(
        () => InkTileCodec.encodePixels(Uint8List(1), width: 257, height: 256),
        throwsArgumentError,
      );
    });
  });
}

Uint8List _encoded2x2() => InkTileCodec.encodePixels(
  Uint8List.fromList(<int>[
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
  ]),
  width: 2,
  height: 2,
);
