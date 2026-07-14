import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/probe/probe_math.dart';

void main() {
  group('percentile', () {
    test('uses the sorted nearest index for p50 and p95', () {
      final List<int> values = <int>[40, 10, 30, 20];

      expect(percentile(values, 0.50), 30);
      expect(percentile(values, 0.95), 40);
    });

    test('does not mutate input and handles a singleton', () {
      final List<int> values = <int>[3, 1, 2];

      expect(percentile(values, 0), 1);
      expect(values, <int>[3, 1, 2]);
      expect(percentile(<int>[7], 0.95), 7);
    });

    test('rejects empty samples and invalid fractions', () {
      expect(() => percentile(<int>[], 0.5), throwsArgumentError);
      expect(() => percentile(<int>[1], -0.1), throwsRangeError);
      expect(() => percentile(<int>[1], 1.1), throwsRangeError);
    });
  });

  group('RollingWindowCounter', () {
    test('retains only the inclusive one-second window', () {
      final RollingWindowCounter counter = RollingWindowCounter();
      counter.add(timestampMicroseconds: 0, x: 0, y: 0, pressure: 0.1);
      counter.add(timestampMicroseconds: 500000, x: 1, y: 1, pressure: 0.2);
      counter.add(timestampMicroseconds: 1100000, x: 2, y: 2, pressure: 0.3);

      final RollingWindowStats stats = counter.snapshot(
        nowMicroseconds: 1100000,
      );

      expect(stats.count, 2);
      expect(stats.distinctPositions, 2);
      expect(stats.minimumGapMicroseconds, 600000);
    });

    test('reports gaps, positions, and pressure range', () {
      final RollingWindowCounter counter = RollingWindowCounter();
      counter.add(timestampMicroseconds: 100, x: 4, y: 5, pressure: 0.7);
      counter.add(timestampMicroseconds: 300, x: 4, y: 5, pressure: 0.2);
      counter.add(timestampMicroseconds: 700, x: 8, y: 9, pressure: 0.9);

      final RollingWindowStats stats = counter.snapshot(nowMicroseconds: 700);

      expect(stats.count, 3);
      expect(stats.distinctPositions, 2);
      expect(stats.minimumGapMicroseconds, 200);
      expect(stats.medianGapMicroseconds, 400);
      expect(stats.minimumPressure, 0.2);
      expect(stats.maximumPressure, 0.9);
    });

    test('handles one sample and reset', () {
      final RollingWindowCounter counter = RollingWindowCounter();
      counter.add(timestampMicroseconds: 10, x: 1, y: 2, pressure: 0.5);

      final RollingWindowStats one = counter.snapshot(nowMicroseconds: 10);
      expect(one.count, 1);
      expect(one.minimumGapMicroseconds, isNull);
      expect(one.medianGapMicroseconds, isNull);

      counter.reset();
      final RollingWindowStats empty = counter.snapshot(nowMicroseconds: 20);
      expect(empty.count, 0);
      expect(empty.minimumPressure, isNull);
      expect(empty.maximumPressure, isNull);
    });
  });

  group('ConcurrentPointerCounter', () {
    test('tracks overlap and ignores duplicate down events', () {
      final ConcurrentPointerCounter counter = ConcurrentPointerCounter();

      counter.pointerDown(1);
      counter.pointerDown(1);
      counter.pointerDown(2);
      counter.pointerUp(1);

      expect(counter.current, 1);
      expect(counter.maximum, 2);
    });

    test('ignores unknown releases and resets the retained maximum', () {
      final ConcurrentPointerCounter counter = ConcurrentPointerCounter();
      counter.pointerDown(4);
      counter.pointerUp(99);

      expect(counter.current, 1);
      expect(counter.maximum, 1);

      counter.reset();
      expect(counter.current, 0);
      expect(counter.maximum, 0);
    });
  });
}
