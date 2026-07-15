import 'dart:async';
import 'dart:typed_data';

import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';
import 'package:pluto_launcher/src/models.dart';
import 'package:pluto_launcher/src/services.dart';

/// Creates deterministic host-preview services.
LauncherServices createHostPreviewServices({
  bool empty = false,
  List<LauncherApp>? apps,
}) {
  return LauncherServices(
    manifests: FakeManifestRepository(
      apps: empty ? const <LauncherApp>[] : apps ?? sampleLauncherApps(),
    ),
    session: FakeSessionManager(),
    settings: FakeLauncherSettings(),
    device: const FakeLauncherDeviceRepository(),
  );
}

/// In-memory manifest repository for host tests and goldens.
final class FakeManifestRepository implements ManifestRepository {
  /// Creates a fake repository seeded with [apps].
  FakeManifestRepository({required List<LauncherApp> apps})
    : _apps = List<LauncherApp>.of(apps);

  final List<LauncherApp> _apps;
  final StreamController<List<LauncherApp>> _controller =
      StreamController<List<LauncherApp>>.broadcast();

  /// Number of subscriptions requested by launcher screens.
  int watchAppsCalls = 0;

  /// Current sorted app list.
  List<LauncherApp> get apps => _sorted();

  @override
  Future<LauncherApp?> appById(AppId id) async {
    for (final LauncherApp app in _apps) {
      if (app.id == id) {
        return app;
      }
    }
    return null;
  }

  @override
  Future<void> setPinned(AppId id, {required bool isPinned}) async {
    for (int i = 0; i < _apps.length; i++) {
      if (_apps[i].id == id) {
        _apps[i] = _apps[i].copyWith(isPinned: isPinned);
      }
    }
    _emit();
  }

  @override
  Future<void> uninstall(AppId id, {required bool deleteData}) async {
    _apps.removeWhere((LauncherApp app) => app.id == id);
    _emit();
  }

  @override
  Future<void> clearAppData(AppId id) async {
    for (int i = 0; i < _apps.length; i++) {
      if (_apps[i].id == id) {
        _apps[i] = _apps[i].copyWith(dataSizeBytes: 0);
      }
    }
    _emit();
  }

  @override
  Stream<List<LauncherApp>> watchApps() async* {
    watchAppsCalls += 1;
    yield _sorted();
    yield* _controller.stream;
  }

  /// Disposes stream resources.
  Future<void> dispose() => _controller.close();

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(_sorted());
    }
  }

  List<LauncherApp> _sorted() {
    final List<LauncherApp> sorted = List<LauncherApp>.of(_apps);
    sorted.sort((LauncherApp a, LauncherApp b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return sorted;
  }
}

/// Fake `plutod` session manager.
final class FakeSessionManager implements SessionManager {
  /// Creates a fake session manager.
  FakeSessionManager({
    this.nextLaunchResult = const LaunchSuccess(pid: 4242),
    this.switcherRequest,
    this.statusOverlayRequest,
    this.powerMenuRequest,
    SessionInfo? info,
  }) : _info = info ?? _defaultSessionInfo;

  static const SessionInfo _defaultSessionInfo = SessionInfo(
    plutoVersion: '0.1.0-host',
    engineVersion: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
    flutterVersion: '3.44.4',
    dartVersion: '3.12.2',
    returnInstructions: 'restart the native Pluto session over SSH.',
  );

  final SessionInfo _info;
  final StreamController<SessionEvent> _events =
      StreamController<SessionEvent>.broadcast();

  /// Result returned by the next launch request.
  LaunchResult nextLaunchResult;

  /// Active app-switcher request returned to the launcher root.
  AppSwitcherRequest? switcherRequest;

  /// Active system status shade request returned to the launcher root.
  StatusOverlayRequest? statusOverlayRequest;

  /// Active full-screen power menu request returned to the launcher root.
  PowerMenuRequest? powerMenuRequest;

  /// Number of no-flash presentation releases requested by system UI.
  int systemUiReadyCalls = 0;

  /// App ids launched through this fake.
  final List<AppId> launchedApps = <AppId>[];

  /// App ids force-stopped through the switcher.
  final List<AppId> forceStoppedApps = <AppId>[];

  /// Whether stock UI was requested.
  bool didSwitchToStock = false;

  /// Whether a full device power-off was requested.
  bool didPowerOff = false;

  /// Optional failure surfaced by [powerOffDevice].
  Object? powerOffError;

  /// Whether sleep was requested.
  bool didSleep = false;

  /// Whether supervisor standby handoff was requested by the standby screen.
  bool didHandoffStandby = false;

  /// Whether the standby screen requested a normal launcher restart.
  bool didReturnToLauncher = false;

  /// Optional failure surfaced by [handoffStandbyToSupervisor].
  Object? standbyHandoffError;

  /// Whether the display test card was requested.
  bool didRunDisplayTestCard = false;

  /// Last damage overlay state set through this fake.
  bool? damageOverlayEnabled;

  /// Last Pluto uninstall options.
  PlutoUninstallOptions? lastUninstallOptions;

  @override
  Stream<SessionEvent> get events => _events.stream;

  @override
  Future<void> beginPlutoUninstall(PlutoUninstallOptions options) async {
    lastUninstallOptions = options;
  }

  @override
  Future<void> cancelLaunch(AppId id) async {}

  @override
  Future<SessionInfo> info() async => _info;

  @override
  Future<LaunchResult> launch(AppId id) async {
    launchedApps.add(id);
    return nextLaunchResult;
  }

  @override
  Future<void> forceStop(AppId id) async {
    forceStoppedApps.add(id);
  }

  @override
  Future<AppSwitcherRequest?> pendingAppSwitcher() async => switcherRequest;

  @override
  Future<StatusOverlayRequest?> pendingStatusOverlay() async =>
      statusOverlayRequest;

  @override
  Future<PowerMenuRequest?> pendingPowerMenu() async => powerMenuRequest;

  @override
  Future<void> systemUiReady() async {
    systemUiReadyCalls += 1;
  }

  @override
  Future<void> sleepNow() async {
    didSleep = true;
  }

  @override
  Future<void> handoffStandbyToSupervisor() async {
    didHandoffStandby = true;
    final Object? error = standbyHandoffError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> returnToLauncher() async {
    didReturnToLauncher = true;
  }

  @override
  Future<void> switchToStockUi() async {
    didSwitchToStock = true;
  }

  @override
  Future<void> powerOffDevice() async {
    didPowerOff = true;
    final Object? error = powerOffError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<LauncherDeveloperStats> developerStats() async {
    return const LauncherDeveloperStats(
      vmServiceUri: 'ws://host-preview/ws',
      renderer: 'RGB565, tile-diff damage',
      ghostPartialsSinceFull: 4,
      ghostBudget: 12,
      buildMs: 4.1,
      rasterMs: 11.8,
    );
  }

  @override
  Future<void> runDisplayTestCard() async {
    didRunDisplayTestCard = true;
  }

  @override
  Future<void> setDamageOverlayEnabled(bool enabled) async {
    damageOverlayEnabled = enabled;
  }

  /// Disposes stream resources.
  Future<void> dispose() => _events.close();
}

/// Fake settings facade with deterministic status and Wi-Fi data.
final class FakeLauncherSettings implements LauncherSettings {
  /// Creates fake settings.
  FakeLauncherSettings({
    StatusSnapshot? status,
    FrontlightState? frontlight,
    List<WifiNetwork>? networks,
    WifiStatus? wifiStatus,
    this.rotation = RotationPreference.auto,
  }) : _status = status ?? StatusSnapshot.fixed,
       _frontlight =
           frontlight ?? const FrontlightState(raw: 1250, maxRaw: 2047),
       _networks = networks ?? _defaultNetworks,
       _wifiStatus =
           wifiStatus ??
           _wifiStatusFromSnapshot(status ?? StatusSnapshot.fixed);

  static const List<WifiNetwork> _defaultNetworks = <WifiNetwork>[
    WifiNetwork(
      ssid: "Anna's Wifi",
      signal: 0.82,
      security: WifiSecurity.wpaPsk,
      isKnown: true,
      isActive: true,
    ),
    WifiNetwork(
      ssid: 'HomeNet-5G',
      signal: 0.78,
      security: WifiSecurity.wpaPsk,
      isKnown: false,
      isActive: false,
    ),
    WifiNetwork(
      ssid: 'CafeGuest',
      signal: 0.52,
      security: WifiSecurity.open,
      isKnown: false,
      isActive: false,
    ),
    WifiNetwork(
      ssid: 'Nachbarn24',
      signal: 0.31,
      security: WifiSecurity.wpaPsk,
      isKnown: false,
      isActive: false,
    ),
  ];

  final StreamController<StatusSnapshot> _statusController =
      StreamController<StatusSnapshot>.broadcast();
  late final Stream<StatusSnapshot> _statusStream =
      Stream<StatusSnapshot>.multi((
        MultiStreamController<StatusSnapshot> controller,
      ) {
        watchStatusCalls += 1;
        controller.add(_status);
        final StreamSubscription<StatusSnapshot> subscription =
            _statusController.stream.listen(
              controller.add,
              onError: controller.addError,
              onDone: controller.close,
            );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);
  StatusSnapshot _status;
  FrontlightState _frontlight;
  List<WifiNetwork> _networks;
  WifiStatus _wifiStatus;

  /// Persisted orientation preference.
  RotationPreference rotation;

  /// Optional failure injected into orientation persistence.
  Object? setRotationError;

  /// Optional failures injected into Wi-Fi operations.
  Object? scanWifiError;
  Object? connectWifiError;
  Object? setWifiEnabledError;
  Object? forgetWifiError;

  /// Optional gate used to hold a scan in its visible loading state.
  Future<void>? scanWifiDelay;

  /// Wi-Fi operation observations used by widget tests.
  int scanWifiCalls = 0;
  int connectWifiCalls = 0;
  int setWifiEnabledCalls = 0;
  String? lastWifiPassphrase;

  /// Last standby timeout set through this fake.
  Duration? standbyTimeout;

  /// Number of status-stream subscriptions requested by launcher screens.
  int watchStatusCalls = 0;

  /// Last PIN set through this fake.
  String? pin;

  /// Current frontlight state.
  FrontlightState get currentFrontlight => _frontlight;

  /// Current Wi-Fi status.
  WifiStatus get currentWifiStatus => _wifiStatus;

  @override
  Future<WifiConnection> connectWifi({
    required String ssid,
    String? passphrase,
  }) async {
    connectWifiCalls += 1;
    lastWifiPassphrase = passphrase;
    final Object? failure = connectWifiError;
    if (failure != null) {
      throw failure;
    }
    final WifiConnection connection = WifiConnection(
      ssid: ssid,
      ipAddress: '192.168.1.74',
      signal: 0.76,
    );
    _wifiStatus = WifiConnected(connection: connection);
    _networks = <WifiNetwork>[
      for (final WifiNetwork network in _networks)
        WifiNetwork(
          ssid: network.ssid,
          signal: network.ssid == ssid ? connection.signal : network.signal,
          security: network.security,
          isKnown: network.isKnown || network.ssid == ssid,
          isActive: network.ssid == ssid,
        ),
    ];
    _status = StatusSnapshot(
      time: _status.time,
      battery: _status.battery,
      penBattery: _status.penBattery,
      wifi: StatusWifi(ssid: ssid, signalPercent: 76),
      isWifiEnabled: true,
      frontlightRaw: _status.frontlightRaw,
      frontlightMaxRaw: _status.frontlightMaxRaw,
      isUsbTethered: _status.isUsbTethered,
    );
    _emitStatus();
    return connection;
  }

  @override
  Future<void> forgetWifi(String ssid) async {
    final Object? failure = forgetWifiError;
    if (failure != null) {
      throw failure;
    }
    _networks = <WifiNetwork>[
      for (final WifiNetwork network in _networks)
        if (network.ssid != ssid) network,
    ];
    if (_wifiStatus case WifiConnected(
      :final WifiConnection connection,
    ) when connection.ssid == ssid) {
      _wifiStatus = const WifiDisconnected();
      _status = StatusSnapshot(
        time: _status.time,
        battery: _status.battery,
        penBattery: _status.penBattery,
        wifi: null,
        isWifiEnabled: true,
        frontlightRaw: _status.frontlightRaw,
        frontlightMaxRaw: _status.frontlightMaxRaw,
        isUsbTethered: _status.isUsbTethered,
      );
      _emitStatus();
    }
  }

  @override
  Future<FrontlightState> frontlight() async => _frontlight;

  @override
  Future<void> removePin() async {
    pin = null;
  }

  @override
  Future<List<WifiNetwork>> scanWifiNetworks() async {
    scanWifiCalls += 1;
    final Future<void>? delay = scanWifiDelay;
    if (delay != null) {
      await delay;
    }
    final Object? failure = scanWifiError;
    if (failure != null) {
      throw failure;
    }
    return _networks;
  }

  @override
  Future<void> setFrontlightRaw(int raw) async {
    _frontlight = FrontlightState(raw: raw, maxRaw: _frontlight.maxRaw);
    _status = StatusSnapshot(
      time: _status.time,
      battery: _status.battery,
      penBattery: _status.penBattery,
      wifi: _status.wifi,
      isWifiEnabled: _status.isWifiEnabled,
      frontlightRaw: raw,
      frontlightMaxRaw: _frontlight.maxRaw,
      isUsbTethered: _status.isUsbTethered,
    );
    _emitStatus();
  }

  @override
  Future<RotationPreference> rotationPreference() async => rotation;

  @override
  Future<void> setRotationPreference(RotationPreference preference) async {
    final Object? failure = setRotationError;
    if (failure != null) {
      throw failure;
    }
    rotation = preference;
  }

  @override
  Future<void> setPin(String digits) async {
    final DevicePin? parsed = DevicePin.tryParse(digits);
    if (parsed == null) {
      throw ArgumentError.value(digits, 'digits', 'must be 4-8 digits');
    }
    pin = parsed.digits;
  }

  @override
  Future<void> setStandbyTimeout(Duration? delay) async {
    standbyTimeout = delay;
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    setWifiEnabledCalls += 1;
    final Object? failure = setWifiEnabledError;
    if (failure != null) {
      throw failure;
    }
    _wifiStatus = enabled ? const WifiDisconnected() : const WifiDisabled();
    _networks = <WifiNetwork>[
      for (final WifiNetwork network in _networks)
        WifiNetwork(
          ssid: network.ssid,
          signal: network.signal,
          security: network.security,
          isKnown: network.isKnown,
          isActive: false,
        ),
    ];
    _status = StatusSnapshot(
      time: _status.time,
      battery: _status.battery,
      penBattery: _status.penBattery,
      wifi: null,
      isWifiEnabled: enabled,
      frontlightRaw: _status.frontlightRaw,
      frontlightMaxRaw: _status.frontlightMaxRaw,
      isUsbTethered: _status.isUsbTethered,
    );
    _emitStatus();
  }

  @override
  Stream<StatusSnapshot> watchStatus() => _statusStream;

  @override
  Future<WifiStatus> wifiStatus() async => _wifiStatus;

  @override
  Future<bool> hasPin() async => pin != null;

  @override
  Future<LauncherNetworkInfo> networkInfo() async {
    final WifiStatus status = _wifiStatus;
    return LauncherNetworkInfo(
      usbIp: _status.isUsbTethered ? '10.11.99.1' : null,
      wifiIp: status is WifiConnected ? status.connection.ipAddress : null,
    );
  }

  /// Disposes stream resources.
  Future<void> dispose() => _statusController.close();

  void _emitStatus() {
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }
}

WifiStatus _wifiStatusFromSnapshot(StatusSnapshot status) {
  final StatusWifi? wifi = status.wifi;
  if (wifi != null) {
    return WifiConnected(
      connection: WifiConnection(
        ssid: wifi.ssid,
        ipAddress: '192.168.1.74',
        signal: wifi.signalPercent / 100,
      ),
    );
  }
  return status.isWifiEnabled ? const WifiDisconnected() : const WifiDisabled();
}

/// Fake device info repository.
final class FakeLauncherDeviceRepository implements LauncherDeviceRepository {
  /// Creates a fake device repository.
  const FakeLauncherDeviceRepository();

  @override
  Future<DeviceInfo> deviceInfo() async {
    return const DeviceInfo(
      model: RemarkableModel.paperProMove,
      codename: 'chiappa',
      firmwareBuild: '20260629074044',
      osVersion: '3.20.0.0',
      panel: PanelGeometry(
        width: 954,
        height: 1696,
        dpi: 264,
        pixelFormat: PanelPixelFormat.rgb565,
        colorMode: PanelColorMode.gallery3,
      ),
      serialNumber: 'host-preview',
    );
  }
}

/// Deterministic sample apps used by host preview and tests.
List<LauncherApp> sampleLauncherApps() {
  return <LauncherApp>[
    _sampleApp(
      id: 'dev.example.counter',
      name: 'Counter',
      version: '1.0.2',
      description: 'Simple tap counter for launch acceptance.',
      isPinned: true,
      sizeBytes: 2100000,
    ),
    _sampleApp(
      id: 'dev.example.sketchbook',
      name: 'Sketchbook',
      version: '0.9.0',
      description: 'Pressure-sensitive drawing with Pluto pen input.',
      sizeBytes: 18400000,
      dataSizeBytes: 2100000,
    ),
    _sampleApp(
      id: 'dev.example.chess',
      name: 'Chess',
      version: '2.3.1',
      description: 'Paged chess board and clock.',
      sizeBytes: 5000000,
    ),
    _sampleApp(
      id: 'dev.example.reader',
      name: 'Reader',
      version: '1.1.0',
      description: 'Document reader tuned for text refreshes.',
      sizeBytes: 12100000,
    ),
    _sampleApp(
      id: 'dev.example.weather',
      name: 'Weather',
      version: '1.4.0',
      description: 'Weather dashboard with settled color icons.',
      sizeBytes: 18400000,
      dataSizeBytes: 2100000,
    ),
    _sampleApp(
      id: 'dev.example.metronome',
      name: 'Metronome',
      version: '0.4.1',
      description: 'Practice metronome with discrete visual ticks.',
      sizeBytes: 1600000,
    ),
    _sampleApp(
      id: 'dev.example.music',
      name: 'Music',
      version: '0.2.5',
      description: 'Local music controls.',
      sizeBytes: 3200000,
    ),
    _sampleApp(
      id: 'dev.example.broken',
      name: 'Broken Demo',
      version: '0.1.0',
      description: 'Intentionally broken app for app-info error states.',
      health: const LauncherAppBroken(reason: 'lib/app.so is missing.'),
      sizeBytes: 900000,
    ),
  ];
}

/// Numbered apps for responsive Home pagination tests.
List<LauncherApp> sampleNumberedLauncherApps(int count) {
  return List<LauncherApp>.generate(count, (int index) {
    final String number = index.toString().padLeft(2, '0');
    return _sampleApp(
      id: 'dev.example.app$number',
      name: 'App $number',
      version: '1.0.0',
      description: 'Responsive launcher pagination fixture $number.',
    );
  });
}

/// The real product family used by the launcher icon golden.
List<LauncherApp> sampleFeaturedLauncherApps({
  required Map<String, Uint8List> icons,
}) {
  return <LauncherApp>[
    _sampleApp(
      id: 'dev.pluto.codex',
      name: 'Paper Codex',
      version: '0.1.0',
      description: 'An intelligent paper notebook.',
      iconBytes: icons['dev.pluto.codex'],
      isPinned: true,
    ),
    _sampleApp(
      id: 'dev.pluto.examples.motion_lab',
      name: 'Motion Lab',
      version: '0.1.0',
      description: 'Measured e-ink motion experiments.',
      iconBytes: icons['dev.pluto.examples.motion_lab'],
    ),
    _sampleApp(
      id: 'dev.pluto.examples.ink_lab',
      name: 'Ink Lab',
      version: '0.1.0',
      description: 'Live pen and ink experiments.',
      iconBytes: icons['dev.pluto.examples.ink_lab'],
    ),
    _sampleApp(
      id: 'dev.pluto.validation_lab',
      name: 'Validation Lab',
      version: '0.1.0',
      description: 'Renderer validation scenes.',
      iconBytes: icons['dev.pluto.validation_lab'],
    ),
  ];
}

/// The complete field-mark family used by the dedicated icon golden.
List<LauncherApp> sampleIconFamilyApps({
  required Map<String, Uint8List> icons,
}) {
  return <LauncherApp>[
    ...sampleFeaturedLauncherApps(icons: icons),
    _sampleApp(
      id: 'dev.pluto.ink',
      name: 'Ink',
      version: '0.1.0',
      description: 'A full drawing studio for paper.',
      iconBytes: icons['dev.pluto.ink'],
    ),
    _sampleApp(
      id: 'dev.pluto.examples.counter',
      name: 'Counter',
      version: '0.1.0',
      description: 'A minimal release counter.',
      iconBytes: icons['dev.pluto.examples.counter'],
    ),
  ];
}

LauncherApp _sampleApp({
  required String id,
  required String name,
  required String version,
  required String description,
  LauncherAppHealth health = const LauncherAppHealthy(),
  bool isPinned = false,
  int sizeBytes = 0,
  int dataSizeBytes = 0,
  Uint8List? iconBytes,
}) {
  final AppManifest manifest = _decodeManifest(
    id: id,
    name: name,
    version: version,
    description: description,
  );
  return LauncherApp(
    manifest: manifest,
    installRecord: _decodeInstallRecord(sizeBytes: sizeBytes),
    installKind: LauncherInstallKind.release,
    health: health,
    isPinned: isPinned,
    sizeBytes: sizeBytes,
    dataSizeBytes: dataSizeBytes,
    updatedAt: DateTime.utc(2026, 7, 5, 9, 12),
    sourceHost: 'mike-mbp',
    iconBytes: iconBytes,
  );
}

AppManifest _decodeManifest({
  required String id,
  required String name,
  required String version,
  required String description,
}) {
  final Result<AppManifest, ManifestError> result = AppManifest.decode('''
{
  "schema": 1,
  "id": "$id",
  "name": "$name",
  "version": "$version",
  "description": "$description",
  "icon": "icon.png",
  "runtime": {
    "type": "flutter-aot",
    "appElf": "lib/app.so",
    "assets": "flutter_assets"
  },
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "a10d8ac38de835021c8d2f920dbf50a920ccc030",
    "plutoAbi": 1
  },
  "permissions": ["device.info", "settings.read"],
  "display": {
    "orientations": ["portrait", "landscapeLeft", "landscapeRight"],
    "defaultOrientation": "portrait",
    "scale": 2.0,
    "color": "auto",
    "refreshProfile": "ui"
  },
  "launch": {"singleInstance": true, "args": []}
}
''');
  final AppManifest? manifest = result.valueOrNull;
  if (manifest == null) {
    throw StateError(result.errorOrNull?.message ?? 'Invalid sample manifest');
  }
  return manifest;
}

InstallRecord _decodeInstallRecord({required int sizeBytes}) {
  final Result<InstallRecord, ManifestError> result = InstallRecord.decode('''
{
  "schema": 1,
  "installedAt": "2026-07-01T14:03:00Z",
  "installedBy": "pluto 0.1.0",
  "source": "pluto-cli",
  "buildMode": "release",
  "engineFlavor": "release",
  "sizeBytes": $sizeBytes,
  "payload": {"manifest.json": "sha256:sample"}
}
''');
  final InstallRecord? record = result.valueOrNull;
  if (record == null) {
    throw StateError(result.errorOrNull?.message ?? 'Invalid install record');
  }
  return record;
}
