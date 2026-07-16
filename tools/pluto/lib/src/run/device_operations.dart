import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

import '../artifacts/checksums.dart';
import '../artifacts/host_metadata.dart';
import '../build/plap_reader.dart';
import '../device/device_probe.dart';
import '../device/remarkable_device.dart';
import '../process.dart';
import '../ssh/device_transport.dart';
import '../ssh/dropbear_transport.dart' show shellQuote;

typedef _ScreenshotCapture = ({
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

bool _hasExactKeys(Map<String, Object?> value, Set<String> expected) =>
    value.length == expected.length &&
    value.keys.every((String key) => expected.contains(key));

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

/// Profile-selected release routing and boot policy for one device.
final class NativeRuntimeSelection {
  /// Creates an immutable selection from an exact hardware profile.
  const NativeRuntimeSelection({
    required this.target,
    required this.profileId,
    required this.bootDefaultEnabled,
  });

  /// Native release slice selected by immutable identity.
  final String target;

  /// Generated hardware profile id used for the decision.
  final String profileId;

  /// Whether this profile has passed the complete boot-default recovery gate.
  final bool bootDefaultEnabled;
}

final class _PreparedLayoutFile {
  const _PreparedLayoutFile({required this.relativePath, required this.bytes});

  final String relativePath;
  final Uint8List bytes;
}

final class _PreparedPayloadFile {
  const _PreparedPayloadFile({required this.file, required this.bytes});

  final PayloadFile file;
  final Uint8List bytes;
}

const String _buildMetadataFileName = 'build-metadata.json';

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

  /// Kind of artifact (stale-log, orphaned-app, bin-backup, staging).
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
///   logs/      current.log and per-app logs
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

  static const Set<String> _supportedTargets = <String>{
    'linux-arm',
    'linux-arm64',
  };
  static const Map<String, Set<String>> _targetArchitectures =
      <String, Set<String>>{
        'linux-arm': <String>{'armv7', 'armv7l'},
        'linux-arm64': <String>{'aarch64', 'arm64'},
      };

  /// SSH transport to the device.
  final DeviceTransport transport;

  /// Root directory on the device that holds the Pluto runtime.
  final String deviceRoot;

  /// Supervisor control directory on the device.
  final String runDir;

  int _nonceCounter = 0;

  String get _bootInstall => '$deviceRoot/bin/pluto-boot-install.sh';

  String get _oneShotSession => '$deviceRoot/bin/pluto-session-once.sh';

  String get _releaseStore => '$deviceRoot.releases';

  String get _dataRoot => '$deviceRoot.data';

  String get _transaction => '$deviceRoot/bin/pluto-install-transaction.sh';

  String get _appControl => '$deviceRoot/bin/pluto-app-control.sh';

  String get _controlClient => '$deviceRoot/bin/pluto-controlctl';

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

  /// Probes immutable hardware identity and returns the native target slice.
  /// Public commands use this to select artifacts without exposing a second
  /// provisioning or lifecycle flow.
  Future<String> runtimeTarget() async {
    return (await runtimeSelection()).target;
  }

  /// Probes immutable identity once and returns release plus boot policy.
  Future<NativeRuntimeSelection> runtimeSelection() async {
    final RemarkableDevice device = await _probeWriteTarget();
    _validateNativeRuntimeDevice(device, operation: 'runtime selection');
    final profile = device.profile!;
    return NativeRuntimeSelection(
      target: device.buildTarget!,
      profileId: profile.id,
      bootDefaultEnabled: profile.runtime.recovery.bootDefaultEnabled,
    );
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

  List<_PreparedPayloadFile> _prepareRuntime(List<PayloadFile> runtime) {
    final Set<String> paths = <String>{};
    final List<_PreparedPayloadFile> prepared = <_PreparedPayloadFile>[];
    for (final PayloadFile file in runtime) {
      if (!_isSafeLayoutPath(file.remoteRelative) ||
          !const <String>{
            'bin',
            'engine',
            'share',
          }.contains(file.remoteRelative.split('/').first)) {
        throw DeviceOperationException(
          'unsafe runtime path: ${file.remoteRelative}',
          'Runtime files must use a unique relative path below bin, engine, '
              'or share.',
        );
      }
      if (!paths.add(file.remoteRelative)) {
        throw DeviceOperationException(
          'duplicate runtime path: ${file.remoteRelative}',
          'A complete release cannot contain two files at one destination.',
        );
      }
      if (FileSystemEntity.typeSync(file.localPath, followLinks: false) !=
          FileSystemEntityType.file) {
        throw DeviceOperationException(
          'missing regular runtime file: ${file.localPath}',
          'Provision only complete, regular release inputs.',
        );
      }
      try {
        prepared.add(
          _PreparedPayloadFile(
            file: file,
            bytes: Uint8List.fromList(File(file.localPath).readAsBytesSync()),
          ),
        );
      } on FileSystemException catch (error) {
        throw DeviceOperationException(
          'could not read runtime file: ${file.localPath}',
          error.message,
        );
      }
    }
    if (!paths.contains('bin/pluto-release-activate.sh')) {
      throw const DeviceOperationException(
        'release activation helper is missing',
        'Every provisionable release must include '
            'bin/pluto-release-activate.sh so the runtime and all apps become '
            'visible through one atomic commit.',
      );
    }
    return List<_PreparedPayloadFile>.unmodifiable(prepared);
  }

  Future<void> _uploadReleaseFile(
    _PreparedPayloadFile prepared, {
    required String releaseRoot,
  }) async {
    final PayloadFile file = prepared.file;
    final String target = '$releaseRoot/${file.remoteRelative}';
    final String parent = target.substring(0, target.lastIndexOf('/'));
    await _run(
      'mkdir -p ${_q(parent)}',
      failure: 'could not prepare ${file.remoteRelative} in the candidate',
    );
    await transport.uploadFileBytes(
      bytes: prepared.bytes,
      remotePath: target,
      executable: file.executable,
    );
    final String mode = file.executable ? '0755' : '0644';
    await _run(
      '[ -f ${_q(target)} ] && [ ! -L ${_q(target)} ] && '
      'chmod $mode ${_q(target)}',
      failure:
          'could not validate candidate runtime file ${file.remoteRelative}',
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
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'appId': appId, 'installedAt': DateTime.now().toUtc().toIso8601String(), 'installedBy': 'pluto 0.1.0', 'source': source, 'buildMode': buildMode, 'engineFlavor': engineFlavor, 'sizeBytes': sizeBytes, 'payload': payload})}\n',
      ),
    );
  }

  _PreparedPayloadApp _prepareApp(PayloadApp app, {String? manifestPath}) {
    _rejectHostMetadata(app);
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
    final AppManifest parsedManifest;
    try {
      manifestBytes = Uint8List.fromList(manifest.readAsBytesSync());
      final Result<AppManifest, ManifestError> result = AppManifest.decode(
        utf8.decode(manifestBytes),
      );
      final AppManifest? value = result.valueOrNull;
      if (value == null) {
        throw DeviceOperationException(
          'invalid manifest for ${app.appId}',
          result.errorOrNull!.message,
        );
      }
      parsedManifest = value;
    } on FileSystemException catch (error) {
      throw DeviceOperationException(
        'could not read manifest for ${app.appId}',
        error.message,
      );
    }
    if (parsedManifest.id.value != app.appId) {
      throw DeviceOperationException(
        'manifest identity does not match ${app.appId}',
        'The canonical manifest declares ${parsedManifest.id.value}.',
      );
    }
    final File buildMetadata = File(
      '${manifest.parent.path}/$_buildMetadataFileName',
    );
    if (FileSystemEntity.typeSync(buildMetadata.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw DeviceOperationException(
        'missing build metadata for ${app.appId}',
        'Expected a regular layout file at ${buildMetadata.path}.',
      );
    }
    final List<_PreparedLayoutFile> layoutFiles = <_PreparedLayoutFile>[];
    try {
      layoutFiles.add(
        _PreparedLayoutFile(
          relativePath: _buildMetadataFileName,
          bytes: Uint8List.fromList(buildMetadata.readAsBytesSync()),
        ),
      );
    } on FileSystemException catch (error) {
      throw DeviceOperationException(
        'could not read build metadata for ${app.appId}',
        error.message,
      );
    }
    final Set<String> seen = <String>{_buildMetadataFileName};
    for (final (String, String) icon in <(String, String)>[
      ('icon', parsedManifest.icon),
      if (parsedManifest.iconMono != null)
        ('iconMono', parsedManifest.iconMono!),
    ]) {
      final String field = icon.$1;
      final String value = icon.$2;
      if (!_isSafeLayoutPath(value)) {
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

  void _rejectHostMetadata(PayloadApp app) {
    final Directory bundle = Directory(app.bundleDir);
    try {
      for (final FileSystemEntity entity in bundle.listSync(
        recursive: true,
        followLinks: false,
      )) {
        final String relative = entity.path
            .substring(bundle.path.length)
            .replaceAll('\\', '/');
        if (isHostMetadataPath(relative)) {
          throw DeviceOperationException(
            'bundle for ${app.appId} contains host metadata',
            'Remove $relative before provisioning. Pluto payloads cannot '
                'contain .DS_Store, .AppleDouble, or AppleDouble ._* files.',
          );
        }
      }
    } on FileSystemException catch (error) {
      throw DeviceOperationException(
        'could not inspect bundle for ${app.appId}',
        error.message,
      );
    }
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

  Future<void> _uploadReleaseApp(
    _PreparedPayloadApp prepared, {
    required String releaseRoot,
  }) async {
    final PayloadApp app = prepared.app;
    final String remote = app.appId == launcherAppId
        ? '$releaseRoot/launcher'
        : '$releaseRoot/apps/${app.appId}';
    await _run(
      'mkdir -p ${_q(remote)}',
      failure: 'could not prepare ${app.appId} in the candidate release',
    );
    await transport.uploadDirectory(
      localPath: app.bundleDir,
      remotePath: '$remote/bundle',
    );
    await transport.uploadFileBytes(
      bytes: prepared.manifestBytes,
      remotePath: '$remote/manifest.json',
    );
    for (final _PreparedLayoutFile file in prepared.layoutFiles) {
      await transport.uploadFileBytes(
        bytes: file.bytes,
        remotePath: '$remote/${file.relativePath}',
      );
    }
    await transport.uploadFileBytes(
      bytes: _installRecord(
        app.appId,
        'provision',
        buildMode: app.buildMode,
        engineFlavor: app.engineFlavor,
      ),
      remotePath: '$remote/install.json',
    );
    final List<String> requiredPaths = <String>[
      '$remote/bundle',
      '$remote/manifest.json',
      '$remote/install.json',
      for (final _PreparedLayoutFile file in prepared.layoutFiles)
        '$remote/${file.relativePath}',
    ];
    await _run(
      '[ -d ${_q(requiredPaths.first)} ] && '
      '${requiredPaths.skip(1).map((String path) => '[ -f ${_q(path)} ] && [ ! -L ${_q(path)} ]').join(' && ')}',
      failure: 'candidate payload validation failed for ${app.appId}',
    );
  }

  /// Installs the target-selected native runtime and complete app layouts.
  Future<DeviceOperationResult> provision({
    required List<PayloadFile> runtime,
    required List<PayloadApp> apps,
    required String payloadTarget,
    bool bootDefault = true,
  }) async {
    _validatePayloadIdentity(payloadTarget, apps);
    final List<_PreparedPayloadFile> preparedRuntime = _prepareRuntime(runtime);
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
    _validateNativeRuntimeDevice(device, operation: 'platform provision');
    if (payloadTarget != device.buildTarget) {
      throw DeviceOperationException(
        'payload target does not match the connected device',
        'Expected ${device.buildTarget}, got $payloadTarget. No device files '
            'were changed.',
      );
    }
    final bool effectiveBootDefault =
        bootDefault && device.profile!.runtime.recovery.bootDefaultEnabled;
    final bool activateForCurrentBoot =
        bootDefault && !device.profile!.runtime.recovery.bootDefaultEnabled;
    final String nonce = _nextNonce();
    final String stage = '$_releaseStore/.candidate-$nonce';
    final String candidate = '$_releaseStore/$nonce';
    await _run(
      'if [ -e ${_q(deviceRoot)} ] && [ ! -L ${_q(deviceRoot)} ]; then '
      'echo ${_q('$deviceRoot conflicts with the managed release symlink')} >&2; '
      'exit 78; fi',
      failure:
          'runtime root ownership is unsafe; remove or relocate the '
          'conflicting path',
    );
    await _run(
      'mkdir -p ${_q(_releaseStore)} '
      '${<String>['appdata', 'logs', 'state', 'staging', 'shared'].map((String directory) => _q('$_dataRoot/$directory')).join(' ')} && '
      'rm -rf ${_q(stage)} ${_q(candidate)} && '
      'mkdir -p ${<String>['bin', 'engine', 'engine/profile', 'engine/release', 'launcher', 'apps'].map((String directory) => _q('$stage/$directory')).join(' ')} && '
      "printf '%s\\n' ${_q(nonce)} > ${_q('$stage/.pluto-release-owned')} && "
      '${<String>['appdata', 'logs', 'state', 'staging', 'shared'].map((String directory) => 'ln -s ${_q('$_dataRoot/$directory')} ${_q('$stage/$directory')}').join(' && ')}',
      failure: 'could not create the isolated candidate release layout',
    );
    for (final _PreparedPayloadFile file in preparedRuntime) {
      await _uploadReleaseFile(file, releaseRoot: stage);
    }
    for (final _PreparedPayloadApp app in preparedApps) {
      await _uploadReleaseApp(app, releaseRoot: stage);
    }
    await _run(
      'date -u +%Y-%m-%dT%H:%M:%SZ > ${_q('$stage/VERSION')} && '
      'nonregular=\$(find ${<String>['bin', 'engine', 'share', 'launcher', 'apps'].map((String directory) => _q('$stage/$directory')).join(' ')} '
      '! -type d ! -type f -print -quit 2>/dev/null); '
      '[ -z "\$nonregular" ] && mv ${_q(stage)} ${_q(candidate)}',
      failure: 'the complete candidate release failed final validation',
    );
    final String activationMode = effectiveBootDefault
        ? 'persistent'
        : activateForCurrentBoot
        ? 'transient'
        : 'stock';
    await _run(
      'PLUTO_ROOT_LINK=${_q(deviceRoot)} '
      'PLUTO_RELEASES_ROOT=${_q(_releaseStore)} '
      'PLUTO_DATA_ROOT=${_q(_dataRoot)} '
      'PLUTO_RUN_DIR=${_q(runDir)} '
      'sh ${_q('$candidate/bin/pluto-release-activate.sh')} '
      'activate ${_q(candidate)} ${_q(activationMode)}',
      failure:
          'whole-release activation failed; the previous complete release was retained',
    );
    if (effectiveBootDefault) {
      return const DeviceOperationResult(
        ok: true,
        message:
            'Pluto provisioned; the launcher (not reMarkable) owns the '
            'panel on normal boots; the peer A/B root remains stock for '
            'recovery. Reboot the device to switch now, or run '
            '`pluto provision --status` to inspect.',
      );
    }
    if (activateForCurrentBoot) {
      return const DeviceOperationResult(
        ok: true,
        message:
            'Pluto provisioned and active for this boot; the generated '
            'recovery gate keeps stock reMarkable as the next boot default.',
      );
    }
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
    _validateKnownDeviceArchitecture(device, operation: 'status');
    final CommandResult result = await transport.exec(
      'if systemctl is-active --quiet pluto-session-once.service; then '
      'printf "current boot: Pluto active (transient); "; fi; '
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} status '
      '2>/dev/null || echo "not provisioned"',
    );
    return result.stdout.trim();
  }

  /// Restores stock xochitl as the boot default but keeps the Pluto runtime
  /// installed (undo of boot-first; `pluto provision --restore-remarkable`).
  Future<DeviceOperationResult> restoreStockBoot() async {
    final RemarkableDevice device = await _probeWriteTarget();
    _validateKnownDeviceArchitecture(device, operation: 'restore');
    await _run(
      'if systemctl is-active --quiet pluto-session-once.service; then '
      'if [ -x ${_q(_oneShotSession)} ]; then '
      'PLUTO_ROOT=${_q(deviceRoot)} PLUTO_RUN_DIR=${_q(runDir)} '
      'sh ${_q(_oneShotSession)} stop || exit; '
      'else systemctl stop pluto-session-once.service || exit; '
      'systemctl reset-failed xochitl.service 2>/dev/null || true; '
      'systemctl start xochitl.service || exit; fi; fi; '
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(_bootInstall)} uninstall',
      failure: 'restoring the stock boot default failed',
    );
    return const DeviceOperationResult(
      ok: true,
      message:
          'Stock reMarkable UI restored now and as the boot default. The Pluto '
          'runtime is still installed; re-run `pluto provision` to make it '
          'boot first again.',
    );
  }

  /// Fully removes Pluto (runtime, boot override) and restores stock
  /// xochitl.
  Future<DeviceOperationResult> uninstallSystem() async {
    final RemarkableDevice device = await _probeWriteTarget();
    _validateKnownDeviceArchitecture(device, operation: 'system uninstall');
    final String uninstaller = '$deviceRoot/bin/pluto-uninstall.sh';
    await _run(
      'if [ -x ${_q(uninstaller)} ]; then '
      'PLUTO_ROOT=${_q(deviceRoot)} sh ${_q(uninstaller)} --yes; '
      'else '
      'echo "authoritative transactional Pluto uninstaller is missing; '
      'owned release/store/data preserved" >&2; '
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
    final RemarkableDevice device = await _probeWriteTarget();
    _validateNativeRuntimeDevice(device, operation: 'app install');
    await _stageApp(
      _prepareApp(
        PayloadApp(
          appId: appId,
          bundleDir: bundleDir,
          buildMode: buildMode,
          engineFlavor: engineFlavor,
          target: device.buildTarget!,
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
    if (!_supportedTargets.contains(payloadTarget)) {
      throw DeviceOperationException(
        'unsupported payload target: $payloadTarget',
        'Expected one of ${_supportedTargets.join(', ')}.',
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
    return DeviceProbe(
      transport: transport,
    ).probe(id: transport.endpoint.id, name: transport.endpoint.id);
  }

  void _validateNativeRuntimeDevice(
    RemarkableDevice device, {
    required String operation,
  }) {
    _validateKnownDeviceArchitecture(device, operation: operation);
    final profile = device.profile!;
    if (!profile.runtime.nativeSessionEnabled) {
      throw DeviceOperationException(
        'native runtime is not enabled for $operation',
        '${profile.marketingName} has not passed its native-session gate. '
            'No device files were changed.',
      );
    }
    if (device.firmwareVersion != profile.testedOs ||
        device.firmwareBuild != profile.runtime.firmwareBuild) {
      throw DeviceOperationException(
        'firmware does not match the native runtime profile',
        '${profile.marketingName} requires ${profile.testedOs} build '
            '${profile.runtime.firmwareBuild}; detected '
            '${device.firmwareVersion ?? 'unknown'} build '
            '${device.firmwareBuild ?? 'unknown'}. No device files were '
            'changed.',
      );
    }
    if (device.kernelRelease != profile.runtime.kernelRelease) {
      throw DeviceOperationException(
        'kernel release does not match the native runtime profile',
        '${profile.marketingName} requires kernel '
            '${profile.runtime.kernelRelease}; detected '
            '${device.kernelRelease ?? 'unknown'}. No device files were '
            'changed.',
      );
    }
  }

  // Restore/status/uninstall must remain available after a firmware drift or
  // a profile gate is closed. The on-device boot installer performs its own
  // fail-closed recovery validation; the host only proves model and ABI here.
  void _validateKnownDeviceArchitecture(
    RemarkableDevice device, {
    required String operation,
  }) {
    final profile = device.profile;
    if (profile == null) {
      throw DeviceOperationException(
        'device model is not supported for $operation',
        'Detected ${device.model ?? 'an unknown model'} at '
            '${transport.endpoint.sshTarget}. A write-authorizing model must '
            'come from SoC or device-tree metadata; hostname is not trusted. '
            'No device files were changed.',
      );
    }
    final String target = profile.targetSlice.wireName;
    final String? architecture = device.architecture;
    final Set<String>? allowedArchitectures = _targetArchitectures[target];
    if (architecture == null ||
        allowedArchitectures == null ||
        !allowedArchitectures.contains(architecture)) {
      throw DeviceOperationException(
        '$target does not match device architecture',
        'The native runtime cannot run on '
            '${architecture ?? 'an unknown architecture'} '
            '(${profile.codename}). No '
            'device files were changed.',
      );
    }
  }

  Future<Map<String, Object?>> _embedderControlRequest(
    String action, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    return _controlRequestUsing(
      action,
      fields: fields,
      client: _controlClient,
      socket: _embedderControlSocket,
      controlName: 'embedder',
    );
  }

  Future<Map<String, Object?>> _controlRequestUsing(
    String action, {
    required Map<String, Object?> fields,
    required String client,
    required String socket,
    required String controlName,
  }) async {
    final String requestId = _nextNonce();
    final String request = jsonEncode(<String, Object?>{
      'requestId': requestId,
      'action': action,
      ...fields,
    });
    final String command =
        'client=${_q(client)}; '
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
        decoded['requestId'] != requestId ||
        decoded['ok'] is! bool) {
      throw DeviceOperationException(
        'invalid Pluto device control response',
        'The Pluto $controlName control response did not match the request '
            'envelope.',
      );
    }
    if (decoded['ok'] != true) {
      if (!_hasExactKeys(decoded, const <String>{'requestId', 'ok', 'error'})) {
        throw DeviceOperationException(
          'invalid Pluto device control response',
          'The Pluto $controlName failure envelope has unknown or missing '
              'fields.',
        );
      }
      final Object? error = decoded['error'];
      if (error is! Map<String, Object?> ||
          !_hasExactKeys(error, const <String>{'code', 'message'}) ||
          error['code'] is! String ||
          error['message'] is! String) {
        throw DeviceOperationException(
          'invalid Pluto device control response',
          'The Pluto $controlName failure detail is not exact.',
        );
      }
      throw DeviceOperationException(
        'Pluto device control rejected $action',
        '${error['code']}: ${error['message']}',
      );
    }
    if (!_hasExactKeys(decoded, const <String>{'requestId', 'ok', 'result'})) {
      throw DeviceOperationException(
        'invalid Pluto device control response',
        'The Pluto $controlName success envelope has unknown or missing '
            'fields.',
      );
    }
    final Object? result = decoded['result'];
    if (result is! Map<String, Object?>) {
      throw DeviceOperationException(
        'invalid Pluto device control response',
        'The Pluto $controlName result is not an object.',
      );
    }
    return result;
  }

  Future<int> _foregroundPid() async {
    final String executable = '$deviceRoot/bin/pluto-embedder';
    // `/proc/<pid>/exe` names the immutable release target, while deviceRoot
    // is the atomically switched managed symlink. Resolve both to one spelling.
    final CommandResult result = await transport.exec(
      'pid=\$(cat ${_q('$runDir/embedder.pid')} 2>/dev/null || true); '
      'case "\$pid" in ""|*[!0-9]*) exit 66 ;; esac; '
      '[ "\$pid" -gt 0 ] 2>/dev/null || exit 66; '
      'expected=\$(readlink -f ${_q(executable)} 2>/dev/null || true); '
      '[ -n "\$expected" ] || exit 66; '
      'exe=\$(readlink "/proc/\$pid/exe" 2>/dev/null || true); '
      'case "\$exe" in "\$expected"|"\$expected (deleted)") ;; '
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

  _ScreenshotCapture _validateScreenshotCapture(
    Map<String, Object?> capture, {
    required String path,
    required String? requestedAppId,
    required String requestedSurface,
    required int expectedPid,
  }) {
    if (!_hasExactKeys(capture, const <String>{
      'path',
      'bytes',
      'sha256',
      'appId',
      'pid',
      'surface',
      'width',
      'height',
      'stride',
      'format',
    })) {
      throw const DeviceOperationException(
        'invalid Pluto screenshot response',
        'The embedder returned unknown or missing screenshot metadata.',
      );
    }
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

  /// Installs one target slice from a validated `.plap` archive.
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
    _validateNativeRuntimeDevice(device, operation: 'app install');
    final PlapTargetSlice slice = archive.sliceForTarget(device.buildTarget!);
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
      bytes: slice.installTarBytes,
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
        buildMode: slice.buildMode,
        engineFlavor: slice.engineFlavor,
        sizeBytes: slice.installTarBytes.length,
        payload: slice.payloadHashes,
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
    _validateNativeRuntimeDevice(device, operation: 'app uninstall');
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

  /// Reads device logs from the current embedder and optional system journal.
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
    _validateNativeRuntimeDevice(device, operation: 'logs');
    final String appLog = appId == null
        ? 'tail -n $lines ${_q('$deviceRoot/logs/current.log')} 2>/dev/null'
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
    _validateNativeRuntimeDevice(device, operation: 'screenshot');
    final int foregroundPid = await _foregroundPid();
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
      final _ScreenshotCapture metadata = _validateScreenshotCapture(
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
    _validateNativeRuntimeDevice(device, operation: 'debug launch');
    if (!device.buildModes.contains('debug')) {
      throw const DeviceOperationException(
        'debug mode is unavailable for this installed runtime',
        'Install and run the app with --release.',
      );
    }
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
    _validateNativeRuntimeDevice(device, operation: 'app launch');
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
