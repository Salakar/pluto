import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:pluto_settings/pluto_settings.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'models.dart';

/// Installed manifest repository consumed by Home and App Info.
abstract interface class ManifestRepository {
  /// Watches installed apps.
  Stream<List<LauncherApp>> watchApps();

  /// Returns an app by id.
  Future<LauncherApp?> appById(AppId id);

  /// Uninstalls an app.
  Future<void> uninstall(AppId id, {required bool deleteData});

  /// Deletes an app's data directory, keeping the app installed.
  Future<void> clearAppData(AppId id);

  /// Pins or unpins an app.
  Future<void> setPinned(AppId id, {required bool isPinned});
}

/// Session event emitted by `plutod`.
sealed class SessionEvent {
  const SessionEvent();
}

/// Registry changed event.
final class RegistryChanged extends SessionEvent {
  /// Creates a registry changed event.
  const RegistryChanged();
}

/// Running app exited event.
final class AppExited extends SessionEvent {
  /// Creates an app-exited event.
  const AppExited({
    required this.appId,
    required this.exitCode,
    required this.wasCrash,
  });

  /// App id.
  final AppId appId;

  /// Exit code.
  final int exitCode;

  /// Whether the exit was considered a crash.
  final bool wasCrash;
}

/// Session manager API backed by `plutod`.
abstract interface class SessionManager {
  /// Fetches session information.
  Future<SessionInfo> info();

  /// Fetches renderer diagnostics for the developer screen.
  Future<LauncherDeveloperStats> developerStats();

  /// Shows the display calibration test card.
  Future<void> runDisplayTestCard();

  /// Enables or disables the damage-rect debug overlay.
  Future<void> setDamageOverlayEnabled(bool enabled);

  /// Launches [id].
  Future<LaunchResult> launch(AppId id);

  /// Returns the active supervisor-authored switcher request, if any.
  Future<AppSwitcherRequest?> pendingAppSwitcher();

  /// Terminates a warm background app selected in the app switcher.
  Future<void> forceStop(AppId id);

  /// Returns the active supervisor-authored status shade request, if any.
  Future<StatusOverlayRequest?> pendingStatusOverlay();

  /// Returns the active supervisor-authored power menu request, if any.
  Future<PowerMenuRequest?> pendingPowerMenu();

  /// Releases the native no-flash gate after system UI has been routed.
  Future<void> systemUiReady();

  /// Cancels a launch attempt.
  Future<void> cancelLaunch(AppId id);

  /// Switches to the stock reMarkable UI.
  Future<void> switchToStockUi();

  /// Requests a safe full device power-off through the supervisor.
  Future<void> powerOffDevice();

  /// Starts the full Pluto uninstall flow.
  Future<void> beginPlutoUninstall(PlutoUninstallOptions options);

  /// Requests the supervisor-managed standby launcher transition.
  Future<void> sleepNow();

  /// Hands standby to the supervisor and requests this engine to shut down.
  ///
  /// A successful return means the handoff was accepted. The supervisor closes
  /// the display stack before suspending and owns post-wake light restoration.
  Future<void> handoffStandbyToSupervisor();

  /// Restarts the launcher at its normal home route.
  Future<void> returnToLauncher();

  /// Session event stream.
  Stream<SessionEvent> get events;
}

/// Settings and telemetry used by the launcher.
abstract interface class LauncherSettings {
  /// Watches status chrome data.
  Stream<StatusSnapshot> watchStatus();

  /// Reads frontlight state.
  Future<FrontlightState> frontlight();

  /// Sets the raw frontlight value.
  Future<void> setFrontlightRaw(int raw);

  /// Reads the global orientation preference. Missing persisted state is Auto.
  Future<RotationPreference> rotationPreference();

  /// Persists the global orientation preference for subsequent app launches.
  Future<void> setRotationPreference(RotationPreference preference);

  /// Reads current Wi-Fi status.
  Future<WifiStatus> wifiStatus();

  /// Enables or disables Wi-Fi.
  Future<void> setWifiEnabled(bool enabled);

  /// Scans visible Wi-Fi networks.
  Future<List<WifiNetwork>> scanWifiNetworks();

  /// Connects to a Wi-Fi network.
  Future<WifiConnection> connectWifi({
    required String ssid,
    String? passphrase,
  });

  /// Forgets a Wi-Fi network.
  Future<void> forgetWifi(String ssid);

  /// Sets standby timeout.
  Future<void> setStandbyTimeout(Duration? delay);

  /// Sets the device PIN.
  Future<void> setPin(String digits);

  /// Removes the device PIN.
  Future<void> removePin();

  /// Whether a lock PIN is currently set.
  Future<bool> hasPin();

  /// Reads current network addresses for developer surfaces.
  Future<LauncherNetworkInfo> networkInfo();
}

/// User-facing orientation policy applied within each app manifest's limits.
enum RotationPreference {
  /// Follow the device accelerometer when the app supports that orientation.
  auto('auto', 'Auto'),

  /// Prefer upright portrait, falling back to the app's declared default.
  portrait('portrait', 'Portrait'),

  /// Prefer landscape-left, falling back to another allowed landscape mode.
  landscape('landscape', 'Landscape');

  const RotationPreference(this.wireName, this.label);

  /// Stable value persisted by the native settings service.
  final String wireName;

  /// Settings UI label.
  final String label;

  /// Parses a persisted value, defaulting safely to Auto.
  static RotationPreference parse(Object? value) {
    return RotationPreference.values.firstWhere(
      (RotationPreference preference) => preference.wireName == value,
      orElse: () => RotationPreference.auto,
    );
  }
}

/// Device identity source.
abstract interface class LauncherDeviceRepository {
  /// Reads device info.
  Future<DeviceInfo> deviceInfo();
}

/// Service bundle injected into the launcher app.
final class LauncherServices {
  /// Creates a service bundle.
  const LauncherServices({
    required this.manifests,
    required this.session,
    required this.settings,
    required this.device,
  });

  /// Installed-app repository.
  final ManifestRepository manifests;

  /// Session manager.
  final SessionManager session;

  /// Settings facade.
  final LauncherSettings settings;

  /// Device info repository.
  final LauncherDeviceRepository device;
}

/// Channel-backed session manager for the on-device launcher.
final class PlutodSessionManager implements SessionManager {
  /// Creates a session manager using [channel].
  const PlutodSessionManager({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pluto/launcher');

  final MethodChannel _channel;

  @override
  Stream<SessionEvent> get events => const Stream<SessionEvent>.empty();

  @override
  Future<void> beginPlutoUninstall(PlutoUninstallOptions options) async {
    await _channel.invokeMethod<void>('beginPlutoUninstall', <String, Object?>{
      'deleteAppData': options.deleteAppData,
      'keepAppListBackup': options.keepAppListBackup,
    });
  }

  @override
  Future<void> cancelLaunch(AppId id) async {
    await _channel.invokeMethod<void>('cancelLaunch', <String, Object?>{
      'appId': id.value,
    });
  }

  @override
  Future<SessionInfo> info() async {
    final Map<String, Object?>? map = await _channel
        .invokeMapMethod<String, Object?>('info');
    if (map == null) {
      throw const FormatException('Missing session info.');
    }
    return SessionInfo(
      backendMode: _backendMode(map['backendMode']),
      plutoVersion: _string(map, 'plutoVersion'),
      engineVersion: _string(map, 'engineVersion'),
      flutterVersion: _string(map, 'flutterVersion'),
      dartVersion: _string(map, 'dartVersion'),
      returnInstructions: _string(map, 'returnInstructions'),
    );
  }

  @override
  Future<LaunchResult> launch(AppId id) async {
    final Map<String, Object?>? map = await _channel
        .invokeMapMethod<String, Object?>('launch', <String, Object?>{
          'appId': id.value,
        });
    if (map == null) {
      return const LaunchFailure(reason: 'plutod returned no response');
    }
    final bool ok = map['ok'] == true;
    if (ok) {
      return LaunchSuccess(pid: _int(map, 'pid'));
    }
    return LaunchFailure(
      reason: _string(map, 'error'),
      stderr: map['stderr'] is String ? map['stderr']! as String : null,
    );
  }

  @override
  Future<AppSwitcherRequest?> pendingAppSwitcher() async => null;

  @override
  Future<void> forceStop(AppId id) async {
    await _channel.invokeMethod<void>('forceStop', <String, Object?>{
      'appId': id.value,
    });
  }

  @override
  Future<StatusOverlayRequest?> pendingStatusOverlay() async => null;

  @override
  Future<PowerMenuRequest?> pendingPowerMenu() async => null;

  @override
  Future<void> systemUiReady() async {
    await _channel.invokeMethod<void>('systemUiReady');
  }

  @override
  Future<void> sleepNow() async {
    await _channel.invokeMethod<void>('sleepNow');
  }

  @override
  Future<void> handoffStandbyToSupervisor() async {
    await _channel.invokeMethod<void>('suspendNow');
  }

  @override
  Future<void> returnToLauncher() async {
    await _channel.invokeMethod<void>('home');
  }

  @override
  Future<void> switchToStockUi() async {
    await _channel.invokeMethod<void>('exitToStock');
  }

  @override
  Future<void> powerOffDevice() async {
    await _channel.invokeMethod<void>('powerOff');
  }

  @override
  Future<LauncherDeveloperStats> developerStats() async {
    final Map<String, Object?> map =
        await _channel.invokeMapMethod<String, Object?>('developerStats') ??
        const <String, Object?>{};
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
  Future<void> runDisplayTestCard() async {
    await _channel.invokeMethod<void>('runDisplayTestCard');
  }

  @override
  Future<void> setDamageOverlayEnabled(bool enabled) async {
    await _channel.invokeMethod<void>('setDamageOverlay', <String, Object?>{
      'enabled': enabled,
    });
  }
}

/// Settings facade backed by `pluto_settings`.
final class PlutoLauncherSettings implements LauncherSettings {
  /// Creates a launcher settings wrapper.
  PlutoLauncherSettings({
    PlutoSettings? settings,
    MethodChannel? rotationChannel,
  }) : _settings = settings ?? PlutoSettings.instance,
       _rotationChannel =
           rotationChannel ?? const MethodChannel('pluto/settings');

  final PlutoSettings _settings;
  final MethodChannel _rotationChannel;

  @override
  Future<WifiConnection> connectWifi({
    required String ssid,
    String? passphrase,
  }) {
    return _settings.wifi.connect(ssid: ssid, passphrase: passphrase);
  }

  @override
  Future<void> forgetWifi(String ssid) {
    return _settings.wifi.forgetNetwork(ssid: ssid);
  }

  @override
  Future<FrontlightState> frontlight() => _settings.frontlight.state();

  @override
  Future<void> removePin() => _settings.security.removePin();

  @override
  Future<List<WifiNetwork>> scanWifiNetworks() => _settings.wifi.scanNetworks();

  @override
  Future<void> setFrontlightRaw(int raw) {
    return _settings.frontlight.setBrightnessRaw(raw);
  }

  @override
  Future<RotationPreference> rotationPreference() async {
    final Object? value = await _rotationChannel.invokeMethod<Object?>(
      'rotationGet',
    );
    return RotationPreference.parse(value);
  }

  @override
  Future<void> setRotationPreference(RotationPreference preference) {
    return _rotationChannel.invokeMethod<void>('rotationSet', <String, Object?>{
      'value': preference.wireName,
    });
  }

  @override
  Future<void> setPin(String digits) {
    final DevicePin? pin = DevicePin.tryParse(digits);
    if (pin == null) {
      throw ArgumentError.value(digits, 'digits', 'must be 4-8 digits');
    }
    return _settings.security.setPin(pin);
  }

  @override
  Future<void> setStandbyTimeout(Duration? delay) {
    return _settings.power.setIdleSuspendDelay(delay ?? Duration.zero);
  }

  @override
  Future<void> setWifiEnabled(bool enabled) {
    return _settings.wifi.setEnabled(enabled);
  }

  @override
  Stream<StatusSnapshot> watchStatus() async* {
    yield await _readStatusSnapshot();
  }

  @override
  Future<WifiStatus> wifiStatus() async {
    final WifiConnection? connection = await _settings.wifi.activeConnection();
    if (connection == null) {
      final bool enabled = await _settings.wifi.isEnabled();
      return enabled ? const WifiDisconnected() : const WifiDisabled();
    }
    return WifiConnected(connection: connection);
  }

  @override
  Future<bool> hasPin() => _settings.security.isPinSet();

  @override
  Future<LauncherNetworkInfo> networkInfo() async {
    final WifiConnection? connection = await _settings.wifi.activeConnection();
    return LauncherNetworkInfo(
      // The package-level API does not expose USB link state. Do not infer a
      // tether from charger power; the on-device channel implementation reads
      // the actual USB network carrier.
      usbIp: null,
      wifiIp: connection?.ipAddress,
    );
  }

  Future<StatusSnapshot> _readStatusSnapshot() async {
    final BatteryStatus battery = await _settings.battery.deviceBattery();
    final MarkerBatteryStatus? marker = await _settings.battery.markerBattery();
    final WifiStatus wifi = await wifiStatus();
    final FrontlightState frontlight = await _settings.frontlight.state();
    return StatusSnapshot(
      time: DateTime.now(),
      battery: StatusBattery(
        levelPercent: (battery.level * 100).round().clamp(0, 100),
        isCharging:
            battery.state == BatteryChargingState.charging ||
            battery.state == BatteryChargingState.full,
      ),
      penBattery: marker == null
          ? null
          : StatusPenBattery(
              levelPercent: (marker.level * 100).round().clamp(0, 100),
            ),
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
      frontlightRaw: frontlight.raw,
      frontlightMaxRaw: frontlight.maxRaw,
      isUsbTethered: false,
    );
  }
}

/// Device repository backed by `pluto_device`.
final class PlutoDeviceRepository implements LauncherDeviceRepository {
  /// Creates a device repository.
  PlutoDeviceRepository({PlutoDevice? device})
    : _device = device ?? PlutoDevice.instance;

  final PlutoDevice _device;

  @override
  Future<DeviceInfo> deviceInfo() => _device.deviceInfo();
}

LauncherBackendMode _backendMode(Object? value) {
  return switch (value) {
    'qtfbCooperative' => LauncherBackendMode.qtfbCooperative,
    'ownSwtcon' => LauncherBackendMode.ownSwtcon,
    'hostPreview' => LauncherBackendMode.hostPreview,
    _ => LauncherBackendMode.hostPreview,
  };
}

String _string(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key string.');
}

int _int(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key int.');
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
