import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/compositor.dart';

void main() {
  group('two-phase stroke preview', () {
    test('cutoff comparison is inclusive and produces opaque black', () {
      final Uint8List source = Uint8List.fromList(<int>[
        12,
        34,
        56,
        127,
        12,
        34,
        56,
        128,
      ]);

      expect(
        thresholdStrokePixels(source, alphaCutoff: 0.5),
        orderedEquals(<int>[0, 0, 0, 0, 0, 0, 0, 255]),
      );
    });

    test('clear preview emits opaque white without mutating truth', () {
      final Uint8List source = Uint8List.fromList(<int>[30, 20, 10, 200]);

      final Uint8List preview = thresholdStrokePixels(
        source,
        alphaCutoff: 0.5,
        previewColorArgb: 0xffffffff,
      );

      expect(preview, orderedEquals(<int>[255, 255, 255, 255]));
      expect(source, orderedEquals(<int>[30, 20, 10, 200]));
    });

    test('zero cutoff never turns transparent scratch pixels opaque', () {
      expect(
        thresholdStrokePixels(Uint8List(4), alphaCutoff: 0),
        orderedEquals(<int>[0, 0, 0, 0]),
      );
    });

    test('changed-region extraction uses the selected preview color', () {
      final StrokeBuffer buffer = StrokeBuffer()
        ..stampRound(
          center: const Offset(5, 5),
          diameter: 4,
          colorArgb: 0xff123456,
        );

      final ThresholdedStrokeRegion region = buffer.thresholdedRegion(
        buffer.inkBounds,
        alphaCutoff: 0.1,
        previewColorArgb: 0xffffffff,
      );

      final int opaqueOffset = _firstOpaqueOffset(region.pixels);
      expect(opaqueOffset, greaterThanOrEqualTo(0));
      expect(
        region.pixels.sublist(opaqueOffset, opaqueOffset + 4),
        orderedEquals(<int>[255, 255, 255, 255]),
      );
    });

    test('overlay configuration carries cutoff, color, and outline style', () {
      final StrokeOverlay overlay = StrokeOverlay();

      overlay.configure(
        alphaCutoff: 0.35,
        previewColorArgb: 0xffffffff,
        outline: true,
      );

      expect(overlay.alphaCutoff, 0.35);
      expect(overlay.previewColorArgb, 0xffffffff);
      expect(overlay.drawsOutline, isTrue);
      overlay.dispose();
      expect(overlay.bounds, Rect.zero);
    });
  });

  group('generic stroke-buffer stamps', () {
    test('ellipse allocation and damage are deterministic', () {
      StrokeBuffer render() => StrokeBuffer()
        ..stampEllipse(
          center: const Offset(20, 30),
          diameterX: 12,
          diameterY: 4,
          angleRadians: 0.4,
          colorArgb: 0xff315a7d,
          flow: 0.7,
        );

      final StrokeBuffer first = render();
      final StrokeBuffer second = render();

      expect(first.inkBounds, second.inkBounds);
      expect(first.snapshot().pixels, orderedEquals(second.snapshot().pixels));
    });

    test('disc bounds and pixels are rotation invariant', () {
      StrokeBuffer render(double angle) => StrokeBuffer()
        ..stampEllipse(
          center: const Offset(20, 30),
          diameterX: 12,
          diameterY: 12,
          angleRadians: angle,
        );

      final StrokeBuffer unrotated = render(0);
      final StrokeBuffer rotated = render(0.7853981633974483);

      expect(unrotated.inkBounds, const Rect.fromLTWH(13.5, 23.5, 13, 13));
      expect(rotated.inkBounds, unrotated.inkBounds);
      expect(
        rotated.snapshot().pixels,
        orderedEquals(unrotated.snapshot().pixels),
      );
    });

    test('coverage modifier controls settle-form alpha', () {
      final StrokeBuffer full = StrokeBuffer()
        ..stampEllipse(center: const Offset(8, 8), diameterX: 8, diameterY: 8);
      final StrokeBuffer half = StrokeBuffer()
        ..stampEllipse(
          center: const Offset(8, 8),
          diameterX: 8,
          diameterY: 8,
          modifyCoverage: (int x, int y, double coverage) => coverage * 0.5,
        );

      expect(
        _maximumAlpha(half.snapshot().pixels),
        lessThan(_maximumAlpha(full.snapshot().pixels)),
      );
    });

    test('sealed buffers reject generic stamps', () {
      final StrokeBuffer buffer = StrokeBuffer()
        ..stampEllipse(center: const Offset(8, 8), diameterX: 4, diameterY: 4);
      buffer.seal();

      expect(
        () => buffer.stampEllipse(
          center: const Offset(10, 10),
          diameterX: 4,
          diameterY: 4,
        ),
        throwsStateError,
      );
    });

    test('final quantization bounds the nontransparent alpha lattice', () {
      final StrokeBuffer buffer = StrokeBuffer();
      for (var index = 1; index <= 9; index += 1) {
        buffer.stampEllipse(
          center: Offset(index * 10, 10),
          diameterX: 6,
          diameterY: 6,
          flow: index / 10,
        );
      }

      buffer.quantizeAlphaLevels(4);

      final Set<int> alphas = <int>{
        for (var offset = 3; offset < buffer.pixels.length; offset += 4)
          if (buffer.pixels[offset] != 0) buffer.pixels[offset],
      };
      expect(alphas.length, lessThanOrEqualTo(4));
    });
  });

  group('hover cursor damage', () {
    test('ring follows brush diameter and unions old and new bounds', () {
      final BrushHoverCursor cursor = BrushHoverCursor();
      final Rect firstDamage = cursor.update(
        center: const Offset(20, 20),
        diameter: 10,
        viewScale: 2,
      );
      final Rect firstBounds = cursor.bounds;
      final Rect moveDamage = cursor.update(
        center: const Offset(40, 20),
        diameter: 16,
        viewScale: 2,
      );

      expect(cursor.diameter, 16);
      expect(cursor.strokeWidth, 0.5);
      expect(firstDamage, firstBounds);
      expect(moveDamage.contains(firstBounds.center), isTrue);
      expect(moveDamage.contains(cursor.bounds.center), isTrue);
      final Rect secondBounds = cursor.bounds;
      expect(cursor.hide(), secondBounds);
      expect(cursor.isVisible, isFalse);
    });
  });
}

int _firstOpaqueOffset(Uint8List pixels) {
  for (var offset = 0; offset < pixels.length; offset += 4) {
    if (pixels[offset + 3] != 0) {
      return offset;
    }
  }
  return -1;
}

int _maximumAlpha(Uint8List pixels) {
  var maximum = 0;
  for (var offset = 3; offset < pixels.length; offset += 4) {
    if (pixels[offset] > maximum) {
      maximum = pixels[offset];
    }
  }
  return maximum;
}
