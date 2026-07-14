import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_sensors/pluto_sensors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AccelerometerSample decodes {tUs, x, y, z}', () {
    final AccelerometerSample sample = AccelerometerSample.fromMap(
      <Object?, Object?>{'tUs': 1500, 'x': 0.1, 'y': -9.8, 'z': 0.2},
    );
    expect(sample.x, 0.1);
    expect(sample.y, -9.8);
    expect(sample.z, 0.2);
    expect(sample.timestamp, const Duration(microseconds: 1500));
  });

  test('PanelOrientation.fromName maps names with an unknown fallback', () {
    expect(
      PanelOrientation.fromName('landscapeLeft'),
      PanelOrientation.landscapeLeft,
    );
    expect(PanelOrientation.fromName('bogus'), PanelOrientation.unknown);
    expect(PanelOrientation.fromName(null), PanelOrientation.unknown);
  });

  test('capabilities/read/orientation invoke the method channel', () async {
    const MethodChannel channel = MethodChannel('test/sensors');
    final Sensors sensors = Sensors(methodChannel: channel);
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'capabilities':
              return <Object?, Object?>{
                'accelerometer': true,
                'tap': false,
                'doubleTap': true,
                'orientation': true,
              };
            case 'accelerometerRead':
              return <Object?, Object?>{
                'tUs': 10,
                'x': 1.0,
                'y': 2.0,
                'z': 3.0,
              };
            case 'orientation':
              return <Object?, Object?>{'orientation': 'portrait'};
          }
          return null;
        });

    final SensorCapabilities caps = await sensors.capabilities();
    expect(caps.accelerometer, isTrue);
    expect(caps.tap, isFalse);
    expect(caps.doubleTap, isTrue);

    final AccelerometerSample sample = await sensors.read();
    expect(sample.y, 2.0);

    expect(await sensors.currentOrientation(), PanelOrientation.portrait);
    expect(
      calls,
      containsAll(<String>['capabilities', 'accelerometerRead', 'orientation']),
    );
  });
}
