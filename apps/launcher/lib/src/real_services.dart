import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:flutter/services.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'models.dart';
import 'services.dart';

/// The launcher's own app id; it is hidden from its own gallery.
const String kLauncherAppId = 'dev.pluto.launcher';

// SDK pins baked into the launcher build; the embedder does not know them.
const String _flutterVersionPin = '3.44.4';
const String _dartVersionPin = '3.12.2';
const String _engineCommitPin = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

/// Creates services backed by the embedder platform channels
/// (`pluto/session`, `pluto/settings`, `pluto/apps`, `pluto/device`).
///
/// All channels speak the standard method codec. Reads degrade gracefully
/// when a backend is unavailable (e.g. host preview without device sysfs).
LauncherServices createRealServices() {
  return LauncherServices(
    manifests: ChannelManifestRepository(),
    session: ChannelSessionManager(),
    settings: ChannelLauncherSettings(),
    device: ChannelLauncherDeviceRepository(),
  );
}

/// Session manager backed by the embedder `pluto/session` channel.
///
/// Session actions write control files under `/run/pluto`; release/profile
/// embedders hibernate while the native supervisor performs the actual swap.
/// Exiting to stock remains a real shutdown.
final class ChannelSessionManager implements SessionManager {
  /// Creates a session manager over [channel].
  const ChannelSessionManager({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pluto/session');

  final MethodChannel _channel;

  @override
  Stream<SessionEvent> get events => const Stream<SessionEvent>.empty();

  @override
  Future<LaunchResult> launch(AppId id) async {
    try {
      final Object? reply = await _channel.invokeMethod<Object?>(
        'launch',
        <String, Object?>{'appId': id.value},
      );
      final Map<String, Object?> map = _stringKeyed(reply);
      if (map['ok'] == true) {
        // The embedder exits and the supervisor spawns the app; no pid yet.
        return const LaunchSuccess(pid: 0);
      }
      return LaunchFailure(
        reason: _stringOr(map, 'error', 'session channel refused the launch'),
      );
    } on PlatformException catch (error) {
      return LaunchFailure(reason: error.message ?? error.code);
    } on MissingPluginException {
      return const LaunchFailure(
        reason: 'pluto/session channel is not attached',
      );
    }
  }

  @override
  Future<AppSwitcherRequest?> pendingAppSwitcher() async {
    final Map<String, Object?> map = await _invokeMap('switcherInfo');
    if (map['active'] != true || map['originAppId'] is! String) {
      return null;
    }
    final AppId? origin = AppId.tryParse(map['originAppId']! as String);
    if (origin == null) {
      return null;
    }
    final List<AppSwitcherPreview> previews = <AppSwitcherPreview>[];
    final Object? rawApps = map['apps'];
    if (rawApps is List<Object?>) {
      for (final Object? rawApp in rawApps) {
        final Map<String, Object?> app = _stringKeyed(rawApp);
        final AppId? id = AppId.tryParse(_stringOr(app, 'appId', ''));
        if (id == null || id == origin || id.value == kLauncherAppId) {
          continue;
        }
        Uint8List? bytes;
        double? aspectRatio;
        final String path = _stringOr(app, 'previewPath', '');
        if (path.isNotEmpty) {
          try {
            final File preview = File(path);
            if (preview.existsSync() && preview.lengthSync() <= 2 << 20) {
              bytes = preview.readAsBytesSync();
              aspectRatio = _bmpAspectRatio(bytes);
            }
          } on FileSystemException {
            // A just-evicted app can disappear between state and preview read.
          }
        }
        previews.add(
          AppSwitcherPreview(
            appId: id,
            imageBytes: bytes,
            aspectRatio: aspectRatio,
          ),
        );
      }
    }
    return AppSwitcherRequest(originAppId: origin, previews: previews);
  }

  @override
  Future<void> forceStop(AppId id) async {
    await _channel.invokeMethod<Object?>('forceStop', <String, Object?>{
      'appId': id.value,
    });
  }

  @override
  Future<StatusOverlayRequest?> pendingStatusOverlay() async {
    final Map<String, Object?> map = await _invokeMap('statusInfo');
    if (map['active'] != true || map['originAppId'] is! String) {
      return null;
    }
    final AppId? origin = AppId.tryParse(map['originAppId']! as String);
    if (origin == null) {
      return null;
    }
    Uint8List? bytes;
    double? aspectRatio;
    final String path = _stringOr(map, 'previewPath', '');
    if (path.isNotEmpty) {
      try {
        final File preview = File(path);
        if (preview.existsSync() && preview.lengthSync() <= 2 << 20) {
          bytes = preview.readAsBytesSync();
          aspectRatio = _bmpAspectRatio(bytes);
        }
      } on FileSystemException {
        // The origin can crash or be evicted between state and preview read.
      }
    }
    return StatusOverlayRequest(
      originAppId: origin,
      imageBytes: bytes,
      aspectRatio: aspectRatio,
    );
  }

  @override
  Future<PowerMenuRequest?> pendingPowerMenu() async {
    final Map<String, Object?> map = await _invokeMap('powerMenuInfo');
    if (map['active'] != true || map['originAppId'] is! String) {
      return null;
    }
    final AppId? origin = AppId.tryParse(map['originAppId']! as String);
    return origin == null ? null : PowerMenuRequest(originAppId: origin);
  }

  @override
  Future<void> systemUiReady() async {
    await _channel.invokeMethod<void>('systemUiReady');
  }

  @override
  Future<void> cancelLaunch(AppId id) {
    return _invokeBestEffort('cancelLaunch', <String, Object?>{
      'appId': id.value,
    });
  }

  @override
  Future<void> switchToStockUi() => _invokeBestEffort('exitToStock');

  @override
  Future<void> powerOffDevice() async {
    final Map<String, Object?> reply = await _invokeMap('powerOff');
    if (reply['ok'] != true) {
      throw StateError('The supervisor rejected the power-off request.');
    }
  }

  @override
  Future<void> sleepNow() async {
    await _channel.invokeMethod<Object?>('sleepNow');
  }

  @override
  Future<void> handoffStandbyToSupervisor() async {
    final Object? reply = await _channel.invokeMethod<Object?>('suspendNow');
    final Map<String, Object?> map = _stringKeyed(reply);
    if (map['ok'] != true) {
      throw StateError('The supervisor standby handoff was rejected.');
    }
  }

  @override
  Future<void> returnToLauncher() async {
    await _channel.invokeMethod<Object?>('home');
  }

  @override
  Future<SessionInfo> info() async {
    final Map<String, Object?> map = await _invokeMap('info');
    return SessionInfo(
      plutoVersion: _stringOr(map, 'plutoVersion', 'unknown'),
      engineVersion: _stringOr(map, 'engineVersion', _engineCommitPin),
      flutterVersion: _stringOr(map, 'flutterVersion', _flutterVersionPin),
      dartVersion: _stringOr(map, 'dartVersion', _dartVersionPin),
      returnInstructions: _stringOr(
        map,
        'returnInstructions',
        'restart it with pluto-session.sh over SSH.',
      ),
    );
  }

  @override
  Future<LauncherDeveloperStats> developerStats() async {
    final Map<String, Object?> map = await _invokeMap('developerStats');
    return LauncherDeveloperStats(
      vmServiceUri: _stringOr(map, 'vmServiceUri', 'unavailable'),
      renderer: _stringOr(map, 'renderer', 'unknown'),
      ghostPartialsSinceFull: _intOr(map, 'ghostPartialsSinceFull', 0),
      ghostBudget: _intOr(map, 'ghostBudget', 0),
      buildMs: _doubleOr(map, 'buildMs', 0),
      rasterMs: _doubleOr(map, 'rasterMs', 0),
    );
  }

  @override
  Future<void> beginPlutoUninstall(PlutoUninstallOptions options) async {
    // Not implemented natively yet; surfaces the platform error rather than
    // pretending the uninstall happened.
    await _channel.invokeMethod<void>('beginPlutoUninstall', <String, Object?>{
      'deleteAppData': options.deleteAppData,
      'keepAppListBackup': options.keepAppListBackup,
    });
  }

  @override
  Future<void> runDisplayTestCard() => _invokeBestEffort('runDisplayTestCard');

  @override
  Future<void> setDamageOverlayEnabled(bool enabled) {
    return _invokeBestEffort('setDamageOverlay', <String, Object?>{
      'enabled': enabled,
    });
  }

  Future<Map<String, Object?>> _invokeMap(
    String method, [
    Object? arguments,
  ]) async {
    try {
      return _stringKeyed(
        await _channel.invokeMethod<Object?>(method, arguments),
      );
    } on PlatformException {
      return const <String, Object?>{};
    } on MissingPluginException {
      return const <String, Object?>{};
    }
  }

  Future<void> _invokeBestEffort(String method, [Object? arguments]) async {
    await _invokeMap(method, arguments);
  }
}

double? _bmpAspectRatio(Uint8List? bytes) {
  if (bytes == null ||
      bytes.lengthInBytes < 26 ||
      bytes[0] != 0x42 ||
      bytes[1] != 0x4d) {
    return null;
  }
  final ByteData header = ByteData.sublistView(bytes);
  final int width = header.getInt32(18, Endian.little).abs();
  final int height = header.getInt32(22, Endian.little).abs();
  if (width == 0 || height == 0) {
    return null;
  }
  final double ratio = width / height;
  return ratio >= 0.25 && ratio <= 4 ? ratio : null;
}

/// Settings facade backed by the embedder `pluto/settings` channel.
final class ChannelLauncherSettings implements LauncherSettings {
  /// Creates a settings facade over [channel].
  ChannelLauncherSettings({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pluto/settings');

  final MethodChannel _channel;

  static const Duration _statusInterval = Duration(seconds: 5);
  // wpa_supplicant scan results settle shortly after the trigger.
  static const Duration _scanSettle = Duration(milliseconds: 2500);
  static const Duration _connectTimeout = Duration(seconds: 25);
  static const Duration _connectPoll = Duration(seconds: 1);
  final StreamController<StatusSnapshot> _statusUpdates =
      StreamController<StatusSnapshot>.broadcast();
  StatusSnapshot? _latestStatus;
  Timer? _statusTimer;
  int _statusListenerCount = 0;
  bool _disposed = false;
  late final Stream<StatusSnapshot> _statusStream =
      Stream<StatusSnapshot>.multi((
        MultiStreamController<StatusSnapshot> controller,
      ) {
        if (_disposed) {
          controller.close();
          return;
        }
        _statusListenerCount += 1;
        final StatusSnapshot? latest = _latestStatus;
        if (latest != null) {
          controller.add(latest);
        }
        _startStatusPolling();
        final StreamSubscription<StatusSnapshot> subscription = _statusUpdates
            .stream
            .listen(
              controller.add,
              onError: controller.addError,
              onDone: controller.close,
            );
        controller.onCancel = () async {
          await subscription.cancel();
          _statusListenerCount -= 1;
          if (_statusListenerCount == 0) {
            _statusTimer?.cancel();
            _statusTimer = null;
          }
        };
      }, isBroadcast: true);

  @override
  Future<FrontlightState> frontlight() async {
    final Map<String, Object?> map = _stringKeyed(
      await _channel.invokeMethod<Object?>('frontlightGet'),
    );
    if (map['raw'] is! int || map['max'] is! int) {
      throw StateError('Frontlight state is unavailable.');
    }
    return FrontlightState(raw: map['raw']! as int, maxRaw: map['max']! as int);
  }

  @override
  Future<void> setFrontlightRaw(int raw) async {
    await _invokeStrict('frontlightSet', <String, Object?>{'raw': raw});
    await _refreshStatus();
  }

  @override
  Future<RotationPreference> rotationPreference() async {
    final Object? value = await _channel.invokeMethod<Object?>('rotationGet');
    return RotationPreference.parse(value);
  }

  @override
  Future<void> setRotationPreference(RotationPreference preference) async {
    await _invokeStrict('rotationSet', <String, Object?>{
      'value': preference.wireName,
    });
  }

  @override
  Future<WifiStatus> wifiStatus() async {
    final Map<String, Object?> map = _stringKeyed(
      await _channel.invokeMethod<Object?>('wifiStatus'),
    );
    if (map['status'] is! String) {
      throw const FormatException('Wi-Fi status is unavailable.');
    }
    switch (map['status']) {
      case 'connected':
        return WifiConnected(
          connection: WifiConnection(
            ssid: _stringOr(map, 'ssid', ''),
            ipAddress: _stringOr(map, 'ipAddress', ''),
            signal: _doubleOr(map, 'signal', 0),
          ),
        );
      case 'connecting':
        return WifiConnecting(ssid: _stringOr(map, 'ssid', ''));
      case 'disabled':
        return const WifiDisabled();
      default:
        return const WifiDisconnected();
    }
  }

  @override
  Future<List<WifiNetwork>> scanWifiNetworks() async {
    await _invokeStrict('wifiScan');
    await Future<void>.delayed(_scanSettle);
    final Object? reply = await _channel.invokeMethod<Object?>(
      'wifiScanResults',
    );
    if (reply is! List<Object?>) {
      return const <WifiNetwork>[];
    }
    final List<WifiNetwork> networks = <WifiNetwork>[];
    for (final Object? item in reply) {
      final Map<String, Object?> map = _stringKeyed(item);
      final String ssid = _stringOr(map, 'ssid', '');
      if (ssid.isEmpty) {
        continue;
      }
      networks.add(
        WifiNetwork(
          ssid: ssid,
          signal: _doubleOr(map, 'signal', 0),
          security: WifiSecurity.parse(_stringOr(map, 'security', 'unknown')),
          isKnown: _boolOr(map, 'isKnown', false),
          isActive: _boolOr(map, 'isActive', false),
        ),
      );
    }
    return networks;
  }

  @override
  Future<WifiConnection> connectWifi({
    required String ssid,
    String? passphrase,
  }) async {
    await _invokeStrict('wifiConnect', <String, Object?>{
      'ssid': ssid,
      'psk': ?passphrase,
    });
    // wpa_supplicant associates in the background; poll until the active
    // connection matches instead of presenting a speculative success.
    final DateTime deadline = DateTime.now().add(_connectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_connectPoll);
      final WifiStatus status = await wifiStatus();
      if (status is WifiConnected && status.connection.ssid == ssid) {
        await _refreshStatus();
        return status.connection;
      }
    }
    throw TimeoutException('Timed out connecting to "$ssid".', _connectTimeout);
  }

  @override
  Future<void> forgetWifi(String ssid) async {
    await _invokeStrict('wifiForget', <String, Object?>{'ssid': ssid});
    await _refreshStatus();
  }

  @override
  Future<void> setWifiEnabled(bool enabled) async {
    await _invokeStrict('wifiSetEnabled', <String, Object?>{
      'enabled': enabled,
    });
    await _refreshStatus();
  }

  @override
  Future<void> setStandbyTimeout(Duration? delay) {
    return _invokeBestEffort('standbySet', <String, Object?>{
      'ms': delay?.inMilliseconds ?? 0,
    });
  }

  @override
  Future<bool> hasPin() async {
    try {
      return await _channel.invokeMethod<bool>('pinIsSet') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> setPin(String digits) async {
    final DevicePin? pin = DevicePin.tryParse(digits);
    if (pin == null) {
      throw ArgumentError.value(digits, 'digits', 'must be 4-8 digits');
    }
    await _channel.invokeMethod<void>('pinSet', <String, Object?>{
      'digits': pin.digits,
    });
  }

  @override
  Future<void> removePin() => _invokeBestEffort('pinRemove');

  @override
  Future<LauncherNetworkInfo> networkInfo() async {
    final Map<String, Object?> network = await _invokeMap('networkInfo');
    final bool usbConnected = _boolOr(network, 'usbConnected', false);
    final String usbIp = _stringOr(network, 'usbIp', '');
    final String wifiIp = _stringOr(network, 'wifiIp', '');
    return LauncherNetworkInfo(
      usbIp: usbConnected && usbIp.isNotEmpty ? usbIp : null,
      wifiIp: wifiIp.isEmpty ? null : wifiIp,
    );
  }

  @override
  Stream<StatusSnapshot> watchStatus() => _statusStream;

  /// Stops passive status polling and releases stream resources.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _statusTimer?.cancel();
    _statusTimer = null;
    await _statusUpdates.close();
  }

  void _startStatusPolling() {
    if (_statusTimer != null || _disposed) {
      return;
    }
    unawaited(_refreshStatus());
    _statusTimer = Timer.periodic(_statusInterval, (_) {
      unawaited(_refreshStatus());
    });
  }

  Future<void> _refreshStatus() async {
    final StatusSnapshot? status = await _statusSnapshot();
    if (status != null && !_disposed) {
      _latestStatus = status;
      _statusUpdates.add(status);
    }
  }

  Future<StatusSnapshot?> _statusSnapshot() async {
    final Map<String, Object?> battery = await _invokeMap('batteryGet');
    if (!battery.containsKey('levelPercent')) {
      return null;
    }
    final WifiStatus? wifi = await _wifiStatusForChrome();
    final Map<String, Object?> frontlight = await _invokeMap('frontlightGet');
    final bool usbNetworkConnected = _boolOr(
      battery,
      'isUsbNetworkConnected',
      false,
    );
    return StatusSnapshot(
      time: DateTime.now(),
      battery: StatusBattery(
        levelPercent: _intOr(battery, 'levelPercent', 0).clamp(0, 100),
        isCharging: _boolOr(battery, 'isCharging', false),
      ),
      penBattery: battery.containsKey('markerLevelPercent')
          ? StatusPenBattery(
              levelPercent: _intOr(
                battery,
                'markerLevelPercent',
                0,
              ).clamp(0, 100),
            )
          : null,
      wifi: wifi is WifiConnected
          ? StatusWifi(
              ssid: wifi.connection.ssid,
              signalPercent: (wifi.connection.signal * 100).round().clamp(
                0,
                100,
              ),
            )
          : null,
      isWifiEnabled: wifi is! WifiDisabled,
      frontlightRaw: frontlight.containsKey('raw')
          ? _intOr(frontlight, 'raw', 0)
          : null,
      frontlightMaxRaw: _intOr(frontlight, 'max', 2047),
      isUsbTethered: usbNetworkConnected,
    );
  }

  Future<WifiStatus?> _wifiStatusForChrome() async {
    try {
      return await wifiStatus();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, Object?>> _invokeMap(
    String method, [
    Object? arguments,
  ]) async {
    try {
      return _stringKeyed(
        await _channel.invokeMethod<Object?>(method, arguments),
      );
    } on PlatformException {
      return const <String, Object?>{};
    } on MissingPluginException {
      return const <String, Object?>{};
    }
  }

  Future<void> _invokeBestEffort(String method, [Object? arguments]) async {
    await _invokeMap(method, arguments);
  }

  Future<void> _invokeStrict(String method, [Object? arguments]) async {
    await _channel.invokeMethod<Object?>(method, arguments);
  }
}

/// Installed-app repository backed by the embedder `pluto/apps` channel.
///
/// The embedder reads `/home/root/pluto/apps/<id>/manifest.json` and
/// returns raw manifest/install-record JSON; validation happens here with
/// `pluto_manifest`.
final class ChannelManifestRepository implements ManifestRepository {
  /// Creates a manifest repository over [channel].
  ChannelManifestRepository({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pluto/apps');

  final MethodChannel _channel;
  final StreamController<List<LauncherApp>> _changes =
      StreamController<List<LauncherApp>>.broadcast();

  @override
  Stream<List<LauncherApp>> watchApps() async* {
    yield await _list();
    yield* _changes.stream;
  }

  @override
  Future<LauncherApp?> appById(AppId id) async {
    for (final LauncherApp app in await _list()) {
      if (app.id == id) {
        return app;
      }
    }
    return null;
  }

  @override
  Future<void> uninstall(AppId id, {required bool deleteData}) async {
    await _channel.invokeMethod<void>('uninstall', <String, Object?>{
      'appId': id.value,
      'deleteData': deleteData,
    });
    await _emit();
  }

  @override
  Future<void> clearAppData(AppId id) async {
    await _channel.invokeMethod<void>('clearAppData', <String, Object?>{
      'appId': id.value,
    });
    await _emit();
  }

  @override
  Future<void> setPinned(AppId id, {required bool isPinned}) async {
    await _channel.invokeMethod<void>('setPinned', <String, Object?>{
      'appId': id.value,
      'isPinned': isPinned,
    });
    await _emit();
  }

  /// Disposes stream resources.
  Future<void> dispose() => _changes.close();

  Future<void> _emit() async {
    if (_changes.isClosed) {
      return;
    }
    _changes.add(await _list());
  }

  Future<List<LauncherApp>> _list() async {
    Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>('list');
    } on PlatformException {
      return const <LauncherApp>[];
    } on MissingPluginException {
      return const <LauncherApp>[];
    }
    if (reply is! List<Object?>) {
      return const <LauncherApp>[];
    }
    final List<LauncherApp> apps = <LauncherApp>[];
    for (final Object? item in reply) {
      final LauncherApp? app = _decodeApp(_stringKeyed(item));
      // The launcher never lists itself in its own gallery.
      if (app != null && app.id.value != kLauncherAppId) {
        apps.add(app);
      }
    }
    apps.sort((LauncherApp a, LauncherApp b) {
      if (a.isPinned != b.isPinned) {
        return a.isPinned ? -1 : 1;
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return apps;
  }

  LauncherApp? _decodeApp(Map<String, Object?> map) {
    final String id = _stringOr(map, 'id', '');
    final Object? manifestJson = map['manifest'];
    String? error = map['error'] is String ? map['error']! as String : null;

    AppManifest? manifest;
    if (manifestJson is String) {
      final Result<AppManifest, ManifestError> result = AppManifest.decode(
        manifestJson,
      );
      manifest = result.valueOrNull;
      if (manifest == null) {
        error ??=
            result.errorOrNull?.message ?? 'manifest.json failed validation';
      }
    }
    // A broken registry entry still needs a valid manifest for LauncherApp;
    // synthesize a placeholder from the directory name.
    manifest ??= _placeholderManifest(id);
    if (manifest == null) {
      return null;
    }

    InstallRecord? record;
    final Object? installJson = map['install'];
    if (installJson is String) {
      record = InstallRecord.decode(installJson).valueOrNull;
    }

    final int updatedAtMs = _intOr(map, 'updatedAtMs', 0);
    final Uint8List? iconBytes = _readIconBytes(
      _stringOr(map, 'path', ''),
      manifest.iconMono ?? manifest.icon,
    );
    return LauncherApp(
      manifest: manifest,
      installRecord: record,
      installKind: record?.buildMode == BuildMode.debug
          ? LauncherInstallKind.dev
          : LauncherInstallKind.release,
      health: error == null
          ? const LauncherAppHealthy()
          : LauncherAppBroken(reason: error),
      isPinned: _boolOr(map, 'isPinned', false),
      sizeBytes: _intOr(map, 'sizeBytes', 0),
      dataSizeBytes: _intOr(map, 'dataSizeBytes', 0),
      updatedAt: updatedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(updatedAtMs)
          : null,
      sourceHost: record?.installedBy,
      iconBytes: iconBytes,
    );
  }

  Uint8List? _readIconBytes(String appPath, String relativePath) {
    if (appPath.isEmpty || relativePath.isEmpty) {
      return null;
    }
    try {
      final File icon = File('$appPath/$relativePath');
      if (!icon.existsSync() || icon.lengthSync() > 2 * 1024 * 1024) {
        return null;
      }
      return icon.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  AppManifest? _placeholderManifest(String id) {
    if (AppId.tryParse(id) == null) {
      return null;
    }
    final String name = id.split('.').last;
    final Result<AppManifest, ManifestError> result = AppManifest.decode(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'id': id,
        'name': name.isEmpty
            ? id
            : '${name[0].toUpperCase()}${name.substring(1)}',
        'version': '0.0.0',
        'runtime': <String, Object?>{
          'type': 'flutter-aot',
          'appElf': 'lib/app.so',
          'assets': 'flutter_assets',
        },
        'engine': <String, Object?>{
          'flutterVersion': _flutterVersionPin,
          'engineCommit': _engineCommitPin,
          'plutoAbi': 1,
        },
      }),
    );
    return result.valueOrNull;
  }
}

/// Device identity backed by the embedder `pluto/device` channel.
final class ChannelLauncherDeviceRepository
    implements LauncherDeviceRepository {
  /// Creates a device repository over [channel].
  ChannelLauncherDeviceRepository({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pluto/device');

  final MethodChannel _channel;
  Future<DeviceInfo>? _cached;

  @override
  Future<DeviceInfo> deviceInfo() => _cached ??= _read();

  Future<DeviceInfo> _read() async {
    Map<String, Object?> map = const <String, Object?>{};
    try {
      map = _stringKeyed(await _channel.invokeMethod<Object?>('getInfo'));
    } on PlatformException {
      // Fall through to defaults below.
    } on MissingPluginException {
      // Fall through to defaults below.
    }
    final Map<String, Object?> panel = _stringKeyed(map['panelSize']);
    final String codename = _stringOr(map, 'codename', 'chiappa');
    return DeviceInfo(
      model: RemarkableModel.parse(
        _stringOr(map, 'model', 'paperProMove'),
        codename,
      ),
      codename: codename,
      firmwareBuild: _stringOr(map, 'firmwareVersion', 'unknown'),
      osVersion: 'unknown',
      panel: PanelGeometry(
        width: _intOr(panel, 'width', 954),
        height: _intOr(panel, 'height', 1696),
        dpi: _intOr(map, 'dpi', 264),
        pixelFormat: PanelPixelFormat.rgb565,
        colorMode: _boolOr(map, 'isColor', true)
            ? PanelColorMode.gallery3
            : PanelColorMode.monochrome,
      ),
    );
  }
}

Map<String, Object?> _stringKeyed(Object? value) {
  if (value is! Map<Object?, Object?>) {
    return const <String, Object?>{};
  }
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is String) {
      result[key] = entry.value;
    }
  }
  return result;
}

String _stringOr(Map<String, Object?> map, String key, String fallback) {
  final Object? value = map[key];
  return value is String ? value : fallback;
}

int _intOr(Map<String, Object?> map, String key, int fallback) {
  final Object? value = map[key];
  return value is int ? value : fallback;
}

double _doubleOr(Map<String, Object?> map, String key, double fallback) {
  final Object? value = map[key];
  return value is num ? value.toDouble() : fallback;
}

bool _boolOr(Map<String, Object?> map, String key, bool fallback) {
  final Object? value = map[key];
  return value is bool ? value : fallback;
}
