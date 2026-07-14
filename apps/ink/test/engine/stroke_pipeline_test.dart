import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/stroke_pipeline.dart';

void main() {
  group('StrokeSample', () {
    test('rejects invalid geometry, pressure, and time', () {
      expect(
        () => StrokeSample(
          point: const Offset(double.nan, 0),
          pressure: 0.5,
          tilt: Offset.zero,
          timestamp: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => StrokeSample(
          point: Offset.zero,
          pressure: 1.01,
          tilt: Offset.zero,
          timestamp: Duration.zero,
        ),
        throwsRangeError,
      );
      expect(
        () => StrokeSample(
          point: Offset.zero,
          pressure: 0.5,
          tilt: Offset.zero,
          timestamp: const Duration(microseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('value equality covers every recipe channel', () {
      final StrokeSample left = _sample(
        1.25,
        -3.5,
        pressure: 0.75,
        tilt: const Offset(0.2, -0.4),
        microseconds: 1234,
      );
      final StrokeSample equal = _sample(
        1.25,
        -3.5,
        pressure: 0.75,
        tilt: const Offset(0.2, -0.4),
        microseconds: 1234,
      );

      expect(left, equal);
      expect(left.hashCode, equal.hashCode);
      expect(left, isNot(_sample(1.25, -3.5, pressure: 0.7)));
    });
  });

  group('StrokeRecipeCodec', () {
    test('round-trips all six version-one fields exactly', () {
      final List<StrokeSample> samples = <StrokeSample>[
        _sample(
          1.25,
          -3.5,
          pressure: 0.75,
          tilt: const Offset(0.2, -0.4),
          microseconds: 1234,
        ),
        _sample(
          99.125,
          45.875,
          pressure: 0.125,
          tilt: const Offset(-1.1, 0.9),
          microseconds: 987654321,
        ),
      ];

      final Uint8List encoded = StrokeRecipeCodec.encode(samples);
      final List<StrokeSample> decoded = StrokeRecipeCodec.decode(encoded);

      expect(
        encoded.length,
        StrokeRecipeCodec.headerByteLength +
            samples.length * StrokeRecipeCodec.sampleByteLength,
      );
      expect(decoded, orderedEquals(samples));
      expect(() => decoded.add(_sample(0, 0)), throwsUnsupportedError);
    });

    test('encoding is deterministic and carries an INKS version header', () {
      final List<StrokeSample> samples = <StrokeSample>[
        _sample(4, 8, pressure: 0.25, microseconds: 12000),
      ];

      final Uint8List first = StrokeRecipeCodec.encode(samples);
      final Uint8List second = StrokeRecipeCodec.encode(samples);
      final ByteData header = ByteData.sublistView(first);

      expect(first, orderedEquals(second));
      expect(first.sublist(0, 4), <int>[0x49, 0x4e, 0x4b, 0x53]);
      expect(
        header.getUint16(4, Endian.little),
        StrokeRecipeCodec.currentVersion,
      );
      expect(
        header.getUint16(6, Endian.little),
        StrokeRecipeCodec.sampleByteLength,
      );
    });

    test('empty recipes retain a decodable version header', () {
      final Uint8List encoded = StrokeRecipeCodec.encode(
        const <StrokeSample>[],
      );

      expect(encoded.length, StrokeRecipeCodec.headerByteLength);
      expect(StrokeRecipeCodec.decode(encoded), isEmpty);
    });

    test('rejects bad magic, unknown versions, and unknown strides', () {
      final Uint8List badMagic = StrokeRecipeCodec.encode(<StrokeSample>[
        _sample(0, 0),
      ])..[0] = 0;
      final Uint8List badVersion = StrokeRecipeCodec.encode(<StrokeSample>[
        _sample(0, 0),
      ]);
      ByteData.sublistView(badVersion).setUint16(4, 99, Endian.little);
      final Uint8List badStride = StrokeRecipeCodec.encode(<StrokeSample>[
        _sample(0, 0),
      ]);
      ByteData.sublistView(badStride).setUint16(6, 40, Endian.little);

      expect(() => StrokeRecipeCodec.decode(badMagic), throwsFormatException);
      expect(() => StrokeRecipeCodec.decode(badVersion), throwsFormatException);
      expect(() => StrokeRecipeCodec.decode(badStride), throwsFormatException);
    });

    test('rejects truncated headers and sample payloads', () {
      final Uint8List valid = StrokeRecipeCodec.encode(<StrokeSample>[
        _sample(0, 0),
      ]);

      expect(
        () => StrokeRecipeCodec.decode(Uint8List(7)),
        throwsFormatException,
      );
      expect(
        () => StrokeRecipeCodec.decode(
          Uint8List.fromList(valid.sublist(0, valid.length - 1)),
        ),
        throwsFormatException,
      );
    });

    test('rejects non-normalized pressure in a corrupt payload', () {
      final Uint8List corrupt = StrokeRecipeCodec.encode(<StrokeSample>[
        _sample(0, 0),
      ]);
      ByteData.sublistView(
        corrupt,
      ).setFloat64(StrokeRecipeCodec.headerByteLength + 16, 2, Endian.little);

      expect(() => StrokeRecipeCodec.decode(corrupt), throwsFormatException);
    });
  });

  group('OneEuroFilter', () {
    test('keeps a constant signal exactly constant', () {
      final OneEuroFilter filter = OneEuroFilter(beta: 0.7);

      for (var index = 0; index < 20; index += 1) {
        expect(
          filter.filter(12.5, timestamp: Duration(milliseconds: index * 10)),
          12.5,
        );
      }
    });

    test('higher beta follows a fast step more closely', () {
      final OneEuroFilter smooth = OneEuroFilter(beta: 0);
      final OneEuroFilter responsive = OneEuroFilter(beta: 10);
      smooth.filter(0, timestamp: Duration.zero);
      responsive.filter(0, timestamp: Duration.zero);

      final double smoothStep = smooth.filter(
        1,
        timestamp: const Duration(milliseconds: 10),
      );
      final double responsiveStep = responsive.filter(
        1,
        timestamp: const Duration(milliseconds: 10),
      );

      expect(smoothStep, greaterThan(0));
      expect(smoothStep, lessThan(1));
      expect(responsiveStep, greaterThan(smoothStep));
      expect(responsiveStep, lessThan(1));
    });

    test('equal timestamps use nominal frequency deterministically', () {
      final OneEuroFilter first = OneEuroFilter(beta: 0.5);
      final OneEuroFilter second = OneEuroFilter(beta: 0.5);

      final List<double> left = <double>[
        first.filter(0, timestamp: Duration.zero),
        first.filter(1, timestamp: Duration.zero),
        first.filter(2, timestamp: const Duration(milliseconds: 10)),
      ];
      final List<double> right = <double>[
        second.filter(0, timestamp: Duration.zero),
        second.filter(1, timestamp: Duration.zero),
        second.filter(2, timestamp: const Duration(milliseconds: 10)),
      ];

      expect(left, orderedEquals(right));
    });

    test('rejects backwards timestamps and reset accepts a new epoch', () {
      final OneEuroFilter filter = OneEuroFilter();
      filter.filter(1, timestamp: const Duration(milliseconds: 10));

      expect(
        () => filter.filter(2, timestamp: const Duration(milliseconds: 9)),
        throwsStateError,
      );
      filter.reset();
      expect(filter.hasValue, isFalse);
      expect(filter.filter(2, timestamp: Duration.zero), 2);
    });
  });

  group('OneEuroStrokeResampler', () {
    test('smooths position, pressure, and tilt with one timestamp', () {
      final OneEuroStrokeResampler resampler = OneEuroStrokeResampler(beta: 0);
      final StrokeSample first = resampler.filter(
        _sample(0, 0, pressure: 0, tilt: Offset.zero),
      );
      final StrokeSample second = resampler.filter(
        _sample(
          10,
          -10,
          pressure: 1,
          tilt: const Offset(1, -1),
          microseconds: 10000,
        ),
      );

      expect(first, _sample(0, 0, pressure: 0, tilt: Offset.zero));
      expect(second.point.dx, inExclusiveRange(0, 10));
      expect(second.point.dy, inExclusiveRange(-10, 0));
      expect(second.pressure, inExclusiveRange(0, 1));
      expect(second.tilt.dx, inExclusiveRange(0, 1));
      expect(second.tilt.dy, inExclusiveRange(-1, 0));
    });
  });

  group('CatmullRomPathFitter', () {
    test('emits origin immediately and holds one sample for look-ahead', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter();

      expect(fitter.add(_sample(0, 0)), hasLength(1));
      expect(fitter.add(_sample(10, 0, microseconds: 10000)), isEmpty);
      expect(fitter.add(_sample(20, 0, microseconds: 20000)), isNotEmpty);
    });

    test('straight paths are arc-spaced and retain the exact endpoint', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter(
        maxSegmentLength: 1.5,
      );
      final List<FittedStrokeSample> fitted = <FittedStrokeSample>[
        ...fitter.add(_sample(0, 0)),
        ...fitter.add(_sample(10, 0, microseconds: 10000)),
        ...fitter.finish(),
      ];

      expect(fitted.first.point, Offset.zero);
      expect(fitted.last.point, const Offset(10, 0));
      expect(fitted.last.arcLength, closeTo(10, 1e-9));
      expect(
        fitted.map((FittedStrokeSample value) => value.arcLength),
        orderedEquals(<double>[0, 1.5, 3, 4.5, 6, 7.5, 9, 10]),
      );
    });

    test('every fitted curve chord is at most 1.5 document pixels', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter();
      final List<FittedStrokeSample> fitted = <FittedStrokeSample>[];
      final List<StrokeSample> controls = <StrokeSample>[
        _sample(0, 0),
        _sample(8, 20, microseconds: 10000),
        _sample(16, -15, microseconds: 20000),
        _sample(24, 25, microseconds: 30000),
        _sample(32, 0, microseconds: 40000),
      ];
      for (final StrokeSample control in controls) {
        fitted.addAll(fitter.add(control));
      }
      fitted.addAll(fitter.finish());

      for (var index = 1; index < fitted.length; index += 1) {
        expect(
          (fitted[index].point - fitted[index - 1].point).distance,
          lessThanOrEqualTo(1.5 + 1e-9),
          reason: 'segment $index',
        );
        expect(
          fitted[index].arcLength,
          greaterThanOrEqualTo(fitted[index - 1].arcLength),
        );
      }
      expect(fitted.last.point, controls.last.point);
    });

    test('Catmull-Rom bends between non-collinear controls', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter(
        maxSegmentLength: 0.75,
      );
      final List<FittedStrokeSample> fitted = <FittedStrokeSample>[];
      for (final StrokeSample control in <StrokeSample>[
        _sample(0, 0),
        _sample(10, 10, microseconds: 10000),
        _sample(20, 0, microseconds: 20000),
        _sample(30, 10, microseconds: 30000),
      ]) {
        fitted.addAll(fitter.add(control));
      }
      fitted.addAll(fitter.finish());

      expect(
        fitted.any(
          (FittedStrokeSample value) =>
              value.point.dx > 10 &&
              value.point.dx < 20 &&
              value.point.dy > 0 &&
              value.point.dy < 10,
        ),
        isTrue,
      );
    });

    test('interpolates pressure, tilt, and timestamps monotonically', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter(
        maxSegmentLength: 1,
      );
      final List<FittedStrokeSample> fitted = <FittedStrokeSample>[
        ...fitter.add(_sample(0, 0, pressure: 0, tilt: Offset.zero)),
        ...fitter.add(
          _sample(
            10,
            0,
            pressure: 1,
            tilt: const Offset(0.5, -0.5),
            microseconds: 10000,
          ),
        ),
        ...fitter.finish(),
      ];

      for (var index = 1; index < fitted.length; index += 1) {
        expect(fitted[index].pressure, inInclusiveRange(0, 1));
        expect(
          fitted[index].timestamp,
          greaterThanOrEqualTo(fitted[index - 1].timestamp),
        );
      }
      expect(fitted.last.pressure, 1);
      expect(fitted.last.tilt, const Offset(0.5, -0.5));
      expect(fitted.last.timestamp, const Duration(milliseconds: 10));
    });

    test('stationary pressure changes survive finalization', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter();
      final List<FittedStrokeSample> fitted = <FittedStrokeSample>[
        ...fitter.add(_sample(2, 3, pressure: 0.1)),
        ...fitter.add(_sample(2, 3, pressure: 0.9, microseconds: 10000)),
        ...fitter.finish(),
      ];

      expect(fitted, hasLength(2));
      expect(fitted.last.point, const Offset(2, 3));
      expect(fitted.last.pressure, 0.9);
      expect(fitted.last.arcLength, 0);
    });

    test('reset makes a finished fitter reusable', () {
      final CatmullRomPathFitter fitter = CatmullRomPathFitter();
      fitter.add(_sample(0, 0));
      fitter.finish();
      expect(() => fitter.add(_sample(1, 1)), throwsStateError);

      fitter.reset();

      expect(fitter.isFinished, isFalse);
      expect(fitter.isEmpty, isTrue);
      expect(fitter.add(_sample(5, 5)).single.point, const Offset(5, 5));
    });
  });

  group('StrokePipeline', () {
    test('orchestrates origin, incremental path, and one final callback', () {
      final List<_PathDelivery> deliveries = <_PathDelivery>[];
      final StrokePipeline pipeline = StrokePipeline(
        smoothing: 0,
        onPath: (List<FittedStrokeSample> samples, {required bool isFinal}) {
          deliveries.add(_PathDelivery(samples: samples, isFinal: isFinal));
        },
      );

      pipeline.begin(_sample(0, 0));
      pipeline.add(_sample(10, 0, microseconds: 10000));
      pipeline.add(_sample(20, 0, microseconds: 20000));
      pipeline.end();

      expect(deliveries.first.samples.single.point, Offset.zero);
      expect(deliveries.first.isFinal, isFalse);
      expect(
        deliveries.where((_PathDelivery value) => value.isFinal),
        hasLength(1),
      );
      expect(deliveries.last.isFinal, isTrue);
      expect(deliveries.last.samples.last.point.dx, closeTo(20, 1e-9));
      expect(pipeline.isActive, isFalse);
    });

    test('retains raw recipe samples rather than smoothed samples', () {
      final StrokePipeline pipeline = StrokePipeline(
        smoothing: 0,
        onPath: (_, {required bool isFinal}) {},
      );
      final List<StrokeSample> raw = <StrokeSample>[
        _sample(0, 0),
        _sample(100, 50, pressure: 1, microseconds: 10000),
      ];

      pipeline.begin(raw.first);
      pipeline.end(sample: raw.last);

      expect(pipeline.inputSamples, orderedEquals(raw));
      expect(
        StrokeRecipeCodec.decode(pipeline.encodeRecipe()),
        orderedEquals(raw),
      );
    });

    test('enforces lifecycle and cancel removes an abandoned recipe', () {
      var callbacks = 0;
      final StrokePipeline pipeline = StrokePipeline(
        onPath: (_, {required bool isFinal}) => callbacks += 1,
      );

      expect(() => pipeline.add(_sample(0, 0)), throwsStateError);
      expect(() => pipeline.end(), throwsStateError);
      pipeline.begin(_sample(0, 0));
      expect(() => pipeline.begin(_sample(1, 1)), throwsStateError);
      pipeline.cancel();

      expect(callbacks, 1);
      expect(pipeline.isActive, isFalse);
      expect(pipeline.inputSamples, isEmpty);
      expect(StrokeRecipeCodec.decode(pipeline.encodeRecipe()), isEmpty);
    });

    test('identical input and settings produce identical fitted output', () {
      final List<StrokeSample> input = <StrokeSample>[
        _sample(0, 0),
        _sample(5, 8, pressure: 0.2, microseconds: 10000),
        _sample(12, 2, pressure: 0.8, microseconds: 20000),
        _sample(20, 10, pressure: 0.5, microseconds: 30000),
      ];

      final List<String> first = _runPipeline(input);
      final List<String> second = _runPipeline(input);

      expect(first, orderedEquals(second));
    });
  });
}

StrokeSample _sample(
  double x,
  double y, {
  double pressure = 0.5,
  Offset tilt = Offset.zero,
  int microseconds = 0,
}) => StrokeSample(
  point: Offset(x, y),
  pressure: pressure,
  tilt: tilt,
  timestamp: Duration(microseconds: microseconds),
);

List<String> _runPipeline(List<StrokeSample> input) {
  final List<String> output = <String>[];
  final StrokePipeline pipeline = StrokePipeline(
    onPath: (List<FittedStrokeSample> samples, {required bool isFinal}) {
      for (final FittedStrokeSample sample in samples) {
        output.add(
          '${sample.point.dx},${sample.point.dy},${sample.pressure},'
          '${sample.arcLength},${sample.timestamp.inMicroseconds},$isFinal',
        );
      }
      if (samples.isEmpty) {
        output.add('empty,$isFinal');
      }
    },
  );
  pipeline.begin(input.first);
  for (final StrokeSample sample in input.skip(1)) {
    pipeline.add(sample);
  }
  pipeline.end();
  return output;
}

final class _PathDelivery {
  const _PathDelivery({required this.samples, required this.isFinal});

  final List<FittedStrokeSample> samples;
  final bool isFinal;
}
