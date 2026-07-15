import 'dart:io';

int _level(int pixel) {
  final int red5 = (pixel >> 11) & 0x1f;
  final int green6 = (pixel >> 5) & 0x3f;
  final int blue5 = pixel & 0x1f;
  final int red8 = (red5 << 3) | (red5 >> 2);
  final int green8 = (green6 << 2) | (green6 >> 4);
  final int blue8 = (blue5 << 3) | (blue5 >> 2);
  final int luma = (77 * red8 + 150 * green8 + 29 * blue8 + 128) >> 8;
  return (luma * 15 + 127) ~/ 255;
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart tools/codegen/generate_rm2_rgb565_lut.dart OUTPUT',
    );
    exitCode = 64;
    return;
  }
  final StringBuffer output = StringBuffer()
    ..writeln(
      '// GENERATED FILE. Run tools/codegen/generate_rm2_rgb565_lut.dart.',
    )
    ..writeln('#ifndef PLUTO_GENERATED_RM2_RGB565_LUT_H_')
    ..writeln('#define PLUTO_GENERATED_RM2_RGB565_LUT_H_')
    ..writeln()
    ..writeln('#include <array>')
    ..writeln('#include <cstdint>')
    ..writeln()
    ..writeln('namespace pluto::native::rm2 {')
    ..writeln()
    ..writeln('alignas(64) inline constexpr std::array<std::uint8_t, 65536>')
    ..writeln('    kRm2Rgb565LevelLut = {');
  for (int base = 0; base < 65536; base += 32) {
    output
      ..write('    ')
      ..write(
        List<String>.generate(
          32,
          (int offset) => _level(base + offset).toString(),
          growable: false,
        ).join(', '),
      )
      ..writeln(',');
  }
  output
    ..writeln('};')
    ..writeln()
    ..writeln('} // namespace pluto::native::rm2')
    ..writeln()
    ..writeln('#endif // PLUTO_GENERATED_RM2_RGB565_LUT_H_');
  File(arguments.single).writeAsStringSync(output.toString());
}
