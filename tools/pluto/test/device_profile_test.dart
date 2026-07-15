import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('generated runtime identities pin exact accepted releases', () {
    expect(deviceProfileById('rm1')!.runtime.firmwareBuild, '20260612085811');
    expect(
      deviceProfileById('rm1')!.runtime.kernelRelease,
      '5.4.70-v1.6.3-rm10x',
    );
    expect(deviceProfileById('rm1')!.runtime.maxResidentApps, 2);
    expect(deviceProfileById('rm1')!.runtime.takeoverQuiesceMilliseconds, 5500);
    expect(
      deviceProfileById('rm1')!.runtime.supervisorControlPollMilliseconds,
      200,
    );
    expect(deviceProfileById('rm2')!.runtime.firmwareBuild, '20260629074044');
    expect(
      deviceProfileById('rm2')!.runtime.kernelRelease,
      '5.4.70-v1.6.3-rm11x',
    );
    expect(deviceProfileById('rm2')!.runtime.maxResidentApps, 4);
    expect(deviceProfileById('rm2')!.runtime.takeoverQuiesceMilliseconds, 300);
    expect(
      deviceProfileById('rm2')!.runtime.supervisorControlPollMilliseconds,
      100,
    );
    expect(
      deviceProfileById('move')!.runtime.kernelRelease,
      '6.12.49+git-imx93-chiappa-gf4c2ab7040e8',
    );
    expect(deviceProfileById('move')!.runtime.maxResidentApps, 4);
    expect(deviceProfileById('move')!.runtime.takeoverQuiesceMilliseconds, 300);
    expect(
      deviceProfileById('move')!.runtime.supervisorControlPollMilliseconds,
      50,
    );
  });

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

  test('generated waveform option keys match native driver ownership', () {
    expect(deviceProfileById('rm1')!.runtime.waveformOptionKey, isNull);
    expect(deviceProfileById('rm2')!.runtime.waveformOptionKey, 'wbf');
    expect(deviceProfileById('move')!.runtime.waveformOptionKey, 'eink');
  });
}
