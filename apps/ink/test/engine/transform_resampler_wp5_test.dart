import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/raster_ops.dart';
import 'package:paper_ink/src/engine/transform_resampler.dart';

void main() {
  group('AffineRasterTransform', () {
    test('inverse round-trips a general affine point', () {
      final transform = AffineRasterTransform(
        m00: 2,
        m01: 0.25,
        m02: 5,
        m10: -0.5,
        m11: 3,
        m12: -7,
      );
      final mappedX = transform.mapX(4, 6);
      final mappedY = transform.mapY(4, 6);
      final inverse = transform.inverted();

      expect(inverse.mapX(mappedX, mappedY), closeTo(4, 1e-10));
      expect(inverse.mapY(mappedX, mappedY), closeTo(6, 1e-10));
    });

    test('followedBy applies transforms in named order', () {
      final transform = AffineRasterTransform.translation(
        3,
        4,
      ).followedBy(AffineRasterTransform.scale(2, 3));

      expect(transform.mapX(1, 2), 8);
      expect(transform.mapY(1, 2), 18);
    });

    test('rotation honors a non-origin pivot', () {
      final transform = AffineRasterTransform.rotation(
        math.pi / 2,
        originX: 2,
        originY: 3,
      );

      expect(transform.mapX(3, 3), closeTo(2, 1e-12));
      expect(transform.mapY(3, 3), closeTo(4, 1e-12));
    });

    test('singular transforms are rejected', () {
      final singular = AffineRasterTransform.scale(0, 1);

      expect(singular.inverted, throwsStateError);
    });

    test('non-finite transform entries are rejected', () {
      expect(
        () => AffineRasterTransform.translation(double.nan, 0),
        throwsArgumentError,
      );
    });
  });

  group('float RGBA resampling', () {
    test('nearest identity preserves exact premultiplied bytes', () {
      final source = _twoColorSource();
      final result = resampleTransformedRgba(
        source: source,
        destinationWidth: 2,
        destinationHeight: 1,
        sourceToDestination: AffineRasterTransform.identity(),
        sampling: RasterSampling.nearest,
      );

      expect(result.pixels, source.pixels);
    });

    test('bilinear identity preserves exact premultiplied bytes', () {
      final source = _twoColorSource();
      final result = resampleTransformedRgba(
        source: source,
        destinationWidth: 2,
        destinationHeight: 1,
        sourceToDestination: AffineRasterTransform.identity(),
        sampling: RasterSampling.bilinear,
      );

      expect(result.pixels, source.pixels);
    });

    test('translation leaves transparent pixels outside the float', () {
      final result = resampleTransformedRgba(
        source: _twoColorSource(),
        destinationWidth: 3,
        destinationHeight: 1,
        sourceToDestination: AffineRasterTransform.translation(1, 0),
        sampling: RasterSampling.nearest,
      );

      expect(result.colorAt(0, 0), RgbaColor.transparent);
      expect(result.colorAt(1, 0), _red);
      expect(result.colorAt(2, 0), _blue);
    });

    test('nearest resize replicates source pixels during drag', () {
      final result = resizeRgba(
        source: _twoColorSource(),
        width: 4,
        height: 1,
        sampling: RasterSampling.nearest,
      );

      expect(
        <RgbaColor>[for (var x = 0; x < 4; x += 1) result.colorAt(x, 0)],
        <RgbaColor>[_red, _red, _blue, _blue],
      );
    });

    test('bilinear resize interpolates at rest', () {
      final result = resizeRgba(
        source: _twoColorSource(),
        width: 3,
        height: 1,
        sampling: RasterSampling.bilinear,
      );

      expect(result.pixels.sublist(4, 8), <int>[128, 0, 128, 255]);
    });

    test('bilinear alpha interpolation avoids dark color fringes', () {
      final source = RgbaBitmap.fromColors(
        width: 2,
        height: 1,
        colors: <RgbaColor>[_red, RgbaColor.transparent],
      );
      final result = resizeRgba(
        source: source,
        width: 3,
        height: 1,
        sampling: RasterSampling.bilinear,
      );

      expect(result.pixels.sublist(4, 8), <int>[128, 0, 0, 128]);
      expect(
        result.colorAt(1, 0),
        RgbaColor(red: 255, green: 0, blue: 0, alpha: 128),
      );
    });

    test('quarter-turn rotation maps the full source vertically', () {
      final result = resampleTransformedRgba(
        source: _twoColorSource(),
        destinationWidth: 1,
        destinationHeight: 2,
        sourceToDestination: AffineRasterTransform.rotation(math.pi / 2),
        sampling: RasterSampling.nearest,
      );

      expect(result.colorAt(0, 0), _red);
      expect(result.colorAt(0, 1), _blue);
    });

    test('invalid destination extents are rejected', () {
      expect(
        () => resizeRgba(
          source: _twoColorSource(),
          width: 0,
          height: 1,
          sampling: RasterSampling.nearest,
        ),
        throwsRangeError,
      );
    });
  });
}

RgbaBitmap _twoColorSource() => RgbaBitmap.fromColors(
  width: 2,
  height: 1,
  colors: <RgbaColor>[_red, _blue],
);

final RgbaColor _red = RgbaColor(red: 255, green: 0, blue: 0);
final RgbaColor _blue = RgbaColor(red: 0, green: 0, blue: 255);
