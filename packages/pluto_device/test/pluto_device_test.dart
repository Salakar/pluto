import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_core/testing.dart';
import 'package:pluto_device/pluto_device.dart';

void main() {
  test('device facade decodes Paper Pro Move info and capabilities', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoDeviceChannel,
        deviceInfoMethod,
        (Object? arguments) => <String, Object?>{
          'model': 'paperProMove',
          'codename': 'chiappa',
          'firmwareBuild': '20260629074044',
          'osVersion': '3.28.0.162',
          'panel': <String, Object?>{
            'width': 954,
            'height': 1696,
            'dpi': 264,
            'pixelFormat': 'rgb565',
            'colorMode': 'gallery3',
          },
          'serialNumber': null,
        },
      )
      ..onInvoke(
        plutoDeviceChannel,
        deviceCapabilitiesMethod,
        (Object? arguments) => <Object?>[
          'frontlight',
          'colorPanel',
          'futureCapability',
        ],
      );

    final PlutoDevice device = PlutoDevice.withTransport(transport);
    final DeviceInfo info = await device.deviceInfo();
    final DeviceCapabilities capabilities = await device.capabilities();

    expect(info.model, RemarkableModel.paperProMove);
    expect(info.codename, 'chiappa');
    expect(info.size.width, 954);
    expect(info.size.height, 1696);
    expect(info.dpi, 264);
    expect(info.isColor, isTrue);
    expect(capabilities.supports(Capability.frontlight), isTrue);
    expect(capabilities.supports(Capability.wifi), isFalse);
  });

  test('device info preserves unknown codenames and value semantics', () async {
    final FakePlutoTransport transport = FakePlutoTransport()
      ..onInvoke(
        plutoDeviceChannel,
        deviceInfoMethod,
        (Object? arguments) => <String, Object?>{
          'model': 'futureModel',
          'codename': 'future-board',
          'firmwareBuild': '1',
          'osVersion': '2',
          'panel': <String, Object?>{
            'width': 100,
            'height': 200,
            'dpi': 100,
            'pixelFormat': 'gray8',
            'colorMode': 'monochrome',
          },
        },
      );

    final DeviceInfo info = await PlutoDevice.withTransport(
      transport,
    ).deviceInfo();

    expect(info.model, RemarkableModel.unknown);
    expect(info.codename, 'future-board');
    expect(info.isColor, isFalse);
    expect(info.panel.physicalSizeMm.width, closeTo(25.4, 0.001));
    expect(
      info.panel,
      const PanelGeometry(
        width: 100,
        height: 200,
        dpi: 100,
        pixelFormat: PanelPixelFormat.gray8,
        colorMode: PanelColorMode.monochrome,
      ),
    );
  });
}
