import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';
import 'package:pluto_settings/pluto_settings.dart';

void main() {
  test(
    'settings services invoke documented methods and decode values',
    () async {
      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(
          plutoSettingsChannel,
          frontlightReadMethod,
          (Object? arguments) => <String, Object?>{'raw': 100, 'maxRaw': 2047},
        )
        ..onInvoke(
          plutoSettingsChannel,
          frontlightWriteMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiIsEnabledMethod,
          (Object? arguments) => <String, Object?>{'enabled': true},
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiScanMethod,
          (Object? arguments) => <Object?>[
            <String, Object?>{
              'ssid': 'Lab',
              'signal': 0.82,
              'security': 'wpaPsk',
              'isKnown': true,
              'isActive': false,
            },
          ],
        )
        ..onInvoke(
          plutoSettingsChannel,
          powerPolicyMethod,
          (Object? arguments) => <String, Object?>{
            'idleSuspendDelayMs': 300000,
            'suspendPowerOffDelayMs': 3600000,
          },
        )
        ..onInvoke(
          plutoSettingsChannel,
          securityIsPinSetMethod,
          (Object? arguments) => false,
        )
        ..onInvoke(
          plutoSettingsChannel,
          securitySetPinMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          batteryDeviceMethod,
          (Object? arguments) => <String, Object?>{
            'level': 0.68,
            'state': 'discharging',
            'isUsbPowerPresent': true,
          },
        );

      final PlutoSettings settings = PlutoSettings.withTransport(transport);
      final FrontlightState light = await settings.frontlight.state();
      await settings.frontlight.setBrightnessRaw(200);
      final List<WifiNetwork> networks = await settings.wifi.scanNetworks();
      final PowerPolicy policy = await settings.power.policy();
      final DevicePin pin = DevicePin.tryParse('1234')!;
      await settings.security.setPin(pin);
      final BatteryStatus battery = await settings.battery.deviceBattery();

      expect(light.fraction, closeTo(100 / 2047, 0.0001));
      expect(await settings.wifi.isEnabled(), isTrue);
      expect(networks.single.security, WifiSecurity.wpaPsk);
      expect(policy.idleSuspendDelay, const Duration(minutes: 5));
      expect(await settings.security.isPinSet(), isFalse);
      expect(battery.level, 0.68);
      expect(
        transport.invocations.any((invocation) {
          return invocation.method == frontlightWriteMethod;
        }),
        isTrue,
      );
    },
  );

  test('frontlight stream decodes events', () async {
    final FakePlutoTransport transport = FakePlutoTransport();
    final Frontlight frontlight = Frontlight.withTransport(transport);

    final Future<FrontlightState> first = frontlight.onChanged.first;
    transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
      'raw': 2047,
      'maxRaw': 2047,
    });

    expect((await first).isOn, isTrue);
    await transport.close();
  });

  test('invalid raw brightness and invalid PIN fail before wire use', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoSettingsChannel,
        frontlightReadMethod,
        (Object? arguments) => <String, Object?>{'raw': 0, 'maxRaw': 10},
      );

    final Frontlight frontlight = Frontlight.withTransport(transport);

    expect(frontlight.setBrightnessRaw(11), throwsRangeError);
    expect(DevicePin.tryParse('abcd'), isNull);
  });

  test(
    'wifi connection, status, known networks, and failures are typed',
    () async {
      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(
          plutoSettingsChannel,
          wifiConnectMethod,
          (Object? arguments) => <String, Object?>{
            'ssid': 'Lab',
            'ipAddress': '192.168.1.74',
            'signal': 0.9,
          },
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiActiveMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiKnownMethod,
          (Object? arguments) => <Object?>[
            <String, Object?>{'ssid': 'Lab', 'security': 'sae'},
          ],
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiDisconnectMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          wifiForgetMethod,
          (Object? arguments) => null,
        );

      final WifiSettings wifi = WifiSettings.withTransport(transport);
      final Future<WifiStatus> status = wifi.onStatusChanged.first;
      transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
        'status': 'connected',
        'connection': <String, Object?>{
          'ssid': 'Lab',
          'ipAddress': '192.168.1.74',
          'signal': 0.9,
        },
      });

      expect((await wifi.connect(ssid: 'Lab')).ipAddress, '192.168.1.74');
      expect(await wifi.activeConnection(), isNull);
      expect((await wifi.knownNetworks()).single.security, WifiSecurity.sae);
      await wifi.disconnect();
      await wifi.forgetNetwork(ssid: 'Lab');
      expect(await status, isA<WifiConnected>());

      final FakePlutoTransport failing = FakePlutoTransport()
        ..onInvoke(
          plutoSettingsChannel,
          wifiConnectMethod,
          (Object? arguments) => throw const PlutoPlatformException(
            'bad passphrase',
            code: 'wifi.bad-passphrase',
          ),
        );

      expect(
        WifiSettings.withTransport(failing).connect(ssid: 'Lab'),
        throwsA(
          isA<WifiConnectException>().having(
            (WifiConnectException error) => error.failure,
            'failure',
            WifiConnectFailure.badPassphrase,
          ),
        ),
      );
    },
  );

  test(
    'power, security removal, and marker battery use documented methods',
    () async {
      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(
          plutoSettingsChannel,
          powerSetIdleSuspendDelayMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          powerSetSuspendPowerOffDelayMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          powerSuspendNowMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          securityRemovePinMethod,
          (Object? arguments) => null,
        )
        ..onInvoke(
          plutoSettingsChannel,
          batteryMarkerMethod,
          (Object? arguments) => <String, Object?>{
            'level': 0.68,
            'nfcCellLevel': 0.0,
          },
        );

      final PowerSettings power = PowerSettings.withTransport(transport);
      await power.setIdleSuspendDelay(const Duration(minutes: 10));
      await power.setSuspendPowerOffDelay(const Duration(hours: 1));
      await power.suspendNow();
      await SecuritySettings.withTransport(transport).removePin();
      final MarkerBatteryStatus? marker = await BatteryTelemetry.withTransport(
        transport,
      ).markerBattery();

      expect(marker!.nfcCellLevel, 0);
      expect(
        transport.invocations.map((invocation) => invocation.method),
        contains(powerSuspendNowMethod),
      );
    },
  );

  test('status and battery streams decode remaining variants', () async {
    final FakePlutoTransport transport = FakePlutoTransport();
    final WifiSettings wifi = WifiSettings.withTransport(transport);
    final BatteryTelemetry battery = BatteryTelemetry.withTransport(transport);

    final Future<List<WifiStatus>> statuses = wifi.onStatusChanged
        .take(3)
        .toList();
    transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
      'status': 'disabled',
    });
    transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
      'status': 'disconnected',
    });
    transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
      'status': 'connecting',
      'ssid': 'Lab',
    });

    final Future<BatteryStatus> device = battery.deviceBatteryUpdates().first;
    transport.emitEvent(plutoSettingsEventsChannel, <String, Object?>{
      'level': 1.0,
      'state': 'full',
      'isUsbPowerPresent': true,
    });
    final Future<MarkerBatteryStatus?> marker = battery
        .markerBatteryUpdates()
        .first;
    transport.emitEvent(plutoSettingsEventsChannel, null);

    expect(await statuses, <Matcher>[
      isA<WifiDisabled>(),
      isA<WifiDisconnected>(),
      isA<WifiConnecting>(),
    ]);
    expect((await device).state, BatteryChargingState.full);
    expect(await marker, isNull);
  });
}
