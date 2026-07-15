import 'dart:convert';
import 'dart:io';

import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('doctor reports host checks and skips device by default', () async {
    final _DoctorHarness harness = _DoctorHarness();
    addTearDown(harness.dispose);

    final DoctorReport report = await harness.environment.doctorService.run();

    expect(report.hasErrors, isFalse);
    expect(
      report.checks.map((DoctorCheck check) => check.id),
      containsAll(<String>[
        'flutter.version',
        'flutter.engine',
        'artifacts.cached',
        'ssh.client',
        'device.probe',
      ]),
    );
    expect(
      report.checks
          .singleWhere((DoctorCheck check) => check.id == 'device.probe')
          .severity,
      DoctorSeverity.skipped,
    );
  });

  test('doctor prefers the setup-managed SDK over Flutter on PATH', () async {
    final _DoctorHarness harness = _DoctorHarness(useManagedSdk: true);
    addTearDown(harness.dispose);

    final DoctorReport report = await harness.environment.doctorService.run();

    expect(report.hasErrors, isFalse);
    expect(
      harness.hostEnvironment.lastFlutterExecutable,
      '${harness.temp.path}/.pluto/sdk/3.44.4/bin/flutter',
    );
  });

  test(
    'doctor probes fake device firmware and native runtime on request',
    () async {
      final _DoctorHarness harness = _DoctorHarness();
      addTearDown(harness.dispose);

      final DoctorReport report = await harness.environment.doctorService.run(
        probeDevice: true,
      );

      expect(report.hasErrors, isFalse);
      expect(
        report.checks
            .singleWhere((DoctorCheck check) => check.id == 'device.firmware')
            .severity,
        DoctorSeverity.ok,
      );
      expect(
        report.checks
            .singleWhere(
              (DoctorCheck check) => check.id == 'device.nativeRuntime',
            )
            .severity,
        DoctorSeverity.ok,
      );
    },
  );
}

final class _DoctorHarness {
  _DoctorHarness({this.useManagedSdk = false}) {
    pins.createSync(recursive: true);
    File('${pins.path}/flutter.version').writeAsStringSync('3.44.4');
    File('${pins.path}/engine.version').writeAsStringSync(engineHash);
    File(
      '${pins.path}/supported_os.json',
    ).writeAsStringSync('{"supportedOsBuilds":["20260629074044"]}');
  }

  static const String engineHash = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

  final bool useManagedSdk;

  final Directory temp = Directory.systemTemp.createTempSync('pluto-doctor-');

  late final Directory pins = Directory('${temp.path}/pins');

  late final StringBuffer out = StringBuffer();

  late final StringBuffer err = StringBuffer();

  late final _FakeHostEnvironment hostEnvironment = _FakeHostEnvironment(
    engineHash: engineHash,
    managedSdkRoot: useManagedSdk ? '${temp.path}/.pluto/sdk/3.44.4' : null,
  );

  late final PlutoCliEnvironment environment = PlutoCliEnvironment(
    paths: PlutoPaths(packageRoot: temp.path, homeDirectory: temp.path),
    hostEnvironment: hostEnvironment,
    transportFactory: (DeviceEndpoint endpoint) => FakeTransport(
      endpoint: endpoint,
      execHandler: (String command) async {
        if (command == 'cat /sys/devices/soc0/machine') {
          return const CommandResult(exitCode: 0, stdout: 'chiappa');
        }
        if (command == 'cat /proc/device-tree/compatible') {
          return const CommandResult(exitCode: 0, stdout: 'fsl,imx93');
        }
        if (command == 'uname -m') {
          return const CommandResult(exitCode: 0, stdout: 'aarch64');
        }
        if (command == 'cat /etc/version') {
          return const CommandResult(exitCode: 0, stdout: '20260629074044');
        }
        if (command.startsWith('test -e')) {
          return const CommandResult(exitCode: 0);
        }
        return const CommandResult(exitCode: 0);
      },
    ),
    out: out,
    err: err,
  );

  void dispose() {
    temp.deleteSync(recursive: true);
  }
}

final class _FakeHostEnvironment implements HostEnvironment {
  _FakeHostEnvironment({required this.engineHash, this.managedSdkRoot});

  final String engineHash;
  final String? managedSdkRoot;
  String? lastFlutterExecutable;

  @override
  String? executablePath(String executable) {
    return switch (executable) {
      'flutter' => '/fake/flutter/bin/flutter',
      'ssh' => '/usr/bin/ssh',
      _ => null,
    };
  }

  @override
  Future<CommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> environment = const <String, String>{},
    String? workingDirectory,
  }) async {
    final bool isManagedSdk =
        managedSdkRoot != null && command[0] == '$managedSdkRoot/bin/flutter';
    if (command.length == 3 &&
        (command[0] == '/fake/flutter/bin/flutter' || isManagedSdk) &&
        command[1] == '--version' &&
        command[2] == '--machine') {
      lastFlutterExecutable = command[0];
      return CommandResult(
        exitCode: 0,
        stdout: jsonEncode(<String, Object?>{
          'frameworkVersion': managedSdkRoot == null || isManagedSdk
              ? '3.44.4'
              : '0.0.0',
          'dartSdkVersion': '3.12.2',
        }),
      );
    }
    return const CommandResult(exitCode: 1, stderr: 'unexpected command');
  }

  @override
  bool fileExists(String path) {
    if (path == '/fake/flutter/bin/internal/engine.version') {
      return true;
    }
    if (managedSdkRoot != null &&
        (path == '$managedSdkRoot/bin/flutter' ||
            path == '$managedSdkRoot/bin/internal/engine.version')) {
      return true;
    }
    return false;
  }

  @override
  bool directoryExists(String path) => true;

  @override
  String readTextFile(String path) => engineHash;

  @override
  String? environmentVariable(String name) => null;

  @override
  String get operatingSystem => 'macos';
}
