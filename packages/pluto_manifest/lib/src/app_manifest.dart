import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

final RegExp _appIdPattern = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$');
final RegExp _engineCommitPattern = RegExp(r'^[0-9a-f]{40}$');
final RegExp _relativePathPattern = RegExp(r'^(?!/)(?!.*\.\.).+$');

/// A validated reverse-DNS Pluto app id.
extension type const AppId._(String _value) {
  /// Validates [input] and returns an [AppId] when it is schema-1 compatible.
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

/// The manifest schema is newer than this package understands.
final class ManifestSchemaTooNew extends ManifestError {
  /// Creates a schema-version error.
  const ManifestSchemaTooNew(this.schema);

  /// Requested schema version.
  final int schema;

  @override
  String get message =>
      'Manifest schema $schema is newer than supported schema 1.';
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

/// Closed schema-1 permission registry.
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

/// Required engine and Pluto ABI versions for an app.
final class EngineRequirement {
  /// Creates an engine requirement.
  const EngineRequirement({
    required this.flutterVersion,
    required this.engineCommit,
    required this.plutoAbi,
  });

  /// Flutter SDK version used to build the app.
  final String flutterVersion;

  /// Engine commit hash required by the app snapshot.
  final String engineCommit;

  /// Pluto platform ABI required by the app.
  final int plutoAbi;

  Map<String, Object?> _toJson() => <String, Object?>{
    'flutterVersion': flutterVersion,
    'engineCommit': engineCommit,
    'plutoAbi': plutoAbi,
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
    this.scale,
    this.color = DisplayColorMode.auto,
    this.refreshProfile = DisplayRefreshProfile.ui,
  });

  /// Allowed orientations.
  final List<ManifestOrientation> orientations;

  /// Orientation applied at app start.
  final ManifestOrientation defaultOrientation;

  /// Explicit device-pixel-ratio override, or null to use device metrics.
  final double? scale;

  /// Whether the runtime should use the connected device's native metrics.
  bool get usesAutomaticScale => scale == null;

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
    'scale': scale ?? 'auto',
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
    required this.schema,
    required this.id,
    required this.name,
    required this.version,
    required this.runtime,
    required this.engine,
    this.description,
    this.author,
    this.icon = 'icon.png',
    this.iconMono,
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

  /// Parses and validates YAML with the installed manifest schema.
  static Result<AppManifest, ManifestError> decodeYaml(String yaml) {
    try {
      final Object? decoded = _yamlToPlain(loadYaml(yaml));
      return _decodePlainObject(decoded);
    } on YamlException catch (error) {
      return ResultErr<AppManifest, ManifestError>(
        ManifestSyntaxError(error.message),
      );
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
      final Map<String, Object?> stamped = <String, Object?>{
        ...decoded,
        'runtime': runtime._toJson(),
        'engine': engine._toJson(),
      };
      return _decodePlainObject(stamped);
    } on YamlException catch (error) {
      return ResultErr<AppManifest, ManifestError>(
        ManifestSyntaxError(error.message),
      );
    }
  }

  static Result<AppManifest, ManifestError> _decodePlainObject(
    Object? decoded,
  ) {
    if (decoded is! Map<String, Object?>) {
      return const ResultErr<AppManifest, ManifestError>(
        ManifestFieldError(path: r'$', reason: 'expected an object'),
      );
    }
    try {
      return ResultOk<AppManifest, ManifestError>(_parse(decoded));
    } on ManifestSchemaTooNew catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    } on ManifestFieldError catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    } on ManifestUnknownPermission catch (error) {
      return ResultErr<AppManifest, ManifestError>(error);
    }
  }

  static AppManifest _parse(Map<String, Object?> root) {
    final int schema = _required<int>(root, 'schema', 'schema');
    if (schema > 1) {
      throw ManifestSchemaTooNew(schema);
    }
    if (schema < 1) {
      throw const ManifestFieldError(path: 'schema', reason: 'must be 1');
    }

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

    final String icon = _optional<String>(root, 'icon', 'icon') ?? 'icon.png';
    _validateRelativePath(icon, 'icon');
    final String? iconMono = _optional<String>(root, 'iconMono', 'iconMono');
    if (iconMono != null) {
      _validateRelativePath(iconMono, 'iconMono');
    }

    return AppManifest(
      schema: schema,
      id: id,
      name: name,
      version: version,
      description: description,
      author: _optional<String>(root, 'author', 'author'),
      icon: icon,
      iconMono: iconMono,
      runtime: _parseRuntime(_requiredMap(root, 'runtime', 'runtime')),
      engine: _parseEngine(_requiredMap(root, 'engine', 'engine')),
      permissions: _parsePermissions(root),
      display: _parseDisplay(_optionalMap(root, 'display', 'display')),
      launch: _parseLaunch(_optionalMap(root, 'launch', 'launch')),
    );
  }

  /// Manifest schema version.
  final int schema;

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

  /// Runtime launch layout.
  final AppRuntime runtime;

  /// Required engine and ABI versions.
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
      'schema': schema,
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
    required this.schema,
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
    final int schema = _required<int>(root, 'schema', 'schema');
    if (schema > 1) {
      throw ManifestSchemaTooNew(schema);
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
    final Map<String, Object?> payloadMap =
        _optionalMap(root, 'payload', 'payload') ?? const <String, Object?>{};
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
    return InstallRecord(
      schema: schema,
      installedAt: installedAt,
      installedBy: _required<String>(root, 'installedBy', 'installedBy'),
      source: _required<String>(root, 'source', 'source'),
      buildMode: BuildMode._fromWireName(
        _required<String>(root, 'buildMode', 'buildMode'),
      ),
      engineFlavor: _required<String>(root, 'engineFlavor', 'engineFlavor'),
      sizeBytes: _required<int>(root, 'sizeBytes', 'sizeBytes'),
      payload: Map<String, String>.unmodifiable(payload),
    );
  }

  /// Install-record schema version.
  final int schema;

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
  final String assets = _required<String>(map, 'assets', 'runtime.assets');
  _validateRelativePath(assets, 'runtime.assets');
  switch (kind) {
    case AppRuntimeKind.flutterAot:
      final String appElf = _required<String>(map, 'appElf', 'runtime.appElf');
      _validateRelativePath(appElf, 'runtime.appElf');
      return FlutterAotRuntime(appElf: appElf, assets: assets);
    case AppRuntimeKind.flutterKernel:
      return FlutterKernelRuntime(assets: assets);
  }
}

EngineRequirement _parseEngine(Map<String, Object?> map) {
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
  final int abi = _required<int>(map, 'plutoAbi', 'engine.plutoAbi');
  if (abi < 1) {
    throw const ManifestFieldError(
      path: 'engine.plutoAbi',
      reason: 'must be at least 1',
    );
  }
  return EngineRequirement(
    flutterVersion: _required<String>(
      map,
      'flutterVersion',
      'engine.flutterVersion',
    ),
    engineCommit: commit,
    plutoAbi: abi,
  );
}

Set<AppPermission> _parsePermissions(Map<String, Object?> root) {
  final Object? raw = root['permissions'];
  if (raw == null) {
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

DisplayPrefs _parseDisplay(Map<String, Object?>? map) {
  if (map == null) {
    return const DisplayPrefs();
  }
  final List<ManifestOrientation> orientations = _parseOrientations(
    map['orientations'],
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
  final double? scale = _parseDisplayScale(map);
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
    scale: scale,
    color: color,
    refreshProfile: refresh,
  );
}

List<ManifestOrientation> _parseOrientations(Object? raw) {
  if (raw == null) {
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

LaunchPrefs _parseLaunch(Map<String, Object?>? map) {
  if (map == null) {
    return const LaunchPrefs();
  }
  final Object? argsRaw = map['args'];
  final List<String> args = <String>[];
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
  if (value == null) {
    return null;
  }
  if (value is T) {
    return value as T;
  }
  throw ManifestFieldError(path: path, reason: 'has the wrong type');
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

double? _parseDisplayScale(Map<String, Object?> map) {
  if (!map.containsKey('scale')) {
    return null;
  }
  final Object? value = map['scale'];
  if (value == 'auto') {
    return null;
  }
  final double scale;
  if (value is int) {
    scale = value.toDouble();
  } else if (value is double) {
    scale = value;
  } else {
    throw const ManifestFieldError(
      path: 'display.scale',
      reason: 'must be auto or a number',
    );
  }
  if (!scale.isFinite || scale < 1.0 || scale > 3.0) {
    throw const ManifestFieldError(
      path: 'display.scale',
      reason: 'numeric overrides must be between 1.0 and 3.0',
    );
  }
  return scale;
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
