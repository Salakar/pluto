library;

part 'generated/device_profiles.g.dart';

/// Native executable slice selected by immutable hardware identity.
enum DeviceTargetSlice {
  /// ARMv7 hard-float release slice.
  linuxArm('linux-arm'),

  /// AArch64 release/profile/debug slice.
  linuxArm64('linux-arm64');

  const DeviceTargetSlice(this.wireName);

  /// Package and build metadata spelling.
  final String wireName;
}

/// Hardware display implementation selected inside the native presenter.
enum NativeDisplayDriverKind {
  /// Kernel EPDC/MXCFB updates on reMarkable 1.
  mxcfbEpdc,

  /// Userspace waveform generation and LCDIF scanout on reMarkable 2.
  lcdifTcon,

  /// Gallery 3 waveform generation and DRM scanout on Paper Pro Move.
  gallery3Drm,
}

/// Immutable physical panel facts.
final class PanelProfile {
  /// Creates panel facts emitted from the reviewed profile source.
  const PanelProfile({
    required this.width,
    required this.height,
    required this.dpi,
    required this.sourcePixelFormat,
    required this.color,
  });

  /// Logical panel width in pixels.
  final int width;

  /// Logical panel height in pixels.
  final int height;

  /// Nominal panel density.
  final int dpi;

  /// Common compositor source format accepted by the native presenter.
  final String sourcePixelFormat;

  /// Whether the physical panel has chromatic pigments.
  final bool color;
}

/// Generated, immutable hardware profile shared by all host-side commands.
final class DeviceProfile {
  /// Creates a profile emitted by the deterministic generator.
  const DeviceProfile({
    required this.id,
    required this.wireModel,
    required this.codename,
    required this.marketingName,
    required this.testedOs,
    required this.targetSlice,
    required this.displayDriver,
    required this.panel,
    required this.architectures,
    required this.boardTokens,
    required this.compatibleTokens,
    required this.buildModes,
    required this.capabilities,
  });

  /// Stable internal identity (`rm1`, `rm2`, or `move`).
  final String id;

  /// Stable model value exposed through `pluto/device`.
  final String wireModel;

  /// Hardware codename.
  final String codename;

  /// Human-readable product name.
  final String marketingName;

  /// Exact reMarkable OS release used for the current compatibility gate.
  final String testedOs;

  /// Native executable slice.
  final DeviceTargetSlice targetSlice;

  /// Native display implementation.
  final NativeDisplayDriverKind displayDriver;

  /// Physical panel facts.
  final PanelProfile panel;

  /// Exact normalized kernel architecture values accepted by this profile.
  final List<String> architectures;

  /// Tokens accepted from immutable SoC machine or device-tree model fields.
  final List<String> boardTokens;

  /// Tokens accepted from the device-tree compatible field.
  final List<String> compatibleTokens;

  /// Build modes supported by this target slice.
  final List<String> buildModes;

  /// Hardware/runtime capabilities consumed by common higher layers.
  final List<String> capabilities;

  /// Whether the profile exposes [capability].
  bool hasCapability(String capability) => capabilities.contains(capability);
}

/// Immutable identity evidence kept in separate fields for conjunctive match.
final class DeviceIdentityEvidence {
  /// Creates identity evidence from read-only kernel and device-tree probes.
  const DeviceIdentityEvidence({
    required this.machine,
    required this.deviceTreeModel,
    required this.deviceTreeCompatible,
    required this.architecture,
  });

  /// `/sys/devices/soc0/machine`.
  final String machine;

  /// `/proc/device-tree/model`.
  final String deviceTreeModel;

  /// `/proc/device-tree/compatible`.
  final String deviceTreeCompatible;

  /// `uname -m`.
  final String architecture;
}

/// Shared generated fixture used to prove all language matchers agree.
final class DeviceIdentityFixture {
  /// Creates an accepted or rejected generated identity fixture.
  const DeviceIdentityFixture({
    required this.profileId,
    required this.machine,
    required this.deviceTreeModel,
    required this.deviceTreeCompatible,
    required this.architecture,
  });

  /// Expected profile id, or empty when the evidence must be rejected.
  final String profileId;

  /// Fixture SoC machine value.
  final String machine;

  /// Fixture device-tree model value.
  final String deviceTreeModel;

  /// Fixture device-tree compatible value.
  final String deviceTreeCompatible;

  /// Fixture kernel architecture.
  final String architecture;

  /// Converts the fixture to matcher input.
  DeviceIdentityEvidence get evidence => DeviceIdentityEvidence(
    machine: machine,
    deviceTreeModel: deviceTreeModel,
    deviceTreeCompatible: deviceTreeCompatible,
    architecture: architecture,
  );
}

/// All supported profiles from `config/device_profiles.json`.
List<DeviceProfile> get deviceProfiles => _generatedDeviceProfiles;

/// Returns one generated profile by stable id.
DeviceProfile? deviceProfileById(String id) {
  for (final DeviceProfile profile in _generatedDeviceProfiles) {
    if (profile.id == id) {
      return profile;
    }
  }
  return null;
}

/// Matches all required immutable evidence groups and fails closed on conflict.
DeviceProfile? matchDeviceProfile(DeviceIdentityEvidence evidence) {
  final String board = _normalizeIdentity(
    '${evidence.machine} ${evidence.deviceTreeModel}',
  );
  final String compatible = _normalizeIdentity(evidence.deviceTreeCompatible);
  final String architecture = _normalizeIdentity(
    evidence.architecture,
  ).replaceAll(' ', '');
  final List<DeviceProfile> matches = <DeviceProfile>[
    for (final DeviceProfile profile in _generatedDeviceProfiles)
      if (profile.architectures.contains(architecture) &&
          profile.boardTokens.any(board.contains) &&
          profile.compatibleTokens.any(compatible.contains))
        profile,
  ];
  return matches.length == 1 ? matches.single : null;
}

String _normalizeIdentity(String value) => value
    .toLowerCase()
    .replaceAll('\u0000', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
