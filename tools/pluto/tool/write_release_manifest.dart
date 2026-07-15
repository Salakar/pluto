import 'dart:io';

import 'package:pluto_cli/src/build/release_set.dart';

Never _usage() {
  stderr.writeln(
    'usage: dart tool/write_release_manifest.dart '
    '--release-root DIR --pins-dir DIR --git-revision HASH',
  );
  exit(64);
}

void main(List<String> arguments) {
  final Map<String, String> values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 1) {
    final String argument = arguments[index];
    if (!argument.startsWith('--') || index + 1 >= arguments.length) {
      _usage();
    }
    values[argument.substring(2)] = arguments[index + 1];
    index += 1;
  }
  if (values.keys.toSet().difference(const <String>{
        'release-root',
        'pins-dir',
        'git-revision',
      }).isNotEmpty ||
      values.length != 3) {
    _usage();
  }
  final ReleaseSetManifest manifest = ReleaseSetManifest.create(
    root: values['release-root']!,
    gitRevision: values['git-revision']!,
    pins: ReleaseSetPins.read(values['pins-dir']!),
  );
  manifest.write();
  stdout.writeln(
    'Wrote ${values['release-root']}/${ReleaseSetManifest.fileName} '
    'for ${manifest.gitRevision}.',
  );
}
