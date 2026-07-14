import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../artifacts/checksums.dart';
import '../build/plap_reader.dart';
import '../device/device_probe.dart';
import '../device/remarkable_device.dart';
import '../process.dart';
import '../ssh/device_transport.dart';
import '../ssh/dropbear_transport.dart' show shellQuote;

typedef _CooperativeFirmwareProfile = ({
  String firmwareVersion,
  String firmwareBuild,
  String xochitlDigest,
});

typedef _CooperativeActivationState = ({
  String pid,
  String qtfbGeneration,
  String controlGeneration,
});

typedef _CooperativeDefaultSnapshot = ({String backupPath, String? appId});

typedef _DirectScreenshotCapture = ({
  String path,
  int byteCount,
  String digest,
  String appId,
  int pid,
  String surface,
  int width,
  int height,
  int stride,
  String format,
});

/// A single runtime payload file to stage onto the device.
final class PayloadFile {
  /// Creates a payload file mapping.
  const PayloadFile({
    required this.localPath,
    required this.remoteRelative,
    this.executable = false,
  });

  /// Host path to read from.
  final String localPath;

  /// Path under the device root to write to.
  final String remoteRelative;

  /// Whether to mark the uploaded file executable.
  final bool executable;
}

/// Host-side XOVI/AppLoad integration tree carried by a cooperative release
/// payload. It is installed only by the model-selected provisioning backend.
final class CooperativeIntegrationPayload {
  /// Creates an integration payload rooted at [rootDirectory].
  const CooperativeIntegrationPayload({required this.rootDirectory});

  /// Directory containing `CHECKSUMS.txt` and the versioned `xovi/` tree.
  final String rootDirectory;
}

/// A packaged app to stage into the on-device registry.
final class PayloadApp {
  /// Creates an app payload.
  const PayloadApp({
    required this.appId,
    required this.bundleDir,
    required this.buildMode,
    required this.engineFlavor,
    required this.target,
  });

  /// App id (registry directory name).
  final String appId;

  /// Host path to the app's `bundle/` directory.
  final String bundleDir;

  /// Exact build mode recorded during provisioning.
  final String buildMode;

  /// Exact engine flavor selected by the supervisor.
  final String engineFlavor;

  /// Build target recorded in the app layout metadata.
  final String target;
}

final class _PreparedLayoutFile {
  const _PreparedLayoutFile({required this.relativePath, required this.bytes});

  final String relativePath;
  final Uint8List bytes;
}

final class _PreparedPayloadApp {
  const _PreparedPayloadApp({
    required this.app,
    required this.manifestBytes,
    required this.layoutFiles,
  });

  final PayloadApp app;
  final Uint8List manifestBytes;
  final List<_PreparedLayoutFile> layoutFiles;
}

final class _PreparedIntegrationFile {
  const _PreparedIntegrationFile({
    required this.relativePath,
    required this.bytes,
    required this.executable,
    required this.digest,
  });

  final String relativePath;
  final Uint8List bytes;
  final bool executable;
  final String digest;
}

final class _PreparedCooperativeIntegration {
  const _PreparedCooperativeIntegration({
    required this.files,
    required this.hashtabDigest,
  });

  final List<_PreparedIntegrationFile> files;
  final String hashtabDigest;
}

/// Outcome of a device operation, for CLI reporting.
final class DeviceOperationResult {
  /// Creates a result.
  const DeviceOperationResult({required this.ok, required this.message});

  /// Whether the operation succeeded.
  final bool ok;

  /// Human-readable summary.
  final String message;
}

/// One removable artifact found by `pluto cleanup`.
final class CleanupItem {
  /// Creates a cleanup item.
  const CleanupItem({
    required this.category,
    required this.sizeKb,
    required this.path,
  });

  /// Kind of artifact (stale-log, orphaned-app, swtcon-probe, bin-backup,
  /// staging).
  final String category;

  /// Size in kilobytes as reported by `du -sk`.
  final int sizeKb;

  /// Absolute device path.
  final String path;
}

/// Result of a cleanup scan or apply run.
final class CleanupReport {
  /// Creates a report.
  const CleanupReport({required this.items, required this.applied});

  /// Artifacts found (and removed when [applied]).
  final List<CleanupItem> items;

  /// Whether the artifacts were deleted (`--apply`) or just listed.
  final bool applied;

  /// Total size of all items in kilobytes.
  int get totalKb =>
      items.fold(0, (int sum, CleanupItem item) => sum + item.sizeKb);
}

/// Live implementations of the Pluto device operations over an SSH
/// [DeviceTransport], targeting the canonical on-device runtime layout used
/// by the session supervisor (`tools/device/pluto-session.sh`):
///
/// ```
/// /home/root/pluto/
///   bin/       pluto-embedder, pluto-session.sh, device scripts
///   engine/    release/profile engines; debug only for explicit hot reload
///   launcher/  bundle/ + manifest.json (app id dev.pluto.launcher)
///   apps/      <app-id>/{bundle/, manifest.json, install.json}
///   logs/      current.log, boot-hook.log
///   state/     boot-mode, default-app, apps-changed, ...
///   staging/   install transaction scratch space
/// ```
final class LiveDeviceOperations {
  /// Creates operations bound to [transport].
  LiveDeviceOperations(
    this.transport, {
    this.deviceRoot = defaultDeviceRoot,
    this.runDir = defaultRunDir,
  });

  /// Canonical runtime root shared by every supported device backend.
  static const String defaultDeviceRoot = '/home/root/pluto';

  /// Supervisor control directory (launch/home/stock request files).
  static const String defaultRunDir = '/run/pluto';

  /// App id of the built-in launcher (lives at `$deviceRoot/launcher`, not in
  /// the `apps/` registry).
  static const String launcherAppId = 'dev.pluto.launcher';

  static const String _directTarget = 'linux-arm64';
  static const String _cooperativeTarget = 'linux-arm';
  static const String _appLoadRoot = '/home/root/xovi/exthome/appload';
  static const String _appLoadControlSocket = '/run/pluto/appload-control.sock';
  static const String _xoviRoot = '/home/root/xovi';
  static const String _xoviControlClient =
      '/home/root/xovi/bin/pluto-apploadctl';
  static const String _integrationRollback =
      '/home/root/xovi/rollback/pluto-previous';
  static const String _integrationLock =
      '/run/pluto/integration-provision.lock';
  static const String _restartLedger =
      '/home/root/.pluto-xochitl-restart-ledger';
  static const String _qrrHashtab =
      '/home/root/xovi/exthome/qt-resource-rebuilder/hashtab';

  static const Map<String, bool> _commonIntegrationFiles = <String, bool>{
    'xovi.so': false,
    'start': true,
    'stock': true,
    'debug': true,
    'rebuild_hashtable': true,
    'extensions.d/qt-resource-rebuilder.so': false,
    'services/xochitl.service/qt-resource-rebuilder.conf': false,
    'scripts/debug/qt-resource-rebuilder.sh': true,
    'bin/pluto-apploadctl': true,
    'exthome/appload/shims/qtfb-shim-32bit.so': false,
    'exthome/appload/shims/qtfb-shim.so': false,
  };
  static const Map<String, bool> _integrationFiles = <String, bool>{
    ..._commonIntegrationFiles,
    'extensions.d/appload.so': false,
    'exthome/qt-resource-rebuilder/hashtab': false,
  };
  static const Map<String, String> _appLoadFirmwareProfiles = <String, String>{
    '3.27.3.0': 'profiles/3.27.3.0/appload.so',
    '3.28.0.162': 'profiles/3.28.0.162/appload.so',
  };
  static const Map<String, String> _qrrHashtabProfiles = <String, String>{
    '3.27.3.0': 'profiles/3.27.3.0/hashtab',
    '3.28.0.162': 'profiles/3.28.0.162/hashtab',
  };
  static const Map<String, _CooperativeFirmwareProfile>
  _cooperativeProfilesByModel = <String, _CooperativeFirmwareProfile>{
    'zero-gravitas': (
      firmwareVersion: '3.27.3.0',
      firmwareBuild: '20260612085811',
      xochitlDigest:
          '28268d44e710738622e576ca9256d14045fd8a18464252f3fb266c7f28d00b1f',
    ),
    'zero-sugar': (
      firmwareVersion: '3.28.0.162',
      firmwareBuild: '20260629074044',
      xochitlDigest:
          'e0fef1de8e4644b6ef6d829436deaa8d8e8a083c14a806f6300b2de248199b18',
    ),
  };

  static const Set<String> _directTargetArchitectures = <String>{
    'aarch64',
    'arm64',
  };
  static const Set<String> _cooperativeTargetArchitectures = <String>{
    'armv7',
    'armv7l',
  };

  /// SSH transport to the device.
  final DeviceTransport transport;

  /// Root directory on the device that holds the Pluto runtime.
  final String deviceRoot;

  /// Supervisor control directory on the device.
  final String runDir;

  int _nonceCounter = 0;

  String get _bootInstall => '$deviceRoot/bin/pluto-boot-install.sh';

  String get _transaction => '$deviceRoot/bin/pluto-install-transaction.sh';

  String get _appControl => '$deviceRoot/bin/pluto-app-control.sh';

  String get _cooperativeControlClient => '$deviceRoot/bin/pluto-apploadctl';

  String get _embedderControlSocket => '$runDir/embedder-control.sock';

  String _q(String value) => shellQuote(value);

  Future<void> _run(String command, {String? failure}) async {
    final CommandResult result = await transport.exec(
      command,
      timeout: const Duration(seconds: 120),
    );
    if (!result.isSuccess) {
      throw DeviceOperationException(
        failure ?? 'command failed: $command',
        result.stderr.isNotEmpty ? result.stderr : result.stdout,
      );
    }
  }

  /// Probes immutable hardware identity and returns Pluto's internal runtime
  /// backend selection. Public commands use this to choose an implementation
  /// without exposing a second device workflow.
  Future<PlutoRuntimeBackend> runtimeBackend() async {
    final RemarkableDevice device = await _probeWriteTarget();
    final PlutoRuntimeBackend? backend = device.runtimeBackend;
    if (backend == null) {
      throw DeviceOperationException(
        'device model is not supported',
        'Detected ${device.model ?? 'an unknown model'} at '
            '${transport.endpoint.sshTarget}. Hardware identity must come '
            'from SoC or device-tree metadata; hostname is not trusted.',
      );
    }
    return backend;
  }

  String _nextNonce() {
    final String timestamp = DateTime.now().microsecondsSinceEpoch
        .toRadixString(36);
    final String counter = (_nonceCounter++).toRadixString(36);
    return '$timestamp-$counter';
  }

  Future<void> _stopInstalledApp(String appId) async {
    await _run(
      '[ -x ${_q(_appControl)} ] || { '
      'echo ${_q('missing app lifecycle helper: $_appControl')} >&2; '
      'exit 69; }; '
      'PLUTO_ROOT=${_q(deviceRoot)} PLUTO_RUN_DIR=${_q(runDir)} '
      'sh ${_q(_appControl)} stop ${_q(appId)}',
      failure: 'could not stop running versions of $appId',
    );
  }

  Future<void> _uploadFile(PayloadFile file) async {
    final Uint8List bytes = Uint8List.fromList(
      File(file.localPath).readAsBytesSync(),
    );
    final String target = '$deviceRoot/${file.remoteRelative}';
    final int separator = target.lastIndexOf('/');
    final String parent = target.substring(0, separator);
    final String basename = target.substring(separator + 1);
    final String staged = '$parent/.$basename.pluto-new-${_nextNonce()}';
    await _run(
      'mkdir -p ${_q(parent)}',
      failure: 'could not prepare ${file.remoteRelative}',
    );
    await transport.uploadFileBytes(bytes: bytes, remotePath: staged);
    final String mode = file.executable ? '0755' : '0644';
    await _run(
      '[ ! -d ${_q(target)} ] && chmod $mode ${_q(staged)} && '
      'mv -f ${_q(staged)} ${_q(target)}',
      failure: 'could not atomically install ${file.remoteRelative}',
    );
  }

  Uint8List _installRecord(
    String appId,
    String source, {
    String buildMode = 'release',
    String engineFlavor = 'release',
    int sizeBytes = 0,
    Map<String, String> payload = const <String, String>{},
  }) {
    return Uint8List.fromList(
      utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'schema': 1, 'appId': appId, 'installedAt': DateTime.now().toUtc().toIso8601String(), 'installedBy': 'pluto 0.1.0', 'source': source, 'buildMode': buildMode, 'engineFlavor': engineFlavor, 'sizeBytes': sizeBytes, 'payload': payload})}\n',
      ),
    );
  }

  _PreparedPayloadApp _prepareApp(PayloadApp app, {String? manifestPath}) {
    final File manifest = File(
      manifestPath ?? '${app.bundleDir}/../manifest.json',
    );
    if (!manifest.existsSync()) {
      throw DeviceOperationException(
        'missing manifest for ${app.appId}',
        'Expected ${manifest.path}; provision only complete Pluto layouts.',
      );
    }
    final Uint8List manifestBytes;
    final Object? decoded;
    try {
      manifestBytes = Uint8List.fromList(manifest.readAsBytesSync());
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } on FileSystemException catch (error) {
      throw DeviceOperationException(
        'could not read manifest for ${app.appId}',
        error.message,
      );
    } on FormatException catch (error) {
      throw DeviceOperationException(
        'invalid manifest for ${app.appId}',
        error.message,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw DeviceOperationException(
        'invalid manifest for ${app.appId}',
        'Expected ${manifest.path} to contain a JSON object.',
      );
    }
    final List<_PreparedLayoutFile> layoutFiles = <_PreparedLayoutFile>[];
    final Set<String> seen = <String>{};
    for (final String field in const <String>['icon', 'iconMono']) {
      if (!decoded.containsKey(field)) {
        continue;
      }
      final Object? value = decoded[field];
      if (value is! String || !_isSafeLayoutPath(value)) {
        throw DeviceOperationException(
          'unsafe $field path for ${app.appId}',
          '$field must be a non-empty relative path without dot segments or '
              'backslashes.',
        );
      }
      if (!seen.add(value)) {
        continue;
      }
      final File asset = File('${manifest.parent.path}/$value');
      if (FileSystemEntity.typeSync(asset.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw DeviceOperationException(
          'missing $field for ${app.appId}',
          'Expected a regular layout file at ${asset.path}.',
        );
      }
      try {
        layoutFiles.add(
          _PreparedLayoutFile(
            relativePath: value,
            bytes: Uint8List.fromList(asset.readAsBytesSync()),
          ),
        );
      } on FileSystemException catch (error) {
        throw DeviceOperationException(
          'could not read $field for ${app.appId}',
          error.message,
        );
      }
    }
    return _PreparedPayloadApp(
      app: app,
      manifestBytes: manifestBytes,
      layoutFiles: List<_PreparedLayoutFile>.unmodifiable(layoutFiles),
    );
  }

  bool _isSafeLayoutPath(String value) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      return false;
    }
    return value
        .split('/')
        .every(
          (String segment) =>
              segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }

  Future<void> _stageApp(
    _PreparedPayloadApp prepared, {
    required String source,
  }) async {
    final PayloadApp app = prepared.app;
    final bool isLauncher = app.appId == launcherAppId;
    final String remote = isLauncher
        ? '$deviceRoot/launcher'
        : '$deviceRoot/apps/${app.appId}';
    final int separator = remote.lastIndexOf('/');
    final String parent = remote.substring(0, separator);
    final String basename = remote.substring(separator + 1);
    final String nonce = _nextNonce();
    final String staged = '$parent/.$basename.pluto-new-$nonce';
    final String backup = '$parent/.$basename.pluto-old-$nonce';
    await _run(
      'mkdir -p ${_q(parent)} && rm -rf ${_q(staged)} ${_q(backup)} && '
      'mkdir -p ${_q(staged)}',
      failure: 'could not prepare ${app.appId} staging directory',
    );
    await transport.uploadDirectory(
      localPath: app.bundleDir,
      remotePath: '$staged/bundle',
    );
    await transport.uploadFileBytes(
      bytes: prepared.manifestBytes,
      remotePath: '$staged/manifest.json',
    );
    for (final _PreparedLayoutFile file in prepared.layoutFiles) {
      await transport.uploadFileBytes(
        bytes: file.bytes,
        remotePath: '$staged/${file.relativePath}',
      );
    }
    // For registry apps this is the transaction repair commit marker. The
    // launcher keeps the same record so its release-only identity is explicit
    // and auditable even though it is outside the app registry.
    await transport.uploadFileBytes(
      bytes: _installRecord(
        app.appId,
        source,
        buildMode: app.buildMode,
        engineFlavor: app.engineFlavor,
      ),
      remotePath: '$staged/install.json',
    );
    final List<String> requiredPaths = <String>[
      '$staged/bundle',
      '$staged/manifest.json',
      '$staged/install.json',
      for (final _PreparedLayoutFile file in prepared.layoutFiles)
        '$staged/${file.relativePath}',
    ];
    await _run(
      '[ -d ${_q(requiredPaths.first)} ] && '
      '${requiredPaths.skip(1).map((String path) => '[ -f ${_q(path)} ]').join(' && ')}',
      failure: 'staged payload validation failed for ${app.appId}',
    );
    if (!isLauncher) {
      await _stopInstalledApp(app.appId);
    }
    await _run(
      'had_live=0; '
      'if [ -e ${_q(remote)} ] || [ -L ${_q(remote)} ]; then '
      'mv ${_q(remote)} ${_q(backup)} || exit 1; had_live=1; fi; '
      'if mv ${_q(staged)} ${_q(remote)}; then '
      'rm -rf ${_q(backup)}; '
      'else rc=\$?; '
      'if [ "\$had_live" = 1 ]; then '
      'mv ${_q(backup)} ${_q(remote)}; fi; '
      'exit "\$rc"; fi',
      failure: 'could not atomically install ${app.appId}',
    );
  }

  Future<void> _removeStaleDebugState() async {
    final String nonce = _nextNonce();
    final String engineRoot = '$deviceRoot/engine';
    final String appsRoot = '$deviceRoot/apps';
    await _run(
      'for remnant in '
      '${_q(engineRoot)}/.*.pluto-new-* '
      '${_q(engineRoot)}/.*.pluto-old-* '
      '${_q(appsRoot)}/.*.pluto-new-* '
      '${_q(appsRoot)}/.*.pluto-old-* '
      '${_q(deviceRoot)}/.launcher.pluto-new-* '
      '${_q(deviceRoot)}/.launcher.pluto-old-*; do '
      '[ -e "\$remnant" ] || [ -L "\$remnant" ] || continue; '
      'rm -rf "\$remnant" || exit 1; done; '
      'for flavor in release profile; do '
      'flavor_dir=${_q(engineRoot)}/\$flavor; '
      '[ -d "\$flavor_dir" ] && [ ! -L "\$flavor_dir" ] || continue; '
      'for remnant in "\$flavor_dir"/.*.pluto-new-* '
      '"\$flavor_dir"/.*.pluto-old-*; do '
      '[ -e "\$remnant" ] || [ -L "\$remnant" ] || continue; '
      'rm -rf "\$remnant" || exit 1; done; done; '
      'for engine in ${_q(engineRoot)}/*; do '
      '[ -e "\$engine" ] || [ -L "\$engine" ] || continue; '
      'flavor=\${engine##*/}; '
      'case "\$flavor" in release|profile) continue ;; esac; '
      'stale=${_q(engineRoot)}/.\$flavor.pluto-old-$nonce; '
      'rm -rf "\$stale" && mv "\$engine" "\$stale" && '
      'rm -rf "\$stale" || exit 1; done; '
      'default_app=\$(cat ${_q('$deviceRoot/state/default-app')} '
      '2>/dev/null || true); removed=0; '
      'for d in ${_q('$deviceRoot/apps')}/*; do '
      '[ -d "\$d" ] || continue; is_debug=0; '
      "grep -Eq '\"(buildMode|engineFlavor)\"[[:space:]]*:"
      "[[:space:]]*\"debug\"' \"\$d/install.json\" 2>/dev/null && "
      'is_debug=1; '
      "grep -Eq '\"type\"[[:space:]]*:[[:space:]]*"
      "\"(flutter-kernel|flutterKernel)\"' \"\$d/manifest.json\" "
      '2>/dev/null && is_debug=1; '
      '[ ! -f "\$d/bundle/flutter_assets/kernel_blob.bin" ] || is_debug=1; '
      '[ "\$is_debug" = 1 ] || continue; app_id=\${d##*/}; '
      'stale=${_q('$deviceRoot/apps')}/.\$app_id.pluto-old-$nonce; '
      'rm -rf "\$stale" && mv "\$d" "\$stale" && rm -rf "\$stale" '
      '|| exit 1; '
      'if [ "\$default_app" = "\$app_id" ]; then '
      'rm -f ${_q('$deviceRoot/state/default-app')}; fi; removed=1; done; '
      '[ "\$removed" != 1 ] || '
      'touch ${_q('$deviceRoot/state/apps-changed')}',
      failure: 'could not remove stale debug runtime state',
    );
  }

  Future<bool> _commitCooperativeStages({
    required String appId,
    required String stagedApp,
    required String stagedEntry,
  }) async {
    final String liveApp = appId == launcherAppId
        ? '$deviceRoot/launcher'
        : '$deviceRoot/apps/$appId';
    final String liveEntry = _appLoadEntryPath(appId);
    final String nonce = _nextNonce();
    final String appBackup = '$liveApp.pluto-old-$nonce';
    final String entryBackup = '$liveEntry.pluto-old-$nonce';
    final Map<String, Object?> stop = await _controlRequest(
      'stop',
      fields: <String, Object?>{'appId': appId},
    );
    final bool wasRunning = stop['stopped'] == true;
    await _run(
      'rm -rf ${_q(appBackup)} ${_q(entryBackup)}; '
      'if [ -e ${_q(liveApp)} ] || [ -L ${_q(liveApp)} ]; then '
      'mv ${_q(liveApp)} ${_q(appBackup)} || exit 1; fi; '
      'if [ -e ${_q(liveEntry)} ] || [ -L ${_q(liveEntry)} ]; then '
      'mv ${_q(liveEntry)} ${_q(entryBackup)} || { '
      '[ ! -e ${_q(appBackup)} ] || mv ${_q(appBackup)} ${_q(liveApp)}; '
      'exit 1; }; fi; '
      'if ! mv ${_q(stagedApp)} ${_q(liveApp)}; then '
      '[ ! -e ${_q(entryBackup)} ] || '
      'mv ${_q(entryBackup)} ${_q(liveEntry)}; '
      '[ ! -e ${_q(appBackup)} ] || mv ${_q(appBackup)} ${_q(liveApp)}; '
      'exit 1; fi; '
      'if ! mv ${_q(stagedEntry)} ${_q(liveEntry)}; then '
      'rm -rf ${_q(liveApp)}; '
      '[ ! -e ${_q(entryBackup)} ] || '
      'mv ${_q(entryBackup)} ${_q(liveEntry)}; '
      '[ ! -e ${_q(appBackup)} ] || mv ${_q(appBackup)} ${_q(liveApp)}; '
      'exit 1; fi',
      failure: 'could not atomically install $appId',
    );
    try {
      await _controlRequest('reload');
    } on Object {
      await _run(
        'rm -rf ${_q(liveApp)} ${_q(liveEntry)}; '
        '[ ! -e ${_q(appBackup)} ] || '
        'mv ${_q(appBackup)} ${_q(liveApp)}; '
        '[ ! -e ${_q(entryBackup)} ] || '
        'mv ${_q(entryBackup)} ${_q(liveEntry)}',
        failure: 'could not roll back $appId after AppLoad reload failed',
      );
      try {
        await _controlRequest('reload');
        if (wasRunning) {
          await _controlRequest(
            'launch',
            fields: <String, Object?>{
              'appId': appId,
              'entryId': _appLoadEntryId(appId),
              'replace': true,
            },
          );
        }
      } on Object {
        // Preserve the original reload failure. The on-disk rollback above is
        // authoritative even if the UI integration also needs recovery.
      }
      rethrow;
    }
    await _run('rm -rf ${_q(appBackup)} ${_q(entryBackup)}');
    return wasRunning;
  }

  Future<void> _stageCooperativeApp(
    _PreparedPayloadApp prepared, {
    required String source,
  }) async {
    final PayloadApp app = prepared.app;
    if (app.buildMode != 'release' || app.engineFlavor != 'release') {
      throw DeviceOperationException(
        'cooperative apps must be release AOT',
        '${app.appId} is ${app.buildMode}/${app.engineFlavor}.',
      );
    }
    final String liveApp = app.appId == launcherAppId
        ? '$deviceRoot/launcher'
        : '$deviceRoot/apps/${app.appId}';
    final String appParent = liveApp.substring(0, liveApp.lastIndexOf('/'));
    final String entryParent = _appLoadRoot;
    final String nonce = _nextNonce();
    final String stagedApp =
        '$appParent/.${liveApp.split('/').last}.pluto-new-$nonce';
    final String stagedEntry =
        '$entryParent/.${_appLoadEntryName(app.appId)}.pluto-new-$nonce';
    await _run(
      'mkdir -p ${_q(appParent)} ${_q(entryParent)} && '
      'rm -rf ${_q(stagedApp)} ${_q(stagedEntry)} && '
      'mkdir -p ${_q(stagedApp)} ${_q(stagedEntry)}',
      failure: 'could not prepare ${app.appId} staging directories',
    );
    await transport.uploadDirectory(
      localPath: app.bundleDir,
      remotePath: '$stagedApp/bundle',
    );
    await transport.uploadFileBytes(
      bytes: prepared.manifestBytes,
      remotePath: '$stagedApp/manifest.json',
    );
    for (final _PreparedLayoutFile file in prepared.layoutFiles) {
      await transport.uploadFileBytes(
        bytes: file.bytes,
        remotePath: '$stagedApp/${file.relativePath}',
      );
    }
    await transport.uploadFileBytes(
      bytes: _installRecord(
        app.appId,
        source,
        buildMode: app.buildMode,
        engineFlavor: app.engineFlavor,
      ),
      remotePath: '$stagedApp/install.json',
    );
    await transport.uploadFileBytes(
      bytes: _cooperativeManifestBytes(
        appId: app.appId,
        appName: _manifestAppName(prepared.manifestBytes, app.appId),
      ),
      remotePath: '$stagedEntry/external.manifest.json',
    );
    final _PreparedLayoutFile? icon = prepared.layoutFiles
        .where((file) => file.relativePath.toLowerCase().endsWith('.png'))
        .firstOrNull;
    if (icon != null) {
      await transport.uploadFileBytes(
        bytes: icon.bytes,
        remotePath: '$stagedEntry/icon.png',
      );
    }
    await _run(
      '[ -d ${_q('$stagedApp/bundle')} ] && '
      '[ -f ${_q('$stagedApp/bundle/lib/app.so')} ] && '
      '[ -f ${_q('$stagedApp/manifest.json')} ] && '
      '[ -f ${_q('$stagedApp/install.json')} ] && '
      '[ -f ${_q('$stagedEntry/external.manifest.json')} ]',
      failure: 'staged payload validation failed for ${app.appId}',
    );
    final bool wasRunning = await _commitCooperativeStages(
      appId: app.appId,
      stagedApp: stagedApp,
      stagedEntry: stagedEntry,
    );
    if (wasRunning) {
      await _controlRequest(
        'launch',
        fields: <String, Object?>{
          'appId': app.appId,
          'entryId': _appLoadEntryId(app.appId),
          'replace': true,
        },
      );
    }
  }

  _PreparedCooperativeIntegration _prepareCooperativeIntegration(
    CooperativeIntegrationPayload payload,
    _CooperativeFirmwareProfile profile,
  ) {
    final String firmware = profile.firmwareVersion;
    final String root = payload.rootDirectory;
    if (FileSystemEntity.typeSync(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw DeviceOperationException(
        'cooperative integration payload is missing',
        'Expected a regular directory at $root.',
      );
    }
    final File checksums = File('$root/CHECKSUMS.txt');
    if (FileSystemEntity.typeSync(checksums.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw DeviceOperationException(
        'cooperative integration checksums are missing',
        'Expected ${checksums.path}.',
      );
    }
    final Map<String, String> metadata = <String, String>{};
    final Map<String, String> digests = <String, String>{};
    for (final String line in const LineSplitter().convert(
      checksums.readAsStringSync(),
    )) {
      final RegExpMatch? digest = RegExp(
        r'^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$',
      ).firstMatch(line);
      if (digest != null) {
        final String relative = digest.group(2)!;
        if (digests.containsKey(relative)) {
          throw DeviceOperationException(
            'duplicate cooperative integration checksum',
            relative,
          );
        }
        digests[relative] = digest.group(1)!;
        continue;
      }
      if (line.startsWith('link ') || line.trim().isEmpty) {
        continue;
      }
      final int separator = line.indexOf('=');
      if (separator > 0) {
        final String key = line.substring(0, separator);
        if (metadata.containsKey(key)) {
          throw DeviceOperationException(
            'duplicate cooperative integration metadata',
            key,
          );
        }
        metadata[key] = line.substring(separator + 1);
        continue;
      }
      throw DeviceOperationException(
        'invalid cooperative integration manifest',
        line,
      );
    }
    const Map<String, String> expectedMetadata = <String, String>{
      'schema': '1',
      'target': _cooperativeTarget,
      'xovi': '0.3.3',
      'qrr': 'v19',
      'apploadControlProtocol': '1',
      'hashtab': 'profile-matched',
      'firmwareProfiles': '3.27.3.0,3.28.0.162',
    };
    for (final MapEntry<String, String> expected in expectedMetadata.entries) {
      if (metadata[expected.key] != expected.value) {
        throw DeviceOperationException(
          'cooperative integration metadata mismatch',
          '${expected.key}=${metadata[expected.key]} '
              '(expected ${expected.value}).',
        );
      }
    }
    final Set<String> expectedDigestPaths = <String>{
      ..._commonIntegrationFiles.keys,
      ..._appLoadFirmwareProfiles.values,
      ..._qrrHashtabProfiles.values,
    };
    if (digests.length != expectedDigestPaths.length ||
        !digests.keys.every(expectedDigestPaths.contains)) {
      throw const DeviceOperationException(
        'cooperative integration file set is not exact',
        'Restore the release payload before provisioning.',
      );
    }
    final List<_PreparedIntegrationFile> prepared =
        <_PreparedIntegrationFile>[];
    for (final MapEntry<String, bool> expected
        in _commonIntegrationFiles.entries) {
      final String path = '$root/xovi/${expected.key}';
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw DeviceOperationException(
          'cooperative integration file is missing or unsafe',
          path,
        );
      }
      final Uint8List bytes = File(path).readAsBytesSync();
      final String digest = sha256Bytes(bytes);
      if (bytes.isEmpty || digests[expected.key] != digest) {
        throw DeviceOperationException(
          'cooperative integration checksum mismatch',
          path,
        );
      }
      prepared.add(
        _PreparedIntegrationFile(
          relativePath: expected.key,
          bytes: bytes,
          executable: expected.value,
          digest: digest,
        ),
      );
    }
    final String? profileRelative = _appLoadFirmwareProfiles[firmware];
    if (profileRelative == null) {
      throw DeviceOperationException(
        'firmware has no validated cooperative integration',
        'Detected $firmware. Update Pluto with a device-validated release '
            'profile before provisioning.',
      );
    }
    final String profilePath = '$root/$profileRelative';
    if (FileSystemEntity.typeSync(profilePath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw DeviceOperationException(
        'firmware integration profile is missing or unsafe',
        profilePath,
      );
    }
    final Uint8List profileBytes = File(profilePath).readAsBytesSync();
    final String profileDigest = sha256Bytes(profileBytes);
    if (profileBytes.isEmpty || digests[profileRelative] != profileDigest) {
      throw DeviceOperationException(
        'firmware integration checksum mismatch',
        profilePath,
      );
    }
    prepared.add(
      _PreparedIntegrationFile(
        relativePath: 'extensions.d/appload.so',
        bytes: profileBytes,
        executable: false,
        digest: profileDigest,
      ),
    );
    final String? hashtabRelative = _qrrHashtabProfiles[firmware];
    if (hashtabRelative == null) {
      throw DeviceOperationException(
        'firmware has no validated QRR table',
        'Detected $firmware. Update Pluto with a device-validated release '
            'profile before provisioning.',
      );
    }
    final String hashtabPath = '$root/$hashtabRelative';
    if (FileSystemEntity.typeSync(hashtabPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw DeviceOperationException(
        'firmware QRR table is missing or unsafe',
        hashtabPath,
      );
    }
    final Uint8List hashtabBytes = File(hashtabPath).readAsBytesSync();
    final String hashtabDigest = sha256Bytes(hashtabBytes);
    if (hashtabBytes.isEmpty || digests[hashtabRelative] != hashtabDigest) {
      throw DeviceOperationException(
        'firmware QRR table checksum mismatch',
        hashtabPath,
      );
    }
    prepared.add(
      _PreparedIntegrationFile(
        relativePath: 'exthome/qt-resource-rebuilder/hashtab',
        bytes: hashtabBytes,
        executable: false,
        digest: hashtabDigest,
      ),
    );
    const Map<String, String> links = <String, String>{
      'services/xochitl.service/extensions.d': '/home/root/xovi/extensions.d',
      'services/xochitl.service/exthome': '/home/root/xovi/exthome',
    };
    for (final MapEntry<String, String> link in links.entries) {
      final String path = '$root/xovi/${link.key}';
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.link ||
          Link(path).targetSync() != link.value) {
        throw DeviceOperationException(
          'cooperative integration link is missing or unsafe',
          '$path must point to ${link.value}.',
        );
      }
    }
    final String bundledHashtab =
        '$root/xovi/exthome/qt-resource-rebuilder/hashtab';
    if (FileSystemEntity.typeSync(bundledHashtab, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw DeviceOperationException(
        'release payload contains an unverified firmware table',
        'Remove $bundledHashtab. Provisioning preserves the table already '
            'matched to the connected device.',
      );
    }
    return _PreparedCooperativeIntegration(
      files: prepared,
      hashtabDigest: hashtabDigest,
    );
  }

  Future<_CooperativeFirmwareProfile> _authorizeCooperativeFirmware(
    RemarkableDevice device,
  ) async {
    final _CooperativeFirmwareProfile? profile =
        _cooperativeProfilesByModel[device.model];
    final String? version = device.firmwareVersion;
    if (profile == null ||
        version != profile.firmwareVersion ||
        device.firmwareBuild != profile.firmwareBuild) {
      throw DeviceOperationException(
        'firmware has no validated cooperative integration',
        'Detected ${device.model ?? 'unknown model'}, release '
            '${version ?? 'unknown'}, build '
            '${device.firmwareBuild ?? 'unknown'}. Provisioning requires an '
            'exact model, release, build, and xochitl profile and made no '
            'changes.',
      );
    }
    final CommandResult hash = await transport.exec(
      "sha256sum /usr/bin/xochitl | awk '{print \$1}'",
    );
    if (!hash.isSuccess || hash.stdout.trim() != profile.xochitlDigest) {
      throw DeviceOperationException(
        'xochitl does not match the validated firmware profile',
        '${device.model} release $version build ${profile.firmwareBuild} '
            'requires xochitl ${profile.xochitlDigest}; got '
            '${hash.stdout.trim().isEmpty ? 'unknown' : hash.stdout.trim()}. '
            'No device files were changed.',
      );
    }
    return profile;
  }

  Future<String> _acquireCooperativeActivationLock() async {
    final String token = _nextNonce();
    final CommandResult result = await transport.exec(
      'umask 077; mkdir -p ${_q(runDir)}; '
      'if mkdir ${_q(_integrationLock)} 2>/dev/null; then '
      "printf '%s\\n' ${_q(token)} > ${_q('$_integrationLock/owner')} || { "
      'rmdir ${_q(_integrationLock)} 2>/dev/null; exit 1; }; '
      'else echo "another Pluto integration activation is active" >&2; '
      'exit 75; fi',
    );
    if (!result.isSuccess) {
      throw DeviceOperationException(
        'device integration is already being changed',
        result.stderr.trim().isEmpty
            ? 'Wait for the active provision operation to finish.'
            : result.stderr.trim(),
      );
    }
    return token;
  }

  Future<void> _releaseCooperativeActivationLock(String token) async {
    await transport.exec(
      'owner=${_q('$_integrationLock/owner')}; '
      '[ -f "\$owner" ] && [ ! -L "\$owner" ] && '
      '[ "\$(cat "\$owner")" = ${_q(token)} ] && '
      'rm -rf ${_q(_integrationLock)}',
    );
  }

  Future<_CooperativeActivationState> _preflightCooperativeActivation() async {
    final String temporary = '$_restartLedger.pluto-new';
    final CommandResult result = await transport.exec(
      'set -eu; umask 077; ledger=${_q(_restartLedger)}; '
      'if [ -e "\$ledger" ] || [ -L "\$ledger" ]; then '
      '[ -f "\$ledger" ] && [ ! -L "\$ledger" ] || { '
      'echo "unsafe xochitl restart ledger" >&2; exit 78; }; '
      'else : > "\$ledger"; chmod 0600 "\$ledger"; fi; '
      'now=\$(date +%s); cutoff=\$((now - 600)); '
      ': > ${_q(temporary)}; '
      'while IFS= read -r stamp; do case "\$stamp" in '
      "''|*[!0-9]*) continue ;; esac; "
      '[ "\$stamp" -gt "\$cutoff" ] && '
      "printf '%s\\n' \"\$stamp\" >> ${_q(temporary)} || true; done < \"\$ledger\"; "
      'mv ${_q(temporary)} "\$ledger"; chmod 0600 "\$ledger"; '
      'count=\$(wc -l < "\$ledger" | tr -d "[:space:]"); '
      '[ "\$count" -lt 3 ] || { '
      'echo "xochitl restart capacity is exhausted for this 10-minute window" >&2; '
      'exit 75; }; last=0; [ "\$count" -eq 0 ] || '
      'last=\$(tail -n 1 "\$ledger"); '
      '[ "\$last" -eq 0 ] || [ \$((now - last)) -ge 180 ] || { '
      'echo "xochitl restart gate requires at least 3 minutes between attempts" >&2; '
      'exit 75; }; '
      '[ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ] || { '
      'echo "xochitl must be active before integration activation" >&2; exit 69; }; '
      'pid=\$(systemctl show xochitl.service -p MainPID --value 2>/dev/null); '
      'case "\$pid" in ""|*[!0-9]*|0|1) '
      'echo "xochitl has no valid main pid" >&2; exit 69 ;; esac; '
      'qtfb=absent; control=absent; '
      '[ ! -S /tmp/qtfb.sock ] || '
      'qtfb=\$(stat -c "%d:%i" /tmp/qtfb.sock 2>/dev/null); '
      '[ ! -S ${_q(_appLoadControlSocket)} ] || '
      'control=\$(stat -c "%d:%i" ${_q(_appLoadControlSocket)} 2>/dev/null); '
      "printf 'PLUTO-ACTIVATION-PREFLIGHT|%s|%s|%s\\n' "
      '"\$pid" "\$qtfb" "\$control"',
    );
    final RegExpMatch? match = RegExp(
      r'^PLUTO-ACTIVATION-PREFLIGHT\|([0-9]+)\|([^|\n]+)\|([^|\n]+)$',
    ).firstMatch(result.stdout.trim());
    if (!result.isSuccess || match == null) {
      throw DeviceOperationException(
        'device integration restart preflight failed',
        result.stderr.trim().isEmpty
            ? 'The restart ledger, service state, or socket generation could not be verified.'
            : result.stderr.trim(),
      );
    }
    return (
      pid: match.group(1)!,
      qtfbGeneration: match.group(2)!,
      controlGeneration: match.group(3)!,
    );
  }

  Future<void> _recordCooperativeRestartAttempt() async {
    await _run(
      'set -eu; ledger=${_q(_restartLedger)}; '
      '[ -f "\$ledger" ] && [ ! -L "\$ledger" ]; '
      "printf '%s\\n' \"\$(date +%s)\" >> \"\$ledger\"; "
      'chmod 0600 "\$ledger"; sync',
      failure: 'could not persist the xochitl restart attempt',
    );
  }

  String get _integrationGuard =>
      '$_xoviRoot/services/xochitl.service/'
      '99-pluto-validation-guard.conf';

  static final Uint8List _integrationGuardBytes = Uint8List.fromList(
    utf8.encode(
      '[Unit]\n'
      'OnFailure=\n'
      '\n'
      '[Service]\n'
      'Restart=no\n'
      'RestartMode=normal\n',
    ),
  );

  Future<void> _recoverCooperativeIntegration({
    required String stage,
    required String backup,
  }) async {
    final String files = _integrationFiles.keys.map(_q).join(' ');
    final String links = const <String>[
      'services/xochitl.service/extensions.d',
      'services/xochitl.service/exthome',
    ].map(_q).join(' ');
    await _run(
      'set +e; umount -q /etc/systemd/system/xochitl.service.d '
      '2>/dev/null; systemctl daemon-reload; set -e; '
      'set -e; live=${_q(_xoviRoot)}; backup=${_q(backup)}; '
      'for rel in $files; do rm -f "\$live/\$rel"; '
      'if [ -f "\$backup/files/\$rel" ]; then '
      'mkdir -p "\$live/\${rel%/*}"; '
      'mv "\$backup/files/\$rel" "\$live/\$rel"; fi; done; '
      'for rel in $links; do '
      'if [ -f "\$backup/absent/\$rel" ]; then rm -f "\$live/\$rel"; fi; '
      'done; rm -f ${_q(_integrationGuard)} '
      '${_q('/etc/systemd/system/xochitl.service.d/99-pluto-validation-guard.conf')}; '
      'rm -rf ${_q(stage)} ${_q(backup)}; systemctl daemon-reload; '
      'pending=${_q('$_restartLedger.recovery-required')}; '
      'if [ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ]; '
      'then rm -f "\$pending"; exit 0; fi; '
      'ledger=${_q(_restartLedger)}; now=\$(date +%s); count=99; last=\$now; '
      'if [ -f "\$ledger" ] && [ ! -L "\$ledger" ]; then '
      'count=\$(wc -l < "\$ledger" | tr -d "[:space:]"); '
      '[ "\$count" -eq 0 ] || last=\$(tail -n 1 "\$ledger"); fi; '
      'if [ "\$count" -lt 3 ] && [ \$((now - last)) -ge 180 ]; then '
      "printf '%s\\n' \"\$now\" >> \"\$ledger\"; "
      'systemctl reset-failed xochitl.service 2>/dev/null; '
      'systemctl start xochitl.service; '
      '[ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ]; '
      'rm -f "\$pending"; else : > "\$pending"; chmod 0600 "\$pending"; '
      'echo "stock files restored; restart deferred by the 3-minute safety gate" >&2; '
      'exit 75; fi',
      failure: 'could not restore the stock display session after activation',
    );
  }

  Future<void> _restorePersistentCooperativeIntegration() async {
    final CommandResult saved = await transport.exec(
      '[ -d ${_q(_integrationRollback)} ] && echo saved || echo absent',
    );
    if (saved.stdout.trim() == 'saved') {
      await _recoverCooperativeIntegration(
        stage: '/home/root/.pluto-no-integration-stage',
        backup: _integrationRollback,
      );
      return;
    }
    await _run(
      'systemctl reset-failed xochitl.service 2>/dev/null; '
      'if [ -x ${_q('$_xoviRoot/stock')} ]; then '
      'cd /home/root && bash xovi/stock; else '
      'umount -q /etc/systemd/system/xochitl.service.d 2>/dev/null; '
      'systemctl daemon-reload; systemctl restart xochitl.service; fi; '
      '[ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ]',
      failure: 'could not restore the stock display session',
    );
  }

  Future<String?> _inspectCooperativeDefault() async {
    const String marker = 'PLUTO-DEFAULT-STATE';
    final String root = deviceRoot;
    final String state = '$deviceRoot/state';
    final String live = '$state/default-app';
    final CommandResult result = await transport.exec(
      'set -eu; root=${_q(root)}; state=${_q(state)}; live=${_q(live)}; '
      'if [ ! -e "\$root" ] && [ ! -L "\$root" ]; then '
      "printf '$marker|absent\\n'; exit 0; fi; "
      '[ -d "\$root" ] && [ ! -L "\$root" ] || { '
      'echo "unsafe Pluto runtime root" >&2; exit 78; }; '
      'if [ ! -e "\$state" ] && [ ! -L "\$state" ]; then '
      "printf '$marker|absent\\n'; exit 0; fi; "
      '[ -d "\$state" ] && [ ! -L "\$state" ] || { '
      'echo "unsafe Pluto state directory" >&2; exit 78; }; '
      'if [ ! -e "\$live" ] && [ ! -L "\$live" ]; then '
      "printf '$marker|absent\\n'; exit 0; fi; "
      '[ -f "\$live" ] && [ ! -L "\$live" ] || { '
      'echo "unsafe Pluto default app file" >&2; exit 78; }; '
      'bytes=\$(wc -c < "\$live" | tr -d "[:space:]"); '
      'lines=\$(wc -l < "\$live" | tr -d "[:space:]"); '
      '[ "\$bytes" -gt 0 ] && [ "\$bytes" -le 129 ] '
      '&& [ "\$lines" -eq 1 ] || { '
      'echo "invalid Pluto default app file" >&2; exit 78; }; '
      'app_id=\$(cat "\$live"); '
      "printf '$marker|%s\\n' \"\$app_id\"",
      timeout: const Duration(seconds: 30),
    );
    if (!result.isSuccess) {
      throw DeviceOperationException(
        'could not validate the existing Pluto boot default',
        result.stderr.trim().isEmpty
            ? 'The default-app path was not a safe regular file.'
            : result.stderr.trim(),
      );
    }
    final String response = result.stdout.trim();
    if (response == '$marker|absent') {
      return null;
    }
    final RegExpMatch? match = RegExp(
      '^${RegExp.escape(marker)}\\|(.+)\$',
    ).firstMatch(response);
    final String? appId = match?.group(1);
    if (appId == null || !isSafeAppId(appId)) {
      throw const DeviceOperationException(
        'could not validate the existing Pluto boot default',
        'The default-app file did not contain one safe reverse-DNS app id.',
      );
    }
    return appId;
  }

  Future<_CooperativeDefaultSnapshot> _suppressCooperativeDefault() async {
    final String? appId = await _inspectCooperativeDefault();
    final String root = deviceRoot;
    final String state = '$deviceRoot/state';
    final String live = '$state/default-app';
    final String backup = '$state/.default-app.pluto-old-${_nextNonce()}';
    if (appId == null) {
      await _run(
        'set -eu; root=${_q(root)}; state=${_q(state)}; live=${_q(live)}; '
        'backup=${_q(backup)}; '
        'if [ ! -e "\$root" ] && [ ! -L "\$root" ]; then exit 0; fi; '
        '[ -d "\$root" ] && [ ! -L "\$root" ] || exit 78; '
        'if [ ! -e "\$state" ] && [ ! -L "\$state" ]; then exit 0; fi; '
        '[ -d "\$state" ] && [ ! -L "\$state" ] || exit 78; '
        '[ ! -e "\$backup" ] && [ ! -L "\$backup" ] || exit 78; '
        '[ ! -e "\$live" ] && [ ! -L "\$live" ]',
        failure: 'could not suppress the Pluto boot default safely',
      );
      return (backupPath: backup, appId: null);
    }
    final String entry = _appLoadEntryPath(appId);
    final String manifest = '$entry/external.manifest.json';
    await _run(
      'set -eu; root=${_q(root)}; state=${_q(state)}; live=${_q(live)}; '
      'backup=${_q(backup)}; entry=${_q(entry)}; manifest=${_q(manifest)}; '
      'expected=${_q(appId)}; '
      '[ -d "\$root" ] && [ ! -L "\$root" ] || exit 78; '
      '[ -d "\$state" ] && [ ! -L "\$state" ] || exit 78; '
      '[ -f "\$live" ] && [ ! -L "\$live" ] || exit 78; '
      '[ ! -e "\$backup" ] && [ ! -L "\$backup" ] || exit 78; '
      '[ "\$(wc -l < "\$live" | tr -d "[:space:]")" -eq 1 ] '
      '&& [ "\$(cat "\$live")" = "\$expected" ] || exit 78; '
      '[ -d "\$entry" ] && [ ! -L "\$entry" ] || exit 78; '
      '[ -f "\$manifest" ] && [ ! -L "\$manifest" ] || exit 78; '
      'grep -F -q ${_q('"managed": true')} "\$manifest" '
      '&& grep -F -q ${_q('"appId": "$appId"')} "\$manifest" '
      '&& grep -F -q '
      '${_q('"application": "$deviceRoot/bin/pluto-embedder"')} '
      '"\$manifest" || exit 78; '
      'mv "\$live" "\$backup"',
      failure: 'could not suppress the validated Pluto boot default',
    );
    return (backupPath: backup, appId: appId);
  }

  Future<void> _restoreCooperativeDefault(
    _CooperativeDefaultSnapshot snapshot,
  ) async {
    final String root = deviceRoot;
    final String state = '$deviceRoot/state';
    final String live = '$state/default-app';
    final String backup = snapshot.backupPath;
    final String? appId = snapshot.appId;
    if (appId == null) {
      await _run(
        'set -eu; root=${_q(root)}; state=${_q(state)}; live=${_q(live)}; '
        'backup=${_q(backup)}; '
        'if [ ! -e "\$root" ] && [ ! -L "\$root" ]; then exit 0; fi; '
        '[ -d "\$root" ] && [ ! -L "\$root" ] || exit 78; '
        'if [ ! -e "\$state" ] && [ ! -L "\$state" ]; then exit 0; fi; '
        '[ -d "\$state" ] && [ ! -L "\$state" ] || exit 78; '
        '[ ! -e "\$backup" ] && [ ! -L "\$backup" ] || exit 78; '
        'if [ -e "\$live" ] || [ -L "\$live" ]; then '
        '[ -f "\$live" ] && [ ! -L "\$live" ] || exit 78; '
        'rm -f "\$live"; sync; fi',
        failure: 'could not restore the absent Pluto boot default',
      );
      return;
    }
    await _run(
      'set -eu; root=${_q(root)}; state=${_q(state)}; live=${_q(live)}; '
      'backup=${_q(backup)}; expected=${_q(appId)}; '
      '[ -d "\$root" ] && [ ! -L "\$root" ] || exit 78; '
      '[ -d "\$state" ] && [ ! -L "\$state" ] || exit 78; '
      '[ -f "\$backup" ] && [ ! -L "\$backup" ] || exit 78; '
      '[ "\$(wc -l < "\$backup" | tr -d "[:space:]")" -eq 1 ] '
      '&& [ "\$(cat "\$backup")" = "\$expected" ] || exit 78; '
      'if [ -e "\$live" ] || [ -L "\$live" ]; then '
      '[ -f "\$live" ] && [ ! -L "\$live" ] || exit 78; '
      'rm -f "\$live"; fi; '
      'mv "\$backup" "\$live"; chmod 0600 "\$live"; sync',
      failure: 'could not restore the previous Pluto boot default',
    );
  }

  Future<void> _discardCooperativeDefaultSnapshot(
    _CooperativeDefaultSnapshot snapshot,
  ) async {
    final String? appId = snapshot.appId;
    if (appId == null) {
      return;
    }
    final String state = '$deviceRoot/state';
    await _run(
      'set -eu; state=${_q(state)}; backup=${_q(snapshot.backupPath)}; '
      'expected=${_q(appId)}; '
      '[ -d "\$state" ] && [ ! -L "\$state" ] || exit 78; '
      '[ -f "\$backup" ] && [ ! -L "\$backup" ] || exit 78; '
      '[ "\$(wc -l < "\$backup" | tr -d "[:space:]")" -eq 1 ] '
      '&& [ "\$(cat "\$backup")" = "\$expected" ] || exit 78; '
      'rm -f "\$backup"',
      failure: 'could not finish the Pluto boot-default transaction',
    );
  }

  Future<void> _installCooperativeIntegration(
    _PreparedCooperativeIntegration integration,
    _CooperativeActivationState activationState,
  ) async {
    final String nonce = _nextNonce();
    final String stage = '/home/root/.pluto-xovi-stage-$nonce';
    final String backup = '/home/root/.pluto-xovi-backup-$nonce';
    await _run(
      'rm -rf ${_q(stage)} ${_q(backup)} && '
      'mkdir -p ${_q(stage)} ${_q('$backup/files')} '
      '${_q('$backup/absent')} && chmod 0700 ${_q(backup)}',
      failure: 'could not prepare device integration staging',
    );
    for (final _PreparedIntegrationFile file in integration.files) {
      await transport.uploadFileBytes(
        bytes: file.bytes,
        remotePath: '$stage/${file.relativePath}',
        executable: file.executable,
      );
    }
    final String stagedGuard =
        '$stage/services/xochitl.service/'
        '99-pluto-validation-guard.conf';
    await transport.uploadFileBytes(
      bytes: _integrationGuardBytes,
      remotePath: stagedGuard,
    );
    final String verification = integration.files
        .map(
          (file) =>
              '[ "\$(sha256sum ${_q('$stage/${file.relativePath}')} | '
              'awk \'{print \$1}\')" = ${_q(file.digest)} ]',
        )
        .join(' && ');
    await _run(
      '$verification && [ -f ${_q(stagedGuard)} ] && '
      '[ ! -L ${_q(stagedGuard)} ]',
      failure: 'device integration upload did not match its release checksums',
    );

    final String files = integration.files
        .map((file) => _q(file.relativePath))
        .join(' ');
    final String executables = integration.files
        .where((file) => file.executable)
        .map((file) => _q(file.relativePath))
        .join(' ');
    bool commitStarted = false;
    try {
      commitStarted = true;
      await _run(
        'set -eu; stage=${_q(stage)}; live=${_q(_xoviRoot)}; '
        'backup=${_q(backup)}; guard=${_q(_integrationGuard)}; '
        '[ ! -e "\$guard" ] && [ ! -L "\$guard" ] || { '
        'echo "a previous validation guard is still present" >&2; exit 78; }; '
        'for rel in $files; do dst="\$live/\$rel"; '
        'if [ -e "\$dst" ] || [ -L "\$dst" ]; then '
        '[ -f "\$dst" ] && [ ! -L "\$dst" ] || exit 78; fi; done; '
        'for pair in '
        '${_q('services/xochitl.service/extensions.d:/home/root/xovi/extensions.d')} '
        '${_q('services/xochitl.service/exthome:/home/root/xovi/exthome')}; do '
        'rel=\${pair%%:*}; target=\${pair#*:}; dst="\$live/\$rel"; '
        'if [ -e "\$dst" ] || [ -L "\$dst" ]; then '
        '[ -L "\$dst" ] && [ "\$(readlink "\$dst")" = "\$target" ] '
        '|| exit 78; fi; done; '
        'for rel in $files; do dir=\${rel%/*}; '
        '[ "\$dir" != "\$rel" ] || dir=.; '
        'mkdir -p "\$live/\$dir" "\$backup/files/\$dir" '
        '"\$backup/absent/\$dir"; dst="\$live/\$rel"; '
        'if [ -e "\$dst" ]; then mv "\$dst" "\$backup/files/\$rel"; '
        'else : > "\$backup/absent/\$rel"; fi; '
        'mv "\$stage/\$rel" "\$dst"; chmod 0644 "\$dst"; done; '
        'for rel in $executables; do chmod 0755 "\$live/\$rel"; done; '
        'for pair in '
        '${_q('services/xochitl.service/extensions.d:/home/root/xovi/extensions.d')} '
        '${_q('services/xochitl.service/exthome:/home/root/xovi/exthome')}; do '
        'rel=\${pair%%:*}; target=\${pair#*:}; dst="\$live/\$rel"; '
        'if [ ! -e "\$dst" ] && [ ! -L "\$dst" ]; then '
        'dir=\${rel%/*}; mkdir -p "\$live/\$dir" '
        '"\$backup/absent/\$dir"; : > "\$backup/absent/\$rel"; '
        'ln -s "\$target" "\$dst"; fi; done; '
        'mkdir -p ${_q('$_xoviRoot/scripts/pre-start')} '
        '${_q('$_xoviRoot/scripts/post-start')} '
        '${_q('$_xoviRoot/scripts/pre-stock')} '
        '${_q('$_xoviRoot/scripts/post-stock')} '
        '${_q('$_xoviRoot/exthome/qt-resource-rebuilder')}; '
        'mv ${_q(stagedGuard)} "\$guard"; chmod 0644 "\$guard"; sync',
        failure: 'could not atomically install the device integration',
      );
      await _recordCooperativeRestartAttempt();
      await _run(
        'old_pid=${_q(activationState.pid)}; '
        'old_qtfb=${_q(activationState.qtfbGeneration)}; '
        'old_control=${_q(activationState.controlGeneration)}; '
        'cd /home/root && bash xovi/start; '
        'ready=0; i=0; while [ "\$i" -lt 30 ]; do '
        'if [ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ] '
        '&& [ -S /tmp/qtfb.sock ] '
        '&& [ -S ${_q(_appLoadControlSocket)} ]; then '
        'new_pid=\$(systemctl show xochitl.service -p MainPID --value 2>/dev/null); '
        'new_qtfb=\$(stat -c "%d:%i" /tmp/qtfb.sock 2>/dev/null); '
        'new_control=\$(stat -c "%d:%i" ${_q(_appLoadControlSocket)} 2>/dev/null); '
        'if [ -n "\$new_pid" ] && [ "\$new_pid" != "\$old_pid" ] '
        '&& [ -n "\$new_qtfb" ] && [ "\$new_qtfb" != "\$old_qtfb" ] '
        '&& [ -n "\$new_control" ] '
        '&& [ "\$new_control" != "\$old_control" ]; then '
        'ready=1; break; fi; fi; '
        'i=\$((i + 1)); sleep 1; done; [ "\$ready" -eq 1 ]',
        failure:
            'the matching display integration did not publish a fresh process and sockets',
      );
      await _controlRequest('ping');
      await _run(
        '[ "\$(sha256sum ${_q(_qrrHashtab)} | awk \'{print \$1}\')" = '
        '${_q(integration.hashtabDigest)} ] && '
        'rm -f ${_q(_integrationGuard)} '
        '${_q('/etc/systemd/system/xochitl.service.d/99-pluto-validation-guard.conf')} '
        '&& systemctl daemon-reload && '
        '[ "\$(systemctl is-active xochitl.service 2>/dev/null)" = active ] '
        '&& mkdir -p ${_q('$_xoviRoot/rollback')} '
        '&& chmod 0700 ${_q('$_xoviRoot/rollback')} && '
        'if [ -d ${_q(_integrationRollback)} ]; then rm -rf ${_q(backup)}; '
        'else mv ${_q(backup)} ${_q(_integrationRollback)}; fi; '
        'rm -rf ${_q(stage)}',
        failure: 'device integration validation did not finish safely',
      );
    } on Object {
      if (commitStarted) {
        try {
          await _recoverCooperativeIntegration(stage: stage, backup: backup);
        } on Object {
          // Preserve the activation failure. The guard has already disabled
          // restart escalation, and a tethered reboot returns to stock.
        }
      } else {
        await transport.exec('rm -rf ${_q(stage)} ${_q(backup)}');
      }
      rethrow;
    }
  }

  Future<DeviceOperationResult> _provisionCooperative({
    required List<PayloadFile> runtime,
    required List<_PreparedPayloadApp> apps,
    required _PreparedCooperativeIntegration integration,
    required bool bootDefault,
  }) async {
    final String lockToken = await _acquireCooperativeActivationLock();
    try {
      final _CooperativeActivationState activationState =
          await _preflightCooperativeActivation();
      return await _provisionCooperativeWithLock(
        runtime: runtime,
        apps: apps,
        integration: integration,
        activationState: activationState,
        bootDefault: bootDefault,
      );
    } finally {
      await _releaseCooperativeActivationLock(lockToken);
    }
  }

  Future<DeviceOperationResult> _provisionCooperativeWithLock({
    required List<PayloadFile> runtime,
    required List<_PreparedPayloadApp> apps,
    required _PreparedCooperativeIntegration integration,
    required _CooperativeActivationState activationState,
    required bool bootDefault,
  }) async {
    final List<PayloadFile> forbiddenRuntime = runtime
        .where(
          (PayloadFile file) => !const <String>{
            'bin/pluto-embedder',
            'bin/pluto-apploadctl',
            'bin/codex',
            'engine/release/libflutter_engine.so',
            'engine/release/icudtl.dat',
          }.contains(file.remoteRelative),
        )
        .toList(growable: false);
    if (forbiddenRuntime.isNotEmpty) {
      throw DeviceOperationException(
        'payload contains files that do not belong to this device backend',
        forbiddenRuntime
            .map((PayloadFile file) => file.remoteRelative)
            .join(', '),
      );
    }
    final String probe = '$_appLoadRoot/pluto-probe';
    await _run(
      'if [ -e ${_q(probe)} ] || [ -L ${_q(probe)} ]; then '
      '[ -d ${_q(probe)} ] && [ ! -L ${_q(probe)} ] || exit 78; '
      'manifest=${_q('$probe/external.manifest.json')}; '
      '[ -f "\$manifest" ] && [ ! -L "\$manifest" ] || exit 78; '
      "grep -Eq '\"name\"[[:space:]]*:[[:space:]]*\"Pluto ARMv7 Probe\"' "
      '"\$manifest" || exit 78; '
      "grep -Eq '\"application\"[[:space:]]*:[[:space:]]*\"probe\"' "
      '"\$manifest" || exit 78; rm -rf ${_q(probe)}; fi',
      failure: 'could not remove the known Pluto bring-up probe safely',
    );
    // AppLoad applies default-app shortly after xochitl starts. Keep the old
    // release default off that restart path so it cannot execute while its
    // binary and bundle are being replaced below.
    final _CooperativeDefaultSnapshot defaultSnapshot =
        await _suppressCooperativeDefault();
    var launchRequested = false;
    try {
      await _installCooperativeIntegration(integration, activationState);
      final List<String> layout = <String>[
        'bin',
        'engine/release',
        'launcher',
        'apps',
        'appdata',
        'logs',
        'state',
        'staging',
      ];
      await _run(
        'mkdir -p ${layout.map((String d) => _q('$deviceRoot/$d')).join(' ')}',
        failure: 'could not create the Pluto runtime layout',
      );
      for (final PayloadFile file in runtime) {
        await _uploadFile(file);
      }
      await _run(
        'date -u +%Y-%m-%dT%H:%M:%SZ > ${_q('$deviceRoot/VERSION')}',
        failure: 'could not write $deviceRoot/VERSION',
      );
      for (final _PreparedPayloadApp app in apps) {
        await _stageCooperativeApp(app, source: 'provision');
      }
      await _controlRequest(
        'setDefault',
        fields: <String, Object?>{'appId': bootDefault ? launcherAppId : null},
      );
      if (bootDefault) {
        // The startup timer was deliberately suppressed. Launch the fully
        // promoted Home exactly once through the verified control channel.
        launchRequested = true;
        await _controlRequest(
          'launch',
          fields: <String, Object?>{
            'appId': launcherAppId,
            'entryId': _appLoadEntryId(launcherAppId),
            'replace': true,
          },
        );
      }
      await _discardCooperativeDefaultSnapshot(defaultSnapshot);
      return const DeviceOperationResult(
        ok: true,
        message:
            'Pluto provisioned. The device selected and activated its matching '
            'runtime; use the normal `pluto run`, `logs`, and `screenshot` '
            'commands.',
      );
    } on Object {
      if (launchRequested) {
        // A rejected launch may still have created a child before AppLoad
        // could publish its matching window. Best-effort cleanup prevents
        // that failed generation from surviving the provisioning rollback.
        try {
          await _controlRequest(
            'stopAll',
            fields: const <String, Object?>{'scope': 'pluto'},
          );
        } on Object {
          // Restoring the previous boot default remains the primary rollback
          // invariant even if the failed control generation is unavailable.
        }
      }
      await _restoreCooperativeDefault(defaultSnapshot);
      rethrow;
    }
  }

  /// Provisions the runtime and packaged apps for the verified device.
  ///
  /// [runtime] carries the target-correct embedder, engine, and integration
  /// files. [apps] contains the launcher and application layouts. The concrete
  /// display and lifecycle backend is selected from immutable device metadata;
  /// callers use this same operation for every supported model.
  Future<DeviceOperationResult> provision({
    required List<PayloadFile> runtime,
    required List<PayloadApp> apps,
    required String payloadTarget,
    CooperativeIntegrationPayload? cooperativeIntegration,
    bool bootDefault = true,
  }) async {
    _validatePayloadIdentity(payloadTarget, apps);
    final bool hasDebugEngine = runtime.any(
      (PayloadFile file) =>
          file.remoteRelative == 'engine/debug/libflutter_engine.so' ||
          file.remoteRelative.startsWith('engine/debug/'),
    );
    if (!hasDebugEngine &&
        apps.any(
          (PayloadApp app) =>
              app.buildMode == 'debug' || app.engineFlavor == 'debug',
        )) {
      throw const DeviceOperationException(
        'release-only provisioning cannot include debug apps',
        'Add an explicit debug engine for hot reload, or provision only '
            'profile/release AOT apps.',
      );
    }
    final List<_PreparedPayloadApp> preparedApps = <_PreparedPayloadApp>[
      for (final PayloadApp app in apps) _prepareApp(app),
    ];
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      if (payloadTarget != _cooperativeTarget) {
        _validateCooperativeRuntimeDevice(
          device,
          operation: 'platform provision',
          requireInstalledIntegration: false,
        );
        throw DeviceOperationException(
          'payload target does not match the connected device',
          'Expected $_cooperativeTarget, got $payloadTarget. No device files '
              'were changed.',
        );
      }
      _validateCooperativeRuntimeDevice(
        device,
        operation: 'platform provision',
        requireInstalledIntegration: false,
      );
      if (hasDebugEngine ||
          apps.any(
            (PayloadApp app) =>
                app.buildMode != 'release' || app.engineFlavor != 'release',
          )) {
        throw const DeviceOperationException(
          'this device requires release AOT apps',
          'Provision a release payload; debug and profile content was '
              'rejected before any device files were changed.',
        );
      }
      if (cooperativeIntegration == null) {
        throw const DeviceOperationException(
          'cooperative integration payload is missing',
          'Rebuild the release payload before provisioning.',
        );
      }
      final _CooperativeFirmwareProfile profile =
          await _authorizeCooperativeFirmware(device);
      final _PreparedCooperativeIntegration preparedIntegration =
          _prepareCooperativeIntegration(cooperativeIntegration, profile);
      return _provisionCooperative(
        runtime: runtime,
        apps: preparedApps,
        integration: preparedIntegration,
        bootDefault: bootDefault,
      );
    }
    if (payloadTarget != _directTarget) {
      _validateDirectRuntimeDevice(device, operation: 'platform provision');
      throw DeviceOperationException(
        'payload target does not match the connected device',
        'Expected $_directTarget, got $payloadTarget. No device files were '
            'changed.',
      );
    }
    _validateDirectRuntimeDevice(device, operation: 'platform provision');
    final List<String> layout = <String>[
      'bin',
      'engine',
      'engine/profile',
      'engine/release',
      'launcher',
      'apps',
      'appdata',
      'logs',
      'state',
      'staging',
    ];
    await _run(
      'mkdir -p ${layout.map((String d) => _q('$deviceRoot/$d')).join(' ')}',
      failure: 'could not create $deviceRoot layout',
    );
    for (final PayloadFile file in runtime) {
      await _uploadFile(file);
    }
    // The provisioned marker `pluto devices --probe` looks for.
    await _run(
      'date -u +%Y-%m-%dT%H:%M:%SZ > ${_q('$deviceRoot/VERSION')}',
      failure: 'could not write $deviceRoot/VERSION',
    );
    for (final _PreparedPayloadApp app in preparedApps) {
      await _stageApp(app, source: 'provision');
    }
    if (!hasDebugEngine) {
      await _removeStaleDebugState();
    }
    if (bootDefault) {
      await _run(
        'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} install',
        failure: 'boot-first install failed',
      );
      return const DeviceOperationResult(
        ok: true,
        message:
            'Pluto provisioned; the launcher (not reMarkable) owns the '
            'panel on normal boots; the peer A/B root remains stock for '
            'recovery. Reboot the device to switch now, or run '
            '`pluto provision --status` to inspect.',
      );
    }
    await _run(
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} uninstall',
      failure: 'removing the Pluto boot override failed',
    );
    return const DeviceOperationResult(
      ok: true,
      message:
          'Pluto runtime staged; any existing boot override was removed, '
          'so stock UI boots by default.',
    );
  }

  /// Reports provisioned boot state.
  Future<String> provisionStatus() async {
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'status');
      final Map<String, Object?> status = await _controlRequest('status');
      final CommandResult marker = await transport.exec(
        '[ -f ${_q('$deviceRoot/VERSION')} ] && echo provisioned || '
        'echo not-provisioned',
      );
      return '${marker.stdout.trim()} ${jsonEncode(status)}';
    }
    _validateDirectRuntimeDevice(device, operation: 'status');
    final CommandResult result = await transport.exec(
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} status '
      '2>/dev/null || echo "not provisioned"',
    );
    return result.stdout.trim();
  }

  /// Restores stock xochitl as the boot default but keeps the Pluto runtime
  /// installed (undo of boot-first; `pluto provision --restore-remarkable`).
  Future<DeviceOperationResult> restoreStockBoot() async {
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'restore');
      await _controlRequest(
        'stopAll',
        fields: const <String, Object?>{'scope': 'pluto'},
      );
      await _controlRequest(
        'setDefault',
        fields: const <String, Object?>{'appId': null},
      );
      return const DeviceOperationResult(
        ok: true,
        message:
            'Stock reMarkable is active. Pluto remains installed and can be '
            'started again with `pluto run`.',
      );
    }
    _validateDirectRuntimeDevice(device, operation: 'restore');
    await _run(
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} uninstall',
      failure: 'restoring the stock boot default failed',
    );
    return const DeviceOperationResult(
      ok: true,
      message:
          'Stock reMarkable UI restored as the boot default. The Pluto '
          'runtime is still installed; re-run `pluto provision` to make it '
          'boot first again.',
    );
  }

  /// Fully removes Pluto (runtime, boot override) and restores stock
  /// xochitl.
  Future<DeviceOperationResult> uninstallSystem() async {
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'system uninstall');
      await _controlRequest('ping');
      await _controlRequest(
        'stopAll',
        fields: const <String, Object?>{'scope': 'pluto'},
      );
      final String backup = '/home/root/.pluto-uninstall-${_nextNonce()}';
      await _run(
        'rm -rf ${_q(backup)} && mkdir -p ${_q(backup)}; '
        'for entry in ${_q(_appLoadRoot)}/pluto-*; do '
        '[ -d "\$entry" ] && [ ! -L "\$entry" ] || continue; '
        'manifest="\$entry/external.manifest.json"; '
        '[ -f "\$manifest" ] && [ ! -L "\$manifest" ] || continue; '
        "grep -Eq '\"managed\"[[:space:]]*:[[:space:]]*true' "
        '"\$manifest" || continue; '
        'mv "\$entry" ${_q(backup)}/ || exit 1; done',
        failure: 'could not stage Pluto integration removal',
      );
      try {
        await _controlRequest('reload');
      } on Object {
        await _run(
          'for entry in ${_q(backup)}/*; do [ -e "\$entry" ] || continue; '
          'mv "\$entry" ${_q(_appLoadRoot)}/ || exit 1; done',
          failure: 'could not roll back Pluto integration removal',
        );
        try {
          await _controlRequest('reload');
        } on Object {
          // The files are restored. Preserve the original reload failure.
        }
        rethrow;
      }
      await _restorePersistentCooperativeIntegration();
      await _run('rm -rf ${_q(deviceRoot)} ${_q(backup)}');
      return const DeviceOperationResult(
        ok: true,
        message: 'Pluto removed; stock reMarkable remains active.',
      );
    }
    _validateDirectRuntimeDevice(device, operation: 'system uninstall');
    final String uninstaller = '$deviceRoot/bin/pluto-uninstall.sh';
    await _run(
      'if [ -x ${_q(uninstaller)} ]; then '
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(uninstaller)} --yes; '
      'elif [ -x ${_q(_bootInstall)} ]; then '
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} uninstall || '
      'exit \$?; '
      'rm -rf ${_q(deviceRoot)} || exit 1; '
      'systemctl reset-failed xochitl.service 2>/dev/null || true; '
      'systemctl restart xochitl.service 2>/dev/null || true; '
      'else '
      // Without an authoritative A/B-aware script, only clean the live-slot
      // override. A peer-slot override may remain, so preserve the runtime and
      // fail loudly instead of leaving that override pointing at deleted files.
      'mount -o remount,rw / 2>/dev/null || true; '
      'rm -f /usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf '
      '2>/dev/null || true; '
      'rmdir /usr/lib/systemd/system/xochitl.service.d 2>/dev/null || true; '
      'sync; mount -o remount,ro / 2>/dev/null; '
      'systemctl daemon-reload 2>/dev/null || true; '
      'echo "authoritative Pluto uninstall scripts are missing; '
      'runtime preserved because a peer-slot boot override may remain" >&2; '
      'exit 1; fi',
      failure: 'system uninstall failed',
    );
    return const DeviceOperationResult(
      ok: true,
      message: 'Pluto removed; stock reMarkable UI restored as boot default.',
    );
  }

  /// Installs one app directory into the on-device registry.
  Future<DeviceOperationResult> installApp({
    required String appId,
    required String bundleDir,
    required String buildMode,
    required String engineFlavor,
    String? manifestPath,
  }) async {
    await _stageApp(
      _prepareApp(
        PayloadApp(
          appId: appId,
          bundleDir: bundleDir,
          buildMode: buildMode,
          engineFlavor: engineFlavor,
          target: 'linux-arm64',
        ),
        manifestPath: manifestPath,
      ),
      source: 'install-app',
    );
    await _notifyAppsChanged();
    return DeviceOperationResult(
      ok: true,
      message: 'Installed $appId into the launcher registry.',
    );
  }

  void _validatePayloadIdentity(String payloadTarget, List<PayloadApp> apps) {
    if (!const <String>{
      _directTarget,
      _cooperativeTarget,
    }.contains(payloadTarget)) {
      throw DeviceOperationException(
        'unsupported payload target: $payloadTarget',
        'Expected $_directTarget or $_cooperativeTarget.',
      );
    }
    final PayloadApp? mismatch = apps
        .where((PayloadApp app) => app.target != payloadTarget)
        .firstOrNull;
    if (mismatch != null) {
      throw DeviceOperationException(
        'payload contains mixed build targets',
        '${mismatch.appId} targets ${mismatch.target}, while the runtime '
            'targets $payloadTarget.',
      );
    }
  }

  Future<RemarkableDevice> _probeWriteTarget() async {
    if (!await transport.canConnect()) {
      throw const DeviceOperationException(
        'device unreachable',
        'SSH connection to the device failed',
      );
    }
    return DeviceProbe(transport: transport).probe(
      id: transport.endpoint.id,
      name: transport.endpoint.id,
      allowHostnameFallback: false,
    );
  }

  void _validateDirectRuntimeDevice(
    RemarkableDevice device, {
    required String operation,
  }) {
    final String? model = device.model;
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      throw DeviceOperationException(
        'payload target does not match the connected device',
        'Detected $model at ${transport.endpoint.sshTarget}. '
            '$operation requires a $_cooperativeTarget payload on this '
            'device. No device files were changed.',
      );
    }
    if (device.runtimeBackend != PlutoRuntimeBackend.direct) {
      throw DeviceOperationException(
        'device model is not supported for $operation',
        'Detected ${model ?? 'an unknown model'} at '
            '${transport.endpoint.sshTarget}. A write-authorizing model must '
            'come from SoC or device-tree metadata; hostname is not trusted. '
            'No device files were changed.',
      );
    }
    final String? architecture = device.architecture;
    if (architecture == null ||
        !_directTargetArchitectures.contains(architecture)) {
      throw DeviceOperationException(
        '$_directTarget does not match device architecture',
        'The direct runtime cannot run on '
            '${architecture ?? 'an unknown architecture'} ($model). No '
            'device files were changed.',
      );
    }
  }

  void _validateCooperativeRuntimeDevice(
    RemarkableDevice device, {
    required String operation,
    bool requireInstalledIntegration = true,
  }) {
    final String? model = device.model;
    if (device.runtimeBackend == PlutoRuntimeBackend.direct) {
      throw DeviceOperationException(
        'payload target does not match the connected device',
        'Detected $model at ${transport.endpoint.sshTarget}. '
            '$operation requires a $_directTarget payload on this device. '
            'No device files were changed.',
      );
    }
    if (device.runtimeBackend != PlutoRuntimeBackend.cooperative) {
      throw DeviceOperationException(
        'device model is not supported for $operation',
        'Detected ${model ?? 'an unknown model'} at '
            '${transport.endpoint.sshTarget}. A write-authorizing model must '
            'come from SoC or device-tree metadata; hostname is not trusted. '
            'No device files were changed.',
      );
    }
    final String? architecture = device.architecture;
    if (architecture == null ||
        !_cooperativeTargetArchitectures.contains(architecture)) {
      throw DeviceOperationException(
        '$_cooperativeTarget does not match device architecture',
        'The runtime cannot run on '
            '${architecture ?? 'an unknown architecture'} ($model). No '
            'device files were changed.',
      );
    }
    if (requireInstalledIntegration &&
        (!device.xoviAvailable || !device.appLoadAvailable)) {
      throw const DeviceOperationException(
        'Pluto device integration is not ready',
        'The managed device integration is missing. Run `pluto provision` to '
            'install the matching integration; no app files were changed.',
      );
    }
  }

  String _appLoadEntryName(String appId) => 'pluto-$appId';

  String _appLoadEntryId(String appId) =>
      'external::${_appLoadEntryName(appId)}';

  String _appLoadEntryPath(String appId) =>
      '$_appLoadRoot/${_appLoadEntryName(appId)}';

  Uint8List _cooperativeManifestBytes({
    required String appId,
    required String appName,
  }) {
    final String appRoot = appId == launcherAppId
        ? '$deviceRoot/launcher'
        : '$deviceRoot/apps/$appId';
    final String appRunDir = appId == launcherAppId
        ? runDir
        : '$runDir/apps/$appId';
    return Uint8List.fromList(
      utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'name': appName,
          'application': '$deviceRoot/bin/pluto-embedder',
          'workingDirectory': appRoot,
          'qtfb': true,
          'aspectRatio': 'auto',
          'disablesWindowedMode': true,
          'pluto': <String, Object?>{'schema': 1, 'managed': true, 'appId': appId},
          'environment': <String, String>{'PLUTO_APP_ID': appId, 'PLUTO_APPS_DIR': '$deviceRoot/apps', 'PLUTO_DATA_DIR': '$deviceRoot/appdata', 'PLUTO_CONFIG_DIR': '$deviceRoot/state/launcher-config', 'PLUTO_RUN_DIR': appRunDir, if (appId == 'dev.pluto.codex') 'PAPER_CODEX_BIN': '$deviceRoot/bin/codex'},
          'args': <String>['--release', '--bundle=$appRoot/bundle', '--aot-elf=$appRoot/bundle/lib/app.so', '--engine=$deviceRoot/engine/release/libflutter_engine.so', '--icu-data=$deviceRoot/engine/release/icudtl.dat', '--presenter=qtfb', '--presenter-options=profile=legacy', '--run-dir=$appRunDir', '--touch', '--pen', '--rotation=0', '--allowed-rotations=0'],
        })}\n',
      ),
    );
  }

  String _manifestAppName(Uint8List manifestBytes, String appId) {
    final Object? decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is Map<String, Object?>) {
      final Object? name = decoded['name'];
      if (name is String && name.trim().isNotEmpty) {
        return name.trim();
      }
    }
    return appId;
  }

  Future<Map<String, Object?>> _controlRequest(
    String action, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    return _controlRequestUsing(
      action,
      fields: fields,
      client: _cooperativeControlClient,
      fallbackClient: _xoviControlClient,
      socket: _appLoadControlSocket,
      controlName: 'AppLoad',
    );
  }

  Future<Map<String, Object?>> _embedderControlRequest(
    String action, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    return _controlRequestUsing(
      action,
      fields: fields,
      client: _cooperativeControlClient,
      socket: _embedderControlSocket,
      controlName: 'embedder',
    );
  }

  Future<Map<String, Object?>> _controlRequestUsing(
    String action, {
    required Map<String, Object?> fields,
    required String client,
    String? fallbackClient,
    required String socket,
    required String controlName,
  }) async {
    final String requestId = _nextNonce();
    final String request = jsonEncode(<String, Object?>{
      'schema': 1,
      'requestId': requestId,
      'action': action,
      ...fields,
    });
    final String command =
        'client=${_q(client)}; '
        '${fallbackClient == null ? '' : '[ -x "\$client" ] || client=${_q(fallbackClient)}; '}'
        '[ -x "\$client" ] || { '
        'echo ${_q('missing Pluto $controlName control client')} >&2; '
        'exit 69; }; '
        '[ -S ${_q(socket)} ] || { '
        'echo ${_q('Pluto $controlName control socket is unavailable')} >&2; '
        'exit 69; }; '
        '"\$client" --socket ${_q(socket)} '
        '--request ${_q(request)}';
    final CommandResult response = await transport.exec(
      command,
      timeout: const Duration(seconds: 30),
    );
    if (!response.isSuccess) {
      throw DeviceOperationException(
        'Pluto device control request failed: $action',
        response.stderr.isNotEmpty ? response.stderr : response.stdout,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.stdout.trim());
    } on FormatException catch (error) {
      throw DeviceOperationException(
        'invalid Pluto device control response',
        error.message,
      );
    }
    if (decoded is! Map<String, Object?> ||
        decoded['schema'] != 1 ||
        decoded['requestId'] != requestId ||
        decoded['ok'] is! bool) {
      throw DeviceOperationException(
        'invalid Pluto device control response',
        'The Pluto $controlName control response did not match the request '
            'envelope.',
      );
    }
    if (decoded['ok'] != true) {
      final Object? error = decoded['error'];
      throw DeviceOperationException(
        'Pluto device control rejected $action',
        error is Map<String, Object?>
            ? '${error['code'] ?? 'error'}: ${error['message'] ?? ''}'
            : '$error',
      );
    }
    final Object? result = decoded['result'];
    return result is Map<String, Object?> ? result : const <String, Object?>{};
  }

  Future<int> _directForegroundPid() async {
    final String executable = '$deviceRoot/bin/pluto-embedder';
    final CommandResult result = await transport.exec(
      'pid=\$(cat ${_q('$runDir/embedder.pid')} 2>/dev/null || true); '
      'case "\$pid" in ""|*[!0-9]*) exit 66 ;; esac; '
      '[ "\$pid" -gt 0 ] 2>/dev/null || exit 66; '
      'exe=\$(readlink "/proc/\$pid/exe" 2>/dev/null || true); '
      'case "\$exe" in '
      '${_q(executable)}|${_q('$executable (deleted)')}) ;; '
      '*) exit 66 ;; esac; '
      "printf 'PLUTO-FOREGROUND-PID|%s\\n' \"\$pid\"",
    );
    final RegExpMatch? match = RegExp(
      r'^PLUTO-FOREGROUND-PID\|([1-9][0-9]*)$',
      multiLine: true,
    ).firstMatch(result.stdout);
    final int? pid = match == null ? null : int.tryParse(match.group(1)!);
    if (!result.isSuccess || pid == null) {
      throw DeviceOperationException(
        'screenshot unavailable',
        result.stderr.isNotEmpty
            ? result.stderr
            : 'The foreground Pluto embedder could not be identified.',
      );
    }
    return pid;
  }

  bool _isTrustedScreenshotPath(Object? path) {
    return path is String &&
        RegExp(
          '^${RegExp.escape(runDir)}/screenshots/'
          r'[A-Za-z0-9._-]+\.png$',
        ).hasMatch(path);
  }

  _DirectScreenshotCapture _validateDirectScreenshotCapture(
    Map<String, Object?> capture, {
    required String path,
    required String? requestedAppId,
    required String requestedSurface,
    required int expectedPid,
  }) {
    final Object? rawBytes = capture['bytes'];
    final Object? rawDigest = capture['sha256'];
    final Object? rawAppId = capture['appId'];
    final Object? rawPid = capture['pid'];
    final Object? rawSurface = capture['surface'];
    final Object? rawWidth = capture['width'];
    final Object? rawHeight = capture['height'];
    final Object? rawStride = capture['stride'];
    final Object? rawFormat = capture['format'];
    final int? bytesPerPixel = switch (rawFormat) {
      'gray8' => 1,
      'rgb565' => 2,
      'xrgb8888' => 4,
      _ => null,
    };
    if (rawBytes is! int ||
        rawBytes < 1 ||
        rawDigest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawDigest) ||
        rawAppId is! String ||
        !isSafeAppId(rawAppId) ||
        (requestedAppId != null && rawAppId != requestedAppId) ||
        rawPid is! int ||
        rawPid != expectedPid ||
        rawSurface is! String ||
        rawSurface != requestedSurface ||
        rawWidth is! int ||
        rawWidth < 1 ||
        rawHeight is! int ||
        rawHeight < 1 ||
        rawStride is! int ||
        rawFormat is! String ||
        bytesPerPixel == null ||
        rawStride < rawWidth * bytesPerPixel) {
      throw const DeviceOperationException(
        'invalid Pluto screenshot response',
        'The embedder returned unsafe or inconsistent screenshot metadata.',
      );
    }
    return (
      path: path,
      byteCount: rawBytes,
      digest: rawDigest,
      appId: rawAppId,
      pid: rawPid,
      surface: rawSurface,
      width: rawWidth,
      height: rawHeight,
      stride: rawStride,
      format: rawFormat,
    );
  }

  void _validatePngDimensions(
    Uint8List bytes, {
    required int width,
    required int height,
  }) {
    const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    bool signatureMatches = bytes.length >= signature.length;
    for (
      int index = 0;
      signatureMatches && index < signature.length;
      index += 1
    ) {
      signatureMatches = bytes[index] == signature[index];
    }
    if (bytes.length < 24 || !signatureMatches) {
      throw const DeviceOperationException(
        'invalid screenshot data',
        'The screenshot artifact does not have a PNG signature.',
      );
    }
    final ByteData header = ByteData.sublistView(bytes);
    if (header.getUint32(8, Endian.big) != 13 ||
        header.getUint32(12, Endian.big) != 0x49484452) {
      throw const DeviceOperationException(
        'invalid screenshot data',
        'The screenshot artifact does not begin with a PNG IHDR chunk.',
      );
    }
    final int pngWidth = header.getUint32(16, Endian.big);
    final int pngHeight = header.getUint32(20, Endian.big);
    if (pngWidth != width || pngHeight != height) {
      throw DeviceOperationException(
        'screenshot dimensions do not match',
        'The PNG is ${pngWidth}x$pngHeight, while the embedder reported '
            '${width}x$height.',
      );
    }
  }

  Uint8List? _packageIconBytes(PlapArchive archive) {
    final Object? rawPath = archive.manifest['icon'];
    if (rawPath == null) {
      return null;
    }
    if (rawPath is! String || !_isSafeLayoutPath(rawPath)) {
      throw DeviceOperationException(
        'unsafe icon path for ${archive.appId}',
        'The package icon must be a safe relative path.',
      );
    }
    final PlapEntry? entry = readTarEntries(
      archive.tarBytes,
    ).where((PlapEntry entry) => entry.path == rawPath).firstOrNull;
    if (entry == null) {
      throw DeviceOperationException(
        'missing icon for ${archive.appId}',
        'Expected $rawPath in the package.',
      );
    }
    return entry.bytes;
  }

  Future<DeviceOperationResult> _installCooperativePackage(
    PlapArchive archive,
    String plapPath, {
    required bool force,
    required bool launch,
    required bool setDefault,
  }) async {
    final String appId = archive.appId;
    await _controlRequest('ping');
    final String liveApp = '$deviceRoot/apps/$appId';
    final String liveEntry = _appLoadEntryPath(appId);
    if (!force) {
      final CommandResult check = await transport.exec(
        'if [ -e ${_q(liveApp)} ] || [ -L ${_q(liveApp)} ] || '
        '[ -e ${_q(liveEntry)} ] || [ -L ${_q(liveEntry)} ]; then '
        'echo exists; else echo absent; fi',
      );
      if (check.stdout.trim() == 'exists') {
        throw DeviceOperationException(
          '$appId is already installed',
          'Pass --force to replace it.',
        );
      }
    }
    final String nonce = _nextNonce();
    final String stagedApp = '$deviceRoot/apps/.$appId.pluto-new-$nonce';
    final String stagedEntry =
        '$_appLoadRoot/.${_appLoadEntryName(appId)}.pluto-new-$nonce';
    final String upload = '$deviceRoot/staging/.upload-$appId.$nonce.tar';
    await _run(
      'mkdir -p ${_q('$deviceRoot/apps')} '
      '${_q('$deviceRoot/staging')} ${_q(_appLoadRoot)} && '
      'rm -rf ${_q(stagedApp)} ${_q(stagedEntry)} && '
      'mkdir -p ${_q(stagedApp)} ${_q(stagedEntry)}',
    );
    await transport.uploadFileBytes(
      bytes: archive.tarBytes,
      remotePath: upload,
    );
    await _run(
      'tar -C ${_q(stagedApp)} -xf ${_q(upload)} && rm -f ${_q(upload)}',
      failure: 'could not extract package on device',
    );
    await transport.uploadFileBytes(
      bytes: _installRecord(
        appId,
        plapPath.split(Platform.pathSeparator).last,
        buildMode: archive.buildMode,
        engineFlavor: archive.engineFlavor,
        sizeBytes: archive.tarBytes.length,
        payload: archive.payloadHashes,
      ),
      remotePath: '$stagedApp/install.json',
    );
    final Object? rawName = archive.manifest['name'];
    await transport.uploadFileBytes(
      bytes: _cooperativeManifestBytes(
        appId: appId,
        appName: rawName is String && rawName.trim().isNotEmpty
            ? rawName.trim()
            : appId,
      ),
      remotePath: '$stagedEntry/external.manifest.json',
    );
    final Uint8List? icon = _packageIconBytes(archive);
    if (icon != null) {
      await transport.uploadFileBytes(
        bytes: icon,
        remotePath: '$stagedEntry/icon.png',
      );
    }
    await _run(
      '[ -f ${_q('$stagedApp/manifest.json')} ] && '
      '[ -f ${_q('$stagedApp/bundle/lib/app.so')} ] && '
      '[ -f ${_q('$stagedApp/install.json')} ] && '
      '[ -f ${_q('$stagedEntry/external.manifest.json')} ]',
      failure: 'staged payload validation failed for $appId',
    );
    final bool wasRunning = await _commitCooperativeStages(
      appId: appId,
      stagedApp: stagedApp,
      stagedEntry: stagedEntry,
    );
    final List<String> extras = <String>[];
    if (setDefault) {
      await _controlRequest(
        'setDefault',
        fields: <String, Object?>{'appId': appId},
      );
      extras.add('set as default');
    }
    if (launch || wasRunning) {
      await _controlRequest(
        'launch',
        fields: <String, Object?>{
          'appId': appId,
          'entryId': _appLoadEntryId(appId),
          'replace': true,
        },
      );
      if (launch) {
        extras.add('launching');
      }
    }
    final String suffix = extras.isEmpty ? '' : ' (${extras.join(', ')})';
    return DeviceOperationResult(ok: true, message: 'Installed $appId$suffix.');
  }

  /// Installs a packaged `.plap` app: opens it on the host, streams the tar
  /// to device staging, and commits it through the install transaction.
  ///
  /// [force] replaces an already-installed app; [setDefault] makes the app
  /// the supervisor's boot-default; [launch] asks the running supervisor to
  /// switch to the app now.
  Future<DeviceOperationResult> installPackage(
    String plapPath, {
    bool force = false,
    bool launch = false,
    bool setDefault = false,
    String? expectedFlutterVersion,
    String? expectedEngineCommit,
  }) async {
    final PlapArchive archive = await PlapArchive.read(plapPath);
    if ((expectedFlutterVersion != null &&
            archive.flutterVersion != expectedFlutterVersion) ||
        (expectedEngineCommit != null &&
            archive.engineCommit != expectedEngineCommit)) {
      throw DeviceOperationException(
        'package toolchain does not match this checkout',
        'Package uses Flutter ${archive.flutterVersion}, engine '
            '${archive.engineCommit}; expected '
            '${expectedFlutterVersion ?? archive.flutterVersion}, '
            '${expectedEngineCommit ?? archive.engineCommit}.',
      );
    }
    if (setDefault &&
        (archive.buildMode == 'debug' || archive.engineFlavor == 'debug')) {
      throw const DeviceOperationException(
        'a debug app cannot be the boot default',
        'JIT is reserved for an explicit hot-reload session. Install without '
            '--set-default, or package a profile/release AOT build.',
      );
    }
    final String appId = archive.appId;
    if (appId == launcherAppId) {
      throw const DeviceOperationException(
        'the launcher cannot be installed as an app',
        'Use `pluto provision` to update the launcher.',
      );
    }
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'app install');
      if (archive.target != _cooperativeTarget) {
        throw DeviceOperationException(
          'package target does not match the connected device',
          'Expected $_cooperativeTarget, got ${archive.target}. No device '
              'files were changed.',
        );
      }
      if (archive.buildMode != 'release' || archive.engineFlavor != 'release') {
        throw const DeviceOperationException(
          'this device requires a release AOT package',
          'Build and install the app with --release.',
        );
      }
      return _installCooperativePackage(
        archive,
        plapPath,
        force: force,
        launch: launch,
        setDefault: setDefault,
      );
    }
    if (archive.target != _directTarget) {
      _validateDirectRuntimeDevice(device, operation: 'app install');
      throw DeviceOperationException(
        'package target does not match the connected device',
        'Expected $_directTarget, got ${archive.target}. No device files '
            'were changed.',
      );
    }
    _validateDirectRuntimeDevice(device, operation: 'direct app install');
    if (!force) {
      final CommandResult check = await transport.exec(
        '[ -d ${_q('$deviceRoot/apps/$appId')} ] && echo exists || echo absent',
      );
      if (check.stdout.trim() == 'exists') {
        throw DeviceOperationException(
          '$appId is already installed',
          'Pass --force to replace it.',
        );
      }
    }
    final String nonce = DateTime.now().millisecondsSinceEpoch.toRadixString(
      36,
    );
    final String stageDir = '$deviceRoot/staging/$appId.$nonce';
    final String tarPath = '$deviceRoot/staging/.upload-$appId.$nonce.tar';
    await _run(
      'mkdir -p ${_q('$deviceRoot/staging')} '
      '${_q('$deviceRoot/state')}',
    );
    await transport.uploadFileBytes(
      bytes: archive.tarBytes,
      remotePath: tarPath,
    );
    await _run(
      'rm -rf ${_q(stageDir)} && mkdir -p ${_q(stageDir)} && '
      'tar -C ${_q(stageDir)} -xf ${_q(tarPath)} && rm -f ${_q(tarPath)}',
      failure: 'could not extract package on device',
    );
    await transport.uploadFileBytes(
      bytes: _installRecord(
        appId,
        plapPath.split(Platform.pathSeparator).last,
        buildMode: archive.buildMode,
        engineFlavor: archive.engineFlavor,
        sizeBytes: archive.tarBytes.length,
        payload: archive.payloadHashes,
      ),
      remotePath: '$stageDir/install.json.pending',
    );
    await _run(
      'PLUTO_ROOT=${_q(deviceRoot)} PLUTO_RUN_DIR=${_q(runDir)} '
      'sh ${_q(_transaction)} commit '
      '${_q(appId)} ${_q(nonce)}',
      failure: 'install transaction failed for $appId',
    );
    await _notifyAppsChanged();
    final List<String> extras = <String>[];
    if (setDefault) {
      await _run(
        "printf '%s\\n' ${_q(appId)} > ${_q('$deviceRoot/state/default-app')}",
        failure: 'could not set the default app',
      );
      extras.add('set as boot default');
    }
    if (launch) {
      await _requestLaunch(appId);
      extras.add('launching');
    }
    final String suffix = extras.isEmpty ? '' : ' (${extras.join(', ')})';
    return DeviceOperationResult(ok: true, message: 'Installed $appId$suffix.');
  }

  /// Removes one app from the registry.
  Future<DeviceOperationResult> uninstallApp(
    String appId, {
    bool purgeData = false,
  }) async {
    if (!isSafeAppId(appId)) {
      throw DeviceOperationException(
        'invalid app id for uninstall',
        '$appId is not a reverse-DNS app id.',
      );
    }
    if (appId == launcherAppId) {
      throw const DeviceOperationException(
        'the launcher cannot be uninstalled as an app',
        'Use `pluto provision --uninstall` to remove the platform.',
      );
    }
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'app uninstall');
      await _controlRequest('ping');
      final Map<String, Object?> stop = await _controlRequest(
        'stop',
        fields: <String, Object?>{'appId': appId},
      );
      final String liveApp = appId == launcherAppId
          ? '$deviceRoot/launcher'
          : '$deviceRoot/apps/$appId';
      final String liveEntry = _appLoadEntryPath(appId);
      final String nonce = _nextNonce();
      final String appBackup = '$liveApp.pluto-remove-$nonce';
      final String entryBackup = '$liveEntry.pluto-remove-$nonce';
      await _run(
        'rm -rf ${_q(appBackup)} ${_q(entryBackup)}; '
        '[ ! -e ${_q(liveApp)} ] && [ ! -L ${_q(liveApp)} ] || '
        'mv ${_q(liveApp)} ${_q(appBackup)} || exit 1; '
        '[ ! -e ${_q(liveEntry)} ] && [ ! -L ${_q(liveEntry)} ] || '
        'mv ${_q(liveEntry)} ${_q(entryBackup)} || { '
        '[ ! -e ${_q(appBackup)} ] || mv ${_q(appBackup)} ${_q(liveApp)}; '
        'exit 1; }',
        failure: 'could not stage uninstall of $appId',
      );
      try {
        await _controlRequest('reload');
      } on Object {
        await _run(
          '[ ! -e ${_q(appBackup)} ] || '
          'mv ${_q(appBackup)} ${_q(liveApp)}; '
          '[ ! -e ${_q(entryBackup)} ] || '
          'mv ${_q(entryBackup)} ${_q(liveEntry)}',
          failure: 'could not roll back uninstall of $appId',
        );
        try {
          await _controlRequest('reload');
          if (stop['stopped'] == true) {
            await _controlRequest(
              'launch',
              fields: <String, Object?>{
                'appId': appId,
                'entryId': _appLoadEntryId(appId),
                'replace': true,
              },
            );
          }
        } on Object {
          // The disk state is restored; preserve the initial reload failure.
        }
        rethrow;
      }
      await _run('rm -rf ${_q(appBackup)} ${_q(entryBackup)}');
      if (purgeData) {
        await _run('rm -rf ${_q('$deviceRoot/appdata/$appId')}');
      }
      return DeviceOperationResult(ok: true, message: 'Uninstalled $appId.');
    }
    _validateDirectRuntimeDevice(device, operation: 'app uninstall');
    await _stopInstalledApp(appId);
    await _run('rm -rf ${_q('$deviceRoot/apps/$appId')}');
    if (purgeData) {
      await transport.exec(
        'rm -rf ${_q('$deviceRoot/appdata/$appId')} 2>/dev/null',
      );
    }
    // Drop the boot default if it pointed at the removed app.
    await transport.exec(
      'if [ "\$(cat ${_q('$deviceRoot/state/default-app')} 2>/dev/null)" = '
      '${_q(appId)} ]; then rm -f ${_q('$deviceRoot/state/default-app')}; fi',
    );
    await _notifyAppsChanged();
    return DeviceOperationResult(ok: true, message: 'Uninstalled $appId.');
  }

  /// Streams device logs (the current embedder log + the boot hook log).
  Future<String> logs({
    int lines = 200,
    String? appId,
    bool includeSystem = false,
    String since = '10m',
    bool json = false,
  }) async {
    if (lines < 1 || lines > 100000) {
      throw DeviceOperationException('invalid log line count', '$lines');
    }
    if (appId != null &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(appId)) {
      throw DeviceOperationException('invalid app id for logs', appId);
    }
    final String journalFormat = json ? ' -o json' : '';
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'logs');
      final String appLog = appId == null
          ? 'for log in ${_q('$deviceRoot/logs')}/*.log; do '
                '[ -f "\$log" ] || continue; echo "--- \$log ---"; '
                'tail -n $lines "\$log"; done'
          : 'log=${_q('$deviceRoot/logs/$appId.log')}; '
                '[ ! -f "\$log" ] || tail -n $lines "\$log"';
      final CommandResult result = await transport.exec(
        'journalctl -u xochitl.service --since ${_q(since)} -n $lines '
        '--no-pager$journalFormat 2>/dev/null; '
        'echo "--- Pluto app logs ---"; '
        '$appLog'
        '${includeSystem ? '; echo "--- system ---"; journalctl -u swupdate.service --since ${_q(since)} -n $lines --no-pager$journalFormat 2>/dev/null; journalctl -k --since ${_q(since)} -n $lines --no-pager$journalFormat 2>/dev/null' : ''}',
      );
      return result.stdout;
    }
    _validateDirectRuntimeDevice(device, operation: 'logs');
    final String appLog = appId == null
        ? 'tail -n $lines ${_q('$deviceRoot/logs/current.log')} 2>/dev/null; '
              'echo "--- boot-hook ---"; '
              'tail -n $lines ${_q('$deviceRoot/logs/boot-hook.log')} '
              '2>/dev/null'
        : 'tail -n $lines ${_q('$deviceRoot/logs/$appId.log')} 2>/dev/null';
    final CommandResult result = await transport.exec(
      '$appLog'
      '${includeSystem ? '; echo "--- system ---"; journalctl -u xochitl.service -u swupdate.service --since ${_q(since)} -n $lines --no-pager$journalFormat 2>/dev/null; journalctl -k --since ${_q(since)} -n $lines --no-pager$journalFormat 2>/dev/null' : ''}',
    );
    return result.stdout;
  }

  /// Captures the running app's renderer-owned surface as PNG bytes.
  ///
  /// Geometry and source format come from the live renderer. This proves the
  /// requested software pixels, not the panel's final optical pigment state.
  Future<Uint8List> screenshot({
    String? appId,
    String surface = 'logical',
  }) async {
    if (appId != null && !isSafeAppId(appId)) {
      throw DeviceOperationException(
        'invalid app id for screenshot',
        '$appId is not a reverse-DNS app id.',
      );
    }
    if (!const <String>{'logical', 'post-dither'}.contains(surface)) {
      throw DeviceOperationException('unsupported screenshot surface', surface);
    }
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'screenshot');
      final Map<String, Object?> capture = await _controlRequest(
        'screenshot',
        fields: <String, Object?>{'appId': appId, 'surface': surface},
      );
      final Object? rawPath = capture['path'];
      final Object? rawBytes = capture['bytes'];
      final Object? rawDigest = capture['sha256'];
      if (rawPath is! String ||
          !RegExp(
            r'^/run/pluto/screenshots/[A-Za-z0-9._-]+\.png$',
          ).hasMatch(rawPath) ||
          rawBytes is! int ||
          rawBytes < 1 ||
          rawDigest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawDigest)) {
        throw const DeviceOperationException(
          'invalid Pluto screenshot response',
          'The AppLoad integration returned unsafe screenshot metadata.',
        );
      }
      final String trustedPath = rawPath;
      try {
        final CommandResult preflight = await transport.exec(
          '[ -f ${_q(trustedPath)} ] && [ ! -L ${_q(trustedPath)} ] || '
          'exit 66; '
          'actual=\$(wc -c < ${_q(trustedPath)} | tr -d "[:space:]"); '
          '[ "\$actual" = ${_q('$rawBytes')} ] || exit 65',
        );
        if (!preflight.isSuccess) {
          throw DeviceOperationException(
            'screenshot unavailable',
            preflight.stderr.isNotEmpty
                ? preflight.stderr
                : 'The screenshot artifact failed its preflight checks.',
          );
        }
        final Uint8List bytes;
        try {
          bytes = await transport.downloadFileBytes(
            remotePath: trustedPath,
            expectedBytes: rawBytes,
          );
        } on Object catch (error) {
          throw DeviceOperationException(
            'screenshot transfer failed',
            error.toString(),
          );
        }
        if (bytes.length != rawBytes || sha256Bytes(bytes) != rawDigest) {
          throw const DeviceOperationException(
            'screenshot integrity check failed',
            'The captured PNG changed while it was transferred.',
          );
        }
        return bytes;
      } finally {
        await transport.exec('rm -f ${_q(trustedPath)} 2>/dev/null || true');
      }
    }
    _validateDirectRuntimeDevice(device, operation: 'screenshot');
    final int foregroundPid = await _directForegroundPid();
    final Map<String, Object?> capture = await _embedderControlRequest(
      'screenshot',
      fields: <String, Object?>{'appId': appId, 'surface': surface},
    );
    final Object? rawPath = capture['path'];
    if (!_isTrustedScreenshotPath(rawPath)) {
      throw const DeviceOperationException(
        'invalid Pluto screenshot response',
        'The embedder returned an unsafe screenshot artifact path.',
      );
    }
    final String trustedPath = rawPath! as String;
    try {
      final _DirectScreenshotCapture metadata =
          _validateDirectScreenshotCapture(
            capture,
            path: trustedPath,
            requestedAppId: appId,
            requestedSurface: surface,
            expectedPid: foregroundPid,
          );
      final String pidFile = '$runDir/embedder.pid';
      final CommandResult preflight = await transport.exec(
        'artifact=${_q(metadata.path)}; '
        'current=\$(cat ${_q(pidFile)} 2>/dev/null || true); '
        '[ "\$current" = ${_q('${metadata.pid}')} ] || { '
        'echo ${_q('foreground Pluto embedder changed before screenshot transfer')} >&2; '
        'exit 67; }; '
        '[ -f "\$artifact" ] && [ ! -L "\$artifact" ] || { '
        'echo ${_q('screenshot artifact is not a regular file')} >&2; '
        'exit 66; }; '
        'actual=\$(wc -c < "\$artifact" | tr -d "[:space:]"); '
        '[ "\$actual" = ${_q('${metadata.byteCount}')} ] || { '
        'echo ${_q('screenshot artifact length changed')} >&2; exit 65; }',
      );
      if (!preflight.isSuccess) {
        throw DeviceOperationException(
          'screenshot unavailable',
          preflight.stderr.isNotEmpty
              ? preflight.stderr
              : 'The screenshot artifact failed its preflight checks.',
        );
      }
      final Uint8List bytes;
      try {
        bytes = await transport.downloadFileBytes(
          remotePath: metadata.path,
          expectedBytes: metadata.byteCount,
        );
      } on Object catch (error) {
        throw DeviceOperationException(
          'screenshot transfer failed',
          error.toString(),
        );
      }
      final CommandResult postflight = await transport.exec(
        'current=\$(cat ${_q(pidFile)} 2>/dev/null || true); '
        '[ "\$current" = ${_q('${metadata.pid}')} ] || { '
        'echo ${_q('foreground Pluto embedder changed during screenshot transfer')} >&2; '
        'exit 67; }',
      );
      if (!postflight.isSuccess) {
        throw DeviceOperationException(
          'screenshot unavailable',
          postflight.stderr.isNotEmpty
              ? postflight.stderr
              : 'The foreground renderer changed during transfer.',
        );
      }
      if (bytes.length != metadata.byteCount ||
          sha256Bytes(bytes) != metadata.digest) {
        throw const DeviceOperationException(
          'screenshot integrity check failed',
          'The captured PNG changed while it was transferred.',
        );
      }
      _validatePngDimensions(
        bytes,
        width: metadata.width,
        height: metadata.height,
      );
      return bytes;
    } finally {
      await transport.exec('rm -f ${_q(trustedPath)} 2>/dev/null || true');
    }
  }

  /// Explicitly authorizes one debug/JIT launch of [appId] and forwards its
  /// Dart VM service so the host toolchain can hot reload/restart. Returns the
  /// local forwarded VM service URI.
  Future<Uri> runDebugApp({
    required String appId,
    int vmServicePort = 38383,
  }) async {
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'debug launch');
      throw const DeviceOperationException(
        'debug mode is unavailable for this installed runtime',
        'Install and run the app with --release.',
      );
    }
    _validateDirectRuntimeDevice(device, operation: 'debug launch');
    await _requestDebugLaunch(appId);
    final PortForwardHandle handle = await transport.forwardPort(
      hostPort: vmServicePort,
      devicePort: vmServicePort,
      successPattern: RegExp('.'),
    );
    return Uri.parse('http://127.0.0.1:${handle.hostPort}/');
  }

  /// Launches an AOT app without opening a Dart VM-service tunnel.
  ///
  /// Profile and release applications are selected by their installed
  /// manifest/record on the device supervisor. They must never enter the JIT
  /// attach path used by [runDebugApp].
  Future<void> launchAotApp({required String appId}) async {
    final RemarkableDevice device = await _probeWriteTarget();
    if (device.runtimeBackend == PlutoRuntimeBackend.cooperative) {
      _validateCooperativeRuntimeDevice(device, operation: 'app launch');
      await _controlRequest(
        'launch',
        fields: <String, Object?>{
          'appId': appId,
          'entryId': _appLoadEntryId(appId),
          'replace': true,
        },
      );
      return;
    }
    _validateDirectRuntimeDevice(device, operation: 'app launch');
    await _requestLaunch(appId);
  }

  /// Returns the installed runtime mode selected by the device supervisor.
  Future<String> installedBuildMode(String appId) async {
    final String appDir = appId == launcherAppId
        ? '$deviceRoot/launcher'
        : '$deviceRoot/apps/$appId';
    final CommandResult result = await transport.exec(
      'd=${_q(appDir)}; '
      r'''if [ ! -d "$d/bundle" ]; then echo missing;
elif grep -q '"buildMode"[[:space:]]*:[[:space:]]*"profile"' "$d/install.json" 2>/dev/null; then echo profile;
elif grep -q '"buildMode"[[:space:]]*:[[:space:]]*"release"' "$d/install.json" 2>/dev/null; then echo release;
elif grep -q '"buildMode"[[:space:]]*:[[:space:]]*"debug"' "$d/install.json" 2>/dev/null; then echo debug;
elif [ -f "$d/bundle/lib/app.so" ] || [ -f "$d/bundle/app.so" ]; then echo release;
elif [ -f "$d/bundle/flutter_assets/kernel_blob.bin" ]; then echo debug;
else echo unknown; fi''',
    );
    final String mode = result.stdout.trim();
    if (!result.isSuccess ||
        !const <String>{'debug', 'profile', 'release'}.contains(mode)) {
      throw DeviceOperationException(
        'cannot determine installed mode for $appId',
        mode == 'missing'
            ? 'Install the app first.'
            : 'The installed manifest/record is incomplete.',
      );
    }
    return mode;
  }

  /// Attaches to an already-running app's VM service by forwarding its port.
  Future<Uri> attachApp({int vmServicePort = 38383}) async {
    final PortForwardHandle handle = await transport.forwardPort(
      hostPort: vmServicePort,
      devicePort: vmServicePort,
      successPattern: RegExp('.'),
    );
    return Uri.parse('http://127.0.0.1:${handle.hostPort}/');
  }

  /// Scans the device for stale Pluto artifacts; deletes them when [apply]
  /// is true. [keepBackups] preserves `bin/*.bak-*` binaries.
  Future<CleanupReport> cleanup({
    bool apply = false,
    bool keepBackups = false,
  }) async {
    final CommandResult result = await transport.exec(
      _cleanupScript(apply: apply, keepBackups: keepBackups),
      timeout: const Duration(seconds: 120),
    );
    if (!result.isSuccess) {
      throw DeviceOperationException(
        'cleanup scan failed',
        result.stderr.isNotEmpty ? result.stderr : result.stdout,
      );
    }
    final List<CleanupItem> items = <CleanupItem>[];
    for (final String line in const LineSplitter().convert(result.stdout)) {
      if (!line.startsWith('PLUTO-CLEAN|')) {
        continue;
      }
      final List<String> parts = line.split('|');
      if (parts.length < 4) {
        continue;
      }
      items.add(
        CleanupItem(
          category: parts[1],
          sizeKb: int.tryParse(parts[2]) ?? 0,
          path: parts.sublist(3).join('|'),
        ),
      );
    }
    return CleanupReport(items: items, applied: apply);
  }

  /// BusyBox-ash cleanup script. Emits one `PLUTO-CLEAN|category|kb|path`
  /// line per artifact; deletes each one immediately after emitting when
  /// APPLY=1 (no plan/apply divergence).
  String _cleanupScript({required bool apply, required bool keepBackups}) {
    final String root = _q(deviceRoot);
    return '''
ROOT=$root; APPLY=${apply ? 1 : 0}; KEEP_BAK=${keepBackups ? 1 : 0}
emit() {
  sz=\$(du -sk "\$2" 2>/dev/null | cut -f1); [ -n "\$sz" ] || sz=0
  printf 'PLUTO-CLEAN|%s|%s|%s\\n' "\$1" "\$sz" "\$2"
  [ "\$APPLY" != 1 ] || rm -rf "\$2"
}
# Logs from before the current boot (mtime not newer than PID 1).
[ ! -d "\$ROOT/logs" ] || find "\$ROOT/logs" -name '*.log' ! -newer /proc/1 2>/dev/null | while read -r f; do
  emit stale-log "\$f"
done
# App dirs without a manifest (broken/interrupted installs).
for d in "\$ROOT/apps"/*; do
  [ -d "\$d" ] || continue
  [ -f "\$d/manifest.json" ] || emit orphaned-app "\$d"
done
# SWTCON probe artifacts.
for f in /tmp/swtcon_probe*; do
  [ -e "\$f" ] || continue
  emit swtcon-probe "\$f"
done
# Backup binaries left by manual bin swaps.
if [ "\$KEEP_BAK" = 0 ]; then
  for f in "\$ROOT/bin"/*.bak-*; do
    [ -e "\$f" ] || continue
    emit bin-backup "\$f"
  done
fi
# Staging leftovers (interrupted install transactions).
for f in "\$ROOT/staging"/* "\$ROOT/staging"/.[!.]*; do
  [ -e "\$f" ] || continue
  emit staging "\$f"
done
true
''';
  }

  Future<void> _requestLaunch(String appId) async {
    await _run(
      'mkdir -p ${_q(runDir)} && '
      "printf '%s\\n' ${_q(appId)} > ${_q('$runDir/launch')}",
      failure: 'could not request launch of $appId',
    );
  }

  Future<void> _requestDebugLaunch(String appId) async {
    final String pending = '$runDir/.debug-launch.pluto-new-';
    await _run(
      'mkdir -p ${_q(runDir)} && umask 077 && '
      'tmp=${_q(pending)}\$\$ && '
      "printf '%s\\n' ${_q(appId)} > \"\$tmp\" && "
      'chmod 0600 "\$tmp" && '
      'rm -f ${_q('$runDir/launch')} && '
      'mv -f "\$tmp" ${_q('$runDir/debug-launch')}',
      failure: 'could not authorize debug launch of $appId',
    );
    await _nudgeCurrentEmbedder();
  }

  /// Ends the exact embedder child for a one-shot debug/JIT launch.
  ///
  /// A `/proc` executable check prevents a stale/reused PID from being
  /// signalled. The short KILL fallback keeps app handoffs bounded if a native
  /// shutdown path wedges; normal exits receive TERM and complete cleanly.
  /// Release/profile launches deliberately do not use this path: the session
  /// supervisor owns their USR1, exact-color handoff, acknowledgement, and
  /// warm-process stop transaction. Killing that child after publishing the
  /// launch marker can tear it down after the bundle is saved but before its
  /// hibernation marker is published.
  Future<void> _nudgeCurrentEmbedder() async {
    final String executable = '$deviceRoot/bin/pluto-embedder';
    final String pidFile = '$runDir/embedder.pid';
    await transport.exec(
      'pid=\$(cat ${_q(pidFile)} 2>/dev/null || true); '
      'case "\$pid" in ""|*[!0-9]*) pid="" ;; esac; '
      'if [ -z "\$pid" ]; then '
      'for proc in /proc/[0-9]*; do '
      'candidate=\${proc#/proc/}; '
      'exe=\$(readlink "\$proc/exe" 2>/dev/null || true); '
      'case "\$exe" in ${_q(executable)}|${_q('$executable (deleted)')}) '
      'pid="\$candidate"; break ;; esac; done; fi; '
      'if [ -n "\$pid" ]; then '
      'exe=\$(readlink "/proc/\$pid/exe" 2>/dev/null || true); '
      'case "\$exe" in ${_q(executable)}|${_q('$executable (deleted)')}) '
      'kill -TERM "\$pid" 2>/dev/null || true; '
      'i=0; while kill -0 "\$pid" 2>/dev/null && [ "\$i" -lt 10 ]; do '
      'sleep 0.1; i=\$((i + 1)); done; '
      'if kill -0 "\$pid" 2>/dev/null; then '
      'exe=\$(readlink "/proc/\$pid/exe" 2>/dev/null || true); '
      'case "\$exe" in ${_q(executable)}|${_q('$executable (deleted)')}) '
      'kill -KILL "\$pid" 2>/dev/null || true ;; esac; fi ;; esac; fi; '
      'true',
    );
  }

  Future<void> _notifyAppsChanged() async {
    await transport.exec(
      'touch ${_q('$deviceRoot/state/apps-changed')} 2>/dev/null',
    );
  }
}

/// Raised when a device operation fails.
final class DeviceOperationException implements Exception {
  /// Creates an exception with a [message] and device [detail].
  const DeviceOperationException(this.message, this.detail);

  /// Short summary.
  final String message;

  /// Device-side detail (stderr/stdout).
  final String detail;

  @override
  String toString() => 'DeviceOperationException: $message\n$detail';
}
