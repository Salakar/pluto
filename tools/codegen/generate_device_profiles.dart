import 'dart:convert';
import 'dart:io';

final class _Profile {
  _Profile(Map<String, Object?> json)
    : id = _string(json, 'id'),
      wireModel = _string(json, 'wireModel'),
      codename = _string(json, 'codename'),
      marketingName = _string(json, 'marketingName'),
      testedOs = _string(json, 'testedOs'),
      targetSlice = _string(json, 'targetSlice'),
      displayDriver = _string(json, 'displayDriver'),
      identity = _Identity(_map(json, 'identity')),
      panel = _Panel(_map(json, 'panel')),
      runtime = _Runtime(_map(json, 'runtime')),
      buildModes = _strings(json, 'buildModes'),
      capabilities = _strings(json, 'capabilities');

  final String id;
  final String wireModel;
  final String codename;
  final String marketingName;
  final String testedOs;
  final String targetSlice;
  final String displayDriver;
  final _Identity identity;
  final _Panel panel;
  final _Runtime runtime;
  final List<String> buildModes;
  final List<String> capabilities;
}

final class _Identity {
  _Identity(Map<String, Object?> json)
    : architectures = _strings(json, 'architectures'),
      boardTokens = _strings(json, 'boardTokens'),
      compatibleTokens = _strings(json, 'compatibleTokens');

  final List<String> architectures;
  final List<String> boardTokens;
  final List<String> compatibleTokens;
}

final class _Panel {
  _Panel(Map<String, Object?> json)
    : width = _integer(json, 'width'),
      height = _integer(json, 'height'),
      dpi = _integer(json, 'dpi'),
      signature = _string(json, 'signature'),
      sourcePixelFormat = _string(json, 'sourcePixelFormat'),
      color = _boolean(json, 'color');

  final int width;
  final int height;
  final int dpi;
  final String signature;
  final String sourcePixelFormat;
  final bool color;
}

final class _Runtime {
  _Runtime(Map<String, Object?> json)
    : nativeSessionEnabled = _boolean(json, 'nativeSessionEnabled'),
      firmwareBuild = _string(json, 'firmwareBuild'),
      kernelRelease = _string(json, 'kernelRelease'),
      maxResidentApps = _integer(json, 'maxResidentApps'),
      takeoverQuiesceMilliseconds = _integer(
        json,
        'takeoverQuiesceMilliseconds',
      ),
      supervisorControlPollMilliseconds = _integer(
        json,
        'supervisorControlPollMilliseconds',
      ),
      displayDevice = _string(json, 'displayDevice'),
      display = _DisplayContract(_map(json, 'display')),
      waveform = _Waveform(_map(json, 'waveform')),
      waveformOptionKey = _optionalString(json, 'waveformOptionKey'),
      presenterOptions = _optionalString(json, 'presenterOptions'),
      pen = _InputDevice(_map(json, 'pen')),
      touch = _InputDevice(_map(json, 'touch')),
      powerKey = _InputDevice(_map(json, 'powerKey')),
      frontlightBrightnessPath = _optionalString(
        json,
        'frontlightBrightnessPath',
      ),
      vpddTimeoutPath = _optionalString(json, 'vpddTimeoutPath'),
      bezelRedrawIioPath = _optionalString(json, 'bezelRedrawIioPath'),
      bezelRedrawEnablePath = _optionalString(json, 'bezelRedrawEnablePath'),
      recovery = _Recovery(_map(json, 'recovery')),
      suspendCommand = _string(json, 'suspendCommand');

  final bool nativeSessionEnabled;
  final String firmwareBuild;
  final String kernelRelease;
  final int maxResidentApps;
  final int takeoverQuiesceMilliseconds;
  final int supervisorControlPollMilliseconds;
  final String displayDevice;
  final _DisplayContract display;
  final _Waveform waveform;
  final String? waveformOptionKey;
  final String? presenterOptions;
  final _InputDevice pen;
  final _InputDevice touch;
  final _InputDevice powerKey;
  final String? frontlightBrightnessPath;
  final String? vpddTimeoutPath;
  final String? bezelRedrawIioPath;
  final String? bezelRedrawEnablePath;
  final _Recovery recovery;
  final String suspendCommand;
}

final class _Recovery {
  _Recovery(Map<String, Object?> json)
    : confirmationStrategy = _string(json, 'confirmationStrategy'),
      failureStrategy = _string(json, 'failureStrategy'),
      bootDefaultEnabled = _boolean(json, 'bootDefaultEnabled'),
      mmcDevice = _optionalString(json, 'mmcDevice'),
      rootPartitions = _optionalIntegers(json, 'rootPartitions'),
      expectedBootLimit = _optionalPositiveInteger(json, 'expectedBootLimit'),
      helperPath = _optionalString(json, 'helperPath'),
      counterDirectory = _optionalString(json, 'counterDirectory');

  final String confirmationStrategy;
  final String failureStrategy;
  final bool bootDefaultEnabled;
  final String? mmcDevice;
  final List<int>? rootPartitions;
  final int? expectedBootLimit;
  final String? helperPath;
  final String? counterDirectory;
}

final class _DisplayContract {
  _DisplayContract(Map<String, Object?> json)
    : scanoutWidth = _integer(json, 'scanoutWidth'),
      scanoutHeight = _integer(json, 'scanoutHeight'),
      virtualWidth = _optionalPositiveInteger(json, 'virtualWidth'),
      virtualHeight = _optionalPositiveInteger(json, 'virtualHeight'),
      strideBytes = _optionalPositiveInteger(json, 'strideBytes'),
      mappingBytes = _optionalPositiveInteger(json, 'mappingBytes'),
      bitsPerPixel = _integer(json, 'bitsPerPixel'),
      rotation = _optionalNonnegativeInteger(json, 'rotation'),
      bufferSlots = _optionalPositiveInteger(json, 'bufferSlots'),
      slotBytes = _optionalPositiveInteger(json, 'slotBytes'),
      damageAlignmentPixels = _integer(json, 'damageAlignmentPixels'),
      phaseIntervalNanoseconds = _optionalPositiveInteger(
        json,
        'phaseIntervalNanoseconds',
      );

  final int scanoutWidth;
  final int scanoutHeight;
  final int? virtualWidth;
  final int? virtualHeight;
  final int? strideBytes;
  final int? mappingBytes;
  final int bitsPerPixel;
  final int? rotation;
  final int? bufferSlots;
  final int? slotBytes;
  final int damageAlignmentPixels;
  final int? phaseIntervalNanoseconds;
}

final class _Waveform {
  _Waveform(Map<String, Object?> json)
    : discoveryPaths = _strings(json, 'discoveryPaths'),
      acceptedSources = _maps(
        json,
        'acceptedSources',
      ).map(_WaveformSource.new).toList(growable: false);

  final List<String> discoveryPaths;
  final List<_WaveformSource> acceptedSources;
}

final class _WaveformSource {
  _WaveformSource(Map<String, Object?> json)
    : path = _string(json, 'path'),
      sha256 = _string(json, 'sha256'),
      panelSignature = _string(json, 'panelSignature');

  final String path;
  final String sha256;
  final String panelSignature;
}

final class _InputDevice {
  _InputDevice(Map<String, Object?> json)
    : byPath = _string(json, 'byPath'),
      name = _string(json, 'name');

  final String byPath;
  final String name;
}

void main(List<String> arguments) {
  if (arguments.any((String argument) => argument != '--check')) {
    stderr.writeln(
      'usage: dart tools/codegen/generate_device_profiles.dart [--check]',
    );
    exitCode = 64;
    return;
  }
  final bool check = arguments.contains('--check');
  final Directory root = File.fromUri(Platform.script).parent.parent.parent;
  final File source = File('${root.path}/config/device_profiles.json');
  final Object? decoded = jsonDecode(source.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    _fail('profile source must contain a JSON object');
  }
  final Object? rawProfiles = decoded['profiles'];
  if (rawProfiles is! List<Object?> || rawProfiles.isEmpty) {
    _fail('profiles must be a non-empty JSON array');
  }
  final List<_Profile> profiles = rawProfiles
      .map((Object? value) {
        if (value is! Map<String, Object?>) {
          _fail('every profile must be a JSON object');
        }
        return _Profile(value);
      })
      .toList(growable: false);
  _validate(profiles);

  final Map<String, String> outputs = <String, String>{
    'embedder/src/generated/device_profiles.h': _cpp(profiles),
    'tools/pluto/lib/src/device/generated/device_profiles.g.dart': _formatDart(
      _dart(profiles),
    ),
    'packages/pluto_device/lib/src/generated/remarkable_models.g.dart':
        _formatDart(_deviceModelsDart(profiles)),
    'tools/device/generated/device-profiles.sh': _shell(profiles),
    'docs/generated/device-support-matrix.md': _markdown(profiles),
  };

  bool drift = false;
  for (final MapEntry<String, String> output in outputs.entries) {
    final File file = File('${root.path}/${output.key}');
    if (check) {
      if (!file.existsSync() || file.readAsStringSync() != output.value) {
        stderr.writeln('generated device profile drift: ${output.key}');
        drift = true;
      }
      continue;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(output.value);
    stdout.writeln(output.key);
  }
  if (drift) {
    stderr.writeln('run: dart tools/codegen/generate_device_profiles.dart');
    exitCode = 1;
  }
}

String _formatDart(String source) {
  final Directory directory = Directory.systemTemp.createTempSync(
    'pluto-device-profiles-',
  );
  try {
    final File file = File('${directory.path}/device_profiles.g.dart')
      ..writeAsStringSync(source);
    final ProcessResult result = Process.runSync(
      Platform.resolvedExecutable,
      <String>['format', file.path],
      environment: <String, String>{
        ...Platform.environment,
        'DART_DISABLE_ANALYTICS': '1',
        'HOME': Directory.systemTemp.path,
      },
    );
    if (result.exitCode != 0) {
      _fail('dart format failed for generated output: ${result.stderr}');
    }
    return file.readAsStringSync();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Never _fail(String message) {
  stderr.writeln('device profile source: $message');
  exit(65);
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! Map<String, Object?>) {
    _fail('$key must be an object');
  }
  return value;
}

List<Map<String, Object?>> _maps(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?> || value.isEmpty) {
    _fail('$key must be a non-empty object array');
  }
  return value
      .map((Object? item) {
        if (item is! Map<String, Object?>) {
          _fail('$key must contain only objects');
        }
        return item;
      })
      .toList(growable: false);
}

String _string(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    _fail('$key must be a non-empty string');
  }
  return value.trim();
}

String? _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    _fail('$key must be null or a non-empty string');
  }
  return value.trim();
}

int _integer(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int || value <= 0) {
    _fail('$key must be a positive integer');
  }
  return value;
}

int? _optionalPositiveInteger(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int || value <= 0) {
    _fail('$key must be null or a positive integer');
  }
  return value;
}

int? _optionalNonnegativeInteger(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int || value < 0) {
    _fail('$key must be null or a nonnegative integer');
  }
  return value;
}

List<int>? _optionalIntegers(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! List<Object?> || value.isEmpty) {
    _fail('$key must be null or a non-empty positive integer array');
  }
  return value
      .map((Object? item) {
        if (item is! int || item <= 0) {
          _fail('$key must contain only positive integers');
        }
        return item;
      })
      .toList(growable: false);
}

bool _boolean(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! bool) {
    _fail('$key must be a boolean');
  }
  return value;
}

List<String> _strings(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?> || value.isEmpty) {
    _fail('$key must be a non-empty string array');
  }
  return value
      .map((Object? item) {
        if (item is! String || item.trim().isEmpty) {
          _fail('$key must contain only non-empty strings');
        }
        return item.trim();
      })
      .toList(growable: false);
}

void _validate(List<_Profile> profiles) {
  final Set<String> ids = <String>{};
  final Set<String> codenames = <String>{};
  final Set<String> wireModels = <String>{};
  for (final _Profile profile in profiles) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(profile.id)) {
      _fail('invalid profile id ${profile.id}');
    }
    if (!ids.add(profile.id)) {
      _fail('duplicate profile id ${profile.id}');
    }
    if (!codenames.add(profile.codename)) {
      _fail('duplicate codename ${profile.codename}');
    }
    if (!wireModels.add(profile.wireModel)) {
      _fail('duplicate wire model ${profile.wireModel}');
    }
    if (!const <String>{
      'linux-arm',
      'linux-arm64',
    }.contains(profile.targetSlice)) {
      _fail('unsupported target slice ${profile.targetSlice}');
    }
    if (!const <String>{
      'mxcfb_epdc',
      'lcdif_tcon',
      'gallery3_drm',
    }.contains(profile.displayDriver)) {
      _fail('unsupported display driver ${profile.displayDriver}');
    }
    for (final String token in <String>[
      ...profile.identity.architectures,
      ...profile.identity.boardTokens,
      ...profile.identity.compatibleTokens,
    ]) {
      if (token != token.toLowerCase()) {
        _fail('${profile.id} identity token must be lowercase: $token');
      }
    }
    if (profile.panel.color !=
        profile.capabilities.contains('color-quantization')) {
      _fail(
        '${profile.id} color panel and color-quantization capability disagree',
      );
    }
    if (!RegExp(r'^[0-9]{14}$').hasMatch(profile.runtime.firmwareBuild)) {
      _fail('${profile.id} firmware build must be exactly 14 digits');
    }
    if (!RegExp(
      r'^[A-Za-z0-9._+-]+$',
    ).hasMatch(profile.runtime.kernelRelease)) {
      _fail('${profile.id} kernel release is not a safe exact token');
    }
    if (profile.runtime.maxResidentApps > 8) {
      _fail('${profile.id} max resident apps must be in 1..8');
    }
    if (profile.runtime.takeoverQuiesceMilliseconds > 10000) {
      _fail('${profile.id} panel takeover quiesce exceeds 10 seconds');
    }
    if (profile.runtime.supervisorControlPollMilliseconds < 25 ||
        profile.runtime.supervisorControlPollMilliseconds > 1000) {
      _fail('${profile.id} supervisor control poll must be in 25..1000 ms');
    }
    _validateDisplayContract(profile);
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(profile.panel.signature)) {
      _fail('${profile.id} panel signature is not shell-safe');
    }
    final Set<String> discoveryPaths = <String>{};
    for (final String path in profile.runtime.waveform.discoveryPaths) {
      if (!discoveryPaths.add(path)) {
        _fail('${profile.id} has duplicate waveform discovery path: $path');
      }
      _validateRuntimePath(profile.id, path);
      _validateWaveformField(profile.id, 'discovery path', path);
    }
    final Set<String> acceptedPaths = <String>{};
    for (final _WaveformSource source
        in profile.runtime.waveform.acceptedSources) {
      if (!acceptedPaths.add(source.path)) {
        _fail('${profile.id} has duplicate accepted waveform: ${source.path}');
      }
      if (!discoveryPaths.contains(source.path)) {
        _fail(
          '${profile.id} accepted waveform is not a discovery candidate: ${source.path}',
        );
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(source.sha256)) {
        _fail('${profile.id} waveform SHA-256 must be lowercase hexadecimal');
      }
      if (source.panelSignature != profile.panel.signature) {
        _fail(
          '${profile.id} accepted waveform panel ${source.panelSignature} does not match ${profile.panel.signature}',
        );
      }
      _validateWaveformField(profile.id, 'accepted path', source.path);
      _validateWaveformField(profile.id, 'accepted digest', source.sha256);
      _validateWaveformField(
        profile.id,
        'accepted panel',
        source.panelSignature,
      );
    }
    _validateWaveformOptionContract(profile);
    _validatePresenterOptionsContract(profile);
    for (final String path in <String>[
      profile.runtime.displayDevice,
      profile.runtime.pen.byPath,
      profile.runtime.touch.byPath,
      profile.runtime.powerKey.byPath,
      ?profile.runtime.frontlightBrightnessPath,
      ?profile.runtime.vpddTimeoutPath,
      ?profile.runtime.bezelRedrawIioPath,
      ?profile.runtime.bezelRedrawEnablePath,
      ?profile.runtime.recovery.mmcDevice,
      ?profile.runtime.recovery.helperPath,
      ?profile.runtime.recovery.counterDirectory,
    ]) {
      _validateRuntimePath(profile.id, path);
    }
    final bool hasFrontlight = profile.capabilities.contains('frontlight');
    if (hasFrontlight != (profile.runtime.frontlightBrightnessPath != null)) {
      _fail('${profile.id} frontlight capability and path disagree');
    }
    if ((profile.runtime.bezelRedrawIioPath == null) !=
        (profile.runtime.bezelRedrawEnablePath == null)) {
      _fail('${profile.id} bezel redraw paths must both be present or absent');
    }
    _validateRecoveryContract(profile);
  }
}

void _validatePresenterOptionsContract(_Profile profile) {
  switch (profile.displayDriver) {
    case 'gallery3_drm':
      if (profile.runtime.presenterOptions !=
          'exact_color=1,enable_rails=1,vcom=-0.62') {
        _fail('${profile.id} Gallery3 presenter options are not canonical');
      }
      break;
    case 'mxcfb_epdc':
    case 'lcdif_tcon':
      if (profile.runtime.presenterOptions != null) {
        _fail('${profile.id} native presenter options must be absent');
      }
      break;
    default:
      _fail('${profile.id} has an unvalidated presenter options driver');
  }
}

void _validateWaveformOptionContract(_Profile profile) {
  final String? optionKey = profile.runtime.waveformOptionKey;
  if (optionKey != null && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(optionKey)) {
    _fail('${profile.id} waveform option key is not a safe lowercase name');
  }
  switch (profile.displayDriver) {
    case 'mxcfb_epdc':
      if (optionKey != null) {
        _fail('${profile.id} kernel-owned MXCFB waveform needs no option key');
      }
      break;
    case 'lcdif_tcon':
      if (optionKey != 'wbf') {
        _fail('${profile.id} LCDIF waveform option key must be wbf');
      }
      break;
    case 'gallery3_drm':
      if (optionKey != 'eink') {
        _fail('${profile.id} Gallery3 waveform option key must be eink');
      }
      break;
    default:
      _fail('${profile.id} has an unvalidated waveform option driver');
  }
}

void _validateRuntimePath(String profileId, String path) {
  if (!path.startsWith('/') || path.contains('/../') || path.endsWith('/..')) {
    _fail('$profileId runtime path must be absolute and normalized: $path');
  }
}

void _validateDisplayContract(_Profile profile) {
  final _DisplayContract display = profile.runtime.display;
  if (display.bitsPerPixel % 8 != 0 || display.bitsPerPixel > 64) {
    _fail('${profile.id} display bitsPerPixel must be byte-aligned and <= 64');
  }
  if (display.rotation != null && display.rotation! > 3) {
    _fail('${profile.id} framebuffer rotation must be in 0..3 or absent');
  }
  if ((display.virtualWidth == null) != (display.virtualHeight == null)) {
    _fail(
      '${profile.id} virtual display dimensions must both be set or absent',
    );
  }
  if ((display.bufferSlots == null) != (display.slotBytes == null)) {
    _fail(
      '${profile.id} display slot count and size must both be set or absent',
    );
  }
  if (!_isPowerOfTwo(display.damageAlignmentPixels)) {
    _fail('${profile.id} damage alignment must be a positive power of two');
  }

  final int bytesPerPixel = display.bitsPerPixel ~/ 8;
  final int tightRowBytes = display.scanoutWidth * bytesPerPixel;
  int? virtualFootprintBytes;
  if (display.virtualWidth != null) {
    if (display.virtualWidth! < display.scanoutWidth ||
        display.virtualHeight! < display.scanoutHeight) {
      _fail('${profile.id} virtual display is smaller than scanout');
    }
    final int minimumStride = display.virtualWidth! * bytesPerPixel;
    if (display.strideBytes == null || display.strideBytes! < minimumStride) {
      _fail('${profile.id} framebuffer stride does not cover virtual width');
    }
    virtualFootprintBytes = display.strideBytes! * display.virtualHeight!;
  } else if (display.strideBytes != null) {
    _fail('${profile.id} stride requires virtual framebuffer dimensions');
  }
  if (display.slotBytes != null) {
    final int minimumSlotBytes = display.strideBytes == null
        ? tightRowBytes * display.scanoutHeight
        : display.strideBytes! * display.scanoutHeight;
    if (display.slotBytes != minimumSlotBytes) {
      _fail('${profile.id} scanout slot size is not exact row geometry');
    }
    if (display.virtualHeight != null &&
        display.virtualHeight != display.scanoutHeight * display.bufferSlots!) {
      _fail('${profile.id} virtual height does not equal its scanout slots');
    }
  }

  switch (profile.displayDriver) {
    case 'mxcfb_epdc':
      if (display.virtualWidth == null ||
          display.strideBytes == null ||
          display.mappingBytes == null ||
          display.rotation == null ||
          display.bufferSlots != null ||
          display.phaseIntervalNanoseconds != null) {
        _fail('${profile.id} MXCFB display contract has incompatible fields');
      }
      if (display.mappingBytes! < virtualFootprintBytes!) {
        _fail('${profile.id} MXCFB mapping does not cover virtual framebuffer');
      }
      if (display.mappingBytes != virtualFootprintBytes) {
        _fail('${profile.id} MXCFB mapping is not the exact framebuffer size');
      }
      break;
    case 'lcdif_tcon':
      if (display.virtualWidth == null ||
          display.strideBytes == null ||
          display.mappingBytes == null ||
          display.rotation == null ||
          display.bufferSlots == null ||
          display.phaseIntervalNanoseconds == null) {
        _fail('${profile.id} LCDIF display contract is incomplete');
      }
      if (display.mappingBytes! < virtualFootprintBytes!) {
        _fail('${profile.id} LCDIF mapping does not cover virtual framebuffer');
      }
      break;
    case 'gallery3_drm':
      if (display.virtualWidth != null ||
          display.strideBytes != null ||
          display.mappingBytes != null ||
          display.rotation != null ||
          display.bufferSlots == null ||
          display.phaseIntervalNanoseconds == null) {
        _fail('${profile.id} DRM display contract has incompatible fields');
      }
      break;
    default:
      _fail('${profile.id} has an unvalidated display driver');
  }
}

void _validateRecoveryContract(_Profile profile) {
  final _Recovery recovery = profile.runtime.recovery;
  switch (recovery.confirmationStrategy) {
    case 'uboot_env':
      if (recovery.mmcDevice == null ||
          !RegExp(r'^/dev/mmcblk[0-9]+$').hasMatch(recovery.mmcDevice!) ||
          recovery.rootPartitions == null ||
          recovery.rootPartitions!.length != 2 ||
          recovery.rootPartitions!.toSet().length != 2 ||
          recovery.rootPartitions!.any((int partition) => partition <= 0) ||
          recovery.expectedBootLimit == null ||
          recovery.failureStrategy != 'uboot_env_force_reboot' ||
          recovery.helperPath != null ||
          recovery.counterDirectory != null) {
        _fail('${profile.id} U-Boot environment recovery contract is invalid');
      }
      break;
    case 'lpgpr_counter':
      if (recovery.mmcDevice != null ||
          recovery.rootPartitions != null ||
          recovery.expectedBootLimit != null ||
          recovery.failureStrategy != 'unverified' ||
          recovery.bootDefaultEnabled ||
          recovery.helperPath == null ||
          !recovery.helperPath!.startsWith('/') ||
          recovery.counterDirectory == null ||
          !recovery.counterDirectory!.startsWith('/')) {
        _fail('${profile.id} LPGPR helper recovery contract is invalid');
      }
      break;
    default:
      _fail('${profile.id} confirmation strategy is unsupported');
  }
}

bool _isPowerOfTwo(int value) => value > 0 && (value & (value - 1)) == 0;

void _validateWaveformField(String profileId, String role, String value) {
  if (value.contains('|') || value.contains('\n') || value.contains('\r')) {
    _fail('$profileId waveform $role contains a reserved delimiter');
  }
}

String _cpp(List<_Profile> profiles) {
  final StringBuffer output = StringBuffer()
    ..writeln('// GENERATED FILE. Edit config/device_profiles.json, then run')
    ..writeln('// dart tools/codegen/generate_device_profiles.dart.')
    ..writeln('#ifndef PLUTO_GENERATED_DEVICE_PROFILES_H_')
    ..writeln('#define PLUTO_GENERATED_DEVICE_PROFILES_H_')
    ..writeln()
    ..writeln('#include <array>')
    ..writeln('#include <cstdint>')
    ..writeln('#include <optional>')
    ..writeln('#include <span>')
    ..writeln('#include <string_view>')
    ..writeln()
    ..writeln('namespace pluto {')
    ..writeln()
    ..writeln('enum class DeviceTargetSlice { kLinuxArm, kLinuxArm64 };')
    ..writeln('enum class NativeDisplayDriverKind {')
    ..writeln('  kMxcfbEpdc,')
    ..writeln('  kLcdifTcon,')
    ..writeln('  kGallery3Drm,')
    ..writeln('};')
    ..writeln('enum class GeneratedBootConfirmationStrategy {')
    ..writeln('  kUbootEnv,')
    ..writeln('  kLpgprCounter,')
    ..writeln('};')
    ..writeln('enum class GeneratedBootFailureStrategy {')
    ..writeln('  kUbootEnvForceReboot,')
    ..writeln('  kUnverified,')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedPanelProfile {')
    ..writeln('  int width;')
    ..writeln('  int height;')
    ..writeln('  int dpi;')
    ..writeln('  std::string_view signature;')
    ..writeln('  std::string_view source_pixel_format;')
    ..writeln('  bool color;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedInputDeviceProfile {')
    ..writeln('  std::string_view by_path;')
    ..writeln('  std::string_view name;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedDisplayContract {')
    ..writeln('  std::uint32_t scanout_width;')
    ..writeln('  std::uint32_t scanout_height;')
    ..writeln('  std::optional<std::uint32_t> virtual_width;')
    ..writeln('  std::optional<std::uint32_t> virtual_height;')
    ..writeln('  std::optional<std::uint32_t> stride_bytes;')
    ..writeln('  std::optional<std::uint64_t> mapping_bytes;')
    ..writeln('  std::uint32_t bits_per_pixel;')
    ..writeln('  std::optional<std::uint32_t> rotation;')
    ..writeln('  std::optional<std::uint32_t> buffer_slots;')
    ..writeln('  std::optional<std::uint32_t> slot_bytes;')
    ..writeln('  std::uint32_t damage_alignment_pixels;')
    ..writeln('  std::optional<std::uint64_t> phase_interval_nanoseconds;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedRecoveryContract {')
    ..writeln('  GeneratedBootConfirmationStrategy confirmation_strategy;')
    ..writeln('  GeneratedBootFailureStrategy failure_strategy;')
    ..writeln('  bool boot_default_enabled;')
    ..writeln('  std::string_view mmc_device;')
    ..writeln('  std::optional<std::array<std::uint32_t, 2>> root_partitions;')
    ..writeln('  std::optional<std::uint32_t> expected_boot_limit;')
    ..writeln('  std::string_view helper_path;')
    ..writeln('  std::string_view counter_directory;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedWaveformSourceProfile {')
    ..writeln('  std::string_view path;')
    ..writeln('  std::string_view sha256;')
    ..writeln('  std::string_view panel_signature;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedWaveformProfile {')
    ..writeln('  std::span<const std::string_view> discovery_paths;')
    ..writeln(
      '  std::span<const GeneratedWaveformSourceProfile> accepted_sources;',
    )
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedRuntimeProfile {')
    ..writeln('  bool native_session_enabled;')
    ..writeln('  std::string_view firmware_build;')
    ..writeln('  std::string_view kernel_release;')
    ..writeln('  std::uint32_t max_resident_apps;')
    ..writeln('  std::uint32_t takeover_quiesce_milliseconds;')
    ..writeln('  std::uint32_t supervisor_control_poll_milliseconds;')
    ..writeln('  std::string_view display_device;')
    ..writeln('  GeneratedDisplayContract display;')
    ..writeln('  GeneratedWaveformProfile waveform;')
    ..writeln('  std::optional<std::string_view> waveform_option_key;')
    ..writeln('  std::string_view presenter_options;')
    ..writeln('  GeneratedInputDeviceProfile pen;')
    ..writeln('  GeneratedInputDeviceProfile touch;')
    ..writeln('  GeneratedInputDeviceProfile power_key;')
    ..writeln('  std::string_view frontlight_brightness_path;')
    ..writeln('  std::string_view vpdd_timeout_path;')
    ..writeln('  std::string_view bezel_redraw_iio_path;')
    ..writeln('  std::string_view bezel_redraw_enable_path;')
    ..writeln('  GeneratedRecoveryContract recovery;')
    ..writeln('  std::string_view suspend_command;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedDeviceProfile {')
    ..writeln('  std::string_view id;')
    ..writeln('  std::string_view wire_model;')
    ..writeln('  std::string_view codename;')
    ..writeln('  std::string_view marketing_name;')
    ..writeln('  std::string_view tested_os;')
    ..writeln('  DeviceTargetSlice target_slice;')
    ..writeln('  NativeDisplayDriverKind display_driver;')
    ..writeln('  GeneratedPanelProfile panel;')
    ..writeln('  GeneratedRuntimeProfile runtime;')
    ..writeln('  std::span<const std::string_view> architectures;')
    ..writeln('  std::span<const std::string_view> board_tokens;')
    ..writeln('  std::span<const std::string_view> compatible_tokens;')
    ..writeln('  std::span<const std::string_view> build_modes;')
    ..writeln('  std::span<const std::string_view> capabilities;')
    ..writeln('};')
    ..writeln()
    ..writeln('struct GeneratedDeviceIdentityFixture {')
    ..writeln('  std::string_view profile_id;')
    ..writeln('  std::string_view machine;')
    ..writeln('  std::string_view device_tree_model;')
    ..writeln('  std::string_view device_tree_compatible;')
    ..writeln('  std::string_view architecture;')
    ..writeln('};')
    ..writeln();

  for (final _Profile profile in profiles) {
    final String prefix = _cppName(profile.id);
    _cppArray(output, '${prefix}Architectures', profile.identity.architectures);
    _cppArray(output, '${prefix}BoardTokens', profile.identity.boardTokens);
    _cppArray(
      output,
      '${prefix}CompatibleTokens',
      profile.identity.compatibleTokens,
    );
    _cppArray(output, '${prefix}BuildModes', profile.buildModes);
    _cppArray(output, '${prefix}Capabilities', profile.capabilities);
    _cppArray(
      output,
      '${prefix}WaveformDiscoveryPaths',
      profile.runtime.waveform.discoveryPaths,
    );
    _cppWaveformSourceArray(
      output,
      '${prefix}AcceptedWaveformSources',
      profile.runtime.waveform.acceptedSources,
    );
  }

  output
    ..writeln(
      'inline constexpr std::array<GeneratedDeviceProfile, ${profiles.length}>',
    )
    ..writeln('    kGeneratedDeviceProfiles = {{');
  for (final _Profile profile in profiles) {
    final String prefix = _cppName(profile.id);
    output
      ..writeln('        {')
      ..writeln('            .id = ${_cppString(profile.id)},')
      ..writeln('            .wire_model = ${_cppString(profile.wireModel)},')
      ..writeln('            .codename = ${_cppString(profile.codename)},')
      ..writeln(
        '            .marketing_name = ${_cppString(profile.marketingName)},',
      )
      ..writeln('            .tested_os = ${_cppString(profile.testedOs)},')
      ..writeln(
        '            .target_slice = DeviceTargetSlice::${_cppTarget(profile.targetSlice)},',
      )
      ..writeln(
        '            .display_driver = NativeDisplayDriverKind::${_cppDriver(profile.displayDriver)},',
      )
      ..writeln('            .panel =')
      ..writeln('                {')
      ..writeln('                    .width = ${profile.panel.width},')
      ..writeln('                    .height = ${profile.panel.height},')
      ..writeln('                    .dpi = ${profile.panel.dpi},')
      ..writeln(
        '                    .signature = ${_cppString(profile.panel.signature)},',
      )
      ..writeln(
        '                    .source_pixel_format = ${_cppString(profile.panel.sourcePixelFormat)},',
      )
      ..writeln('                    .color = ${profile.panel.color},')
      ..writeln('                },')
      ..writeln('            .runtime =')
      ..writeln('                {')
      ..writeln(
        '                    .native_session_enabled = ${profile.runtime.nativeSessionEnabled},',
      )
      ..writeln(
        '                    .firmware_build = ${_cppString(profile.runtime.firmwareBuild)},',
      )
      ..writeln(
        '                    .kernel_release = ${_cppString(profile.runtime.kernelRelease)},',
      )
      ..writeln(
        '                    .max_resident_apps = ${profile.runtime.maxResidentApps},',
      )
      ..writeln(
        '                    .takeover_quiesce_milliseconds = ${profile.runtime.takeoverQuiesceMilliseconds},',
      )
      ..writeln(
        '                    .supervisor_control_poll_milliseconds = ${profile.runtime.supervisorControlPollMilliseconds},',
      )
      ..writeln(
        '                    .display_device = ${_cppString(profile.runtime.displayDevice)},',
      )
      ..writeln('                    .display =')
      ..writeln('                        {')
      ..writeln(
        '                            .scanout_width = ${profile.runtime.display.scanoutWidth},',
      )
      ..writeln(
        '                            .scanout_height = ${profile.runtime.display.scanoutHeight},',
      )
      ..writeln(
        '                            .virtual_width = ${_cppOptionalInt(profile.runtime.display.virtualWidth)},',
      )
      ..writeln(
        '                            .virtual_height = ${_cppOptionalInt(profile.runtime.display.virtualHeight)},',
      )
      ..writeln(
        '                            .stride_bytes = ${_cppOptionalInt(profile.runtime.display.strideBytes)},',
      )
      ..writeln(
        '                            .mapping_bytes = ${_cppOptionalInt(profile.runtime.display.mappingBytes)},',
      )
      ..writeln(
        '                            .bits_per_pixel = ${profile.runtime.display.bitsPerPixel},',
      )
      ..writeln(
        '                            .rotation = ${_cppOptionalInt(profile.runtime.display.rotation)},',
      )
      ..writeln(
        '                            .buffer_slots = ${_cppOptionalInt(profile.runtime.display.bufferSlots)},',
      )
      ..writeln(
        '                            .slot_bytes = ${_cppOptionalInt(profile.runtime.display.slotBytes)},',
      )
      ..writeln(
        '                            .damage_alignment_pixels = ${profile.runtime.display.damageAlignmentPixels},',
      )
      ..writeln(
        '                            .phase_interval_nanoseconds = ${_cppOptionalInt(profile.runtime.display.phaseIntervalNanoseconds)},',
      )
      ..writeln('                        },')
      ..writeln('                    .waveform =')
      ..writeln('                        {')
      ..writeln(
        '                            .discovery_paths = k${prefix}WaveformDiscoveryPaths,',
      )
      ..writeln(
        '                            .accepted_sources = k${prefix}AcceptedWaveformSources,',
      )
      ..writeln('                        },')
      ..writeln(
        '                    .waveform_option_key = ${_cppOptionalString(profile.runtime.waveformOptionKey)},',
      )
      ..writeln(
        '                    .presenter_options = ${_cppString(profile.runtime.presenterOptions ?? '')},',
      )
      ..writeln('                    .pen =')
      ..writeln('                        {')
      ..writeln(
        '                            .by_path = ${_cppString(profile.runtime.pen.byPath)},',
      )
      ..writeln(
        '                            .name = ${_cppString(profile.runtime.pen.name)},',
      )
      ..writeln('                        },')
      ..writeln('                    .touch =')
      ..writeln('                        {')
      ..writeln(
        '                            .by_path = ${_cppString(profile.runtime.touch.byPath)},',
      )
      ..writeln(
        '                            .name = ${_cppString(profile.runtime.touch.name)},',
      )
      ..writeln('                        },')
      ..writeln('                    .power_key =')
      ..writeln('                        {')
      ..writeln(
        '                            .by_path = ${_cppString(profile.runtime.powerKey.byPath)},',
      )
      ..writeln(
        '                            .name = ${_cppString(profile.runtime.powerKey.name)},',
      )
      ..writeln('                        },')
      ..writeln(
        '                    .frontlight_brightness_path = ${_cppString(profile.runtime.frontlightBrightnessPath ?? '')},',
      )
      ..writeln(
        '                    .vpdd_timeout_path = ${_cppString(profile.runtime.vpddTimeoutPath ?? '')},',
      )
      ..writeln(
        '                    .bezel_redraw_iio_path = ${_cppString(profile.runtime.bezelRedrawIioPath ?? '')},',
      )
      ..writeln(
        '                    .bezel_redraw_enable_path = ${_cppString(profile.runtime.bezelRedrawEnablePath ?? '')},',
      )
      ..writeln('                    .recovery =')
      ..writeln('                        {')
      ..writeln(
        '                            .confirmation_strategy = GeneratedBootConfirmationStrategy::${_cppConfirmationStrategy(profile.runtime.recovery.confirmationStrategy)},',
      )
      ..writeln(
        '                            .failure_strategy = GeneratedBootFailureStrategy::${_cppFailureStrategy(profile.runtime.recovery.failureStrategy)},',
      )
      ..writeln(
        '                            .boot_default_enabled = ${profile.runtime.recovery.bootDefaultEnabled},',
      )
      ..writeln(
        '                            .mmc_device = ${_cppString(profile.runtime.recovery.mmcDevice ?? '')},',
      )
      ..writeln(
        '                            .root_partitions = ${_cppOptionalIntArray2(profile.runtime.recovery.rootPartitions)},',
      )
      ..writeln(
        '                            .expected_boot_limit = ${_cppOptionalInt(profile.runtime.recovery.expectedBootLimit)},',
      )
      ..writeln(
        '                            .helper_path = ${_cppString(profile.runtime.recovery.helperPath ?? '')},',
      )
      ..writeln(
        '                            .counter_directory = ${_cppString(profile.runtime.recovery.counterDirectory ?? '')},',
      )
      ..writeln('                        },')
      ..writeln(
        '                    .suspend_command = ${_cppString(profile.runtime.suspendCommand)},',
      )
      ..writeln('                },')
      ..writeln(
        '            .architectures = k$prefix'
        'Architectures,',
      )
      ..writeln(
        '            .board_tokens = k$prefix'
        'BoardTokens,',
      )
      ..writeln(
        '            .compatible_tokens = k$prefix'
        'CompatibleTokens,',
      )
      ..writeln(
        '            .build_modes = k$prefix'
        'BuildModes,',
      )
      ..writeln(
        '            .capabilities = k$prefix'
        'Capabilities,',
      )
      ..writeln('        },');
  }
  output
    ..writeln('    }};')
    ..writeln()
    ..writeln('inline constexpr const GeneratedDeviceProfile *')
    ..writeln('generated_device_profile_by_id(std::string_view id) {')
    ..writeln(
      '  for (const GeneratedDeviceProfile &profile : kGeneratedDeviceProfiles) {',
    )
    ..writeln('    if (profile.id == id) {')
    ..writeln('      return &profile;')
    ..writeln('    }')
    ..writeln('  }')
    ..writeln('  return nullptr;')
    ..writeln('}')
    ..writeln();

  final List<({String profileId, String board, String compatible, String arch})>
  accepted = _acceptedFixtures(profiles);
  output
    ..writeln(
      'inline constexpr std::array<GeneratedDeviceIdentityFixture, ${accepted.length}>',
    )
    ..writeln('    kGeneratedAcceptedDeviceIdentityFixtures = {{');
  for (int index = 0; index < accepted.length; index += 1) {
    final fixture = accepted[index];
    final bool useModel = index.isOdd;
    output
      ..writeln('        {')
      ..writeln('            .profile_id = ${_cppString(fixture.profileId)},')
      ..writeln(
        '            .machine = ${_cppString(useModel ? '' : fixture.board)},',
      )
      ..writeln(
        '            .device_tree_model = ${_cppString(useModel ? fixture.board : '')},',
      )
      ..writeln(
        '            .device_tree_compatible = ${_cppString(fixture.compatible)},',
      )
      ..writeln('            .architecture = ${_cppString(fixture.arch)},')
      ..writeln('        },');
  }
  output
    ..writeln('    }};')
    ..writeln();

  final List<({String machine, String model, String compatible, String arch})>
  rejected = _rejectedFixtures(profiles);
  output
    ..writeln(
      'inline constexpr std::array<GeneratedDeviceIdentityFixture, ${rejected.length}>',
    )
    ..writeln('    kGeneratedRejectedDeviceIdentityFixtures = {{');
  for (final fixture in rejected) {
    output
      ..writeln('        {')
      ..writeln('            .profile_id = "",')
      ..writeln('            .machine = ${_cppString(fixture.machine)},')
      ..writeln(
        '            .device_tree_model = ${_cppString(fixture.model)},',
      )
      ..writeln(
        '            .device_tree_compatible = ${_cppString(fixture.compatible)},',
      )
      ..writeln('            .architecture = ${_cppString(fixture.arch)},')
      ..writeln('        },');
  }
  output
    ..writeln('    }};')
    ..writeln()
    ..writeln('} // namespace pluto')
    ..writeln()
    ..writeln('#endif // PLUTO_GENERATED_DEVICE_PROFILES_H_');
  return output.toString();
}

void _cppArray(StringBuffer output, String name, List<String> values) {
  output.writeln(
    'inline constexpr std::array<std::string_view, ${values.length}> k$name = {',
  );
  for (final String value in values) {
    output.writeln('    ${_cppString(value)},');
  }
  output
    ..writeln('};')
    ..writeln();
}

void _cppWaveformSourceArray(
  StringBuffer output,
  String name,
  List<_WaveformSource> values,
) {
  output.writeln(
    'inline constexpr std::array<GeneratedWaveformSourceProfile, ${values.length}> k$name = {{',
  );
  for (final _WaveformSource value in values) {
    output
      ..writeln('    {')
      ..writeln('        .path = ${_cppString(value.path)},')
      ..writeln('        .sha256 = ${_cppString(value.sha256)},')
      ..writeln(
        '        .panel_signature = ${_cppString(value.panelSignature)},',
      )
      ..writeln('    },');
  }
  output
    ..writeln('}};')
    ..writeln();
}

String _deviceModelsDart(List<_Profile> profiles) {
  final StringBuffer output = StringBuffer()
    ..writeln('// GENERATED FILE. Edit config/device_profiles.json, then run')
    ..writeln('// dart tools/codegen/generate_device_profiles.dart.')
    ..writeln()
    ..writeln('/// reMarkable models accepted by this exact Pluto release.')
    ..writeln('enum RemarkableModel {');
  for (int index = 0; index < profiles.length; index += 1) {
    final _Profile profile = profiles[index];
    final String terminator = index == profiles.length - 1 ? ';' : ',';
    output
      ..writeln('  /// ${profile.marketingName}.')
      ..writeln(
        '  ${profile.wireModel}(wireName: ${_dartString(profile.wireModel)}, codename: ${_dartString(profile.codename)})$terminator',
      )
      ..writeln();
  }
  output
    ..writeln('  const RemarkableModel({')
    ..writeln('    required this.wireName,')
    ..writeln('    required this.codename,')
    ..writeln('  });')
    ..writeln()
    ..writeln('  /// Exact protocol model name.')
    ..writeln('  final String wireName;')
    ..writeln()
    ..writeln('  /// Exact board codename.')
    ..writeln('  final String codename;')
    ..writeln()
    ..writeln('  /// Resolves only an exact generated model/codename pair.')
    ..writeln('  static RemarkableModel parse(String name, String codename) {')
    ..writeln('    return switch ((name, codename)) {');
  for (final _Profile profile in profiles) {
    output.writeln(
      '      (${_dartString(profile.wireModel)}, ${_dartString(profile.codename)}) => RemarkableModel.${profile.wireModel},',
    );
  }
  output
    ..writeln('      _ => throw FormatException(')
    ..writeln(
      "        'Unsupported exact device identity: \$name / \$codename',",
    )
    ..writeln('      ),')
    ..writeln('    };')
    ..writeln('  }')
    ..writeln('}');
  return output.toString();
}

String _dart(List<_Profile> profiles) {
  final StringBuffer output = StringBuffer()
    ..writeln('// GENERATED FILE. Edit config/device_profiles.json, then run')
    ..writeln('// dart tools/codegen/generate_device_profiles.dart.')
    ..writeln("part of '../device_profile.dart';")
    ..writeln()
    ..writeln('const List<DeviceProfile> _generatedDeviceProfiles =')
    ..writeln('    <DeviceProfile>[');
  for (final _Profile profile in profiles) {
    output
      ..writeln('      DeviceProfile(')
      ..writeln("        id: ${_dartString(profile.id)},")
      ..writeln("        wireModel: ${_dartString(profile.wireModel)},")
      ..writeln("        codename: ${_dartString(profile.codename)},")
      ..writeln("        marketingName: ${_dartString(profile.marketingName)},")
      ..writeln("        testedOs: ${_dartString(profile.testedOs)},")
      ..writeln(
        '        targetSlice: DeviceTargetSlice.${_dartTarget(profile.targetSlice)},',
      )
      ..writeln(
        '        displayDriver: NativeDisplayDriverKind.${_dartDriver(profile.displayDriver)},',
      )
      ..writeln('        panel: PanelProfile(')
      ..writeln('          width: ${profile.panel.width},')
      ..writeln('          height: ${profile.panel.height},')
      ..writeln('          dpi: ${profile.panel.dpi},')
      ..writeln("          signature: ${_dartString(profile.panel.signature)},")
      ..writeln(
        "          sourcePixelFormat: ${_dartString(profile.panel.sourcePixelFormat)},",
      )
      ..writeln('          color: ${profile.panel.color},')
      ..writeln('        ),')
      ..writeln('        runtime: DeviceRuntimeProfile(')
      ..writeln(
        '          nativeSessionEnabled: ${profile.runtime.nativeSessionEnabled},',
      )
      ..writeln(
        '          firmwareBuild: ${_dartString(profile.runtime.firmwareBuild)},',
      )
      ..writeln(
        '          kernelRelease: ${_dartString(profile.runtime.kernelRelease)},',
      )
      ..writeln(
        '          maxResidentApps: ${profile.runtime.maxResidentApps},',
      )
      ..writeln(
        '          takeoverQuiesceMilliseconds: ${profile.runtime.takeoverQuiesceMilliseconds},',
      )
      ..writeln(
        '          supervisorControlPollMilliseconds: ${profile.runtime.supervisorControlPollMilliseconds},',
      )
      ..writeln(
        '          displayDevice: ${_dartString(profile.runtime.displayDevice)},',
      )
      ..writeln('          display: DisplayContract(')
      ..writeln(
        '            scanoutWidth: ${profile.runtime.display.scanoutWidth},',
      )
      ..writeln(
        '            scanoutHeight: ${profile.runtime.display.scanoutHeight},',
      )
      ..writeln(
        '            virtualWidth: ${_dartNullableInt(profile.runtime.display.virtualWidth)},',
      )
      ..writeln(
        '            virtualHeight: ${_dartNullableInt(profile.runtime.display.virtualHeight)},',
      )
      ..writeln(
        '            strideBytes: ${_dartNullableInt(profile.runtime.display.strideBytes)},',
      )
      ..writeln(
        '            mappingBytes: ${_dartNullableInt(profile.runtime.display.mappingBytes)},',
      )
      ..writeln(
        '            bitsPerPixel: ${profile.runtime.display.bitsPerPixel},',
      )
      ..writeln(
        '            rotation: ${_dartNullableInt(profile.runtime.display.rotation)},',
      )
      ..writeln(
        '            bufferSlots: ${_dartNullableInt(profile.runtime.display.bufferSlots)},',
      )
      ..writeln(
        '            slotBytes: ${_dartNullableInt(profile.runtime.display.slotBytes)},',
      )
      ..writeln(
        '            damageAlignmentPixels: ${profile.runtime.display.damageAlignmentPixels},',
      )
      ..writeln(
        '            phaseIntervalNanoseconds: ${_dartNullableInt(profile.runtime.display.phaseIntervalNanoseconds)},',
      )
      ..writeln('          ),')
      ..writeln('          waveform: WaveformProfile(')
      ..writeln('            discoveryPaths: <String>[');
    for (final String path in profile.runtime.waveform.discoveryPaths) {
      output.writeln('              ${_dartString(path)},');
    }
    output
      ..writeln('            ],')
      ..writeln('            acceptedSources: <WaveformSourceProfile>[');
    for (final _WaveformSource source
        in profile.runtime.waveform.acceptedSources) {
      output
        ..writeln('              WaveformSourceProfile(')
        ..writeln('                path: ${_dartString(source.path)},')
        ..writeln('                sha256: ${_dartString(source.sha256)},')
        ..writeln(
          '                panelSignature: ${_dartString(source.panelSignature)},',
        )
        ..writeln('              ),');
    }
    output
      ..writeln('            ],')
      ..writeln('          ),')
      ..writeln(
        '          waveformOptionKey: ${_dartNullableString(profile.runtime.waveformOptionKey)},',
      )
      ..writeln(
        '          presenterOptions: ${_dartNullableString(profile.runtime.presenterOptions)},',
      )
      ..writeln('          pen: InputDeviceProfile(')
      ..writeln(
        '            byPath: ${_dartString(profile.runtime.pen.byPath)},',
      )
      ..writeln('            name: ${_dartString(profile.runtime.pen.name)},')
      ..writeln('          ),')
      ..writeln('          touch: InputDeviceProfile(')
      ..writeln(
        '            byPath: ${_dartString(profile.runtime.touch.byPath)},',
      )
      ..writeln('            name: ${_dartString(profile.runtime.touch.name)},')
      ..writeln('          ),')
      ..writeln('          powerKey: InputDeviceProfile(')
      ..writeln(
        '            byPath: ${_dartString(profile.runtime.powerKey.byPath)},',
      )
      ..writeln(
        '            name: ${_dartString(profile.runtime.powerKey.name)},',
      )
      ..writeln('          ),')
      ..writeln(
        '          frontlightBrightnessPath: ${_dartNullableString(profile.runtime.frontlightBrightnessPath)},',
      )
      ..writeln(
        '          vpddTimeoutPath: ${_dartNullableString(profile.runtime.vpddTimeoutPath)},',
      )
      ..writeln(
        '          bezelRedrawIioPath: ${_dartNullableString(profile.runtime.bezelRedrawIioPath)},',
      )
      ..writeln(
        '          bezelRedrawEnablePath: ${_dartNullableString(profile.runtime.bezelRedrawEnablePath)},',
      )
      ..writeln('          recovery: BootRecoveryContract(')
      ..writeln(
        '            confirmationStrategy: BootConfirmationStrategy.${_dartConfirmationStrategy(profile.runtime.recovery.confirmationStrategy)},',
      )
      ..writeln(
        '            failureStrategy: BootFailureStrategy.${_dartFailureStrategy(profile.runtime.recovery.failureStrategy)},',
      )
      ..writeln(
        '            bootDefaultEnabled: ${profile.runtime.recovery.bootDefaultEnabled},',
      )
      ..writeln(
        '            mmcDevice: ${_dartNullableString(profile.runtime.recovery.mmcDevice)},',
      )
      ..writeln(
        '            rootPartitions: ${_dartNullableIntList(profile.runtime.recovery.rootPartitions)},',
      )
      ..writeln(
        '            expectedBootLimit: ${_dartNullableInt(profile.runtime.recovery.expectedBootLimit)},',
      )
      ..writeln(
        '            helperPath: ${_dartNullableString(profile.runtime.recovery.helperPath)},',
      )
      ..writeln(
        '            counterDirectory: ${_dartNullableString(profile.runtime.recovery.counterDirectory)},',
      )
      ..writeln('          ),')
      ..writeln(
        '          suspendCommand: ${_dartString(profile.runtime.suspendCommand)},',
      )
      ..writeln('        ),')
      ..writeln(
        '        architectures: ${_dartStringList(profile.identity.architectures)},',
      )
      ..writeln(
        '        boardTokens: ${_dartStringList(profile.identity.boardTokens)},',
      )
      ..writeln(
        '        compatibleTokens: ${_dartStringList(profile.identity.compatibleTokens)},',
      )
      ..writeln('        buildModes: ${_dartStringList(profile.buildModes)},')
      ..writeln(
        '        capabilities: ${_dartStringList(profile.capabilities)},',
      )
      ..writeln('      ),');
  }
  output
    ..writeln('    ];')
    ..writeln()
    ..writeln('/// Accepted fixtures generated from every profile token.')
    ..writeln(
      'const List<DeviceIdentityFixture> generatedAcceptedIdentityFixtures =',
    )
    ..writeln('    <DeviceIdentityFixture>[');
  final accepted = _acceptedFixtures(profiles);
  for (int index = 0; index < accepted.length; index += 1) {
    final fixture = accepted[index];
    final bool useModel = index.isOdd;
    output
      ..writeln('      DeviceIdentityFixture(')
      ..writeln("        profileId: ${_dartString(fixture.profileId)},")
      ..writeln(
        "        machine: ${_dartString(useModel ? '' : fixture.board)},",
      )
      ..writeln(
        "        deviceTreeModel: ${_dartString(useModel ? fixture.board : '')},",
      )
      ..writeln(
        "        deviceTreeCompatible: ${_dartString(fixture.compatible)},",
      )
      ..writeln("        architecture: ${_dartString(fixture.arch)},")
      ..writeln('      ),');
  }
  output
    ..writeln('    ];')
    ..writeln()
    ..writeln('/// Rejected incomplete, mismatched, and conflicting fixtures.')
    ..writeln(
      'const List<DeviceIdentityFixture> generatedRejectedIdentityFixtures =',
    )
    ..writeln('    <DeviceIdentityFixture>[');
  for (final fixture in _rejectedFixtures(profiles)) {
    output
      ..writeln('      DeviceIdentityFixture(')
      ..writeln("        profileId: '',")
      ..writeln("        machine: ${_dartString(fixture.machine)},")
      ..writeln("        deviceTreeModel: ${_dartString(fixture.model)},")
      ..writeln(
        "        deviceTreeCompatible: ${_dartString(fixture.compatible)},",
      )
      ..writeln("        architecture: ${_dartString(fixture.arch)},")
      ..writeln('      ),');
  }
  output.writeln('    ];');
  return output.toString();
}

String _shell(List<_Profile> profiles) {
  final StringBuffer output = StringBuffer()
    ..writeln('# GENERATED FILE. Edit config/device_profiles.json, then run')
    ..writeln('# dart tools/codegen/generate_device_profiles.dart.')
    ..writeln()
    ..writeln('pluto_profile_load() {')
    ..writeln('  case "\$1" in');
  for (final _Profile profile in profiles) {
    output
      ..writeln('    ${profile.id})')
      ..writeln("      PLUTO_PROFILE_ID=${_shellString(profile.id)}")
      ..writeln(
        "      PLUTO_PROFILE_WIRE_MODEL=${_shellString(profile.wireModel)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_CODENAME=${_shellString(profile.codename)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_TARGET=${_shellString(profile.targetSlice)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_DISPLAY_DRIVER=${_shellString(profile.displayDriver)}",
      )
      ..writeln('      PLUTO_PROFILE_PANEL_WIDTH=${profile.panel.width}')
      ..writeln('      PLUTO_PROFILE_PANEL_HEIGHT=${profile.panel.height}')
      ..writeln('      PLUTO_PROFILE_PANEL_DPI=${profile.panel.dpi}')
      ..writeln(
        "      PLUTO_PROFILE_PANEL_SIGNATURE=${_shellString(profile.panel.signature)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT=${_shellString(profile.panel.sourcePixelFormat)}",
      )
      ..writeln(
        '      PLUTO_PROFILE_NATIVE_SESSION_ENABLED=${profile.runtime.nativeSessionEnabled ? 1 : 0}',
      )
      ..writeln(
        "      PLUTO_PROFILE_FIRMWARE_BUILD=${_shellString(profile.runtime.firmwareBuild)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_KERNEL_RELEASE=${_shellString(profile.runtime.kernelRelease)}",
      )
      ..writeln(
        '      PLUTO_PROFILE_MAX_RESIDENT_APPS=${profile.runtime.maxResidentApps}',
      )
      ..writeln(
        '      PLUTO_PROFILE_TAKEOVER_QUIESCE_MS=${profile.runtime.takeoverQuiesceMilliseconds}',
      )
      ..writeln(
        '      PLUTO_PROFILE_SUPERVISOR_CONTROL_POLL_MS=${profile.runtime.supervisorControlPollMilliseconds}',
      )
      ..writeln(
        "      PLUTO_PROFILE_DISPLAY_DEVICE=${_shellString(profile.runtime.displayDevice)}",
      )
      ..writeln(
        '      PLUTO_PROFILE_SCANOUT_WIDTH=${profile.runtime.display.scanoutWidth}',
      )
      ..writeln(
        '      PLUTO_PROFILE_SCANOUT_HEIGHT=${profile.runtime.display.scanoutHeight}',
      )
      ..writeln(
        "      PLUTO_PROFILE_VIRTUAL_WIDTH=${_shellOptionalInt(profile.runtime.display.virtualWidth)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_VIRTUAL_HEIGHT=${_shellOptionalInt(profile.runtime.display.virtualHeight)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_STRIDE_BYTES=${_shellOptionalInt(profile.runtime.display.strideBytes)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_MAPPING_BYTES=${_shellOptionalInt(profile.runtime.display.mappingBytes)}",
      )
      ..writeln(
        '      PLUTO_PROFILE_BITS_PER_PIXEL=${profile.runtime.display.bitsPerPixel}',
      )
      ..writeln(
        "      PLUTO_PROFILE_FRAMEBUFFER_ROTATION=${_shellOptionalInt(profile.runtime.display.rotation)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_BUFFER_SLOTS=${_shellOptionalInt(profile.runtime.display.bufferSlots)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_SLOT_BYTES=${_shellOptionalInt(profile.runtime.display.slotBytes)}",
      )
      ..writeln(
        '      PLUTO_PROFILE_DAMAGE_ALIGNMENT=${profile.runtime.display.damageAlignmentPixels}',
      )
      ..writeln(
        "      PLUTO_PROFILE_PHASE_INTERVAL_NS=${_shellOptionalInt(profile.runtime.display.phaseIntervalNanoseconds)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_WAVEFORM_OPTION_KEY=${_shellString(profile.runtime.waveformOptionKey ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_PRESENTER_OPTIONS=${_shellString(profile.runtime.presenterOptions ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_PEN_DEVICE=${_shellString(profile.runtime.pen.byPath)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_PEN_NAME=${_shellString(profile.runtime.pen.name)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_TOUCH_DEVICE=${_shellString(profile.runtime.touch.byPath)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_TOUCH_NAME=${_shellString(profile.runtime.touch.name)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_POWER_KEY_DEVICE=${_shellString(profile.runtime.powerKey.byPath)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_POWER_KEY_NAME=${_shellString(profile.runtime.powerKey.name)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS=${_shellString(profile.runtime.frontlightBrightnessPath ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_VPDD_TIMEOUT=${_shellString(profile.runtime.vpddTimeoutPath ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_BEZEL_REDRAW_IIO=${_shellString(profile.runtime.bezelRedrawIioPath ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_BEZEL_REDRAW_ENABLE=${_shellString(profile.runtime.bezelRedrawEnablePath ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY=${_shellString(profile.runtime.recovery.confirmationStrategy)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY=${_shellString(profile.runtime.recovery.failureStrategy)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED=${_shellString(profile.runtime.recovery.bootDefaultEnabled ? '1' : '0')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_MMC_DEVICE=${_shellString(profile.runtime.recovery.mmcDevice ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS=${_shellString(profile.runtime.recovery.rootPartitions?.join(',') ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_BOOT_LIMIT=${_shellOptionalInt(profile.runtime.recovery.expectedBootLimit)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_HELPER=${_shellString(profile.runtime.recovery.helperPath ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_RECOVERY_COUNTER_DIR=${_shellString(profile.runtime.recovery.counterDirectory ?? '')}",
      )
      ..writeln(
        "      PLUTO_PROFILE_SUSPEND_COMMAND=${_shellString(profile.runtime.suspendCommand)}",
      )
      ..writeln(
        "      PLUTO_PROFILE_BUILD_MODES=${_shellString(profile.buildModes.join(','))}",
      )
      ..writeln(
        "      PLUTO_PROFILE_CAPABILITIES=${_shellString(profile.capabilities.join(','))}",
      )
      ..writeln('      ;;');
  }
  output
    ..writeln('    *)')
    ..writeln('      return 1')
    ..writeln('      ;;')
    ..writeln('  esac')
    ..writeln('  export PLUTO_PROFILE_ID PLUTO_PROFILE_WIRE_MODEL')
    ..writeln('  export PLUTO_PROFILE_CODENAME PLUTO_PROFILE_TARGET')
    ..writeln('  export PLUTO_PROFILE_DISPLAY_DRIVER PLUTO_PROFILE_PANEL_WIDTH')
    ..writeln('  export PLUTO_PROFILE_PANEL_HEIGHT PLUTO_PROFILE_PANEL_DPI')
    ..writeln('  export PLUTO_PROFILE_PANEL_SIGNATURE')
    ..writeln('  export PLUTO_PROFILE_SOURCE_PIXEL_FORMAT')
    ..writeln('  export PLUTO_PROFILE_NATIVE_SESSION_ENABLED')
    ..writeln('  export PLUTO_PROFILE_FIRMWARE_BUILD')
    ..writeln('  export PLUTO_PROFILE_KERNEL_RELEASE')
    ..writeln('  export PLUTO_PROFILE_MAX_RESIDENT_APPS')
    ..writeln('  export PLUTO_PROFILE_SUPERVISOR_CONTROL_POLL_MS')
    ..writeln('  export PLUTO_PROFILE_DISPLAY_DEVICE')
    ..writeln(
      '  export PLUTO_PROFILE_SCANOUT_WIDTH PLUTO_PROFILE_SCANOUT_HEIGHT',
    )
    ..writeln(
      '  export PLUTO_PROFILE_VIRTUAL_WIDTH PLUTO_PROFILE_VIRTUAL_HEIGHT',
    )
    ..writeln(
      '  export PLUTO_PROFILE_STRIDE_BYTES PLUTO_PROFILE_BITS_PER_PIXEL',
    )
    ..writeln('  export PLUTO_PROFILE_MAPPING_BYTES')
    ..writeln('  export PLUTO_PROFILE_FRAMEBUFFER_ROTATION')
    ..writeln('  export PLUTO_PROFILE_BUFFER_SLOTS PLUTO_PROFILE_SLOT_BYTES')
    ..writeln('  export PLUTO_PROFILE_DAMAGE_ALIGNMENT')
    ..writeln('  export PLUTO_PROFILE_PHASE_INTERVAL_NS')
    ..writeln('  export PLUTO_PROFILE_WAVEFORM_OPTION_KEY')
    ..writeln('  export PLUTO_PROFILE_PRESENTER_OPTIONS')
    ..writeln('  export PLUTO_PROFILE_PEN_DEVICE PLUTO_PROFILE_PEN_NAME')
    ..writeln('  export PLUTO_PROFILE_TOUCH_DEVICE PLUTO_PROFILE_TOUCH_NAME')
    ..writeln(
      '  export PLUTO_PROFILE_POWER_KEY_DEVICE PLUTO_PROFILE_POWER_KEY_NAME',
    )
    ..writeln('  export PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS')
    ..writeln('  export PLUTO_PROFILE_VPDD_TIMEOUT')
    ..writeln('  export PLUTO_PROFILE_BEZEL_REDRAW_IIO')
    ..writeln('  export PLUTO_PROFILE_BEZEL_REDRAW_ENABLE')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_MMC_DEVICE')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_BOOT_LIMIT')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_HELPER')
    ..writeln('  export PLUTO_PROFILE_RECOVERY_COUNTER_DIR')
    ..writeln('  export PLUTO_PROFILE_SUSPEND_COMMAND')
    ..writeln('  export PLUTO_PROFILE_BUILD_MODES PLUTO_PROFILE_CAPABILITIES')
    ..writeln('}')
    ..writeln()
    ..writeln('pluto_profile_presenter_options() {')
    ..writeln('  _pluto_profile_base_options=\$1')
    ..writeln('  _pluto_profile_waveform_path=\$2')
    ..writeln('  if [ -z "\$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" ]; then')
    ..writeln('    printf \'%s\\n\' "\$_pluto_profile_base_options"')
    ..writeln('    return 0')
    ..writeln('  fi')
    ..writeln('  [ -n "\$_pluto_profile_waveform_path" ] || return 1')
    ..writeln('  if [ -n "\$_pluto_profile_base_options" ]; then')
    ..writeln(
      '    printf \'%s,%s=%s\\n\' "\$_pluto_profile_base_options" "\$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" "\$_pluto_profile_waveform_path"',
    )
    ..writeln('  else')
    ..writeln(
      '    printf \'%s=%s\\n\' "\$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" "\$_pluto_profile_waveform_path"',
    )
    ..writeln('  fi')
    ..writeln('}')
    ..writeln()
    ..writeln('pluto_profile_waveform_discovery_paths() {')
    ..writeln(r'  case "${PLUTO_PROFILE_ID:-}" in');
  for (final _Profile profile in profiles) {
    output.writeln('    ${profile.id})');
    for (final String path in profile.runtime.waveform.discoveryPaths) {
      output.writeln("      printf '%s\\n' ${_shellString(path)}");
    }
    output.writeln('      ;;');
  }
  output
    ..writeln('    *) return 1 ;;')
    ..writeln('  esac')
    ..writeln('}')
    ..writeln()
    ..writeln('pluto_profile_waveform_sources() {')
    ..writeln(r'  case "${PLUTO_PROFILE_ID:-}" in');
  for (final _Profile profile in profiles) {
    output.writeln('    ${profile.id})');
    for (final _WaveformSource source
        in profile.runtime.waveform.acceptedSources) {
      output.writeln(
        "      printf '%s|%s|%s\\n' ${_shellString(source.path)} ${_shellString(source.sha256)} ${_shellString(source.panelSignature)}",
      );
    }
    output.writeln('      ;;');
  }
  output
    ..writeln('    *) return 1 ;;')
    ..writeln('  esac')
    ..writeln('}')
    ..writeln()
    ..writeln('pluto_profile_detect() {')
    ..writeln(
      "  _pluto_board=\$(printf '%s %s' \"\$1\" \"\$2\" | tr '[:upper:]' '[:lower:]')",
    )
    ..writeln(
      "  _pluto_compatible=\$(printf '%s' \"\$3\" | tr '[:upper:]' '[:lower:]')",
    )
    ..writeln(
      "  _pluto_arch=\$(printf '%s' \"\$4\" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')",
    )
    ..writeln("  _pluto_board_matches=''")
    ..writeln("  _pluto_compatible_matches=''");
  for (final _Profile profile in profiles) {
    output
      ..writeln('  case "\$_pluto_board" in')
      ..writeln(
        '    ${profile.identity.boardTokens.map(_shellContainsPattern).join('|')}) _pluto_board_matches="\$_pluto_board_matches ${profile.id}" ;;',
      )
      ..writeln('  esac')
      ..writeln('  case "\$_pluto_compatible" in')
      ..writeln(
        '    ${profile.identity.compatibleTokens.map(_shellContainsPattern).join('|')}) _pluto_compatible_matches="\$_pluto_compatible_matches ${profile.id}" ;;',
      )
      ..writeln('  esac');
  }
  output.writeln(
    '  case "\$_pluto_board_matches:\$_pluto_compatible_matches" in',
  );
  for (final _Profile profile in profiles) {
    output
      ..writeln('    " ${profile.id}: ${profile.id}")')
      ..writeln('      case "\$_pluto_arch" in')
      ..writeln(
        '        ${profile.identity.architectures.map(_shellExactPattern).join('|')}) pluto_profile_load ${profile.id} ;;',
      )
      ..writeln('        *) return 1 ;;')
      ..writeln('      esac')
      ..writeln('      ;;');
  }
  output
    ..writeln('    *) return 1 ;;')
    ..writeln('  esac')
    ..writeln('}')
    ..writeln()
    ..writeln('pluto_profile_probe() {')
    ..writeln(
      "  _pluto_machine=\$(cat /sys/devices/soc0/machine 2>/dev/null || true)",
    )
    ..writeln(
      r"  _pluto_model=$(tr '\000' ' ' </proc/device-tree/model 2>/dev/null || true)",
    )
    ..writeln(
      r"  _pluto_compatible=$(tr '\000' ' ' </proc/device-tree/compatible 2>/dev/null || true)",
    )
    ..writeln('  _pluto_arch=\$(uname -m 2>/dev/null || true)')
    ..writeln(
      '  pluto_profile_detect "\$_pluto_machine" "\$_pluto_model" "\$_pluto_compatible" "\$_pluto_arch"',
    )
    ..writeln('}');
  return output.toString();
}

String _markdown(List<_Profile> profiles) {
  final StringBuffer output = StringBuffer()
    ..writeln('<!-- GENERATED FILE: edit config/device_profiles.json. -->')
    ..writeln(
      '| Device | Profile | Codename | Tested OS | Target | Native driver | Panel | Resident apps | Scanout contract | Recovery | Boot default | Build modes |',
    )
    ..writeln(
      '| --- | --- | --- | --- | --- | --- | ---: | ---: | --- | --- | --- | --- |',
    );
  for (final _Profile profile in profiles) {
    output.writeln(
      '| ${profile.marketingName} | `${profile.id}` | `${profile.codename}` | ${profile.testedOs} | `${profile.targetSlice}` | `${profile.displayDriver}` | ${profile.panel.width} × ${profile.panel.height} @ ${profile.panel.dpi} dpi | ${profile.runtime.maxResidentApps} | ${_displaySummary(profile.runtime.display)} | `${profile.runtime.recovery.confirmationStrategy}` / `${profile.runtime.recovery.failureStrategy}` | ${profile.runtime.recovery.bootDefaultEnabled ? 'enabled' : 'staging only'} | ${profile.buildModes.map((String mode) => '`$mode`').join(', ')} |',
    );
  }
  return output.toString();
}

String _displaySummary(_DisplayContract display) {
  final List<String> facts = <String>[
    '${display.scanoutWidth} × ${display.scanoutHeight}',
    '${display.bitsPerPixel} bpp',
    if (display.virtualWidth != null)
      'virtual ${display.virtualWidth} × ${display.virtualHeight}',
    if (display.strideBytes != null) 'stride ${display.strideBytes} B',
    if (display.mappingBytes != null) 'mapping ${display.mappingBytes} B',
    if (display.bufferSlots != null) '${display.bufferSlots} slots',
    'align ${display.damageAlignmentPixels} px',
  ];
  return facts.join('; ');
}

List<({String profileId, String board, String compatible, String arch})>
_acceptedFixtures(List<_Profile> profiles) =>
    <({String profileId, String board, String compatible, String arch})>[
      for (final _Profile profile in profiles)
        for (final String board in profile.identity.boardTokens)
          for (final String compatible in profile.identity.compatibleTokens)
            (
              profileId: profile.id,
              board: board,
              compatible: compatible,
              arch: profile.identity.architectures.first,
            ),
    ];

List<({String machine, String model, String compatible, String arch})>
_rejectedFixtures(List<_Profile> profiles) {
  final List<({String machine, String model, String compatible, String arch})>
  fixtures = <({String machine, String model, String compatible, String arch})>[
    (machine: '', model: '', compatible: '', arch: ''),
    (
      machine: 'unrecognized tablet',
      model: '',
      compatible: 'vendor,unknown',
      arch: 'armv7l',
    ),
  ];
  for (final _Profile profile in profiles) {
    fixtures.addAll(
      <({String machine, String model, String compatible, String arch})>[
        (
          machine: profile.identity.boardTokens.first,
          model: '',
          compatible: '',
          arch: profile.identity.architectures.first,
        ),
        (
          machine: '',
          model: '',
          compatible: profile.identity.compatibleTokens.first,
          arch: profile.identity.architectures.first,
        ),
        (
          machine: profile.identity.boardTokens.first,
          model: '',
          compatible: profile.identity.compatibleTokens.first,
          arch: 'wrong-architecture',
        ),
      ],
    );
  }
  final List<_Profile> sameArchitecture = profiles
      .where(
        (_Profile profile) =>
            profile.identity.architectures.first ==
            profiles.first.identity.architectures.first,
      )
      .take(2)
      .toList(growable: false);
  if (sameArchitecture.length == 2) {
    final String conflictingBoards = sameArchitecture
        .map((_Profile profile) => profile.identity.boardTokens.first)
        .join(' ');
    final String conflictingCompatible = sameArchitecture
        .map((_Profile profile) => profile.identity.compatibleTokens.first)
        .join(' ');
    fixtures.addAll(
      <({String machine, String model, String compatible, String arch})>[
        (
          machine: conflictingBoards,
          model: '',
          compatible: sameArchitecture.first.identity.compatibleTokens.first,
          arch: sameArchitecture.first.identity.architectures.first,
        ),
        (
          machine: sameArchitecture.first.identity.boardTokens.first,
          model: '',
          compatible: conflictingCompatible,
          arch: sameArchitecture.first.identity.architectures.first,
        ),
        (
          machine: conflictingBoards,
          model: '',
          compatible: conflictingCompatible,
          arch: sameArchitecture.first.identity.architectures.first,
        ),
      ],
    );
  }
  return fixtures;
}

String _cppName(String value) => value
    .split('_')
    .map((String part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join();

String _cppString(String value) => jsonEncode(value);

String _cppOptionalInt(int? value) => value == null ? 'std::nullopt' : '$value';

String _cppOptionalString(String? value) =>
    value == null ? 'std::nullopt' : _cppString(value);

String _cppOptionalIntArray2(List<int>? values) => values == null
    ? 'std::nullopt'
    : 'std::array<std::uint32_t, 2>{${values.join(', ')}}';

String _cppConfirmationStrategy(String value) => switch (value) {
  'uboot_env' => 'kUbootEnv',
  'lpgpr_counter' => 'kLpgprCounter',
  _ => throw StateError('unvalidated confirmation strategy $value'),
};

String _cppFailureStrategy(String value) => switch (value) {
  'uboot_env_force_reboot' => 'kUbootEnvForceReboot',
  'unverified' => 'kUnverified',
  _ => throw StateError('unvalidated failure strategy $value'),
};

String _dartString(String value) => jsonEncode(value).replaceAll('"', "'");

String _dartNullableString(String? value) =>
    value == null ? 'null' : _dartString(value);

String _dartNullableInt(int? value) => value == null ? 'null' : '$value';

String _dartNullableIntList(List<int>? values) =>
    values == null ? 'null' : '<int>[${values.join(', ')}]';

String _dartConfirmationStrategy(String value) => switch (value) {
  'uboot_env' => 'ubootEnv',
  'lpgpr_counter' => 'lpgprCounter',
  _ => throw StateError('unvalidated confirmation strategy $value'),
};

String _dartFailureStrategy(String value) => switch (value) {
  'uboot_env_force_reboot' => 'ubootEnvForceReboot',
  'unverified' => 'unverified',
  _ => throw StateError('unvalidated failure strategy $value'),
};

String _dartStringList(List<String> values) =>
    '<String>[${values.map(_dartString).join(', ')}]';

String _shellString(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _shellOptionalInt(int? value) => _shellString(value?.toString() ?? '');

String _shellExactPattern(String value) => '"${_shellDoubleQuoted(value)}"';

String _shellContainsPattern(String value) =>
    '*"${_shellDoubleQuoted(value)}"*';

String _shellDoubleQuoted(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll(r'$', r'\$')
    .replaceAll('`', r'\`');

String _cppTarget(String value) => switch (value) {
  'linux-arm' => 'kLinuxArm',
  'linux-arm64' => 'kLinuxArm64',
  _ => throw StateError('unvalidated target $value'),
};

String _cppDriver(String value) => switch (value) {
  'mxcfb_epdc' => 'kMxcfbEpdc',
  'lcdif_tcon' => 'kLcdifTcon',
  'gallery3_drm' => 'kGallery3Drm',
  _ => throw StateError('unvalidated driver $value'),
};

String _dartTarget(String value) => switch (value) {
  'linux-arm' => 'linuxArm',
  'linux-arm64' => 'linuxArm64',
  _ => throw StateError('unvalidated target $value'),
};

String _dartDriver(String value) => switch (value) {
  'mxcfb_epdc' => 'mxcfbEpdc',
  'lcdif_tcon' => 'lcdifTcon',
  'gallery3_drm' => 'gallery3Drm',
  _ => throw StateError('unvalidated driver $value'),
};
