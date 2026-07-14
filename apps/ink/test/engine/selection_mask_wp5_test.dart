import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/selection_mask.dart';

void main() {
  group('SelectionMask validation and combination', () {
    test('rejects non-positive and mismatched dimensions', () {
      expect(
        () => SelectionMask(width: 0, height: 1, coverage: Uint8List(0)),
        throwsRangeError,
      );
      expect(
        () => SelectionMask(width: 2, height: 2, coverage: Uint8List(3)),
        throwsArgumentError,
      );
    });

    test('defensively copies input and exposes a read-only view', () {
      final bytes = Uint8List.fromList(<int>[255, 0]);
      final mask = SelectionMask(width: 2, height: 1, coverage: bytes);
      bytes[0] = 0;

      expect(mask.coverageAt(0, 0), 255);
      expect(() => mask.coverage[0] = 0, throwsUnsupportedError);
    });

    test('empty and full factories report their state', () {
      expect(SelectionMask.empty(width: 2, height: 2).isEmpty, isTrue);
      expect(SelectionMask.full(width: 2, height: 2).isNotEmpty, isTrue);
      expect(
        SelectionMask.full(width: 2, height: 2).coverage,
        everyElement(255),
      );
    });

    test('add takes maximum partial coverage', () {
      final current = _mask(<int>[0, 60, 220]);
      final incoming = _mask(<int>[20, 180, 40]);

      expect(
        current.combine(incoming, SelectionMaskOperation.add).coverage,
        <int>[20, 180, 220],
      );
    });

    test('subtract clamps incoming coverage at zero', () {
      final current = _mask(<int>[10, 100, 220]);
      final incoming = _mask(<int>[20, 40, 220]);

      expect(
        current.combine(incoming, SelectionMaskOperation.subtract).coverage,
        <int>[0, 60, 0],
      );
    });

    test('intersect takes minimum partial coverage', () {
      final current = _mask(<int>[10, 100, 220]);
      final incoming = _mask(<int>[20, 40, 220]);

      expect(
        current.combine(incoming, SelectionMaskOperation.intersect).coverage,
        <int>[10, 40, 220],
      );
    });

    test('replace returns an independent incoming mask copy', () {
      final incoming = _mask(<int>[10, 20]);
      final result = _mask(<int>[
        255,
        255,
      ]).combine(incoming, SelectionMaskOperation.replace);

      expect(result.coverage, <int>[10, 20]);
      expect(identical(result.coverage, incoming.coverage), isFalse);
    });

    test('combination rejects different dimensions', () {
      expect(
        () => _mask(<int>[255, 0]).combine(
          SelectionMask.full(width: 1, height: 2),
          SelectionMaskOperation.add,
        ),
        throwsArgumentError,
      );
    });
  });

  group('SelectionMask morphology', () {
    test('grow by one uses a square pixel neighborhood', () {
      final center = SelectionMask.fromBools(
        width: 5,
        height: 5,
        selected: <bool>[
          for (var index = 0; index < 25; index += 1) index == 12,
        ],
      );
      final grown = center.growOrContract(1);

      expect(grown.coverage.where((value) => value != 0), hasLength(9));
      expect(grown.contains(1, 1), isTrue);
      expect(grown.contains(3, 3), isTrue);
      expect(grown.contains(0, 0), isFalse);
    });

    test('contract by one removes a full mask border', () {
      final contracted = SelectionMask.full(
        width: 5,
        height: 5,
      ).growOrContract(-1);

      expect(contracted.coverage.where((value) => value != 0), hasLength(9));
      expect(contracted.contains(2, 2), isTrue);
      expect(contracted.contains(0, 2), isFalse);
    });

    test('morphological close seals a one-pixel line gap', () {
      final line = SelectionMask.fromBools(
        width: 7,
        height: 5,
        selected: <bool>[
          for (var y = 0; y < 5; y += 1)
            for (var x = 0; x < 7; x += 1) x == 3 && y != 2,
        ],
      );
      final closed = line.closeGaps(1, outsideCoverage: 255);

      expect(closed.contains(3, 2), isTrue);
      expect(closed.contains(2, 2), isFalse);
      expect(closed.contains(4, 2), isFalse);
    });

    test('morphological close preserves a mask touching canvas edges', () {
      final closed = SelectionMask.full(width: 3, height: 3).closeGaps(1);

      expect(closed.coverage, everyElement(255));
    });

    test('morphology rejects adjustments beyond four pixels', () {
      final mask = SelectionMask.full(width: 2, height: 2);

      expect(() => mask.growOrContract(5), throwsRangeError);
      expect(() => mask.growOrContract(-5), throwsRangeError);
      expect(() => mask.closeGaps(5), throwsRangeError);
    });
  });

  group('SelectionMask clipping', () {
    test('clips byte coverage with rounded multiplication', () {
      final mask = _mask(<int>[255, 128, 0]);

      expect(mask.clipCoverage(Uint8List.fromList(<int>[100, 101, 255])), <int>[
        100,
        51,
        0,
      ]);
    });

    test('clips every premultiplied RGBA channel', () {
      final mask = _mask(<int>[128, 0]);
      final clipped = mask.clipPremultipliedRgba(
        Uint8List.fromList(<int>[100, 80, 60, 120, 1, 2, 3, 4]),
      );

      expect(clipped, <int>[50, 40, 30, 60, 0, 0, 0, 0]);
    });

    test('clip operations reject mismatched payload lengths', () {
      final mask = SelectionMask.full(width: 2, height: 2);

      expect(() => mask.clipCoverage(Uint8List(3)), throwsArgumentError);
      expect(
        () => mask.clipPremultipliedRgba(Uint8List(15)),
        throwsArgumentError,
      );
    });
  });
}

SelectionMask _mask(List<int> coverage) => SelectionMask(
  width: coverage.length,
  height: 1,
  coverage: Uint8List.fromList(coverage),
);
