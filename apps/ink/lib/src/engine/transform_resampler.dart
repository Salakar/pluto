import 'dart:math' as math;
import 'dart:typed_data';

import 'raster_ops.dart';

/// Sampling quality used while or after a floating-selection gesture.
enum RasterSampling { nearest, bilinear }

/// Framework-independent two-dimensional affine transform.
///
/// The matrix maps source pixel-center coordinates to destination pixel-center
/// coordinates:
///
/// ```text
/// x' = m00*x + m01*y + m02
/// y' = m10*x + m11*y + m12
/// ```
final class AffineRasterTransform {
  AffineRasterTransform({
    required this.m00,
    required this.m01,
    required this.m02,
    required this.m10,
    required this.m11,
    required this.m12,
  }) {
    for (final value in <double>[m00, m01, m02, m10, m11, m12]) {
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'matrix value', 'must be finite');
      }
    }
  }

  factory AffineRasterTransform.identity() =>
      AffineRasterTransform(m00: 1, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0);

  factory AffineRasterTransform.translation(double x, double y) =>
      AffineRasterTransform(m00: 1, m01: 0, m02: x, m10: 0, m11: 1, m12: y);

  factory AffineRasterTransform.scale(
    double x,
    double y, {
    double originX = 0,
    double originY = 0,
  }) => AffineRasterTransform(
    m00: x,
    m01: 0,
    m02: originX * (1 - x),
    m10: 0,
    m11: y,
    m12: originY * (1 - y),
  );

  factory AffineRasterTransform.rotation(
    double radians, {
    double originX = 0,
    double originY = 0,
  }) {
    if (!radians.isFinite) {
      throw ArgumentError.value(radians, 'radians', 'must be finite');
    }
    final cosine = math.cos(radians);
    final sine = math.sin(radians);
    return AffineRasterTransform(
      m00: cosine,
      m01: -sine,
      m02: originX - cosine * originX + sine * originY,
      m10: sine,
      m11: cosine,
      m12: originY - sine * originX - cosine * originY,
    );
  }

  final double m00;
  final double m01;
  final double m02;
  final double m10;
  final double m11;
  final double m12;

  /// Determinant of the linear portion.
  double get determinant => m00 * m11 - m01 * m10;

  /// Maps an x coordinate without allocating a point object.
  double mapX(double x, double y) => m00 * x + m01 * y + m02;

  /// Maps a y coordinate without allocating a point object.
  double mapY(double x, double y) => m10 * x + m11 * y + m12;

  /// Returns a transform that applies this matrix and then [next].
  AffineRasterTransform followedBy(AffineRasterTransform next) =>
      AffineRasterTransform(
        m00: next.m00 * m00 + next.m01 * m10,
        m01: next.m00 * m01 + next.m01 * m11,
        m02: next.m00 * m02 + next.m01 * m12 + next.m02,
        m10: next.m10 * m00 + next.m11 * m10,
        m11: next.m10 * m01 + next.m11 * m11,
        m12: next.m10 * m02 + next.m11 * m12 + next.m12,
      );

  /// Returns the exact inverse, rejecting singular and near-singular matrices.
  AffineRasterTransform inverted() {
    final value = determinant;
    if (!value.isFinite || value.abs() <= 1e-12) {
      throw StateError('The raster transform is singular.');
    }
    final inverseDeterminant = 1 / value;
    final inverse00 = m11 * inverseDeterminant;
    final inverse01 = -m01 * inverseDeterminant;
    final inverse10 = -m10 * inverseDeterminant;
    final inverse11 = m00 * inverseDeterminant;
    return AffineRasterTransform(
      m00: inverse00,
      m01: inverse01,
      m02: -(inverse00 * m02 + inverse01 * m12),
      m10: inverse10,
      m11: inverse11,
      m12: -(inverse10 * m02 + inverse11 * m12),
    );
  }
}

/// Resamples a floating bitmap through [sourceToDestination].
///
/// Destination pixels are inverse-mapped to the source. Pixels outside the
/// source are transparent. Bilinear interpolation is performed directly in
/// premultiplied RGBA, avoiding dark/colored fringes around alpha edges.
RgbaBitmap resampleTransformedRgba({
  required RgbaBitmap source,
  required int destinationWidth,
  required int destinationHeight,
  required AffineRasterTransform sourceToDestination,
  required RasterSampling sampling,
}) {
  _checkPositiveExtent(destinationWidth, 'destinationWidth');
  _checkPositiveExtent(destinationHeight, 'destinationHeight');
  final destinationToSource = sourceToDestination.inverted();
  final sourcePixels = source.pixels;
  final output = Uint8List(destinationWidth * destinationHeight * 4);
  for (var y = 0; y < destinationHeight; y += 1) {
    for (var x = 0; x < destinationWidth; x += 1) {
      final sourceX = destinationToSource.mapX(x.toDouble(), y.toDouble());
      final sourceY = destinationToSource.mapY(x.toDouble(), y.toDouble());
      final outputOffset = (y * destinationWidth + x) * 4;
      switch (sampling) {
        case RasterSampling.nearest:
          _sampleNearest(
            sourcePixels,
            source.width,
            source.height,
            sourceX,
            sourceY,
            output,
            outputOffset,
          );
        case RasterSampling.bilinear:
          _sampleBilinear(
            sourcePixels,
            source.width,
            source.height,
            sourceX,
            sourceY,
            output,
            outputOffset,
          );
      }
    }
  }
  return RgbaBitmap.fromPremultipliedRgba(
    width: destinationWidth,
    height: destinationHeight,
    pixels: output,
  );
}

/// Resizes [source], aligning the outer pixel edges of source and destination.
RgbaBitmap resizeRgba({
  required RgbaBitmap source,
  required int width,
  required int height,
  required RasterSampling sampling,
}) {
  _checkPositiveExtent(width, 'width');
  _checkPositiveExtent(height, 'height');
  final scaleX = width / source.width;
  final scaleY = height / source.height;
  final transform = AffineRasterTransform(
    m00: scaleX,
    m01: 0,
    m02: (scaleX - 1) / 2,
    m10: 0,
    m11: scaleY,
    m12: (scaleY - 1) / 2,
  );
  return resampleTransformedRgba(
    source: source,
    destinationWidth: width,
    destinationHeight: height,
    sourceToDestination: transform,
    sampling: sampling,
  );
}

void _sampleNearest(
  Uint8List sourcePixels,
  int sourceWidth,
  int sourceHeight,
  double x,
  double y,
  Uint8List output,
  int outputOffset,
) {
  final nearestX = x.round();
  final nearestY = y.round();
  if (nearestX < 0 ||
      nearestX >= sourceWidth ||
      nearestY < 0 ||
      nearestY >= sourceHeight) {
    return;
  }
  final sourceOffset = (nearestY * sourceWidth + nearestX) * 4;
  output.setRange(outputOffset, outputOffset + 4, sourcePixels, sourceOffset);
}

void _sampleBilinear(
  Uint8List sourcePixels,
  int sourceWidth,
  int sourceHeight,
  double x,
  double y,
  Uint8List output,
  int outputOffset,
) {
  final left = x.floor();
  final top = y.floor();
  final fractionX = x - left;
  final fractionY = y - top;
  final topLeftWeight = (1 - fractionX) * (1 - fractionY);
  final topRightWeight = fractionX * (1 - fractionY);
  final bottomLeftWeight = (1 - fractionX) * fractionY;
  final bottomRightWeight = fractionX * fractionY;
  for (var channel = 0; channel < 4; channel += 1) {
    final value =
        _channelOrZero(
              sourcePixels,
              sourceWidth,
              sourceHeight,
              left,
              top,
              channel,
            ) *
            topLeftWeight +
        _channelOrZero(
              sourcePixels,
              sourceWidth,
              sourceHeight,
              left + 1,
              top,
              channel,
            ) *
            topRightWeight +
        _channelOrZero(
              sourcePixels,
              sourceWidth,
              sourceHeight,
              left,
              top + 1,
              channel,
            ) *
            bottomLeftWeight +
        _channelOrZero(
              sourcePixels,
              sourceWidth,
              sourceHeight,
              left + 1,
              top + 1,
              channel,
            ) *
            bottomRightWeight;
    output[outputOffset + channel] = value.round().clamp(0, 255);
  }
}

int _channelOrZero(
  Uint8List sourcePixels,
  int sourceWidth,
  int sourceHeight,
  int x,
  int y,
  int channel,
) {
  if (x < 0 || x >= sourceWidth || y < 0 || y >= sourceHeight) {
    return 0;
  }
  return sourcePixels[(y * sourceWidth + x) * 4 + channel];
}

void _checkPositiveExtent(int value, String name) {
  if (value <= 0) {
    throw RangeError.value(value, name, 'must be positive');
  }
}
