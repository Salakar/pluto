import 'dart:convert';
import 'dart:io';

void main() {
  final Directory root = File.fromUri(Platform.script).parent.parent.parent;
  final String generator = File(
    '${root.path}/tools/codegen/generate_device_profiles.dart',
  ).readAsStringSync();
  final Map<String, Object?> source =
      jsonDecode(
            File('${root.path}/config/device_profiles.json').readAsStringSync(),
          )
          as Map<String, Object?>;

  _expectMappingRejected(
    generator,
    source,
    profileId: 'rm1',
    mappingBytes: null,
    message: 'rm1 MXCFB display contract has incompatible fields',
  );
  _expectMappingRejected(
    generator,
    source,
    profileId: 'rm1',
    mappingBytes: 10813439,
    message: 'rm1 MXCFB mapping does not cover virtual framebuffer',
  );
  _expectMappingRejected(
    generator,
    source,
    profileId: 'rm1',
    mappingBytes: 10813441,
    message: 'rm1 MXCFB mapping is not the exact framebuffer size',
  );
  _expectMappingRejected(
    generator,
    source,
    profileId: 'rm2',
    mappingBytes: 24893439,
    message: 'rm2 LCDIF mapping does not cover virtual framebuffer',
  );
  _expectMappingRejected(
    generator,
    source,
    profileId: 'move',
    mappingBytes: 1,
    message: 'move DRM display contract has incompatible fields',
  );
  _expectWaveformOptionRejected(
    generator,
    source,
    profileId: 'rm2',
    waveformOptionKey: 'wbf,extra',
    message: 'rm2 waveform option key is not a safe lowercase name',
  );
  _expectWaveformOptionRejected(
    generator,
    source,
    profileId: 'rm1',
    waveformOptionKey: 'eink',
    message: 'rm1 kernel-owned MXCFB waveform needs no option key',
  );
  _expectWaveformOptionRejected(
    generator,
    source,
    profileId: 'rm2',
    waveformOptionKey: null,
    message: 'rm2 LCDIF waveform option key must be wbf',
  );
  _expectWaveformOptionRejected(
    generator,
    source,
    profileId: 'move',
    waveformOptionKey: 'wbf',
    message: 'move Gallery3 waveform option key must be eink',
  );
  _expectRejected(
    generator,
    source,
    profileId: 'rm1',
    message: 'rm1 firmware build must be exactly 14 digits',
    mutateRuntime: (Map<String, Object?> runtime) {
      runtime['firmwareBuild'] = '2026061208581';
    },
  );
  _expectRejected(
    generator,
    source,
    profileId: 'rm1',
    message: 'rm1 kernel release is not a safe exact token',
    mutateRuntime: (Map<String, Object?> runtime) {
      runtime['kernelRelease'] = '5.4.70 rm1';
    },
  );

  stdout.writeln('generate_device_profiles_test: ok');
}

void _expectMappingRejected(
  String generator,
  Map<String, Object?> source, {
  required String profileId,
  required int? mappingBytes,
  required String message,
}) {
  _expectRejected(
    generator,
    source,
    profileId: profileId,
    message: message,
    mutateRuntime: (Map<String, Object?> runtime) {
      final Map<String, Object?> display =
          runtime['display']! as Map<String, Object?>;
      display['mappingBytes'] = mappingBytes;
    },
  );
}

void _expectWaveformOptionRejected(
  String generator,
  Map<String, Object?> source, {
  required String profileId,
  required String? waveformOptionKey,
  required String message,
}) {
  _expectRejected(
    generator,
    source,
    profileId: profileId,
    message: message,
    mutateRuntime: (Map<String, Object?> runtime) {
      runtime['waveformOptionKey'] = waveformOptionKey;
    },
  );
}

void _expectRejected(
  String generator,
  Map<String, Object?> source, {
  required String profileId,
  required String message,
  required void Function(Map<String, Object?> runtime) mutateRuntime,
}) {
  final Map<String, Object?> candidate =
      jsonDecode(jsonEncode(source)) as Map<String, Object?>;
  final List<Object?> profiles = candidate['profiles']! as List<Object?>;
  final Map<String, Object?> profile = profiles
      .cast<Map<String, Object?>>()
      .singleWhere((Map<String, Object?> value) => value['id'] == profileId);
  final Map<String, Object?> runtime =
      profile['runtime']! as Map<String, Object?>;
  mutateRuntime(runtime);

  final Directory temporary = Directory.systemTemp.createTempSync(
    'pluto-device-profile-generator-test-',
  );
  try {
    final Directory codegen = Directory('${temporary.path}/tools/codegen')
      ..createSync(recursive: true);
    final Directory config = Directory('${temporary.path}/config')
      ..createSync(recursive: true);
    final File script = File('${codegen.path}/generate_device_profiles.dart')
      ..writeAsStringSync(generator);
    File(
      '${config.path}/device_profiles.json',
    ).writeAsStringSync(jsonEncode(candidate));

    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>[script.path],
      environment: <String, String>{
        ...Platform.environment,
        'DART_DISABLE_ANALYTICS': '1',
        'HOME': temporary.path,
      },
    );
    if (result.exitCode != 65 || !result.stderr.toString().contains(message)) {
      throw StateError(
        'expected generator rejection "$message" for $profileId, got '
        '${result.exitCode}: ${result.stderr}',
      );
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
