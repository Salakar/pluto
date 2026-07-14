import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/model/settings_model.dart';

void main() {
  group('PressureCurvePreference.mapPressure', () {
    test('maps each curve at a representative device pressure', () {
      const double pressure = 0.5;

      final double soft = PressureCurvePreference.soft.mapPressure(pressure);
      final double normal = PressureCurvePreference.normal.mapPressure(
        pressure,
      );
      final double firm = PressureCurvePreference.firm.mapPressure(pressure);

      expect(soft, closeTo(math.pow(pressure, 0.65), 1e-12));
      expect(normal, pressure);
      expect(firm, closeTo(math.pow(pressure, 1.55), 1e-12));
      expect(firm, lessThan(normal));
      expect(normal, lessThan(soft));
    });

    test('clamps pressure to the normalized input range', () {
      for (final PressureCurvePreference curve
          in PressureCurvePreference.values) {
        expect(curve.mapPressure(-0.25), 0);
        expect(curve.mapPressure(1.25), 1);
      }
    });

    test('live-stroke preset decoding drives the same mapping', () {
      const double pressure = 0.5;

      expect(
        mapPressureFromPreset('soft', pressure),
        PressureCurvePreference.soft.mapPressure(pressure),
      );
      expect(
        mapPressureFromPreset('firm', pressure),
        PressureCurvePreference.firm.mapPressure(pressure),
      );
      expect(mapPressureFromPreset('future', pressure), pressure);
      expect(
        mapPressureFromPreset('soft', null),
        closeTo(math.pow(0.6, 0.65), 1e-12),
      );
    });
  });
}
