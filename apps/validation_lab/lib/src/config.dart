/// Compile-time mode define, set with `--dart-define=VALIDATION_MODE=...`.
const String _modeDefine = String.fromEnvironment('VALIDATION_MODE');

/// Compile-time scene define, set with `--dart-define=VALIDATION_SCENE=...`.
const String _sceneDefine = String.fromEnvironment('VALIDATION_SCENE');

/// Compile-time HUD define, set with `--dart-define=VALIDATION_HUD=...`.
const String _hudDefine = String.fromEnvironment('VALIDATION_HUD');

/// Playback modes for the scene runner.
enum SceneRunnerMode {
  /// Runs the full scene loop and repeats forever.
  auto,

  /// Advances only on taps: left half = previous, right half = next.
  manual,

  /// Stays pinned on a single scene.
  single;

  /// Parses a wire [name], returning null when unknown.
  static SceneRunnerMode? tryParse(String name) {
    for (final SceneRunnerMode mode in SceneRunnerMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return null;
  }
}

/// Resolved launch configuration for the validation lab.
///
/// Sources, weakest to strongest:
/// 1. Built-in defaults (auto mode, full loop, HUD on).
/// 2. Compile-time defines: `VALIDATION_MODE`, `VALIDATION_SCENE`,
///    `VALIDATION_HUD` (via `--dart-define`).
/// 3. Entrypoint arguments: `--mode=<auto|manual|single>`, `--scene=<id>`,
///    `--hud=<on|off>` (via the embedder's `--dart-entrypoint-args`).
final class ValidationLabConfig {
  /// Creates a configuration.
  const ValidationLabConfig({
    this.mode = SceneRunnerMode.auto,
    this.initialSceneId,
    this.showHud = true,
  });

  /// Parses entrypoint [args] on top of the compile-time defines.
  ///
  /// Specifying a scene without a mode implies [SceneRunnerMode.single].
  /// Throws [FormatException] for unknown mode or HUD values.
  factory ValidationLabConfig.parse(
    List<String> args, {
    String modeDefine = _modeDefine,
    String sceneDefine = _sceneDefine,
    String hudDefine = _hudDefine,
  }) {
    final String modeText = _lastOptionValue(args, 'mode', modeDefine);
    final String sceneText = _lastOptionValue(args, 'scene', sceneDefine);
    final String hudText = _lastOptionValue(args, 'hud', hudDefine);

    final String? initialSceneId = sceneText.isEmpty ? null : sceneText;
    final SceneRunnerMode mode;
    if (modeText.isEmpty) {
      mode = initialSceneId == null
          ? SceneRunnerMode.auto
          : SceneRunnerMode.single;
    } else {
      mode =
          SceneRunnerMode.tryParse(modeText) ??
          (throw FormatException(
            'Unknown mode "$modeText". '
            'Valid modes: auto, manual, single.',
          ));
    }
    final bool showHud = switch (hudText) {
      '' || 'on' => true,
      'off' => false,
      _ => throw FormatException(
        'Unknown HUD value "$hudText". Valid values: on, off.',
      ),
    };
    return ValidationLabConfig(
      mode: mode,
      initialSceneId: initialSceneId,
      showHud: showHud,
    );
  }

  /// Scene playback mode.
  final SceneRunnerMode mode;

  /// Scene id to start on, or null for the first scene in the loop.
  final String? initialSceneId;

  /// Whether the stats overlay starts visible.
  final bool showHud;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ValidationLabConfig &&
            other.mode == mode &&
            other.initialSceneId == initialSceneId &&
            other.showHud == showHud;
  }

  @override
  int get hashCode => Object.hash(mode, initialSceneId, showHud);

  @override
  String toString() {
    return 'ValidationLabConfig(mode: ${mode.name}, '
        'initialSceneId: $initialSceneId, showHud: $showHud)';
  }
}

/// Returns the value of the last `--name=value` argument, or [fallback].
String _lastOptionValue(List<String> args, String name, String fallback) {
  final String prefix = '--$name=';
  String value = fallback;
  for (final String arg in args) {
    if (arg.startsWith(prefix)) {
      value = arg.substring(prefix.length);
    }
  }
  return value;
}
