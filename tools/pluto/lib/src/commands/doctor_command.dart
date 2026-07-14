import 'dart:convert';

import '../doctor/doctor.dart';
import '../exit_codes.dart';
import 'base_command.dart';

/// `pluto doctor` command.
final class DoctorCommand extends PlutoCommand {
  /// Creates the command.
  DoctorCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit a machine-readable doctor report.',
      )
      ..addFlag(
        'probe-usb',
        negatable: false,
        help:
            'Probe root@10.11.99.1 over SSH. Without this flag, device '
            'checks are skipped unless --device is set.',
      );
  }

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check host and optional device environment health.';

  @override
  Future<int> run() async {
    return guard(() async {
      final bool json = argResults!['json'] as bool || globalMachine;
      final DoctorReport report = await environment.doctorService.run(
        flutterSdkOverride: globalFlutterSdk,
        probeDevice: argResults!['probe-usb'] as bool,
        endpoint: endpointFromTarget(resolveDeviceTarget()),
      );
      if (json) {
        environment.out.writeln(
          const JsonEncoder.withIndent('  ').convert(report.toJson()),
        );
      } else {
        _printHumanReport(report);
      }
      return report.hasErrors ? ExitCodes.failure : ExitCodes.ok;
    });
  }

  void _printHumanReport(DoctorReport report) {
    environment.out.writeln(report.title);
    String? currentSection;
    for (final DoctorCheck check in report.checks) {
      if (check.section != currentSection) {
        currentSection = check.section;
        environment.out.writeln('');
        environment.out.writeln(currentSection);
      }
      environment.out.writeln(' ${check.severity.marker} ${check.message}');
      if (check.remediation != null) {
        environment.out.writeln('      ${check.remediation}');
      }
    }
  }
}
