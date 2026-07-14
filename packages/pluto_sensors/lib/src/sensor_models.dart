import 'package:meta/meta.dart';

/// Physical device orientation reported by the accelerometer.
enum PanelOrientation {
  /// Upright.
  portrait,

  /// Upside down.
  portraitUpsideDown,

  /// Rotated 90° counter-clockwise.
  landscapeLeft,

  /// Rotated 90° clockwise.
  landscapeRight,

  /// Not yet determined.
  unknown;

  /// Parses the embedder's orientation name.
  static PanelOrientation fromName(String? name) {
    switch (name) {
      case 'portrait':
        return PanelOrientation.portrait;
      case 'portraitUpsideDown':
        return PanelOrientation.portraitUpsideDown;
      case 'landscapeLeft':
        return PanelOrientation.landscapeLeft;
      case 'landscapeRight':
        return PanelOrientation.landscapeRight;
      default:
        return PanelOrientation.unknown;
    }
  }
}

Duration _timestampFrom(Object? micros) => Duration(
  microseconds: micros is int
      ? micros
      : micros is num
      ? micros.toInt()
      : 0,
);

double _double(Object? value) => value is num ? value.toDouble() : 0;

/// A single accelerometer reading in device axes (metres per second squared).
@immutable
final class AccelerometerSample {
  /// Creates a sample.
  const AccelerometerSample({
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
  });

  /// Decodes an event map (`{tUs, x, y, z}`) from the sensor channel.
  factory AccelerometerSample.fromMap(Map<Object?, Object?> map) {
    return AccelerometerSample(
      x: _double(map['x']),
      y: _double(map['y']),
      z: _double(map['z']),
      timestamp: _timestampFrom(map['tUs']),
    );
  }

  /// Acceleration along the device x axis.
  final double x;

  /// Acceleration along the device y axis.
  final double y;

  /// Acceleration along the device z axis.
  final double z;

  /// Device-monotonic timestamp of the sample.
  final Duration timestamp;

  @override
  String toString() =>
      'AccelerometerSample(x: $x, y: $y, z: $z, t: ${timestamp.inMilliseconds}ms)';
}

/// A tap or double-tap gesture detected by the accelerometer.
@immutable
final class TapEvent {
  /// Creates a tap event.
  const TapEvent({required this.timestamp});

  /// Decodes a `{tUs}` event map.
  factory TapEvent.fromMap(Map<Object?, Object?> map) =>
      TapEvent(timestamp: _timestampFrom(map['tUs']));

  /// Device-monotonic timestamp of the tap.
  final Duration timestamp;
}

/// An orientation-change event.
@immutable
final class OrientationEvent {
  /// Creates an orientation event.
  const OrientationEvent({required this.orientation, required this.timestamp});

  /// Decodes a `{tUs, orientation}` event map.
  factory OrientationEvent.fromMap(Map<Object?, Object?> map) =>
      OrientationEvent(
        orientation: PanelOrientation.fromName(map['orientation'] as String?),
        timestamp: _timestampFrom(map['tUs']),
      );

  /// The new orientation.
  final PanelOrientation orientation;

  /// Device-monotonic timestamp of the change.
  final Duration timestamp;
}

/// Which motion sensors the device exposes.
@immutable
final class SensorCapabilities {
  /// Creates a capabilities record.
  const SensorCapabilities({
    required this.accelerometer,
    required this.tap,
    required this.doubleTap,
    required this.orientation,
  });

  /// Decodes the `capabilities` reply.
  factory SensorCapabilities.fromMap(Map<Object?, Object?> map) =>
      SensorCapabilities(
        accelerometer: map['accelerometer'] == true,
        tap: map['tap'] == true,
        doubleTap: map['doubleTap'] == true,
        orientation: map['orientation'] == true,
      );

  /// Whether raw accelerometer streaming is available.
  final bool accelerometer;

  /// Whether single-tap detection is available.
  final bool tap;

  /// Whether double-tap detection is available.
  final bool doubleTap;

  /// Whether orientation detection is available.
  final bool orientation;
}
