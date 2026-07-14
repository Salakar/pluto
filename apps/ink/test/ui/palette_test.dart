import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/palette.dart';

void main() {
  group('WP6 palette data', () {
    test('native hero row is K W C M Y R G B in renderer colors', () {
      expect(
        inkNativeSwatches.map((InkPaletteSwatch swatch) => swatch.label),
        <String>['K', 'W', 'C', 'M', 'Y', 'R', 'G', 'B'],
      );
      expect(
        inkNativeSwatches.map((InkPaletteSwatch swatch) => swatch.argb),
        Gallery3NativeState.values.map(
          (Gallery3NativeState state) => state.argb,
        ),
      );
    });

    test('authored identities preserve the binding prose order', () {
      expect(
        inkDevelopsWellAuthoredSwatches.map(
          (InkPaletteSwatch swatch) => swatch.hex,
        ),
        <String>[
          '#000000',
          '#95897D',
          '#C9BFB3',
          '#F2E9DE',
          '#FFFFFF',
          '#1D3E74',
          '#4A7FC1',
          '#1F6F6A',
          '#2E5D34',
          '#5B8F3E',
          '#6B6A2E',
          '#B08A1E',
          '#C77F2A',
          '#A64B22',
          '#B3261E',
          '#7E1F2B',
          '#5C2A5E',
          '#4B3A8C',
          '#5C4632',
          '#A9895F',
          '#C98D8A',
          '#1A8FA8',
          '#B03A7E',
          '#2B3540',
        ],
      );
    });

    test(
      'production grid is a duplicate-free permutation of authored data',
      () {
        expect(inkDevelopsWellSwatches, hasLength(24));
        expect(
          inkDevelopsWellSwatches
              .map((InkPaletteSwatch swatch) => swatch.id)
              .toSet(),
          inkDevelopsWellAuthoredSwatches
              .map((InkPaletteSwatch swatch) => swatch.id)
              .toSet(),
        );
      },
    );

    test('every horizontal grid neighbor differs by two gray levels', () {
      for (var row = 0; row < 6; row += 1) {
        for (var column = 0; column < 3; column += 1) {
          _expectGraySeparation(row * 4 + column, row * 4 + column + 1);
        }
      }
    });

    test('every vertical grid neighbor differs by two gray levels', () {
      for (var row = 0; row < 5; row += 1) {
        for (var column = 0; column < 4; column += 1) {
          _expectGraySeparation(row * 4 + column, (row + 1) * 4 + column);
        }
      }
    });

    test('every horizontal grid neighbor has a distinct Gallery-3 state', () {
      for (var row = 0; row < 6; row += 1) {
        for (var column = 0; column < 3; column += 1) {
          _expectGallery3Separation(row * 4 + column, row * 4 + column + 1);
        }
      }
    });

    test('every vertical grid neighbor has a distinct Gallery-3 state', () {
      for (var row = 0; row < 5; row += 1) {
        for (var column = 0; column < 4; column += 1) {
          _expectGallery3Separation(row * 4 + column, (row + 1) * 4 + column);
        }
      }
    });

    test('authored order demonstrates why production reordering is needed', () {
      final InkPaletteSwatch gray10 = inkDevelopsWellAuthoredSwatches[1];
      final InkPaletteSwatch gray18 = inkDevelopsWellAuthoredSwatches[2];

      expect(gray10.gallery3State, Gallery3NativeState.white);
      expect(gray18.gallery3State, Gallery3NativeState.white);
    });

    test('named warm grays develop to their authored levels', () {
      expect(
        inkDevelopsWellAuthoredSwatches
            .skip(1)
            .take(3)
            .map((InkPaletteSwatch swatch) => swatch.developedLumaLevel),
        <int>[10, 18, 26],
      );
    });

    test('gray rail has sixteen even levels and never emits rail 31', () {
      expect(inkGrayLatticeLevels, <int>[
        for (var level = 0; level <= 30; level += 2) level,
      ]);
      expect(inkGrayLatticeLevels, isNot(contains(31)));
    });

    test('all sixteen gray representatives survive one develop pass', () {
      for (final int level in inkGrayLatticeLevels) {
        expect(
          inkDevelopedLumaLevel(inkGrayArgbForLevel(level)),
          closeTo(level, 1),
          reason: 'inverse-developed representative for level $level',
        );
      }
    });

    test('developed gray helper preserves each source developed level', () {
      for (final InkPaletteSwatch swatch in inkDevelopsWellSwatches) {
        expect(
          inkDevelopedLumaLevel(inkDevelopedGrayArgb(swatch.argb)),
          closeTo(swatch.developedLumaLevel, 1),
          reason: swatch.label,
        );
      }
    });

    test('black and paper are exact /30 endpoints', () {
      expect(inkDevelopedLumaLevel(0xff000000), 0);
      expect(inkDevelopedLumaLevel(0xffffffff), 30);
      expect(inkGrayArgbForLevel(0), 0xff000000);
      expect(inkGrayArgbForLevel(30), 0xffffffff);
    });

    test('invalid gray levels are rejected', () {
      expect(() => inkGrayArgbForLevel(-1), throwsRangeError);
      expect(() => inkGrayArgbForLevel(31), throwsRangeError);
    });

    test('highlighter row cannot drift from the WP4 brush contract', () {
      expect(
        inkHighlighterSwatches.map((InkPaletteSwatch swatch) => swatch.argb),
        highlighterColorsArgb,
      );
    });

    test('each highlighter remains at or above developed level twelve', () {
      expect(
        inkHighlighterSwatches.map(
          (InkPaletteSwatch swatch) => swatch.developedLumaLevel,
        ),
        everyElement(greaterThanOrEqualTo(12)),
      );
    });

    test(
      'all native colors are fixed points of nearest-state quantization',
      () {
        for (final Gallery3NativeState state in Gallery3NativeState.values) {
          expect(quantizeGallery3(state.argb), state, reason: state.code);
        }
      },
    );

    test('representative authored hues map deterministically', () {
      final Map<String, Gallery3NativeState> expected =
          <String, Gallery3NativeState>{
            'deep-blue': Gallery3NativeState.blue,
            'teal': Gallery3NativeState.green,
            'mustard': Gallery3NativeState.yellow,
            'red': Gallery3NativeState.red,
            'cyan': Gallery3NativeState.cyan,
            'magenta': Gallery3NativeState.magenta,
          };
      for (final InkPaletteSwatch swatch in inkDevelopsWellAuthoredSwatches) {
        final Gallery3NativeState? state = expected[swatch.id];
        if (state != null) {
          expect(swatch.gallery3State, state, reason: swatch.label);
        }
      }
    });
  });
}

void _expectGraySeparation(int firstIndex, int secondIndex) {
  final InkPaletteSwatch first = inkDevelopsWellSwatches[firstIndex];
  final InkPaletteSwatch second = inkDevelopsWellSwatches[secondIndex];
  expect(
    (first.developedLumaLevel - second.developedLumaLevel).abs(),
    greaterThanOrEqualTo(2),
    reason:
        '${first.label} (${first.developedLumaLevel}) beside '
        '${second.label} (${second.developedLumaLevel})',
  );
}

void _expectGallery3Separation(int firstIndex, int secondIndex) {
  final InkPaletteSwatch first = inkDevelopsWellSwatches[firstIndex];
  final InkPaletteSwatch second = inkDevelopsWellSwatches[secondIndex];
  expect(
    first.gallery3State,
    isNot(second.gallery3State),
    reason:
        '${first.label} and ${second.label} both quantize to '
        '${first.gallery3State.code}',
  );
}
