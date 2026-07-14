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
      sourcePixelFormat = _string(json, 'sourcePixelFormat'),
      color = _boolean(json, 'color');

  final int width;
  final int height;
  final int dpi;
  final String sourcePixelFormat;
  final bool color;
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

String _string(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    _fail('$key must be a non-empty string');
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
    ..writeln()
    ..writeln('struct GeneratedPanelProfile {')
    ..writeln('  int width;')
    ..writeln('  int height;')
    ..writeln('  int dpi;')
    ..writeln('  std::string_view source_pixel_format;')
    ..writeln('  bool color;')
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
        '                    .source_pixel_format = ${_cppString(profile.panel.sourcePixelFormat)},',
      )
      ..writeln('                    .color = ${profile.panel.color},')
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
      ..writeln(
        "          sourcePixelFormat: ${_dartString(profile.panel.sourcePixelFormat)},",
      )
      ..writeln('          color: ${profile.panel.color},')
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
        "      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT=${_shellString(profile.panel.sourcePixelFormat)}",
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
    ..writeln('  export PLUTO_PROFILE_SOURCE_PIXEL_FORMAT')
    ..writeln('  export PLUTO_PROFILE_BUILD_MODES PLUTO_PROFILE_CAPABILITIES')
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
    ..writeln("  _pluto_matches=''");
  for (final _Profile profile in profiles) {
    output
      ..writeln('  case "\$_pluto_arch" in')
      ..writeln(
        '    ${profile.identity.architectures.map(_shellExactPattern).join('|')})',
      )
      ..writeln('      case "\$_pluto_board" in')
      ..writeln(
        '        ${profile.identity.boardTokens.map(_shellContainsPattern).join('|')})',
      )
      ..writeln('          case "\$_pluto_compatible" in')
      ..writeln(
        '            ${profile.identity.compatibleTokens.map(_shellContainsPattern).join('|')}) _pluto_matches="\$_pluto_matches ${profile.id}" ;;',
      )
      ..writeln('          esac')
      ..writeln('          ;;')
      ..writeln('      esac')
      ..writeln('      ;;')
      ..writeln('  esac');
  }
  output.writeln('  case "\$_pluto_matches" in');
  for (final _Profile profile in profiles) {
    output.writeln('    " ${profile.id}") pluto_profile_load ${profile.id} ;;');
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
      '| Device | Profile | Codename | Tested OS | Target | Native driver | Panel | Build modes |',
    )
    ..writeln('| --- | --- | --- | --- | --- | --- | ---: | --- |');
  for (final _Profile profile in profiles) {
    output.writeln(
      '| ${profile.marketingName} | `${profile.id}` | `${profile.codename}` | ${profile.testedOs} | `${profile.targetSlice}` | `${profile.displayDriver}` | ${profile.panel.width} × ${profile.panel.height} @ ${profile.panel.dpi} dpi | ${profile.buildModes.map((String mode) => '`$mode`').join(', ')} |',
    );
  }
  return output.toString();
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
    fixtures.add((
      machine: sameArchitecture
          .map((_Profile profile) => profile.identity.boardTokens.first)
          .join(' '),
      model: '',
      compatible: sameArchitecture
          .map((_Profile profile) => profile.identity.compatibleTokens.first)
          .join(' '),
      arch: sameArchitecture.first.identity.architectures.first,
    ));
  }
  return fixtures;
}

String _cppName(String value) => value
    .split('_')
    .map((String part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join();

String _cppString(String value) => jsonEncode(value);

String _dartString(String value) => jsonEncode(value).replaceAll('"', "'");

String _dartStringList(List<String> values) =>
    '<String>[${values.map(_dartString).join(', ')}]';

String _shellString(String value) => "'${value.replaceAll("'", "'\\''")}'";

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
