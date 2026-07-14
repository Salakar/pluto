import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pluto_manifest/pluto_manifest.dart';

import 'install_transaction.dart';

/// An installed app exposed by the plutod registry.
final class PlutodRegisteredApp {
  /// Creates a registered app.
  const PlutodRegisteredApp({
    required this.id,
    required this.name,
    required this.version,
    required this.appDir,
    required this.dataDir,
  });

  /// App id.
  final AppId id;

  /// Display name.
  final String name;

  /// Version string.
  final String version;

  /// Payload directory.
  final String appDir;

  /// Writable app-data directory.
  final String dataDir;
}

/// Registry read by plutod for list/launch operations.
abstract interface class PlutodRegistry {
  /// Lists installed apps.
  Future<List<PlutodRegisteredApp>> listApps();

  /// Finds one installed app.
  Future<PlutodRegisteredApp?> getApp(AppId id);

  /// Re-scans backing storage.
  Future<void> refresh();
}

/// Registry backed by the manifest install transaction filesystem.
final class TransactionPlutodRegistry implements PlutodRegistry {
  /// Creates a transaction-backed registry.
  const TransactionPlutodRegistry(this.transaction);

  /// Install transaction used for discovery.
  final PlutoInstallTransaction transaction;

  @override
  Future<PlutodRegisteredApp?> getApp(AppId id) async {
    final List<PlutodRegisteredApp> apps = await listApps();
    for (final PlutodRegisteredApp app in apps) {
      if (app.id.value == id.value) {
        return app;
      }
    }
    return null;
  }

  @override
  Future<List<PlutodRegisteredApp>> listApps() async {
    final List<InstalledApp> installed = await transaction
        .discoverInstalledApps();
    return <PlutodRegisteredApp>[
      for (final InstalledApp app in installed)
        PlutodRegisteredApp(
          id: app.manifest.id,
          name: app.manifest.name,
          version: app.manifest.version.toString(),
          appDir: app.appDir,
          dataDir: app.dataDir,
        ),
    ];
  }

  @override
  Future<void> refresh() async {
    await transaction.repair();
  }
}

/// Launch request handed to the device integration layer.
final class PlutoLaunchSpec {
  /// Creates a launch spec.
  const PlutoLaunchSpec({
    required this.appId,
    required this.appDir,
    required this.dataDir,
  });

  /// App id.
  final AppId appId;

  /// Payload directory.
  final String appDir;

  /// Writable app-data directory.
  final String dataDir;
}

/// Spawned embedder process handle.
final class PlutoProcessHandle {
  /// Creates a process handle.
  const PlutoProcessHandle({required this.pid});

  /// Process id.
  final int pid;
}

/// Device operations used by plutod.
abstract interface class PlutodDevice {
  /// Spawns one `pluto-embedder` process for [spec].
  Future<PlutoProcessHandle> launchEmbedder(PlutoLaunchSpec spec);

  /// Brings an already-running app to the front.
  Future<void> foregroundApp(AppId id);

  /// Brings the launcher home surface to the front.
  Future<void> showLauncher();

  /// Leaves Pluto for stock xochitl UI.
  Future<void> exitToStock();

  /// Terminates a running embedder process.
  Future<void> terminateProcess(int pid);

  /// Starts the full Pluto uninstall script.
  Future<void> runFullUninstall();
}

/// App uninstaller used by the `uninstall` operation.
abstract interface class PlutodAppUninstaller {
  /// Uninstalls [appId].
  Future<void> uninstall(AppId appId, {required bool purgeData});
}

/// App uninstaller backed by [PlutoInstallTransaction].
final class TransactionPlutodAppUninstaller implements PlutodAppUninstaller {
  /// Creates a transaction-backed app uninstaller.
  const TransactionPlutodAppUninstaller(this.transaction);

  /// Install transaction.
  final PlutoInstallTransaction transaction;

  @override
  Future<void> uninstall(AppId appId, {required bool purgeData}) async {
    await transaction.uninstall(appId.value, purgeData: purgeData);
  }
}

/// One running app process tracked by plutod.
final class PlutodRunningApp {
  /// Creates a running app state.
  const PlutodRunningApp({required this.appId, required this.pid});

  /// App id.
  final AppId appId;

  /// Process id.
  final int pid;
}

/// In-process plutod protocol server and state machine.
final class PlutodServer {
  /// Creates a plutod server.
  PlutodServer({
    required this.registry,
    required this.device,
    this.uninstaller,
    this.plutoVersion = '0.1.0',
    this.backendMode = 'qtfb-cooperative',
  });

  /// Installed-app registry.
  final PlutodRegistry registry;

  /// Device operations.
  final PlutodDevice device;

  /// App uninstaller.
  final PlutodAppUninstaller? uninstaller;

  /// Platform version reported in status.
  final String plutoVersion;

  /// Display backend mode reported in status.
  final String backendMode;

  final Map<String, PlutodRunningApp> _running = <String, PlutodRunningApp>{};
  String _foreground = 'launcher';

  /// Snapshot of currently running apps.
  List<PlutodRunningApp> get runningApps => List<PlutodRunningApp>.unmodifiable(
    _running.values.toList()..sort(_compareRunning),
  );

  /// Handles one newline-delimited JSON request line.
  Future<String> handleJsonLine(String line) async {
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        return _encodeError('badRequest', 'Request must be a JSON object.');
      }
      final Map<String, Object?> response = await handleRequest(decoded);
      return jsonEncode(response);
    } on FormatException catch (error) {
      return _encodeError('badJson', error.message);
    } on PlutodProtocolException catch (error) {
      return _encodeError(error.code, error.message);
    } on Object catch (error) {
      return _encodeError('internal', error.toString());
    }
  }

  /// Handles one decoded request object.
  Future<Map<String, Object?>> handleRequest(
    Map<String, Object?> request,
  ) async {
    final int version = _optionalInt(request, 'v') ?? 1;
    if (version != 1) {
      throw PlutodProtocolException(
        code: 'unsupportedVersion',
        message: 'Unsupported plutod protocol version $version.',
      );
    }
    final String op = _requiredString(request, 'op');
    switch (op) {
      case 'launch':
        return _launch(_requiredAppId(request));
      case 'list':
        return _list();
      case 'foreground':
        return _foregroundApp(_requiredAppId(request));
      case 'home':
        await device.showLauncher();
        _foreground = 'launcher';
        return _ok();
      case 'exitToStock':
        await device.exitToStock();
        _foreground = 'stock';
        return _ok();
      case 'uninstall':
        return _uninstall(
          _requiredAppId(request),
          purgeData: request['purgeData'] == true,
        );
      case 'registryChanged':
        await registry.refresh();
        return _ok();
      case 'status':
        return _status();
      case 'beginFullUninstall':
        await device.runFullUninstall();
        return _ok();
      default:
        throw PlutodProtocolException(
          code: 'unknownOp',
          message: 'Unknown operation: $op.',
        );
    }
  }

  /// Marks [appId] as exited.
  void processExited(AppId appId) {
    _running.remove(appId.value);
    if (_foreground == appId.value) {
      _foreground = 'launcher';
    }
  }

  /// Serves the protocol on a Unix-domain socket.
  Future<ServerSocket> serve(String socketPath) async {
    final File stale = File(socketPath);
    if (stale.existsSync()) {
      stale.deleteSync();
    }
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    unawaited(_chmodSocket(socketPath));
    server.listen((Socket socket) {
      final StreamSubscription<String> subscription = utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen((String line) async {
            socket.writeln(await handleJsonLine(line));
            await socket.flush();
          });
      unawaited(socket.done.whenComplete(subscription.cancel));
    });
    return server;
  }

  Future<Map<String, Object?>> _launch(AppId appId) async {
    final PlutodRunningApp? running = _running[appId.value];
    if (running != null) {
      await device.foregroundApp(appId);
      _foreground = appId.value;
      return <String, Object?>{'v': 1, 'ok': true, 'pid': running.pid};
    }
    final PlutodRegisteredApp? app = await registry.getApp(appId);
    if (app == null) {
      throw PlutodProtocolException(
        code: 'notInstalled',
        message: 'App is not installed: ${appId.value}.',
      );
    }
    final PlutoProcessHandle handle = await device.launchEmbedder(
      PlutoLaunchSpec(appId: app.id, appDir: app.appDir, dataDir: app.dataDir),
    );
    _running[appId.value] = PlutodRunningApp(appId: appId, pid: handle.pid);
    _foreground = appId.value;
    return <String, Object?>{'v': 1, 'ok': true, 'pid': handle.pid};
  }

  Future<Map<String, Object?>> _list() async {
    final List<PlutodRegisteredApp> apps = await registry.listApps();
    return <String, Object?>{
      'v': 1,
      'apps': <Map<String, Object?>>[
        for (final PlutodRegisteredApp app in apps)
          <String, Object?>{
            'id': app.id.value,
            'name': app.name,
            'version': app.version,
            'running': _running.containsKey(app.id.value),
          },
      ],
    };
  }

  Future<Map<String, Object?>> _foregroundApp(AppId appId) async {
    if (!_running.containsKey(appId.value)) {
      throw PlutodProtocolException(
        code: 'notRunning',
        message: 'App is not running: ${appId.value}.',
      );
    }
    await device.foregroundApp(appId);
    _foreground = appId.value;
    return _ok();
  }

  Future<Map<String, Object?>> _uninstall(
    AppId appId, {
    required bool purgeData,
  }) async {
    final PlutodAppUninstaller? localUninstaller = uninstaller;
    if (localUninstaller == null) {
      throw const PlutodProtocolException(
        code: 'uninstallUnavailable',
        message: 'No app uninstaller is configured.',
      );
    }
    final PlutodRunningApp? running = _running.remove(appId.value);
    if (running != null) {
      await device.terminateProcess(running.pid);
    }
    await localUninstaller.uninstall(appId, purgeData: purgeData);
    await registry.refresh();
    if (_foreground == appId.value) {
      _foreground = 'launcher';
    }
    return _ok();
  }

  Map<String, Object?> _status() => <String, Object?>{
    'v': 1,
    'ok': true,
    'backendMode': backendMode,
    'plutoVersion': plutoVersion,
    'foreground': _foreground,
    'running': <Map<String, Object?>>[
      for (final PlutodRunningApp app in runningApps)
        <String, Object?>{'appId': app.appId.value, 'pid': app.pid},
    ],
  };
}

/// Typed client for the plutod JSON wire protocol.
final class PlutodClient {
  /// Creates a client over [transport].
  const PlutodClient(this.transport);

  /// Creates a client that connects to a Unix-domain socket.
  factory PlutodClient.unixSocket(String socketPath) =>
      PlutodClient(UnixSocketPlutodTransport(socketPath));

  /// JSON request/response transport.
  final PlutodTransport transport;

  /// Launches [appId].
  Future<PlutodLaunchResult> launch(AppId appId) async {
    final Map<String, Object?> response = await transport.send(
      <String, Object?>{'v': 1, 'op': 'launch', 'appId': appId.value},
    );
    if (response['ok'] == true) {
      return PlutodLaunchSuccess(pid: _requiredInt(response, 'pid'));
    }
    return PlutodLaunchFailure(
      code: _stringOrDefault(response, 'code', 'error'),
      message: _stringOrDefault(response, 'error', 'Unknown launch failure.'),
    );
  }

  /// Lists installed apps.
  Future<List<PlutodListApp>> list() async {
    final Map<String, Object?> response = await transport.send(
      <String, Object?>{'v': 1, 'op': 'list'},
    );
    final Object? rawApps = response['apps'];
    if (rawApps is! List<Object?>) {
      throw const PlutodProtocolException(
        code: 'badResponse',
        message: 'list response missing apps.',
      );
    }
    return <PlutodListApp>[
      for (final Object? raw in rawApps) PlutodListApp.fromJson(_asObject(raw)),
    ];
  }

  /// Foregrounds [appId].
  Future<void> foreground(AppId appId) async {
    await _sendOk(<String, Object?>{
      'v': 1,
      'op': 'foreground',
      'appId': appId.value,
    });
  }

  /// Returns to the launcher home surface.
  Future<void> home() async {
    await _sendOk(<String, Object?>{'v': 1, 'op': 'home'});
  }

  /// Leaves Pluto for stock UI.
  Future<void> exitToStock() async {
    await _sendOk(<String, Object?>{'v': 1, 'op': 'exitToStock'});
  }

  /// Uninstalls [appId].
  Future<void> uninstall(AppId appId, {bool purgeData = false}) async {
    await _sendOk(<String, Object?>{
      'v': 1,
      'op': 'uninstall',
      'appId': appId.value,
      'purgeData': purgeData,
    });
  }

  /// Notifies plutod that the registry changed out of process.
  Future<void> registryChanged() async {
    await _sendOk(<String, Object?>{'v': 1, 'op': 'registryChanged'});
  }

  /// Reads daemon status.
  Future<PlutodStatus> status() async {
    final Map<String, Object?> response = await transport.send(
      <String, Object?>{'v': 1, 'op': 'status'},
    );
    _requireOk(response);
    return PlutodStatus.fromJson(response);
  }

  Future<void> _sendOk(Map<String, Object?> request) async {
    _requireOk(await transport.send(request));
  }
}

/// JSON request/response transport used by [PlutodClient].
abstract interface class PlutodTransport {
  /// Sends one request and returns one response.
  Future<Map<String, Object?>> send(Map<String, Object?> request);
}

/// Unix-domain socket transport for out-of-process callers.
final class UnixSocketPlutodTransport implements PlutodTransport {
  /// Creates a socket transport.
  const UnixSocketPlutodTransport(this.socketPath);

  /// Socket path.
  final String socketPath;

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) async {
    final Socket socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    socket.writeln(jsonEncode(request));
    await socket.flush();
    final String line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first;
    await socket.close();
    return _asObject(jsonDecode(line));
  }
}

/// In-memory client transport for tests.
final class DirectPlutodTransport implements PlutodTransport {
  /// Creates a direct transport.
  const DirectPlutodTransport(this.server);

  /// Server called directly.
  final PlutodServer server;

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) async {
    final String line = await server.handleJsonLine(jsonEncode(request));
    return _asObject(jsonDecode(line));
  }
}

/// Result of `launch`.
sealed class PlutodLaunchResult {
  const PlutodLaunchResult();

  /// Whether launch succeeded.
  bool get ok;
}

/// Successful launch.
final class PlutodLaunchSuccess extends PlutodLaunchResult {
  /// Creates a launch success.
  const PlutodLaunchSuccess({required this.pid});

  /// Process id.
  final int pid;

  @override
  bool get ok => true;
}

/// Failed launch.
final class PlutodLaunchFailure extends PlutodLaunchResult {
  /// Creates a launch failure.
  const PlutodLaunchFailure({required this.code, required this.message});

  /// Error code.
  final String code;

  /// Human-readable error.
  final String message;

  @override
  bool get ok => false;
}

/// App item returned by `list`.
final class PlutodListApp {
  /// Creates a list item.
  const PlutodListApp({
    required this.id,
    required this.name,
    required this.version,
    required this.running,
  });

  /// Decodes from protocol JSON.
  factory PlutodListApp.fromJson(Map<String, Object?> json) => PlutodListApp(
    id: _parseAppId(_requiredString(json, 'id')),
    name: _requiredString(json, 'name'),
    version: _requiredString(json, 'version'),
    running: json['running'] == true,
  );

  /// App id.
  final AppId id;

  /// Display name.
  final String name;

  /// Version.
  final String version;

  /// Whether an embedder process is running.
  final bool running;
}

/// Status response.
final class PlutodStatus {
  /// Creates a status value.
  const PlutodStatus({
    required this.backendMode,
    required this.plutoVersion,
    required this.foreground,
    required this.running,
  });

  /// Decodes from protocol JSON.
  factory PlutodStatus.fromJson(Map<String, Object?> json) {
    final Object? rawRunning = json['running'];
    if (rawRunning is! List<Object?>) {
      throw const PlutodProtocolException(
        code: 'badResponse',
        message: 'status response missing running list.',
      );
    }
    return PlutodStatus(
      backendMode: _requiredString(json, 'backendMode'),
      plutoVersion: _requiredString(json, 'plutoVersion'),
      foreground: _requiredString(json, 'foreground'),
      running: <PlutodRunningApp>[
        for (final Object? raw in rawRunning) _runningFromJson(_asObject(raw)),
      ],
    );
  }

  /// Backend mode.
  final String backendMode;

  /// Pluto version.
  final String plutoVersion;

  /// Foreground owner.
  final String foreground;

  /// Running apps.
  final List<PlutodRunningApp> running;
}

/// Protocol error.
final class PlutodProtocolException implements Exception {
  /// Creates a protocol error.
  const PlutodProtocolException({required this.code, required this.message});

  /// Stable error code.
  final String code;

  /// Human-readable error.
  final String message;

  @override
  String toString() => 'PlutodProtocolException($code): $message';
}

/// Fake device implementation for state-machine tests.
final class FakePlutodDevice implements PlutodDevice {
  /// Creates a fake device.
  FakePlutodDevice({this.nextPid = 1000});

  /// Next pid allocated by [launchEmbedder].
  int nextPid;

  /// Recorded operation log.
  final List<String> calls = <String>[];

  @override
  Future<void> exitToStock() async {
    calls.add('exitToStock');
  }

  @override
  Future<void> foregroundApp(AppId id) async {
    calls.add('foreground:${id.value}');
  }

  @override
  Future<PlutoProcessHandle> launchEmbedder(PlutoLaunchSpec spec) async {
    final int pid = nextPid++;
    calls.add('launch:${spec.appId.value}:$pid');
    return PlutoProcessHandle(pid: pid);
  }

  @override
  Future<void> runFullUninstall() async {
    calls.add('runFullUninstall');
  }

  @override
  Future<void> showLauncher() async {
    calls.add('home');
  }

  @override
  Future<void> terminateProcess(int pid) async {
    calls.add('terminate:$pid');
  }
}

Map<String, Object?> _ok() => <String, Object?>{'v': 1, 'ok': true};

String _encodeError(String code, String message) => jsonEncode(
  <String, Object?>{'v': 1, 'ok': false, 'code': code, 'error': message},
);

int _compareRunning(PlutodRunningApp a, PlutodRunningApp b) =>
    a.appId.value.compareTo(b.appId.value);

PlutodRunningApp _runningFromJson(Map<String, Object?> json) =>
    PlutodRunningApp(
      appId: _parseAppId(_requiredString(json, 'appId')),
      pid: _requiredInt(json, 'pid'),
    );

AppId _requiredAppId(Map<String, Object?> request) =>
    _parseAppId(_requiredString(request, 'appId'));

AppId _parseAppId(String text) {
  final AppId? id = AppId.tryParse(text);
  if (id == null) {
    throw PlutodProtocolException(
      code: 'badAppId',
      message: 'Invalid app id: $text.',
    );
  }
  return id;
}

String _requiredString(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw PlutodProtocolException(
    code: 'badRequest',
    message: '$key must be a string.',
  );
}

int _requiredInt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw PlutodProtocolException(
    code: 'badResponse',
    message: '$key must be an integer.',
  );
}

int? _optionalInt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw PlutodProtocolException(
    code: 'badRequest',
    message: '$key must be an integer.',
  );
}

Map<String, Object?> _asObject(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw const PlutodProtocolException(
          code: 'badJson',
          message: 'Object keys must be strings.',
        );
      }
      result[key] = entry.value;
    }
    return result;
  }
  throw const PlutodProtocolException(
    code: 'badJson',
    message: 'Expected a JSON object.',
  );
}

String _stringOrDefault(
  Map<String, Object?> map,
  String key,
  String defaultValue,
) {
  final Object? value = map[key];
  return value is String ? value : defaultValue;
}

void _requireOk(Map<String, Object?> response) {
  if (response['ok'] == true) {
    return;
  }
  throw PlutodProtocolException(
    code: _stringOrDefault(response, 'code', 'error'),
    message: _stringOrDefault(response, 'error', 'Request failed.'),
  );
}

Future<void> _chmodSocket(String socketPath) async {
  try {
    await Process.run('chmod', <String>['700', socketPath]);
  } on Object {
    // Best effort only: binding still works under the process umask.
  }
}
