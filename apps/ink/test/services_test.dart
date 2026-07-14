import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/services.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_pen/pluto_pen_testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppPaths', () {
    test('uses the channel documents directory', () async {
      final AppPaths paths = await AppPaths.resolve(
        channelCall: () async => <Object?, Object?>{
          'documents': '/channel/documents',
          'cache': '/ignored',
        },
        environment: const <String, String>{'PAPER_INK_HOME': '/fallback'},
      );

      expect(paths.root.path, '/channel/documents');
    });

    test('uses PAPER_INK_HOME when the channel is missing', () async {
      final AppPaths paths = await AppPaths.resolve(
        channelCall: () => throw MissingPluginException(),
        environment: const <String, String>{
          'PAPER_INK_HOME': '/configured/ink',
          'HOME': '/home/tester',
        },
      );

      expect(paths.root.path, '/configured/ink');
    });

    test('uses the home directory fallback', () async {
      final AppPaths paths = await AppPaths.resolve(
        channelCall: () => throw MissingPluginException(),
        environment: const <String, String>{'HOME': '/home/artist'},
      );

      expect(paths.root.path, '/home/artist/.paper-ink');
    });

    test('uses system temp when HOME is unavailable', () async {
      final AppPaths paths = await AppPaths.resolve(
        channelCall: () => throw MissingPluginException(),
        environment: const <String, String>{},
      );

      expect(paths.root.path, '${Directory.systemTemp.path}/.paper-ink');
    });

    test('falls back on PlatformException and malformed payloads', () async {
      final AppPaths exceptionPaths = await AppPaths.resolve(
        channelCall: () => throw PlatformException(code: 'unavailable'),
        environment: const <String, String>{'HOME': '/one'},
      );
      final AppPaths malformedPaths = await AppPaths.resolve(
        channelCall: () async => <Object?, Object?>{'documents': ''},
        environment: const <String, String>{'HOME': '/two'},
      );

      expect(exceptionPaths.root.path, '/one/.paper-ink');
      expect(malformedPaths.root.path, '/two/.paper-ink');
    });

    test('ensure creates every owned directory', () async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'ink-services-paths-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final AppPaths paths = AppPaths(
        root: Directory('${temporary.path}/documents'),
      );

      paths.ensure();

      expect(paths.root.existsSync(), isTrue);
      expect(paths.artworks.existsSync(), isTrue);
      expect(paths.trash.existsSync(), isTrue);
      expect(paths.exports.existsSync(), isTrue);
      expect(paths.imports.existsSync(), isTrue);
    });
  });

  group('DeviceFacts and display capabilities', () {
    test('copies the device snapshot including DeviceInfo.isColor', () async {
      final DeviceFacts facts = await DeviceFacts.detect(
        loader: () async => _deviceInfo(
          model: RemarkableModel.paperProMove,
          colorMode: PanelColorMode.monochrome,
          width: 1000,
          height: 1700,
          dpi: 300,
        ),
      );

      expect(facts.model, RemarkableModel.paperProMove);
      expect(facts.panelWidth, 1000);
      expect(facts.panelHeight, 1700);
      expect(facts.dpi, 300);
      expect(facts.isColor, isFalse);
    });

    test('uses color-friendly host defaults after detection failure', () async {
      final DeviceFacts facts = await DeviceFacts.detect(
        loader: () => throw StateError('host'),
      );

      expect(facts, same(DeviceFacts.hostDefault));
      expect(facts.isColor, isTrue);
      expect(facts.panelWidth, 954);
      expect(facts.panelHeight, 1696);
      expect(facts.dpi, 264);
    });

    test('presenterDrivesColor follows isColor exactly', () {
      const DeviceFacts color = DeviceFacts(
        model: RemarkableModel.unknown,
        panelWidth: 1,
        panelHeight: 1,
        dpi: 1,
        isColor: true,
      );
      const DeviceFacts monochrome = DeviceFacts(
        model: RemarkableModel.paperProMove,
        panelWidth: 1,
        panelHeight: 1,
        dpi: 1,
        isColor: false,
      );

      expect(InkDisplayCaps.fromDevice(color).presenterDrivesColor, isTrue);
      expect(
        InkDisplayCaps.fromDevice(monochrome).presenterDrivesColor,
        isFalse,
      );
    });

    test('physical class follows the hardware model, not color readiness', () {
      const DeviceFacts moveWithoutColor = DeviceFacts(
        model: RemarkableModel.paperProMove,
        panelWidth: 1,
        panelHeight: 1,
        dpi: 1,
        isColor: false,
      );
      const DeviceFacts otherWithColor = DeviceFacts(
        model: RemarkableModel.paperPro,
        panelWidth: 1,
        panelHeight: 1,
        dpi: 1,
        isColor: true,
      );

      expect(
        InkDisplayCaps.fromDevice(moveWithoutColor).physicalPanelClass,
        InkPhysicalPanelClass.gallery3,
      );
      expect(
        InkDisplayCaps.fromDevice(otherWithColor).physicalPanelClass,
        InkPhysicalPanelClass.gallery3,
      );
    });
  });

  group('ChannelSystemBridge', () {
    test('dispatches launcher exit and full refresh', () async {
      var exits = 0;
      var refreshes = 0;
      final ChannelSystemBridge bridge = ChannelSystemBridge(
        exitCall: () async {
          exits += 1;
        },
        refreshCall: () async {
          refreshes += 1;
          return null;
        },
      );

      await bridge.exitToLauncher();
      await bridge.requestFullRefresh();

      expect(exits, 1);
      expect(refreshes, 1);
    });

    test('missing host plugins are harmless', () async {
      final ChannelSystemBridge bridge = ChannelSystemBridge(
        exitCall: () => throw MissingPluginException(),
        refreshCall: () => throw MissingPluginException(),
      );

      await expectLater(bridge.exitToLauncher(), completes);
      await expectLater(bridge.requestFullRefresh(), completes);
    });

    test('platform channel failures are harmless', () async {
      final ChannelSystemBridge bridge = ChannelSystemBridge(
        exitCall: () => throw PlatformException(code: 'exit'),
        refreshCall: () => throw PlatformException(code: 'refresh'),
      );

      await expectLater(bridge.exitToLauncher(), completes);
      await expectLater(bridge.requestFullRefresh(), completes);
    });
  });

  group('InkServices', () {
    test('environment fake gate swaps pen and invokes the seeder', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'ink-services-fake-',
      );
      addTearDown(() => root.delete(recursive: true));
      var seeded = 0;
      final InkServices services = await InkServices.createReal(
        pathsChannelCall: () async => <Object?, Object?>{
          'documents': root.path,
        },
        environment: const <String, String>{'PAPER_INK_FAKE': '1'},
        deviceInfoLoader: () async => _deviceInfo(),
        livePen: const _TestPen(),
        system: const _TestSystemBridge(),
        clock: const _TestClock(1234),
        fakeDocumentSeeder: (store, clock) async {
          seeded += 1;
          expect(clock.nowMilliseconds(), 1234);
        },
      );

      expect(services.isFake, isTrue);
      expect(services.pen, isA<FakePenEvents>());
      expect(seeded, 1);
      expect(services.display.presenterDrivesColor, isTrue);
    });

    test(
      'marker-file fake gate works without environment inheritance',
      () async {
        final Directory root = await Directory.systemTemp.createTemp(
          'ink-services-marker-',
        );
        addTearDown(() => root.delete(recursive: true));
        File('${root.path}/fake-ink').writeAsStringSync('1');

        final InkServices services = await InkServices.createReal(
          pathsChannelCall: () async => <Object?, Object?>{
            'documents': root.path,
          },
          environment: const <String, String>{},
          deviceInfoLoader: () async => _deviceInfo(),
          livePen: const _TestPen(),
          system: const _TestSystemBridge(),
          fakeDocumentSeeder: (store, clock) async {},
        );

        expect(services.isFake, isTrue);
        expect(services.pen, isA<FakePenEvents>());
      },
    );

    test('default fake mode seeds one deterministic demo document', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'ink-services-seed-',
      );
      addTearDown(() => root.delete(recursive: true));

      final InkServices first = await InkServices.createReal(
        pathsChannelCall: () async => <Object?, Object?>{
          'documents': root.path,
        },
        environment: const <String, String>{'PAPER_INK_FAKE': '1'},
        deviceInfoLoader: () async => _deviceInfo(),
        system: const _TestSystemBridge(),
        clock: const _TestClock(4567),
      );
      final InkServices second = await InkServices.createReal(
        pathsChannelCall: () async => <Object?, Object?>{
          'documents': root.path,
        },
        environment: const <String, String>{'PAPER_INK_FAKE': '1'},
        deviceInfoLoader: () async => _deviceInfo(),
        system: const _TestSystemBridge(),
        clock: const _TestClock(9999),
      );

      final firstGallery = await first.store.loadGallery();
      final secondGallery = await second.store.loadGallery();
      expect(firstGallery, hasLength(1));
      expect(firstGallery.single.id, 'demo-welcome');
      expect(firstGallery.single.name, 'Welcome to Ink');
      expect(firstGallery.single.createdAtMs, 4567);
      expect(secondGallery, hasLength(1));
      expect(secondGallery.single.createdAtMs, 4567);
      expect(await second.store.openDocument('demo-welcome'), isNotNull);
    });

    test('normal construction retains injected live services', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'ink-services-live-',
      );
      addTearDown(() => root.delete(recursive: true));
      const _TestPen pen = _TestPen();
      const _TestSystemBridge system = _TestSystemBridge();
      const _TestClock clock = _TestClock(9000);

      final InkServices services = await InkServices.createReal(
        pathsChannelCall: () async => <Object?, Object?>{
          'documents': root.path,
        },
        environment: const <String, String>{},
        deviceInfoLoader: () async =>
            _deviceInfo(colorMode: PanelColorMode.monochrome),
        livePen: pen,
        system: system,
        clock: clock,
      );

      expect(services.isFake, isFalse);
      expect(services.pen, same(pen));
      expect(services.system, same(system));
      expect(services.clock, same(clock));
      expect(services.store.root.path, root.path);
      expect(services.display.presenterDrivesColor, isFalse);
    });
  });
}

DeviceInfo _deviceInfo({
  RemarkableModel model = RemarkableModel.paperProMove,
  PanelColorMode colorMode = PanelColorMode.gallery3,
  int width = 954,
  int height = 1696,
  int dpi = 264,
}) {
  return DeviceInfo(
    model: model,
    codename: model.codename,
    firmwareBuild: 'test',
    osVersion: 'test',
    panel: PanelGeometry(
      width: width,
      height: height,
      dpi: dpi,
      pixelFormat: PanelPixelFormat.rgb565,
      colorMode: colorMode,
    ),
  );
}

final class _TestPen implements PenEvents {
  const _TestPen();

  @override
  Stream<PenEvent> get events => const Stream<PenEvent>.empty();
}

final class _TestSystemBridge implements SystemBridge {
  const _TestSystemBridge();

  @override
  Future<void> exitToLauncher() async {}

  @override
  Future<void> requestFullRefresh() async {}
}

final class _TestClock implements Clock {
  const _TestClock(this.milliseconds);

  final int milliseconds;

  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(milliseconds);

  @override
  int nowMilliseconds() => milliseconds;
}
