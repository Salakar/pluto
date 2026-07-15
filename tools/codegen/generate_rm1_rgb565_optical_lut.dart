import 'dart:io';

int _opticalLevel(int pixel) {
  final int red5 = (pixel >> 11) & 0x1f;
  final int green6 = (pixel >> 5) & 0x3f;
  final int blue5 = pixel & 0x1f;
  final int red8 = (red5 * 255 + 15) ~/ 31;
  final int green8 = (green6 * 255 + 31) ~/ 63;
  final int blue8 = (blue5 * 255 + 15) ~/ 31;
  final int luma = (54 * red8 + 183 * green8 + 19 * blue8 + 128) >> 8;
  final int scaled = luma * 15;
  int level = scaled ~/ 255;
  final int remainder = scaled - level * 255;
  if (remainder > 127 && level < 15) {
    level++;
  }
  return level * 2;
}

String _render() {
  final StringBuffer output = StringBuffer()
    ..writeln(
      '// GENERATED FILE. Run '
      'tools/codegen/generate_rm1_rgb565_optical_lut.dart.',
    )
    ..writeln('#ifndef PLUTO_GENERATED_RM1_RGB565_OPTICAL_LUT_H_')
    ..writeln('#define PLUTO_GENERATED_RM1_RGB565_OPTICAL_LUT_H_')
    ..writeln()
    ..writeln('#include <array>')
    ..writeln('#include <cstdint>')
    ..writeln()
    ..writeln('namespace pluto::native::mxcfb {')
    ..writeln()
    ..writeln('alignas(64) inline constexpr std::array<std::uint8_t, 65536>')
    ..writeln('    kRm1Rgb565OpticalLevelLut = {');
  for (int base = 0; base < 65536; base += 32) {
    output
      ..write('    ')
      ..write(
        List<String>.generate(
          32,
          (int offset) => _opticalLevel(base + offset).toString(),
          growable: false,
        ).join(', '),
      )
      ..writeln(',');
  }
  output
    ..writeln('};')
    ..writeln()
    ..writeln('} // namespace pluto::native::mxcfb')
    ..writeln()
    ..writeln('#endif // PLUTO_GENERATED_RM1_RGB565_OPTICAL_LUT_H_');
  return output.toString();
}

void main(List<String> arguments) {
  final bool check = arguments.contains('--check');
  final List<String> outputArguments = arguments
      .where((String argument) => argument != '--check')
      .toList(growable: false);
  if (arguments.any(
        (String argument) => argument != '--check' && argument.startsWith('-'),
      ) ||
      arguments.where((String argument) => argument == '--check').length > 1 ||
      outputArguments.length > 1) {
    stderr.writeln(
      'usage: dart tools/codegen/generate_rm1_rgb565_optical_lut.dart '
      '[--check] [OUTPUT]',
    );
    exitCode = 64;
    return;
  }

  final Directory repositoryRoot = File.fromUri(
    Platform.script,
  ).parent.parent.parent;
  final File outputFile = File(
    outputArguments.isEmpty
        ? '${repositoryRoot.path}/embedder/src/generated/'
              'rm1_rgb565_optical_lut.h'
        : outputArguments.single,
  );
  final String expected = _render();
  if (check) {
    if (!outputFile.existsSync() || outputFile.readAsStringSync() != expected) {
      stderr.writeln('RM1 RGB565 optical LUT is stale: ${outputFile.path}');
      stderr.writeln(
        'run: dart tools/codegen/generate_rm1_rgb565_optical_lut.dart',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('RM1 RGB565 optical LUT is current: ${outputFile.path}');
    return;
  }
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(expected);
}
