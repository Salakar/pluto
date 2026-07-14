import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_launcher/main.dart';
import 'package:pluto_launcher/src/screens.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../test/support/fake_services.dart';

void main() {
  setUpAll(_loadGoldenFonts);

  group('launcher screen goldens', () {
    testWidgets('S1 welcome', (WidgetTester tester) async {
      await _pumpRoute(tester, '/welcome');
      await _expectGolden(tester, 's01_welcome');
    });

    testWidgets('S2 home grid', (WidgetTester tester) async {
      await _pumpRoute(tester, '/', apps: _featuredApps());
      await _settleMemoryImages(tester);
      expect(find.byType(Image), findsNWidgets(4));
      for (final Image image in tester.widgetList<Image>(find.byType(Image))) {
        expect((image.image as MemoryImage).bytes, isNotEmpty);
      }
      await _expectGolden(tester, 's02_home_grid');
    });

    testWidgets('S17 app icon family', (WidgetTester tester) async {
      await _pumpScreen(tester, _IconFamilySheet(apps: _iconFamilyApps()));
      await _settleMemoryImages(tester);
      await _expectGolden(tester, 's17_icon_family');
    });

    testWidgets('S18 home grid landscape', (WidgetTester tester) async {
      await _pumpRoute(
        tester,
        '/',
        apps: _featuredApps(),
        physicalSize: const Size(1696, 954),
      );
      await _settleMemoryImages(tester);
      await _expectGolden(tester, 's18_home_grid_landscape');
    });

    testWidgets('S19 settings landscape', (WidgetTester tester) async {
      await _pumpRoute(
        tester,
        '/settings',
        physicalSize: const Size(1696, 954),
      );
      await tester.pump();
      await _expectGolden(tester, 's19_settings_landscape');
    });

    testWidgets('S20 running apps portrait', (WidgetTester tester) async {
      final List<LauncherApp> apps = _featuredApps();
      await _pumpScreen(
        tester,
        AppSwitcherScreen(request: _switcherRequest()),
        services: createHostPreviewServices(apps: apps),
      );
      await tester.pump();
      await _settleMemoryImages(tester);
      expect(find.text('Running apps'), findsNothing);
      expect(find.text('WARM'), findsNothing);
      expect(find.text('Return'), findsNothing);
      await _expectGolden(tester, 's20_app_switcher_portrait');
    });

    testWidgets('S21 running apps landscape', (WidgetTester tester) async {
      final List<LauncherApp> apps = _featuredApps();
      await _pumpScreen(
        tester,
        AppSwitcherScreen(request: _switcherRequest()),
        services: createHostPreviewServices(apps: apps),
        physicalSize: const Size(1696, 954),
      );
      await tester.pump();
      await _settleMemoryImages(tester);
      expect(tester.takeException(), isNull);
      await _expectGolden(tester, 's21_app_switcher_landscape');
    });

    testWidgets('S22 system status shade portrait', (
      WidgetTester tester,
    ) async {
      await _pumpScreen(
        tester,
        StatusOverlayScreen(request: _statusOverlayRequest()),
        services: createHostPreviewServices(apps: _featuredApps()),
      );
      await _settleMemoryImages(tester);
      expect(find.text('Open Settings'), findsOneWidget);
      await _expectGolden(tester, 's22_status_overlay_portrait');
    });

    testWidgets('S23 system status shade landscape', (
      WidgetTester tester,
    ) async {
      await _pumpScreen(
        tester,
        StatusOverlayScreen(request: _statusOverlayRequest()),
        services: createHostPreviewServices(apps: _featuredApps()),
        physicalSize: const Size(1696, 954),
      );
      await _settleMemoryImages(tester);
      expect(tester.takeException(), isNull);
      await _expectGolden(tester, 's23_status_overlay_landscape');
    });

    testWidgets('S24 power off portrait', (WidgetTester tester) async {
      await _pumpScreen(tester, PowerOffScreen(request: _powerMenuRequest()));
      await _expectGolden(tester, 's24_power_off_portrait');
    });

    testWidgets('S25 power off landscape', (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        PowerOffScreen(request: _powerMenuRequest()),
        physicalSize: const Size(1696, 954),
      );
      expect(tester.takeException(), isNull);
      await _expectGolden(tester, 's25_power_off_landscape');
    });

    testWidgets('S26 power off hold progress', (WidgetTester tester) async {
      await _pumpScreen(tester, PowerOffScreen(request: _powerMenuRequest()));
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('power-off-hold'))),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await _expectGolden(tester, 's26_power_off_hold_progress');
      await gesture.up();
      await tester.pump();
    });

    testWidgets('S27 powering off farewell', (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        PowerOffScreen(
          request: _powerMenuRequest(),
          initiallyPoweringOff: true,
        ),
      );
      await _expectGolden(tester, 's27_powering_off');
    });

    testWidgets('S4 home empty', (WidgetTester tester) async {
      _setMoveViewport(tester);
      await tester.pumpWidget(
        PlutoLauncherApp(services: createHostPreviewServices(empty: true)),
      );
      await tester.pump();
      await tester.pump();
      await _expectGolden(tester, 's04_home_empty');
    });

    testWidgets('S5 app context sheet', (WidgetTester tester) async {
      await _pumpRoute(tester, '/');
      await tester.longPress(find.text('Weather').first);
      await tester.pump();
      await _expectGolden(tester, 's05_app_context_sheet');
    });

    testWidgets('S6 app info', (WidgetTester tester) async {
      await _pumpRoute(tester, '/app/dev.example.weather');
      await tester.pump();
      await _expectGolden(tester, 's06_app_info');
    });

    testWidgets('S7 uninstall confirm', (WidgetTester tester) async {
      await _pumpRoute(tester, '/');
      await tester.longPress(find.text('Weather').first);
      await tester.pump();
      await tester.tap(find.text('Uninstall…').last);
      await tester.pump(const Duration(milliseconds: 100));
      await _expectGolden(tester, 's07_uninstall_confirm');
    });

    testWidgets('S9 launch failure', (WidgetTester tester) async {
      final LauncherApp app = sampleLauncherApps().first;
      await _pumpScreen(
        tester,
        LaunchFailureScreen(
          app: app,
          failure: const LaunchFailure(
            reason: 'The app exited during startup (code 127).',
            stderr: 'lib/app.so: wrong ELF class: ELFCLASS32',
          ),
        ),
      );
      await _expectGolden(tester, 's09_launch_failure');
    });

    testWidgets('S10 settings root', (WidgetTester tester) async {
      await _pumpRoute(tester, '/settings');
      await tester.pump();
      await _expectGolden(tester, 's10_settings');
    });

    testWidgets('S11 Wi-Fi picker', (WidgetTester tester) async {
      await _pumpRoute(tester, '/settings/wifi');
      await tester.pump();
      await _expectGolden(tester, 's11_wifi_picker');
    });

    testWidgets('S11 Wi-Fi password OSK', (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        const WifiScreen(initialPasswordSsid: 'HomeNet-5G'),
      );
      await tester.pump();
      await _expectGolden(tester, 's11_wifi_password_osk');
    });

    testWidgets('S12 security PIN', (WidgetTester tester) async {
      await _pumpRoute(tester, '/settings/security');
      await _expectGolden(tester, 's12_security_pin');
    });

    testWidgets('S13 exit to stock confirm', (WidgetTester tester) async {
      await _pumpRoute(tester, '/');
      await tester.tap(find.text('reMarkable').first);
      await tester.pump();
      await _expectGolden(tester, 's13_exit_to_stock_confirm');
    });

    testWidgets('S14 uninstall Pluto step 1', (WidgetTester tester) async {
      await _pumpRoute(tester, '/settings/uninstall');
      await _expectGolden(tester, 's14_uninstall_pluto_step1');
    });

    testWidgets('S14 uninstall Pluto hold confirm', (
      WidgetTester tester,
    ) async {
      await _pumpRoute(tester, '/settings/uninstall');
      await tester.tap(find.text('Continue to uninstall'));
      await tester.pump(const Duration(milliseconds: 100));
      await _expectGolden(tester, 's14_uninstall_pluto_hold');
    });

    testWidgets('S14 uninstall Pluto progress', (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        const UninstallPlutoScreen(initialProgress: true),
      );
      await _expectGolden(tester, 's14_uninstall_pluto_progress');
    });

    testWidgets('S15 about developer', (WidgetTester tester) async {
      await _pumpRoute(tester, '/settings/about');
      await tester.pump();
      await tester.pump();
      await _expectGolden(tester, 's15_about_developer');
    });

    testWidgets('S16 standby screen', (WidgetTester tester) async {
      await _pumpScreen(tester, const StandbyScreen(beginStandby: false));
      await _expectGolden(tester, 's16_standby');
    });
  });
}

Future<void> _pumpRoute(
  WidgetTester tester,
  String route, {
  List<LauncherApp>? apps,
  Size physicalSize = const Size(954, 1696),
}) async {
  _setMoveViewport(tester, physicalSize: physicalSize);
  await tester.pumpWidget(
    PlutoLauncherApp(
      services: createHostPreviewServices(apps: apps),
      initialRoute: route,
    ),
  );
  await tester.pump();
}

List<LauncherApp> _featuredApps() {
  return sampleFeaturedLauncherApps(
    icons: <String, Uint8List>{
      'dev.pluto.codex': _iconBytes('apps/codex/assets/pluto/icon.png'),
      'dev.pluto.examples.motion_lab': _iconBytes(
        'apps/examples/motion_lab/assets/pluto/icon.png',
      ),
      'dev.pluto.examples.ink_lab': _iconBytes(
        'apps/examples/ink_lab/assets/pluto/icon.png',
      ),
      'dev.pluto.validation_lab': _iconBytes(
        'apps/validation_lab/assets/pluto/icon.png',
      ),
    },
  );
}

List<LauncherApp> _iconFamilyApps() {
  return sampleIconFamilyApps(
    icons: <String, Uint8List>{
      'dev.pluto.codex': _iconBytes('apps/codex/assets/pluto/icon.png'),
      'dev.pluto.examples.motion_lab': _iconBytes(
        'apps/examples/motion_lab/assets/pluto/icon.png',
      ),
      'dev.pluto.examples.ink_lab': _iconBytes(
        'apps/examples/ink_lab/assets/pluto/icon.png',
      ),
      'dev.pluto.validation_lab': _iconBytes(
        'apps/validation_lab/assets/pluto/icon.png',
      ),
      'dev.pluto.ink': _iconBytes('apps/ink/assets/pluto/icon_mono.png'),
      'dev.pluto.examples.counter': _iconBytes(
        'apps/examples/counter/assets/pluto/icon.png',
      ),
    },
  );
}

Uint8List _iconBytes(String relativePath) =>
    _findRepositoryFile(relativePath).readAsBytesSync();

AppSwitcherRequest _switcherRequest() {
  AppId id(String value) => AppId.tryParse(value)!;
  return AppSwitcherRequest(
    originAppId: id('dev.pluto.validation_lab'),
    previews: <AppSwitcherPreview>[
      AppSwitcherPreview(
        appId: id('dev.pluto.codex'),
        aspectRatio: 954 / 1696,
        imageBytes: _iconBytes(
          'apps/codex/test_goldens/goldens/g02_conversation_color.png',
        ),
      ),
      AppSwitcherPreview(
        appId: id('dev.pluto.examples.motion_lab'),
        aspectRatio: 954 / 1696,
        imageBytes: _iconBytes(
          'apps/launcher/test_goldens/goldens/s02_home_grid.png',
        ),
      ),
      AppSwitcherPreview(
        appId: id('dev.pluto.examples.ink_lab'),
        aspectRatio: 954 / 1696,
        imageBytes: _iconBytes(
          'apps/codex/test_goldens/goldens/g03_handwriting_draft.png',
        ),
      ),
    ],
  );
}

StatusOverlayRequest _statusOverlayRequest() {
  return StatusOverlayRequest(
    originAppId: AppId.tryParse('dev.pluto.codex')!,
    imageBytes: _iconBytes(
      'apps/codex/test_goldens/goldens/g02_conversation_color.png',
    ),
    aspectRatio: 954 / 1696,
  );
}

PowerMenuRequest _powerMenuRequest() {
  return PowerMenuRequest(originAppId: AppId.tryParse('dev.pluto.codex')!);
}

Future<void> _settleMemoryImages(WidgetTester tester) async {
  for (final Element element in find.byType(Image).evaluate()) {
    final Image image = element.widget as Image;
    await tester.runAsync(() => precacheImage(image.image, element));
  }
  await tester.pumpAndSettle();
}

final class _IconFamilySheet extends StatelessWidget {
  const _IconFamilySheet({required this.apps});

  final List<LauncherApp> apps;

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      header: const PageHeader(title: 'Field marks'),
      body: Center(
        child: SizedBox(
          width: 620,
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 72,
            runSpacing: 64,
            children: <Widget>[
              for (final LauncherApp app in apps)
                AppTile(
                  app: PaperAppTileData(
                    id: app.id.value,
                    name: app.displayName,
                    iconBytes: app.iconBytes,
                  ),
                  onLaunch: () {},
                  onManage: () {},
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget child, {
  LauncherServices? services,
  Size physicalSize = const Size(954, 1696),
}) async {
  _setMoveViewport(tester, physicalSize: physicalSize);
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: LauncherScope(
        services: services ?? createHostPreviewServices(),
        child: WidgetsApp(
          color: const Color(0xFFFFFFFF),
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
            return PaperPageRoute<T>(settings: settings, builder: builder);
          },
          debugShowCheckedModeBanner: false,
          home: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(WidgetsApp),
    matchesGoldenFile('../test_goldens/goldens/$name.png'),
  );
}

void _setMoveViewport(
  WidgetTester tester, {
  Size physicalSize = const Size(954, 1696),
}) {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _loadGoldenFonts() async {
  final Directory flutterRoot = _findFlutterRoot();
  final File testFont = _findRepositoryFile(
    'assets/test_fonts/JetBrainsMono-VariableFont_wght.ttf',
  );
  final FontLoader uiLoader = FontLoader('Inter')
    ..addFont(
      _fontData(
        '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
        'Roboto-Regular.ttf',
      ),
    );
  // Flutter's bundled Roboto fixture intentionally has a compact glyph set.
  // Register the tracked OFL test font as the first PaperTypography fallback
  // so arrows and other UI symbols are deterministic on every host OS.
  final FontLoader symbolLoader = FontLoader('Arial')
    ..addFont(_fontData(testFont.path));
  final FontLoader monoLoader = FontLoader('JetBrains Mono')
    ..addFont(_fontData(testFont.path));
  await uiLoader.load();
  await symbolLoader.load();
  await monoLoader.load();
}

File _findRepositoryFile(String relativePath) {
  Directory current = Directory.current.absolute;
  while (true) {
    final File marker = File.fromUri(
      current.uri.resolve('tools/pluto/pins/engine.version'),
    );
    if (marker.existsSync()) {
      final File file = File.fromUri(current.uri.resolve(relativePath));
      if (!file.existsSync()) {
        throw StateError('Repository fixture does not exist: ${file.path}.');
      }
      return file;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  throw StateError('Cannot locate the repository from ${Directory.current}.');
}

Directory _findFlutterRoot() {
  Directory current = File(Platform.resolvedExecutable).parent;
  while (current.parent.path != current.path) {
    final File uiFont = File.fromUri(
      current.uri.resolve(
        'bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    );
    if (uiFont.existsSync()) {
      return current;
    }
    current = current.parent;
  }
  throw StateError(
    'Cannot locate the Flutter SDK from ${Platform.resolvedExecutable}.',
  );
}

Future<ByteData> _fontData(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
}
