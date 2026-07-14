import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pluto_device/pluto_device.dart';
import 'package:pluto_settings/pluto_settings.dart';

import 'codex/codex_bridge.dart';
import 'codex/fake_bridge.dart';
import 'store.dart';

/// Writable locations for the notebook. On device these come from the
/// `pluto/paths` channel (per-app appdata); on a host without the embedder
/// they fall back to `$PAPER_CODEX_HOME` or `~/.paper-codex`.
final class AppPaths {
  const AppPaths({required this.root});

  final Directory root;

  Directory get state => Directory('${root.path}/state');
  Directory get workspace => Directory('${root.path}/workspace');
  Directory get tmp => Directory('${root.path}/tmp');

  void ensure() {
    state.createSync(recursive: true);
    workspace.createSync(recursive: true);
    tmp.createSync(recursive: true);
  }

  static Future<AppPaths> resolve() async {
    try {
      const channel = MethodChannel('pluto/paths');
      final raw = await channel.invokeMethod<Object?>('getPaths');
      if (raw is Map<Object?, Object?>) {
        final documents = raw['documents'];
        if (documents is String && documents.isNotEmpty) {
          return AppPaths(root: Directory(documents));
        }
      }
    } on MissingPluginException {
      // Host preview — fall through.
    } on PlatformException {
      // Embedder without the paths handler — fall through.
    }
    final env = Platform.environment;
    final home =
        env['PAPER_CODEX_HOME'] ??
        '${env['HOME'] ?? Directory.systemTemp.path}/.paper-codex';
    return AppPaths(root: Directory(home));
  }
}

/// Panel description (palette + geometry), with graceful host fallback.
final class PanelInfo {
  const PanelInfo({required this.isColor});

  final bool isColor;

  static Future<PanelInfo> detect() async {
    try {
      final info = await PlutoDevice.instance.deviceInfo();
      return PanelInfo(
        isColor: info.panel.colorMode == PanelColorMode.gallery3,
      );
    } on Object {
      return const PanelInfo(isColor: true);
    }
  }
}

/// Wi-Fi status line for the settings page.
final class WifiSummary {
  const WifiSummary({required this.line, required this.connected});

  final String line;
  final bool connected;
}

/// Device-facing side effects, injectable for tests.
abstract interface class SystemBridge {
  Future<void> exitToLauncher();

  Future<double?> frontlightFraction();

  Future<void> setFrontlightFraction(double fraction);

  Future<WifiSummary> wifiSummary();
}

/// Channel-backed implementation; every call degrades gracefully off-device.
final class ChannelSystemBridge implements SystemBridge {
  ChannelSystemBridge();

  @override
  Future<void> exitToLauncher() async {
    await SystemNavigator.pop();
  }

  @override
  Future<double?> frontlightFraction() async {
    try {
      final state = await PlutoSettings.instance.frontlight.state();
      if (state.maxRaw <= 0) {
        return null;
      }
      return state.raw / state.maxRaw;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> setFrontlightFraction(double fraction) async {
    try {
      await PlutoSettings.instance.frontlight.setBrightnessFraction(fraction);
    } on Object {
      // Not available off-device.
    }
  }

  @override
  Future<WifiSummary> wifiSummary() async {
    try {
      final active = await PlutoSettings.instance.wifi.activeConnection();
      if (active != null) {
        return WifiSummary(
          line: 'wi-fi: ${active.ssid} (${active.ipAddress})',
          connected: true,
        );
      }
      final enabled = await PlutoSettings.instance.wifi.isEnabled();
      return WifiSummary(
        line: enabled ? 'wi-fi: not connected' : 'wi-fi: off',
        connected: false,
      );
    } on Object {
      return const WifiSummary(line: 'wi-fi: unknown', connected: false);
    }
  }
}

/// The writer's instrument settings: which mind and how long it thinks.
/// Null means "as the house config set it" (no override passed to codex).
final class MindSettings {
  const MindSettings({this.model, this.effort});

  final String? model;
  final String? effort;

  /// Models this codex build ships metadata for (probed from the CLI).
  static const List<String> models = [
    'gpt-5.6-sol',
    'gpt-5.6-luna',
    'gpt-5.6-terra',
  ];

  static const List<String> efforts = [
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  ];

  /// Normalizes persisted/selected effort against the bundled 0.144.x model
  /// catalog. `minimal` was exposed by an early UI but is not a valid Codex
  /// effort. Luna tops out at `max`; Sol and Terra additionally support
  /// `ultra`.
  static String? normalizeEffort(String? effort, {String? model}) {
    if (effort == null) {
      return null;
    }
    final normalized = effort == 'minimal' ? 'low' : effort;
    if (!efforts.contains(normalized)) {
      return null;
    }
    if (model == 'gpt-5.6-luna' && normalized == 'ultra') {
      return 'max';
    }
    return normalized;
  }

  MindSettings copyWith({
    String? Function()? model,
    String? Function()? effort,
  }) => MindSettings(
    model: model == null ? this.model : model(),
    effort: effort == null ? this.effort : effort(),
  );

  Map<String, Object?> toJson() => {
    if (model != null) 'model': model,
    if (effort != null) 'effort': effort,
  };

  static MindSettings fromJson(Map<String, Object?> json) {
    final model = json['model'] as String?;
    return MindSettings(
      model: model,
      effort: normalizeEffort(json['effort'] as String?, model: model),
    );
  }
}

/// Tiny atomic store for [MindSettings].
final class MindSettingsStore {
  MindSettingsStore({required this.stateDir});

  final Directory stateDir;

  File get _file => File('${stateDir.path}/mind.json');

  Future<MindSettings> load() async {
    try {
      if (!_file.existsSync()) {
        return const MindSettings();
      }
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map<String, Object?>) {
        final settings = MindSettings.fromJson(decoded);
        if (decoded['model'] != settings.model ||
            decoded['effort'] != settings.effort) {
          await save(settings);
        }
        return settings;
      }
    } on Object {
      // Corrupt settings never block the page.
    }
    return const MindSettings();
  }

  Future<void> save(MindSettings settings) async {
    try {
      stateDir.createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await tmp.rename(_file.path);
    } on Object {
      // Best effort.
    }
  }
}

/// Everything the app needs, bundled for constructor injection.
final class CodexServices {
  CodexServices({
    required this.bridge,
    required this.store,
    required this.paths,
    required this.panel,
    required this.system,
    MindSettingsStore? mindStore,
  }) : mindStore = mindStore ?? MindSettingsStore(stateDir: paths.state);

  final CodexBridge bridge;
  final TranscriptStore store;
  final AppPaths paths;
  final PanelInfo panel;
  final SystemBridge system;
  final MindSettingsStore mindStore;

  static Future<CodexServices> createReal() async {
    final paths = await AppPaths.resolve();
    paths.ensure();
    final panel = await PanelInfo.detect();
    // Scripted bridge for UI QA: env var on hosts, or a marker file in the
    // app's data root on device (where the supervisor owns the environment).
    final fake =
        Platform.environment['PAPER_CODEX_FAKE'] == '1' ||
        File('${paths.root.path}/fake-codex').existsSync();
    return CodexServices(
      bridge: fake ? FakeCodexBridge() : LiveCodexBridge(),
      store: TranscriptStore(stateDir: paths.state),
      paths: paths,
      panel: panel,
      system: ChannelSystemBridge(),
    );
  }
}
