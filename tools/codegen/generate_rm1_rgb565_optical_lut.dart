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

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart tools/codegen/generate_rm1_rgb565_optical_lut.dart OUTPUT',
    );
    exitCode = 64;
    return;
  }
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
  File(arguments.single).writeAsStringSync(output.toString());
}
