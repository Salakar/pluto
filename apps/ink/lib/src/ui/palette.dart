import 'dart:math' as math;

/// Highest usable shade on Ink's 0–30 display lattice.
///
/// Level 31 is a waveform rail and is deliberately never emitted.
const int inkGrayLatticeMaxLevel = 30;

/// The sixteen gray choices exposed by the custom-color rail.
const List<int> inkGrayLatticeLevels = <int>[
  0,
  2,
  4,
  6,
  8,
  10,
  12,
  14,
  16,
  18,
  20,
  22,
  24,
  26,
  28,
  30,
];

/// One of the eight conservative pigment states used by Gallery 3.
///
/// The RGB values intentionally mirror the renderer's interim CMYW palette,
/// including its muted pairwise mixes. They are preview values rather than a
/// claim that the physical pigments reproduce sRGB exactly.
enum Gallery3NativeState {
  /// All pigments stacked.
  black('K', 0xff000000),

  /// Paper white.
  white('W', 0xffffffff),

  /// Cyan pigment.
  cyan('C', 0xff00c8dc),

  /// Magenta pigment.
  magenta('M', 0xffc80082),

  /// Yellow pigment.
  yellow('Y', 0xffebc800),

  /// Magenta and yellow mix.
  red('R', 0xffd22828),

  /// Cyan and yellow mix.
  green('G', 0xff32a046),

  /// Cyan and magenta mix.
  blue('B', 0xff2846b4);

  const Gallery3NativeState(this.code, this.argb);

  /// One-letter pigment-state label used by the hero grid.
  final String code;

  /// Muted host-preview color for this pigment state.
  final int argb;
}

/// Immutable color choice shown by Ink's color panel.
final class InkPaletteSwatch {
  /// Creates a named opaque ARGB swatch.
  const InkPaletteSwatch({
    required this.id,
    required this.label,
    required this.argb,
  }) : assert(argb >= 0xff000000 && argb <= 0xffffffff);

  /// Stable machine-readable identifier.
  final String id;

  /// Short authored display name.
  final String label;

  /// Opaque color encoded as `0xAARRGGBB`.
  final int argb;

  /// Canonical authored `#RRGGBB` identity.
  String get hex =>
      '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// This color's `sRGB luma → luma^1.8 → /30` result.
  int get developedLumaLevel => inkDevelopedLumaLevel(argb);

  /// Achromatic preview of the shade presented by monochrome glass.
  int get developedGrayArgb => inkDevelopedGrayArgb(argb);

  /// Nearest conservative Gallery-3 pigment state without spatial dithering.
  Gallery3NativeState get gallery3State => quantizeGallery3(argb);
}

/// The eight native K/W/C/M/Y/R/G/B states in their binding order.
const List<InkPaletteSwatch> inkNativeSwatches = <InkPaletteSwatch>[
  InkPaletteSwatch(id: 'native-k', label: 'K', argb: 0xff000000),
  InkPaletteSwatch(id: 'native-w', label: 'W', argb: 0xffffffff),
  InkPaletteSwatch(id: 'native-c', label: 'C', argb: 0xff00c8dc),
  InkPaletteSwatch(id: 'native-m', label: 'M', argb: 0xffc80082),
  InkPaletteSwatch(id: 'native-y', label: 'Y', argb: 0xffebc800),
  InkPaletteSwatch(id: 'native-r', label: 'R', argb: 0xffd22828),
  InkPaletteSwatch(id: 'native-g', label: 'G', argb: 0xff32a046),
  InkPaletteSwatch(id: 'native-b', label: 'B', argb: 0xff2846b4),
];

const InkPaletteSwatch _inkBlack = InkPaletteSwatch(
  id: 'ink-black',
  label: 'ink black',
  argb: 0xff000000,
);
const InkPaletteSwatch _warmGray10 = InkPaletteSwatch(
  id: 'warm-gray-10',
  label: 'warm gray 10',
  argb: 0xff95897d,
);
const InkPaletteSwatch _warmGray18 = InkPaletteSwatch(
  id: 'warm-gray-18',
  label: 'warm gray 18',
  argb: 0xffc9bfb3,
);
const InkPaletteSwatch _warmGray26 = InkPaletteSwatch(
  id: 'warm-gray-26',
  label: 'warm gray 26',
  argb: 0xfff2e9de,
);
const InkPaletteSwatch _paperWhite = InkPaletteSwatch(
  id: 'paper-white',
  label: 'paper white',
  argb: 0xffffffff,
);
const InkPaletteSwatch _deepBlue = InkPaletteSwatch(
  id: 'deep-blue',
  label: 'deep blue',
  argb: 0xff1d3e74,
);
const InkPaletteSwatch _sky = InkPaletteSwatch(
  id: 'sky',
  label: 'sky',
  argb: 0xff4a7fc1,
);
const InkPaletteSwatch _teal = InkPaletteSwatch(
  id: 'teal',
  label: 'teal',
  argb: 0xff1f6f6a,
);
const InkPaletteSwatch _forest = InkPaletteSwatch(
  id: 'forest',
  label: 'forest',
  argb: 0xff2e5d34,
);
const InkPaletteSwatch _leaf = InkPaletteSwatch(
  id: 'leaf',
  label: 'leaf',
  argb: 0xff5b8f3e,
);
const InkPaletteSwatch _olive = InkPaletteSwatch(
  id: 'olive',
  label: 'olive',
  argb: 0xff6b6a2e,
);
const InkPaletteSwatch _mustard = InkPaletteSwatch(
  id: 'mustard',
  label: 'mustard',
  argb: 0xffb08a1e,
);
const InkPaletteSwatch _amber = InkPaletteSwatch(
  id: 'amber',
  label: 'amber',
  argb: 0xffc77f2a,
);
const InkPaletteSwatch _rust = InkPaletteSwatch(
  id: 'rust',
  label: 'rust',
  argb: 0xffa64b22,
);
const InkPaletteSwatch _red = InkPaletteSwatch(
  id: 'red',
  label: 'red',
  argb: 0xffb3261e,
);
const InkPaletteSwatch _crimson = InkPaletteSwatch(
  id: 'crimson',
  label: 'crimson',
  argb: 0xff7e1f2b,
);
const InkPaletteSwatch _plum = InkPaletteSwatch(
  id: 'plum',
  label: 'plum',
  argb: 0xff5c2a5e,
);
const InkPaletteSwatch _violet = InkPaletteSwatch(
  id: 'violet',
  label: 'violet',
  argb: 0xff4b3a8c,
);
const InkPaletteSwatch _brown = InkPaletteSwatch(
  id: 'brown',
  label: 'brown',
  argb: 0xff5c4632,
);
const InkPaletteSwatch _tan = InkPaletteSwatch(
  id: 'tan',
  label: 'tan',
  argb: 0xffa9895f,
);
const InkPaletteSwatch _blush = InkPaletteSwatch(
  id: 'blush',
  label: 'blush',
  argb: 0xffc98d8a,
);
const InkPaletteSwatch _cyan = InkPaletteSwatch(
  id: 'cyan',
  label: 'cyan',
  argb: 0xff1a8fa8,
);
const InkPaletteSwatch _magenta = InkPaletteSwatch(
  id: 'magenta',
  label: 'magenta',
  argb: 0xffb03a7e,
);
const InkPaletteSwatch _charcoalBlue = InkPaletteSwatch(
  id: 'charcoal-blue',
  label: 'charcoal blue',
  argb: 0xff2b3540,
);

/// The binding palette, in its authored order.
///
/// The three warm-gray RGB representatives are pinned to authored /30 levels
/// 10, 18, and 26. Use [inkDevelopsWellSwatches] for panel presentation; its
/// reordered grid prevents adjacent gray and Gallery-3 collisions.
const List<InkPaletteSwatch> inkDevelopsWellAuthoredSwatches =
    <InkPaletteSwatch>[
      _inkBlack,
      _warmGray10,
      _warmGray18,
      _warmGray26,
      _paperWhite,
      _deepBlue,
      _sky,
      _teal,
      _forest,
      _leaf,
      _olive,
      _mustard,
      _amber,
      _rust,
      _red,
      _crimson,
      _plum,
      _violet,
      _brown,
      _tan,
      _blush,
      _cyan,
      _magenta,
      _charcoalBlue,
    ];

/// Collision-safe 6×4 production layout of the 24 develops-well colors.
///
/// Every horizontal and vertical pair differs by at least two /30 gray levels
/// and maps to a different nearest Gallery-3 state. The order is deliberately
/// explicit so future visual tuning cannot silently invalidate that matrix.
const List<InkPaletteSwatch> inkDevelopsWellSwatches = <InkPaletteSwatch>[
  _charcoalBlue,
  _magenta,
  _tan,
  _inkBlack,
  _cyan,
  _blush,
  _brown,
  _rust,
  _warmGray10,
  _violet,
  _amber,
  _warmGray18,
  _forest,
  _warmGray26,
  _deepBlue,
  _teal,
  _leaf,
  _red,
  _paperWhite,
  _sky,
  _crimson,
  _olive,
  _mustard,
  _plum,
];

/// Four highlighter-only choices, byte-identical to the WP4 brush contract.
const List<InkPaletteSwatch> inkHighlighterSwatches = <InkPaletteSwatch>[
  InkPaletteSwatch(
    id: 'highlight-yellow',
    label: 'pale yellow',
    argb: 0xffffef78,
  ),
  InkPaletteSwatch(id: 'highlight-cyan', label: 'pale cyan', argb: 0xff91e7ee),
  InkPaletteSwatch(id: 'highlight-pink', label: 'pale pink', argb: 0xfff1a6c1),
  InkPaletteSwatch(
    id: 'highlight-green',
    label: 'pale green',
    argb: 0xffa9e4a1,
  ),
];

/// Applies Ink's binding `sRGB luma → luma^1.8 → /30` conversion.
int inkDevelopedLumaLevel(int argb) {
  final int red = (argb >>> 16) & 0xff;
  final int green = (argb >>> 8) & 0xff;
  final int blue = argb & 0xff;
  final double luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;
  return (math.pow(luma, 1.8) * inkGrayLatticeMaxLevel).round().clamp(
    0,
    inkGrayLatticeMaxLevel,
  );
}

/// Expands one valid /30 shade to its inverse-developed sRGB representative.
///
/// Applying [inkDevelopedLumaLevel] to the result returns [level] (within
/// integer rounding), so the presenter develops the corner preview once.
int inkGrayArgbForLevel(int level) {
  if (level < 0 || level > inkGrayLatticeMaxLevel) {
    throw RangeError.range(level, 0, inkGrayLatticeMaxLevel, 'level');
  }
  final int channel = level == 0
      ? 0
      : (math.pow(level / inkGrayLatticeMaxLevel, 1 / 1.8) * 255).round().clamp(
          0,
          255,
        );
  return 0xff000000 | channel << 16 | channel << 8 | channel;
}

/// Returns the monochrome-glass preview of [argb].
int inkDevelopedGrayArgb(int argb) =>
    inkGrayArgbForLevel(inkDevelopedLumaLevel(argb));

/// Maps [argb] to the nearest conservative Gallery-3 pigment state.
///
/// This is the renderer's deterministic, no-dither nearest-state metric. Luma
/// error has weight 2 and chroma-axis error has weight 9, which keeps a muted
/// color near its intended pigment instead of treating RGB distance as panel
/// physics. Equal distances retain the earlier K/W/C/M/Y/R/G/B state.
Gallery3NativeState quantizeGallery3(int argb) {
  final int red = (argb >>> 16) & 0xff;
  final int green = (argb >>> 8) & 0xff;
  final int blue = argb & 0xff;
  Gallery3NativeState best = Gallery3NativeState.values.first;
  int bestDistance = _gallery3Distance(best.argb, red, green, blue);
  for (final Gallery3NativeState candidate in Gallery3NativeState.values.skip(
    1,
  )) {
    final int distance = _gallery3Distance(candidate.argb, red, green, blue);
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}

int _gallery3Distance(int candidateArgb, int red, int green, int blue) {
  final int candidateRed = (candidateArgb >>> 16) & 0xff;
  final int candidateGreen = (candidateArgb >>> 8) & 0xff;
  final int candidateBlue = candidateArgb & 0xff;
  final int candidateLuma = _gallery3Luma(
    candidateRed,
    candidateGreen,
    candidateBlue,
  );
  final int luma = _gallery3Luma(red, green, blue);
  final int lumaDelta = candidateLuma - luma;
  final int redChromaDelta = (candidateRed - candidateLuma) - (red - luma);
  final int greenChromaDelta =
      (candidateGreen - candidateLuma) - (green - luma);
  final int blueChromaDelta = (candidateBlue - candidateLuma) - (blue - luma);
  return 2 * lumaDelta * lumaDelta +
      9 *
          (redChromaDelta * redChromaDelta +
              greenChromaDelta * greenChromaDelta +
              blueChromaDelta * blueChromaDelta);
}

int _gallery3Luma(int red, int green, int blue) =>
    (30 * red + 59 * green + 11 * blue + 50) ~/ 100;
