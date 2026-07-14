import 'package:flutter/widgets.dart';

import 'src/config.dart';
import 'src/scene_runner.dart';
import 'src/scenes.dart';

export 'src/config.dart';
export 'src/lab_style.dart';
export 'src/scene.dart';
export 'src/scene_runner.dart';
export 'src/scenes.dart';

/// Starts the validation lab.
///
/// [args] come from the embedder's `--dart-entrypoint-args` (CSV-split),
/// layered on top of `--dart-define` values; see [ValidationLabConfig.parse].
void main(List<String> args) {
  runApp(ValidationLabApp(config: ValidationLabConfig.parse(args)));
}

/// Root widget for the renderer validation lab.
final class ValidationLabApp extends StatelessWidget {
  /// Creates the app with a resolved [config].
  const ValidationLabApp({required this.config, super.key});

  /// Scene runner configuration.
  final ValidationLabConfig config;

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFFFFFFFF),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: _pageRouteBuilder,
      title: 'Validation Lab',
      home: SceneRunner(
        scenes: buildValidationScenes(),
        mode: config.mode,
        initialSceneId: config.initialSceneId,
        showHud: config.showHud,
      ),
    );
  }
}

PageRoute<T> _pageRouteBuilder<T>(
  RouteSettings settings,
  WidgetBuilder builder,
) {
  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return builder(context);
        },
  );
}
