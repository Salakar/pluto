import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../artifacts/checksums.dart';
import '../build/release_pipeline.dart';
import '../config/pins.dart';
import '../device/remarkable_device.dart';
import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto provision` command — detects the connected reMarkable and installs
/// the target-correct Pluto runtime, launcher, and application set.
///
/// The public workflow is identical across supported devices. Backend-specific
/// display ownership and lifecycle integration are selected only after the
/// device identity has been verified.
final class ProvisionCommand extends PlutoCommand {
  /// Creates the command.
  ProvisionCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addOption(
        'display-backend',
        allowed: <String>['auto', 'swtcon'],
        defaultsTo: 'auto',
        help: 'Presenter backend (auto selects the connected hardware).',
      )
      ..addOption(
        'payload-dir',
        help:
            'Directory with the runtime payload (pluto-embedder, '
            'bin/pluto-controlctl, bin/codex, COOPERATIVE-PAYLOAD.json, '
            'engine/{release,profile}/libflutter_engine.so, '
            'apps/<id>/{build-metadata.json,manifest.json,bundle/}). '
            'Defaults to '
            '<repo>/build/pluto-payload.',
      )
      ..addFlag(
        'debug',
        negatable: false,
        help:
            'Explicitly permit a debug/JIT engine and debug apps for '
            'hot reload. Release-only provisioning rejects them by default.',
      )
      ..addFlag(
        'no-boot-default',
        negatable: false,
        help:
            'Install runtime and ensure stock UI is the boot default '
            '(removes an existing Pluto boot override).',
      )
      ..addFlag(
        'status',
        negatable: false,
        help: 'Report provisioned boot state without changing the device.',
      )
      ..addFlag(
        'restore-remarkable',
        negatable: false,
        help:
            'Restore stock reMarkable (xochitl) as the boot default; '
            'keep the Pluto runtime installed.',
      )
      ..addFlag(
        'uninstall',
        negatable: false,
        help:
            'Remove Pluto entirely and restore stock xochitl as boot '
            'default.',
      );
  }

  /// Device scripts used by the direct-display backend.
  static const List<String> deviceScripts = <String>[
    'pluto-session.sh',
    'pluto-power-key-watch.sh',
    'pluto-boot-install.sh',
    'pluto-app-control.sh',
    'pluto-install-transaction.sh',
    'pluto-uninstall.sh',
  ];

  /// Device scripts staged when present (used by fallback/restore paths).
  static const List<String> optionalDeviceScripts = <String>[
    'pluto-xochitl-guard.sh',
  ];

  @override
  String get name => 'provision';

  @override
  String get description =>
      'Install the matching Pluto runtime on a reMarkable device.';

  @override
  Future<int> run() async {
    return guard(() async {
      final DeviceEndpoint? endpoint = endpointFromTarget(
        resolveDeviceTarget(),
      );
      if (endpoint == null) {
        usageException('No device: pass --device <user@host> or connect USB.');
      }
      final LiveDeviceOperations ops = LiveDeviceOperations(
        environment.transportFactory(endpoint),
      );

      if (argResults!['status'] as bool) {
        environment.out.writeln(await ops.provisionStatus());
        return 0;
      }
      if (argResults!['restore-remarkable'] as bool) {
        final DeviceOperationResult result = await ops.restoreStockBoot();
        environment.out.writeln(result.message);
        return result.ok ? 0 : 1;
      }
      if (argResults!['uninstall'] as bool) {
        final DeviceOperationResult result = await ops.uninstallSystem();
        environment.out.writeln(result.message);
        return result.ok ? 0 : 1;
      }

      final String repoRoot = environment.paths.repositoryRoot;
      final String? explicitPayloadDir = argResults!['payload-dir'] as String?;
      PlutoRuntimeBackend? selectedBackend;
      if (explicitPayloadDir == null) {
        selectedBackend = await ops.runtimeBackend();
      }
      final String payloadDir =
          explicitPayloadDir ??
          (selectedBackend == PlutoRuntimeBackend.cooperative
              ? '$repoRoot/build/pluto-appload-arm/home/root/pluto-arm'
              : '$repoRoot/build/pluto-payload');
      final PlutoPins pins = environment.pinsRepository.readPins();
      if (File('$payloadDir/libflutter_engine.so').existsSync()) {
        usageException(
          'Ambiguous legacy engine rejected: '
          '$payloadDir/libflutter_engine.so. Use the checksum-verified '
          'engine/release/libflutter_engine.so path.',
        );
      }
      final List<PayloadApp> apps = _collectApps(payloadDir, pins);
      final bool bootDefault = !(argResults!['no-boot-default'] as bool);
      final bool hasLauncher = apps.any(
        (PayloadApp app) => app.appId == LiveDeviceOperations.launcherAppId,
      );
      if (!hasLauncher) {
        usageException(
          'No launcher payload found. Provide '
          '$payloadDir/apps/${LiveDeviceOperations.launcherAppId}/bundle or '
          '$payloadDir/launcher/bundle'
          '${bootDefault ? ' (required as the default Pluto app)' : ''}.',
        );
      }
      final Set<String> appTargets = apps
          .map((PayloadApp app) => app.target)
          .toSet();
      if (appTargets.length != 1) {
        final List<String> sortedTargets = appTargets.toList()..sort();
        usageException(
          'Provision payload mixes build targets: $sortedTargets.',
        );
      }
      final String payloadTarget = appTargets.single;
      final PlutoTargetPlatform? targetPlatform =
          PlutoTargetPlatform.fromCliName(payloadTarget);
      if (targetPlatform == null) {
        usageException('Unsupported payload target: $payloadTarget.');
      }
      final bool cooperativePayload =
          targetPlatform == PlutoTargetPlatform.linuxArm;
      final PayloadFile? cooperativeCodex = cooperativePayload
          ? _resolveCooperativeCodex(payloadDir, pins)
          : null;

      final String releaseEngine = _resolvePinnedAotEngine(
        payloadDir: payloadDir,
        repoRoot: repoRoot,
        pins: pins,
        mode: PlutoBuildMode.release,
        target: targetPlatform,
      );
      final String? scriptsDir = cooperativePayload
          ? null
          : _resolveScriptsDir(payloadDir, repoRoot);
      if (!cooperativePayload && scriptsDir == null) {
        usageException(
          'Device scripts not found. Expected pluto-session.sh in '
          '$payloadDir or tools/device.',
        );
      }
      final String? profileEngine = cooperativePayload
          ? null
          : _resolvePinnedAotEngine(
              payloadDir: payloadDir,
              repoRoot: repoRoot,
              pins: pins,
              mode: PlutoBuildMode.profile,
            );
      final String debugPath = '$payloadDir/engine/debug/libflutter_engine.so';
      final String? debugEngine = File(debugPath).existsSync()
          ? debugPath
          : null;
      final bool allowDebug = argResults!['debug'] as bool;
      if (cooperativePayload && allowDebug) {
        usageException(
          'The installed runtime on this device supports release AOT only. '
          'Provision without --debug.',
        );
      }

      String selectPayloadFile(List<String> candidates) {
        for (final String candidate in candidates) {
          if (File(candidate).existsSync()) {
            return candidate;
          }
        }
        return candidates.first;
      }

      final List<PayloadFile> runtime = <PayloadFile>[
        if (!cooperativePayload) ...<PayloadFile>[
          for (final String s in deviceScripts)
            PayloadFile(
              localPath: '$scriptsDir/$s',
              remoteRelative: 'bin/$s',
              executable: true,
            ),
          for (final String s in optionalDeviceScripts)
            if (File('$scriptsDir/$s').existsSync())
              PayloadFile(
                localPath: '$scriptsDir/$s',
                remoteRelative: 'bin/$s',
                executable: true,
              ),
        ],
        PayloadFile(
          localPath: selectPayloadFile(<String>[
            '$payloadDir/pluto-embedder',
            '$payloadDir/bin/pluto-embedder',
          ]),
          remoteRelative: 'bin/pluto-embedder',
          executable: true,
        ),
        if (!cooperativePayload)
          PayloadFile(
            localPath: selectPayloadFile(<String>[
              '$payloadDir/bin/pluto-controlctl',
              '$repoRoot/embedder/build/device-arm64/pluto-controlctl',
            ]),
            remoteRelative: 'bin/pluto-controlctl',
            executable: true,
          ),
        PayloadFile(
          localPath: releaseEngine,
          remoteRelative: 'engine/release/libflutter_engine.so',
        ),
        if (profileEngine != null)
          PayloadFile(
            localPath: profileEngine,
            remoteRelative: 'engine/profile/libflutter_engine.so',
          ),
        if (cooperativePayload) ...<PayloadFile>[
          PayloadFile(
            localPath: selectPayloadFile(<String>[
              '$payloadDir/bin/pluto-controlctl',
              '$repoRoot/embedder/build/device-arm/pluto-controlctl',
            ]),
            remoteRelative: 'bin/pluto-controlctl',
            executable: true,
          ),
          PayloadFile(
            localPath: selectPayloadFile(<String>[
              '$payloadDir/engine/release/icudtl.dat',
              '$repoRoot/third_party/engine/${pins.engineVersion}/'
                  'linux-arm-release/icudtl.dat',
            ]),
            remoteRelative: 'engine/release/icudtl.dat',
          ),
          cooperativeCodex!,
        ],
        if (allowDebug && debugEngine != null)
          PayloadFile(
            localPath: debugEngine,
            remoteRelative: 'engine/debug/libflutter_engine.so',
          ),
      ];
      final CooperativeIntegrationPayload? cooperativeIntegration =
          cooperativePayload
          ? CooperativeIntegrationPayload(
              rootDirectory: '$payloadDir/integration',
            )
          : null;
      if (cooperativeIntegration != null &&
          !Directory(cooperativeIntegration.rootDirectory).existsSync()) {
        usageException(
          'Missing target integration payload: '
          '${cooperativeIntegration.rootDirectory}. Rebuild the release '
          'payload before provisioning.',
        );
      }
      for (final PayloadFile file in runtime) {
        if (!File(file.localPath).existsSync()) {
          usageException(
            'Missing payload file: ${file.localPath}. '
            'Build the runtime first (see `pluto build`).',
          );
        }
      }
      final bool hasDebugApp = apps.any(
        (PayloadApp app) =>
            app.buildMode == PlutoBuildMode.debug.cliName ||
            app.engineFlavor == PlutoBuildMode.debug.engineFlavor,
      );
      if (!allowDebug && (debugEngine != null || hasDebugApp)) {
        usageException(
          'Debug/JIT payload content requires explicit `provision --debug` '
          'for a hot-reload setup. Normal provisioning is release AOT only.',
        );
      }
      final PayloadApp launcher = apps.firstWhere(
        (PayloadApp app) => app.appId == LiveDeviceOperations.launcherAppId,
      );
      if (launcher.buildMode != PlutoBuildMode.release.cliName ||
          launcher.engineFlavor != PlutoBuildMode.release.engineFlavor) {
        usageException(
          'The launcher payload must be a release AOT build, not '
          '${launcher.buildMode}/${launcher.engineFlavor}. JIT launchers are '
          'allowed only in an explicit hot-reload session.',
        );
      }
      if (allowDebug && debugEngine == null && hasDebugApp) {
        usageException(
          'A debug app is present but engine/debug/libflutter_engine.so is '
          'missing. Debug is only supported as an explicit hot-reload '
          'payload.',
        );
      }
      final PlutoRuntimeBackend backend =
          selectedBackend ?? await ops.runtimeBackend();
      if (backend == PlutoRuntimeBackend.cooperative &&
          argResults!['display-backend'] == 'swtcon') {
        usageException(
          'The explicitly requested display backend does not match this '
          'device. Omit --display-backend to select it automatically.',
        );
      }
      final String expectedTarget = backend == PlutoRuntimeBackend.cooperative
          ? PlutoTargetPlatform.linuxArm.cliName
          : PlutoTargetPlatform.linuxArm64.cliName;
      if (payloadTarget != expectedTarget) {
        usageException(
          'Payload target $payloadTarget does not match the connected device '
          '(expected $expectedTarget).',
        );
      }
      environment.out.writeln(
        'Provisioning ${endpoint.sshTarget} '
        '(${apps.length} apps)…',
      );
      final DeviceOperationResult result = await ops.provision(
        runtime: runtime,
        apps: apps,
        payloadTarget: payloadTarget,
        cooperativeIntegration: cooperativeIntegration,
        bootDefault: bootDefault,
      );
      environment.out.writeln(result.message);
      return result.ok ? 0 : 1;
    });
  }

  /// The device scripts ship in the repo (`tools/device/`); a self-contained
  /// payload directory may carry its own copies which take precedence.
  String? _resolveScriptsDir(String payloadDir, String repoRoot) {
    final List<String> candidates = <String>[
      payloadDir,
      '$repoRoot/tools/device',
      '$repoRoot/../device',
    ];
    for (final String candidate in candidates) {
      if (File('$candidate/pluto-session.sh').existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _resolvePinnedAotEngine({
    required String payloadDir,
    required String repoRoot,
    required PlutoPins pins,
    required PlutoBuildMode mode,
    PlutoTargetPlatform target = PlutoTargetPlatform.linuxArm64,
  }) {
    if (!mode.isAot) {
      throw ArgumentError.value(mode, 'mode', 'must be an AOT mode');
    }
    if (target == PlutoTargetPlatform.linuxArm &&
        mode != PlutoBuildMode.release) {
      usageException('The linux-arm runtime supports release AOT only.');
    }
    final String artifactDirectory = target == PlutoTargetPlatform.linuxArm
        ? 'linux-arm-release'
        : 'linux-arm64-${mode.cliName}';
    final String artifactRoot =
        '$repoRoot/third_party/engine/${pins.engineVersion}/'
        '$artifactDirectory';
    final File manifest = File('$artifactRoot/CHECKSUMS.txt');
    if (_entityType(manifest.path) != FileSystemEntityType.file) {
      usageException(
        'Missing committed ${mode.cliName} CHECKSUMS.txt for engine '
        '${pins.engineVersion}. Run `tools/setup/setup.sh --verify`.',
      );
    }

    final Map<String, String> metadata = <String, String>{};
    final Map<String, String> digests = <String, String>{};
    for (final String line in const LineSplitter().convert(
      manifest.readAsStringSync(),
    )) {
      final RegExpMatch? digest = RegExp(
        r'^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$',
      ).firstMatch(line);
      if (digest != null) {
        final String name = digest.group(2)!;
        if (digests.containsKey(name)) {
          usageException('Duplicate engine checksum record: $name.');
        }
        digests[name] = digest.group(1)!;
        continue;
      }
      final int equals = line.indexOf('=');
      if (equals > 0) {
        final String key = line.substring(0, equals);
        if (metadata.containsKey(key)) {
          usageException('Duplicate engine metadata record: $key.');
        }
        metadata[key] = line.substring(equals + 1);
      }
    }
    final Map<String, String> expectedMetadata = <String, String>{
      'schema': '1',
      'flutter': pins.flutterVersion,
      'engine': pins.engineVersion,
      'target': target.cliName,
      'mode': mode.cliName,
    };
    for (final MapEntry<String, String> expected in expectedMetadata.entries) {
      if (metadata[expected.key] != expected.value) {
        usageException(
          'Pinned ${mode.cliName} engine metadata mismatch: '
          '${expected.key}=${metadata[expected.key]} '
          '(expected ${expected.value}).',
        );
      }
    }

    final String? expectedDigest = digests['libflutter_engine.so'];
    if (expectedDigest == null) {
      usageException(
        '${manifest.path} does not authenticate libflutter_engine.so.',
      );
    }
    final String payloadEngine =
        '$payloadDir/engine/${mode.cliName}/libflutter_engine.so';
    final String committedEngine = '$artifactRoot/libflutter_engine.so';
    final String selected = File(payloadEngine).existsSync()
        ? payloadEngine
        : committedEngine;
    if (_entityType(selected) != FileSystemEntityType.file) {
      usageException(
        'Missing pinned ${mode.cliName} libflutter_engine.so. Provide the '
        'canonical payload path or restore $committedEngine.',
      );
    }
    final String actualDigest = sha256Bytes(File(selected).readAsBytesSync());
    if (actualDigest != expectedDigest) {
      usageException(
        '${mode.cliName} engine checksum mismatch: $selected. Refusing to '
        'install a mislabeled or unpinned engine.',
      );
    }
    return selected;
  }

  FileSystemEntityType _entityType(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  PayloadFile _resolveCooperativeCodex(String payloadDir, PlutoPins pins) {
    final File pinFile = File(
      '${environment.paths.pinsDirectory}/codex-armv7.json',
    );
    final File payloadMetadata = File('$payloadDir/COOPERATIVE-PAYLOAD.json');
    final File binary = File('$payloadDir/bin/codex');
    for (final File file in <File>[pinFile, payloadMetadata, binary]) {
      if (_entityType(file.path) != FileSystemEntityType.file) {
        usageException(
          'Missing regular cooperative payload file: ${file.path}.',
        );
      }
    }

    Map<String, Object?> readJson(File file) {
      try {
        final Object? decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, Object?>) {
          return decoded;
        }
      } on FileSystemException catch (error) {
        usageException('Could not read ${file.path}: ${error.message}.');
      } on FormatException catch (error) {
        usageException('Invalid ${file.path}: ${error.message}.');
      }
      usageException('${file.path} must contain a JSON object.');
    }

    final Map<String, Object?> pin = readJson(pinFile);
    final Object? pinVersion = pin['version'];
    final Object? pinDigest = pin['sha256'];
    if (pin['schema'] != 1 ||
        pin['target'] != PlutoTargetPlatform.linuxArm.cliName ||
        pinVersion is! String ||
        pinVersion.isEmpty ||
        pinDigest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(pinDigest)) {
      usageException('Invalid Codex ARMv7 pin: ${pinFile.path}.');
    }

    final Map<String, Object?> metadata = readJson(payloadMetadata);
    final Object? rawCodex = metadata['codex'];
    if (metadata['schema'] != 1 ||
        metadata['target'] != PlutoTargetPlatform.linuxArm.cliName ||
        metadata['mode'] != PlutoBuildMode.release.cliName ||
        metadata['flutterVersion'] != pins.flutterVersion ||
        metadata['engineCommit'] != pins.engineVersion ||
        metadata['runtimeRoot'] != LiveDeviceOperations.defaultDeviceRoot ||
        rawCodex is! Map<String, Object?> ||
        rawCodex['version'] != pinVersion ||
        rawCodex['sha256'] != pinDigest ||
        rawCodex['path'] !=
            '${LiveDeviceOperations.defaultDeviceRoot}/bin/codex' ||
        rawCodex['authentication'] != 'user-managed') {
      usageException(
        'Cooperative Codex metadata does not match the release pin: '
        '${payloadMetadata.path}.',
      );
    }

    final Uint8List bytes = binary.readAsBytesSync();
    final String actualDigest = sha256Bytes(bytes);
    if (actualDigest != pinDigest) {
      usageException(
        'Codex ARMv7 checksum mismatch: ${binary.path}. Refusing to '
        'provision a tampered binary.',
      );
    }
    if (!_isArmV7HardFloatElf(bytes) ||
        !_containsBytes(bytes, utf8.encode(pinVersion))) {
      usageException(
        'Codex payload is not the pinned ARMv7 hard-float release '
        '$pinVersion: ${binary.path}.',
      );
    }
    return PayloadFile(
      localPath: binary.path,
      remoteRelative: 'bin/codex',
      executable: true,
    );
  }

  bool _isArmV7HardFloatElf(Uint8List bytes) {
    if (bytes.length < 52 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46 ||
        bytes[4] != 1 ||
        bytes[5] != 1 ||
        bytes[18] != 40 ||
        bytes[19] != 0) {
      return false;
    }
    final int flags =
        bytes[36] | (bytes[37] << 8) | (bytes[38] << 16) | (bytes[39] << 24);
    return ((flags >> 24) & 0xff) == 5 &&
        (flags & 0x400) != 0 &&
        (flags & 0x200) == 0;
  }

  bool _containsBytes(Uint8List bytes, List<int> needle) {
    if (needle.isEmpty || needle.length > bytes.length) {
      return false;
    }
    for (var start = 0; start <= bytes.length - needle.length; start += 1) {
      var matches = true;
      for (var index = 0; index < needle.length; index += 1) {
        if (bytes[start + index] != needle[index]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }

  /// Collects complete Pluto layouts under `apps/<id>/`, plus an optional
  /// top-level `launcher/` layout treated as the launcher app.
  List<PayloadApp> _collectApps(String payloadDir, PlutoPins pins) {
    final List<PayloadApp> apps = <PayloadApp>[];
    final Directory launcherDir = Directory('$payloadDir/launcher/bundle');
    if (launcherDir.existsSync()) {
      final BuildLayoutMetadata metadata = BuildLayoutMetadata.read(
        '$payloadDir/launcher',
      );
      metadata.validate('$payloadDir/launcher', pins: pins);
      apps.add(
        PayloadApp(
          appId: LiveDeviceOperations.launcherAppId,
          bundleDir: launcherDir.path,
          buildMode: metadata.buildMode.cliName,
          engineFlavor: metadata.engineFlavor,
          target: metadata.target,
        ),
      );
    }
    final Directory appsDir = Directory('$payloadDir/apps');
    if (appsDir.existsSync()) {
      for (final FileSystemEntity entity in appsDir.listSync()) {
        if (entity is! Directory ||
            !Directory('${entity.path}/bundle').existsSync()) {
          continue;
        }
        final String appId = entity.uri.pathSegments
            .where((String s) => s.isNotEmpty)
            .last;
        if (appId == LiveDeviceOperations.launcherAppId &&
            apps.any((PayloadApp a) => a.appId == appId)) {
          continue;
        }
        final BuildLayoutMetadata metadata = BuildLayoutMetadata.read(
          entity.path,
        );
        metadata.validate(entity.path, pins: pins);
        apps.add(
          PayloadApp(
            appId: appId,
            bundleDir: '${entity.path}/bundle',
            buildMode: metadata.buildMode.cliName,
            engineFlavor: metadata.engineFlavor,
            target: metadata.target,
          ),
        );
      }
    }
    return apps;
  }
}
