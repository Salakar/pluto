import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('generated framebuffer mapping contracts preserve stock lengths', () {
    final DisplayContract rm1 = deviceProfileById('rm1')!.runtime.display;
    final DisplayContract rm2 = deviceProfileById('rm2')!.runtime.display;
    final DisplayContract move = deviceProfileById('move')!.runtime.display;

    expect(rm1.mappingBytes, 10813440);
    expect(rm1.mappingBytes, rm1.strideBytes! * rm1.virtualHeight!);

    expect(rm2.mappingBytes, 33554432);
    expect(
      rm2.mappingBytes,
      greaterThan(rm2.strideBytes! * rm2.virtualHeight!),
    );

    expect(move.mappingBytes, isNull);
  });
}
