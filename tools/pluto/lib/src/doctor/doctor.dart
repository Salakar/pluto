import 'dart:convert';
import 'dart:io';

import '../artifacts/engine_artifacts.dart';
import '../config/pins.dart';
import '../device/remarkable_discovery.dart';
import '../device/remarkable_device.dart';
import '../process.dart';
import '../ssh/device_transport.dart';

/// Severity of a doctor check.
enum DoctorSeverity {
  /// Check passed.
  ok,

  /// Check found a non-fatal issue.
  warning,

  /// Check failed.
  error,

  /// Check was intentionally skipped.
  skipped;

  /// CLI marker for this severity.
  String get marker {
    return switch (this) {
      DoctorSeverity.ok => '[ok]',
      DoctorSeverity.warning => '[warn]',
      DoctorSeverity.error => '[fail]',
      DoctorSeverity.skipped => '[skip]',
    };
  }
}

/// One doctor check result.
final class DoctorCheck {
  /// Creates a doctor check result.
  const DoctorCheck({
    required this.id,
    required this.section,
    required this.severity,
    required this.message,
    this.remediation,
  });

  /// Stable check id.
  final String id;

  /// Report section.
  final String section;

  /// Severity.
  final DoctorSeverity severity;

  /// User-facing result.
  final String message;

  /// Concrete remediation, if any.
  final String? remediation;
}

/// Full doctor report.
final class DoctorReport {
  /// Creates a report.
  const DoctorReport({required this.title, required this.checks});

  /// Report title.
  final String title;

  /// Ordered checks.
  final List<DoctorCheck> checks;

  /// Whether any check failed.
  bool get hasErrors =>
      checks.any((DoctorCheck check) => check.severity == DoctorSeverity.error);

  /// Encodes this report for `--json`.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'title': title,
      'hasErrors': hasErrors,
      'checks': checks
          .map(
            (DoctorCheck check) => <String, Object?>{
              'id': check.id,
              'section': check.section,
              'severity': check.severity.name,
              'message': check.message,
              if (check.remediation != null) 'remediation': check.remediation,
            },
          )
          .toList(growable: false),
    };
  }
}

/// Runs host and optional device health checks.
final class DoctorService {
  /// Creates a doctor service.
  const DoctorService({
    required this.pinsRepository,
    required this.artifactResolver,
    required this.hostEnvironment,
    required this.deviceDiscovery,
  });

  /// Toolchain pin source.
  final PinsRepository pinsRepository;

  /// Engine cache resolver.
  final EngineArtifactResolver artifactResolver;

  /// Host process/filesystem access.
  final HostEnvironment hostEnvironment;

  /// Device discovery service.
  final RemarkableDeviceDiscovery deviceDiscovery;

  /// Runs doctor checks.
  Future<DoctorReport> run({
    String? flutterSdkOverride,
    bool probeDevice = false,
    DeviceEndpoint? endpoint,
  }) async {
    final PlutoPins pins = pinsRepository.readPins();
    final List<DoctorCheck> checks = <DoctorCheck>[
      ...await _hostChecks(pins: pins, flutterSdkOverride: flutterSdkOverride),
      ...await _artifactChecks(pins),
      ...await _deviceChecks(
        pins: pins,
        probeDevice: probeDevice,
        endpoint: endpoint,
      ),
    ];
    return DoctorReport(title: 'Pluto doctor - pluto 0.1.0', checks: checks);
  }

  Future<List<DoctorCheck>> _hostChecks({
    required PlutoPins pins,
    required String? flutterSdkOverride,
  }) async {
    final List<DoctorCheck> checks = <DoctorCheck>[];
    final _FlutterSdkResolution flutter = _resolveFlutter(
      flutterSdkOverride,
      pins,
    );
    if (flutter.executable == null) {
      checks.add(
        const DoctorCheck(
          id: 'flutter.onPath',
          section: 'Host',
          severity: DoctorSeverity.error,
          message: 'Flutter SDK not found.',
          remediation:
              'Put ~/.pluto/sdk/3.44.4/bin on PATH or pass '
              '--flutter-sdk.',
        ),
      );
    } else {
      checks.addAll(await _flutterVersionChecks(pins, flutter));
    }

    final String? sshPath = hostEnvironment.executablePath('ssh');
    checks.add(
      DoctorCheck(
        id: 'ssh.client',
        section: 'Host',
        severity: sshPath == null ? DoctorSeverity.error : DoctorSeverity.ok,
        message: sshPath == null
            ? 'OpenSSH client not found.'
            : 'OpenSSH client found at $sshPath.',
        remediation: sshPath == null ? 'Install OpenSSH and retry.' : null,
      ),
    );
    return checks;
  }

  Future<List<DoctorCheck>> _flutterVersionChecks(
    PlutoPins pins,
    _FlutterSdkResolution flutter,
  ) async {
    final List<DoctorCheck> checks = <DoctorCheck>[];
    final CommandResult result = await hostEnvironment.run(<String>[
      flutter.executable!,
      '--version',
      '--machine',
    ], timeout: const Duration(seconds: 20));
    if (!result.isSuccess) {
      return <DoctorCheck>[
        DoctorCheck(
          id: 'flutter.version',
          section: 'Host',
          severity: DoctorSeverity.error,
          message: 'Could not run `${flutter.executable} --version`.',
          remediation: result.stderr.trim().isEmpty
              ? null
              : result.stderr.trim(),
        ),
      ];
    }

    final Object? decoded = jsonDecode(result.stdout);
    final Map<String, Object?> versionJson = decoded is Map<String, Object?>
        ? decoded
        : <String, Object?>{};
    final String? frameworkVersion = versionJson['frameworkVersion'] as String?;
    final String? dartVersion = versionJson['dartSdkVersion'] as String?;
    checks.add(
      DoctorCheck(
        id: 'flutter.version',
        section: 'Host',
        severity: frameworkVersion == pins.flutterVersion
            ? DoctorSeverity.ok
            : DoctorSeverity.error,
        message: frameworkVersion == pins.flutterVersion
            ? 'Flutter SDK pinned and compatible '
                  '(${pins.flutterVersion}, Dart ${dartVersion ?? 'unknown'}).'
            : 'Flutter SDK version ${frameworkVersion ?? 'unknown'} does not '
                  'match pin ${pins.flutterVersion}.',
        remediation: frameworkVersion == pins.flutterVersion
            ? null
            : 'Run with PATH=~/.pluto/sdk/${pins.flutterVersion}/bin:\$PATH.',
      ),
    );

    final String? sdkRoot = flutter.sdkRoot;
    if (sdkRoot == null) {
      checks.add(
        const DoctorCheck(
          id: 'flutter.engine',
          section: 'Host',
          severity: DoctorSeverity.warning,
          message: 'Could not infer Flutter SDK root for engine hash check.',
        ),
      );
      return checks;
    }
    final String engineFile = '$sdkRoot/bin/internal/engine.version';
    if (!hostEnvironment.fileExists(engineFile)) {
      checks.add(
        DoctorCheck(
          id: 'flutter.engine',
          section: 'Host',
          severity: DoctorSeverity.error,
          message: 'Engine version file missing at $engineFile.',
        ),
      );
      return checks;
    }
    final String sdkEngine = hostEnvironment.readTextFile(engineFile).trim();
    checks.add(
      DoctorCheck(
        id: 'flutter.engine',
        section: 'Host',
        severity: sdkEngine == pins.engineVersion
            ? DoctorSeverity.ok
            : DoctorSeverity.error,
        message: sdkEngine == pins.engineVersion
            ? 'Engine hash matches pin (${_shortHash(pins.engineVersion)}).'
            : 'Engine hash ${_shortHash(sdkEngine)} does not match pin '
                  '${_shortHash(pins.engineVersion)}.',
        remediation: sdkEngine == pins.engineVersion
            ? null
            : 'Use the pinned Flutter SDK ${pins.flutterVersion}.',
      ),
    );
    return checks;
  }

  Future<List<DoctorCheck>> _artifactChecks(PlutoPins pins) async {
    if (!pins.hasConcreteEngineVersion) {
      return <DoctorCheck>[
        DoctorCheck(
          id: 'artifacts.enginePin',
          section: 'Host',
          severity: DoctorSeverity.error,
          message: 'Engine pin is not a concrete hash: ${pins.engineVersion}.',
        ),
      ];
    }
    final String root =
        '${artifactResolver.paths.repositoryRoot}/third_party/engine/'
        '${pins.engineVersion}';
    final List<String> missing = <String>[
      for (final String mode in <String>['release', 'profile'])
        for (final String name in <String>[
          'libflutter_engine.so',
          'gen_snapshot',
          'icudtl.dat',
          'CHECKSUMS.txt',
        ])
          if (!File('$root/linux-arm64-$mode/$name').existsSync())
            '$root/linux-arm64-$mode/$name',
    ];
    if (missing.isEmpty) {
      return <DoctorCheck>[
        DoctorCheck(
          id: 'artifacts.cached',
          section: 'Host',
          severity: DoctorSeverity.ok,
          message:
              'Committed release/profile AOT artifacts are ready for '
              '${_shortHash(pins.engineVersion)}. Debug/JIT remains optional '
              'for hot reload.',
        ),
      ];
    }
    return <DoctorCheck>[
      DoctorCheck(
        id: 'artifacts.cached',
        section: 'Host',
        severity: DoctorSeverity.warning,
        message:
            'Committed AOT artifact set is incomplete '
            '(${missing.length} missing).',
        remediation:
            'Restore third_party/engine/${pins.engineVersion}/linux-arm64-'
            '{release,profile}, then run tools/setup/setup.sh --verify.',
      ),
    ];
  }

  Future<List<DoctorCheck>> _deviceChecks({
    required PlutoPins pins,
    required bool probeDevice,
    required DeviceEndpoint? endpoint,
  }) async {
    if (!probeDevice && endpoint == null) {
      return const <DoctorCheck>[
        DoctorCheck(
          id: 'device.probe',
          section: 'Device',
          severity: DoctorSeverity.skipped,
          message: 'No device target requested; USB SSH checks skipped.',
          remediation: 'Run `pluto doctor --probe-usb` to probe 10.11.99.1.',
        ),
      ];
    }
    final List<RemarkableDevice> devices = await deviceDiscovery.discover(
      probeDetails: true,
      endpoint: endpoint,
    );
    if (devices.isEmpty) {
      return const <DoctorCheck>[
        DoctorCheck(
          id: 'device.reachable',
          section: 'Device',
          severity: DoctorSeverity.skipped,
          message: 'No reachable reMarkable device found.',
        ),
      ];
    }
    final RemarkableDevice device = devices.single;
    final List<DoctorCheck> checks = <DoctorCheck>[
      DoctorCheck(
        id: 'device.reachable',
        section: 'Device',
        severity: DoctorSeverity.ok,
        message:
            'Reachable at ${device.endpoint.host} as '
            '${device.endpoint.user}.',
      ),
    ];
    final String? firmware = device.firmwareBuild;
    if (firmware == null) {
      checks.add(
        const DoctorCheck(
          id: 'device.firmware',
          section: 'Device',
          severity: DoctorSeverity.warning,
          message: 'Firmware build could not be read.',
        ),
      );
    } else {
      checks.add(
        DoctorCheck(
          id: 'device.firmware',
          section: 'Device',
          severity: pins.supportsFirmware(firmware)
              ? DoctorSeverity.ok
              : DoctorSeverity.error,
          message: pins.supportsFirmware(firmware)
              ? 'Firmware $firmware is in the support matrix.'
              : 'Firmware $firmware is not in the support matrix.',
          remediation: pins.supportsFirmware(firmware)
              ? null
              : 'Pass --allow-untested only after reading the provisioning '
                    'risk notes.',
        ),
      );
    }
    checks.add(
      DoctorCheck(
        id: 'device.runtime',
        section: 'Device',
        severity: device.provisioned
            ? DoctorSeverity.ok
            : DoctorSeverity.warning,
        message: device.provisioned
            ? 'Pluto runtime marker found.'
            : 'Pluto runtime marker not found.',
        remediation: device.provisioned ? null : 'Run `pluto provision`.',
      ),
    );
    checks.add(
      DoctorCheck(
        id: 'device.nativeRuntime',
        section: 'Device',
        severity: device.nativeRuntimeEnabled
            ? DoctorSeverity.ok
            : DoctorSeverity.error,
        message: device.nativeRuntimeEnabled
            ? 'Native session is enabled for ${device.name}.'
            : 'Native session is not enabled for the detected hardware.',
        remediation: device.nativeRuntimeEnabled
            ? null
            : 'Use a Pluto revision whose exact device profile has passed '
                  'native display acceptance.',
      ),
    );
    return checks;
  }

  _FlutterSdkResolution _resolveFlutter(
    String? flutterSdkOverride,
    PlutoPins pins,
  ) {
    if (flutterSdkOverride != null) {
      return _FlutterSdkResolution(
        executable: '$flutterSdkOverride/bin/flutter',
        sdkRoot: flutterSdkOverride,
      );
    }
    for (final String variable in <String>['PLUTO_SDK', 'PLUTO_FLUTTER_SDK']) {
      final String? envSdk = hostEnvironment.environmentVariable(variable);
      if (envSdk != null && envSdk.isNotEmpty) {
        return _FlutterSdkResolution(
          executable: '$envSdk/bin/flutter',
          sdkRoot: envSdk,
        );
      }
    }
    final String managedSdk =
        '${artifactResolver.paths.plutoHome}/sdk/${pins.flutterVersion}';
    if (hostEnvironment.fileExists('$managedSdk/bin/flutter')) {
      return _FlutterSdkResolution(
        executable: '$managedSdk/bin/flutter',
        sdkRoot: managedSdk,
      );
    }
    final String? executable = hostEnvironment.executablePath('flutter');
    return _FlutterSdkResolution(
      executable: executable,
      sdkRoot: _sdkRootFromFlutterExecutable(executable),
    );
  }
}

final class _FlutterSdkResolution {
  const _FlutterSdkResolution({
    required this.executable,
    required this.sdkRoot,
  });

  final String? executable;
  final String? sdkRoot;
}

String? _sdkRootFromFlutterExecutable(String? executable) {
  if (executable == null) {
    return null;
  }
  const String suffix = '/bin/flutter';
  if (executable.endsWith(suffix)) {
    return executable.substring(0, executable.length - suffix.length);
  }
  return null;
}

String _shortHash(String hash) {
  if (hash.length <= 10) {
    return hash;
  }
  return hash.substring(0, 10);
}
