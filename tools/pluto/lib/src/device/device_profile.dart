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

/// Hardware-specific stable-boot confirmation mechanism.
enum BootConfirmationStrategy {
  /// U-Boot environment selects A/B MMC root partitions.
  ubootEnv,

  /// Vendor helper clears the active LPGPR root error counter.
  lpgprCounter,
}

/// Hardware-specific action taken when the boot-default service fails.
enum BootFailureStrategy {
  /// Arm the U-Boot fallback counter and force an immediate reboot.
  ubootEnvForceReboot,

  /// Failure and reboot behavior has not passed the hardware acceptance gate.
  unverified,
}

/// Immutable physical panel facts.
final class PanelProfile {
  /// Creates panel facts emitted from the reviewed profile source.
  const PanelProfile({
    required this.width,
    required this.height,
    required this.dpi,
    required this.signature,
    required this.sourcePixelFormat,
    required this.color,
  });

  /// Logical panel width in pixels.
  final int width;

  /// Logical panel height in pixels.
  final int height;

  /// Nominal panel density.
  final int dpi;

  /// Stable panel identifier bound to accepted waveform sources.
  final String signature;

  /// Common compositor source format accepted by the native presenter.
  final String sourcePixelFormat;

  /// Whether the physical panel has chromatic pigments.
  final bool color;
}

/// Stable evdev identity selected by a hardware profile.
final class InputDeviceProfile {
  /// Creates an immutable evdev identity.
  const InputDeviceProfile({required this.byPath, required this.name});

  /// Stable `/dev/input/by-path` symlink, never a transient event number.
  final String byPath;

  /// Exact kernel evdev name expected behind [byPath].
  final String name;
}

/// Strict framebuffer or scanout geometry expected from a device backend.
final class DisplayContract {
  /// Creates an immutable display-interface contract.
  const DisplayContract({
    required this.scanoutWidth,
    required this.scanoutHeight,
    required this.virtualWidth,
    required this.virtualHeight,
    required this.strideBytes,
    required this.bitsPerPixel,
    required this.rotation,
    required this.bufferSlots,
    required this.slotBytes,
    required this.damageAlignmentPixels,
    required this.phaseIntervalNanoseconds,
  });

  /// Hardware scanout width, which may differ from logical panel width.
  final int scanoutWidth;

  /// Height of one hardware scanout frame or slot.
  final int scanoutHeight;

  /// Exact fbdev virtual width, absent for separate DRM buffers.
  final int? virtualWidth;

  /// Exact fbdev virtual height, absent for separate DRM buffers.
  final int? virtualHeight;

  /// Exact fbdev line stride, absent when DRM chooses a validated pitch.
  final int? strideBytes;

  /// Storage bits per scanout pixel or packed scanout word.
  final int bitsPerPixel;

  /// Kernel fbdev rotation enum, absent for DRM scanout.
  final int? rotation;

  /// Number of allocated scanout slots, when the interface exposes a ring.
  final int? bufferSlots;

  /// Exact payload bytes in one scanout slot.
  final int? slotBytes;

  /// Required outward damage alignment in logical panel pixels.
  final int damageAlignmentPixels;

  /// Expected phase cadence, absent when the kernel EPDC owns timing.
  final int? phaseIntervalNanoseconds;
}

/// Typed A/B root and stable-boot confirmation contract.
final class BootRecoveryContract {
  /// Creates an immutable recovery contract.
  const BootRecoveryContract({
    required this.confirmationStrategy,
    required this.failureStrategy,
    required this.bootDefaultEnabled,
    required this.mmcDevice,
    required this.rootPartitions,
    required this.expectedBootLimit,
    required this.helperPath,
    required this.counterDirectory,
  });

  /// Stable-boot confirmation selected for this hardware family.
  final BootConfirmationStrategy confirmationStrategy;

  /// Failure action selected for this hardware family.
  final BootFailureStrategy failureStrategy;

  /// Whether the complete failure/reboot path has passed its device gate.
  final bool bootDefaultEnabled;

  /// MMC device prefix used by U-Boot root partition values.
  final String? mmcDevice;

  /// Exact pair of legal root partition numbers.
  final List<int>? rootPartitions;

  /// U-Boot boot limit that must be observed before confirmation.
  final int? expectedBootLimit;

  /// Vendor stable-boot helper for LPGPR devices.
  final String? helperPath;

  /// LPGPR counter directory paired with [helperPath].
  final String? counterDirectory;
}

/// A panel-bound waveform file whose exact contents have been observed.
final class WaveformSourceProfile {
  /// Creates an accepted waveform identity.
  const WaveformSourceProfile({
    required this.path,
    required this.sha256,
    required this.panelSignature,
  });

  /// Device-owned path observed as the active source.
  final String path;

  /// Lowercase SHA-256 of [path].
  final String sha256;

  /// Physical panel signature for which this source was accepted.
  final String panelSignature;
}

/// Waveform discovery candidates and the strictly accepted subset.
final class WaveformProfile {
  /// Creates a waveform selection contract.
  const WaveformProfile({
    required this.discoveryPaths,
    required this.acceptedSources,
  });

  /// Paths an observer may inspect; existence alone never grants acceptance.
  final List<String> discoveryPaths;

  /// Exact path, digest, and panel bindings allowed at runtime.
  final List<WaveformSourceProfile> acceptedSources;
}

/// Device-side paths and policies consumed by the common native supervisor.
final class DeviceRuntimeProfile {
  /// Creates runtime facts emitted from the reviewed profile source.
  const DeviceRuntimeProfile({
    required this.nativeSessionEnabled,
    required this.displayDevice,
    required this.display,
    required this.waveform,
    required this.presenterOptions,
    required this.pen,
    required this.touch,
    required this.powerKey,
    required this.frontlightBrightnessPath,
    required this.vpddTimeoutPath,
    required this.bezelRedrawIioPath,
    required this.bezelRedrawEnablePath,
    required this.recovery,
    required this.suspendCommand,
  });

  /// Whether the native display backend has passed its device bring-up gate.
  final bool nativeSessionEnabled;

  /// Display ownership node validated by the native backend.
  final String displayDevice;

  /// Strict driver-facing framebuffer or scanout expectations.
  final DisplayContract display;

  /// Discovery candidates and panel-bound accepted waveform identities.
  final WaveformProfile waveform;

  /// Device-specific options passed through the common native presenter.
  final String? presenterOptions;

  /// Stable pen device identity.
  final InputDeviceProfile pen;

  /// Stable touch device identity.
  final InputDeviceProfile touch;

  /// Stable power-key device identity.
  final InputDeviceProfile powerKey;

  /// Brightness sysfs file, or `null` when the device has no frontlight.
  final String? frontlightBrightnessPath;

  /// Regulator idle countdown, or `null` when no supervisor fence is needed.
  final String? vpddTimeoutPath;

  /// IIO device used for the optional bezel-redraw gesture.
  final String? bezelRedrawIioPath;

  /// Sysfs enable file paired with [bezelRedrawIioPath].
  final String? bezelRedrawEnablePath;

  /// Hardware-specific A/B rescue and stable-confirmation contract.
  final BootRecoveryContract recovery;

  /// Blocking suspend command that returns only after wake or failure.
  final String suspendCommand;
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
    required this.runtime,
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

  /// Device-side supervisor and hardware ownership facts.
  final DeviceRuntimeProfile runtime;

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
