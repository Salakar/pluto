import 'dart:math' as math;

/// Returns the nearest-index percentile from [values].
///
/// This matches Flutter's frame-timing summarizer: the sorted index is
/// `((length - 1) * fraction).round()`.
double percentile(List<num> values, double fraction) {
  if (values.isEmpty) {
    throw ArgumentError.value(values, 'values', 'must not be empty');
  }
  if (!fraction.isFinite || fraction < 0 || fraction > 1) {
    throw RangeError.range(fraction, 0, 1, 'fraction');
  }
  final List<double> sorted =
      values.map((num value) => value.toDouble()).toList(growable: false)
        ..sort();
  final int index = ((sorted.length - 1) * fraction).round();
  return sorted[index];
}

/// Delivery statistics for the samples currently in a rolling window.
final class RollingWindowStats {
  const RollingWindowStats({
    required this.count,
    required this.distinctPositions,
    required this.minimumGapMicroseconds,
    required this.medianGapMicroseconds,
    required this.minimumPressure,
    required this.maximumPressure,
  });

  /// Number of delivered move events in the window.
  final int count;

  /// Number of exact positions represented in the window.
  final int distinctPositions;

  /// Smallest adjacent delivery gap, or null with fewer than two samples.
  final int? minimumGapMicroseconds;

  /// Median adjacent delivery gap, or null with fewer than two samples.
  final double? medianGapMicroseconds;

  /// Lowest pressure, or null when the window is empty.
  final double? minimumPressure;

  /// Highest pressure, or null when the window is empty.
  final double? maximumPressure;
}

/// Counts pointer deliveries retained within a monotonic rolling interval.
final class RollingWindowCounter {
  RollingWindowCounter({this.window = const Duration(seconds: 1)});

  /// Width of the rolling interval.
  final Duration window;

  final List<_DeliverySample> _samples = <_DeliverySample>[];

  /// Adds one delivered pointer move.
  void add({
    required int timestampMicroseconds,
    required double x,
    required double y,
    required double pressure,
  }) {
    _samples.add(
      _DeliverySample(
        timestampMicroseconds: timestampMicroseconds,
        x: x,
        y: y,
        pressure: pressure,
      ),
    );
  }

  /// Returns current statistics after discarding samples older than [now].
  RollingWindowStats snapshot({required int nowMicroseconds}) {
    final int cutoff = nowMicroseconds - window.inMicroseconds;
    _samples.removeWhere(
      (_DeliverySample sample) => sample.timestampMicroseconds < cutoff,
    );

    if (_samples.isEmpty) {
      return const RollingWindowStats(
        count: 0,
        distinctPositions: 0,
        minimumGapMicroseconds: null,
        medianGapMicroseconds: null,
        minimumPressure: null,
        maximumPressure: null,
      );
    }

    final Set<(double, double)> positions = <(double, double)>{};
    final List<int> gaps = <int>[];
    var minimumPressure = double.infinity;
    var maximumPressure = double.negativeInfinity;
    for (var index = 0; index < _samples.length; index++) {
      final _DeliverySample sample = _samples[index];
      positions.add((sample.x, sample.y));
      minimumPressure = math.min(minimumPressure, sample.pressure);
      maximumPressure = math.max(maximumPressure, sample.pressure);
      if (index > 0) {
        gaps.add(
          sample.timestampMicroseconds -
              _samples[index - 1].timestampMicroseconds,
        );
      }
    }

    return RollingWindowStats(
      count: _samples.length,
      distinctPositions: positions.length,
      minimumGapMicroseconds: gaps.isEmpty ? null : gaps.reduce(math.min),
      medianGapMicroseconds: gaps.isEmpty ? null : percentile(gaps, 0.5),
      minimumPressure: minimumPressure,
      maximumPressure: maximumPressure,
    );
  }

  /// Removes all samples.
  void reset() {
    _samples.clear();
  }
}

/// Tracks the current and maximum number of concurrent pointer identifiers.
final class ConcurrentPointerCounter {
  final Set<int> _activePointers = <int>{};
  var _maximum = 0;

  /// Number of active pointers.
  int get current => _activePointers.length;

  /// Highest simultaneous count since construction or [reset].
  int get maximum => _maximum;

  /// Records a pointer becoming active. Duplicate identifiers are ignored.
  void pointerDown(int pointer) {
    _activePointers.add(pointer);
    _maximum = math.max(_maximum, _activePointers.length);
  }

  /// Records a pointer ending or being cancelled.
  void pointerUp(int pointer) {
    _activePointers.remove(pointer);
  }

  /// Clears both active pointers and the retained maximum.
  void reset() {
    _activePointers.clear();
    _maximum = 0;
  }
}

final class _DeliverySample {
  const _DeliverySample({
    required this.timestampMicroseconds,
    required this.x,
    required this.y,
    required this.pressure,
  });

  final int timestampMicroseconds;
  final double x;
  final double y;
  final double pressure;
}
