import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:flutter/services.dart';
import 'package:pluto_manifest/pluto_manifest.dart';

import 'models.dart';
import 'services.dart';

/// The launcher's own app id; it is hidden from its own gallery.
const String kLauncherAppId = 'dev.pluto.launcher';

/// Creates services backed by the embedder platform channels
/// (`pluto/session`, `pluto/settings`, `pluto/apps`, `pluto/device`).
///
/// All channels speak the standard method codec. Device identity is decoded
/// through `pluto_device` and fails closed if the native service is absent or
/// returns malformed data.
LauncherServices createRealServices() {
  return LauncherServices(
    manifests: ChannelManifestRepository(),
    session: ChannelSessionManager(),
    settings: PlutoLauncherSettings(),
    device: PlutoDeviceRepository(),
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
  Future<LaunchResult> launch(AppId id) async {
    try {
      final Object? reply = await _channel.invokeMethod<Object?>(
        'launch',
        <String, Object?>{'appId': id.value},
      );
      _expectOkSessionReply(reply, 'launch');
      // The embedder exits and the supervisor spawns the app; no pid yet.
      return const LaunchSuccess(pid: 0);
    } on FormatException catch (error) {
      return LaunchFailure(reason: error.message.toString());
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
    const String method = 'switcherInfo';
    final Map<String, Object?> map = _decodeSessionMap(
      await _channel.invokeMethod<Object?>(method),
      method,
    );
    final bool active = _sessionBool(map, 'active', method);
    _expectExactSessionKeys(
      map,
      active
          ? const <String>{'active', 'originAppId', 'apps'}
          : const <String>{'active'},
      method,
    );
    if (!active) {
      return null;
    }
    final AppId origin = _sessionAppId(map, 'originAppId', method);
    final List<AppSwitcherPreview> previews = <AppSwitcherPreview>[];
    final Object? rawApps = map['apps'];
    if (rawApps is! List<Object?>) {
      _invalidSessionResponse(method);
    }
    for (final Object? rawApp in rawApps) {
      final Map<String, Object?> app = _decodeSessionMap(rawApp, method);
      _expectExactSessionKeys(app, const <String>{
        'appId',
        'previewPath',
      }, method);
      final AppId id = _sessionAppId(app, 'appId', method);
      if (id == origin || id.value == kLauncherAppId) {
        continue;
      }
      Uint8List? bytes;
      double? aspectRatio;
      final String path = _sessionString(app, 'previewPath', method);
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
    return AppSwitcherRequest(originAppId: origin, previews: previews);
  }

  @override
  Future<void> forceStop(AppId id) async {
    _expectOkSessionReply(
      await _channel.invokeMethod<Object?>('forceStop', <String, Object?>{
        'appId': id.value,
      }),
      'forceStop',
    );
  }

  @override
  Future<StatusOverlayRequest?> pendingStatusOverlay() async {
    const String method = 'statusInfo';
    final Map<String, Object?> map = _decodeSessionMap(
      await _channel.invokeMethod<Object?>(method),
      method,
    );
    final bool active = _sessionBool(map, 'active', method);
    _expectExactSessionKeys(
      map,
      active
          ? const <String>{'active', 'originAppId', 'previewPath'}
          : const <String>{'active'},
      method,
    );
    if (!active) {
      return null;
    }
    final AppId origin = _sessionAppId(map, 'originAppId', method);
    Uint8List? bytes;
    double? aspectRatio;
    final String path = _sessionString(map, 'previewPath', method);
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
    const String method = 'powerMenuInfo';
    final Map<String, Object?> map = _decodeSessionMap(
      await _channel.invokeMethod<Object?>(method),
      method,
    );
    final bool active = _sessionBool(map, 'active', method);
    _expectExactSessionKeys(
      map,
      active
          ? const <String>{'active', 'originAppId'}
          : const <String>{'active'},
      method,
    );
    if (!active) {
      return null;
    }
    return PowerMenuRequest(
      originAppId: _sessionAppId(map, 'originAppId', method),
    );
  }

  @override
  Future<void> systemUiReady() async {
    _expectOkSessionReply(
      await _channel.invokeMethod<Object?>('systemUiReady'),
      'systemUiReady',
    );
  }

  @override
  Future<void> switchToStockUi() async {
    await _channel.invokeMethod<void>('exitToStock');
  }

  @override
  Future<void> powerOffDevice() async {
    _expectOkSessionReply(
      await _channel.invokeMethod<Object?>('powerOff'),
      'powerOff',
    );
  }

  @override
  Future<void> sleepNow() async {
    _expectOkSessionReply(
      await _channel.invokeMethod<Object?>('sleepNow'),
      'sleepNow',
    );
  }

  @override
  Future<void> handoffStandbyToSupervisor() async {
    _expectOkSessionReply(
      await _channel.invokeMethod<Object?>('suspendNow'),
      'suspendNow',
    );
  }

  @override
  Future<void> returnToLauncher() async {
    await _channel.invokeMethod<Object?>('home');
  }
}

Map<String, Object?> _decodeSessionMap(Object? value, String method) {
  if (value is! Map<Object?, Object?>) {
    _invalidSessionResponse(method);
  }
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      _invalidSessionResponse(method);
    }
    result[key] = entry.value;
  }
  return result;
}

void _expectExactSessionKeys(
  Map<String, Object?> map,
  Set<String> expected,
  String method,
) {
  if (map.length != expected.length || !map.keys.every(expected.contains)) {
    _invalidSessionResponse(method);
  }
}

String _sessionString(Map<String, Object?> map, String key, String method) {
  final Object? value = map[key];
  if (value is! String) {
    _invalidSessionResponse(method);
  }
  return value;
}

bool _sessionBool(Map<String, Object?> map, String key, String method) {
  final Object? value = map[key];
  if (value is! bool) {
    _invalidSessionResponse(method);
  }
  return value;
}

AppId _sessionAppId(Map<String, Object?> map, String key, String method) {
  final AppId? id = AppId.tryParse(_sessionString(map, key, method));
  if (id == null) {
    _invalidSessionResponse(method);
  }
  return id;
}

void _expectOkSessionReply(Object? value, String method) {
  final Map<String, Object?> map = _decodeSessionMap(value, method);
  _expectExactSessionKeys(map, const <String>{'ok'}, method);
  if (map['ok'] != true) {
    _invalidSessionResponse(method);
  }
}

Never _invalidSessionResponse(String method) {
  throw FormatException('Invalid pluto/session $method response.');
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
      final Result<InstallRecord, ManifestError> result = InstallRecord.decode(
        installJson,
      );
      record = result.valueOrNull;
      if (record == null) {
        error ??=
            result.errorOrNull?.message ?? 'install.json failed validation';
      } else if (record.appId != manifest.id) {
        error ??= 'install.json appId does not match manifest.json';
        record = null;
      }
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
    final Result<AppManifest, ManifestError> result =
        AppManifest.decodeAuthoredYaml(
          jsonEncode(<String, Object?>{
            'id': id,
            'name': name.isEmpty
                ? id
                : '${name[0].toUpperCase()}${name.substring(1)}',
            'version': '0.0.0',
          }),
          runtime: const FlutterAotRuntime(),
          engine: const EngineRequirement(
            flutterVersion: kFlutterVersionPin,
            engineCommit: kEngineCommitPin,
          ),
        );
    return result.valueOrNull;
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

bool _boolOr(Map<String, Object?> map, String key, bool fallback) {
  final Object? value = map[key];
  return value is bool ? value : fallback;
}
