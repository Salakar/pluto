import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'screens.dart';
import 'models.dart';
import 'services.dart';

/// Root Pluto launcher application.
final class PlutoLauncherApp extends StatefulWidget {
  /// Creates the launcher app.
  const PlutoLauncherApp({
    required this.services,
    this.initialRoute = '/',
    super.key,
  });

  /// Injected service bundle.
  final LauncherServices services;

  /// Initial route.
  final String initialRoute;

  @override
  State<PlutoLauncherApp> createState() => _PlutoLauncherAppState();
}

final class _PlutoLauncherAppState extends State<PlutoLauncherApp>
    with WidgetsBindingObserver {
  // Assume color until the panel reports otherwise; accent tokens then
  // resolve to ink on monochrome glass (PaperPalette handles the fallback).
  bool _isColorPanel = true;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final NavigatorObserver _navigatorObserver;
  late String _currentRouteName;
  bool _checkingSystemUi = false;

  @override
  void initState() {
    super.initState();
    _currentRouteName = widget.initialRoute;
    _navigatorObserver = _LauncherNavigatorObserver((String routeName) {
      _currentRouteName = routeName;
    });
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPanelClass());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showPendingSystemUi());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_showPendingSystemUi());
      });
    }
  }

  Future<void> _showPendingSystemUi() async {
    if (!mounted || _checkingSystemUi) {
      return;
    }
    _checkingSystemUi = true;
    final PowerMenuRequest? power = await widget.services.session
        .pendingPowerMenu();
    final AppSwitcherRequest? switcher = power == null
        ? await widget.services.session.pendingAppSwitcher()
        : null;
    final StatusOverlayRequest? status = power == null && switcher == null
        ? await widget.services.session.pendingStatusOverlay()
        : null;
    _checkingSystemUi = false;
    final NavigatorState? navigator = _navigatorKey.currentState;
    final String? route = power != null
        ? '/power'
        : switcher != null
        ? '/switcher'
        : status != null
        ? '/status'
        : null;
    if (!mounted || navigator == null) {
      return;
    }
    if (route == null) {
      if (_currentRouteName == '/power' ||
          _currentRouteName == '/switcher' ||
          _currentRouteName == '/status') {
        unawaited(
          navigator.pushNamedAndRemoveUntil<void>(
            '/',
            (Route<Object?> _) => false,
          ),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            widget.services.session.systemUiReady().catchError((Object _) {}),
          );
        }
      });
      return;
    }
    final Object request = power ?? switcher ?? status!;
    if (_currentRouteName == '/power' ||
        _currentRouteName == '/switcher' ||
        _currentRouteName == '/status') {
      unawaited(navigator.pushReplacementNamed(route, arguments: request));
    } else {
      unawaited(navigator.pushNamed<void>(route, arguments: request));
    }
  }

  Future<void> _loadPanelClass() async {
    final DeviceInfo info = await widget.services.device.deviceInfo();
    if (mounted && info.isColor != _isColorPanel) {
      setState(() => _isColorPanel = info.isColor);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PaperTheme(
      data: PaperThemeData(isColorPanel: _isColorPanel),
      child: LauncherScope(
        services: widget.services,
        child: WidgetsApp(
          navigatorKey: _navigatorKey,
          navigatorObservers: <NavigatorObserver>[_navigatorObserver],
          color: const Color(0xFFFFFFFF),
          debugShowCheckedModeBanner: false,
          initialRoute: widget.initialRoute,
          onGenerateInitialRoutes: (String initialRoute) {
            // The default named-route expansion builds `/` beneath a nested
            // initial route. Standby must be the only initial page so Home
            // cannot start manifest/status I/O or flash underneath it.
            return <Route<Object?>>[
              _generateRoute(RouteSettings(name: initialRoute)),
            ];
          },
          onGenerateRoute: _generateRoute,
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
            return PaperPageRoute<T>(settings: settings, builder: builder);
          },
          title: 'Pluto Home',
        ),
      ),
    );
  }

  Route<Object?> _generateRoute(RouteSettings settings) {
    final String routeName = settings.name ?? '/';
    WidgetBuilder builder;
    if (routeName == '/welcome') {
      builder = (_) => const WelcomeScreen();
    } else if (routeName == '/settings') {
      builder = (_) => const SettingsScreen();
    } else if (routeName == '/settings/wifi') {
      builder = (_) => const WifiScreen();
    } else if (routeName == '/settings/security') {
      builder = (_) => const SecurityPinScreen();
    } else if (routeName == '/settings/uninstall') {
      builder = (_) => const UninstallPlutoScreen();
    } else if (routeName == '/settings/about') {
      builder = (_) => const AboutScreen();
    } else if (routeName == '/standby' || routeName == '/sleep') {
      builder = (_) => const StandbyScreen();
    } else if (routeName == '/power') {
      final Object? request = settings.arguments;
      builder = request is PowerMenuRequest
          ? (_) => PowerOffScreen(request: request)
          : (_) => const PowerOffActivationScreen();
    } else if (routeName == '/switcher') {
      final Object? request = settings.arguments;
      builder = request is AppSwitcherRequest
          ? (_) => AppSwitcherScreen(request: request)
          : (_) => const AppSwitcherActivationScreen();
    } else if (routeName == '/status') {
      final Object? request = settings.arguments;
      builder = request is StatusOverlayRequest
          ? (_) => StatusOverlayScreen(request: request)
          : (_) => const StatusOverlayActivationScreen();
    } else if (routeName.startsWith('/app/')) {
      builder = (_) => AppInfoScreen(appIdText: routeName.substring(5));
    } else {
      builder = (_) => const HomeScreen();
    }
    return PaperPageRoute<Object?>(settings: settings, builder: builder);
  }
}

final class _LauncherNavigatorObserver extends NavigatorObserver {
  _LauncherNavigatorObserver(this.onRouteChanged);

  final ValueChanged<String> onRouteChanged;

  void _publish(Route<dynamic>? route) {
    onRouteChanged(route?.settings.name ?? '/');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _publish(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _publish(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _publish(newRoute);
  }
}

/// Provides launcher services to screens.
final class LauncherScope extends InheritedWidget {
  /// Creates a launcher scope.
  const LauncherScope({
    required this.services,
    required super.child,
    super.key,
  });

  /// Injected services.
  final LauncherServices services;

  /// Returns services from the nearest scope.
  static LauncherServices of(BuildContext context) {
    final LauncherScope? scope = context
        .dependOnInheritedWidgetOfExactType<LauncherScope>();
    if (scope == null) {
      throw StateError('No LauncherScope found.');
    }
    return scope.services;
  }

  @override
  bool updateShouldNotify(LauncherScope oldWidget) {
    return services != oldWidget.services;
  }
}
