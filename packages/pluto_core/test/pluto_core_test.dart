import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fake transport records channel calls and emits events', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoDeviceChannel,
        deviceInfoMethod,
        (Object? arguments) => <String, Object?>{'ok': true},
      );

    final Object? response = await transport.invoke<Object?>(
      channel: plutoDeviceChannel,
      method: deviceInfoMethod,
      arguments: const <String, Object?>{'verbose': true},
    );
    final Future<Object?> firstEvent = transport
        .events(channel: plutoSettingsEventsChannel)
        .first;
    transport.emitEvent(plutoSettingsEventsChannel, 'ready');
    final Object? event = await firstEvent;

    expect(response, const <String, Object?>{'ok': true});
    expect(event, 'ready');
    expect(transport.invocations.single.channel, plutoDeviceChannel);
    expect(transport.invocations.single.method, deviceInfoMethod);
    expect(Capability.penSampleRing.name, 'penSampleRing');
    await transport.close();
  });

  test('unsupported exception names the missing capability', () {
    final PlutoException exception = PlutoUnsupportedException(
      Capability.frontlight,
    );

    expect(exception.toString(), contains('frontlight'));
  });

  test('platform errors map to typed exceptions', () {
    expect(
      convertPlatformException(
        PlatformException(
          code: 'unsupported',
          message: 'no light',
          details: Capability.frontlight.name,
        ),
      ),
      isA<PlutoUnsupportedException>(),
    );
    expect(
      convertPlatformException(
        PlatformException(code: 'permission-denied', message: 'managed'),
      ),
      isA<PlutoPermissionException>(),
    );
    expect(
      convertPlatformException(
        PlatformException(
          code: 'protocol',
          details: <String, Object?>{
            'clientProtocol': 1,
            'embedderProtocol': 2,
          },
        ),
      ),
      isA<PlutoProtocolException>(),
    );
    expect(
      convertPlatformException(PlatformException(code: 'io')),
      isA<PlutoPlatformException>(),
    );
  });

  test('protocol helpers and ring writer validate inputs', () {
    expect(packageNameForChannel(plutoPenEventsChannel), 'pluto_pen');
    expect(() => PenRingWriter(capacity: 3), throwsA(isA<ArgumentError>()));
    final PenRingWriter writer = PenRingWriter(capacity: 2)
      ..write(
        timestampUs: 1,
        flags: 0,
        rawX: 1,
        rawY: 2,
        rawPressure: 3,
        rawDistance: 4,
        tiltXCentiDegrees: 5,
        tiltYCentiDegrees: -5,
        orientationTag: 0,
        xLogical: 1,
        yLogical: 2,
      )
      ..write(
        timestampUs: 2,
        flags: 0,
        rawX: 2,
        rawY: 3,
        rawPressure: 4,
        rawDistance: 5,
        tiltXCentiDegrees: 6,
        tiltYCentiDegrees: -6,
        orientationTag: 0,
        xLogical: 2,
        yLogical: 3,
      )
      ..write(
        timestampUs: 3,
        flags: 0,
        rawX: 3,
        rawY: 4,
        rawPressure: 5,
        rawDistance: 6,
        tiltXCentiDegrees: 7,
        tiltYCentiDegrees: -7,
        orientationTag: 0,
        xLogical: 3,
        yLogical: 4,
      );

    expect(writer.data.getUint32(0, Endian.little), PenRingWriter.magic);
    expect(writer.data.getUint64(16, Endian.little), 3);
    expect(writer.data.getUint64(24, Endian.little), 1);
  });

  test(
    'channel transport performs handshake and invokes method channel',
    () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(plutoCoreChannel), (
            MethodCall call,
          ) async {
            calls.add(call);
            return <String, Object?>{
              'protocol': plutoProtocolVersion,
              'embedderVersion': 'test',
              'model': 'chiappa',
            };
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(plutoDeviceChannel), (
            MethodCall call,
          ) async {
            calls.add(call);
            return <String, Object?>{'ok': true};
          });

      final Object? response = await ChannelTransport.shared.invoke<Object?>(
        channel: plutoDeviceChannel,
        method: deviceInfoMethod,
      );

      expect(response, const <String, Object?>{'ok': true});
      expect(
        calls.map((MethodCall call) => call.method),
        contains('handshake'),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(plutoCoreChannel),
            null,
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(plutoDeviceChannel),
            null,
          );
    },
  );
}
