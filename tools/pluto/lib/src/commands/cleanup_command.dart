import '../exit_codes.dart';
import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto cleanup` command — device janitor. Scans the provisioned runtime
/// for stale artifacts (old logs, orphaned app dirs, swtcon probe files,
/// backup binaries, staging leftovers) and lists them; `--apply` deletes.
final class CleanupCommand extends PlutoCommand {
  /// Creates the command.
  CleanupCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'apply',
        negatable: false,
        help: 'Delete the listed artifacts. Default is a dry run.',
      )
      ..addFlag(
        'keep-backups',
        negatable: false,
        help: 'Keep *.bak-* backup binaries in bin/.',
      );
  }

  @override
  String get name => 'cleanup';

  @override
  String get description =>
      'Remove stale Pluto artifacts (logs, orphans, probes) from a device.';

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
      final bool apply = argResults!['apply'] as bool;
      final CleanupReport report = await ops.cleanup(
        apply: apply,
        keepBackups: argResults!['keep-backups'] as bool,
      );
      if (report.items.isEmpty) {
        environment.out.writeln('Device is clean — nothing to remove.');
        return ExitCodes.ok;
      }
      environment.out.writeln(_renderTable(report));
      environment.out.writeln(
        report.applied
            ? 'Removed ${report.items.length} item(s), '
                  '${report.totalKb} KB reclaimed.'
            : 'Dry run: ${report.items.length} item(s), '
                  '${report.totalKb} KB. Pass --apply to delete.',
      );
      return ExitCodes.ok;
    });
  }

  String _renderTable(CleanupReport report) {
    const String categoryHeader = 'CATEGORY';
    const String sizeHeader = 'SIZE';
    int categoryWidth = categoryHeader.length;
    int sizeWidth = sizeHeader.length;
    final List<(String, String, String)> rows = <(String, String, String)>[];
    for (final CleanupItem item in report.items) {
      final String size = '${item.sizeKb} KB';
      if (item.category.length > categoryWidth) {
        categoryWidth = item.category.length;
      }
      if (size.length > sizeWidth) {
        sizeWidth = size.length;
      }
      rows.add((item.category, size, item.path));
    }
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '${categoryHeader.padRight(categoryWidth)}  '
        '${sizeHeader.padRight(sizeWidth)}  PATH',
      );
    for (final (String category, String size, String path) in rows) {
      buffer.writeln(
        '${category.padRight(categoryWidth)}  ${size.padRight(sizeWidth)}  '
        '$path',
      );
    }
    return buffer.toString().trimRight();
  }
}
