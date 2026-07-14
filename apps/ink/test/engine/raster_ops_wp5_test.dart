import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/raster_ops.dart';
import 'package:paper_ink/src/engine/selection_mask.dart';

void main() {
  group('RgbaBitmap', () {
    test('validates RGBA shape and premultiplication', () {
      expect(
        () => RgbaBitmap.fromPremultipliedRgba(
          width: 2,
          height: 1,
          pixels: Uint8List(7),
        ),
        throwsArgumentError,
      );
      expect(
        () => RgbaBitmap.fromPremultipliedRgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList(<int>[200, 0, 0, 100]),
        ),
        throwsArgumentError,
      );
    });

    test('defensively copies premultiplied bytes', () {
      final bytes = Uint8List.fromList(<int>[40, 20, 0, 80]);
      final bitmap = RgbaBitmap.fromPremultipliedRgba(
        width: 1,
        height: 1,
        pixels: bytes,
      );
      bytes.fillRange(0, bytes.length, 0);

      expect(bitmap.pixels, <int>[40, 20, 0, 80]);
      expect(() => bitmap.pixels[0] = 0, throwsUnsupportedError);
    });

    test('straight colors round-trip through premultiplied storage', () {
      final color = RgbaColor(red: 255, green: 128, blue: 0, alpha: 128);
      final bitmap = RgbaBitmap.solid(width: 1, height: 1, color: color);

      expect(bitmap.pixels, <int>[128, 64, 0, 128]);
      expect(bitmap.colorAt(0, 0), color);
      expect(bitmap.channelAt(0, 0, 3), 128);
    });

    test('color channels and coordinates are range checked', () {
      expect(() => RgbaColor(red: 256, green: 0, blue: 0), throwsRangeError);
      final bitmap = RgbaBitmap.transparent(width: 2, height: 2);
      expect(() => bitmap.colorAt(2, 0), throwsRangeError);
      expect(() => bitmap.channelAt(0, 0, 4), throwsRangeError);
    });
  });

  group('wand and flood region', () {
    test('selects only the contiguous exact-color component', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        <RgbaColor>[_white, _white, _black, _white],
        <RgbaColor>[_white, _black, _black, _white],
        <RgbaColor>[_white, _white, _black, _white],
      ]);
      final region = wandRegion(source: bitmap, seedX: 0, seedY: 0);

      expect(region.contains(0, 2), isTrue);
      expect(region.contains(3, 0), isFalse);
      expect(region.contains(2, 0), isFalse);
    });

    test('uses four-way connectivity rather than diagonal leakage', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        <RgbaColor>[_white, _black],
        <RgbaColor>[_black, _white],
      ]);
      final region = wandRegion(source: bitmap, seedX: 0, seedY: 0);

      expect(region.contains(0, 0), isTrue);
      expect(region.contains(1, 1), isFalse);
    });

    test('tolerance is RMS straight-RGB channel distance', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        <RgbaColor>[
          RgbaColor(red: 100, green: 0, blue: 0),
          RgbaColor(red: 200, green: 0, blue: 0),
        ],
      ]);

      expect(
        wandRegion(
          source: bitmap,
          seedX: 0,
          seedY: 0,
          tolerance: 58,
        ).contains(1, 0),
        isTrue,
      );
      expect(
        wandRegion(
          source: bitmap,
          seedX: 0,
          seedY: 0,
          tolerance: 57,
        ).contains(1, 0),
        isFalse,
      );
    });

    test('RGB tolerance deliberately ignores alpha differences', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        <RgbaColor>[
          RgbaColor(red: 100, green: 80, blue: 60),
          RgbaColor(red: 100, green: 80, blue: 60, alpha: 128),
        ],
      ]);

      final region = wandRegion(
        source: bitmap,
        seedX: 0,
        seedY: 0,
        tolerance: 0,
      );

      expect(region.contains(1, 0), isTrue);
    });

    test('gap close seals a one-pixel break in a boundary', () {
      final rows = <List<RgbaColor>>[
        for (var y = 0; y < 7; y += 1)
          <RgbaColor>[
            for (var x = 0; x < 9; x += 1)
              if (x == 4 && y != 3) _black else _white,
          ],
      ];
      final bitmap = _bitmap(rows);

      expect(
        wandRegion(source: bitmap, seedX: 1, seedY: 3).contains(7, 3),
        isTrue,
      );
      expect(
        wandRegion(
          source: bitmap,
          seedX: 1,
          seedY: 3,
          gapClose: 1,
        ).contains(7, 3),
        isFalse,
      );
    });

    test('positive grow expands the flooded region', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        for (var y = 0; y < 5; y += 1)
          <RgbaColor>[
            for (var x = 0; x < 5; x += 1)
              if (x == 2 && y == 2) _red else _black,
          ],
      ]);
      final region = wandRegion(source: bitmap, seedX: 2, seedY: 2, grow: 1);

      expect(region.coverage.where((value) => value != 0), hasLength(9));
    });

    test('negative grow contracts the flooded region', () {
      final bitmap = _bitmap(<List<RgbaColor>>[
        for (var y = 0; y < 5; y += 1)
          <RgbaColor>[
            for (var x = 0; x < 5; x += 1)
              if (x >= 1 && x <= 3 && y >= 1 && y <= 3) _red else _black,
          ],
      ]);
      final region = wandRegion(source: bitmap, seedX: 2, seedY: 2, grow: -1);

      expect(region.coverage.where((value) => value != 0), hasLength(1));
      expect(region.contains(2, 2), isTrue);
    });

    test('rejects out-of-contract tolerance, gap, and growth', () {
      final bitmap = RgbaBitmap.solid(width: 1, height: 1, color: _white);

      expect(
        () => wandRegion(source: bitmap, seedX: 0, seedY: 0, tolerance: 65),
        throwsRangeError,
      );
      expect(
        () => wandRegion(source: bitmap, seedX: 0, seedY: 0, gapClose: 5),
        throwsRangeError,
      );
      expect(
        () => wandRegion(source: bitmap, seedX: 0, seedY: 0, grow: -5),
        throwsRangeError,
      );
    });
  });

  group('fill patterns and selection clip', () {
    test('solid fill is clipped to the active selection', () {
      final source = RgbaBitmap.transparent(width: 3, height: 1);
      final clip = SelectionMask.fromBools(
        width: 3,
        height: 1,
        selected: const <bool>[false, true, false],
      );
      final result = applyRasterFill(
        source: source,
        region: SelectionMask.full(width: 3, height: 1),
        fill: SolidRasterFill(_red),
        clip: clip,
      );

      expect(result.colorAt(0, 0), RgbaColor.transparent);
      expect(result.colorAt(1, 0), _red);
      expect(result.colorAt(2, 0), RgbaColor.transparent);
    });

    test('partial mask coverage source-overs premultiplied color', () {
      final source = RgbaBitmap.solid(width: 1, height: 1, color: _blue);
      final result = applyRasterFill(
        source: source,
        region: SelectionMask(
          width: 1,
          height: 1,
          coverage: Uint8List.fromList(<int>[128]),
        ),
        fill: SolidRasterFill(_red),
      );

      expect(result.pixels, <int>[128, 0, 127, 255]);
    });

    test('hatch fill leaves deterministic transparent-backed holes', () {
      final source = RgbaBitmap.transparent(width: 4, height: 4);
      final result = applyRasterFill(
        source: source,
        region: SelectionMask.full(width: 4, height: 4),
        fill: HatchRasterFill(color: _black, spacing: 2),
      );

      expect(
        <int>[
          for (var y = 0; y < 4; y += 1)
            for (var x = 0; x < 4; x += 1) result.channelAt(x, y, 3),
        ].where((alpha) => alpha == 255),
        hasLength(8),
      );
      expect(result.channelAt(0, 0, 3), 255);
      expect(result.channelAt(1, 0, 3), 0);
    });

    test('Bayer-4 dot screen honors exact half density', () {
      final result = applyRasterFill(
        source: RgbaBitmap.transparent(width: 4, height: 4),
        region: SelectionMask.full(width: 4, height: 4),
        fill: DotScreenRasterFill(color: _black, density: 0.5),
      );

      expect(
        <int>[
          for (var y = 0; y < 4; y += 1)
            for (var x = 0; x < 4; x += 1) result.channelAt(x, y, 3),
        ].where((alpha) => alpha != 0),
        hasLength(8),
      );
    });

    test('zero and full dot densities produce empty and solid patterns', () {
      final zero = DotScreenRasterFill(color: _black, density: 0);
      final full = DotScreenRasterFill(
        color: _black,
        density: 1,
        matrix: DotScreenMatrix.bayer8,
      );

      expect(zero.coverageAt(0, 0), 0);
      expect(full.coverageAt(7, 7), 255);
    });

    test('flood can sample composite while writing the active target', () {
      final target = RgbaBitmap.transparent(width: 3, height: 1);
      final composite = _bitmap(<List<RgbaColor>>[
        <RgbaColor>[_white, _white, _black],
      ]);
      final result = floodFill(
        target: target,
        sampleSource: composite,
        seedX: 0,
        seedY: 0,
        fill: SolidRasterFill(_green),
      );

      expect(result.colorAt(0, 0), _green);
      expect(result.colorAt(1, 0), _green);
      expect(result.colorAt(2, 0), RgbaColor.transparent);
    });

    test('fill keeps its source bitmap immutable', () {
      final source = RgbaBitmap.solid(width: 2, height: 1, color: _white);
      floodFill(
        target: source,
        seedX: 0,
        seedY: 0,
        fill: SolidRasterFill(_black),
      );

      expect(source.colorAt(0, 0), _white);
      expect(source.colorAt(1, 0), _white);
    });
  });
}

RgbaBitmap _bitmap(List<List<RgbaColor>> rows) => RgbaBitmap.fromColors(
  width: rows.first.length,
  height: rows.length,
  colors: <RgbaColor>[for (final row in rows) ...row],
);

final RgbaColor _white = RgbaColor(red: 255, green: 255, blue: 255);
final RgbaColor _black = RgbaColor(red: 0, green: 0, blue: 0);
final RgbaColor _red = RgbaColor(red: 255, green: 0, blue: 0);
final RgbaColor _green = RgbaColor(red: 0, green: 255, blue: 0);
final RgbaColor _blue = RgbaColor(red: 0, green: 0, blue: 255);
