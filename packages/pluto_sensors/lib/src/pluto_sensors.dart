import 'dart:async';

import 'package:flutter/services.dart';

import 'sensor_models.dart';

/// Motion-sensor APIs for reMarkable apps: a live accelerometer stream, tap and
/// double-tap gestures, and device orientation. Backed by the embedder's
/// `pluto/sensors` method + event channels (LIS2DW12 over IIO).
///
/// ```dart
/// final Sensors sensors = Sensors();
/// sensors.doubleTaps.listen((_) => goHome());
/// sensors.accelerometer().listen((AccelerometerSample s) => ...);
/// ```
final class Sensors {
  /// Creates a sensors facade. Channel names default to the embedder's and can
  /// be overridden for testing.
  Sensors({
    MethodChannel? methodChannel,
    EventChannel? accelerometerChannel,
    EventChannel? tapChannel,
    EventChannel? doubleTapChannel,
    EventChannel? orientationChannel,
  }) : _method = methodChannel ?? const MethodChannel('pluto/sensors'),
       _accelerometer =
           accelerometerChannel ??
           const EventChannel('pluto/sensors/accelerometer'),
       _tap = tapChannel ?? const EventChannel('pluto/sensors/tap'),
       _doubleTap =
           doubleTapChannel ?? const EventChannel('pluto/sensors/doubleTap'),
       _orientation =
           orientationChannel ??
           const EventChannel('pluto/sensors/orientation');

  final MethodChannel _method;
  final EventChannel _accelerometer;
  final EventChannel _tap;
  final EventChannel _doubleTap;
  final EventChannel _orientation;

  static Map<Object?, Object?> _asMap(Object? event) =>
      event is Map<Object?, Object?> ? event : const <Object?, Object?>{};

  /// A live accelerometer stream sampled every [period] (clamped 10 ms – 2 s by
  /// the embedder).
  Stream<AccelerometerSample> accelerometer({
    Duration period = const Duration(milliseconds: 50),
  }) {
    return _accelerometer
        .receiveBroadcastStream(<String, Object?>{
          'periodMs': period.inMilliseconds,
        })
        .map((Object? event) => AccelerometerSample.fromMap(_asMap(event)));
  }

  /// Single-tap gestures on the device body.
  Stream<TapEvent> get taps => _tap.receiveBroadcastStream().map(
    (Object? e) => TapEvent.fromMap(_asMap(e)),
  );

  /// Double-tap gestures on the device body (e.g. a bezel double-tap).
  Stream<TapEvent> get doubleTaps => _doubleTap.receiveBroadcastStream().map(
    (Object? e) => TapEvent.fromMap(_asMap(e)),
  );

  /// Orientation-change events.
  Stream<OrientationEvent> get orientationChanges => _orientation
      .receiveBroadcastStream()
      .map((Object? e) => OrientationEvent.fromMap(_asMap(e)));

  /// Reads the accelerometer once.
  Future<AccelerometerSample> read() async {
    final Object? reply = await _method.invokeMethod<Object?>(
      'accelerometerRead',
    );
    return AccelerometerSample.fromMap(_asMap(reply));
  }

  /// Reads the current orientation once.
  Future<PanelOrientation> currentOrientation() async {
    final Object? reply = await _method.invokeMethod<Object?>('orientation');
    return PanelOrientation.fromName(_asMap(reply)['orientation'] as String?);
  }

  /// Reports which motion sensors this device supports.
  Future<SensorCapabilities> capabilities() async {
    final Object? reply = await _method.invokeMethod<Object?>('capabilities');
    return SensorCapabilities.fromMap(_asMap(reply));
  }
}
