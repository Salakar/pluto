import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_launcher/src/models.dart';
import 'package:pluto_launcher/src/real_services.dart';
import 'package:pluto_launcher/src/services.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real service bundle uses the canonical package facades', () {
    final LauncherServices services = createRealServices();

    expect(services.settings, isA<PlutoLauncherSettings>());
    expect(services.device, isA<PlutoDeviceRepository>());
  });

  test('canonical runtime manifest remains a healthy launcher app', () async {
    const MethodChannel channel = MethodChannel('test/pluto/apps');
    final ChannelManifestRepository repository = ChannelManifestRepository(
      channel: channel,
    );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await repository.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'list');
          return <Object?>[
            <String, Object?>{
              'id': 'dev.example.notes',
              'manifest': _canonicalManifest,
              'install': _releaseInstall,
              'sizeBytes': 2048,
            },
          ];
        });

    final List<LauncherApp> apps = await repository.watchApps().first;

    expect(apps, hasLength(1));
    expect(apps.single.health, isA<LauncherAppHealthy>());
    expect(apps.single.manifest.runtime.kind, AppRuntimeKind.flutterAot);
    expect(apps.single.manifest.encode(), contains('"type":"flutter-aot"'));
  });

  test('canonical launcher manifest is hidden from its own gallery', () async {
    const MethodChannel channel = MethodChannel('test/pluto/apps-self');
    final ChannelManifestRepository repository = ChannelManifestRepository(
      channel: channel,
    );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await repository.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'list');
          return <Object?>[
            <String, Object?>{
              'id': kLauncherAppId,
              'manifest': _canonicalManifest.replaceAll(
                'dev.example.notes',
                kLauncherAppId,
              ),
              'install': _releaseInstall,
            },
            <String, Object?>{
              'id': 'dev.example.notes',
              'manifest': _canonicalManifest,
              'install': _releaseInstall,
            },
          ];
        });

    final List<LauncherApp> apps = await repository.watchApps().first;

    expect(apps.map((LauncherApp app) => app.id.value), <String>[
      'dev.example.notes',
    ]);
  });

  test('manifest icon is loaded from the installed app directory', () async {
    final Directory appDir = Directory.systemTemp.createTempSync(
      'launcher-icon-test',
    );
    addTearDown(() => appDir.deleteSync(recursive: true));
    final File icon = File('${appDir.path}/icon.png')
      ..writeAsBytesSync(<int>[1, 3, 3, 7]);
    const MethodChannel channel = MethodChannel('test/pluto/apps-icon');
    final ChannelManifestRepository repository = ChannelManifestRepository(
      channel: channel,
    );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await repository.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          return <Object?>[
            <String, Object?>{
              'id': 'dev.example.notes',
              'path': appDir.path,
              'manifest': _canonicalManifest,
              'install': _releaseInstall,
            },
          ];
        });

    final LauncherApp app = (await repository.watchApps().first).single;

    expect(app.iconBytes, icon.readAsBytesSync());
  });

  test(
    'frontlight reads back exact raw state and surfaces channel failures',
    () async {
      int raw = 913;
      bool failRead = false;
      bool failWrite = false;
      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(plutoSettingsChannel, frontlightReadMethod, (
          Object? arguments,
        ) {
          if (failRead) {
            throw const PlutoPlatformException(
              'frontlight read failed',
              code: 'unavailable',
            );
          }
          return <String, Object?>{'raw': raw, 'maxRaw': 2047};
        })
        ..onInvoke(plutoSettingsChannel, frontlightWriteMethod, (
          Object? arguments,
        ) {
          if (failWrite) {
            throw const PlutoPlatformException(
              'frontlight write failed',
              code: 'unavailable',
            );
          }
          raw = (arguments! as Map<Object?, Object?>)['raw']! as int;
          return null;
        });
      addTearDown(transport.close);

      final PlutoLauncherSettings settings = PlutoLauncherSettings(
        settings: PlutoSettings.withTransport(transport),
      );
      addTearDown(settings.dispose);
      expect((await settings.frontlight()).raw, 913);

      await settings.setFrontlightRaw(347);
      expect((await settings.frontlight()).raw, 347);

      failWrite = true;
      await expectLater(
        settings.setFrontlightRaw(100),
        throwsA(isA<PlutoPlatformException>()),
      );
      expect(
        raw,
        347,
        reason: 'failed writes must not be presented as success',
      );

      failWrite = false;
      failRead = true;
      await expectLater(
        settings.frontlight(),
        throwsA(isA<PlutoPlatformException>()),
      );
    },
  );

  test(
    'rotation preference defaults safely and persists wire values',
    () async {
      const MethodChannel channel = MethodChannel('test/rotation-settings');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String value = 'auto';
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'rotation.read') {
          return value;
        }
        if (call.method == 'rotation.write') {
          value =
              (call.arguments! as Map<Object?, Object?>)['value']! as String;
          return null;
        }
        throw MissingPluginException(call.method);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final PlutoLauncherSettings settings = PlutoLauncherSettings(
        settings: PlutoSettings.withTransport(FakePlutoTransport()),
        channel: channel,
      );
      addTearDown(settings.dispose);
      expect(await settings.rotationPreference(), RotationPreference.auto);
      await settings.setRotationPreference(RotationPreference.landscape);
      expect(value, 'landscape');
      expect(await settings.rotationPreference(), RotationPreference.landscape);
      value = 'corrupt';
      expect(await settings.rotationPreference(), RotationPreference.auto);
    },
  );

  test('standby and home control writes surface platform failures', () async {
    const MethodChannel channel = MethodChannel('test/standby-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'io', message: call.method);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    await expectLater(session.sleepNow(), throwsA(isA<PlatformException>()));
    await expectLater(
      session.handoffStandbyToSupervisor(),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      session.returnToLauncher(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('switch-to-stock propagates the channel failure', () async {
    const MethodChannel channel = MethodChannel('test/stock-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'exitToStock');
      throw PlatformException(code: 'io', message: 'stock handoff failed');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    await expectLater(
      session.switchToStockUi(),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'io',
        ),
      ),
    );
  });

  test('session decoders reject keys outside the current contract', () async {
    const MethodChannel channel = MethodChannel('test/exact-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Object? reply = <String, Object?>{'active': false};
    messenger.setMockMethodCallHandler(channel, (_) async => reply);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    expect(await session.pendingPowerMenu(), isNull);

    reply = <String, Object?>{
      'active': false,
      'originAppId': 'dev.pluto.codex',
    };
    await expectLater(
      session.pendingPowerMenu(),
      throwsA(isA<FormatException>()),
    );

    reply = <String, Object?>{'ok': true, 'legacyPid': 42};
    await expectLater(
      session.powerOffDevice(),
      throwsA(isA<FormatException>()),
    );
  });

  test('launch accepts only the current acknowledgement shape', () async {
    const MethodChannel channel = MethodChannel('test/exact-launch-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Object? reply = <String, Object?>{'ok': true};
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'launch');
      return reply;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    expect(
      await session.launch(AppId.tryParse('dev.example.weather')!),
      isA<LaunchSuccess>(),
    );

    reply = <String, Object?>{'ok': true, 'pid': 42};
    final LaunchResult malformed = await session.launch(
      AppId.tryParse('dev.example.weather')!,
    );
    expect(malformed, isA<LaunchFailure>());
    expect(
      (malformed as LaunchFailure).reason,
      'Invalid pluto/session launch response.',
    );
  });

  test(
    'power menu reads its origin and requests supervisor power-off',
    () async {
      const MethodChannel channel = MethodChannel('test/power-menu-session');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final List<String> calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'powerMenuInfo') {
          return <String, Object?>{
            'active': true,
            'originAppId': 'dev.pluto.codex',
          };
        }
        if (call.method == 'powerOff') {
          return <String, Object?>{'ok': true};
        }
        throw MissingPluginException(call.method);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      const ChannelSessionManager session = ChannelSessionManager(
        channel: channel,
      );
      final PowerMenuRequest request = (await session.pendingPowerMenu())!;
      expect(request.originAppId.value, 'dev.pluto.codex');
      await session.powerOffDevice();
      expect(calls, <String>['powerMenuInfo', 'powerOff']);
    },
  );

  test(
    'app switcher keeps supervisor order and reads bounded previews',
    () async {
      final Directory previews = Directory.systemTemp.createTempSync(
        'launcher-switcher-preview',
      );
      addTearDown(() => previews.deleteSync(recursive: true));
      final List<int> bmp = List<int>.filled(54, 0);
      bmp[0] = 0x42;
      bmp[1] = 0x4d;
      void putInt32(int offset, int value) {
        for (int byte = 0; byte < 4; byte += 1) {
          bmp[offset + byte] = (value >> (byte * 8)) & 0xff;
        }
      }

      putInt32(18, 320);
      putInt32(22, 640);
      final File preview = File('${previews.path}/weather.bmp')
        ..writeAsBytesSync(bmp);
      const MethodChannel channel = MethodChannel('test/switcher-session');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'switcherInfo');
        return <String, Object?>{
          'active': true,
          'originAppId': 'dev.pluto.codex',
          'apps': <Object?>[
            <String, Object?>{
              'appId': 'dev.example.weather',
              'previewPath': preview.path,
            },
            <String, Object?>{
              'appId': 'dev.example.counter',
              'previewPath': '${previews.path}/evicted.bmp',
            },
            <String, Object?>{
              'appId': 'dev.pluto.codex',
              'previewPath': preview.path,
            },
            <String, Object?>{
              'appId': kLauncherAppId,
              'previewPath': preview.path,
            },
          ],
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      const ChannelSessionManager session = ChannelSessionManager(
        channel: channel,
      );
      final AppSwitcherRequest request = (await session.pendingAppSwitcher())!;

      expect(request.originAppId.value, 'dev.pluto.codex');
      expect(
        request.previews.map((AppSwitcherPreview item) => item.appId.value),
        <String>['dev.example.weather', 'dev.example.counter'],
      );
      expect(request.previews.first.imageBytes, preview.readAsBytesSync());
      expect(request.previews.first.aspectRatio, closeTo(0.5, 0.0001));
      expect(request.previews.last.imageBytes, isNull);
    },
  );

  test('force stop publishes the selected app id', () async {
    const MethodChannel channel = MethodChannel('test/force-stop-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? stoppedId;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'forceStop');
      stoppedId =
          (call.arguments! as Map<Object?, Object?>)['appId']! as String;
      return <String, Object?>{'ok': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    await session.forceStop(AppId.tryParse('dev.example.weather')!);
    expect(stoppedId, 'dev.example.weather');
  });

  test('status shade reads its origin preview and aspect ratio', () async {
    final Directory previews = Directory.systemTemp.createTempSync(
      'launcher-status-preview',
    );
    addTearDown(() => previews.deleteSync(recursive: true));
    final List<int> bmp = List<int>.filled(54, 0);
    bmp[0] = 0x42;
    bmp[1] = 0x4d;
    void putInt32(int offset, int value) {
      for (int byte = 0; byte < 4; byte += 1) {
        bmp[offset + byte] = (value >> (byte * 8)) & 0xff;
      }
    }

    putInt32(18, 954);
    putInt32(22, 1696);
    final File preview = File('${previews.path}/codex.bmp')
      ..writeAsBytesSync(bmp);
    const MethodChannel channel = MethodChannel('test/status-session');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'statusInfo');
      return <String, Object?>{
        'active': true,
        'originAppId': 'dev.pluto.codex',
        'previewPath': preview.path,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const ChannelSessionManager session = ChannelSessionManager(
      channel: channel,
    );
    final StatusOverlayRequest request = (await session
        .pendingStatusOverlay())!;

    expect(request.originAppId.value, 'dev.pluto.codex');
    expect(request.imageBytes, bmp);
    expect(request.aspectRatio, closeTo(954 / 1696, 0.0001));
  });

  test(
    'status chrome remains available when the Wi-Fi backend is unavailable',
    () async {
      const MethodChannel channel = MethodChannel(
        'test/unavailable-wifi-status-chrome',
      );
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        expect(call.method, 'network.info');
        return <String, Object?>{
          'usbConnected': true,
          'usbIp': '10.11.99.1',
          'wifiIp': '',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(
          plutoSettingsChannel,
          batteryDeviceMethod,
          (Object? arguments) => <String, Object?>{
            'level': 0.64,
            'state': 'charging',
            'isUsbPowerPresent': false,
          },
        )
        ..onInvoke(
          plutoSettingsChannel,
          batteryMarkerMethod,
          (Object? arguments) => <String, Object?>{'level': 0.77},
        )
        ..onInvoke(plutoSettingsChannel, wifiActiveMethod, (Object? arguments) {
          throw const PlutoPlatformException(
            'wpa_supplicant control socket is unavailable',
            code: 'unavailable',
          );
        })
        ..onInvoke(
          plutoSettingsChannel,
          frontlightReadMethod,
          (Object? arguments) => <String, Object?>{'raw': 512, 'maxRaw': 2048},
        );
      addTearDown(transport.close);
      final PlutoLauncherSettings settings = PlutoLauncherSettings(
        settings: PlutoSettings.withTransport(transport),
        channel: channel,
      );
      addTearDown(settings.dispose);
      final StatusSnapshot status = await settings.watchStatus().first.timeout(
        const Duration(seconds: 1),
      );

      expect(status.battery.levelPercent, 64);
      expect(status.battery.isCharging, isTrue);
      expect(status.penBattery?.levelPercent, 77);
      expect(status.wifi, isNull);
      expect(status.isWifiEnabled, isTrue);
      expect(status.frontlightRaw, 512);
      expect(status.frontlightMaxRaw, 2048);
      expect(status.isUsbTethered, isTrue);
    },
  );

  test(
    'Wi-Fi status surfaces backend failures instead of inventing state',
    () async {
      final FakePlutoTransport transport = FakePlutoTransport()
        ..onInvoke(plutoSettingsChannel, wifiActiveMethod, (Object? arguments) {
          throw const PlutoPlatformException(
            'wpa_supplicant control socket is unavailable',
            code: 'unavailable',
          );
        });
      addTearDown(transport.close);
      final PlutoLauncherSettings settings = PlutoLauncherSettings(
        settings: PlutoSettings.withTransport(transport),
      );
      addTearDown(settings.dispose);
      await expectLater(
        settings.wifiStatus(),
        throwsA(
          isA<PlutoPlatformException>().having(
            (PlutoPlatformException error) => error.code,
            'code',
            'unavailable',
          ),
        ),
      );
    },
  );

  test('device repository forwards profile capabilities', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoDeviceChannel,
        deviceCapabilitiesMethod,
        (Object? arguments) => <Object?>['wifi', 'devicePin', 'powerPolicy'],
      );
    addTearDown(transport.close);
    final PlutoDeviceRepository repository = PlutoDeviceRepository(
      device: PlutoDevice.withTransport(transport),
    );

    final DeviceCapabilities capabilities = await repository.capabilities();

    expect(capabilities.supports(Capability.frontlight), isFalse);
    expect(capabilities.supports(Capability.wifi), isTrue);
  });

  test('device identity failures propagate without a Move fallback', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(plutoDeviceChannel, deviceInfoMethod, (Object? arguments) {
        throw const PlutoPlatformException(
          'device profile is unavailable',
          code: 'unavailable',
        );
      });
    addTearDown(transport.close);
    final PlutoDeviceRepository repository = PlutoDeviceRepository(
      device: PlutoDevice.withTransport(transport),
    );

    await expectLater(
      repository.deviceInfo(),
      throwsA(
        isA<PlutoPlatformException>().having(
          (PlutoPlatformException error) => error.code,
          'code',
          'unavailable',
        ),
      ),
    );
  });
}

const String _canonicalManifest = '''
{
  "id": "dev.example.notes",
  "name": "Notes",
  "version": "1.0.0",
  "icon": "icon.png",
  "runtime": {
    "type": "flutter-aot",
    "appElf": "lib/app.so",
    "assets": "flutter_assets"
  },
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "a10d8ac38de835021c8d2f920dbf50a920ccc030"
  },
  "targets": ["linux-arm", "linux-arm64"],
  "permissions": [],
  "display": {
    "orientations": ["portrait"],
    "defaultOrientation": "portrait",
    "scale": "auto",
    "color": "auto",
    "refreshProfile": "ui"
  },
  "launch": {"singleInstance": true, "args": []}
}
''';

const String _releaseInstall = '''
{
  "appId": "dev.example.notes",
  "installedAt": "2026-07-10T00:00:00Z",
  "installedBy": "pluto 0.1.0",
  "source": "pluto-cli",
  "buildMode": "release",
  "engineFlavor": "release",
  "sizeBytes": 2048,
  "payload": {}
}
''';
