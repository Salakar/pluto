import 'dart:io';

import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('pins repository reads Flutter, engine, and firmware pins', () {
    final Directory temp = Directory.systemTemp.createTempSync('pluto-pins-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Directory pins = Directory('${temp.path}/pins')..createSync();
    File('${pins.path}/flutter.version').writeAsStringSync('3.44.4\n');
    File(
      '${pins.path}/engine.version',
    ).writeAsStringSync('a10d8ac38de835021c8d2f920dbf50a920ccc030\n');
    File(
      '${pins.path}/supported_os.json',
    ).writeAsStringSync('{"supportedOsBuilds":["20260629074044"]}');

    final PlutoPins result = PinsRepository(
      pinsDirectory: pins.path,
    ).readPins();

    expect(result.flutterVersion, '3.44.4');
    expect(result.hasConcreteEngineVersion, isTrue);
    expect(result.supportsFirmware('20260629074044'), isTrue);
    expect(result.supportsFirmware('unknown'), isFalse);
  });
}
