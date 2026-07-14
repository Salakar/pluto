import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_launcher/main.dart';
import 'package:pluto_launcher/src/screens.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'support/fake_services.dart';

void main() {
  testWidgets('launcher shows the host home gallery', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    await tester.pumpWidget(
      PlutoLauncherApp(services: createHostPreviewServices()),
    );
    await tester.pump();

    expect(find.text('Apps'), findsOneWidget);
    expect(find.text('Counter'), findsOneWidget);
    expect(find.text('Grid'), findsNothing);
    expect(find.text('List'), findsNothing);
    expect(find.byType(AppTile), findsWidgets);
  });

  testWidgets('standby initial route does not initialize Home underneath', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    _mockStandbyRefreshChannel();
    final _Harness harness = _Harness();
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/standby'),
    );
    await tester.pump();

    expect(find.text('Standing by'), findsOneWidget);
    expect(harness.repository.watchAppsCalls, 0);
    // Standby is deliberately minimal: it shows no live status, so it must
    // not subscribe to the status stream either.
    expect(harness.settings.watchStatusCalls, 0);

    // Finish the conservative Gallery3 settle timer so no async timer leaks
    // into the next widget test.
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump();
  });

  testWidgets('tapping an app launches through SessionManager', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    await tester.tap(find.text('Counter').first);
    await tester.pump();
    await tester.pump();

    expect(harness.session.launchedApps, hasLength(1));
    expect(harness.session.launchedApps.single.value, 'dev.example.counter');
    expect(find.text('Opening…'), findsNothing);
    expect(find.byType(SegmentRing), findsNothing);
    expect(find.text('Apps'), findsOneWidget);
  });

  testWidgets('launch refusal opens failure directly without loader route', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.nextLaunchResult = const LaunchFailure(
      reason: 'runtime rejected the manifest',
    );
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    await tester.tap(find.text('Counter').first);
    await tester.pump();
    await tester.pump();

    expect(find.text("Counter couldn't start"), findsOneWidget);
    expect(find.text('runtime rejected the manifest'), findsOneWidget);
    expect(find.text('Opening…'), findsNothing);
    expect(find.byType(SegmentRing), findsNothing);
  });

  testWidgets('debug installs are hidden from Home and disabled in app info', (
    WidgetTester tester,
  ) async {
    final LauncherApp debugApp = _asDebugInstall(sampleLauncherApps().first);
    final _Harness harness = _Harness(apps: <LauncherApp>[debugApp]);

    await _pumpLauncherRoute(tester, harness, '/');

    expect(find.text(debugApp.displayName), findsNothing);
    expect(find.text('No apps installed yet.'), findsOneWidget);
    expect(harness.session.launchedApps, isEmpty);

    await _pumpLauncherRoute(tester, harness, '/app/${debugApp.id.value}');

    expect(find.text('Use pluto run --debug'), findsOneWidget);
    expect(
      find.textContaining('Debug/JIT installs are hidden'),
      findsOneWidget,
    );
    await tester.tap(find.text('Use pluto run --debug'));
    await tester.pump();
    expect(harness.session.launchedApps, isEmpty);
  });

  testWidgets('app uninstall flow removes the manifest entry', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    await tester.longPress(find.text('Weather').first);
    await tester.pump();
    expect(find.text('App info'), findsOneWidget);

    await tester.tap(find.text('Uninstall…').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Uninstall Weather?'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 650));
    await tester.tap(find.text('Uninstall'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    final AppId weatherId = AppId.tryParse('dev.example.weather')!;
    expect(await harness.repository.appById(weatherId), isNull);
  });

  testWidgets('settings frontlight slider writes through settings service', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/settings'),
    );
    await tester.pump();

    final Offset topLeft = tester.getTopLeft(find.byType(DiscreteSlider));
    await tester.tapAt(topLeft + const Offset(48, 24));
    await tester.pump(const Duration(milliseconds: 100));

    expect(harness.settings.currentFrontlight.raw, 0);

    await tester.tap(find.text('Never'));
    await tester.pump();
    expect(harness.settings.standbyTimeout, isNull);

    expect(harness.settings.rotation, RotationPreference.auto);
    await tester.tap(find.text('Landscape'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.settings.rotation, RotationPreference.landscape);
    expect(harness.session.didReturnToLauncher, isTrue);
  });

  testWidgets('home and settings lay out without overflow in landscape', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1696, 954);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _Harness harness = _Harness();

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Weather'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/settings'),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Auto'), findsOneWidget);
  });

  testWidgets('home and settings adapt to the RM1 and RM2 viewport', (
    WidgetTester tester,
  ) async {
    _setRm12Viewport(tester);
    final _Harness harness = _Harness();

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Apps'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    for (final Element tile in find.byType(AppTile).evaluate()) {
      final Rect bounds = tester.getRect(find.byWidget(tile.widget));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(
        bounds.right,
        lessThanOrEqualTo(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
        ),
      );
      expect(
        bounds.bottom,
        lessThanOrEqualTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/settings'),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Auto'), findsOneWidget);
  });

  testWidgets('home pages by the live RM1 and RM2 grid capacity', (
    WidgetTester tester,
  ) async {
    _setRm12Viewport(tester);
    final _Harness harness = _Harness(apps: sampleNumberedLauncherApps(30));

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    expect(tester.takeException(), isNull);
    PageDots dots = tester.widget<PageDots>(find.byType(PageDots));
    expect(dots.count, 2);
    expect(dots.index, 0);
    final List<String> firstPage = tester
        .widgetList<AppTile>(find.byType(AppTile))
        .map((AppTile tile) => tile.app.name)
        .toList(growable: false);
    expect(firstPage, hasLength(24));
    expect(firstPage.first, 'App 00');
    expect(firstPage.last, 'App 23');

    final Rect pageDotsBounds = tester.getRect(find.byType(PageDots));
    await tester.tapAt(
      Offset(pageDotsBounds.right - 10, pageDotsBounds.center.dy),
    );
    await tester.pump();

    dots = tester.widget<PageDots>(find.byType(PageDots));
    expect(dots.count, 2);
    expect(dots.index, 1);
    final List<String> secondPage = tester
        .widgetList<AppTile>(find.byType(AppTile))
        .map((AppTile tile) => tile.app.name)
        .toList(growable: false);
    expect(secondPage, <String>[
      'App 24',
      'App 25',
      'App 26',
      'App 27',
      'App 28',
      'App 29',
      'reMarkable',
    ]);
    expect(firstPage.toSet().intersection(secondPage.toSet()), isEmpty);
  });

  testWidgets(
    'warm app switcher opens once, browses in recency order, resumes',
    (WidgetTester tester) async {
      _setMoveViewport(tester);
      final _Harness harness = _Harness();
      harness.session.switcherRequest = AppSwitcherRequest(
        originAppId: AppId.tryParse('dev.pluto.codex')!,
        previews: <AppSwitcherPreview>[
          AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
          AppSwitcherPreview(appId: AppId.tryParse('dev.example.counter')!),
        ],
      );
      await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
      await tester.pumpAndSettle();

      expect(find.byType(AppSwitcherScreen), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('switcher-preview-dev.example.weather'),
        ),
        findsOneWidget,
      );
      expect(harness.session.systemUiReadyCalls, 1);

      // A slow, deliberate drag has little release velocity but must still
      // page by distance on e-ink where there is no continuous animation.
      await tester.drag(
        find.byKey(const ValueKey<String>('app-switcher-carousel')),
        const Offset(-250, 0),
      );
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey<String>('switcher-preview-dev.example.counter'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('switcher-preview-dev.example.counter'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(harness.session.launchedApps.single.value, 'dev.example.counter');
    },
  );

  testWidgets('missing switcher preview follows the live RM1/RM2 surface', (
    WidgetTester tester,
  ) async {
    _setRm12Viewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
      ],
    );

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();

    final Rect preview = tester.getRect(
      find.byKey(
        const ValueKey<String>('switcher-preview-dev.example.weather'),
      ),
    );
    expect(preview.width / preview.height, closeTo(1404 / 1872, 0.001));
  });

  testWidgets('swiping a switcher preview up force-stops and removes it', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.counter')!),
      ],
    );
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey<String>('app-switcher-carousel')),
      const Offset(0, -180),
    );
    await tester.pump();

    expect(harness.session.forceStoppedApps, hasLength(1));
    expect(
      harness.session.forceStoppedApps.single.value,
      'dev.example.weather',
    );
    expect(
      find.byKey(
        const ValueKey<String>('switcher-preview-dev.example.weather'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('switcher-preview-dev.example.counter'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('cold switcher route is not pushed a second time', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
      ],
    );
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/switcher'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppSwitcherScreen), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('switcher-preview-dev.example.weather'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.session.launchedApps.single.value, 'dev.example.weather');
  });

  testWidgets('app switcher never renders the launcher as a card', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.pluto.launcher')!),
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
      ],
    );
    await tester.pumpWidget(
      PlutoLauncherApp(services: harness.services, initialRoute: '/switcher'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('switcher-preview-dev.pluto.launcher')),
      findsNothing,
    );
    expect(find.text('App Launcher'), findsNothing);
    expect(find.text('WARM'), findsNothing);
    expect(find.text('Running apps'), findsNothing);
    expect(find.text('Return'), findsNothing);
  });

  testWidgets('app switcher stays open when no background apps are running', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.launcher')!,
      previews: const <AppSwitcherPreview>[],
    );

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();

    expect(find.byType(AppSwitcherScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('app-switcher-empty')),
      findsOneWidget,
    );
    expect(find.text('No apps running.'), findsOneWidget);
    expect(harness.session.launchedApps, isEmpty);
    expect(harness.session.systemUiReadyCalls, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AppSwitcherScreen), findsOneWidget);
    expect(find.text('No apps running.'), findsOneWidget);
  });

  testWidgets('dismissing the last switcher card leaves the empty state', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
      ],
    );

    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey<String>('app-switcher-carousel')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();

    expect(
      harness.session.forceStoppedApps.single.value,
      'dev.example.weather',
    );
    expect(harness.session.launchedApps, isEmpty);
    expect(find.byType(AppSwitcherScreen), findsOneWidget);
    expect(find.text('No apps running.'), findsOneWidget);
  });

  testWidgets('cleared system activation restores Home on launcher resume', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.switcherRequest = AppSwitcherRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
      previews: <AppSwitcherPreview>[
        AppSwitcherPreview(appId: AppId.tryParse('dev.example.weather')!),
      ],
    );
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();
    expect(find.byType(AppSwitcherScreen), findsOneWidget);

    harness.session.switcherRequest = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byType(AppSwitcherScreen), findsNothing);
    expect(find.text('Apps'), findsOneWidget);
    expect(harness.session.systemUiReadyCalls, greaterThanOrEqualTo(2));
  });

  testWidgets('top-edge status shade opens Settings and returns to origin', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    harness.session.statusOverlayRequest = StatusOverlayRequest(
      originAppId: AppId.tryParse('dev.pluto.codex')!,
    );
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pumpAndSettle();

    expect(find.byType(StatusOverlayScreen), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('status-overlay-settings')),
    );
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);

    Navigator.of(tester.element(find.text('Settings').first)).pop();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('status-overlay-return')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.session.launchedApps.single.value, 'dev.pluto.codex');
  });

  testWidgets(
    'power menu is full-screen, signals ready, and returns to origin',
    (WidgetTester tester) async {
      _setMoveViewport(tester);
      final _Harness harness = _Harness();
      final AppId origin = AppId.tryParse('dev.pluto.codex')!;
      harness.session.powerMenuRequest = PowerMenuRequest(originAppId: origin);

      await tester.pumpWidget(
        PlutoLauncherApp(services: harness.services, initialRoute: '/power'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PowerOffScreen), findsOneWidget);
      expect(find.text('Turn off Pluto?'), findsOneWidget);
      expect(harness.repository.watchAppsCalls, 0);
      expect(harness.settings.watchStatusCalls, 0);
      expect(harness.session.systemUiReadyCalls, 1);

      await tester.tap(find.byKey(const ValueKey<String>('power-off-cancel')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(harness.session.launchedApps, <AppId>[origin]);
    },
  );

  testWidgets('power-off hold releases early and confirms only at full dwell', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness();
    await _pumpPowerOff(tester, harness);
    final Finder hold = find.byKey(const ValueKey<String>('power-off-hold'));

    TestGesture gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump(const Duration(milliseconds: 1500));
    await gesture.up();
    await tester.pump();
    expect(harness.session.didPowerOff, isFalse);
    expect(find.text('Turn off Pluto?'), findsOneWidget);

    gesture = await tester.startGesture(tester.getCenter(hold));
    await _completePowerOffHold(tester);
    expect(harness.session.didPowerOff, isTrue);
    expect(find.text('Good night'), findsOneWidget);
    await gesture.up();
  });

  testWidgets('failed power-off returns to the confirmation surface', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness();
    harness.session.powerOffError = StateError('systemd refused poweroff');
    await _pumpPowerOff(tester, harness);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('power-off-hold'))),
    );
    await _completePowerOffHold(tester);
    await gesture.up();

    expect(harness.session.didPowerOff, isTrue);
    expect(find.text('Turn off Pluto?'), findsOneWidget);
    expect(
      find.text('Could not turn off the device. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('stock UI route calls SessionManager exit-to-stock', (
    WidgetTester tester,
  ) async {
    _setMoveViewport(tester);
    final _Harness harness = _Harness();
    await tester.pumpWidget(PlutoLauncherApp(services: harness.services));
    await tester.pump();

    await tester.tap(find.text('reMarkable').first);
    await tester.pump();
    expect(find.text('Switch to reMarkable?'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 650));
    await tester.tap(find.text('Switch'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(harness.session.didSwitchToStock, isTrue);
  });

  testWidgets('app info and settings omit stale diagnostic controls', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness();
    await _pumpLauncherRoute(tester, harness, '/app/dev.example.weather');

    expect(find.text('Installed'), findsNothing);
    expect(find.text('Source'), findsNothing);
    expect(find.text('Orientation'), findsNothing);
    expect(find.text('Runtime'), findsOneWidget);

    await _pumpLauncherRoute(tester, harness, '/settings');
    expect(find.text('Ghost cleaning'), findsNothing);
    expect(find.text('Wi-Fi'), findsOneWidget);
  });

  testWidgets('about omits unsupported diagnostics', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness();
    await _pumpLauncherRoute(tester, harness, '/settings/about');

    for (final String removed in <String>[
      'Firmware',
      'Backend',
      'Renderer',
      'Ghost budget',
      'Frame stats',
      'Run display test card',
      'Show damage overlay',
      'Hide damage overlay',
    ]) {
      expect(find.text(removed), findsNothing);
    }
    expect(find.text('VM service'), findsOneWidget);
  });

  testWidgets('Wi-Fi open-network connect and toggle refresh visible state', (
    WidgetTester tester,
  ) async {
    final FakeLauncherSettings settings = FakeLauncherSettings();
    final _Harness harness = _Harness(settings: settings);
    await _pumpLauncherRoute(tester, harness, '/settings/wifi');

    await tester.tap(find.text('CafeGuest'));
    await tester.pump();
    await tester.pump();
    expect(settings.connectWifiCalls, 1);
    expect(
      settings.currentWifiStatus,
      isA<WifiConnected>().having(
        (WifiConnected status) => status.connection.ssid,
        'ssid',
        'CafeGuest',
      ),
    );

    await tester.tap(find.text('Off'));
    await tester.pump();
    await tester.pump();
    expect(settings.setWifiEnabledCalls, 1);
    expect(settings.currentWifiStatus, isA<WifiDisabled>());
    expect(find.text('Wi-Fi is off'), findsOneWidget);
  });

  testWidgets('Wi-Fi scanning label has enough button width', (
    WidgetTester tester,
  ) async {
    final Completer<void> scanGate = Completer<void>();
    addTearDown(() {
      if (!scanGate.isCompleted) {
        scanGate.complete();
      }
    });
    final FakeLauncherSettings settings = FakeLauncherSettings()
      ..scanWifiDelay = scanGate.future;
    await _pumpLauncherRoute(
      tester,
      _Harness(settings: settings),
      '/settings/wifi',
    );

    final Finder button = find.widgetWithText(PaperButton, 'Scanning…');
    expect(button, findsOneWidget);
    expect(tester.getSize(button).width, 132);

    scanGate.complete();
    await tester.pump();
  });

  testWidgets('Wi-Fi scan and password failures are visible and recoverable', (
    WidgetTester tester,
  ) async {
    final FakeLauncherSettings scanFailure = FakeLauncherSettings()
      ..scanWifiError = StateError('scan unavailable');
    await _pumpLauncherRoute(
      tester,
      _Harness(settings: scanFailure),
      '/settings/wifi',
    );
    expect(find.textContaining('scan unavailable'), findsOneWidget);

    final FakeLauncherSettings authFailure = FakeLauncherSettings()
      ..connectWifiError = StateError('authentication rejected');
    await _pumpLauncherRoute(
      tester,
      _Harness(settings: authFailure),
      '/settings/wifi',
    );
    await tester.tap(find.text('HomeNet-5G'));
    await tester.pump();
    await tester.tap(find.text('p'));
    await tester.pump();
    await tester.tap(find.text('Join'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(authFailure.connectWifiCalls, 1);
    expect(authFailure.lastWifiPassphrase, 'p');
    expect(find.textContaining('authentication rejected'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);

    final FakeLauncherSettings platformFailure = FakeLauncherSettings()
      ..scanWifiError = PlatformException(
        code: 'unavailable',
        message: 'wpa_supplicant scan failed',
      );
    await _pumpLauncherRoute(
      tester,
      _Harness(settings: platformFailure),
      '/settings/wifi',
    );
    expect(find.text('Wi-Fi: wpa_supplicant scan failed'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
  });

  test('real status stream is stable and preserves telemetry truth', () async {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var sequence = 0;

    Future<({ChannelLauncherSettings settings, StatusSnapshot status})> read({
      required Map<String, Object?> battery,
      required Map<String, Object?> wifi,
    }) async {
      sequence += 1;
      final MethodChannel channel = MethodChannel(
        'pluto/test/settings/$sequence',
      );
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return switch (call.method) {
          'batteryGet' => battery,
          'wifiStatus' => wifi,
          'frontlightGet' => <String, Object?>{'raw': 1024, 'max': 2048},
          'networkInfo' => <String, Object?>{
            'usbConnected': battery['isUsbNetworkConnected'],
            'usbIp': battery['isUsbNetworkConnected'] == true
                ? '10.11.99.1'
                : '',
            'wifiIp': wifi['ipAddress'] ?? '',
          },
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final ChannelLauncherSettings settings = ChannelLauncherSettings(
        channel: channel,
      );
      addTearDown(settings.dispose);
      final Stream<StatusSnapshot> stream = settings.watchStatus();
      expect(identical(stream, settings.watchStatus()), isTrue);
      final StatusSnapshot status = await stream.first.timeout(
        const Duration(seconds: 2),
      );
      return (settings: settings, status: status);
    }

    final commonBattery = <String, Object?>{
      'levelPercent': 73,
      'markerLevelPercent': 81,
      'isCharging': false,
      'isUsbPowerPresent': true,
      'isUsbNetworkConnected': false,
    };
    final disabled = await read(
      battery: commonBattery,
      wifi: <String, Object?>{'status': 'disabled'},
    );
    expect(disabled.status.isWifiEnabled, isFalse);
    expect(disabled.status.wifi, isNull);
    expect(disabled.status.battery.levelPercent, 73);
    expect(disabled.status.battery.isCharging, isFalse);
    expect(disabled.status.penBattery?.levelPercent, 81);
    expect(disabled.status.frontlightRaw, 1024);
    expect(disabled.status.frontlightMaxRaw, 2048);
    expect(disabled.status.isUsbTethered, isFalse);

    final disconnected = await read(
      battery: commonBattery,
      wifi: <String, Object?>{'status': 'disconnected'},
    );
    expect(disconnected.status.isWifiEnabled, isTrue);
    expect(disconnected.status.wifi, isNull);

    final connected = await read(
      battery: <String, Object?>{
        ...commonBattery,
        'isUsbPowerPresent': false,
        'isUsbNetworkConnected': true,
      },
      wifi: <String, Object?>{
        'status': 'connected',
        'ssid': 'HomeNet',
        'ipAddress': '192.168.1.44',
        'signal': 0.82,
      },
    );
    expect(connected.status.isWifiEnabled, isTrue);
    expect(connected.status.wifi?.ssid, 'HomeNet');
    expect(connected.status.wifi?.signalPercent, 82);
    expect(connected.status.isUsbTethered, isTrue);
    final LauncherNetworkInfo network = await connected.settings.networkInfo();
    expect(network.usbIp, '10.11.99.1');
    expect(network.wifiIp, '192.168.1.44');
  });

  test('successful settings mutations refresh status immediately', () async {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const MethodChannel channel = MethodChannel('pluto/test/settings/refresh');
    var wifiEnabled = true;
    var frontlightRaw = 160;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'batteryGet':
          return <String, Object?>{
            'levelPercent': 73,
            'isCharging': false,
            'isUsbNetworkConnected': false,
          };
        case 'wifiStatus':
          return <String, Object?>{
            'status': wifiEnabled ? 'disconnected' : 'disabled',
          };
        case 'frontlightGet':
          return <String, Object?>{'raw': frontlightRaw, 'max': 2048};
        case 'wifiSetEnabled':
          wifiEnabled =
              (call.arguments! as Map<Object?, Object?>)['enabled']! as bool;
          return null;
        case 'frontlightSet':
          frontlightRaw =
              (call.arguments! as Map<Object?, Object?>)['raw']! as int;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final ChannelLauncherSettings settings = ChannelLauncherSettings(
      channel: channel,
    );
    addTearDown(settings.dispose);
    final Stream<StatusSnapshot> stream = settings.watchStatus();
    expect((await stream.first).isWifiEnabled, isTrue);

    final Future<StatusSnapshot> wifiRefresh = stream.firstWhere(
      (StatusSnapshot status) => !status.isWifiEnabled,
    );
    await settings.setWifiEnabled(false);
    expect(
      (await wifiRefresh.timeout(const Duration(seconds: 1))).isWifiEnabled,
      isFalse,
    );

    final Future<StatusSnapshot> lightRefresh = stream.firstWhere(
      (StatusSnapshot status) => status.frontlightRaw == 900,
    );
    await settings.setFrontlightRaw(900);
    expect(
      (await lightRefresh.timeout(const Duration(seconds: 1))).frontlightRaw,
      900,
    );
  });

  testWidgets('accepted standby handoff leaves the frontlight off', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(
      frontlight: const FrontlightState(raw: 913, maxRaw: 2047),
    );

    await _pumpStandby(tester, harness);

    expect(harness.session.didHandoffStandby, isTrue);
    expect(harness.settings.currentFrontlight.raw, 0);
    expect(harness.session.didReturnToLauncher, isFalse);

    await tester.pump(const Duration(milliseconds: 100));
    expect(harness.settings.currentFrontlight.raw, 0);
    expect(harness.session.didReturnToLauncher, isFalse);
  });

  testWidgets('standby restores frontlight after handoff failure', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(
      frontlight: const FrontlightState(raw: 347, maxRaw: 2047),
    );
    harness.session.standbyHandoffError = StateError('handoff write failed');

    await _pumpStandby(tester, harness);
    await tester.pump();

    expect(harness.session.didHandoffStandby, isTrue);
    expect(harness.settings.currentFrontlight.raw, 347);
    expect(harness.session.didReturnToLauncher, isTrue);
    expect(find.textContaining('Standby was interrupted'), findsOneWidget);
  });
}

Future<void> _pumpStandby(WidgetTester tester, _Harness harness) async {
  _setMoveViewport(tester);
  _mockStandbyRefreshChannel();
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: LauncherScope(
        services: harness.services,
        child: WidgetsApp(
          color: const Color(0xFFFFFFFF),
          debugShowCheckedModeBanner: false,
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
            return PaperPageRoute<T>(settings: settings, builder: builder);
          },
          home: const StandbyScreen(settleDelay: Duration.zero),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpPowerOff(WidgetTester tester, _Harness harness) async {
  _setMoveViewport(tester);
  _mockPowerRefreshChannel();
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: LauncherScope(
        services: harness.services,
        child: WidgetsApp(
          color: const Color(0xFFFFFFFF),
          debugShowCheckedModeBanner: false,
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
            return PaperPageRoute<T>(settings: settings, builder: builder);
          },
          home: PowerOffScreen(
            request: PowerMenuRequest(
              originAppId: AppId.tryParse('dev.pluto.codex')!,
            ),
            settleDelay: Duration.zero,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _completePowerOffHold(WidgetTester tester) async {
  for (int segment = 0; segment < 6; segment += 1) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pump();
  await tester.pump();
}

void _mockPowerRefreshChannel() {
  const MethodChannel channel = MethodChannel('pluto/refresh');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

void _mockStandbyRefreshChannel() {
  const MethodChannel channel = MethodChannel('pluto/refresh');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

Future<void> _pumpLauncherRoute(
  WidgetTester tester,
  _Harness harness,
  String route,
) async {
  // Dispose any previous navigator so a new initialRoute is honored when a
  // test exercises multiple launcher roots with the same widget type.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  _setMoveViewport(tester);
  await tester.pumpWidget(
    PlutoLauncherApp(services: harness.services, initialRoute: route),
  );
  await tester.pump();
  await tester.pump();
}

void _setMoveViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _setRm12Viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1404, 1872);
  tester.view.devicePixelRatio = 226 / 160;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _Harness {
  _Harness({
    FrontlightState? frontlight,
    FakeLauncherSettings? settings,
    List<LauncherApp>? apps,
  }) : repository = FakeManifestRepository(apps: apps ?? sampleLauncherApps()),
       session = FakeSessionManager(),
       settings = settings ?? FakeLauncherSettings(frontlight: frontlight) {
    services = LauncherServices(
      manifests: repository,
      session: session,
      settings: this.settings,
      device: const FakeLauncherDeviceRepository(),
    );
  }

  final FakeManifestRepository repository;
  final FakeSessionManager session;
  final FakeLauncherSettings settings;
  late final LauncherServices services;
}

LauncherApp _asDebugInstall(LauncherApp app) {
  return LauncherApp(
    manifest: app.manifest,
    installRecord: app.installRecord,
    installKind: LauncherInstallKind.dev,
    health: app.health,
    isPinned: app.isPinned,
    sizeBytes: app.sizeBytes,
    dataSizeBytes: app.dataSizeBytes,
    updatedAt: app.updatedAt,
    sourceHost: app.sourceHost,
  );
}
