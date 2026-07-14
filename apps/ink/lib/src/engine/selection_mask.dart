import 'dart:typed_data';

/// How a new selection is combined with the current selection.
enum SelectionMaskOperation { replace, add, subtract, intersect }

/// Immutable byte-coverage selection aligned to a raster.
///
/// Zero is unselected and 255 is fully selected. Intermediate values preserve
/// anti-aliased selection edges without coupling the engine math to `dart:ui`.
final class SelectionMask {
  /// Copies and validates [coverage].
  SelectionMask({
    required this.width,
    required this.height,
    required Uint8List coverage,
  }) : _coverage = Uint8List.fromList(coverage) {
    _validateDimensions(width, height, coverage.length, 'coverage');
  }

  /// Creates an empty mask.
  factory SelectionMask.empty({required int width, required int height}) {
    _validateDimensions(width, height, width * height, 'coverage');
    return SelectionMask(
      width: width,
      height: height,
      coverage: Uint8List(width * height),
    );
  }

  /// Creates a fully selected mask.
  factory SelectionMask.full({required int width, required int height}) {
    _validateDimensions(width, height, width * height, 'coverage');
    return SelectionMask(
      width: width,
      height: height,
      coverage: Uint8List(width * height)..fillRange(0, width * height, 255),
    );
  }

  /// Creates a hard-edged mask from row-major booleans.
  factory SelectionMask.fromBools({
    required int width,
    required int height,
    required List<bool> selected,
  }) {
    _validateDimensions(width, height, selected.length, 'selected');
    return SelectionMask(
      width: width,
      height: height,
      coverage: Uint8List.fromList(<int>[
        for (final value in selected)
          if (value) 255 else 0,
      ]),
    );
  }

  /// Raster width in pixels.
  final int width;

  /// Raster height in pixels.
  final int height;

  final Uint8List _coverage;

  /// Read-only row-major coverage bytes.
  Uint8List get coverage => _coverage.asUnmodifiableView();

  /// Whether no pixel has coverage.
  bool get isEmpty => !_coverage.any((value) => value != 0);

  /// Whether at least one pixel has coverage.
  bool get isNotEmpty => !isEmpty;

  /// Coverage at ([x], [y]).
  int coverageAt(int x, int y) => _coverage[_checkedIndex(x, y)];

  /// Whether ([x], [y]) has non-zero selection coverage.
  bool contains(int x, int y) => coverageAt(x, y) != 0;

  /// Combines this mask with [other] without mutating either input.
  ///
  /// Add/intersect use maximum/minimum coverage. Subtract removes the incoming
  /// coverage arithmetically, clamped at zero.
  SelectionMask combine(SelectionMask other, SelectionMaskOperation operation) {
    _requireSameSize(other.width, other.height, 'other');
    if (operation == SelectionMaskOperation.replace) {
      return SelectionMask(
        width: width,
        height: height,
        coverage: other._coverage,
      );
    }
    final result = Uint8List(_coverage.length);
    for (var index = 0; index < result.length; index += 1) {
      final current = _coverage[index];
      final incoming = other._coverage[index];
      result[index] = switch (operation) {
        SelectionMaskOperation.replace => incoming,
        SelectionMaskOperation.add => current > incoming ? current : incoming,
        SelectionMaskOperation.subtract =>
          current > incoming ? current - incoming : 0,
        SelectionMaskOperation.intersect =>
          current < incoming ? current : incoming,
      };
    }
    return SelectionMask(width: width, height: height, coverage: result);
  }

  /// Grows a selection for positive [pixels] and contracts it for negatives.
  ///
  /// The WP5 tool contract bounds the adjustment to four pixels. A square
  /// (Chebyshev-distance) structuring element keeps the operation deterministic
  /// and closes diagonal one-pixel cracks as users expect.
  SelectionMask growOrContract(int pixels) {
    _checkRadius(pixels.abs(), 'pixels');
    if (pixels == 0) {
      return SelectionMask(width: width, height: height, coverage: _coverage);
    }
    return _morph(pixels.abs(), grow: pixels > 0, outsideCoverage: 0);
  }

  /// Performs a bounded morphological close (dilation followed by erosion).
  ///
  /// [outsideCoverage] defaults to 255 so a selected region or flood boundary
  /// touching the canvas edge is not eroded open by the finite raster extent.
  SelectionMask closeGaps(int pixels, {int outsideCoverage = 255}) {
    _checkRadius(pixels, 'pixels');
    if (outsideCoverage < 0 || outsideCoverage > 255) {
      throw RangeError.range(outsideCoverage, 0, 255, 'outsideCoverage');
    }
    if (pixels == 0) {
      return SelectionMask(width: width, height: height, coverage: _coverage);
    }
    return _morph(
      pixels,
      grow: true,
      outsideCoverage: 0,
    )._morph(pixels, grow: false, outsideCoverage: outsideCoverage);
  }

  /// Multiplies row-major [inputCoverage] by this selection.
  Uint8List clipCoverage(Uint8List inputCoverage) {
    _requirePayloadLength(inputCoverage.length, 'inputCoverage', 1);
    final result = Uint8List(inputCoverage.length);
    for (var index = 0; index < inputCoverage.length; index += 1) {
      result[index] = _multiplyBytes(inputCoverage[index], _coverage[index]);
    }
    return result;
  }

  /// Clips premultiplied RGBA8888 [rgba] by this selection.
  ///
  /// Every premultiplied channel, including alpha, is scaled by selection
  /// coverage. The input is copied and never mutated.
  Uint8List clipPremultipliedRgba(Uint8List rgba) {
    _requirePayloadLength(rgba.length, 'rgba', 4);
    final result = Uint8List(rgba.length);
    for (var index = 0; index < _coverage.length; index += 1) {
      final mask = _coverage[index];
      final offset = index * 4;
      result[offset] = _multiplyBytes(rgba[offset], mask);
      result[offset + 1] = _multiplyBytes(rgba[offset + 1], mask);
      result[offset + 2] = _multiplyBytes(rgba[offset + 2], mask);
      result[offset + 3] = _multiplyBytes(rgba[offset + 3], mask);
    }
    return result;
  }

  SelectionMask _morph(
    int radius, {
    required bool grow,
    required int outsideCoverage,
  }) {
    final result = Uint8List(_coverage.length);
    for (var y = 0; y < height; y += 1) {
      for (var x = 0; x < width; x += 1) {
        var resolved = grow ? 0 : 255;
        var finished = false;
        for (
          var offsetY = -radius;
          offsetY <= radius && !finished;
          offsetY += 1
        ) {
          final sampleY = y + offsetY;
          for (var offsetX = -radius; offsetX <= radius; offsetX += 1) {
            final sampleX = x + offsetX;
            final sample =
                sampleX < 0 ||
                    sampleX >= width ||
                    sampleY < 0 ||
                    sampleY >= height
                ? outsideCoverage
                : _coverage[sampleY * width + sampleX];
            if (grow) {
              if (sample > resolved) {
                resolved = sample;
              }
              if (resolved == 255) {
                finished = true;
                break;
              }
            } else {
              if (sample < resolved) {
                resolved = sample;
              }
              if (resolved == 0) {
                finished = true;
                break;
              }
            }
          }
        }
        result[y * width + x] = resolved;
      }
    }
    return SelectionMask(width: width, height: height, coverage: result);
  }

  int _checkedIndex(int x, int y) {
    if (x < 0 || x >= width) {
      throw RangeError.range(x, 0, width - 1, 'x');
    }
    if (y < 0 || y >= height) {
      throw RangeError.range(y, 0, height - 1, 'y');
    }
    return y * width + x;
  }

  void _requireSameSize(int otherWidth, int otherHeight, String name) {
    if (otherWidth != width || otherHeight != height) {
      throw ArgumentError(
        '$name dimensions must be ${width}x$height, '
        'not ${otherWidth}x$otherHeight.',
      );
    }
  }

  void _requirePayloadLength(int length, String name, int channels) {
    final expected = width * height * channels;
    if (length != expected) {
      throw ArgumentError.value(
        length,
        name,
        'length must be $expected for ${width}x$height',
      );
    }
  }
}

int _multiplyBytes(int first, int second) => (first * second + 127) ~/ 255;

void _checkRadius(int radius, String name) {
  if (radius < 0 || radius > 4) {
    throw RangeError.range(radius, 0, 4, name);
  }
}

void _validateDimensions(
  int width,
  int height,
  int payloadLength,
  String payloadName,
) {
  if (width <= 0) {
    throw RangeError.value(width, 'width', 'must be positive');
  }
  if (height <= 0) {
    throw RangeError.value(height, 'height', 'must be positive');
  }
  final expected = width * height;
  if (payloadLength != expected) {
    throw ArgumentError.value(
      payloadLength,
      payloadName,
      'length must be $expected for ${width}x$height',
    );
  }
}
