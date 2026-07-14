import 'dart:convert';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

import 'filesystem.dart';
import 'tar_archive.dart';

/// Source of transaction nonces.
typedef NonceFactory = String Function();

/// Source of UTC timestamps.
typedef Clock = DateTime Function();

/// Result of installing an app payload.
final class InstallTransactionResult {
  /// Creates an install result.
  const InstallTransactionResult({
    required this.appId,
    required this.revision,
    required this.installedPath,
    required this.changed,
  });

  /// Installed app id.
  final AppId appId;

  /// New `state/apps.rev` value.
  final int revision;

  /// Absolute installed payload path.
  final String installedPath;

  /// Whether the transaction changed app-visible state.
  final bool changed;
}

/// Result of uninstalling an app payload.
final class UninstallTransactionResult {
  /// Creates an uninstall result.
  const UninstallTransactionResult({
    required this.appId,
    required this.revision,
    required this.changed,
  });

  /// App id requested for removal.
  final AppId appId;

  /// Current `state/apps.rev` value.
  final int revision;

  /// Whether an app payload was removed.
  final bool changed;
}

/// Exception thrown by provisioning transaction failures.
final class ProvisionTransactionException implements Exception {
  /// Creates a transaction exception.
  const ProvisionTransactionException(this.message);

  /// Human-readable failure.
  final String message;

  @override
  String toString() => 'ProvisionTransactionException: $message';
}

/// App install/uninstall transaction.
final class PlutoInstallTransaction {
  /// Creates an install transaction runner.
  PlutoInstallTransaction({
    required this.fs,
    this.root = '/home/root/pluto',
    Clock? clock,
    NonceFactory? nonceFactory,
    this.installedBy = 'pluto 0.1.0',
    this.source = 'pluto-cli',
  }) : clock = clock ?? (() => DateTime.now().toUtc()),
       nonceFactory = nonceFactory ?? _defaultNonce;

  /// Filesystem backing this transaction.
  final ProvisionFileSystem fs;

  /// Platform root, normally `/home/root/pluto`.
  final String root;

  /// Clock used for install records and tombstones.
  final Clock clock;

  /// Nonce factory for staging directories.
  final NonceFactory nonceFactory;

  /// `install.json.installedBy`.
  final String installedBy;

  /// `install.json.source`.
  final String source;

  /// Installs a decoded `.plap` tar stream into `apps/<id>`.
  ///
  /// Runtime identity is derived only from complete, checksum-verified
  /// `INTEGRITY.json` metadata; callers cannot label an unverified archive as
  /// release through an API default.
  Future<InstallTransactionResult> installPlap(
    Uint8List plapTarBytes, {
    String? nonce,
  }) async {
    final PlapArchive archive = PlapArchive.decode(plapTarBytes);
    final Map<String, Uint8List> payload = archive.installedPayload();
    final AppManifest manifest = _decodeManifest(payload['manifest.json']);
    final _ArchiveBuildIdentity identity = _authenticateArchiveBuildIdentity(
      archive,
      payload: payload,
      manifest: manifest,
    );
    await repair();
    final String appId = manifest.id.value;
    final String txNonce = nonce ?? nonceFactory();
    final String stagingDir = _join('staging', '$appId.$txNonce');
    final String appDir = _join('apps', appId);
    final String oldDir = _join('staging', '.old-$appId.$txNonce');

    await _ensureLayout();
    await fs.delete(stagingDir, recursive: true);
    await fs.createDirectory(stagingDir);
    for (final MapEntry<String, Uint8List> file in payload.entries) {
      _validateRelativePayloadPath(file.key);
      await fs.writeFile('$stagingDir/${file.key}', file.value);
    }

    if (await fs.exists(oldDir)) {
      await fs.delete(oldDir, recursive: true);
    }
    if (await fs.exists(appDir)) {
      await fs.rename(appDir, oldDir);
    }
    await fs.rename(stagingDir, appDir);

    await fs.createDirectory(_join('appdata', appId));
    await fs.writeFile(
      '$appDir/install.json',
      utf8.encode(
        _installRecordJson(
          buildMode: identity.buildMode,
          engineFlavor: identity.engineFlavor,
          payload: payload,
        ),
      ),
    );
    await fs.delete(oldDir, recursive: true);
    final int revision = await _bumpAppsRevision();
    return InstallTransactionResult(
      appId: manifest.id,
      revision: revision,
      installedPath: appDir,
      changed: true,
    );
  }

  /// Uninstalls [appIdText] from `apps/`.
  Future<UninstallTransactionResult> uninstall(
    String appIdText, {
    bool purgeData = false,
    String? nonce,
  }) async {
    await repair();
    final AppId appId = _parseAppId(appIdText);
    if (appId.value == 'dev.pluto.launcher') {
      throw const ProvisionTransactionException(
        'The launcher can only be removed by full Pluto uninstall.',
      );
    }
    final String appDir = _join('apps', appId.value);
    final String txNonce = nonce ?? nonceFactory();
    final String removedDir = _join('staging', '.rm-${appId.value}.$txNonce');
    await _ensureLayout();
    if (!await fs.exists(appDir)) {
      await fs.delete(removedDir, recursive: true);
      return UninstallTransactionResult(
        appId: appId,
        revision: await _readAppsRevision(),
        changed: false,
      );
    }
    await fs.delete(removedDir, recursive: true);
    await fs.rename(appDir, removedDir);
    final int revision = await _bumpAppsRevision();
    await fs.delete(removedDir, recursive: true);
    final String dataDir = _join('appdata', appId.value);
    if (purgeData) {
      await fs.delete(dataDir, recursive: true);
    } else {
      await fs.createDirectory(dataDir);
      final int epoch = clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      await fs.writeFile('$dataDir/.uninstalled-$epoch', utf8.encode(''));
    }
    return UninstallTransactionResult(
      appId: appId,
      revision: revision,
      changed: true,
    );
  }

  /// Repairs interrupted install/uninstall staging states.
  Future<void> repair() async {
    await _ensureLayout();
    final List<ProvisionPathEntry> appEntries = await fs.listDirectory(
      _join('apps'),
    );
    for (final ProvisionPathEntry app in appEntries) {
      if (app.type != ProvisionEntryType.directory) {
        continue;
      }
      if (!await fs.exists('${app.path}/install.json')) {
        final String? old = await _oldStagingDirFor(app.name);
        await fs.delete(app.path, recursive: true);
        if (old != null) {
          await fs.rename(old, app.path);
        }
      }
    }

    final List<ProvisionPathEntry> stagingEntries = await fs.listDirectory(
      _join('staging'),
    );
    for (final ProvisionPathEntry entry in stagingEntries) {
      if (entry.type != ProvisionEntryType.directory) {
        continue;
      }
      final String name = entry.name;
      if (name.startsWith('.old-')) {
        final String? appId = _appIdFromHiddenStaging(name, '.old-');
        if (appId == null) {
          await fs.delete(entry.path, recursive: true);
          continue;
        }
        final String appDir = _join('apps', appId);
        if (await fs.exists(appDir)) {
          await fs.delete(entry.path, recursive: true);
        } else {
          await fs.rename(entry.path, appDir);
        }
        continue;
      }
      await fs.delete(entry.path, recursive: true);
    }
  }

  /// Discovers committed installed apps.
  Future<List<InstalledApp>> discoverInstalledApps() async {
    await _ensureLayout();
    final List<InstalledApp> apps = <InstalledApp>[];
    final List<ProvisionPathEntry> entries = await fs.listDirectory(
      _join('apps'),
    );
    for (final ProvisionPathEntry entry in entries) {
      if (entry.type != ProvisionEntryType.directory) {
        continue;
      }
      final String manifestPath = '${entry.path}/manifest.json';
      final String recordPath = '${entry.path}/install.json';
      if (!await fs.exists(manifestPath) || !await fs.exists(recordPath)) {
        continue;
      }
      final AppManifest manifest = _decodeManifest(
        await fs.readFile(manifestPath),
      );
      final InstallRecord record = _decodeInstallRecord(
        await fs.readFile(recordPath),
      );
      apps.add(
        InstalledApp(
          manifest: manifest,
          record: record,
          appDir: entry.path,
          dataDir: _join('appdata', manifest.id.value),
        ),
      );
    }
    apps.sort(
      (InstalledApp a, InstalledApp b) =>
          a.manifest.id.value.compareTo(b.manifest.id.value),
    );
    return apps;
  }

  Future<String?> _oldStagingDirFor(String appId) async {
    final List<ProvisionPathEntry> stagingEntries = await fs.listDirectory(
      _join('staging'),
    );
    for (final ProvisionPathEntry entry in stagingEntries) {
      if (entry.type != ProvisionEntryType.directory) {
        continue;
      }
      final String? oldAppId = _appIdFromHiddenStaging(entry.name, '.old-');
      if (oldAppId == appId) {
        return entry.path;
      }
    }
    return null;
  }

  Future<void> _ensureLayout() async {
    await fs.createDirectory(_join('apps'));
    await fs.createDirectory(_join('appdata'));
    await fs.createDirectory(_join('staging'));
    await fs.createDirectory(_join('state'));
  }

  Future<int> _bumpAppsRevision() async {
    final int next = await _readAppsRevision() + 1;
    final String temp = _join('state', 'apps.rev.tmp');
    final String target = _join('state', 'apps.rev');
    await fs.writeFile(temp, utf8.encode('$next\n'));
    await fs.rename(temp, target);
    return next;
  }

  Future<int> _readAppsRevision() async {
    final String path = _join('state', 'apps.rev');
    if (!await fs.exists(path)) {
      return 0;
    }
    final String text = utf8.decode(await fs.readFile(path)).trim();
    if (text.isEmpty) {
      return 0;
    }
    return int.parse(text);
  }

  String _installRecordJson({
    required BuildMode buildMode,
    required String engineFlavor,
    required Map<String, Uint8List> payload,
  }) {
    final Map<String, String> payloadHashes = _payloadHashes(payload);
    final Map<String, Object?> record = <String, Object?>{
      'schema': 1,
      'installedAt': clock().toUtc().toIso8601String(),
      'installedBy': installedBy,
      'source': source,
      'buildMode': buildMode.wireName,
      'engineFlavor': engineFlavor,
      'sizeBytes': payload.values.fold<int>(
        0,
        (int total, Uint8List bytes) => total + bytes.length,
      ),
      'payload': payloadHashes,
    };
    return const JsonEncoder.withIndent('  ').convert(record);
  }

  Map<String, String> _payloadHashes(Map<String, Uint8List> payload) {
    final List<MapEntry<String, Uint8List>> files = payload.entries.toList()
      ..sort(
        (MapEntry<String, Uint8List> a, MapEntry<String, Uint8List> b) =>
            a.key.compareTo(b.key),
      );
    final Map<String, String> hashes = <String, String>{};
    final Map<String, String> assetFileHashes = <String, String>{};
    for (final MapEntry<String, Uint8List> file in files) {
      final String digest = sha256Hex(file.value);
      hashes[file.key] = 'sha256:$digest';
      if (file.key.startsWith('flutter_assets/')) {
        assetFileHashes[file.key] = digest;
      }
    }
    if (assetFileHashes.isNotEmpty) {
      hashes['flutter_assets/'] = 'sha256:tree:${_treeHash(assetFileHashes)}';
    }
    return hashes;
  }

  String _join(String first, [String? second]) {
    if (second == null) {
      return provisionJoin(<String>[root, first]);
    }
    return provisionJoin(<String>[root, first, second]);
  }
}

final class _ArchiveBuildIdentity {
  const _ArchiveBuildIdentity({
    required this.buildMode,
    required this.engineFlavor,
  });

  final BuildMode buildMode;
  final String engineFlavor;
}

_ArchiveBuildIdentity _authenticateArchiveBuildIdentity(
  PlapArchive archive, {
  required Map<String, Uint8List> payload,
  required AppManifest manifest,
}) {
  final Map<String, Object?> integrity = archive.integrity;
  if (integrity['schema'] != 1) {
    throw const ProvisionTransactionException(
      'INTEGRITY.json must use schema 1.',
    );
  }

  final Object? rawFiles = integrity['files'];
  final Object? rawTreeHash = integrity['treeSha256'];
  if (rawFiles is! Map<String, Object?> ||
      rawTreeHash is! String ||
      !_sha256Pattern.hasMatch(rawTreeHash)) {
    throw const ProvisionTransactionException(
      'INTEGRITY.json must authenticate the complete payload tree.',
    );
  }

  final Map<String, String> expectedHashes = <String, String>{};
  for (final MapEntry<String, Object?> entry in rawFiles.entries) {
    final Object? digest = entry.value;
    if (entry.key == 'INTEGRITY.json' ||
        digest is! String ||
        !_sha256Pattern.hasMatch(digest)) {
      throw ProvisionTransactionException(
        'Invalid integrity record for ${entry.key}.',
      );
    }
    expectedHashes[entry.key] = digest;
  }
  final Map<String, String> actualHashes = <String, String>{
    for (final MapEntry<String, Uint8List> entry in archive.entries.entries)
      if (entry.key != 'INTEGRITY.json') entry.key: sha256Hex(entry.value),
  };
  if (actualHashes.length != expectedHashes.length ||
      !actualHashes.keys.every(expectedHashes.containsKey) ||
      !expectedHashes.keys.every(actualHashes.containsKey)) {
    throw const ProvisionTransactionException(
      'Archive payload set does not match INTEGRITY.json.',
    );
  }
  for (final MapEntry<String, String> entry in actualHashes.entries) {
    if (expectedHashes[entry.key] != entry.value) {
      throw ProvisionTransactionException(
        'Integrity check failed for ${entry.key}.',
      );
    }
  }
  if (_treeHash(actualHashes) != rawTreeHash) {
    throw const ProvisionTransactionException(
      'Archive tree hash does not match INTEGRITY.json.',
    );
  }

  final Object? rawBuildMode = integrity['buildMode'];
  final Object? rawEngineFlavor = integrity['engineFlavor'];
  if (rawBuildMode is! String || rawEngineFlavor is! String) {
    throw const ProvisionTransactionException(
      'INTEGRITY.json has no authenticated buildMode/engineFlavor.',
    );
  }
  final BuildMode? buildMode = _buildModeFromWireName(rawBuildMode);
  if (buildMode == null || rawEngineFlavor != rawBuildMode) {
    throw ProvisionTransactionException(
      'Invalid buildMode/engineFlavor: $rawBuildMode/$rawEngineFlavor.',
    );
  }
  _validateRuntimePayloadShape(
    payload,
    manifest: manifest,
    buildMode: buildMode,
  );
  return _ArchiveBuildIdentity(
    buildMode: buildMode,
    engineFlavor: rawEngineFlavor,
  );
}

void _validateRuntimePayloadShape(
  Map<String, Uint8List> payload, {
  required AppManifest manifest,
  required BuildMode buildMode,
}) {
  final AppRuntime runtime = manifest.runtime;
  final String assetsPrefix = '${runtime.assets}/';
  if (!payload.keys.any((String path) => path.startsWith(assetsPrefix))) {
    throw ProvisionTransactionException(
      'Package has no assets under ${runtime.assets}.',
    );
  }
  final String kernelPath = '${runtime.assets}/kernel_blob.bin';
  final bool hasKernel = payload.containsKey(kernelPath);
  final bool isAot = buildMode != BuildMode.debug;
  if (isAot) {
    if (runtime is! FlutterAotRuntime ||
        !payload.containsKey(runtime.appElf) ||
        hasKernel) {
      throw ProvisionTransactionException(
        '${buildMode.wireName} package must use flutter-aot, contain '
        'its declared app.so, and contain no kernel_blob.bin.',
      );
    }
    return;
  }
  final bool hasCanonicalAotElf =
      payload.containsKey('lib/app.so') || payload.containsKey('app.so');
  if (runtime is! FlutterKernelRuntime || !hasKernel || hasCanonicalAotElf) {
    throw const ProvisionTransactionException(
      'Debug package must use flutter-kernel, contain kernel_blob.bin, and '
      'contain no app.so.',
    );
  }
}

BuildMode? _buildModeFromWireName(String name) {
  for (final BuildMode mode in BuildMode.values) {
    if (mode.wireName == name) {
      return mode;
    }
  }
  return null;
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

AppManifest _decodeManifest(Uint8List? bytes) {
  if (bytes == null) {
    throw const ProvisionTransactionException('Missing manifest.json.');
  }
  final Result<AppManifest, ManifestError> result = AppManifest.decode(
    utf8.decode(bytes),
  );
  final AppManifest? manifest = result.valueOrNull;
  if (manifest != null) {
    return manifest;
  }
  throw ProvisionTransactionException(result.errorOrNull!.message);
}

InstallRecord _decodeInstallRecord(Uint8List bytes) {
  final Result<InstallRecord, ManifestError> result = InstallRecord.decode(
    utf8.decode(bytes),
  );
  final InstallRecord? record = result.valueOrNull;
  if (record != null) {
    return record;
  }
  throw ProvisionTransactionException(result.errorOrNull!.message);
}

AppId _parseAppId(String appIdText) {
  final AppId? appId = AppId.tryParse(appIdText);
  if (appId == null) {
    throw ProvisionTransactionException('Invalid app id: $appIdText');
  }
  return appId;
}

void _validateRelativePayloadPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('..')) {
    throw ProvisionTransactionException('Unsafe payload path: $path');
  }
}

String? _appIdFromHiddenStaging(String name, String prefix) {
  if (!name.startsWith(prefix)) {
    return null;
  }
  final String rest = name.substring(prefix.length);
  final int lastDot = rest.lastIndexOf('.');
  if (lastDot <= 0) {
    return null;
  }
  return rest.substring(0, lastDot);
}

String _treeHash(Map<String, String> fileHashes) {
  final StringBuffer buffer = StringBuffer();
  final List<MapEntry<String, String>> entries = fileHashes.entries.toList()
    ..sort(
      (MapEntry<String, String> a, MapEntry<String, String> b) =>
          a.key.compareTo(b.key),
    );
  for (final MapEntry<String, String> entry in entries) {
    buffer
      ..write(entry.key)
      ..write('\u0000')
      ..write(entry.value)
      ..write('\n');
  }
  return sha256Hex(utf8.encode(buffer.toString()));
}

String _defaultNonce() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(16);
