import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_pen/pluto_pen_testing.dart';

import 'document/document.dart';
import 'document/document_io.dart';
import 'document/tile_store.dart';

/// Resolves the embedder's application paths payload.
typedef PathsChannelCall = Future<Object?> Function();

/// Loads a device snapshot from `pluto_device`.
typedef DeviceInfoLoader = Future<DeviceInfo> Function();

/// Seeds deterministic content when Ink runs through its fake gate.
typedef FakeDocumentSeeder =
    Future<void> Function(DocumentStore store, Clock clock);

/// Writable locations used by Ink.
///
/// On device [root] is the channel-provided documents directory. Host runs
/// fall back to `PAPER_INK_HOME`, then `~/.paper-ink`.
final class AppPaths {
  /// Creates an application path bundle rooted at [root].
  const AppPaths({required this.root});

  /// The documents directory containing gallery metadata and artworks.
  final Directory root;

  /// Persisted artwork directories.
  Directory get artworks => Directory('${root.path}/artworks');

  /// Soft-deleted artwork directories.
  Directory get trash => Directory('${root.path}/trash');

  /// User-visible exported files.
  Directory get exports => Directory('${root.path}/exports');

  /// Files waiting to be imported.
  Directory get imports => Directory('${root.path}/imports');

  /// Creates the directories Ink owns.
  void ensure() {
    root.createSync(recursive: true);
    artworks.createSync(recursive: true);
    trash.createSync(recursive: true);
    exports.createSync(recursive: true);
    imports.createSync(recursive: true);
  }

  /// Resolves paths from `pluto/paths`, with host-safe fallbacks.
  static Future<AppPaths> resolve({
    PathsChannelCall? channelCall,
    Map<String, String>? environment,
  }) async {
    try {
      final Object? raw = await (channelCall ?? _readPathsChannel)();
      if (raw is Map<Object?, Object?>) {
        final Object? documents = raw['documents'];
        if (documents is String && documents.isNotEmpty) {
          return AppPaths(root: Directory(documents));
        }
      }
    } on MissingPluginException {
      // Host preview: fall through to the environment-backed path.
    } on PlatformException {
      // Older embedders may not expose the paths handler.
    }

    final Map<String, String> env = environment ?? Platform.environment;
    final String root =
        env['PAPER_INK_HOME'] ??
        '${env['HOME'] ?? Directory.systemTemp.path}/.paper-ink';
    return AppPaths(root: Directory(root));
  }

  static Future<Object?> _readPathsChannel() {
    const MethodChannel channel = MethodChannel('pluto/paths');
    return channel.invokeMethod<Object?>('getPaths');
  }
}

/// Physical e-ink film class used for palette and preview labelling.
enum InkPhysicalPanelClass {
  /// Carta-family monochrome film, or an unknown host device.
  monochrome,

  /// Gallery 3 film in the Paper Pro family.
  gallery3,
}

/// Cached device facts needed by Ink's model and renderer.
final class DeviceFacts {
  /// Creates a cached device description.
  const DeviceFacts({
    required this.panelWidth,
    required this.panelHeight,
    required this.dpi,
    required this.isColor,
  });

  /// Portrait Pluto render-surface width in pixels.
  final int panelWidth;

  /// Portrait Pluto render-surface height in pixels.
  final int panelHeight;

  /// Active render-surface density.
  final int dpi;

  /// Whether the active presenter currently drives color.
  final bool isColor;

  /// Safe defaults for host previews and tests without an embedder.
  static const DeviceFacts hostDefault = DeviceFacts(
    panelWidth: 954,
    panelHeight: 1696,
    dpi: 264,
    isColor: true,
  );

  /// Reads and caches device facts, returning [hostDefault] on any failure.
  static Future<DeviceFacts> detect({DeviceInfoLoader? loader}) async {
    try {
      final DeviceInfo info =
          await (loader ?? PlutoDevice.instance.deviceInfo)();
      return DeviceFacts(
        panelWidth: info.panel.width,
        panelHeight: info.panel.height,
        dpi: info.panel.dpi,
        isColor: info.isColor,
      );
    } on Object {
      return hostDefault;
    }
  }
}

/// Display capabilities derived from the device snapshot.
final class InkDisplayCaps {
  /// Creates display capabilities.
  const InkDisplayCaps({
    required this.presenterDrivesColor,
    required this.physicalPanelClass,
  });

  /// Whether the presenter currently emits color pixels to glass.
  final bool presenterDrivesColor;

  /// The physical film class, independent of presenter readiness.
  final InkPhysicalPanelClass physicalPanelClass;

  /// Derives capabilities without presenter-name string matching.
  factory InkDisplayCaps.fromDevice(DeviceFacts device) {
    return InkDisplayCaps(
      presenterDrivesColor: device.isColor,
      physicalPanelClass: device.isColor
          ? InkPhysicalPanelClass.gallery3
          : InkPhysicalPanelClass.monochrome,
    );
  }
}

/// Device-facing side effects, injectable for tests.
abstract interface class SystemBridge {
  /// Returns control to the Pluto launcher.
  Future<void> exitToLauncher();

  /// Requests a full-quality refresh of the physical display.
  Future<void> requestFullRefresh();
}

/// Channel-backed system side effects with off-device no-op fallbacks.
final class ChannelSystemBridge implements SystemBridge {
  /// Creates a channel-backed bridge.
  ChannelSystemBridge({
    Future<void> Function()? exitCall,
    Future<Object?> Function()? refreshCall,
  }) : _exitCall = exitCall ?? (() => SystemNavigator.pop()),
       _refreshCall = refreshCall ?? _requestRefreshChannel;

  final Future<void> Function() _exitCall;
  final Future<Object?> Function() _refreshCall;

  @override
  Future<void> exitToLauncher() async {
    try {
      await _exitCall();
    } on MissingPluginException {
      // Host tests do not install the platform navigation handler.
    } on PlatformException {
      // A device without the launcher bridge treats exit as a no-op.
    }
  }

  @override
  Future<void> requestFullRefresh() async {
    try {
      await _refreshCall();
    } on MissingPluginException {
      // Host previews have no physical display to refresh.
    } on PlatformException {
      // Older embedders do not expose manual refresh control.
    }
  }

  static Future<Object?> _requestRefreshChannel() {
    const MethodChannel channel = MethodChannel('pluto/refresh');
    return channel.invokeMethod<Object?>('requestFullRefresh');
  }
}

/// Time source for persistence metadata and deterministic tests.
abstract interface class Clock {
  /// Current wall-clock time.
  DateTime now();

  /// Current Unix epoch time in milliseconds.
  int nowMilliseconds();
}

/// Wall-clock implementation used by the real application.
final class SystemClock implements Clock {
  /// Creates the process wall clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  int nowMilliseconds() => DateTime.now().millisecondsSinceEpoch;
}

/// All external dependencies used by Ink, bundled for constructor injection.
final class InkServices {
  /// Creates an explicit service bundle.
  const InkServices({
    required this.paths,
    required this.store,
    required this.pen,
    required this.device,
    required this.system,
    required this.display,
    required this.clock,
    this.isFake = false,
  });

  /// Writable application locations.
  final AppPaths paths;

  /// Document persistence rooted at [paths].
  final DocumentStore store;

  /// Typed pen metadata source.
  final PenEvents pen;

  /// Cached panel and hardware facts.
  final DeviceFacts device;

  /// Launcher and display side effects.
  final SystemBridge system;

  /// Capabilities derived from [device].
  final InkDisplayCaps display;

  /// Injectable wall clock.
  final Clock clock;

  /// Whether the scripted host/device fake gate is active.
  final bool isFake;

  /// Builds real services, while retaining seams for host-side tests.
  static Future<InkServices> createReal({
    PathsChannelCall? pathsChannelCall,
    Map<String, String>? environment,
    DeviceInfoLoader? deviceInfoLoader,
    PenEvents? livePen,
    SystemBridge? system,
    Clock clock = const SystemClock(),
    FakeDocumentSeeder? fakeDocumentSeeder,
  }) async {
    final AppPaths paths = await AppPaths.resolve(
      channelCall: pathsChannelCall,
      environment: environment,
    );
    paths.ensure();
    final DeviceFacts device = await DeviceFacts.detect(
      loader: deviceInfoLoader,
    );
    final Map<String, String> env = environment ?? Platform.environment;
    final bool isFake =
        env['PAPER_INK_FAKE'] == '1' ||
        File('${paths.root.path}/fake-ink').existsSync();
    final DocumentStore store = DocumentStore(
      root: paths.root,
      nowMilliseconds: clock.nowMilliseconds,
    );
    final InkServices services = InkServices(
      paths: paths,
      store: store,
      pen: isFake
          ? const FakePenEvents(Stream<PenEvent>.empty())
          : (livePen ?? PlutoPen.instance),
      device: device,
      system: system ?? ChannelSystemBridge(),
      display: InkDisplayCaps.fromDevice(device),
      clock: clock,
      isFake: isFake,
    );
    if (isFake) {
      await (fakeDocumentSeeder ?? _seedFakeDocuments)(store, clock);
    }
    return services;
  }

  static Future<void> _seedFakeDocuments(
    DocumentStore store,
    Clock clock,
  ) async {
    if ((await store.loadGallery()).isNotEmpty) {
      return;
    }
    final InkDocument demo = InkDocument.blank(
      id: 'demo-welcome',
      nowMs: clock.nowMilliseconds(),
      name: 'Welcome to Ink',
    );
    await store.saveDocument(demo, TileStore());
  }
}
