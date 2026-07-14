import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// One document-space input sample retained in a deterministic stroke recipe.
final class StrokeSample {
  /// Creates a normalized input sample.
  StrokeSample({
    required this.point,
    required this.pressure,
    required this.tilt,
    required this.timestamp,
  }) {
    _checkOffset(point, 'point');
    if (!pressure.isFinite || pressure < 0 || pressure > 1) {
      throw RangeError.range(pressure, 0, 1, 'pressure');
    }
    _checkOffset(tilt, 'tilt');
    if (timestamp.isNegative) {
      throw ArgumentError.value(timestamp, 'timestamp', 'must not be negative');
    }
    if (timestamp.inMicroseconds > _maximumInt64) {
      throw ArgumentError.value(
        timestamp,
        'timestamp',
        'must fit a signed 64-bit microsecond value',
      );
    }
  }

  /// Full-precision position in document pixels.
  final Offset point;

  /// Normalized pressure from zero through one.
  final double pressure;

  /// Pen tilt in radians on the x and y axes.
  final Offset tilt;

  /// Monotonic input timestamp.
  final Duration timestamp;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrokeSample &&
          point == other.point &&
          pressure == other.pressure &&
          tilt == other.tilt &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(point, pressure, tilt, timestamp);

  @override
  String toString() =>
      'StrokeSample(point: $point, pressure: $pressure, tilt: $tilt, '
      'timestamp: $timestamp)';
}

/// One arc-length-positioned sample emitted by [CatmullRomPathFitter].
final class FittedStrokeSample {
  /// Creates a fitted sample at [arcLength] document pixels from stroke start.
  FittedStrokeSample({required this.sample, required this.arcLength}) {
    if (!arcLength.isFinite || arcLength < 0) {
      throw ArgumentError.value(
        arcLength,
        'arcLength',
        'must be finite and non-negative',
      );
    }
  }

  /// Interpolated stroke data at this fitted position.
  final StrokeSample sample;

  /// Approximate cumulative curve length in document pixels.
  final double arcLength;

  /// Convenience access to [StrokeSample.point].
  Offset get point => sample.point;

  /// Convenience access to [StrokeSample.pressure].
  double get pressure => sample.pressure;

  /// Convenience access to [StrokeSample.tilt].
  Offset get tilt => sample.tilt;

  /// Convenience access to [StrokeSample.timestamp].
  Duration get timestamp => sample.timestamp;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FittedStrokeSample &&
          sample == other.sample &&
          arcLength == other.arcLength;

  @override
  int get hashCode => Object.hash(sample, arcLength);
}

/// Versioned binary codec for deterministic stroke-recipe samples.
///
/// The payload starts with an eight-byte `INKS` header containing a little-
/// endian version and stride. Version 1 stores exactly 48 bytes per sample:
/// five float64 values (x, y, pressure, tilt x, tilt y), followed by one
/// signed int64 timestamp in microseconds.
final class StrokeRecipeCodec {
  const StrokeRecipeCodec._();

  /// Version written by [encode].
  static const int currentVersion = 1;

  /// Byte size of the magic, version, and stride header.
  static const int headerByteLength = 8;

  /// Byte size of one version-1 sample.
  static const int sampleByteLength = 48;

  static const List<int> _magic = <int>[0x49, 0x4e, 0x4b, 0x53];

  /// Encodes [samples] into the current deterministic little-endian format.
  static Uint8List encode(Iterable<StrokeSample> samples) {
    final List<StrokeSample> values = samples.toList(growable: false);
    final Uint8List bytes = Uint8List(
      headerByteLength + values.length * sampleByteLength,
    );
    bytes.setRange(0, _magic.length, _magic);
    final ByteData data = ByteData.sublistView(bytes);
    data.setUint16(4, currentVersion, Endian.little);
    data.setUint16(6, sampleByteLength, Endian.little);
    for (var index = 0; index < values.length; index += 1) {
      final int offset = headerByteLength + index * sampleByteLength;
      final StrokeSample sample = values[index];
      data.setFloat64(offset, sample.point.dx, Endian.little);
      data.setFloat64(offset + 8, sample.point.dy, Endian.little);
      data.setFloat64(offset + 16, sample.pressure, Endian.little);
      data.setFloat64(offset + 24, sample.tilt.dx, Endian.little);
      data.setFloat64(offset + 32, sample.tilt.dy, Endian.little);
      data.setInt64(
        offset + 40,
        sample.timestamp.inMicroseconds,
        Endian.little,
      );
    }
    return bytes;
  }

  /// Decodes a recipe payload, rejecting unknown versions and malformed data.
  static List<StrokeSample> decode(Uint8List bytes) {
    if (bytes.lengthInBytes < headerByteLength) {
      throw const FormatException('Stroke recipe header is truncated.');
    }
    for (var index = 0; index < _magic.length; index += 1) {
      if (bytes[index] != _magic[index]) {
        throw const FormatException('Stroke recipe magic is invalid.');
      }
    }
    final ByteData data = ByteData.sublistView(bytes);
    final int version = data.getUint16(4, Endian.little);
    if (version != currentVersion) {
      throw FormatException('Unsupported stroke recipe version $version.');
    }
    final int stride = data.getUint16(6, Endian.little);
    if (stride != sampleByteLength) {
      throw FormatException('Unsupported stroke recipe stride $stride.');
    }
    final int payloadLength = bytes.lengthInBytes - headerByteLength;
    if (payloadLength % stride != 0) {
      throw const FormatException('Stroke recipe sample payload is truncated.');
    }
    final int count = payloadLength ~/ stride;
    final List<StrokeSample> result = <StrokeSample>[];
    for (var index = 0; index < count; index += 1) {
      final int offset = headerByteLength + index * stride;
      try {
        result.add(
          StrokeSample(
            point: Offset(
              data.getFloat64(offset, Endian.little),
              data.getFloat64(offset + 8, Endian.little),
            ),
            pressure: data.getFloat64(offset + 16, Endian.little),
            tilt: Offset(
              data.getFloat64(offset + 24, Endian.little),
              data.getFloat64(offset + 32, Endian.little),
            ),
            timestamp: Duration(
              microseconds: data.getInt64(offset + 40, Endian.little),
            ),
          ),
        );
      } on ArgumentError catch (error) {
        throw FormatException('Invalid stroke recipe sample $index.', error);
      }
    }
    return List<StrokeSample>.unmodifiable(result);
  }
}

/// Canonical scalar One-Euro low-pass filter with timestamp-derived frequency.
final class OneEuroFilter {
  /// Creates a One-Euro filter.
  OneEuroFilter({
    this.minCutoff = 1,
    this.beta = 0,
    this.derivativeCutoff = 1,
    this.nominalFrequency = 120,
  }) {
    _checkPositive(minCutoff, 'minCutoff');
    if (!beta.isFinite || beta < 0) {
      throw ArgumentError.value(
        beta,
        'beta',
        'must be finite and non-negative',
      );
    }
    _checkPositive(derivativeCutoff, 'derivativeCutoff');
    _checkPositive(nominalFrequency, 'nominalFrequency');
  }

  /// Base signal cutoff in hertz.
  final double minCutoff;

  /// Speed coefficient that reduces smoothing during fast movement.
  final double beta;

  /// Derivative low-pass cutoff in hertz.
  final double derivativeCutoff;

  /// Frequency used when two successive samples share a timestamp.
  final double nominalFrequency;

  double? _previousRaw;
  double? _previousFiltered;
  double? _previousDerivative;
  Duration? _previousTimestamp;

  /// Whether at least one value has initialized this filter.
  bool get hasValue => _previousFiltered != null;

  /// Most recently filtered value, or null before the first sample.
  double? get value => _previousFiltered;

  /// Filters [input] at the monotonic [timestamp].
  double filter(double input, {required Duration timestamp}) {
    if (!input.isFinite) {
      throw ArgumentError.value(input, 'input', 'must be finite');
    }
    if (timestamp.isNegative) {
      throw ArgumentError.value(timestamp, 'timestamp', 'must not be negative');
    }
    final Duration? previousTimestamp = _previousTimestamp;
    if (previousTimestamp == null) {
      _previousRaw = input;
      _previousFiltered = input;
      _previousDerivative = 0;
      _previousTimestamp = timestamp;
      return input;
    }
    if (timestamp < previousTimestamp) {
      throw StateError('One-Euro timestamps must be monotonic.');
    }
    final int elapsedMicroseconds =
        timestamp.inMicroseconds - previousTimestamp.inMicroseconds;
    final double elapsedSeconds = elapsedMicroseconds == 0
        ? 1 / nominalFrequency
        : elapsedMicroseconds / Duration.microsecondsPerSecond;
    final double derivative = (input - _previousRaw!) / elapsedSeconds;
    final double filteredDerivative = _lowPass(
      derivative,
      _previousDerivative!,
      _alpha(elapsedSeconds, derivativeCutoff),
    );
    final double cutoff = minCutoff + beta * filteredDerivative.abs();
    final double filtered = _lowPass(
      input,
      _previousFiltered!,
      _alpha(elapsedSeconds, cutoff),
    );
    _previousRaw = input;
    _previousFiltered = filtered;
    _previousDerivative = filteredDerivative;
    _previousTimestamp = timestamp;
    return filtered;
  }

  /// Returns this filter to its uninitialized state.
  void reset() {
    _previousRaw = null;
    _previousFiltered = null;
    _previousDerivative = null;
    _previousTimestamp = null;
  }
}

/// Applies matching One-Euro filters to every continuous stroke channel.
final class OneEuroStrokeResampler {
  /// Creates a document-space stroke resampler.
  OneEuroStrokeResampler({
    double minCutoff = 1,
    double beta = 0,
    double derivativeCutoff = 1,
    double nominalFrequency = 120,
  }) : _x = OneEuroFilter(
         minCutoff: minCutoff,
         beta: beta,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       ),
       _y = OneEuroFilter(
         minCutoff: minCutoff,
         beta: beta,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       ),
       _pressure = OneEuroFilter(
         minCutoff: minCutoff,
         beta: beta,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       ),
       _tiltX = OneEuroFilter(
         minCutoff: minCutoff,
         beta: beta,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       ),
       _tiltY = OneEuroFilter(
         minCutoff: minCutoff,
         beta: beta,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       );

  final OneEuroFilter _x;
  final OneEuroFilter _y;
  final OneEuroFilter _pressure;
  final OneEuroFilter _tiltX;
  final OneEuroFilter _tiltY;

  /// Smooths one input while preserving its timestamp.
  StrokeSample filter(StrokeSample sample) => StrokeSample(
    point: Offset(
      _x.filter(sample.point.dx, timestamp: sample.timestamp),
      _y.filter(sample.point.dy, timestamp: sample.timestamp),
    ),
    pressure: _pressure
        .filter(sample.pressure, timestamp: sample.timestamp)
        .clamp(0.0, 1.0),
    tilt: Offset(
      _tiltX.filter(sample.tilt.dx, timestamp: sample.timestamp),
      _tiltY.filter(sample.tilt.dy, timestamp: sample.timestamp),
    ),
    timestamp: sample.timestamp,
  );

  /// Clears every channel filter.
  void reset() {
    _x.reset();
    _y.reset();
    _pressure.reset();
    _tiltX.reset();
    _tiltY.reset();
  }
}

/// Incrementally fits uniform Catmull-Rom curves and emits arc-spaced samples.
final class CatmullRomPathFitter {
  /// Creates a path fitter whose output chords never exceed
  /// [maxSegmentLength] document pixels.
  CatmullRomPathFitter({
    this.maxSegmentLength = 1.5,
    this.flatnessTolerance = 0.05,
  }) {
    _checkPositive(maxSegmentLength, 'maxSegmentLength');
    _checkPositive(flatnessTolerance, 'flatnessTolerance');
  }

  /// Maximum approximate arc interval between emitted samples.
  final double maxSegmentLength;

  /// Maximum Bezier control-polygon deviation used while flattening curves.
  final double flatnessTolerance;

  final List<StrokeSample> _controls = <StrokeSample>[];
  var _nextCurve = 0;
  var _finished = false;
  FittedStrokeSample? _lastEmitted;
  StrokeSample? _traversalSample;
  var _traversalArcLength = 0.0;

  /// Whether no control sample has been added.
  bool get isEmpty => _controls.isEmpty;

  /// Whether [finish] has closed this fitter.
  bool get isFinished => _finished;

  /// Adds one smoothed control sample and returns newly fitted path samples.
  ///
  /// The first call emits the stroke origin immediately. A curve is otherwise
  /// held until one look-ahead control is available; [finish] emits the final
  /// endpoint using a duplicated tail control.
  List<FittedStrokeSample> add(StrokeSample sample) {
    if (_finished) {
      throw StateError(
        'A finished CatmullRomPathFitter cannot accept samples.',
      );
    }
    if (_controls.isNotEmpty && sample.timestamp < _controls.last.timestamp) {
      throw StateError('Stroke sample timestamps must be monotonic.');
    }
    _controls.add(sample);
    if (_controls.length == 1) {
      final FittedStrokeSample initial = FittedStrokeSample(
        sample: sample,
        arcLength: 0,
      );
      _lastEmitted = initial;
      _traversalSample = sample;
      return List<FittedStrokeSample>.unmodifiable(<FittedStrokeSample>[
        initial,
      ]);
    }
    final List<FittedStrokeSample> output = <FittedStrokeSample>[];
    while (_nextCurve + 2 < _controls.length) {
      _appendCurve(
        curve: _nextCurve,
        tail: _controls[_nextCurve + 2],
        output: output,
      );
      _nextCurve += 1;
    }
    return List<FittedStrokeSample>.unmodifiable(output);
  }

  /// Emits the held Catmull-Rom tail and closes this fitter.
  ///
  /// When upstream smoothing is active, [endpoint] preserves the unsmoothed
  /// terminal sample. The remaining distance is arc-spaced before the exact
  /// endpoint is flushed.
  List<FittedStrokeSample> finish({StrokeSample? endpoint}) {
    if (_finished) {
      return const <FittedStrokeSample>[];
    }
    final List<FittedStrokeSample> output = <FittedStrokeSample>[];
    while (_nextCurve + 1 < _controls.length) {
      final StrokeSample end = _controls[_nextCurve + 1];
      final StrokeSample tail = _nextCurve + 2 < _controls.length
          ? _controls[_nextCurve + 2]
          : end;
      _appendCurve(curve: _nextCurve, tail: tail, output: output);
      _nextCurve += 1;
    }
    if (_controls.isNotEmpty) {
      final StrokeSample actualEndpoint = endpoint ?? _controls.last;
      final StrokeSample? traversalSample = _traversalSample;
      if (traversalSample != null && traversalSample != actualEndpoint) {
        _consumeLine(traversalSample, actualEndpoint, output);
      }
      _flushEndpoint(actualEndpoint, output);
    }
    _finished = true;
    return List<FittedStrokeSample>.unmodifiable(output);
  }

  /// Clears all controls and output state for a new stroke.
  void reset() {
    _controls.clear();
    _nextCurve = 0;
    _finished = false;
    _lastEmitted = null;
    _traversalSample = null;
    _traversalArcLength = 0;
  }

  void _appendCurve({
    required int curve,
    required StrokeSample tail,
    required List<FittedStrokeSample> output,
  }) {
    final StrokeSample p0 = curve == 0 ? _controls.first : _controls[curve - 1];
    final StrokeSample p1 = _controls[curve];
    final StrokeSample p2 = _controls[curve + 1];
    final Offset b0 = p1.point;
    final Offset b1 = p1.point + (p2.point - p0.point) / 6;
    final Offset b2 = p2.point - (tail.point - p1.point) / 6;
    final Offset b3 = p2.point;
    final List<StrokeSample> flattened = <StrokeSample>[p1];
    _flattenBezier(
      b0: b0,
      b1: b1,
      b2: b2,
      b3: b3,
      t0: 0,
      t1: 1,
      start: p1,
      end: p2,
      depth: 0,
      output: flattened,
    );
    for (var index = 1; index < flattened.length; index += 1) {
      _consumeLine(flattened[index - 1], flattened[index], output);
    }
  }

  void _flattenBezier({
    required Offset b0,
    required Offset b1,
    required Offset b2,
    required Offset b3,
    required double t0,
    required double t1,
    required StrokeSample start,
    required StrokeSample end,
    required int depth,
    required List<StrokeSample> output,
  }) {
    final double chord = (b3 - b0).distance;
    final double controlLength =
        (b1 - b0).distance + (b2 - b1).distance + (b3 - b2).distance;
    final double deviation = math.max(
      _distanceToLine(b1, b0, b3),
      _distanceToLine(b2, b0, b3),
    );
    if (depth >= 20 ||
        deviation <= flatnessTolerance &&
            controlLength - chord <= flatnessTolerance) {
      output.add(_interpolateSample(start, end, t1, point: b3));
      return;
    }

    final Offset q0 = Offset.lerp(b0, b1, 0.5)!;
    final Offset q1 = Offset.lerp(b1, b2, 0.5)!;
    final Offset q2 = Offset.lerp(b2, b3, 0.5)!;
    final Offset r0 = Offset.lerp(q0, q1, 0.5)!;
    final Offset r1 = Offset.lerp(q1, q2, 0.5)!;
    final Offset split = Offset.lerp(r0, r1, 0.5)!;
    final double middleT = (t0 + t1) / 2;
    _flattenBezier(
      b0: b0,
      b1: q0,
      b2: r0,
      b3: split,
      t0: t0,
      t1: middleT,
      start: start,
      end: end,
      depth: depth + 1,
      output: output,
    );
    _flattenBezier(
      b0: split,
      b1: r1,
      b2: q2,
      b3: b3,
      t0: middleT,
      t1: t1,
      start: start,
      end: end,
      depth: depth + 1,
      output: output,
    );
  }

  void _consumeLine(
    StrokeSample from,
    StrokeSample to,
    List<FittedStrokeSample> output,
  ) {
    var current = from;
    var currentArc = _traversalArcLength;
    var remaining = (to.point - current.point).distance;
    if (remaining <= _geometryEpsilon) {
      _traversalSample = to;
      return;
    }
    while (true) {
      final double sinceLast = currentArc - _lastEmitted!.arcLength;
      final double needed = maxSegmentLength - sinceLast;
      if (remaining + _geometryEpsilon < needed) {
        break;
      }
      final double fraction = (needed / remaining).clamp(0.0, 1.0);
      final StrokeSample next = _interpolateSample(current, to, fraction);
      currentArc += needed;
      final FittedStrokeSample fitted = FittedStrokeSample(
        sample: next,
        arcLength: currentArc,
      );
      output.add(fitted);
      _lastEmitted = fitted;
      current = next;
      remaining = (to.point - current.point).distance;
      if (remaining <= _geometryEpsilon) {
        break;
      }
    }
    currentArc += remaining;
    _traversalArcLength = currentArc;
    _traversalSample = to;
  }

  void _flushEndpoint(StrokeSample endpoint, List<FittedStrokeSample> output) {
    final FittedStrokeSample? previous = _lastEmitted;
    if (previous == null) {
      return;
    }
    if (_traversalArcLength - previous.arcLength > _geometryEpsilon ||
        endpoint != previous.sample) {
      final FittedStrokeSample fitted = FittedStrokeSample(
        sample: endpoint,
        arcLength: _traversalArcLength,
      );
      output.add(fitted);
      _lastEmitted = fitted;
    }
  }
}

/// Synchronous handoff from [StrokePipeline] to a stateful brush stamper.
///
/// Each delivery contains only newly fitted samples. The initial delivery has
/// one sample at arc length zero; an empty final delivery is valid and lets a
/// brush finalize a one-point stroke or taper tail.
typedef StrokePathSink =
    void Function(List<FittedStrokeSample> samples, {required bool isFinal});

/// Owns one active stroke's smoothing, curve fitting, and brush handoff.
final class StrokePipeline {
  /// Creates a reusable pipeline.
  ///
  /// [smoothing] is the One-Euro beta selected by the active brush.
  StrokePipeline({
    required this.onPath,
    double smoothing = 0.7,
    double minCutoff = 1,
    double derivativeCutoff = 1,
    double nominalFrequency = 120,
    double maxSegmentLength = 1.5,
    double flatnessTolerance = 0.05,
  }) : _resampler = OneEuroStrokeResampler(
         minCutoff: minCutoff,
         beta: smoothing,
         derivativeCutoff: derivativeCutoff,
         nominalFrequency: nominalFrequency,
       ),
       _fitter = CatmullRomPathFitter(
         maxSegmentLength: maxSegmentLength,
         flatnessTolerance: flatnessTolerance,
       );

  /// Synchronous consumer for newly fitted path samples.
  final StrokePathSink onPath;
  final OneEuroStrokeResampler _resampler;
  final CatmullRomPathFitter _fitter;
  final List<StrokeSample> _inputSamples = <StrokeSample>[];
  var _isActive = false;

  /// Whether this pipeline currently owns a stroke.
  bool get isActive => _isActive;

  /// Immutable raw inputs retained for journal recipe encoding.
  List<StrokeSample> get inputSamples =>
      List<StrokeSample>.unmodifiable(_inputSamples);

  /// Starts a new stroke and immediately emits its fitted origin.
  void begin(StrokeSample sample) {
    if (_isActive) {
      throw StateError('StrokePipeline already has an active stroke.');
    }
    _resampler.reset();
    _fitter.reset();
    _inputSamples.clear();
    _isActive = true;
    try {
      final List<FittedStrokeSample> output = _append(sample);
      onPath(output, isFinal: false);
    } on Object {
      _isActive = false;
      rethrow;
    }
  }

  /// Adds one raw sample and emits any curve interval released by look-ahead.
  void add(StrokeSample sample) {
    _checkActive();
    final List<FittedStrokeSample> output = _append(sample);
    if (output.isNotEmpty) {
      onPath(output, isFinal: false);
    }
  }

  /// Adds an optional final input, emits the held tail, and closes the stroke.
  void end({StrokeSample? sample}) {
    _checkActive();
    try {
      final List<FittedStrokeSample> output = <FittedStrokeSample>[];
      if (sample != null) {
        output.addAll(_append(sample));
      }
      output.addAll(_fitter.finish(endpoint: _inputSamples.last));
      onPath(List<FittedStrokeSample>.unmodifiable(output), isFinal: true);
    } finally {
      _isActive = false;
    }
  }

  /// Abandons the active stroke without a final brush callback.
  void cancel() {
    if (!_isActive) {
      return;
    }
    _isActive = false;
    _resampler.reset();
    _fitter.reset();
    _inputSamples.clear();
  }

  /// Encodes the current or most recently completed raw input recipe.
  Uint8List encodeRecipe() => StrokeRecipeCodec.encode(_inputSamples);

  List<FittedStrokeSample> _append(StrokeSample sample) {
    final StrokeSample filtered = _resampler.filter(sample);
    final List<FittedStrokeSample> output = _fitter.add(filtered);
    _inputSamples.add(sample);
    return output;
  }

  void _checkActive() {
    if (!_isActive) {
      throw StateError('StrokePipeline has no active stroke.');
    }
  }
}

const int _maximumInt64 = 0x7fffffffffffffff;
const double _geometryEpsilon = 1e-9;

double _alpha(double elapsedSeconds, double cutoff) {
  final double timeConstant = 1 / (2 * math.pi * cutoff);
  return 1 / (1 + timeConstant / elapsedSeconds);
}

double _lowPass(double current, double previous, double alpha) =>
    alpha * current + (1 - alpha) * previous;

StrokeSample _interpolateSample(
  StrokeSample start,
  StrokeSample end,
  double t, {
  Offset? point,
}) {
  final double fraction = t.clamp(0.0, 1.0);
  final int startMicros = start.timestamp.inMicroseconds;
  final int elapsedMicros = end.timestamp.inMicroseconds - startMicros;
  return StrokeSample(
    point: point ?? Offset.lerp(start.point, end.point, fraction)!,
    pressure: _lerpDouble(
      start.pressure,
      end.pressure,
      fraction,
    ).clamp(0.0, 1.0),
    tilt: Offset.lerp(start.tilt, end.tilt, fraction)!,
    timestamp: Duration(
      microseconds: startMicros + (elapsedMicros * fraction).round(),
    ),
  );
}

double _lerpDouble(double start, double end, double t) =>
    start + (end - start) * t;

double _distanceToLine(Offset point, Offset start, Offset end) {
  final Offset line = end - start;
  final double length = line.distance;
  if (length <= _geometryEpsilon) {
    return (point - start).distance;
  }
  return ((point.dx - start.dx) * line.dy - (point.dy - start.dy) * line.dx)
          .abs() /
      length;
}

void _checkOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'components must be finite');
  }
}

void _checkPositive(double value, String name) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, name, 'must be finite and positive');
  }
}
