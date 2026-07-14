// ignore_for_file: implementation_imports

import 'package:flutter_tools/src/application_package.dart' as app_package;
import 'package:flutter_tools/src/artifacts.dart' as artifacts;
import 'package:flutter_tools/src/build_info.dart' as build_info;
import 'package:flutter_tools/src/build_system/build_system.dart'
    as build_system;
import 'package:flutter_tools/src/build_system/targets/common.dart' as targets;
import 'package:flutter_tools/src/bundle_builder.dart' as bundle_builder;
import 'package:flutter_tools/src/cache.dart' as cache;
import 'package:flutter_tools/src/device.dart' as device;
import 'package:flutter_tools/src/device_port_forwarder.dart' as forwarding;
import 'package:flutter_tools/src/flutter_device_manager.dart' as manager;
import 'package:flutter_tools/src/protocol_discovery.dart' as protocol;
import 'package:flutter_tools/src/resident_runner.dart' as resident;
import 'package:flutter_tools/src/run_hot.dart' as run_hot;

/// Compile-time canary for the flutter_tools internals Pluto plans to use.
///
/// The rest of the Stage 6 implementation stays behind local interfaces. This
/// file is deliberately the only broad flutter_tools import site so SDK refactor
/// breakage lands in one place.
typedef CanaryDevice = device.Device;

/// Canary for flutter_tools `PollingDeviceDiscovery`.
typedef CanaryPollingDeviceDiscovery = device.PollingDeviceDiscovery;

/// Canary for flutter_tools `DeviceManager`.
typedef CanaryDeviceManager = device.DeviceManager;

/// Canary for flutter_tools `FlutterDeviceManager`.
typedef CanaryFlutterDeviceManager = manager.FlutterDeviceManager;

/// Canary for flutter_tools `ApplicationPackage`.
typedef CanaryApplicationPackage = app_package.ApplicationPackage;

/// Canary for flutter_tools `DevicePortForwarder`.
typedef CanaryDevicePortForwarder = forwarding.DevicePortForwarder;

/// Canary for flutter_tools `ForwardedPort`.
typedef CanaryForwardedPort = forwarding.ForwardedPort;

/// Canary for flutter_tools `ProtocolDiscovery`.
typedef CanaryProtocolDiscovery = protocol.ProtocolDiscovery;

/// Canary for flutter_tools `HotRunner`.
typedef CanaryHotRunner = run_hot.HotRunner;

/// Canary for flutter_tools `FlutterDevice`.
typedef CanaryFlutterDevice = resident.FlutterDevice;

/// Canary for flutter_tools `BundleBuilder`.
typedef CanaryBundleBuilder = bundle_builder.BundleBuilder;

/// Canary for flutter_tools `BuildSystem`.
typedef CanaryBuildSystem = build_system.BuildSystem;

/// Canary for flutter_tools `Environment`.
typedef CanaryEnvironment = build_system.Environment;

/// Canary for flutter_tools `Target`.
typedef CanaryTarget = build_system.Target;

/// Canary for flutter_tools `CompositeTarget`.
typedef CanaryCompositeTarget = build_system.CompositeTarget;

/// Canary for flutter_tools `KernelSnapshot`.
typedef CanaryKernelSnapshot = targets.KernelSnapshot;

/// Canary for flutter_tools `AotElfRelease`.
typedef CanaryAotElfRelease = targets.AotElfRelease;

/// Canary for flutter_tools `Artifacts`.
typedef CanaryArtifacts = artifacts.Artifacts;

/// Canary for flutter_tools `Cache`.
typedef CanaryCache = cache.Cache;

/// Canary for `TargetPlatform.linux_arm64`.
const build_info.TargetPlatform canaryLinuxArm64 =
    build_info.TargetPlatform.linux_arm64;
