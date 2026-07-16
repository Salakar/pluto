import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

/// Pluto product version compiled into this launcher.
const String kPlutoVersion = '0.1.0';

/// Flutter SDK version compiled into this launcher.
const String kFlutterVersionPin = '3.44.4';

/// Dart SDK version compiled into this launcher.
const String kDartVersionPin = '3.12.2';

/// Flutter engine commit compiled into this launcher.
const String kEngineCommitPin = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

/// Install kind shown in app metadata.
enum LauncherInstallKind {
  /// Release AOT install.
  release,

  /// Development install.
  dev,
}

/// Health status for an installed app.
sealed class LauncherAppHealth {
  const LauncherAppHealth();
}

/// App manifest and runtime are valid.
final class LauncherAppHealthy extends LauncherAppHealth {
  /// Creates a healthy status.
  const LauncherAppHealthy();
}

/// App manifest or runtime failed validation.
final class LauncherAppBroken extends LauncherAppHealth {
  /// Creates a broken status.
  const LauncherAppBroken({required this.reason});

  /// Human-readable validation or runtime reason.
  final String reason;
}

/// Installed app record used by launcher screens.
final class LauncherApp {
  /// Creates an installed app value.
  const LauncherApp({
    required this.manifest,
    required this.installKind,
    required this.health,
    this.installRecord,
    this.isPinned = false,
    this.sizeBytes = 0,
    this.dataSizeBytes = 0,
    this.updatedAt,
    this.sourceHost,
    this.iconBytes,
  });

  /// Validated manifest.
  final AppManifest manifest;

  /// Optional install receipt.
  final InstallRecord? installRecord;

  /// Build kind.
  final LauncherInstallKind installKind;

  /// Health state.
  final LauncherAppHealth health;

  /// Whether the app is pinned to the front of Home.
  final bool isPinned;

  /// Installed app payload size.
  final int sizeBytes;

  /// App data size.
  final int dataSizeBytes;

  /// Last update time.
  final DateTime? updatedAt;

  /// Host name recorded by the installer.
  final String? sourceHost;

  /// Bytes from the manifest-declared installed icon, if readable.
  final Uint8List? iconBytes;

  /// App id.
  AppId get id => manifest.id;

  /// Display name.
  String get displayName => manifest.name;

  /// Semver string.
  String get versionText => manifest.version.toString();

  /// Whether this app is broken.
  bool get isBroken => health is LauncherAppBroken;

  /// Whether this install is reserved for an explicit CLI debug session.
  ///
  /// Either the install receipt or the runtime manifest is enough to fail
  /// closed: an inconsistent kernel install must never become a Home launch.
  bool get requiresExplicitDebugLaunch =>
      installKind == LauncherInstallKind.dev ||
      manifest.runtime.kind == AppRuntimeKind.flutterKernel;

  /// Creates a copy with selected fields replaced.
  LauncherApp copyWith({
    AppManifest? manifest,
    InstallRecord? installRecord,
    LauncherInstallKind? installKind,
    LauncherAppHealth? health,
    bool? isPinned,
    int? sizeBytes,
    int? dataSizeBytes,
    DateTime? updatedAt,
    String? sourceHost,
    Uint8List? iconBytes,
  }) {
    return LauncherApp(
      manifest: manifest ?? this.manifest,
      installRecord: installRecord ?? this.installRecord,
      installKind: installKind ?? this.installKind,
      health: health ?? this.health,
      isPinned: isPinned ?? this.isPinned,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      dataSizeBytes: dataSizeBytes ?? this.dataSizeBytes,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceHost: sourceHost ?? this.sourceHost,
      iconBytes: iconBytes ?? this.iconBytes,
    );
  }
}

/// Network addresses shown on developer-facing surfaces.
final class LauncherNetworkInfo {
  /// Creates network info.
  const LauncherNetworkInfo({this.usbIp, this.wifiIp});

  /// USB tethering address, when the interface is up.
  final String? usbIp;

  /// Wi-Fi address, when connected.
  final String? wifiIp;
}

/// Result of an app launch request.
sealed class LaunchResult {
  const LaunchResult();
}

/// Successful launch result.
final class LaunchSuccess extends LaunchResult {
  /// Creates a success result.
  const LaunchSuccess({required this.pid});

  /// Spawned process id.
  final int pid;
}

/// Failed launch result.
final class LaunchFailure extends LaunchResult {
  /// Creates a launch failure.
  const LaunchFailure({required this.reason, this.stderr});

  /// Short reason from the Pluto supervisor.
  final String reason;

  /// Optional stderr excerpt.
  final String? stderr;
}

/// One warm process shown in the running-app switcher.
final class AppSwitcherPreview {
  /// Creates a switcher preview.
  const AppSwitcherPreview({
    required this.appId,
    this.imageBytes,
    this.aspectRatio,
  });

  /// Stable installed app id.
  final AppId appId;

  /// Downsampled BMP bytes captured immediately before app hibernation.
  final Uint8List? imageBytes;

  /// Captured frame width divided by height, when the BMP header is valid.
  final double? aspectRatio;
}

/// Supervisor-authored app-switcher activation and recency snapshot.
final class AppSwitcherRequest {
  /// Creates an app-switcher request.
  const AppSwitcherRequest({required this.originAppId, required this.previews});

  /// App whose bottom-edge gesture opened the switcher.
  final AppId originAppId;

  /// Running apps ordered most-recent-first, excluding [originAppId].
  final List<AppSwitcherPreview> previews;
}

/// Supervisor-authored system status shade activation.
final class StatusOverlayRequest {
  /// Creates a status shade request over the captured origin frame.
  const StatusOverlayRequest({
    required this.originAppId,
    this.imageBytes,
    this.aspectRatio,
  });

  /// App that yielded the panel for the temporary status shade.
  final AppId originAppId;

  /// Last submitted frame captured immediately before hibernation.
  final Uint8List? imageBytes;

  /// Captured frame width divided by height, when available.
  final double? aspectRatio;
}

/// Supervisor-authored full-screen power menu activation.
final class PowerMenuRequest {
  /// Creates a power menu request for the app that yielded the display.
  const PowerMenuRequest({required this.originAppId});

  /// App to resume when the user dismisses the power menu.
  final AppId originAppId;
}
