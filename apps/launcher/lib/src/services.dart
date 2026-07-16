import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pluto_core/pluto_core.dart';
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

/// Session manager API backed by the Pluto supervisor.
abstract interface class SessionManager {
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

  /// Switches to the stock reMarkable UI.
  Future<void> switchToStockUi();

  /// Requests a safe full device power-off through the supervisor.
  Future<void> powerOffDevice();

  /// Requests the supervisor-managed standby launcher transition.
  Future<void> sleepNow();

  /// Hands standby to the supervisor and requests this engine to shut down.
  ///
  /// A successful return means the handoff was accepted. The supervisor closes
  /// the display stack before suspending and owns post-wake light restoration.
  Future<void> handoffStandbyToSupervisor();

  /// Restarts the launcher at its normal home route.
  Future<void> returnToLauncher();
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

  /// Reads the capabilities exposed by the validated device profile.
  Future<DeviceCapabilities> capabilities();
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

/// Settings facade backed by `pluto_settings`.
final class PlutoLauncherSettings implements LauncherSettings {
  /// Creates a launcher settings wrapper.
  PlutoLauncherSettings({PlutoSettings? settings, MethodChannel? channel})
    : _settings = settings ?? PlutoSettings.instance,
      _channel = channel ?? const MethodChannel('pluto/settings');

  final PlutoSettings _settings;
  final MethodChannel _channel;
  static const Duration _statusInterval = Duration(seconds: 5);
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
  Future<WifiConnection> connectWifi({
    required String ssid,
    String? passphrase,
  }) async {
    final WifiConnection connection = await _settings.wifi.connect(
      ssid: ssid,
      passphrase: passphrase,
    );
    await _refreshStatus();
    return connection;
  }

  @override
  Future<void> forgetWifi(String ssid) {
    return _refreshAfter(_settings.wifi.forgetNetwork(ssid: ssid));
  }

  @override
  Future<FrontlightState> frontlight() => _settings.frontlight.state();

  @override
  Future<void> removePin() => _settings.security.removePin();

  @override
  Future<List<WifiNetwork>> scanWifiNetworks() => _settings.wifi.scanNetworks();

  @override
  Future<void> setFrontlightRaw(int raw) {
    return _refreshAfter(_settings.frontlight.setBrightnessRaw(raw));
  }

  @override
  Future<RotationPreference> rotationPreference() async {
    final Object? value = await _channel.invokeMethod<Object?>('rotation.read');
    return RotationPreference.parse(value);
  }

  @override
  Future<void> setRotationPreference(RotationPreference preference) {
    return _channel.invokeMethod<void>('rotation.write', <String, Object?>{
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
    return _refreshAfter(_settings.wifi.setEnabled(enabled));
  }

  @override
  Stream<StatusSnapshot> watchStatus() => _statusStream;

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
    final Map<String, Object?> network = await _readAuxiliaryMap(
      'network.info',
    );
    final bool usbConnected = _boolOr(network, 'usbConnected', false);
    final String usbIp = _stringOr(network, 'usbIp', '');
    return LauncherNetworkInfo(
      // pluto_settings intentionally keeps USB gadget state out of the Wi-Fi
      // facade. The native dotted method reads the actual network carrier; it
      // never infers a tether from charger power.
      usbIp: usbConnected && usbIp.isNotEmpty ? usbIp : null,
      wifiIp: connection?.ipAddress,
    );
  }

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

  Future<void> _refreshAfter(Future<void> operation) async {
    await operation;
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    if (_statusListenerCount == 0 || _disposed) {
      return;
    }
    final StatusSnapshot? status = await _readStatusSnapshot();
    if (status != null && !_disposed) {
      _latestStatus = status;
      _statusUpdates.add(status);
    }
  }

  Future<StatusSnapshot?> _readStatusSnapshot() async {
    final BatteryStatus battery;
    try {
      battery = await _settings.battery.deviceBattery();
    } on PlutoException {
      return null;
    } on FormatException {
      return null;
    }

    MarkerBatteryStatus? marker;
    try {
      marker = await _settings.battery.markerBattery();
    } on PlutoException {
      marker = null;
    } on FormatException {
      marker = null;
    }

    final WifiStatus? wifi = await _wifiStatusForChrome();
    FrontlightState? frontlight;
    try {
      frontlight = await _settings.frontlight.state();
    } on PlutoException {
      frontlight = null;
    } on FormatException {
      frontlight = null;
    }
    final Map<String, Object?> network = await _readAuxiliaryMap(
      'network.info',
    );
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
      frontlightRaw: frontlight?.raw,
      frontlightMaxRaw: frontlight?.maxRaw ?? 2047,
      isUsbTethered: _boolOr(network, 'usbConnected', false),
    );
  }

  Future<WifiStatus?> _wifiStatusForChrome() async {
    try {
      return await wifiStatus();
    } on PlutoException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, Object?>> _readAuxiliaryMap(String method) async {
    try {
      final Object? value = await _channel.invokeMethod<Object?>(method);
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
    } on PlatformException {
      return const <String, Object?>{};
    } on MissingPluginException {
      return const <String, Object?>{};
    }
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

  @override
  Future<DeviceCapabilities> capabilities() => _device.capabilities();
}

String _stringOr(Map<String, Object?> map, String key, String fallback) {
  final Object? value = map[key];
  return value is String ? value : fallback;
}

bool _boolOr(Map<String, Object?> map, String key, bool fallback) {
  final Object? value = map[key];
  return value is bool ? value : fallback;
}
