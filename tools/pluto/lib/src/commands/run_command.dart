import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto run` command.
final class RunCommand extends PlutoCommand {
  /// Creates the command.
  RunCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'debug',
        negatable: false,
        help: 'Run with the debug/JIT engine and hot reload.',
      )
      ..addFlag(
        'profile',
        negatable: false,
        help: 'Run an AOT profile build. Hot reload is unavailable.',
      )
      ..addFlag(
        'release',
        negatable: false,
        help:
            'Run an AOT release build (the default). No VM service is '
            'available.',
      )
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'lib/main.dart',
        help: 'Dart entrypoint.',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional Dart defines in K=V form.',
      )
      ..addOption(
        'orientation',
        allowed: <String>[
          'portrait',
          'portraitDown',
          'landscapeLeft',
          'landscapeRight',
        ],
        help: 'Initial device orientation forwarded to the embedder.',
      )
      ..addOption(
        'refresh-profile',
        allowed: <String>['balanced', 'fast', 'quality'],
        defaultsTo: 'balanced',
        help: 'Initial e-ink refresh profile.',
      )
      ..addOption(
        'vm-service-port',
        help: 'Requested VM service port; 0 means choose dynamically.',
      )
      ..addFlag(
        'forward-ssh',
        negatable: false,
        help: 'Force ssh -L forwarding instead of direct VM-service connect.',
      )
      ..addFlag(
        'no-hot',
        negatable: false,
        help: 'Disable hot reload/restart even in debug mode.',
      )
      ..addFlag(
        'verbose-system-logs',
        negatable: false,
        help: 'Include system logs in the run console.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Launch an installed app on a device (via the session supervisor).';

  @override
  Future<int> run() async {
    return guard(() async {
      final _RunMode mode = _validateMode();
      final DeviceEndpoint? endpoint = endpointFromTarget(
        resolveDeviceTarget(),
      );
      if (endpoint == null) {
        usageException('No device: pass --device <user@host> or connect USB.');
      }
      final String appId = argResults!.rest.isNotEmpty
          ? argResults!.rest.first
          : LiveDeviceOperations.launcherAppId;
      final LiveDeviceOperations ops = LiveDeviceOperations(
        environment.transportFactory(endpoint),
      );
      final String installedMode = await ops.installedBuildMode(appId);
      if (installedMode != mode.name) {
        throw DeviceOperationException(
          '$appId is installed as $installedMode, not ${mode.name}.',
          mode == _RunMode.debug
              ? 'Install a debug bundle before using the JIT/hot-reload path.'
              : 'Build/package/install the app with --${mode.name} first.',
        );
      }
      if (mode == _RunMode.debug) {
        final int vmServicePort = _vmServicePort();
        final Uri vmUri = await ops.runDebugApp(
          appId: appId,
          vmServicePort: vmServicePort,
        );
        environment.out
          ..writeln(
            'Requested debug/JIT launch of $appId. '
            'Dart VM service forwarded to $vmUri',
          )
          ..writeln('Hot reload/restart: flutter attach --debug-url=$vmUri');
      } else {
        await ops.launchAotApp(appId: appId);
        environment.out.writeln(
          mode == _RunMode.profile
              ? 'Requested profile AOT launch of $appId. Hot reload is '
                    'disabled; the profile VM service is not auto-forwarded.'
              : 'Requested release AOT launch of $appId. VM service and hot '
                    'reload are disabled.',
        );
      }
      environment.out.writeln(
        'Note: `pluto run` does not build or install; the app must '
        'already be installed (`pluto install`).',
      );
      return 0;
    });
  }

  _RunMode _validateMode() {
    final bool debug = argResults!['debug'] as bool;
    final bool profile = argResults!['profile'] as bool;
    final bool release = argResults!['release'] as bool;
    if (<bool>[debug, profile, release].where((bool value) => value).length >
        1) {
      usageException('Choose only one of --debug, --profile, or --release.');
    }
    final _RunMode mode = debug
        ? _RunMode.debug
        : profile
        ? _RunMode.profile
        : _RunMode.release;
    if (mode != _RunMode.debug && (argResults!['forward-ssh'] as bool)) {
      usageException('--forward-ssh is only valid for debug/JIT runs.');
    }
    if (mode != _RunMode.debug && argResults!.wasParsed('vm-service-port')) {
      usageException('--vm-service-port is only valid for debug/JIT runs.');
    }
    if (mode != _RunMode.debug && (argResults!['no-hot'] as bool)) {
      usageException('--no-hot is only valid for debug/JIT runs.');
    }
    return mode;
  }

  int _vmServicePort() {
    final String? raw = argResults!['vm-service-port'] as String?;
    if (raw == null) {
      return 38383;
    }
    final int? port = int.tryParse(raw);
    if (port == null || port < 0 || port > 65535) {
      usageException('--vm-service-port must be between 0 and 65535.');
    }
    return port;
  }
}

enum _RunMode { debug, profile, release }
