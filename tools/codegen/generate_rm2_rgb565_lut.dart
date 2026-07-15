import 'dart:io';

final BigInt _fnvOffsetBasis64 = BigInt.parse('cbf29ce484222325', radix: 16);
final BigInt _fnvPrime64 = BigInt.parse('100000001b3', radix: 16);
final BigInt _uint64Mask = BigInt.parse('ffffffffffffffff', radix: 16);

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

String _render() {
  final List<int> levels = List<int>.generate(65536, _level, growable: false);
  BigInt checksum = _fnvOffsetBasis64;
  for (final int level in levels) {
    checksum = ((checksum ^ BigInt.from(level)) * _fnvPrime64) & _uint64Mask;
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
  for (int base = 0; base < levels.length; base += 32) {
    output
      ..write('    ')
      ..write(levels.sublist(base, base + 32).join(', '))
      ..writeln(',');
  }
  output
    ..writeln('};')
    ..writeln()
    ..writeln(
      'inline constexpr std::uint64_t kRm2Rgb565LevelLutFnv1a64 = '
      '0x${checksum.toRadixString(16).padLeft(16, '0')}ULL;',
    )
    ..writeln()
    ..writeln('} // namespace pluto::native::rm2')
    ..writeln()
    ..writeln('#endif // PLUTO_GENERATED_RM2_RGB565_LUT_H_');
  return output.toString();
}

void main(List<String> arguments) {
  final bool check = arguments.length == 2 && arguments.first == '--check';
  if (arguments.length != 1 && !check) {
    stderr.writeln(
      'usage: dart tools/codegen/generate_rm2_rgb565_lut.dart '
      '[--check] OUTPUT',
    );
    exitCode = 64;
    return;
  }
  final File destination = File(arguments.last);
  final String generated = _render();
  if (check) {
    if (!destination.existsSync() ||
        destination.readAsStringSync() != generated) {
      stderr.writeln('generated RM2 RGB565 LUT drift: ${destination.path}');
      exitCode = 1;
    }
    return;
  }
  destination.writeAsStringSync(generated);
}
