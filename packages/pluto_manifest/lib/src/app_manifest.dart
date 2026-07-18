import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

final RegExp _appIdPattern = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$');
final RegExp _engineCommitPattern = RegExp(r'^[0-9a-f]{40}$');
final RegExp _relativePathPattern = RegExp(r'^(?!/)(?!.*\.\.).+$');

/// A validated reverse-DNS Pluto app id.
extension type const AppId._(String _value) {
  /// Validates [input] and returns an [AppId] when it is canonical.
  static AppId? tryParse(String input) {
    if (input.length > 100 || !_appIdPattern.hasMatch(input)) {
      return null;
    }
    if (input.startsWith('app.pluto.')) {
      return null;
    }
    return AppId._(input);
  }

  /// The validated id string.
  String get value => _value;
}

/// A JSON/YAML parse result without exceptions in the public API.
sealed class Result<T, E> {
  const Result();

  /// Whether this result contains a value.
  bool get isOk;

  /// The parsed value, or null when this is an error.
  T? get valueOrNull;

  /// The parse error, or null when this is a value.
  E? get errorOrNull;
}

/// Successful [Result].
final class ResultOk<T, E> extends Result<T, E> {
  /// Creates a successful result containing [value].
  const ResultOk(this.value);

  /// The parsed value.
  final T value;

  @override
  bool get isOk => true;

  @override
  T get valueOrNull => value;

  @override
  E? get errorOrNull => null;
}

/// Failed [Result].
final class ResultErr<T, E> extends Result<T, E> {
  /// Creates a failed result containing [error].
  const ResultErr(this.error);

  /// The parse error.
  final E error;

  @override
  bool get isOk => false;

  @override
  T? get valueOrNull => null;

  @override
  E get errorOrNull => error;
}

/// Why a manifest was rejected.
sealed class ManifestError {
  const ManifestError();

  /// Human-readable rejection reason.
  String get message;
}

/// The manifest was not valid JSON or YAML.
final class ManifestSyntaxError extends ManifestError {
  /// Creates a syntax error.
  const ManifestSyntaxError(this.sourceMessage, {this.offset});

  /// Parser-provided message.
  final String sourceMessage;

  /// Byte or character offset, when the parser reports one.
  final int? offset;

  @override
  String get message {
    final int? localOffset = offset;
    if (localOffset == null) {
      return sourceMessage;
    }
    return '$sourceMessage at offset $localOffset';
  }
}

/// A manifest field failed validation.
final class ManifestFieldError extends ManifestError {
  /// Creates a field validation error at [path].
  const ManifestFieldError({required this.path, required this.reason});

  /// JSON path of the invalid field.
  final String path;

  /// Field-specific validation reason.
  final String reason;

  @override
  String get message => '$path: $reason';
}

/// The manifest used an unknown permission string.
final class ManifestUnknownPermission extends ManifestError {
  /// Creates an unknown-permission error.
  const ManifestUnknownPermission(this.permission);

  /// Unknown wire permission.
  final String permission;

  @override
  String get message => 'Unknown Pluto permission: $permission';
}

/// Closed permission registry.
enum AppPermission {
  /// Full-precision pen side channel.
  penRaw('pen.raw'),

  /// Raw multitouch side channel.
  touchRaw('touch.raw'),

  /// Display refresh-control hints.
  displayRefreshControl('display.refreshControl'),

  /// Device information reads.
  deviceInfo('device.info'),

  /// System settings reads.
  settingsRead('settings.read'),

  /// System settings writes.
  settingsWrite('settings.write'),

  /// Network disclosure permission.
  network('network'),

  /// Shared storage path helper permission.
  storageShared('storage.shared'),

  /// External process execution disclosure permission.
  systemShell('system.shell');

  const AppPermission(this.wireName);

  /// Manifest wire string.
  final String wireName;

  /// Returns the permission for [name], or null when unknown.
  static AppPermission? fromWireName(String name) {
    for (final AppPermission permission in AppPermission.values) {
      if (permission.wireName == name) {
        return permission;
      }
    }
    return null;
  }
}

/// Supported Flutter runtime kinds.
enum AppRuntimeKind {
  /// Release/profile AOT ELF runtime.
  flutterAot('flutter-aot'),

  /// Debug/profile kernel runtime.
  flutterKernel('flutter-kernel');

  const AppRuntimeKind(this.wireName);

  /// Manifest wire string.
  final String wireName;

  /// Parses the canonical runtime spelling.
  static AppRuntimeKind? fromWireName(String name) {
    for (final AppRuntimeKind kind in AppRuntimeKind.values) {
      if (kind.wireName == name) {
        return kind;
      }
    }
    return null;
  }
}

/// Device build targets an application can run on.
enum AppTargetPlatform {
  /// ARMv7 EABI5 hard-float used by reMarkable 1 and 2.
  linuxArm('linux-arm'),

  /// AArch64 used by Paper Pro Move.
  linuxArm64('linux-arm64');

  const AppTargetPlatform(this.wireName);

  /// Canonical manifest spelling.
  final String wireName;

  /// Parses the canonical manifest spelling.
  static AppTargetPlatform? fromWireName(String name) {
    for (final AppTargetPlatform target in values) {
      if (target.wireName == name) {
        return target;
      }
    }
    return null;
  }
}

/// Runtime layout for launching a Pluto app.
sealed class AppRuntime {
  const AppRuntime({required this.assets});

  /// Flutter asset-bundle directory.
  final String assets;

  /// Runtime kind.
  AppRuntimeKind get kind;

  Map<String, Object?> _toJson();
}

/// AOT runtime using `lib/app.so`.
final class FlutterAotRuntime extends AppRuntime {
  /// Creates an AOT runtime.
  const FlutterAotRuntime({
    this.appElf = 'lib/app.so',
    super.assets = 'flutter_assets',
  });

  /// Relative path to the AOT ELF.
  final String appElf;

  @override
  AppRuntimeKind get kind => AppRuntimeKind.flutterAot;

  @override
  Map<String, Object?> _toJson() => <String, Object?>{
    'type': kind.wireName,
    'appElf': appElf,
    'assets': assets,
  };
}

/// Kernel runtime using a debug asset bundle.
final class FlutterKernelRuntime extends AppRuntime {
  /// Creates a kernel runtime.
  const FlutterKernelRuntime({super.assets = 'flutter_assets'});

  @override
  AppRuntimeKind get kind => AppRuntimeKind.flutterKernel;

  @override
  Map<String, Object?> _toJson() => <String, Object?>{
    'type': kind.wireName,
    'assets': assets,
  };
}

/// Required Flutter engine identity for an app.
final class EngineRequirement {
  /// Creates an engine requirement.
  const EngineRequirement({
    required this.flutterVersion,
    required this.engineCommit,
  });

  /// Flutter SDK version used to build the app.
  final String flutterVersion;

  /// Engine commit hash required by the app snapshot.
  final String engineCommit;

  Map<String, Object?> _toJson() => <String, Object?>{
    'flutterVersion': flutterVersion,
    'engineCommit': engineCommit,
  };
}

/// Allowed device orientation values in a manifest.
enum ManifestOrientation {
  /// Portrait orientation.
  portrait('portrait'),

  /// Upside-down portrait orientation.
  portraitDown('portraitDown'),

  /// Landscape with the left edge up.
  landscapeLeft('landscapeLeft'),

  /// Landscape with the right edge up.
  landscapeRight('landscapeRight');

  const ManifestOrientation(this.wireName);

  /// Manifest wire string.
  final String wireName;

  static ManifestOrientation? _fromWireName(String name) {
    for (final ManifestOrientation orientation in ManifestOrientation.values) {
      if (orientation.wireName == name) {
        return orientation;
      }
    }
    return null;
  }
}

/// Display color policy.
enum DisplayColorMode {
  /// Use color on color-capable panels.
  auto('auto'),

  /// Force monochrome updates.
  mono('mono');

  const DisplayColorMode(this.wireName);

  /// Manifest wire string.
  final String wireName;

  static DisplayColorMode? _fromWireName(String name) {
    for (final DisplayColorMode mode in DisplayColorMode.values) {
      if (mode.wireName == name) {
        return mode;
      }
    }
    return null;
  }
}

/// Initial display refresh profile.
enum DisplayRefreshProfile {
  /// General interface profile.
  ui('ui'),

  /// Reading-focused profile.
  reading('reading'),

  /// Drawing-focused profile.
  drawing('drawing');

  const DisplayRefreshProfile(this.wireName);

  /// Manifest wire string.
  final String wireName;

  static DisplayRefreshProfile? _fromWireName(String name) {
    for (final DisplayRefreshProfile profile in DisplayRefreshProfile.values) {
      if (profile.wireName == name) {
        return profile;
      }
    }
    return null;
  }
}

/// Display preferences from `manifest.json`.
final class DisplayPrefs {
  /// Creates display preferences.
  const DisplayPrefs({
    this.orientations = const <ManifestOrientation>[
      ManifestOrientation.portrait,
    ],
    this.defaultOrientation = ManifestOrientation.portrait,
    this.color = DisplayColorMode.auto,
    this.refreshProfile = DisplayRefreshProfile.ui,
  });

  /// Allowed orientations.
  final List<ManifestOrientation> orientations;

  /// Orientation applied at app start.
  final ManifestOrientation defaultOrientation;

  /// Color policy.
  final DisplayColorMode color;

  /// Initial refresh profile.
  final DisplayRefreshProfile refreshProfile;

  Map<String, Object?> _toJson() => <String, Object?>{
    'orientations': <String>[
      for (final ManifestOrientation orientation in orientations)
        orientation.wireName,
    ],
    'defaultOrientation': defaultOrientation.wireName,
    'scale': 'auto',
    'color': color.wireName,
    'refreshProfile': refreshProfile.wireName,
  };
}

/// Launch preferences from `manifest.json`.
final class LaunchPrefs {
  /// Creates launch preferences.
  const LaunchPrefs({this.singleInstance = true, this.args = const <String>[]});

  /// Whether the launcher should focus an existing instance.
  final bool singleInstance;

  /// Extra entrypoint arguments passed to the app.
  final List<String> args;

  Map<String, Object?> _toJson() => <String, Object?>{
    'singleInstance': singleInstance,
    'args': args,
  };
}

/// Immutable, validated app manifest.
final class AppManifest {
  /// Creates an app manifest value.
  const AppManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.runtime,
    required this.engine,
    this.description,
    this.author,
    this.icon = 'icon.png',
    this.iconMono,
    this.targets = const <AppTargetPlatform>{
      AppTargetPlatform.linuxArm,
      AppTargetPlatform.linuxArm64,
    },
    this.permissions = const <AppPermission>{},
    this.display = const DisplayPrefs(),
    this.launch = const LaunchPrefs(),
  });

  /// Parses and validates canonical JSON.
  static Result<AppManifest, ManifestError> decode(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      return _decodePlainObject(decoded);
    } on FormatException catch (error) {
      return ResultErr<AppManifest, ManifestError>(
        ManifestSyntaxError(error.message, offset: error.offset),
      );
    }
  }

  /// Parses and validates a canonical installed YAML manifest.
  static Result<AppManifest, ManifestError> decodeYaml(String yaml) {
    try {
      final Object? decoded = _yamlToPlain(loadYaml(yaml));
      return _decodePlainObject(decoded);
    } on YamlException catch (error) {
      return ResultErr<AppManifest, ManifestError>(
        ManifestSyntaxError(error.message),
      );
    } on ManifestError catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    }
  }

  /// Parses authored YAML after [runtime] and [engine] have been stamped.
  static Result<AppManifest, ManifestError> decodeAuthoredYaml(
    String yaml, {
    required AppRuntime runtime,
    required EngineRequirement engine,
  }) {
    try {
      final Object? decoded = _yamlToPlain(loadYaml(yaml));
      if (decoded is! Map<String, Object?>) {
        return const ResultErr<AppManifest, ManifestError>(
          ManifestFieldError(path: r'$', reason: 'expected a map'),
        );
      }
      _validateObjectShape(
        decoded,
        required: const <String>{'id', 'name', 'version'},
        optional: const <String>{
          'description',
          'author',
          'icon',
          'iconMono',
          'targets',
          'permissions',
          'display',
          'launch',
        },
        path: r'$',
      );
      final Map<String, Object?> stamped = <String, Object?>{
        ...decoded,
        'runtime': runtime._toJson(),
        'engine': engine._toJson(),
      };
      return _decodePlainObject(stamped, canonical: false);
    } on YamlException catch (error) {
      return ResultErr<AppManifest, ManifestError>(
        ManifestSyntaxError(error.message),
      );
    } on ManifestError catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    }
  }

  static Result<AppManifest, ManifestError> _decodePlainObject(
    Object? decoded, {
    bool canonical = true,
  }) {
    if (decoded is! Map<String, Object?>) {
      return const ResultErr<AppManifest, ManifestError>(
        ManifestFieldError(path: r'$', reason: 'expected an object'),
      );
    }
    try {
      return ResultOk<AppManifest, ManifestError>(
        _parse(decoded, canonical: canonical),
      );
    } on ManifestError catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    }
  }

  static AppManifest _parse(
    Map<String, Object?> root, {
    required bool canonical,
  }) {
    _validateObjectShape(
      root,
      required: canonical
          ? const <String>{
              'id',
              'name',
              'version',
              'icon',
              'targets',
              'runtime',
              'engine',
              'permissions',
              'display',
              'launch',
            }
          : const <String>{'id', 'name', 'version', 'runtime', 'engine'},
      optional: canonical
          ? const <String>{'description', 'author', 'iconMono'}
          : const <String>{
              'description',
              'author',
              'icon',
              'iconMono',
              'targets',
              'permissions',
              'display',
              'launch',
            },
      path: r'$',
    );

    final String rawId = _required<String>(root, 'id', 'id');
    final AppId? id = AppId.tryParse(rawId);
    if (id == null) {
      throw const ManifestFieldError(
        path: 'id',
        reason: 'must be a reverse-DNS app id up to 100 chars',
      );
    }

    final String name = _required<String>(root, 'name', 'name');
    if (name.isEmpty || name.length > 40) {
      throw const ManifestFieldError(
        path: 'name',
        reason: 'must be 1-40 chars',
      );
    }

    final String versionText = _required<String>(root, 'version', 'version');
    final Version version;
    try {
      version = Version.parse(versionText);
    } on FormatException {
      throw const ManifestFieldError(path: 'version', reason: 'must be semver');
    }

    final String? description = _optional<String>(
      root,
      'description',
      'description',
    );
    if (description != null && description.length > 200) {
      throw const ManifestFieldError(
        path: 'description',
        reason: 'must be at most 200 chars',
      );
    }

    final String icon = canonical
        ? _required<String>(root, 'icon', 'icon')
        : _optional<String>(root, 'icon', 'icon') ?? 'icon.png';
    _validateRelativePath(icon, 'icon');
    final String? iconMono = _optional<String>(root, 'iconMono', 'iconMono');
    if (iconMono != null) {
      _validateRelativePath(iconMono, 'iconMono');
    }

    return AppManifest(
      id: id,
      name: name,
      version: version,
      description: description,
      author: _optional<String>(root, 'author', 'author'),
      icon: icon,
      iconMono: iconMono,
      targets: _parseTargets(root, canonical: canonical),
      runtime: _parseRuntime(_requiredMap(root, 'runtime', 'runtime')),
      engine: _parseEngine(_requiredMap(root, 'engine', 'engine')),
      permissions: _parsePermissions(root, canonical: canonical),
      display: _parseDisplay(
        canonical
            ? _requiredMap(root, 'display', 'display')
            : _optionalMap(root, 'display', 'display'),
        canonical: canonical,
      ),
      launch: _parseLaunch(
        canonical
            ? _requiredMap(root, 'launch', 'launch')
            : _optionalMap(root, 'launch', 'launch'),
        canonical: canonical,
      ),
    );
  }

  /// Reverse-DNS application id.
  final AppId id;

  /// Launcher display name.
  final String name;

  /// Application semver.
  final Version version;

  /// Optional launcher app-info description.
  final String? description;

  /// Optional author attribution.
  final String? author;

  /// Relative icon path.
  final String icon;

  /// Optional relative monochrome icon path.
  final String? iconMono;

  /// Exact device targets supported by this application.
  final Set<AppTargetPlatform> targets;

  /// Runtime launch layout.
  final AppRuntime runtime;

  /// Required Flutter engine identity.
  final EngineRequirement engine;

  /// Declared capability permissions.
  final Set<AppPermission> permissions;

  /// Display preferences.
  final DisplayPrefs display;

  /// Launch preferences.
  final LaunchPrefs launch;

  /// Canonical JSON encoding with stable key order.
  String encode() => jsonEncode(_toJson());

  /// YAML-compatible encoding; JSON is a valid YAML subset.
  String encodeYaml() => encode();

  Map<String, Object?> _toJson() {
    final Map<String, Object?> result = <String, Object?>{
      'id': id.value,
      'name': name,
      'version': version.toString(),
    };
    if (description != null) {
      result['description'] = description;
    }
    if (author != null) {
      result['author'] = author;
    }
    result['icon'] = icon;
    if (iconMono != null) {
      result['iconMono'] = iconMono;
    }
    result['targets'] = <String>[
      for (final AppTargetPlatform target in AppTargetPlatform.values)
        if (targets.contains(target)) target.wireName,
    ];
    result['runtime'] = runtime._toJson();
    result['engine'] = engine._toJson();
    result['permissions'] = <String>[
      for (final AppPermission permission in AppPermission.values)
        if (permissions.contains(permission)) permission.wireName,
    ];
    result['display'] = display._toJson();
    result['launch'] = launch._toJson();
    return result;
  }
}

/// Build mode recorded in `install.json`.
enum BuildMode {
  /// Debug/JIT build.
  debug('debug'),

  /// Profile build.
  profile('profile'),

  /// Release build.
  release('release');

  const BuildMode(this.wireName);

  /// Install-record wire string.
  final String wireName;

  static BuildMode _fromWireName(String name) {
    for (final BuildMode mode in BuildMode.values) {
      if (mode.wireName == name) {
        return mode;
      }
    }
    throw ManifestFieldError(path: 'buildMode', reason: 'unknown build mode');
  }
}

/// Immutable install record parsed from `install.json`.
final class InstallRecord {
  /// Creates an install record.
  const InstallRecord({
    required this.appId,
    required this.installedAt,
    required this.installedBy,
    required this.source,
    required this.buildMode,
    required this.engineFlavor,
    required this.sizeBytes,
    required this.payload,
  });

  /// Parses and validates an install record JSON string.
  static Result<InstallRecord, ManifestError> decode(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) {
        return const ResultErr<InstallRecord, ManifestError>(
          ManifestFieldError(path: r'$', reason: 'expected an object'),
        );
      }
      return ResultOk<InstallRecord, ManifestError>(_parse(decoded));
    } on FormatException catch (error) {
      return ResultErr<InstallRecord, ManifestError>(
        ManifestSyntaxError(error.message, offset: error.offset),
      );
    } on ManifestError catch (error) {
      return ResultErr<InstallRecord, ManifestError>(error);
    }
  }

  static InstallRecord _parse(Map<String, Object?> root) {
    _validateObjectShape(
      root,
      required: const <String>{
        'appId',
        'installedAt',
        'installedBy',
        'source',
        'buildMode',
        'engineFlavor',
        'sizeBytes',
        'payload',
      },
      optional: const <String>{},
      path: r'$',
    );
    final String rawAppId = _required<String>(root, 'appId', 'appId');
    final AppId? appId = AppId.tryParse(rawAppId);
    if (appId == null) {
      throw const ManifestFieldError(
        path: 'appId',
        reason: 'must be a reverse-DNS app id up to 100 chars',
      );
    }
    final String installedAtText = _required<String>(
      root,
      'installedAt',
      'installedAt',
    );
    final DateTime installedAt;
    try {
      installedAt = DateTime.parse(installedAtText);
    } on FormatException {
      throw const ManifestFieldError(
        path: 'installedAt',
        reason: 'must be an ISO-8601 timestamp',
      );
    }
    final Map<String, Object?> payloadMap = _requiredMap(
      root,
      'payload',
      'payload',
    );
    final Map<String, String> payload = <String, String>{};
    for (final MapEntry<String, Object?> entry in payloadMap.entries) {
      final Object? value = entry.value;
      if (value is! String) {
        throw ManifestFieldError(
          path: 'payload.${entry.key}',
          reason: 'must be a string hash',
        );
      }
      payload[entry.key] = value;
    }
    final int sizeBytes = _required<int>(root, 'sizeBytes', 'sizeBytes');
    if (sizeBytes < 0) {
      throw const ManifestFieldError(
        path: 'sizeBytes',
        reason: 'must not be negative',
      );
    }
    return InstallRecord(
      appId: appId,
      installedAt: installedAt,
      installedBy: _required<String>(root, 'installedBy', 'installedBy'),
      source: _required<String>(root, 'source', 'source'),
      buildMode: BuildMode._fromWireName(
        _required<String>(root, 'buildMode', 'buildMode'),
      ),
      engineFlavor: _required<String>(root, 'engineFlavor', 'engineFlavor'),
      sizeBytes: sizeBytes,
      payload: Map<String, String>.unmodifiable(payload),
    );
  }

  /// Application identity bound to this receipt.
  final AppId appId;

  /// UTC install time.
  final DateTime installedAt;

  /// Tool that wrote the record.
  final String installedBy;

  /// Installation source.
  final String source;

  /// Build mode installed.
  final BuildMode buildMode;

  /// Engine flavor installed.
  final String engineFlavor;

  /// Payload size in bytes.
  final int sizeBytes;

  /// Payload hashes by relative path.
  final Map<String, String> payload;
}

/// An app as discovered on device.
final class InstalledApp {
  /// Creates a discovered app value.
  const InstalledApp({
    required this.manifest,
    required this.record,
    required this.appDir,
    required this.dataDir,
  });

  /// Parsed app manifest.
  final AppManifest manifest;

  /// Parsed install record.
  final InstallRecord record;

  /// Absolute app payload directory.
  final String appDir;

  /// Absolute writable app-data directory.
  final String dataDir;

  /// Whether the app was installed by a debug run.
  bool get isDevInstall => record.buildMode == BuildMode.debug;
}

AppRuntime _parseRuntime(Map<String, Object?> map) {
  final String rawType = _required<String>(map, 'type', 'runtime.type');
  final AppRuntimeKind? kind = AppRuntimeKind.fromWireName(rawType);
  if (kind == null) {
    throw const ManifestFieldError(
      path: 'runtime.type',
      reason: 'unknown runtime type',
    );
  }
  switch (kind) {
    case AppRuntimeKind.flutterAot:
      _validateObjectShape(
        map,
        required: const <String>{'type', 'appElf', 'assets'},
        optional: const <String>{},
        path: 'runtime',
      );
      final String assets = _required<String>(map, 'assets', 'runtime.assets');
      _validateRelativePath(assets, 'runtime.assets');
      final String appElf = _required<String>(map, 'appElf', 'runtime.appElf');
      _validateRelativePath(appElf, 'runtime.appElf');
      return FlutterAotRuntime(appElf: appElf, assets: assets);
    case AppRuntimeKind.flutterKernel:
      _validateObjectShape(
        map,
        required: const <String>{'type', 'assets'},
        optional: const <String>{},
        path: 'runtime',
      );
      final String assets = _required<String>(map, 'assets', 'runtime.assets');
      _validateRelativePath(assets, 'runtime.assets');
      return FlutterKernelRuntime(assets: assets);
  }
}

EngineRequirement _parseEngine(Map<String, Object?> map) {
  _validateObjectShape(
    map,
    required: const <String>{'flutterVersion', 'engineCommit'},
    optional: const <String>{},
    path: 'engine',
  );
  final String commit = _required<String>(
    map,
    'engineCommit',
    'engine.engineCommit',
  );
  if (!_engineCommitPattern.hasMatch(commit)) {
    throw const ManifestFieldError(
      path: 'engine.engineCommit',
      reason: 'must be a 40-character lowercase hex hash',
    );
  }
  return EngineRequirement(
    flutterVersion: _required<String>(
      map,
      'flutterVersion',
      'engine.flutterVersion',
    ),
    engineCommit: commit,
  );
}

Set<AppTargetPlatform> _parseTargets(
  Map<String, Object?> root, {
  required bool canonical,
}) {
  if (canonical && !root.containsKey('targets')) {
    throw const ManifestFieldError(path: 'targets', reason: 'is required');
  }
  final Object? raw = root['targets'];
  if (raw == null) {
    if (root.containsKey('targets')) {
      throw const ManifestFieldError(path: 'targets', reason: 'must be a list');
    }
    return const <AppTargetPlatform>{
      AppTargetPlatform.linuxArm,
      AppTargetPlatform.linuxArm64,
    };
  }
  if (raw is! List<Object?> || raw.isEmpty) {
    throw const ManifestFieldError(
      path: 'targets',
      reason: 'must be a non-empty list',
    );
  }
  final Set<AppTargetPlatform> result = <AppTargetPlatform>{};
  for (var index = 0; index < raw.length; index++) {
    final Object? value = raw[index];
    if (value is! String) {
      throw ManifestFieldError(
        path: 'targets[$index]',
        reason: 'must be a string',
      );
    }
    final AppTargetPlatform? target = AppTargetPlatform.fromWireName(value);
    if (target == null) {
      throw ManifestFieldError(
        path: 'targets[$index]',
        reason: 'unknown device target',
      );
    }
    if (!result.add(target)) {
      throw ManifestFieldError(
        path: 'targets[$index]',
        reason: 'duplicate device target',
      );
    }
  }
  return Set<AppTargetPlatform>.unmodifiable(result);
}

Set<AppPermission> _parsePermissions(
  Map<String, Object?> root, {
  required bool canonical,
}) {
  if (canonical && !root.containsKey('permissions')) {
    throw const ManifestFieldError(path: 'permissions', reason: 'is required');
  }
  final Object? raw = root['permissions'];
  if (raw == null) {
    if (root.containsKey('permissions')) {
      throw const ManifestFieldError(
        path: 'permissions',
        reason: 'must be a list',
      );
    }
    return const <AppPermission>{};
  }
  if (raw is! List<Object?>) {
    throw const ManifestFieldError(
      path: 'permissions',
      reason: 'must be a list',
    );
  }
  final Set<AppPermission> permissions = <AppPermission>{};
  for (var index = 0; index < raw.length; index++) {
    final Object? value = raw[index];
    if (value is! String) {
      throw ManifestFieldError(
        path: 'permissions[$index]',
        reason: 'must be a string',
      );
    }
    final AppPermission? permission = AppPermission.fromWireName(value);
    if (permission == null) {
      throw ManifestUnknownPermission(value);
    }
    permissions.add(permission);
  }
  return Set<AppPermission>.unmodifiable(permissions);
}

DisplayPrefs _parseDisplay(
  Map<String, Object?>? map, {
  required bool canonical,
}) {
  if (map == null) {
    return const DisplayPrefs();
  }
  _validateObjectShape(
    map,
    required: canonical
        ? const <String>{
            'orientations',
            'defaultOrientation',
            'scale',
            'color',
            'refreshProfile',
          }
        : const <String>{},
    optional: canonical
        ? const <String>{}
        : const <String>{
            'orientations',
            'defaultOrientation',
            'scale',
            'color',
            'refreshProfile',
          },
    path: 'display',
  );
  final List<ManifestOrientation> orientations = _parseOrientations(
    map['orientations'],
    canonical: canonical,
  );
  final String? defaultOrientationText = _optional<String>(
    map,
    'defaultOrientation',
    'display.defaultOrientation',
  );
  final ManifestOrientation defaultOrientation;
  if (defaultOrientationText == null) {
    defaultOrientation = ManifestOrientation.portrait;
  } else {
    defaultOrientation = _parseOrientation(
      defaultOrientationText,
      'display.defaultOrientation',
    );
  }
  if (!orientations.contains(defaultOrientation)) {
    throw const ManifestFieldError(
      path: 'display.defaultOrientation',
      reason: 'must be included in display.orientations',
    );
  }
  _validateDisplayScale(map);
  final String colorText =
      _optional<String>(map, 'color', 'display.color') ?? 'auto';
  final DisplayColorMode? color = DisplayColorMode._fromWireName(colorText);
  if (color == null) {
    throw const ManifestFieldError(
      path: 'display.color',
      reason: 'must be auto or mono',
    );
  }
  final String refreshText =
      _optional<String>(map, 'refreshProfile', 'display.refreshProfile') ??
      'ui';
  final DisplayRefreshProfile? refresh = DisplayRefreshProfile._fromWireName(
    refreshText,
  );
  if (refresh == null) {
    throw const ManifestFieldError(
      path: 'display.refreshProfile',
      reason: 'must be ui, reading, or drawing',
    );
  }
  return DisplayPrefs(
    orientations: List<ManifestOrientation>.unmodifiable(orientations),
    defaultOrientation: defaultOrientation,
    color: color,
    refreshProfile: refresh,
  );
}

List<ManifestOrientation> _parseOrientations(
  Object? raw, {
  required bool canonical,
}) {
  if (raw == null) {
    if (canonical) {
      throw const ManifestFieldError(
        path: 'display.orientations',
        reason: 'must be a list',
      );
    }
    return const <ManifestOrientation>[ManifestOrientation.portrait];
  }
  if (raw is! List<Object?>) {
    throw const ManifestFieldError(
      path: 'display.orientations',
      reason: 'must be a list',
    );
  }
  if (raw.isEmpty) {
    throw const ManifestFieldError(
      path: 'display.orientations',
      reason: 'must not be empty',
    );
  }
  final List<ManifestOrientation> result = <ManifestOrientation>[];
  for (var index = 0; index < raw.length; index++) {
    final Object? value = raw[index];
    if (value is! String) {
      throw ManifestFieldError(
        path: 'display.orientations[$index]',
        reason: 'must be a string',
      );
    }
    result.add(_parseOrientation(value, 'display.orientations[$index]'));
  }
  return result;
}

ManifestOrientation _parseOrientation(String value, String path) {
  final ManifestOrientation? orientation = ManifestOrientation._fromWireName(
    value,
  );
  if (orientation == null) {
    throw ManifestFieldError(path: path, reason: 'unknown orientation');
  }
  return orientation;
}

LaunchPrefs _parseLaunch(Map<String, Object?>? map, {required bool canonical}) {
  if (map == null) {
    return const LaunchPrefs();
  }
  _validateObjectShape(
    map,
    required: canonical
        ? const <String>{'singleInstance', 'args'}
        : const <String>{},
    optional: canonical
        ? const <String>{}
        : const <String>{'singleInstance', 'args'},
    path: 'launch',
  );
  final Object? argsRaw = map['args'];
  final List<String> args = <String>[];
  if (argsRaw == null && map.containsKey('args')) {
    throw const ManifestFieldError(
      path: 'launch.args',
      reason: 'must be a list',
    );
  }
  if (argsRaw != null) {
    if (argsRaw is! List<Object?>) {
      throw const ManifestFieldError(
        path: 'launch.args',
        reason: 'must be a list',
      );
    }
    for (var index = 0; index < argsRaw.length; index++) {
      final Object? value = argsRaw[index];
      if (value is! String) {
        throw ManifestFieldError(
          path: 'launch.args[$index]',
          reason: 'must be a string',
        );
      }
      args.add(value);
    }
  }
  return LaunchPrefs(
    singleInstance:
        _optional<bool>(map, 'singleInstance', 'launch.singleInstance') ?? true,
    args: List<String>.unmodifiable(args),
  );
}

void _validateRelativePath(String value, String path) {
  if (!_relativePathPattern.hasMatch(value)) {
    throw ManifestFieldError(path: path, reason: 'must be a relative path');
  }
}

T _required<T>(Map<String, Object?> map, String key, String path) {
  if (!map.containsKey(key)) {
    throw ManifestFieldError(path: path, reason: 'is required');
  }
  final Object? value = map[key];
  if (value is T) {
    return value;
  }
  throw ManifestFieldError(path: path, reason: 'has the wrong type');
}

T? _optional<T>(Map<String, Object?> map, String key, String path) {
  if (!map.containsKey(key)) {
    return null;
  }
  final Object? value = map[key];
  if (value is T) {
    return value;
  }
  throw ManifestFieldError(path: path, reason: 'has the wrong type');
}

void _validateObjectShape(
  Map<String, Object?> map, {
  required Set<String> required,
  required Set<String> optional,
  required String path,
}) {
  for (final String key in map.keys) {
    if (!required.contains(key) && !optional.contains(key)) {
      throw ManifestFieldError(
        path: path == r'$' ? key : '$path.$key',
        reason: 'is not supported',
      );
    }
  }
  for (final String key in required) {
    if (!map.containsKey(key)) {
      throw ManifestFieldError(
        path: path == r'$' ? key : '$path.$key',
        reason: 'is required',
      );
    }
  }
}

Map<String, Object?> _requiredMap(
  Map<String, Object?> map,
  String key,
  String path,
) {
  final Object? value = map[key];
  if (value is Map<String, Object?>) {
    return value;
  }
  throw ManifestFieldError(path: path, reason: 'must be an object');
}

Map<String, Object?>? _optionalMap(
  Map<String, Object?> map,
  String key,
  String path,
) {
  if (!map.containsKey(key)) {
    return null;
  }
  final Object? value = map[key];
  if (value is Map<String, Object?>) {
    return value;
  }
  throw ManifestFieldError(path: path, reason: 'must be an object');
}

void _validateDisplayScale(Map<String, Object?> map) {
  if (!map.containsKey('scale')) {
    return;
  }
  final Object? value = map['scale'];
  if (value == 'auto') {
    return;
  }
  throw const ManifestFieldError(
    path: 'display.scale',
    reason: 'must be auto when provided',
  );
}

Object? _yamlToPlain(Object? value) {
  if (value is YamlMap) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw const ManifestFieldError(
          path: r'$',
          reason: 'YAML keys must be strings',
        );
      }
      result[key] = _yamlToPlain(entry.value);
    }
    return result;
  }
  if (value is YamlList) {
    return <Object?>[for (final Object? item in value) _yamlToPlain(item)];
  }
  return value;
}
