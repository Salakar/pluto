import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'selection_mask.dart';

/// Straight-alpha RGBA color used at the raster-operation API boundary.
final class RgbaColor {
  factory RgbaColor({
    required int red,
    required int green,
    required int blue,
    int alpha = 255,
  }) {
    _checkByte(red, 'red');
    _checkByte(green, 'green');
    _checkByte(blue, 'blue');
    _checkByte(alpha, 'alpha');
    return RgbaColor._(red, green, blue, alpha);
  }

  /// Creates a color from `0xAARRGGBB`.
  factory RgbaColor.fromArgb(int argb) => RgbaColor(
    red: (argb >> 16) & 0xff,
    green: (argb >> 8) & 0xff,
    blue: argb & 0xff,
    alpha: (argb >> 24) & 0xff,
  );

  const RgbaColor._(this.red, this.green, this.blue, this.alpha);

  /// Fully transparent black.
  static const RgbaColor transparent = RgbaColor._(0, 0, 0, 0);

  final int red;
  final int green;
  final int blue;
  final int alpha;

  /// This color in `0xAARRGGBB` notation.
  int get argb => alpha << 24 | red << 16 | green << 8 | blue;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RgbaColor &&
          red == other.red &&
          green == other.green &&
          blue == other.blue &&
          alpha == other.alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);

  @override
  String toString() => 'RgbaColor($red, $green, $blue, $alpha)';
}

/// Immutable, validated premultiplied RGBA8888 bitmap.
///
/// This matches Ink's tile and compositor byte contract while avoiding all
/// engine image decoding/upload paths. Constructors defensively copy input.
final class RgbaBitmap {
  RgbaBitmap._({
    required this.width,
    required this.height,
    required Uint8List premultipliedRgba,
  }) : _pixels = Uint8List.fromList(premultipliedRgba);

  /// Copies premultiplied RGBA8888 [pixels] after validating its shape and
  /// premultiplication invariant (`R,G,B <= A`).
  factory RgbaBitmap.fromPremultipliedRgba({
    required int width,
    required int height,
    required Uint8List pixels,
  }) {
    _validateRgbaDimensions(width, height, pixels.length);
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final alpha = pixels[offset + 3];
      if (pixels[offset] > alpha ||
          pixels[offset + 1] > alpha ||
          pixels[offset + 2] > alpha) {
        throw ArgumentError.value(
          pixels.sublist(offset, offset + 4),
          'pixels',
          'pixel ${offset ~/ 4} is not premultiplied RGBA',
        );
      }
    }
    return RgbaBitmap._(
      width: width,
      height: height,
      premultipliedRgba: pixels,
    );
  }

  /// Creates a transparent bitmap.
  factory RgbaBitmap.transparent({required int width, required int height}) {
    _validateRgbaDimensions(width, height, width * height * 4);
    return RgbaBitmap._(
      width: width,
      height: height,
      premultipliedRgba: Uint8List(width * height * 4),
    );
  }

  /// Creates a bitmap filled with one straight-alpha [color].
  factory RgbaBitmap.solid({
    required int width,
    required int height,
    required RgbaColor color,
  }) => RgbaBitmap.fromColors(
    width: width,
    height: height,
    colors: List<RgbaColor>.filled(width * height, color),
  );

  /// Creates a bitmap from row-major straight-alpha [colors].
  factory RgbaBitmap.fromColors({
    required int width,
    required int height,
    required List<RgbaColor> colors,
  }) {
    _validatePixelDimensions(width, height, colors.length, 'colors');
    final pixels = Uint8List(width * height * 4);
    for (var index = 0; index < colors.length; index += 1) {
      _writeStraightColor(pixels, index * 4, colors[index], 255);
    }
    return RgbaBitmap._(
      width: width,
      height: height,
      premultipliedRgba: pixels,
    );
  }

  final int width;
  final int height;
  final Uint8List _pixels;

  /// Read-only row-major premultiplied RGBA8888 bytes.
  Uint8List get pixels => _pixels.asUnmodifiableView();

  /// Returns the unpremultiplied color at ([x], [y]).
  RgbaColor colorAt(int x, int y) {
    final offset = _checkedPixelIndex(x, y) * 4;
    final alpha = _pixels[offset + 3];
    if (alpha == 0) {
      return RgbaColor.transparent;
    }
    return RgbaColor(
      red: _unpremultiply(_pixels[offset], alpha),
      green: _unpremultiply(_pixels[offset + 1], alpha),
      blue: _unpremultiply(_pixels[offset + 2], alpha),
      alpha: alpha,
    );
  }

  /// Returns one stored premultiplied channel (`0=R, 1=G, 2=B, 3=A`).
  int channelAt(int x, int y, int channel) {
    if (channel < 0 || channel > 3) {
      throw RangeError.range(channel, 0, 3, 'channel');
    }
    return _pixels[_checkedPixelIndex(x, y) * 4 + channel];
  }

  int _checkedPixelIndex(int x, int y) {
    if (x < 0 || x >= width) {
      throw RangeError.range(x, 0, width - 1, 'x');
    }
    if (y < 0 || y >= height) {
      throw RangeError.range(y, 0, height - 1, 'y');
    }
    return y * width + x;
  }
}

/// Fill pattern families offered by the WP5 fill tool.
sealed class RasterFillStyle {
  const RasterFillStyle(this.color);

  final RgbaColor color;

  int coverageAt(int x, int y);
}

/// Uniform fill coverage.
final class SolidRasterFill extends RasterFillStyle {
  const SolidRasterFill._(super.color);

  factory SolidRasterFill(RgbaColor color) => SolidRasterFill._(color);

  @override
  int coverageAt(int x, int y) => 255;
}

/// Direction of deterministic hatch lines.
enum HatchDirection { diagonalDown, diagonalUp, horizontal, vertical }

/// Transparent-backed hard-edged hatch pattern.
final class HatchRasterFill extends RasterFillStyle {
  HatchRasterFill({
    required RgbaColor color,
    this.spacing = 8,
    this.lineWidth = 1,
    this.direction = HatchDirection.diagonalDown,
    this.phase = 0,
  }) : super(color) {
    if (spacing < 2 || spacing > 64) {
      throw RangeError.range(spacing, 2, 64, 'spacing');
    }
    if (lineWidth < 1 || lineWidth > spacing) {
      throw RangeError.range(lineWidth, 1, spacing, 'lineWidth');
    }
  }

  final int spacing;
  final int lineWidth;
  final HatchDirection direction;
  final int phase;

  @override
  int coverageAt(int x, int y) {
    final coordinate = switch (direction) {
      HatchDirection.diagonalDown => x - y,
      HatchDirection.diagonalUp => x + y,
      HatchDirection.horizontal => y,
      HatchDirection.vertical => x,
    };
    return _positiveModulo(coordinate + phase, spacing) < lineWidth ? 255 : 0;
  }
}

/// Ordered matrix used by dot-screen fill.
enum DotScreenMatrix { bayer4, bayer8 }

/// Deterministic ordered dot-screen fill.
final class DotScreenRasterFill extends RasterFillStyle {
  DotScreenRasterFill({
    required RgbaColor color,
    this.density = 0.5,
    this.matrix = DotScreenMatrix.bayer4,
    this.phaseX = 0,
    this.phaseY = 0,
  }) : super(color) {
    if (!density.isFinite || density < 0 || density > 1) {
      throw RangeError.range(density, 0, 1, 'density');
    }
  }

  final double density;
  final DotScreenMatrix matrix;
  final int phaseX;
  final int phaseY;

  @override
  int coverageAt(int x, int y) {
    if (density <= 0) {
      return 0;
    }
    if (density >= 1) {
      return 255;
    }
    final size = matrix == DotScreenMatrix.bayer4 ? 4 : 8;
    final values = matrix == DotScreenMatrix.bayer4 ? _bayer4 : _bayer8;
    final matrixX = _positiveModulo(x + phaseX, size);
    final matrixY = _positiveModulo(y + phaseY, size);
    final threshold = (values[matrixY * size + matrixX] + 0.5) / (size * size);
    return density >= threshold ? 255 : 0;
  }
}

/// Finds the contiguous region matching the seed color.
///
/// Tolerance is an RMS distance across straight RGB channels, in the binding
/// range 0-64. Four-way connectivity prevents diagonal corner leaks. Optional
/// gap close closes the non-matching boundary mask before a scanline flood.
SelectionMask contiguousColorRegion({
  required RgbaBitmap source,
  required int seedX,
  required int seedY,
  int tolerance = 0,
  int gapClose = 0,
  int grow = 0,
}) {
  _checkCoordinate(seedX, source.width, 'seedX');
  _checkCoordinate(seedY, source.height, 'seedY');
  if (tolerance < 0 || tolerance > 64) {
    throw RangeError.range(tolerance, 0, 64, 'tolerance');
  }
  if (gapClose < 0 || gapClose > 4) {
    throw RangeError.range(gapClose, 0, 4, 'gapClose');
  }
  if (grow < -4 || grow > 4) {
    throw RangeError.range(grow, -4, 4, 'grow');
  }

  final pixelCount = source.width * source.height;
  final matching = Uint8List(pixelCount);
  final seedOffset = (seedY * source.width + seedX) * 4;
  final seedAlpha = source._pixels[seedOffset + 3];
  final seedRed = _straightChannel(source._pixels[seedOffset], seedAlpha);
  final seedGreen = _straightChannel(source._pixels[seedOffset + 1], seedAlpha);
  final seedBlue = _straightChannel(source._pixels[seedOffset + 2], seedAlpha);
  final maximumSquaredDistance = tolerance * tolerance * 3;
  for (var index = 0; index < pixelCount; index += 1) {
    final offset = index * 4;
    final alpha = source._pixels[offset + 3];
    final redDelta = _straightChannel(source._pixels[offset], alpha) - seedRed;
    final greenDelta =
        _straightChannel(source._pixels[offset + 1], alpha) - seedGreen;
    final blueDelta =
        _straightChannel(source._pixels[offset + 2], alpha) - seedBlue;
    final squaredDistance =
        redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta;
    if (squaredDistance <= maximumSquaredDistance) {
      matching[index] = 255;
    }
  }

  var traversable = matching;
  if (gapClose > 0) {
    final barrier = Uint8List(pixelCount);
    for (var index = 0; index < pixelCount; index += 1) {
      barrier[index] = matching[index] == 0 ? 255 : 0;
    }
    final closedBarrier = SelectionMask(
      width: source.width,
      height: source.height,
      coverage: barrier,
    ).closeGaps(gapClose, outsideCoverage: 255);
    final closedBarrierCoverage = closedBarrier.coverage;
    traversable = Uint8List(pixelCount);
    for (var index = 0; index < pixelCount; index += 1) {
      if (matching[index] != 0 && closedBarrierCoverage[index] == 0) {
        traversable[index] = 255;
      }
    }
    // Closing a tiny cavity may consume it entirely. The seed remains a valid
    // one-pixel region instead of yielding the surprising empty selection.
    traversable[seedY * source.width + seedX] = 255;
  }

  final selected = _scanlineFlood(
    width: source.width,
    height: source.height,
    traversable: traversable,
    seedX: seedX,
    seedY: seedY,
  );
  final region = SelectionMask(
    width: source.width,
    height: source.height,
    coverage: selected,
  );
  return grow == 0 ? region : region.growOrContract(grow);
}

/// Wand-tool spelling of [contiguousColorRegion].
SelectionMask wandRegion({
  required RgbaBitmap source,
  required int seedX,
  required int seedY,
  int tolerance = 0,
  int gapClose = 0,
  int grow = 0,
}) => contiguousColorRegion(
  source: source,
  seedX: seedX,
  seedY: seedY,
  tolerance: tolerance,
  gapClose: gapClose,
  grow: grow,
);

/// Applies [fill] through [region] and an optional active selection [clip].
///
/// Color is composited source-over the immutable [source]. Pattern holes leave
/// the source unchanged. All math operates directly on premultiplied bytes.
RgbaBitmap applyRasterFill({
  required RgbaBitmap source,
  required SelectionMask region,
  required RasterFillStyle fill,
  SelectionMask? clip,
}) {
  _requireMaskSize(source, region, 'region');
  if (clip != null) {
    _requireMaskSize(source, clip, 'clip');
  }
  final output = Uint8List.fromList(source._pixels);
  final regionCoverage = region.coverage;
  final clipCoverage = clip?.coverage;
  for (var y = 0; y < source.height; y += 1) {
    for (var x = 0; x < source.width; x += 1) {
      final index = y * source.width + x;
      var coverage = regionCoverage[index];
      if (clipCoverage != null) {
        coverage = _multiplyBytes(coverage, clipCoverage[index]);
      }
      coverage = _multiplyBytes(coverage, fill.coverageAt(x, y));
      if (coverage == 0 || fill.color.alpha == 0) {
        continue;
      }
      _compositeStraightColorOver(output, index * 4, fill.color, coverage);
    }
  }
  return RgbaBitmap._(
    width: source.width,
    height: source.height,
    premultipliedRgba: output,
  );
}

/// Flood-fills [target], optionally sampling a same-sized composite bitmap.
///
/// Passing [sampleSource] implements the tool's “sample composite” option while
/// writes still land only in [target].
RgbaBitmap floodFill({
  required RgbaBitmap target,
  required int seedX,
  required int seedY,
  required RasterFillStyle fill,
  RgbaBitmap? sampleSource,
  SelectionMask? clip,
  int tolerance = 0,
  int gapClose = 0,
  int grow = 0,
}) {
  final sample = sampleSource ?? target;
  if (sample.width != target.width || sample.height != target.height) {
    throw ArgumentError(
      'sampleSource dimensions must match target dimensions.',
    );
  }
  final region = contiguousColorRegion(
    source: sample,
    seedX: seedX,
    seedY: seedY,
    tolerance: tolerance,
    gapClose: gapClose,
    grow: grow,
  );
  return applyRasterFill(
    source: target,
    region: region,
    fill: fill,
    clip: clip,
  );
}

Uint8List _scanlineFlood({
  required int width,
  required int height,
  required Uint8List traversable,
  required int seedX,
  required int seedY,
}) {
  final selected = Uint8List(width * height);
  final pending = ListQueue<int>()..add(seedY * width + seedX);
  while (pending.isNotEmpty) {
    final seedIndex = pending.removeFirst();
    if (traversable[seedIndex] == 0 || selected[seedIndex] != 0) {
      continue;
    }
    final y = seedIndex ~/ width;
    var left = seedIndex % width;
    while (left > 0) {
      final candidate = y * width + left - 1;
      if (traversable[candidate] == 0 || selected[candidate] != 0) {
        break;
      }
      left -= 1;
    }
    var right = seedIndex % width;
    while (right + 1 < width) {
      final candidate = y * width + right + 1;
      if (traversable[candidate] == 0 || selected[candidate] != 0) {
        break;
      }
      right += 1;
    }
    for (var x = left; x <= right; x += 1) {
      selected[y * width + x] = 255;
    }
    if (y > 0) {
      _enqueueRuns(
        pending: pending,
        traversable: traversable,
        selected: selected,
        width: width,
        y: y - 1,
        left: left,
        right: right,
      );
    }
    if (y + 1 < height) {
      _enqueueRuns(
        pending: pending,
        traversable: traversable,
        selected: selected,
        width: width,
        y: y + 1,
        left: left,
        right: right,
      );
    }
  }
  return selected;
}

void _enqueueRuns({
  required ListQueue<int> pending,
  required Uint8List traversable,
  required Uint8List selected,
  required int width,
  required int y,
  required int left,
  required int right,
}) {
  var inRun = false;
  for (var x = left; x <= right; x += 1) {
    final index = y * width + x;
    final available = traversable[index] != 0 && selected[index] == 0;
    if (available && !inRun) {
      pending.add(index);
    }
    inRun = available;
  }
}

void _compositeStraightColorOver(
  Uint8List destination,
  int offset,
  RgbaColor color,
  int coverage,
) {
  final sourceAlpha = _multiplyBytes(color.alpha, coverage);
  final inverseAlpha = 255 - sourceAlpha;
  final sourceRed = _multiplyBytes(color.red, sourceAlpha);
  final sourceGreen = _multiplyBytes(color.green, sourceAlpha);
  final sourceBlue = _multiplyBytes(color.blue, sourceAlpha);
  destination[offset] = math.min(
    255,
    sourceRed + _multiplyBytes(destination[offset], inverseAlpha),
  );
  destination[offset + 1] = math.min(
    255,
    sourceGreen + _multiplyBytes(destination[offset + 1], inverseAlpha),
  );
  destination[offset + 2] = math.min(
    255,
    sourceBlue + _multiplyBytes(destination[offset + 2], inverseAlpha),
  );
  destination[offset + 3] = math.min(
    255,
    sourceAlpha + _multiplyBytes(destination[offset + 3], inverseAlpha),
  );
}

void _writeStraightColor(
  Uint8List destination,
  int offset,
  RgbaColor color,
  int coverage,
) {
  final alpha = _multiplyBytes(color.alpha, coverage);
  destination[offset] = _multiplyBytes(color.red, alpha);
  destination[offset + 1] = _multiplyBytes(color.green, alpha);
  destination[offset + 2] = _multiplyBytes(color.blue, alpha);
  destination[offset + 3] = alpha;
}

int _straightChannel(int channel, int alpha) =>
    alpha == 0 ? 0 : _unpremultiply(channel, alpha);

int _unpremultiply(int channel, int alpha) =>
    (channel * 255 / alpha).round().clamp(0, 255);

int _multiplyBytes(int first, int second) => (first * second + 127) ~/ 255;

int _positiveModulo(int value, int modulus) {
  final result = value % modulus;
  return result < 0 ? result + modulus : result;
}

void _requireMaskSize(RgbaBitmap source, SelectionMask mask, String name) {
  if (mask.width != source.width || mask.height != source.height) {
    throw ArgumentError(
      '$name dimensions must be ${source.width}x${source.height}, '
      'not ${mask.width}x${mask.height}.',
    );
  }
}

void _checkCoordinate(int value, int extent, String name) {
  if (value < 0 || value >= extent) {
    throw RangeError.range(value, 0, extent - 1, name);
  }
}

void _checkByte(int value, String name) {
  if (value < 0 || value > 255) {
    throw RangeError.range(value, 0, 255, name);
  }
}

void _validateRgbaDimensions(int width, int height, int byteLength) {
  _validatePixelDimensions(width, height, byteLength, 'pixels', channels: 4);
}

void _validatePixelDimensions(
  int width,
  int height,
  int payloadLength,
  String payloadName, {
  int channels = 1,
}) {
  if (width <= 0) {
    throw RangeError.value(width, 'width', 'must be positive');
  }
  if (height <= 0) {
    throw RangeError.value(height, 'height', 'must be positive');
  }
  final expected = width * height * channels;
  if (payloadLength != expected) {
    throw ArgumentError.value(
      payloadLength,
      payloadName,
      'length must be $expected for ${width}x$height',
    );
  }
}

const List<int> _bayer4 = <int>[
  0,
  8,
  2,
  10,
  12,
  4,
  14,
  6,
  3,
  11,
  1,
  9,
  15,
  7,
  13,
  5,
];

const List<int> _bayer8 = <int>[
  0,
  32,
  8,
  40,
  2,
  34,
  10,
  42,
  48,
  16,
  56,
  24,
  50,
  18,
  58,
  26,
  12,
  44,
  4,
  36,
  14,
  46,
  6,
  38,
  60,
  28,
  52,
  20,
  62,
  30,
  54,
  22,
  3,
  35,
  11,
  43,
  1,
  33,
  9,
  41,
  51,
  19,
  59,
  27,
  49,
  17,
  57,
  25,
  15,
  47,
  7,
  39,
  13,
  45,
  5,
  37,
  63,
  31,
  55,
  23,
  61,
  29,
  53,
  21,
];
