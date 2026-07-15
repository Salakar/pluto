import 'dart:io';

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}

void main() {
  final Directory repositoryRoot = Directory.current;
  final String generator =
      '${repositoryRoot.path}/tools/codegen/'
      'generate_rm1_rgb565_optical_lut.dart';
  final Directory temporary = Directory.systemTemp.createTempSync(
    'pluto-rm1-lut-test.',
  );
  try {
    final File output = File('${temporary.path}/rm1_lut.h');
    final ProcessResult generated = Process.runSync(
      Platform.resolvedExecutable,
      <String>[generator, output.path],
    );
    if (generated.exitCode != 0 || !output.existsSync()) {
      _fail('RM1 LUT generation failed: ${generated.stderr}');
    }

    final ProcessResult current = Process.runSync(
      Platform.resolvedExecutable,
      <String>[generator, '--check', output.path],
    );
    if (current.exitCode != 0) {
      _fail('RM1 LUT check rejected generated output: ${current.stderr}');
    }

    output.writeAsStringSync('// drift\n', mode: FileMode.append);
    final ProcessResult drifted = Process.runSync(
      Platform.resolvedExecutable,
      <String>[generator, '--check', output.path],
    );
    if (drifted.exitCode == 0) {
      _fail('RM1 LUT check accepted drifted output');
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
