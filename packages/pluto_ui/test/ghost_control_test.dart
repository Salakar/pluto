import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('pluto/refresh');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends every stock ghost control wire name', () async {
    final List<String> received = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'requestGhostControl');
          received.add(call.arguments! as String);
          return <String, Object?>{'accepted': true};
        });

    for (final GhostControlMode mode in GhostControlMode.values) {
      expect(await EinkGhostControl.request(mode), isTrue);
    }

    expect(received, <String>[
      'blinkNow',
      'blinkLater',
      'bleachNow',
      'factoryReset',
    ]);
  });
}
