import 'package:flutter/widgets.dart';

/// A deterministic, self-contained validation scene.
///
/// Scene content must be reproducible run to run: fixed strings, fixed
/// timer periods, seeded or constant pseudo-randomness, and no wall-clock
/// dependent layout. (Scene *pacing* — dwell and the rest beacon — is
/// wall-clock on purpose, so the loop advances at nominal durations
/// regardless of the device frame rate.)
final class SceneSpec {
  /// Creates a scene description.
  const SceneSpec({
    required this.id,
    required this.title,
    required this.duration,
    required this.builder,
  });

  /// Stable kebab-case identifier, e.g. `ghost-torture`.
  final String id;

  /// Human-readable scene name.
  final String title;

  /// Dwell time before auto-advance in [SceneRunnerMode.auto].
  final Duration duration;

  /// Builds a fresh instance of the scene widget.
  final WidgetBuilder builder;
}

/// Rest-beacon signal from the runner to the scene subtree.
///
/// While `isResting` is true the runner is holding the current scene for
/// its rest beacon: the scene must freeze in its final static state and
/// the app must schedule no further frames, so the renderer's quiescence
/// settles can fire and clear ghost debt before the next scene.
final class SceneRest extends InheritedWidget {
  /// Creates a rest-beacon scope.
  const SceneRest({required this.isResting, required super.child, super.key});

  /// Whether the enclosing runner is inside the rest beacon.
  final bool isResting;

  /// True when an enclosing runner is resting; false when the scene is
  /// standalone (tests, single-scene embedding).
  static bool isRestingIn(BuildContext context) {
    final SceneRest? scope = context
        .dependOnInheritedWidgetOfExactType<SceneRest>();
    return scope?.isResting ?? false;
  }

  @override
  bool updateShouldNotify(SceneRest oldWidget) {
    return oldWidget.isResting != isResting;
  }
}

/// Freezes a scene's self-driven activity when the rest beacon begins.
///
/// The runner never un-rests a scene instance — a rest always ends in a
/// scene switch that builds a fresh instance — so [freezeForRest] fires at
/// most once per instance.
mixin SceneRestFreeze<T extends StatefulWidget> on State<T> {
  bool _frozeForRest = false;

  /// Whether the rest beacon has frozen this scene instance.
  bool get isFrozenForRest => _frozeForRest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_frozeForRest && SceneRest.isRestingIn(context)) {
      _frozeForRest = true;
      // Freeze right after the rest frame paints: post-frame callbacks run
      // before control returns to the event loop, so no scene timer can
      // slip in another frame, and side effects (stopping controllers,
      // halting scrolls) stay out of the build phase.
      WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
        if (mounted) {
          freezeForRest();
        }
      });
    }
  }

  /// Cancels every timer and ticker the scene owns so it holds its final
  /// static state and stops producing frames.
  void freezeForRest();
}
