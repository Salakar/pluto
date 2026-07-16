import 'dart:math' as math;
import 'dart:ui';

/// Which end of the marker is active.
enum PenTool {
  /// Normal pen tip.
  pen,

  /// Eraser end.
  eraser,
}

/// Barrel/stylus button state as a zero-cost value set.
extension type const PenButtons(int _bits) {
  /// No barrel buttons pressed.
  static const PenButtons none = PenButtons(0);

  /// Primary barrel button bit.
  static const int primaryBit = 0x1;

  /// Secondary barrel button bit.
  static const int secondaryBit = 0x2;

  /// Raw bit set.
  int get bits => _bits;

  /// Whether BTN_STYLUS is pressed.
  bool get hasPrimary => _bits & primaryBit != 0;

  /// Whether BTN_STYLUS2 is pressed.
  bool get hasSecondary => _bits & secondaryBit != 0;
}

/// One immutable digitizer sample with all fidelity preserved.
final class PenSample {
  /// Creates a pen sample.
  const PenSample({
    required this.timestamp,
    required this.position,
    required this.rawPosition,
    required this.pressure,
    required this.rawPressure,
    required this.tilt,
    required this.rawTilt,
    required this.distance,
    required this.rawDistance,
    required this.tool,
    required this.buttons,
  });

  /// Creates a pen sample from a platform-channel payload.
  factory PenSample.fromMap(Map<String, Object?> map) {
    final int rawPressure = _intAt(map, 'pressureRaw');
    final int rawDistance = _intAt(map, 'distanceRaw');
    final int rawTiltX = _intAt(map, 'tiltXRaw');
    final int rawTiltY = _intAt(map, 'tiltYRaw');
    return PenSample(
      timestamp: Duration(microseconds: _intAt(map, 'tUs')),
      position: Offset(_doubleAt(map, 'xPx'), _doubleAt(map, 'yPx')),
      rawPosition: Offset(
        _intAt(map, 'rawX').toDouble(),
        _intAt(map, 'rawY').toDouble(),
      ),
      pressure: rawPressure / _defaultRawPressureMax,
      rawPressure: rawPressure,
      tilt: Offset(_tiltRadians(rawTiltX), _tiltRadians(rawTiltY)),
      rawTilt: Offset(rawTiltX.toDouble(), rawTiltY.toDouble()),
      distance: rawDistance / _defaultRawDistanceMax,
      rawDistance: rawDistance,
      tool: _toolFromWire(map['tool']),
      buttons: PenButtons(_intAt(map, 'buttons')),
    );
  }

  /// Monotonic event time.
  final Duration timestamp;

  /// Panel-space position in physical pixels.
  final Offset position;

  /// Untransformed digitizer units.
  final Offset rawPosition;

  /// Normalized contact pressure from 0 to 1.
  final double pressure;

  /// Raw pressure value.
  final int rawPressure;

  /// Tilt around x and y axes in radians.
  final Offset tilt;

  /// Raw tilt in centi-degrees.
  final Offset rawTilt;

  /// Normalized hover distance from 0 to 1.
  final double distance;

  /// Raw ABS_DISTANCE value.
  final int rawDistance;

  /// Active tool.
  final PenTool tool;

  /// Pressed barrel buttons.
  final PenButtons buttons;
}

/// Typed pen lifecycle event.
sealed class PenEvent {
  /// Creates a pen lifecycle event.
  const PenEvent({required this.sample});

  /// Triggering sample.
  final PenSample sample;
}

/// Pen entered digitizer range.
final class PenEnteredProximityEvent extends PenEvent {
  /// Creates a proximity-enter event.
  const PenEnteredProximityEvent({required super.sample});
}

/// Pen moved while hovering.
final class PenHoverEvent extends PenEvent {
  /// Creates a hover event.
  const PenHoverEvent({required super.sample});
}

/// Pen tip or eraser made contact.
final class PenDownEvent extends PenEvent {
  /// Creates a down event.
  const PenDownEvent({required super.sample});
}

/// Pen moved while in contact.
final class PenMoveEvent extends PenEvent {
  /// Creates a move event.
  const PenMoveEvent({required super.sample});
}

/// Pen contact ended.
final class PenUpEvent extends PenEvent {
  /// Creates an up event.
  const PenUpEvent({required super.sample});
}

/// Pen left digitizer range.
final class PenLeftProximityEvent extends PenEvent {
  /// Creates a proximity-leave event.
  const PenLeftProximityEvent({required super.sample});
}

/// Barrel button state changed.
final class PenButtonsChangedEvent extends PenEvent {
  /// Creates a button-change event.
  const PenButtonsChangedEvent({required super.sample, required this.previous});

  /// Button state before this event.
  final PenButtons previous;
}

/// Coarse pen state snapshot.
final class PenState {
  /// Creates a pen state snapshot.
  const PenState({
    required this.isInProximity,
    required this.isInContact,
    required this.tool,
    required this.buttons,
  });

  /// Creates a pen state snapshot from a protocol map.
  factory PenState.fromMap(Map<String, Object?> map) {
    return PenState(
      isInProximity: _boolAt(map, 'isInProximity'),
      isInContact: _boolAt(map, 'isInContact'),
      tool: _toolFromWire(map['tool']),
      buttons: PenButtons(_intAt(map, 'buttons')),
    );
  }

  /// Whether the pen is in digitizer range.
  final bool isInProximity;

  /// Whether the pen is touching the panel.
  final bool isInContact;

  /// Active tool.
  final PenTool tool;

  /// Pressed barrel buttons.
  final PenButtons buttons;
}

/// Digitizer description.
final class PenCapabilities {
  /// Creates a digitizer description.
  const PenCapabilities({
    required this.rawXMax,
    required this.rawYMax,
    required this.rawPressureMax,
    required this.rawDistanceMax,
    required this.rawTiltMaxCentiDegrees,
    required this.estimatedSampleRateHz,
  });

  /// Creates capabilities from a protocol map.
  factory PenCapabilities.fromMap(Map<String, Object?> map) {
    final Map<String, Object?> axes = _mapAt(map, 'axes');
    return PenCapabilities(
      rawXMax: _intAt(axes, 'rawXMax'),
      rawYMax: _intAt(axes, 'rawYMax'),
      rawPressureMax: _intAt(axes, 'rawPressureMax'),
      rawDistanceMax: _intAt(axes, 'rawDistanceMax'),
      rawTiltMaxCentiDegrees: _intAt(axes, 'rawTiltMaxCentiDegrees'),
      estimatedSampleRateHz: _doubleAt(map, 'estimatedSampleRateHz'),
    );
  }

  /// Maximum raw X value.
  final int rawXMax;

  /// Maximum raw Y value.
  final int rawYMax;

  /// Maximum raw pressure value.
  final int rawPressureMax;

  /// Maximum raw hover-distance value.
  final int rawDistanceMax;

  /// Maximum absolute raw tilt in centi-degrees.
  final int rawTiltMaxCentiDegrees;

  /// Estimated sample rate in hertz.
  final double estimatedSampleRateHz;
}

const double _defaultRawPressureMax = 4096;
const double _defaultRawDistanceMax = 65535;

double _tiltRadians(int centiDegrees) => centiDegrees * math.pi / 18000;

PenTool _toolFromWire(Object? value) {
  return switch (value) {
    1 => PenTool.pen,
    2 => PenTool.eraser,
    _ => throw FormatException('Unknown pen tool: $value'),
  };
}

Map<String, Object?> _mapAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? entryKey = entry.key;
      if (entryKey is! String) {
        throw FormatException('Expected $key keys to be strings.');
      }
      result[entryKey] = entry.value;
    }
    return result;
  }
  throw FormatException('Expected $key to be a map.');
}

int _intAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}

double _doubleAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value.toDouble();
  }
  if (value is double) {
    return value;
  }
  throw FormatException('Expected $key to be a number.');
}

bool _boolAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected $key to be a bool.');
}
