import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'launcher_app.dart';
import 'models.dart';
import 'services.dart';

const List<int> _frontlightCurve = <int>[0, 64, 160, 320, 560, 900, 1400, 2047];
const MethodChannel _refreshChannel = MethodChannel('pluto/refresh');
const String _launcherAppId = 'dev.pluto.launcher';

/// S1 first-run welcome screen.
final class WelcomeScreen extends StatefulWidget {
  /// Creates the welcome screen.
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

final class _WelcomeScreenState extends State<WelcomeScreen> {
  int _page = 0;
  Future<LauncherNetworkInfo>? _networkInfo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _networkInfo ??= LauncherScope.of(context).settings.networkInfo();
  }

  void _next() {
    if (_page < 2) {
      setState(() {
        _page += 1;
      });
      EinkRefreshRegion.request(
        context,
        refreshClass: RefreshClass.text,
        reason: 'welcome.page',
      );
      return;
    }
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LauncherNetworkInfo>(
      future: _networkInfo,
      builder: (BuildContext context, AsyncSnapshot<LauncherNetworkInfo> snapshot) {
        final LauncherNetworkInfo network =
            snapshot.data ?? const LauncherNetworkInfo();
        final List<_WelcomeCard> cards = <_WelcomeCard>[
          _WelcomeCard(
            title: 'Flutter for reMarkable.',
            body:
                'This tablet now runs Pluto Home. Your reMarkable notes app is untouched and remains available from Home.',
            codeLines: <String>[
              r'$ pluto devices',
              r'$ pluto install <app>',
              if (network.usbIp != null)
                'This device over USB: ${network.usbIp}',
            ],
          ),
          _WelcomeCard(
            title: 'Install apps from your computer.',
            body:
                'Build normal Flutter apps, add a Pluto manifest, and install them over USB or Wi-Fi. Installs appear live on Home.',
            codeLines: <String>[
              r'$ pluto run',
              r'$ pluto install ./my_app',
              if (network.wifiIp != null) 'Wi-Fi: ${network.wifiIp}',
            ],
          ),
          const _WelcomeCard(
            title: 'Paper-first gestures.',
            body:
                'Tap to launch, long-press to manage, and swipe across a page band to flip pages. Every interaction answers with a crisp one-refresh state.',
            codeLines: <String>['No scrolling. No tweens. Just pages.'],
          ),
        ];
        return _LauncherPage(
          showHeader: false,
          pageIndicator: PageDots(count: cards.length, index: _page),
          body: Padding(
            padding: const EdgeInsets.all(PaperSpacing.pageMargin),
            child: Column(
              children: <Widget>[
                Expanded(child: cards[_page]),
                Align(
                  alignment: Alignment.bottomRight,
                  child: SizedBox(
                    width: 160,
                    child: PaperButton.primary(
                      label: _page == 2 ? 'Start' : 'Continue',
                      onPressed: _next,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({
    required this.title,
    required this.body,
    required this.codeLines,
  });

  final String title;
  final String body;
  final List<String> codeLines;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const _PlutoMark(size: 112),
        const SizedBox(height: PaperSpacing.space32),
        Text(title, textAlign: TextAlign.center, style: theme.type.heading),
        const SizedBox(height: PaperSpacing.space16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: theme.type.body,
          ),
        ),
        const SizedBox(height: PaperSpacing.space32),
        PaperCodeBlock(lines: codeLines),
      ],
    );
  }
}

/// S2/S3/S4 Home screen.
final class HomeScreen extends StatefulWidget {
  /// Creates Home.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends State<HomeScreen> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final LauncherServices services = LauncherScope.of(context);
    return StreamBuilder<List<LauncherApp>>(
      stream: services.manifests.watchApps(),
      builder:
          (BuildContext context, AsyncSnapshot<List<LauncherApp>> snapshot) {
            if (!snapshot.hasData) {
              return const _LauncherPage(
                title: 'Apps',
                body: PaperLoadingState(label: 'Reading installed apps…'),
              );
            }
            final List<LauncherApp> apps =
                (snapshot.data ?? const <LauncherApp>[])
                    .where(
                      (LauncherApp app) => !app.requiresExplicitDebugLaunch,
                    )
                    .toList(growable: false);
            final Widget body = apps.isEmpty
                ? _EmptyHome(
                    onSwitchToStock: () => _showExitToStockConfirm(context),
                  )
                : _HomePager(
                    apps: apps,
                    page: _page,
                    onPageChanged: _setPage,
                    onLaunch: _launchApp,
                    onManage: _showAppSheet,
                    onShowInfo: _showAppInfo,
                    onSwitchToStock: () => _showExitToStockConfirm(context),
                  );
            return _LauncherPage(title: 'Apps', body: body);
          },
    );
  }

  void _setPage(int page) {
    if (page == _page) {
      return;
    }
    setState(() {
      _page = page;
    });
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.text,
      reason: 'home.page',
    );
  }

  void _launchApp(LauncherApp app) {
    unawaited(_launchWithoutInterstitial(context, app));
  }

  void _showAppInfo(LauncherApp app) {
    Navigator.of(context).pushNamed('/app/${app.id.value}');
  }

  Future<void> _showAppSheet(LauncherApp app) async {
    final BuildContext homeContext = context;
    await PaperDialogs.showSheet<void>(
      context,
      builder: (BuildContext sheetContext) {
        return _AppContextSheet(
          app: app,
          onOpen: () {
            Navigator.of(sheetContext).pop();
            _launchApp(app);
          },
          onInfo: () {
            Navigator.of(sheetContext).pop();
            Navigator.of(homeContext).pushNamed('/app/${app.id.value}');
          },
          onPin: () async {
            Navigator.of(sheetContext).pop();
            await LauncherScope.of(
              homeContext,
            ).manifests.setPinned(app.id, isPinned: !app.isPinned);
          },
          onUninstall: () {
            Navigator.of(sheetContext).pop();
            unawaited(_confirmUninstallApp(homeContext, app));
          },
        );
      },
    );
  }
}

/// Resolves a supervisor app-switcher activation on cold start or warm resume.
final class AppSwitcherActivationScreen extends StatefulWidget {
  /// Creates the activation loader.
  const AppSwitcherActivationScreen({super.key});

  @override
  State<AppSwitcherActivationScreen> createState() =>
      _AppSwitcherActivationScreenState();
}

final class _AppSwitcherActivationScreenState
    extends State<AppSwitcherActivationScreen> {
  Future<AppSwitcherRequest?>? _request;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _request ??= LauncherScope.of(context).session.pendingAppSwitcher();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSwitcherRequest?>(
      future: _request,
      builder:
          (BuildContext context, AsyncSnapshot<AppSwitcherRequest?> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox.expand(),
              );
            }
            final AppSwitcherRequest? request = snapshot.data;
            if (request == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.of(context).pushReplacementNamed('/');
                }
              });
              return const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox.expand(),
              );
            }
            return AppSwitcherScreen(request: request);
          },
    );
  }
}

/// Paper-native carousel of warm running app windows.
final class AppSwitcherScreen extends StatefulWidget {
  /// Creates a running-app switcher for [request].
  const AppSwitcherScreen({required this.request, super.key});

  /// Supervisor-authored origin and recency order.
  final AppSwitcherRequest request;

  @override
  State<AppSwitcherScreen> createState() => _AppSwitcherScreenState();
}

final class _AppSwitcherScreenState extends State<AppSwitcherScreen> {
  Future<_SwitcherViewData>? _viewData;
  int _index = 0;
  bool _launching = false;
  String? _stoppingAppId;
  final Set<String> _dismissedAppIds = <String>{};
  bool _systemUiReadySignaled = false;
  int _readyPreviewIndex = -1;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewData ??= _resolveApps(LauncherScope.of(context).manifests);
  }

  Future<_SwitcherViewData> _resolveApps(ManifestRepository manifests) async {
    final List<_SwitcherApp> apps = <_SwitcherApp>[];
    for (final AppSwitcherPreview preview in widget.request.previews) {
      if (preview.appId.value == _launcherAppId) {
        continue;
      }
      final LauncherApp? app = await manifests.appById(preview.appId);
      apps.add(
        _SwitcherApp(
          appId: preview.appId,
          name: app?.displayName ?? _fallbackAppName(preview.appId.value),
          previewBytes: preview.imageBytes,
          previewAspectRatio: preview.aspectRatio,
        ),
      );
    }
    return _SwitcherViewData(apps: apps);
  }

  void _setIndex(int index, int count) {
    final int next = index.clamp(0, math.max(0, count - 1));
    if (next == _index) {
      return;
    }
    setState(() {
      _index = next;
      _error = null;
    });
  }

  void _requestQualityRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _refreshChannel
            .invokeMethod<Object?>('requestFullRefresh')
            .catchError((Object _) => null),
      );
    });
  }

  Future<void> _activate(AppId appId) async {
    if (_launching || _stoppingAppId != null) {
      return;
    }
    setState(() {
      _launching = true;
      _error = null;
    });
    final LaunchResult result = await LauncherScope.of(
      context,
    ).session.launch(appId);
    if (!mounted) {
      return;
    }
    if (result is LaunchFailure) {
      setState(() {
        _launching = false;
        _error = result.reason;
      });
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      unawaited(navigator.pushReplacementNamed('/'));
    }
  }

  Future<void> _forceStop(AppId appId) async {
    if (_launching || _stoppingAppId != null) {
      return;
    }
    setState(() {
      _stoppingAppId = appId.value;
      _error = null;
    });
    try {
      await LauncherScope.of(context).session.forceStop(appId);
      final _SwitcherViewData? resolved = await _viewData;
      if (!mounted) {
        return;
      }
      final Set<String> dismissed = <String>{..._dismissedAppIds, appId.value};
      final int remaining =
          resolved?.apps
              .where((_SwitcherApp app) => !dismissed.contains(app.appId.value))
              .length ??
          0;
      setState(() {
        _dismissedAppIds.add(appId.value);
        _index = _index.clamp(0, math.max(0, remaining - 1));
        _stoppingAppId = null;
      });
      _requestQualityRefresh();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stoppingAppId = null;
        _error = 'Could not close ${appId.value}: $error';
      });
    }
  }

  void _signalSystemUiReady() {
    if (_systemUiReadySignaled) {
      return;
    }
    _systemUiReadySignaled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        LauncherScope.of(
          context,
        ).session.systemUiReady().catchError((Object _) {}),
      );
    });
  }

  void _previewReady(int index) {
    if (_readyPreviewIndex == index) {
      return;
    }
    _readyPreviewIndex = index;
    if (!_systemUiReadySignaled) {
      _signalSystemUiReady();
    } else {
      _requestQualityRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_SwitcherViewData>(
      future: _viewData,
      builder:
          (BuildContext context, AsyncSnapshot<_SwitcherViewData> snapshot) {
            if (!snapshot.hasData) {
              return const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox.expand(),
              );
            }
            final _SwitcherViewData data = snapshot.data!;
            final List<_SwitcherApp> apps = data.apps
                .where(
                  (_SwitcherApp app) =>
                      !_dismissedAppIds.contains(app.appId.value),
                )
                .toList(growable: false);
            if (apps.isEmpty) {
              _signalSystemUiReady();
              final PaperThemeData theme = PaperTheme.of(context);
              return ColoredBox(
                key: const ValueKey<String>('app-switcher-empty'),
                color: theme.palette.paper,
                child: Center(
                  child: Text('No apps running.', style: theme.type.body),
                ),
              );
            }
            final int safeIndex = apps.isEmpty
                ? 0
                : _index.clamp(0, apps.length - 1);
            final _SwitcherApp selected = apps[safeIndex];
            return _SwitcherCarousel(
              key: const ValueKey<String>('app-switcher-carousel'),
              apps: apps,
              index: safeIndex,
              interactionLocked: _launching || _stoppingAppId != null,
              error: _error,
              onPrevious: () => _setIndex(safeIndex - 1, apps.length),
              onNext: () => _setIndex(safeIndex + 1, apps.length),
              onActivate: () => _activate(selected.appId),
              onDismiss: () => _forceStop(selected.appId),
              onPreviewReady: () => _previewReady(safeIndex),
            );
          },
    );
  }
}

/// Resolves a supervisor status-shade activation on cold start or warm resume.
final class StatusOverlayActivationScreen extends StatefulWidget {
  /// Creates the status activation loader.
  const StatusOverlayActivationScreen({super.key});

  @override
  State<StatusOverlayActivationScreen> createState() =>
      _StatusOverlayActivationScreenState();
}

final class _StatusOverlayActivationScreenState
    extends State<StatusOverlayActivationScreen> {
  Future<StatusOverlayRequest?>? _request;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _request ??= LauncherScope.of(context).session.pendingStatusOverlay();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StatusOverlayRequest?>(
      future: _request,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<StatusOverlayRequest?> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _LauncherPage(
                showHeader: false,
                body: PaperLoadingState(label: 'Opening device status…'),
              );
            }
            final StatusOverlayRequest? request = snapshot.data;
            if (request == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.of(context).pushReplacementNamed('/');
                }
              });
              return const _LauncherPage(
                showHeader: false,
                body: PaperLoadingState(label: 'Returning home…'),
              );
            }
            return StatusOverlayScreen(request: request);
          },
    );
  }
}

/// Temporary system status shade drawn over the origin app's captured frame.
final class StatusOverlayScreen extends StatefulWidget {
  /// Creates a status shade.
  const StatusOverlayScreen({required this.request, super.key});

  /// Supervisor-authored origin and preview.
  final StatusOverlayRequest request;

  @override
  State<StatusOverlayScreen> createState() => _StatusOverlayScreenState();
}

final class _StatusOverlayScreenState extends State<StatusOverlayScreen> {
  Future<String>? _originName;
  bool _returning = false;
  bool _qualityRefreshRequested = false;
  bool _systemUiReadySignaled = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _originName ??= _resolveOriginName();
  }

  Future<String> _resolveOriginName() async {
    final ManifestRepository manifests = LauncherScope.of(context).manifests;
    if (widget.request.originAppId.value == _launcherAppId) {
      return 'App Launcher';
    }
    final LauncherApp? app = await manifests.appById(
      widget.request.originAppId,
    );
    return app?.displayName ??
        _fallbackAppName(widget.request.originAppId.value);
  }

  void _openSettings() {
    unawaited(Navigator.of(context).pushNamed('/settings'));
  }

  Future<void> _returnToOrigin() async {
    if (_returning) {
      return;
    }
    setState(() {
      _returning = true;
      _error = null;
    });
    final LaunchResult result = await LauncherScope.of(
      context,
    ).session.launch(widget.request.originAppId);
    if (!mounted) {
      return;
    }
    if (result is LaunchFailure) {
      setState(() {
        _returning = false;
        _error = result.reason;
      });
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      unawaited(navigator.pushReplacementNamed('/'));
    }
  }

  void _signalSystemUiReady() {
    if (_systemUiReadySignaled) {
      return;
    }
    _systemUiReadySignaled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        LauncherScope.of(
          context,
        ).session.systemUiReady().catchError((Object _) {}),
      );
    });
  }

  void _requestQualityRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _refreshChannel
            .invokeMethod<Object?>('requestFullRefresh')
            .catchError((Object _) => null),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return FutureBuilder<String>(
      future: _originName,
      builder: (BuildContext context, AsyncSnapshot<String> nameSnapshot) {
        if (!nameSnapshot.hasData) {
          return const _LauncherPage(
            showHeader: false,
            body: PaperLoadingState(label: 'Reading app preview…'),
          );
        }
        if (!_qualityRefreshRequested) {
          _qualityRefreshRequested = true;
          _requestQualityRefresh();
        }
        _signalSystemUiReady();
        final String originName = nameSnapshot.data!;
        return ColoredBox(
          color: theme.palette.grayDD,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _StatusPreviewBackground(
                originName: originName,
                imageBytes: widget.request.imageBytes,
              ),
              Align(
                alignment: Alignment.topCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.palette.paper,
                    border: Border(
                      bottom: BorderSide(color: theme.palette.ink, width: 2),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(
                        height: 22,
                        child: Center(child: _StatusGestureMark()),
                      ),
                      StreamBuilder<StatusSnapshot>(
                        stream: LauncherScope.of(
                          context,
                        ).settings.watchStatus(),
                        builder:
                            (
                              BuildContext context,
                              AsyncSnapshot<StatusSnapshot> snapshot,
                            ) {
                              final StatusSnapshot? status = snapshot.data;
                              if (status == null) {
                                return const SizedBox(
                                  height: StatusBar.height,
                                  child: Center(child: Text('Device status')),
                                );
                              }
                              return StatusBar(
                                key: const ValueKey<String>(
                                  'status-overlay-bar',
                                ),
                                snapshot: status,
                                onTapCluster: _openSettings,
                              );
                            },
                      ),
                      Semantics(
                        button: true,
                        label: 'Open Settings',
                        child: GestureDetector(
                          key: const ValueKey<String>(
                            'status-overlay-settings',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onTap: _openSettings,
                          child: SizedBox(
                            height: 44,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: PaperSpacing.pageMargin,
                              ),
                              child: Row(
                                children: <Widget>[
                                  Text(
                                    'Open Settings',
                                    style: theme.type.label,
                                  ),
                                  const Spacer(),
                                  Text('›', style: theme.type.heading),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(PaperSpacing.pageMargin),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.palette.paper,
                      border: Border.all(color: theme.palette.ink),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(PaperSpacing.space8),
                      child: SizedBox(
                        width: 300,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            PaperButton(
                              key: const ValueKey<String>(
                                'status-overlay-return',
                              ),
                              label: _returning
                                  ? 'Returning…'
                                  : 'Return to $originName',
                              onPressed: _returning ? null : _returnToOrigin,
                            ),
                            if (_error != null) ...<Widget>[
                              const SizedBox(height: 6),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: theme.type.caption.copyWith(
                                  color: theme.palette.accentRed,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _StatusPreviewBackground extends StatelessWidget {
  const _StatusPreviewBackground({
    required this.originName,
    required this.imageBytes,
  });

  final String originName;
  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Uint8List? bytes = imageBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    }
    return ColoredBox(
      color: theme.palette.grayDD,
      child: Center(
        child: Text(
          originName,
          style: theme.type.heading.copyWith(color: theme.palette.gray66),
        ),
      ),
    );
  }
}

final class _StatusGestureMark extends StatelessWidget {
  const _StatusGestureMark();

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      label: 'Two-finger swipe down from the top edge',
      child: Text(
        '↓  ↓',
        style: theme.type.mono.copyWith(
          fontSize: 14,
          color: theme.palette.gray33,
        ),
      ),
    );
  }
}

final class _SwitcherCarousel extends StatelessWidget {
  const _SwitcherCarousel({
    required this.apps,
    required this.index,
    required this.interactionLocked,
    required this.error,
    required this.onPrevious,
    required this.onNext,
    required this.onActivate,
    required this.onDismiss,
    required this.onPreviewReady,
    super.key,
  });

  final List<_SwitcherApp> apps;
  final int index;
  final bool interactionLocked;
  final String? error;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final VoidCallback onPreviewReady;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final _SwitcherApp selected = apps[index];
    final Size viewport = MediaQuery.sizeOf(context);
    final double liveSurfaceAspect = viewport.height > 0
        ? viewport.width / viewport.height
        : 1;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double aspect = selected.previewAspectRatio ?? liveSurfaceAspect;
        final double previewWidth = math.min(
          constraints.maxWidth * 0.86,
          constraints.maxHeight * 0.82 * aspect,
        );
        final double previewHeight = previewWidth / aspect;
        if (selected.previewBytes == null) {
          onPreviewReady();
        }
        double dragDistance = 0;
        double verticalDragDistance = 0;
        return ColoredBox(
          color: theme.palette.paper,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              dragDistance = 0;
            },
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              dragDistance += details.primaryDelta ?? 0;
            },
            onHorizontalDragEnd: (DragEndDetails details) {
              if (interactionLocked) {
                return;
              }
              final double velocity = details.primaryVelocity ?? 0;
              if ((velocity < -80 || dragDistance < -36) &&
                  index < apps.length - 1) {
                onNext();
              } else if ((velocity > 80 || dragDistance > 36) && index > 0) {
                onPrevious();
              }
            },
            onVerticalDragStart: (_) {
              verticalDragDistance = 0;
            },
            onVerticalDragUpdate: (DragUpdateDetails details) {
              verticalDragDistance += details.primaryDelta ?? 0;
            },
            onVerticalDragEnd: (DragEndDetails details) {
              if (interactionLocked) {
                return;
              }
              final double velocity = details.primaryVelocity ?? 0;
              if (velocity < -120 || verticalDragDistance < -64) {
                onDismiss();
              }
            },
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: previewWidth,
                    height: previewHeight,
                    child: _SwitcherPreview(
                      app: selected,
                      onTap: interactionLocked ? null : onActivate,
                      onReady: onPreviewReady,
                    ),
                  ),
                  if (apps.length > 1) ...<Widget>[
                    const SizedBox(height: 24),
                    _SwitcherPageDots(count: apps.length, index: index),
                  ],
                  if (error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: theme.type.caption.copyWith(
                        color: theme.palette.accentRed,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _SwitcherPreview extends StatelessWidget {
  const _SwitcherPreview({
    required this.app,
    required this.onTap,
    required this.onReady,
  });

  final _SwitcherApp app;
  final VoidCallback? onTap;
  final VoidCallback onReady;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      button: onTap != null,
      label: 'Resume ${app.name}',
      child: GestureDetector(
        key: ValueKey<String>('switcher-preview-${app.appId.value}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.palette.paper,
            border: Border.all(color: theme.palette.ink),
          ),
          child: app.previewBytes == null
              ? _MissingSwitcherPreview(app: app)
              : Image.memory(
                  app.previewBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  frameBuilder:
                      (
                        BuildContext context,
                        Widget child,
                        int? frame,
                        bool wasSynchronouslyLoaded,
                      ) {
                        if (frame != null) {
                          onReady();
                        }
                        return child;
                      },
                ),
        ),
      ),
    );
  }
}

final class _SwitcherPageDots extends StatelessWidget {
  const _SwitcherPageDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      label: 'App ${index + 1} of $count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(count, (int dot) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SizedBox.square(
              dimension: 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dot == index ? theme.palette.ink : theme.palette.paper,
                  border: Border.all(color: theme.palette.ink),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

final class _MissingSwitcherPreview extends StatelessWidget {
  const _MissingSwitcherPreview({required this.app});

  final _SwitcherApp app;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.grayDD,
      child: Center(
        child: Text(
          'Preview unavailable',
          style: theme.type.caption.copyWith(color: theme.palette.gray33),
        ),
      ),
    );
  }
}

final class _SwitcherViewData {
  const _SwitcherViewData({required this.apps});

  final List<_SwitcherApp> apps;
}

final class _SwitcherApp {
  const _SwitcherApp({
    required this.appId,
    required this.name,
    required this.previewBytes,
    required this.previewAspectRatio,
  });

  final AppId appId;
  final String name;
  final Uint8List? previewBytes;
  final double? previewAspectRatio;
}

String _fallbackAppName(String id) {
  final String leaf = id.split('.').last.replaceAll('_', ' ');
  return leaf.isEmpty
      ? 'App'
      : '${leaf.substring(0, 1).toUpperCase()}${leaf.substring(1)}';
}

final class _HomePager extends StatelessWidget {
  const _HomePager({
    required this.apps,
    required this.page,
    required this.onPageChanged,
    required this.onLaunch,
    required this.onManage,
    required this.onShowInfo,
    required this.onSwitchToStock,
  });

  final List<LauncherApp> apps;
  final int page;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<LauncherApp> onLaunch;
  final ValueChanged<LauncherApp> onManage;
  final ValueChanged<LauncherApp> onShowInfo;
  final VoidCallback onSwitchToStock;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int itemCount = apps.length + 1;
        final int fullHeightCapacity = _homeGridCapacity(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
        );
        final bool showsPageIndicator =
            _homePageCount(itemCount, fullHeightCapacity) > 1;
        final double gridHeight = math.max(
          0,
          constraints.maxHeight -
              (showsPageIndicator ? PaperSpacing.touchTargetMin : 0),
        );
        final int capacity = _homeGridCapacity(
          maxWidth: constraints.maxWidth,
          maxHeight: gridHeight,
        );
        final int pageCount = _homePageCount(itemCount, capacity);
        final int safePage = page.clamp(0, pageCount - 1).toInt();
        final Widget grid = _HomeGrid(
          apps: apps,
          page: safePage,
          capacity: capacity,
          onPageChanged: onPageChanged,
          onLaunch: onLaunch,
          onManage: onManage,
          onShowInfo: onShowInfo,
          onSwitchToStock: onSwitchToStock,
        );
        if (!showsPageIndicator) {
          return grid;
        }
        return Column(
          children: <Widget>[
            Expanded(child: grid),
            PageDots(
              count: pageCount,
              index: safePage,
              onPrevious: () => onPageChanged(math.max(0, safePage - 1)),
              onNext: () =>
                  onPageChanged(math.min(pageCount - 1, safePage + 1)),
            ),
          ],
        );
      },
    );
  }
}

final class _HomeGrid extends StatelessWidget {
  const _HomeGrid({
    required this.apps,
    required this.page,
    required this.capacity,
    required this.onPageChanged,
    required this.onLaunch,
    required this.onManage,
    required this.onShowInfo,
    required this.onSwitchToStock,
  });

  final List<LauncherApp> apps;
  final int page;
  final int capacity;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<LauncherApp> onLaunch;
  final ValueChanged<LauncherApp> onManage;
  final ValueChanged<LauncherApp> onShowInfo;
  final VoidCallback onSwitchToStock;

  @override
  Widget build(BuildContext context) {
    final List<_TileEntry> entries = <_TileEntry>[
      for (final LauncherApp app in apps) _TileEntry.app(app),
      const _TileEntry.system(),
    ];
    final int pageCount = _homePageCount(entries.length, capacity);
    final int safePage = page.clamp(0, pageCount - 1).toInt();
    final int start = safePage * capacity;
    final List<_TileEntry> visible = entries
        .skip(start)
        .take(capacity)
        .toList(growable: false);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (DragEndDetails details) {
        final double velocity = details.primaryVelocity ?? 0;
        if (velocity < -100 && safePage < pageCount - 1) {
          onPageChanged(safePage + 1);
        } else if (velocity > 100 && safePage > 0) {
          onPageChanged(safePage - 1);
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(PaperSpacing.pageMargin),
        child: Wrap(
          spacing: PaperSpacing.gutter,
          runSpacing: PaperSpacing.space20,
          children: <Widget>[
            for (final _TileEntry entry in visible)
              AppTile(
                app: entry.tileData,
                state: entry.app?.isBroken == true
                    ? AppTileState.broken
                    : AppTileState.idle,
                onLaunch: entry.app == null
                    ? onSwitchToStock
                    // Broken apps cannot start; honor the tile's
                    // "Tap for info" promise instead.
                    : entry.app!.isBroken
                    ? () => onShowInfo(entry.app!)
                    : () => onLaunch(entry.app!),
                onManage: entry.app == null
                    ? onSwitchToStock
                    : () => onManage(entry.app!),
              ),
          ],
        ),
      ),
    );
  }
}

final class _EmptyHome extends StatefulWidget {
  const _EmptyHome({required this.onSwitchToStock});

  final VoidCallback onSwitchToStock;

  @override
  State<_EmptyHome> createState() => _EmptyHomeState();
}

final class _EmptyHomeState extends State<_EmptyHome> {
  Future<LauncherNetworkInfo>? _networkInfo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _networkInfo ??= LauncherScope.of(context).settings.networkInfo();
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Padding(
      padding: const EdgeInsets.all(PaperSpacing.pageMargin),
      child: Column(
        children: <Widget>[
          Expanded(
            child: PaperEmptyState(
              icon: const _InstallTargetMark(),
              title: 'No apps installed yet.',
              message: 'Install your first app from your computer:',
              extra: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const PaperCodeBlock(
                    lines: <String>[
                      r'$ pluto devices',
                      r'$ pluto install ./my_app',
                    ],
                  ),
                  const SizedBox(height: PaperSpacing.space12),
                  FutureBuilder<LauncherNetworkInfo>(
                    future: _networkInfo,
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<LauncherNetworkInfo> snapshot,
                        ) {
                          final LauncherNetworkInfo network =
                              snapshot.data ?? const LauncherNetworkInfo();
                          final String addresses = <String>[
                            if (network.usbIp != null) 'USB ${network.usbIp}',
                            if (network.wifiIp != null)
                              'Wi-Fi ${network.wifiIp}',
                          ].join(' · ');
                          if (addresses.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            addresses,
                            style: theme.type.mono.copyWith(
                              fontSize: 12,
                              height: 16 / 12,
                            ),
                          );
                        },
                  ),
                ],
              ),
            ),
          ),
          _Hairline(),
          PaperListItem(
            height: 72,
            padding: EdgeInsets.zero,
            leading: const _SmallMonogram(
              PaperAppTileData(
                id: 'stock.remarkable',
                name: 'reMarkable',
                isSystem: true,
              ),
            ),
            title: 'reMarkable',
            subtitle: 'Stock UI — always available',
            trailing: Text('→', style: theme.type.mono),
            onTap: widget.onSwitchToStock,
          ),
        ],
      ),
    );
  }
}

final class _InstallTargetMark extends StatelessWidget {
  const _InstallTargetMark();

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox.square(
      dimension: 96,
      child: CustomPaint(painter: _InstallTargetPainter(theme.palette.ink)),
    );
  }
}

/// Dashed drop-target square with a downward arrow: "apps land here".
final class _InstallTargetPainter extends CustomPainter {
  const _InstallTargetPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    _paintDashedRect(canvas, Offset.zero & size, stroke, 10, 6);
    final Offset center = size.center(Offset.zero);
    final double shaftTop = size.height * 0.28;
    final double shaftBottom = size.height * 0.66;
    canvas.drawLine(
      Offset(center.dx, shaftTop),
      Offset(center.dx, shaftBottom),
      stroke,
    );
    canvas.drawLine(
      Offset(center.dx - 12, shaftBottom - 12),
      Offset(center.dx, shaftBottom),
      stroke,
    );
    canvas.drawLine(
      Offset(center.dx + 12, shaftBottom - 12),
      Offset(center.dx, shaftBottom),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_InstallTargetPainter oldDelegate) =>
      color != oldDelegate.color;
}

void _paintDashedRect(
  Canvas canvas,
  Rect rect,
  Paint paint,
  double dash,
  double gap,
) {
  void drawLine(Offset start, Offset end) {
    final double length = (end - start).distance;
    if (length == 0) {
      return;
    }
    final Offset direction = (end - start) / length;
    double travelled = 0;
    while (travelled < length) {
      final double segmentEnd = math.min(travelled + dash, length);
      canvas.drawLine(
        start + direction * travelled,
        start + direction * segmentEnd,
        paint,
      );
      travelled += dash + gap;
    }
  }

  drawLine(rect.topLeft, rect.topRight);
  drawLine(rect.topRight, rect.bottomRight);
  drawLine(rect.bottomRight, rect.bottomLeft);
  drawLine(rect.bottomLeft, rect.topLeft);
}

final class _AppContextSheet extends StatelessWidget {
  const _AppContextSheet({
    required this.app,
    required this.onOpen,
    required this.onInfo,
    required this.onPin,
    required this.onUninstall,
  });

  final LauncherApp app;
  final VoidCallback onOpen;
  final VoidCallback onInfo;
  final VoidCallback onPin;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _SmallMonogram(
                PaperAppTileData(
                  id: app.id.value,
                  name: app.displayName,
                  isPinned: app.isPinned,
                  isBroken: app.isBroken,
                ),
              ),
              const SizedBox(width: PaperSpacing.space12),
              Expanded(
                child: Text(
                  app.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.heading,
                ),
              ),
              Text(
                'v${app.versionText}',
                style: theme.type.mono.copyWith(color: theme.palette.gray33),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space20),
          PaperButton.primary(label: 'Open', onPressed: onOpen),
          const SizedBox(height: PaperSpacing.space12),
          Row(
            children: <Widget>[
              Expanded(
                child: PaperButton(label: 'App info', onPressed: onInfo),
              ),
              const SizedBox(width: PaperSpacing.space12),
              Expanded(
                child: PaperButton(
                  label: app.isPinned ? 'Unpin' : 'Pin to front',
                  onPressed: onPin,
                ),
              ),
            ],
          ),
          const SizedBox(height: PaperSpacing.space16),
          _Hairline(),
          const SizedBox(height: PaperSpacing.space16),
          PaperButton.destructive(label: 'Uninstall…', onPressed: onUninstall),
          const SizedBox(height: PaperSpacing.space8),
          Center(
            child: PaperButton.ghost(
              label: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// S6 App info screen.
final class AppInfoScreen extends StatefulWidget {
  /// Creates the app info screen.
  const AppInfoScreen({required this.appIdText, super.key});

  /// App id path segment.
  final String appIdText;

  @override
  State<AppInfoScreen> createState() => _AppInfoScreenState();
}

final class _AppInfoScreenState extends State<AppInfoScreen> {
  AppId? _appId;
  Future<LauncherApp?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appId ??= AppId.tryParse(widget.appIdText);
    final AppId? appId = _appId;
    if (appId != null) {
      _future ??= LauncherScope.of(context).manifests.appById(appId);
    }
  }

  void _reload() {
    final AppId? appId = _appId;
    if (appId == null) {
      return;
    }
    setState(() {
      _future = LauncherScope.of(context).manifests.appById(appId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_appId == null) {
      return _InfoError(message: 'Invalid app id: ${widget.appIdText}');
    }
    return FutureBuilder<LauncherApp?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<LauncherApp?> snapshot) {
        final LauncherApp? app = snapshot.data;
        if (app == null) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _LauncherPage(
              body: PaperLoadingState(label: 'Loading app…'),
            );
          }
          return _InfoError(message: 'App not found: ${widget.appIdText}');
        }
        return _AppInfo(app: app, onChanged: _reload);
      },
    );
  }
}

final class _AppInfo extends StatelessWidget {
  const _AppInfo({required this.app, required this.onChanged});

  final LauncherApp app;

  /// Called after an action mutates the app record.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final LauncherAppHealth health = app.health;
    return _LauncherPage(
      title: 'App info',
      leading: _BackButton(label: 'Apps', route: '/'),
      body: Padding(
        padding: const EdgeInsets.all(PaperSpacing.pageMargin),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: PaperSpacing.space4),
            Row(
              children: <Widget>[
                _LargeMonogram(app.displayName),
                const SizedBox(width: PaperSpacing.space20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(app.displayName, style: theme.type.heading),
                      const SizedBox(height: PaperSpacing.space4),
                      Text(
                        app.id.value,
                        style: theme.type.mono.copyWith(
                          color: theme.palette.gray33,
                        ),
                      ),
                      Text(
                        'Version ${app.versionText}',
                        style: theme.type.body,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: PaperSpacing.space20),
            _HeavyRule(),
            const SizedBox(height: PaperSpacing.space8),
            _InfoRow(
              'Size',
              '${_formatBytes(app.sizeBytes)} app · ${_formatBytes(app.dataSizeBytes)} data',
            ),
            _InfoRow('Updated', _formatDateTime(app.updatedAt)),
            _InfoRow(
              'Runtime',
              'Flutter ${app.manifest.engine.flutterVersion} / ${app.installKind.name}',
            ),
            const SizedBox(height: PaperSpacing.space8),
            _HeavyRule(),
            const SizedBox(height: PaperSpacing.space20),
            if (app.requiresExplicitDebugLaunch) ...<Widget>[
              PaperSurface(
                hairline: true,
                child: Text(
                  'Debug/JIT installs are hidden from Home. Start this app '
                  'from your computer with `pluto run --debug '
                  '${app.id.value}`.',
                  style: theme.type.body,
                ),
              ),
              const SizedBox(height: PaperSpacing.space12),
            ],
            PaperButton.primary(
              label: app.requiresExplicitDebugLaunch
                  ? 'Use pluto run --debug'
                  : 'Open',
              onPressed: app.requiresExplicitDebugLaunch
                  ? null
                  : () => unawaited(_launchWithoutInterstitial(context, app)),
            ),
            const SizedBox(height: PaperSpacing.space12),
            Row(
              children: <Widget>[
                Expanded(
                  child: PaperButton(
                    label: 'Clear app data',
                    onPressed: app.dataSizeBytes <= 0
                        ? null
                        : () => unawaited(
                            _confirmClearAppData(context, app, onChanged),
                          ),
                  ),
                ),
                const SizedBox(width: PaperSpacing.space12),
                Expanded(
                  child: PaperButton.destructive(
                    label: 'Uninstall…',
                    onPressed: () =>
                        unawaited(_confirmUninstallApp(context, app)),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              health is LauncherAppBroken
                  ? 'Manifest error — ${health.reason}'
                  : 'Manifest OK — exact shape verified',
              style: health is LauncherAppBroken
                  ? theme.type.mono.copyWith(color: theme.palette.accentRed)
                  : theme.type.caption.copyWith(color: theme.palette.gray33),
            ),
          ],
        ),
      ),
    );
  }
}

final class _InfoError extends StatelessWidget {
  const _InfoError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _LauncherPage(
      title: 'App info',
      leading: _BackButton(label: 'Apps', route: '/'),
      body: PaperErrorState(title: 'App unavailable', message: message),
    );
  }
}

/// Requests the native handoff immediately, without rendering an animated
/// interstitial first. On e-ink the old segment-ring route cost an extra
/// page transition and periodic panel updates while the current engine was
/// already shutting down. A successful handoff terminates this Flutter view;
/// only a synchronous native refusal needs another route.
Future<void> _launchWithoutInterstitial(
  BuildContext context,
  LauncherApp app, {
  bool replaceFailure = false,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final LaunchResult result = app.requiresExplicitDebugLaunch
      ? LaunchFailure(
          reason:
              'Debug/JIT installs do not launch from Home. Use '
              '`pluto run --debug ${app.id.value}` from your computer.',
        )
      : await LauncherScope.of(context).session.launch(app.id);
  if (!context.mounted || result is! LaunchFailure) {
    return;
  }
  final PaperPageRoute<Object?> route = PaperPageRoute<Object?>(
    builder: (_) => LaunchFailureScreen(app: app, failure: result),
    settings: const RouteSettings(name: '/launch-failure'),
  );
  if (replaceFailure) {
    await navigator.pushReplacement(route);
  } else {
    await navigator.push(route);
  }
}

/// S9 Launch failure screen.
final class LaunchFailureScreen extends StatelessWidget {
  /// Creates a launch failure screen.
  const LaunchFailureScreen({
    required this.app,
    required this.failure,
    super.key,
  });

  /// App that failed.
  final LauncherApp app;

  /// Failure details.
  final LaunchFailure failure;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final TextStyle metaMono = theme.type.mono.copyWith(
      fontSize: 12,
      height: 16 / 12,
      color: theme.palette.gray33,
    );
    return ColoredBox(
      color: theme.palette.paper,
      child: Padding(
        padding: const EdgeInsets.all(PaperSpacing.space24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(child: WarningMark(size: 56)),
            const SizedBox(height: PaperSpacing.space24),
            Text(
              "${app.displayName} couldn't start",
              textAlign: TextAlign.center,
              style: theme.type.heading,
            ),
            const SizedBox(height: PaperSpacing.space12),
            Text(
              failure.reason,
              textAlign: TextAlign.center,
              style: theme.type.body,
            ),
            const SizedBox(height: PaperSpacing.space24),
            PaperSurface(
              hairline: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('STDERR', style: metaMono),
                  const SizedBox(height: PaperSpacing.space8),
                  Text(
                    failure.stderr ??
                        'No stderr was reported by the Pluto supervisor.',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.mono,
                  ),
                ],
              ),
            ),
            const SizedBox(height: PaperSpacing.space8),
            Text('Full log: pluto logs ${app.id.value}', style: metaMono),
            const SizedBox(height: PaperSpacing.space32),
            PaperButton.primary(
              label: 'Retry',
              onPressed: () => unawaited(
                _launchWithoutInterstitial(context, app, replaceFailure: true),
              ),
            ),
            const SizedBox(height: PaperSpacing.space12),
            Row(
              children: <Widget>[
                Expanded(
                  child: PaperButton(
                    label: 'App info',
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/app/${app.id.value}'),
                  ),
                ),
                const SizedBox(width: PaperSpacing.space12),
                Expanded(
                  child: PaperButton(
                    label: 'Home',
                    onPressed: () =>
                        Navigator.of(context).pushReplacementNamed('/'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// S10 Settings root.
final class SettingsScreen extends StatefulWidget {
  /// Creates settings.
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

final class _SettingsScreenState extends State<SettingsScreen> {
  int _frontlightRaw = 1250;
  int _frontlightMax = 2047;
  int _frontlightNotch = 5;
  bool _hasFrontlight = false;
  RotationPreference _rotation = RotationPreference.auto;
  String _standby = '20 min';
  String? _wifiSubtitle;
  String? _pinSubtitle;
  bool _loadedState = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedState) {
      return;
    }
    _loadedState = true;
    unawaited(_loadState());
  }

  /// Opens a settings subpage and refreshes summaries when it pops back.
  Future<void> _openSubpage(String route) async {
    await Navigator.of(context).pushNamed(route);
    if (mounted) {
      unawaited(_loadState());
    }
  }

  Future<void> _loadState() async {
    final LauncherServices services = LauncherScope.of(context);
    final LauncherSettings settings = services.settings;
    bool hasFrontlight = false;
    FrontlightState? frontlight;
    RotationPreference rotation = RotationPreference.auto;
    try {
      final DeviceCapabilities capabilities = await services.device
          .capabilities();
      hasFrontlight = capabilities.supports(Capability.frontlight);
    } catch (_) {
      // Fail closed: never offer a hardware control unless the validated
      // device profile explicitly reports it.
    }
    if (hasFrontlight) {
      try {
        frontlight = await settings.frontlight();
      } catch (_) {
        // Keep the last truthful value instead of fabricating hardware state.
      }
    }
    try {
      rotation = await settings.rotationPreference();
    } catch (_) {
      // Auto is the product default when persisted settings are unavailable.
    }
    final WifiStatus wifiStatus = await settings.wifiStatus();
    final bool hasPin = await settings.hasPin();
    if (!mounted) {
      return;
    }
    setState(() {
      _hasFrontlight = hasFrontlight;
      if (frontlight != null) {
        _frontlightRaw = frontlight.raw;
        _frontlightMax = frontlight.maxRaw;
        _frontlightNotch = _nearestFrontlightNotch(frontlight.raw);
      }
      _rotation = rotation;
      _wifiSubtitle = switch (wifiStatus) {
        WifiConnected(:final WifiConnection connection) => connection.ssid,
        WifiConnecting(:final String ssid) => 'Connecting to $ssid…',
        WifiDisconnected() => 'Not connected',
        WifiDisabled() => 'Off',
      };
      _pinSubtitle = hasPin ? 'On' : 'Off';
    });
  }

  Future<void> _setRotation(RotationPreference preference) async {
    final RotationPreference previous = _rotation;
    setState(() => _rotation = preference);
    try {
      final LauncherServices services = LauncherScope.of(context);
      await services.settings.setRotationPreference(preference);
      // The supervisor resolves this preference against the launcher's
      // manifest and restarts with the matching viewport/presenter geometry.
      await services.session.returnToLauncher();
    } catch (error) {
      debugPrint('Rotation change failed: $error');
      if (mounted) {
        setState(() => _rotation = previous);
      }
    }
  }

  Future<void> _setFrontlightNotch(int notch) async {
    final int previousNotch = _frontlightNotch;
    final int previousRaw = _frontlightRaw;
    final int raw =
        _frontlightCurve[notch.clamp(0, _frontlightCurve.length - 1).toInt()];
    setState(() {
      _frontlightNotch = notch;
      _frontlightRaw = raw;
    });
    try {
      await LauncherScope.of(context).settings.setFrontlightRaw(raw);
    } catch (error) {
      debugPrint('Standby handoff failed: $error');
      if (mounted) {
        setState(() {
          _frontlightNotch = previousNotch;
          _frontlightRaw = previousRaw;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final int frontlightPercent = _frontlightMax <= 0
        ? 0
        : ((_frontlightRaw / _frontlightMax) * 100).round().clamp(0, 100);
    final Text arrow = Text('→', style: theme.type.mono);
    return _LauncherPage(
      title: 'Settings',
      leading: _BackButton(label: 'Apps', route: '/'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: PaperSpacing.pageMargin,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SectionLabel('DISPLAY'),
            if (_hasFrontlight) ...<Widget>[
              SizedBox(
                height: 28,
                child: Row(
                  children: <Widget>[
                    Text('Frontlight', style: theme.type.body),
                    const Spacer(),
                    Text(
                      frontlightPercent == 0 ? 'off' : '$frontlightPercent%',
                      style: theme.type.mono.copyWith(
                        color: theme.palette.gray33,
                      ),
                    ),
                  ],
                ),
              ),
              DiscreteSlider(
                notchCount: _frontlightCurve.length,
                notchIndex: _frontlightNotch,
                leadingLabel: 'off',
                onNotchChanged: (int notch) =>
                    unawaited(_setFrontlightNotch(notch)),
              ),
            ],
            _SegmentSetting<RotationPreference>(
              label: 'Rotation',
              value: _rotation,
              segments: const <PaperSegment<RotationPreference>>[
                PaperSegment<RotationPreference>(
                  value: RotationPreference.portrait,
                  label: 'Portrait',
                ),
                PaperSegment<RotationPreference>(
                  value: RotationPreference.landscape,
                  label: 'Landscape',
                ),
                PaperSegment<RotationPreference>(
                  value: RotationPreference.auto,
                  label: 'Auto',
                ),
              ],
              onChanged: (RotationPreference value) =>
                  unawaited(_setRotation(value)),
            ),
            _Divider(),
            _SectionLabel('NETWORK'),
            PaperListItem(
              title: 'Wi-Fi',
              subtitle: _wifiSubtitle,
              padding: EdgeInsets.zero,
              height: 48,
              trailing: arrow,
              onTap: () => unawaited(_openSubpage('/settings/wifi')),
            ),
            _Divider(),
            _SectionLabel('POWER'),
            _SegmentSetting<String>(
              label: 'Standby after',
              value: _standby,
              segments: const <PaperSegment<String>>[
                PaperSegment<String>(value: '5 min', label: '5 min'),
                PaperSegment<String>(value: '20 min', label: '20 min'),
                PaperSegment<String>(value: '1 h', label: '1 h'),
                PaperSegment<String>(value: 'Never', label: 'Never'),
              ],
              onChanged: (String value) {
                setState(() => _standby = value);
                unawaited(
                  LauncherScope.of(
                    context,
                  ).settings.setStandbyTimeout(_standbyDuration(value)),
                );
              },
            ),
            _ButtonSetting(
              label: 'Sleep now',
              buttonLabel: 'Sleep',
              onPressed: () =>
                  unawaited(LauncherScope.of(context).session.sleepNow()),
            ),
            _Divider(),
            _SectionLabel('SECURITY'),
            PaperListItem(
              title: 'Lock PIN',
              subtitle: _pinSubtitle,
              padding: EdgeInsets.zero,
              height: 48,
              trailing: arrow,
              onTap: () => unawaited(_openSubpage('/settings/security')),
            ),
            _Divider(),
            _SectionLabel('SYSTEM'),
            PaperListItem(
              title: 'Switch to reMarkable',
              padding: EdgeInsets.zero,
              height: 48,
              trailing: arrow,
              onTap: () => _showExitToStockConfirm(context),
            ),
            PaperListItem(
              title: 'About',
              padding: EdgeInsets.zero,
              height: 48,
              trailing: arrow,
              onTap: () => Navigator.of(context).pushNamed('/settings/about'),
            ),
          ],
        ),
      ),
    );
  }
}

/// S11 Wi-Fi picker.
final class WifiScreen extends StatefulWidget {
  /// Creates Wi-Fi screen.
  const WifiScreen({this.initialPasswordSsid, super.key});

  /// Optional initial password prompt for goldens.
  final String? initialPasswordSsid;

  @override
  State<WifiScreen> createState() => _WifiScreenState();
}

final class _WifiScreenState extends State<WifiScreen> {
  List<WifiNetwork> _networks = const <WifiNetwork>[];
  WifiStatus _status = const WifiDisconnected();
  bool _enabled = true;
  String? _passwordSsid;
  String _password = '';
  bool _loaded = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passwordSsid = widget.initialPasswordSsid;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load({bool clearError = true}) async {
    final LauncherSettings settings = LauncherScope.of(context).settings;
    if (mounted) {
      setState(() {
        _loading = true;
        if (clearError) {
          _error = null;
        }
      });
    }
    try {
      final WifiStatus status = await settings.wifiStatus();
      if (!mounted) {
        return;
      }
      final bool enabled = status is! WifiDisabled;
      setState(() {
        _status = status;
        _enabled = enabled;
        if (!enabled) {
          _networks = const <WifiNetwork>[];
          _loading = false;
        }
      });
      if (!enabled) {
        return;
      }
      final List<WifiNetwork> networks = await settings.scanWifiNetworks();
      if (!mounted) {
        return;
      }
      setState(() {
        _networks = networks;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = _wifiErrorText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final String? passwordSsid = _passwordSsid;
    return _LauncherPage(
      title: 'Wi-Fi',
      leading: _BackButton(label: 'Settings', route: '/settings'),
      trailing: PaperToggle(
        value: _enabled,
        onChanged: (bool value) => unawaited(_setEnabled(value)),
        onLabel: 'On',
        offLabel: 'Off',
      ),
      body: passwordSsid == null
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PaperSpacing.pageMargin,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_error case final String error) ...<Widget>[
                    SizedBox(
                      height: 52,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.copyWith(
                            color: theme.palette.accentRed,
                          ),
                        ),
                      ),
                    ),
                    _Divider(),
                  ],
                  _SectionLabel('CONNECTED'),
                  if (_status is WifiConnected)
                    _WifiNetworkRow(
                      network: _networkFor(
                        (_status as WifiConnected).connection,
                      ),
                      trailing: SizedBox(
                        width: 96,
                        child: PaperButton(
                          label: _busy ? 'Working…' : 'Forget',
                          onPressed: _busy
                              ? null
                              : () => unawaited(
                                  _forgetNetwork(
                                    (_status as WifiConnected).connection.ssid,
                                  ),
                                ),
                        ),
                      ),
                      onTap: () {},
                    )
                  else
                    SizedBox(
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          switch (_status) {
                            WifiDisabled() => 'Wi-Fi is off',
                            WifiConnecting(:final String ssid) =>
                              ssid.isEmpty
                                  ? 'Connecting…'
                                  : 'Connecting to $ssid…',
                            _ => 'No active network',
                          },
                          style: theme.type.body.copyWith(
                            color: theme.palette.gray33,
                          ),
                        ),
                      ),
                    ),
                  _Divider(),
                  SizedBox(
                    height: 56,
                    child: Row(
                      children: <Widget>[
                        const _SectionLabel('NETWORKS'),
                        const Spacer(),
                        SizedBox(
                          width: 132,
                          child: PaperButton(
                            label: _loading ? 'Scanning…' : 'Rescan',
                            onPressed: _busy || _loading || !_enabled
                                ? null
                                : () => unawaited(_load()),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_enabled && !_loading && _networks.isEmpty)
                    SizedBox(
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'No networks found',
                          style: theme.type.body.copyWith(
                            color: theme.palette.gray33,
                          ),
                        ),
                      ),
                    ),
                  for (final WifiNetwork network in _networks.where(
                    (WifiNetwork network) => !network.isActive,
                  ))
                    _WifiNetworkRow(
                      network: network,
                      onTap: _busy
                          ? () {}
                          : () {
                              if (network.security == WifiSecurity.open) {
                                unawaited(_connect(network.ssid));
                              } else {
                                setState(() {
                                  _passwordSsid = network.ssid;
                                  _error = null;
                                });
                              }
                            },
                    ),
                ],
              ),
            )
          : _WifiPasswordPane(
              ssid: passwordSsid,
              password: _password,
              error: _error,
              joining: _busy,
              onCancel: _busy
                  ? () {}
                  : () => setState(() {
                      _passwordSsid = null;
                      _password = '';
                      _error = null;
                    }),
              onPasswordChanged: (String password) =>
                  setState(() => _password = password),
              onJoin: () => _connect(passwordSsid, passphrase: _password),
            ),
    );
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy || enabled == _enabled) {
      return;
    }
    final bool previousEnabled = _enabled;
    final WifiStatus previousStatus = _status;
    final List<WifiNetwork> previousNetworks = _networks;
    setState(() {
      _busy = true;
      _error = null;
      _enabled = enabled;
      _status = enabled ? const WifiDisconnected() : const WifiDisabled();
      if (!enabled) {
        _networks = const <WifiNetwork>[];
      }
    });
    try {
      await LauncherScope.of(context).settings.setWifiEnabled(enabled);
      if (mounted) {
        await _load();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _enabled = previousEnabled;
          _status = previousStatus;
          _networks = previousNetworks;
          _error = _wifiErrorText(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _connect(String ssid, {String? passphrase}) async {
    if (_busy) {
      return;
    }
    final WifiStatus previousStatus = _status;
    setState(() {
      _busy = true;
      _error = null;
      _status = WifiConnecting(ssid: ssid);
    });
    try {
      final WifiConnection connection = await LauncherScope.of(
        context,
      ).settings.connectWifi(ssid: ssid, passphrase: passphrase);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = WifiConnected(connection: connection);
        _passwordSsid = null;
        _password = '';
      });
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = previousStatus;
          _error = _wifiErrorText(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _forgetNetwork(String ssid) async {
    final bool confirmed = await PaperDialogs.confirm(
      context,
      title: 'Forget "$ssid"?',
      message: 'The saved password is removed and Wi-Fi disconnects.',
      confirmLabel: 'Forget',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await LauncherScope.of(context).settings.forgetWifi(ssid);
      if (mounted) {
        await _load();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _wifiErrorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  WifiNetwork _networkFor(WifiConnection connection) {
    for (final WifiNetwork network in _networks) {
      if (network.ssid == connection.ssid) {
        return WifiNetwork(
          ssid: network.ssid,
          signal: connection.signal,
          security: network.security,
          isKnown: network.isKnown,
          isActive: true,
        );
      }
    }
    return WifiNetwork(
      ssid: connection.ssid,
      signal: connection.signal,
      security: WifiSecurity.unknown,
      isKnown: true,
      isActive: true,
    );
  }
}

String _wifiErrorText(Object error) {
  if (error is PlatformException) {
    final String detail = error.message?.trim() ?? '';
    return 'Wi-Fi: ${detail.isEmpty ? error.code : detail}';
  }
  if (error is PlutoException) {
    final String detail = error.message.trim();
    return detail.isEmpty ? 'Wi-Fi request failed.' : 'Wi-Fi: $detail';
  }
  final String message = error
      .toString()
      .replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '')
      .trim();
  return message.isEmpty ? 'Wi-Fi request failed.' : 'Wi-Fi: $message';
}

final class _WifiPasswordPane extends StatefulWidget {
  const _WifiPasswordPane({
    required this.ssid,
    required this.password,
    required this.error,
    required this.joining,
    required this.onPasswordChanged,
    required this.onCancel,
    required this.onJoin,
  });

  final String ssid;
  final String password;
  final String? error;
  final bool joining;
  final ValueChanged<String> onPasswordChanged;
  final VoidCallback onCancel;
  final Future<void> Function() onJoin;

  @override
  State<_WifiPasswordPane> createState() => _WifiPasswordPaneState();
}

final class _WifiPasswordPaneState extends State<_WifiPasswordPane> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final String password = widget.password;
    final String fieldText = _obscured
        ? '${List<String>.filled(password.length, '*').join()}_'
        : '${password}_';
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(PaperSpacing.pageMargin),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Join "${widget.ssid}"', style: theme.type.heading),
                const SizedBox(height: PaperSpacing.space24),
                Text('Password', style: theme.type.label),
                const SizedBox(height: PaperSpacing.space8),
                SizedBox(
                  height: PaperSpacing.touchTargetMin,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: PaperSurface(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              fieldText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.type.mono,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: PaperSpacing.space8),
                      SizedBox(
                        width: 84,
                        child: PaperButton(
                          label: _obscured ? 'Show' : 'Hide',
                          onPressed: () =>
                              setState(() => _obscured = !_obscured),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.error case final String error) ...<Widget>[
                  const SizedBox(height: PaperSpacing.space12),
                  Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.copyWith(
                      color: theme.palette.accentRed,
                    ),
                  ),
                ],
                const SizedBox(height: PaperSpacing.space24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    PaperButton.ghost(
                      label: 'Cancel',
                      onPressed: widget.onCancel,
                    ),
                    const SizedBox(width: PaperSpacing.space12),
                    SizedBox(
                      width: 160,
                      child: PaperButton.primary(
                        label: widget.joining ? 'Joining…' : 'Join',
                        onPressed: widget.joining
                            ? null
                            : () => unawaited(widget.onJoin()),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        PaperKeyboard(
          submitLabel: 'join',
          onText: (String text) {
            if (!widget.joining) {
              widget.onPasswordChanged('$password$text');
            }
          },
          onBackspace: () {
            if (!widget.joining) {
              widget.onPasswordChanged(
                password.isEmpty
                    ? ''
                    : password.substring(0, password.length - 1),
              );
            }
          },
          onSubmit: () {
            if (!widget.joining) {
              unawaited(widget.onJoin());
            }
          },
        ),
      ],
    );
  }
}

/// S12 Security PIN screen.
final class SecurityPinScreen extends StatefulWidget {
  /// Creates security PIN screen.
  const SecurityPinScreen({super.key});

  @override
  State<SecurityPinScreen> createState() => _SecurityPinScreenState();
}

final class _SecurityPinScreenState extends State<SecurityPinScreen> {
  String _digits = '';

  void _add(String digit) {
    if (_digits.length >= 8) {
      return;
    }
    setState(() => _digits = '$_digits$digit');
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return _LauncherPage(
      title: 'Lock PIN',
      leading: _BackButton(label: 'Settings', route: '/settings'),
      body: Padding(
        padding: const EdgeInsets.all(PaperSpacing.pageMargin),
        child: Column(
          children: <Widget>[
            const SizedBox(height: PaperSpacing.space24),
            Text(
              'Set a 4–8 digit PIN for this tablet.',
              textAlign: TextAlign.center,
              style: theme.type.body,
            ),
            const SizedBox(height: PaperSpacing.space32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int i = 0; i < 8; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _PinSlot(
                      filled: i < _digits.length,
                      required: i < 4,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: PaperSpacing.space32),
            for (final List<String> row in const <List<String>>[
              <String>['1', '2', '3'],
              <String>['4', '5', '6'],
              <String>['7', '8', '9'],
              <String>['del', '0', 'OK'],
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: PaperSpacing.space12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    for (final String key in row)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PaperSpacing.space8,
                        ),
                        child: SizedBox(
                          width: 84,
                          height: 60,
                          child: _pinKey(key),
                        ),
                      ),
                  ],
                ),
              ),
            const Spacer(),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 180,
                child: PaperButton.destructive(
                  label: 'Remove PIN',
                  onPressed: () => unawaited(_removePin()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pinKey(String key) {
    if (key == 'del') {
      return PaperButton(
        label: 'del',
        onPressed: () => setState(
          () => _digits = _digits.isEmpty
              ? ''
              : _digits.substring(0, _digits.length - 1),
        ),
      );
    }
    if (key == 'OK') {
      return PaperButton.primary(
        label: 'OK',
        onPressed: _digits.length < 4 ? null : () => unawaited(_savePin()),
      );
    }
    return PaperButton(label: key, onPressed: () => _add(key));
  }

  Future<void> _savePin() async {
    final NavigatorState navigator = Navigator.of(context);
    await LauncherScope.of(context).settings.setPin(_digits);
    if (mounted) {
      // Return to Settings so the saved state is immediately visible.
      await navigator.maybePop();
    }
  }

  Future<void> _removePin() async {
    final bool confirmed = await PaperDialogs.confirm(
      context,
      title: 'Remove the lock PIN?',
      message: 'The tablet will no longer ask for a PIN on wake.',
      confirmLabel: 'Remove',
    );
    if (confirmed && mounted) {
      await LauncherScope.of(context).settings.removePin();
    }
  }
}

/// S15 About screen.
final class AboutScreen extends StatefulWidget {
  /// Creates About.
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

final class _AboutScreenState extends State<AboutScreen> {
  Future<_AboutData>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _aboutData(LauncherScope.of(context));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AboutData>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<_AboutData> snapshot) {
        final _AboutData? data = snapshot.data;
        if (data == null) {
          return const _LauncherPage(
            body: PaperLoadingState(label: 'Loading about…'),
          );
        }
        final DeviceInfo device = data.device;
        final LauncherNetworkInfo network = data.network;
        // Head + tail keeps the sha identifiable without wrapping.
        final String engineHash =
            '${kEngineCommitPin.substring(0, 8)}…${kEngineCommitPin.substring(kEngineCommitPin.length - 8)}';
        return _LauncherPage(
          title: 'About',
          leading: _BackButton(label: 'Settings', route: '/settings'),
          body: Padding(
            padding: const EdgeInsets.all(PaperSpacing.pageMargin),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _SectionLabel('SYSTEM'),
                const _InfoRow('Pluto', kPlutoVersion),
                _InfoRow('Engine', engineHash),
                const _InfoRow(
                  'Flutter / Dart',
                  '$kFlutterVersionPin / $kDartVersionPin',
                ),
                _InfoRow(
                  'Device',
                  device.model.name,
                  annotation: device.codename,
                ),
                _InfoRow(
                  'Panel',
                  '${device.panel.width}x${device.panel.height} @${device.dpi} dpi',
                ),
                const SizedBox(height: PaperSpacing.space20),
                _SectionLabel('NETWORK'),
                _InfoRow(
                  'USB IP',
                  network.usbIp ?? 'not connected',
                  annotation: 'pluto devices',
                ),
                _InfoRow('Wi-Fi IP', network.wifiIp ?? 'not connected'),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _AboutData {
  const _AboutData({required this.device, required this.network});

  final DeviceInfo device;
  final LauncherNetworkInfo network;
}

/// Resolves a supervisor power-menu activation on cold start or warm resume.
final class PowerOffActivationScreen extends StatefulWidget {
  /// Creates the activation loader.
  const PowerOffActivationScreen({super.key});

  @override
  State<PowerOffActivationScreen> createState() =>
      _PowerOffActivationScreenState();
}

final class _PowerOffActivationScreenState
    extends State<PowerOffActivationScreen> {
  Future<PowerMenuRequest?>? _request;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _request ??= LauncherScope.of(context).session.pendingPowerMenu();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PowerMenuRequest?>(
      future: _request,
      builder:
          (BuildContext context, AsyncSnapshot<PowerMenuRequest?> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox.expand(),
              );
            }
            final PowerMenuRequest? request = snapshot.data;
            if (request == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  Navigator.of(context).pushReplacementNamed('/');
                }
              });
              return const ColoredBox(
                color: Color(0xFFFFFFFF),
                child: SizedBox.expand(),
              );
            }
            return PowerOffScreen(request: request);
          },
    );
  }
}

/// Full-screen, hold-to-confirm device power menu.
final class PowerOffScreen extends StatefulWidget {
  /// Creates a power menu for the app that yielded the display.
  const PowerOffScreen({
    required this.request,
    this.settleDelay = const Duration(milliseconds: 1900),
    this.initiallyPoweringOff = false,
    super.key,
  });

  /// Supervisor-authored app to resume when the menu is dismissed.
  final PowerMenuRequest request;

  /// Time reserved for the final e-ink frame to settle before power-off.
  final Duration settleDelay;

  /// Starts on the final frame for deterministic visual verification.
  final bool initiallyPoweringOff;

  @override
  State<PowerOffScreen> createState() => _PowerOffScreenState();
}

final class _PowerOffScreenState extends State<PowerOffScreen> {
  bool _systemUiReadySignaled = false;
  bool _returning = false;
  late bool _poweringOff;
  String? _error;

  @override
  void initState() {
    super.initState();
    _poweringOff = widget.initiallyPoweringOff;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_systemUiReadySignaled) {
      return;
    }
    _systemUiReadySignaled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        LauncherScope.of(
          context,
        ).session.systemUiReady().catchError((Object _) {}),
      );
    });
  }

  Future<void> _returnToOrigin() async {
    if (_returning || _poweringOff) {
      return;
    }
    setState(() {
      _returning = true;
      _error = null;
    });
    final LaunchResult result = await LauncherScope.of(
      context,
    ).session.launch(widget.request.originAppId);
    if (!mounted) {
      return;
    }
    if (result is LaunchFailure) {
      setState(() {
        _returning = false;
        _error = result.reason;
      });
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      unawaited(navigator.pushReplacementNamed('/'));
    }
  }

  Future<void> _powerOff() async {
    if (_poweringOff || _returning) {
      return;
    }
    setState(() {
      _poweringOff = true;
      _error = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _refreshChannel.invokeMethod<void>(
        'requestFullRefresh',
        const <String, Object?>{
          'class': 'full',
          'reason': 'launcher.power-off.final',
        },
      );
    } on PlatformException {
      // The settled full-class region still preserves the final frame when a
      // backend has no explicit refresh endpoint.
    } on MissingPluginException {
      // Host previews do not attach the native refresh channel.
    }
    if (widget.settleDelay > Duration.zero) {
      await Future<void>.delayed(widget.settleDelay);
    }
    if (!mounted) {
      return;
    }
    try {
      await LauncherScope.of(context).session.powerOffDevice();
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _poweringOff = false;
        _error = 'Could not turn off the device. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return EinkRefreshRegion(
      refreshClass: RefreshClass.full,
      reason: 'launcher.power-off',
      child: ColoredBox(
        color: theme.palette.paper,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool landscape = constraints.maxWidth > constraints.maxHeight;
            return _poweringOff
                ? _PoweringOffFarewell(landscape: landscape)
                : _PowerOffConfirmation(
                    landscape: landscape,
                    returning: _returning,
                    error: _error,
                    onCancel: _returnToOrigin,
                    onConfirmed: () => unawaited(_powerOff()),
                  );
          },
        ),
      ),
    );
  }
}

final class _PowerOffConfirmation extends StatelessWidget {
  const _PowerOffConfirmation({
    required this.landscape,
    required this.returning,
    required this.error,
    required this.onCancel,
    required this.onConfirmed,
  });

  final bool landscape;
  final bool returning;
  final String? error;
  final VoidCallback onCancel;
  final VoidCallback onConfirmed;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget illustration = SizedBox(
      width: landscape ? 330 : 310,
      height: landscape ? 285 : 275,
      child: CustomPaint(
        painter: _PowerOffPlutoPainter(
          ink: theme.palette.ink,
          softInk: theme.palette.gray66,
          paper: theme.palette.paper,
        ),
      ),
    );
    final Widget copyAndActions = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 390),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _PowerEyebrow(),
          const SizedBox(height: PaperSpacing.space16),
          Text(
            'Turn off Pluto?',
            style: theme.type.display,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: PaperSpacing.space12),
          Text(
            'Your apps will close safely. Hold for three seconds when '
            'you\u2019re ready.',
            style: theme.type.body.copyWith(color: theme.palette.gray33),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: PaperSpacing.space24),
          HoldToConfirmButton(
            key: const ValueKey<String>('power-off-hold'),
            label: 'Hold to turn off',
            onConfirmed: onConfirmed,
          ),
          const SizedBox(height: PaperSpacing.space12),
          SizedBox(
            width: double.infinity,
            child: PaperButton(
              key: const ValueKey<String>('power-off-cancel'),
              label: returning ? 'Returning\u2026' : 'Keep using Pluto',
              onPressed: returning ? null : onCancel,
            ),
          ),
          const SizedBox(height: PaperSpacing.space12),
          Text(
            error ?? 'Release early to cancel',
            style: theme.type.caption.copyWith(
              color: error == null
                  ? theme.palette.gray66
                  : theme.palette.accentRed,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );

    if (landscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 28),
        child: Row(
          children: <Widget>[
            Expanded(child: Center(child: illustration)),
            const SizedBox(width: PaperSpacing.space48),
            Expanded(child: Center(child: copyAndActions)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 38, 28, 30),
      child: Column(
        children: <Widget>[
          const _PowerEyebrow(),
          const Spacer(),
          illustration,
          const SizedBox(height: PaperSpacing.space24),
          Text(
            'Turn off Pluto?',
            style: theme.type.display,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: PaperSpacing.space12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              'Your apps will close safely. Hold for three seconds when '
              'you\u2019re ready.',
              style: theme.type.body.copyWith(color: theme.palette.gray33),
              textAlign: TextAlign.center,
            ),
          ),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                HoldToConfirmButton(
                  key: const ValueKey<String>('power-off-hold'),
                  label: 'Hold to turn off',
                  onConfirmed: onConfirmed,
                ),
                const SizedBox(height: PaperSpacing.space12),
                SizedBox(
                  width: double.infinity,
                  child: PaperButton(
                    key: const ValueKey<String>('power-off-cancel'),
                    label: returning ? 'Returning\u2026' : 'Keep using Pluto',
                    onPressed: returning ? null : onCancel,
                  ),
                ),
                const SizedBox(height: PaperSpacing.space12),
                Text(
                  error ?? 'Release early to cancel',
                  style: theme.type.caption.copyWith(
                    color: error == null
                        ? theme.palette.gray66
                        : theme.palette.accentRed,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _PowerEyebrow extends StatelessWidget {
  const _PowerEyebrow();

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(width: 34, height: 1, color: theme.palette.gray99),
        const SizedBox(width: PaperSpacing.space12),
        Text(
          'POWER',
          style: theme.type.mono.copyWith(
            color: theme.palette.gray33,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(width: PaperSpacing.space12),
        Container(width: 34, height: 1, color: theme.palette.gray99),
      ],
    );
  }
}

final class _PoweringOffFarewell extends StatelessWidget {
  const _PoweringOffFarewell({required this.landscape});

  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget illustration = SizedBox(
      width: 310,
      height: 270,
      child: CustomPaint(
        painter: _SleepingPlutoPainter(
          ink: theme.palette.ink,
          softInk: theme.palette.gray66,
          paper: theme.palette.paper,
        ),
      ),
    );
    final Widget farewell = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('Good night', style: theme.type.display),
        const SizedBox(height: PaperSpacing.space12),
        Text(
          'Pluto is powering off safely.',
          style: theme.type.body.copyWith(color: theme.palette.gray33),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: PaperSpacing.space24),
        Text(
          'Press power to start again',
          style: theme.type.caption.copyWith(color: theme.palette.gray66),
        ),
      ],
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: _StandbySkyPainter(
              ink: theme.palette.ink,
              softInk: theme.palette.gray66,
            ),
          ),
        ),
        Center(
          child: landscape
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    illustration,
                    const SizedBox(width: 72),
                    farewell,
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    illustration,
                    const SizedBox(height: PaperSpacing.space32),
                    farewell,
                  ],
                ),
        ),
      ],
    );
  }
}

final class _PowerOffPlutoPainter extends CustomPainter {
  const _PowerOffPlutoPainter({
    required this.ink,
    required this.softInk,
    required this.paper,
  });

  final Color ink;
  final Color softInk;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    const Size design = Size(320, 280);
    final double scale = math.min(
      size.width / design.width,
      size.height / design.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - design.width * scale) / 2,
      (size.height - design.height * scale) / 2,
    );
    canvas.scale(scale);

    final Paint line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Paint soft = Paint()
      ..color = softInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final Paint paperFill = Paint()
      ..color = paper
      ..style = PaintingStyle.fill;

    // A loose orbit ties awake Pluto, Charon, and the power glyph together.
    canvas.drawArc(
      const Rect.fromLTWH(35, 36, 250, 210),
      -math.pi * 0.83,
      math.pi * 1.46,
      false,
      soft,
    );
    canvas.drawCircle(const Offset(58, 64), 10, paperFill);
    canvas.drawCircle(const Offset(58, 64), 10, line);
    canvas.drawCircle(const Offset(55, 61), 1.5, line);
    canvas.drawCircle(const Offset(62, 61), 1.5, line);
    canvas.drawPath(
      Path()
        ..moveTo(54, 67)
        ..quadraticBezierTo(58, 70, 63, 66),
      soft,
    );

    const Offset planet = Offset(150, 146);
    const double radius = 76;
    canvas.drawCircle(planet, radius, paperFill);
    canvas.drawCircle(planet, radius, line);
    canvas.drawCircle(const Offset(112, 108), 6, soft);
    canvas.drawCircle(const Offset(190, 94), 4, soft);

    // Bright, awake expression for a friendly but unambiguous confirmation.
    canvas.drawCircle(const Offset(128, 130), 2.6, line);
    canvas.drawCircle(const Offset(173, 130), 2.6, line);
    canvas.drawPath(
      Path()
        ..moveTo(140, 150)
        ..quadraticBezierTo(151, 159, 162, 150),
      line,
    );

    final Path heart = Path()
      ..moveTo(151, 207)
      ..cubicTo(121, 187, 117, 166, 130, 159)
      ..cubicTo(141, 154, 149, 161, 151, 171)
      ..cubicTo(153, 161, 162, 154, 173, 159)
      ..cubicTo(187, 167, 181, 187, 151, 207)
      ..close();
    canvas.drawPath(heart, line);

    // Pluto waves with one hand and points toward the familiar power mark.
    canvas.drawPath(
      Path()
        ..moveTo(88, 151)
        ..quadraticBezierTo(63, 137, 66, 112)
        ..quadraticBezierTo(69, 96, 59, 88),
      line,
    );
    canvas.drawLine(const Offset(59, 88), const Offset(49, 78), line);
    canvas.drawLine(const Offset(59, 88), const Offset(62, 72), line);
    canvas.drawLine(const Offset(59, 88), const Offset(72, 79), line);
    canvas.drawPath(
      Path()
        ..moveTo(216, 142)
        ..quadraticBezierTo(237, 127, 249, 111),
      line,
    );

    const Offset power = Offset(265, 78);
    canvas.drawArc(
      Rect.fromCircle(center: power, radius: 25),
      -math.pi * 0.72,
      math.pi * 1.44,
      false,
      line,
    );
    canvas.drawLine(
      power - const Offset(0, 34),
      power + const Offset(0, 4),
      line,
    );

    void star(Offset center, double radius) {
      canvas.drawLine(
        center - Offset(radius, 0),
        center + Offset(radius, 0),
        soft,
      );
      canvas.drawLine(
        center - Offset(0, radius),
        center + Offset(0, radius),
        soft,
      );
    }

    star(const Offset(24, 167), 4);
    star(const Offset(280, 188), 4);
    star(const Offset(247, 240), 3);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PowerOffPlutoPainter oldDelegate) {
    return ink != oldDelegate.ink ||
        softInk != oldDelegate.softInk ||
        paper != oldDelegate.paper;
  }
}

/// S16 power-key standby screen.
final class StandbyScreen extends StatefulWidget {
  /// Creates the standby screen.
  const StandbyScreen({
    this.beginStandby = true,
    this.settleDelay = const Duration(milliseconds: 1900),
    super.key,
  });

  /// Whether to perform the hardware standby transaction after first paint.
  final bool beginStandby;

  /// Time reserved for the e-ink presenter to settle this screen before any
  /// supported frontlight is switched off and the kernel is suspended.
  final Duration settleDelay;

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

final class _StandbyScreenState extends State<StandbyScreen> {
  bool _didStart = false;
  bool _suspendFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.beginStandby) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_enterStandby());
      });
    }
  }

  Future<void> _enterStandby() async {
    if (_didStart) {
      return;
    }
    _didStart = true;
    final LauncherServices services = LauncherScope.of(context);
    FrontlightState? previousLight;
    bool handoffAccepted = false;
    try {
      final DeviceCapabilities capabilities = await services.device
          .capabilities();
      final bool hasFrontlight = capabilities.supports(Capability.frontlight);
      if (hasFrontlight) {
        previousLight = await services.settings.frontlight();
      }
      await _requestFullStandbyRefresh();
      if (widget.settleDelay > Duration.zero) {
        await Future<void>.delayed(widget.settleDelay);
      }
      if (hasFrontlight) {
        await services.settings.setFrontlightRaw(0);
      }
      await services.session.handoffStandbyToSupervisor();
      handoffAccepted = true;
    } catch (_) {
      if (mounted) {
        setState(() => _suspendFailed = true);
      }
    }

    // A successful handoff deliberately leaves any supported light off and
    // this process on the standby frame. Native shutdown releases the display;
    // the supervisor then suspends and alone restores saved device state.
    if (handoffAccepted) {
      return;
    }

    // Recover locally only when the handoff itself was rejected. Once the
    // supervisor accepts it, restoring here would recreate the immediate Home
    // and lit-screen failure that standby is meant to prevent.
    if (previousLight != null) {
      try {
        await services.settings.setFrontlightRaw(previousLight.raw);
      } catch (_) {
        // Returning home remains more recoverable than trapping the user on
        // the standby route when the sysfs light driver is unavailable.
      }
    }
    try {
      await services.session.returnToLauncher();
    } catch (_) {
      // A strict home-control failure must still stop this watcher-less
      // standby process. The supervisor's persisted-light recovery then
      // restores brightness and relaunches normal home.
      await SystemNavigator.pop();
    }
  }

  Future<void> _requestFullStandbyRefresh() async {
    try {
      await _refreshChannel.invokeMethod<void>(
        'requestFullRefresh',
        const <String, Object?>{'class': 'full', 'reason': 'launcher.standby'},
      );
    } on PlatformException {
      // A startup race or backend without a settled frame must not prevent
      // standby; the conservative settle delay still protects the panel.
    } on MissingPluginException {
      // Host previews have no native refresh endpoint.
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return EinkRefreshRegion(
      refreshClass: RefreshClass.full,
      reason: 'launcher.standby',
      child: ColoredBox(
        color: theme.palette.paper,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _StandbySkyPainter(
                  ink: theme.palette.ink,
                  softInk: theme.palette.gray66,
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 310,
                    height: 270,
                    child: CustomPaint(
                      painter: _SleepingPlutoPainter(
                        ink: theme.palette.ink,
                        softInk: theme.palette.gray66,
                        paper: theme.palette.paper,
                      ),
                    ),
                  ),
                  const SizedBox(height: PaperSpacing.space24),
                  Text('Standing by', style: theme.type.display),
                  if (_suspendFailed) ...<Widget>[
                    const SizedBox(height: PaperSpacing.space12),
                    Text(
                      'Standby was interrupted · returning home',
                      style: theme.type.body.copyWith(
                        color: theme.palette.gray33,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: PaperSpacing.space48),
                child: Text(
                  'Press power to wake',
                  style: theme.type.caption.copyWith(
                    color: theme.palette.gray33,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _StandbySkyPainter extends CustomPainter {
  const _StandbySkyPainter({required this.ink, required this.softInk});

  final Color ink;
  final Color softInk;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint faint = Paint()
      ..color = softInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final Paint strong = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    void star(Offset center, double radius) {
      canvas.drawLine(
        center - Offset(radius, 0),
        center + Offset(radius, 0),
        faint,
      );
      canvas.drawLine(
        center - Offset(0, radius),
        center + Offset(0, radius),
        faint,
      );
    }

    star(Offset(size.width * 0.17, size.height * 0.19), 5);
    star(Offset(size.width * 0.79, size.height * 0.25), 4);
    star(Offset(size.width * 0.87, size.height * 0.56), 3);
    star(Offset(size.width * 0.13, size.height * 0.68), 3);

    final Offset moon = Offset(size.width * 0.78, size.height * 0.13);
    final Path crescent = Path()
      ..moveTo(moon.dx + 12, moon.dy - 25)
      ..cubicTo(
        moon.dx - 21,
        moon.dy - 16,
        moon.dx - 22,
        moon.dy + 19,
        moon.dx + 9,
        moon.dy + 27,
      )
      ..cubicTo(
        moon.dx - 5,
        moon.dy + 11,
        moon.dx - 4,
        moon.dy - 10,
        moon.dx + 12,
        moon.dy - 25,
      );
    canvas.drawPath(crescent, strong);
  }

  @override
  bool shouldRepaint(_StandbySkyPainter oldDelegate) {
    return ink != oldDelegate.ink || softInk != oldDelegate.softInk;
  }
}

final class _SleepingPlutoPainter extends CustomPainter {
  const _SleepingPlutoPainter({
    required this.ink,
    required this.softInk,
    required this.paper,
  });

  final Color ink;
  final Color softInk;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final Paint soft = Paint()
      ..color = softInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final Paint paperFill = Paint()
      ..color = paper
      ..style = PaintingStyle.fill;

    // Pluto itself: a hollow paper planet. The heart below is Tombaugh Regio,
    // kept as an outline so it survives 1-bit dithering without ghosting.
    const Offset planet = Offset(148, 130);
    const double radius = 78;
    canvas.drawCircle(planet, radius, paperFill);
    canvas.drawCircle(planet, radius, line);

    final Path heart = Path()
      ..moveTo(150, 200)
      ..cubicTo(118, 178, 112, 156, 126, 148)
      ..cubicTo(138, 143, 148, 150, 150, 160)
      ..cubicTo(152, 150, 162, 143, 174, 148)
      ..cubicTo(188, 156, 182, 178, 150, 200)
      ..close();
    canvas.drawPath(heart, line);

    // Closed eyes and a tiny contented smile, high on the face so the heart
    // reads as the planet's tummy.
    canvas.drawPath(
      Path()
        ..moveTo(112, 100)
        ..quadraticBezierTo(124, 112, 136, 100),
      line,
    );
    canvas.drawPath(
      Path()
        ..moveTo(160, 100)
        ..quadraticBezierTo(172, 112, 184, 100),
      line,
    );
    canvas.drawPath(
      Path()
        ..moveTo(140, 124)
        ..quadraticBezierTo(148, 131, 156, 124),
      soft,
    );

    // Sparse craters keep the surface papery rather than shaded.
    canvas.drawCircle(const Offset(106, 70), 6, soft);
    canvas.drawCircle(const Offset(188, 64), 4, soft);

    // Charon dozes nearby on a faint orbit line.
    canvas.drawCircle(const Offset(52, 48), 9, line);
    canvas.drawPath(
      Path()
        ..moveTo(46, 48)
        ..quadraticBezierTo(52, 53, 58, 48),
      soft,
    );
    canvas.drawPath(
      Path()
        ..moveTo(28, 72)
        ..quadraticBezierTo(44, 128, 74, 170),
      soft,
    );

    // Sparse hand-drawn sleep marks.
    canvas.drawPath(
      Path()
        ..moveTo(246, 91)
        ..lineTo(264, 91)
        ..lineTo(246, 108)
        ..lineTo(264, 108),
      soft,
    );
    canvas.drawPath(
      Path()
        ..moveTo(264, 64)
        ..lineTo(280, 64)
        ..lineTo(264, 79)
        ..lineTo(280, 79),
      soft,
    );
  }

  @override
  bool shouldRepaint(_SleepingPlutoPainter oldDelegate) {
    return ink != oldDelegate.ink ||
        softInk != oldDelegate.softInk ||
        paper != oldDelegate.paper;
  }
}

final class _LauncherPage extends StatelessWidget {
  const _LauncherPage({
    required this.body,
    this.title,
    this.leading,
    this.trailing,
    this.pageIndicator,
    this.showHeader = true,
  });

  final Widget body;
  final String? title;
  final Widget? leading;
  final Widget? trailing;
  final Widget? pageIndicator;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final LauncherServices services = LauncherScope.of(context);
    return StreamBuilder<StatusSnapshot>(
      stream: services.settings.watchStatus(),
      builder: (BuildContext context, AsyncSnapshot<StatusSnapshot> snapshot) {
        final StatusSnapshot? status = snapshot.data;
        return PaperScaffold(
          statusBar: status == null
              ? null
              : StatusBar(
                  snapshot: status,
                  onTapCluster: () =>
                      Navigator.of(context).pushNamed('/settings'),
                ),
          header: showHeader && title != null
              ? PageHeader(title: title!, leading: leading, trailing: trailing)
              : null,
          pageIndicator: pageIndicator,
          body: body,
        );
      },
    );
  }
}

final class _TileEntry {
  const _TileEntry.app(this.app);

  const _TileEntry.system() : app = null;

  final LauncherApp? app;

  PaperAppTileData get tileData {
    final LauncherApp? localApp = app;
    if (localApp == null) {
      return const PaperAppTileData(
        id: 'stock.remarkable',
        name: 'reMarkable',
        isSystem: true,
      );
    }
    return PaperAppTileData(
      id: localApp.id.value,
      name: localApp.displayName,
      version: localApp.versionText,
      iconBytes: localApp.iconBytes,
      isPinned: localApp.isPinned,
      isBroken: localApp.isBroken,
    );
  }
}

final class _WifiNetworkRow extends StatelessWidget {
  const _WifiNetworkRow({
    required this.network,
    required this.onTap,
    this.trailing,
  });

  final WifiNetwork network;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return PaperListItem(
      padding: EdgeInsets.zero,
      height: 60,
      leading: _SignalMeter(signal: network.signal),
      title: network.ssid,
      subtitle: _wifiSecurityLabel(network),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

String _wifiSecurityLabel(WifiNetwork network) {
  return switch (network.security) {
    WifiSecurity.open => 'Open network',
    WifiSecurity.wep => 'Secured (WEP)',
    WifiSecurity.wpaPsk => 'Secured (WPA/WPA2)',
    WifiSecurity.wpaEap => 'Enterprise network',
    WifiSecurity.sae => 'Secured (WPA3)',
    WifiSecurity.unknown => network.isActive ? 'Connected' : 'Secured network',
  };
}

final class _SignalMeter extends StatelessWidget {
  const _SignalMeter({required this.signal});

  final double signal;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: 26,
      height: 22,
      child: CustomPaint(
        painter: _SignalMeterPainter(
          bars: signal >= 0.7
              ? 3
              : signal >= 0.4
              ? 2
              : 1,
          ink: theme.palette.ink,
          // Hollow bars stay ink so the meter survives 1-bit dithering.
          faint: theme.palette.ink,
        ),
      ),
    );
  }
}

final class _SignalMeterPainter extends CustomPainter {
  const _SignalMeterPainter({
    required this.bars,
    required this.ink,
    required this.faint,
  });

  final int bars;
  final Color ink;
  final Color faint;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.hairline
      ..color = faint;
    const double barWidth = 6;
    const double gap = 4;
    final List<double> heights = <double>[8, 14, 20];
    for (int i = 0; i < 3; i++) {
      final Rect bar = Rect.fromLTWH(
        i * (barWidth + gap),
        size.height - heights[i],
        barWidth,
        heights[i],
      );
      if (i < bars) {
        fill.color = ink;
        canvas.drawRect(bar, fill);
      } else {
        canvas.drawRect(bar.deflate(0.5), outline);
      }
    }
  }

  @override
  bool shouldRepaint(_SignalMeterPainter oldDelegate) =>
      bars != oldDelegate.bars ||
      ink != oldDelegate.ink ||
      faint != oldDelegate.faint;
}

final class _SmallMonogram extends StatelessWidget {
  const _SmallMonogram(this.data);

  final PaperAppTileData data;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Text initials = Text(
      data.isSystem ? 'rM' : _initials(data.name),
      style: theme.type.label.copyWith(fontSize: 16, height: 22 / 16),
    );
    // The dashed frame marks the stock system entry, matching the grid tile.
    if (data.isSystem) {
      return SizedBox.square(
        dimension: 48,
        child: CustomPaint(
          painter: _DashedSquarePainter(theme.palette.ink),
          child: Center(child: initials),
        ),
      );
    }
    return SizedBox.square(
      dimension: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.palette.ink,
            width: PaperSpacing.rule,
          ),
        ),
        child: Center(child: initials),
      ),
    );
  }
}

final class _DashedSquarePainter extends CustomPainter {
  const _DashedSquarePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    _paintDashedRect(canvas, Offset.zero & size, stroke, 7, 5);
  }

  @override
  bool shouldRepaint(_DashedSquarePainter oldDelegate) =>
      color != oldDelegate.color;
}

final class _LargeMonogram extends StatelessWidget {
  const _LargeMonogram(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox.square(
      dimension: 96,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.palette.ink,
            width: PaperSpacing.rule,
          ),
        ),
        child: Center(child: Text(_initials(name), style: theme.type.display)),
      ),
    );
  }
}

final class _PlutoMark extends StatelessWidget {
  const _PlutoMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final TextStyle markStyle = theme.type.heading.copyWith(
      fontWeight: FontWeight.w700,
      height: 1,
    );
    // Both lines scale to the same measure so the wordmark reads as a
    // deliberate flush-justified block, not a wrapped label.
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.palette.ink,
            width: PaperSpacing.heavyRule,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: size * 0.5,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  child: Text('PLU', style: markStyle),
                ),
              ),
              SizedBox(height: size * 0.04),
              SizedBox(
                width: size * 0.5,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  child: Text('TO', style: markStyle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _PinSlot extends StatelessWidget {
  const _PinSlot({required this.filled, this.required = true});

  final bool filled;

  /// Whether this slot belongs to the mandatory first four digits.
  final bool required;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    // Optional slots use a thinner ink border — a structural distinction
    // that stays legible after 1-bit dithering, unlike a gray tint.
    return SizedBox.square(
      dimension: 30,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: filled ? theme.palette.ink : theme.palette.paper,
          border: Border.all(
            color: theme.palette.ink,
            width: filled || required
                ? PaperSpacing.rule
                : PaperSpacing.hairline,
          ),
        ),
      ),
    );
  }
}

final class _BackButton extends StatelessWidget {
  const _BackButton({required this.label, required this.route});

  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return PaperButton.ghost(
      label: '← $label',
      onPressed: () {
        final NavigatorState navigator = Navigator.of(context);
        unawaited(
          navigator.maybePop().then((bool popped) {
            if (!popped) {
              navigator.pushReplacementNamed(route);
            }
          }),
        );
      },
    );
  }
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(
        label,
        style: theme.type.caption.copyWith(
          color: theme.palette.gray33,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

final class _SegmentSetting<T> extends StatelessWidget {
  const _SegmentSetting({
    required this.label,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<PaperSegment<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: PaperTheme.of(context).type.body)),
          SegmentedControl<T>(
            segments: segments,
            selected: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

final class _ButtonSetting extends StatelessWidget {
  const _ButtonSetting({
    required this.label,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String label;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: PaperTheme.of(context).type.body)),
          SizedBox(
            width: 124,
            child: PaperButton(label: buttonLabel, onPressed: onPressed),
          ),
        ],
      ),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.annotation});

  final String label;
  final String value;
  final String? annotation;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Padding(
              padding: const EdgeInsets.only(right: PaperSpacing.space8),
              child: Text(label, style: theme.type.label),
            ),
          ),
          if (annotation == null)
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.mono,
              ),
            )
          else ...<Widget>[
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.mono,
            ),
            const SizedBox(width: PaperSpacing.space12),
            Expanded(
              child: Text(
                annotation!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.copyWith(color: theme.palette.gray33),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: _Hairline(),
  );
}

final class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PaperTheme.of(context).palette.gray99,
      child: const SizedBox(
        height: PaperSpacing.hairline,
        width: double.infinity,
      ),
    );
  }
}

final class _HeavyRule extends StatelessWidget {
  const _HeavyRule();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PaperTheme.of(context).palette.ink,
      child: const SizedBox(height: PaperSpacing.rule, width: double.infinity),
    );
  }
}

Future<void> _confirmClearAppData(
  BuildContext context,
  LauncherApp app,
  VoidCallback onCleared,
) async {
  final bool confirmed = await PaperDialogs.confirm(
    context,
    title: 'Clear ${app.displayName} data?',
    message:
        'This removes ${_formatBytes(app.dataSizeBytes)} of saved data. The app itself stays installed.',
    confirmLabel: 'Clear',
  );
  if (!confirmed || !context.mounted) {
    return;
  }
  await LauncherScope.of(context).manifests.clearAppData(app.id);
  if (context.mounted) {
    onCleared();
  }
}

Future<void> _confirmUninstallApp(BuildContext context, LauncherApp app) async {
  bool deleteData = false;
  final bool? confirmed = await PaperDialogs.show<bool>(
    context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          return PaperDialog(
            title: 'Uninstall ${app.displayName}?',
            actions: <Widget>[
              PaperButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              PaperButton.destructive(
                label: 'Uninstall',
                armingDelay: const Duration(milliseconds: 600),
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'This removes the app and its icon from this tablet.',
                  style: PaperTheme.of(context).type.body,
                ),
                const SizedBox(height: PaperSpacing.space12),
                PaperCheckbox(
                  value: deleteData,
                  onChanged: (bool value) =>
                      setDialogState(() => deleteData = value),
                  label:
                      'Also delete its data (${_formatBytes(app.dataSizeBytes)})',
                ),
              ],
            ),
          );
        },
      );
    },
  );
  if (confirmed == true && context.mounted) {
    await LauncherScope.of(
      context,
    ).manifests.uninstall(app.id, deleteData: deleteData);
  }
}

Future<void> _showExitToStockConfirm(BuildContext context) async {
  final bool confirmed = await PaperDialogs.confirm(
    context,
    title: 'Switch to reMarkable?',
    message:
        'Your notes and documents open in the stock reMarkable interface. Pluto stays installed. To return, connect the tablet to your computer and run pluto run --release dev.pluto.launcher.',
    confirmLabel: 'Switch',
    armingDelay: const Duration(milliseconds: 600),
  );
  if (confirmed && context.mounted) {
    await LauncherScope.of(context).session.switchToStockUi();
  }
}

Future<_AboutData> _aboutData(LauncherServices services) async {
  final DeviceInfo device = await services.device.deviceInfo();
  final LauncherNetworkInfo network = await services.settings.networkInfo();
  return _AboutData(device: device, network: network);
}

int _homeGridCapacity({required double maxWidth, required double maxHeight}) {
  final int columns = math.max(
    3,
    ((maxWidth - PaperSpacing.pageMargin * 2 + PaperSpacing.gutter) /
            (135 + PaperSpacing.gutter))
        .floor(),
  );
  final int rows = maxHeight < 500 ? 2 : 4;
  return columns * rows;
}

int _homePageCount(int itemCount, int capacity) =>
    math.max(1, (itemCount / capacity).ceil());

int _nearestFrontlightNotch(int raw) {
  int bestIndex = 0;
  int bestDistance = 1 << 30;
  for (int i = 0; i < _frontlightCurve.length; i++) {
    final int distance = (raw - _frontlightCurve[i]).abs();
    if (distance < bestDistance) {
      bestIndex = i;
      bestDistance = distance;
    }
  }
  return bestIndex;
}

Duration? _standbyDuration(String value) {
  return switch (value) {
    '5 min' => const Duration(minutes: 5),
    '20 min' => const Duration(minutes: 20),
    '1 h' => const Duration(hours: 1),
    _ => null,
  };
}

String _formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  final double mb = bytes / (1000 * 1000);
  return '${mb.toStringAsFixed(1)} MB';
}

String _formatDateTime(DateTime? dateTime) {
  if (dateTime == null) {
    return 'unknown';
  }
  final DateTime local = dateTime.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String _initials(String name) {
  final List<String> words = name.trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) {
    return '?';
  }
  if (words.length == 1) {
    return words.first.length == 1
        ? words.first.toUpperCase()
        : words.first.substring(0, 2).toUpperCase();
  }
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}
