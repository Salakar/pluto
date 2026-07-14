import 'scene.dart';
import 'scenes/animation_stress_scene.dart';
import 'scenes/color_swatches_scene.dart';
import 'scenes/concurrent_regions_scene.dart';
import 'scenes/counter_tick_scene.dart';
import 'scenes/ghost_torture_scene.dart';
import 'scenes/gradient_ramps_scene.dart';
import 'scenes/page_turn_scene.dart';
import 'scenes/pen_scribble_scene.dart';
import 'scenes/scroll_list_scene.dart';
import 'scenes/static_text_scene.dart';

export 'scenes/animation_stress_scene.dart';
export 'scenes/color_swatches_scene.dart';
export 'scenes/concurrent_regions_scene.dart';
export 'scenes/counter_tick_scene.dart';
export 'scenes/ghost_torture_scene.dart';
export 'scenes/gradient_ramps_scene.dart';
export 'scenes/page_turn_scene.dart';
export 'scenes/pen_scribble_scene.dart';
export 'scenes/scroll_list_scene.dart';
export 'scenes/static_text_scene.dart';

/// Builds the full validation scene loop in playback order.
///
/// One full cycle is 184 seconds of dwell plus ten 2.5-second rest beacons
/// (209 seconds total in auto mode), satisfying the >= 3 minute dead-man
/// discipline from the device validation plan.
List<SceneSpec> buildValidationScenes() {
  return <SceneSpec>[
    SceneSpec(
      id: 'static-text',
      title: 'Static text',
      duration: const Duration(seconds: 20),
      builder: (_) => const StaticTextScene(),
    ),
    SceneSpec(
      id: 'counter-tick',
      title: 'Counter tick',
      duration: const Duration(seconds: 16),
      builder: (_) => const CounterTickScene(),
    ),
    SceneSpec(
      id: 'scroll-list',
      title: 'Scroll list',
      duration: const Duration(seconds: 20),
      builder: (_) => const ScrollListScene(),
    ),
    SceneSpec(
      id: 'page-turn',
      title: 'Page turn',
      duration: const Duration(seconds: 16),
      builder: (_) => const PageTurnScene(),
    ),
    SceneSpec(
      id: 'color-swatches',
      title: 'Color swatches',
      duration: const Duration(seconds: 16),
      builder: (_) => const ColorSwatchesScene(),
    ),
    SceneSpec(
      id: 'gradient-ramps',
      title: 'Gradient ramps',
      duration: const Duration(seconds: 16),
      builder: (_) => const GradientRampsScene(),
    ),
    SceneSpec(
      id: 'animation-stress',
      title: 'Animation stress',
      duration: const Duration(seconds: 20),
      builder: (_) => const AnimationStressScene(),
    ),
    SceneSpec(
      id: 'ghost-torture',
      title: 'Ghost torture',
      duration: const Duration(seconds: 20),
      builder: (_) => const GhostTortureScene(),
    ),
    SceneSpec(
      id: 'pen-scribble',
      title: 'Pen scribble',
      duration: const Duration(seconds: 20),
      builder: (_) => const PenScribbleScene(),
    ),
    SceneSpec(
      id: 'concurrent-regions',
      title: 'Concurrent regions',
      duration: const Duration(seconds: 20),
      builder: (_) => const ConcurrentRegionsScene(),
    ),
  ];
}
