import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_validation_lab/main.dart';

const Size _viewportSize = Size(578, 1027);

/// Dwell (1 s) + rest beacon (2.5 s) for the test scenes below.
const Duration _scenePeriod = Duration(milliseconds: 3500);

List<SceneSpec> _threeScenes() {
  return <SceneSpec>[
    SceneSpec(
      id: 'one',
      title: 'One',
      duration: const Duration(seconds: 1),
      builder: (_) => const Text('SCENE ONE'),
    ),
    SceneSpec(
      id: 'two',
      title: 'Two',
      duration: const Duration(seconds: 1),
      builder: (_) => const Text('SCENE TWO'),
    ),
    SceneSpec(
      id: 'three',
      title: 'Three',
      duration: const Duration(seconds: 1),
      builder: (_) => const Text('SCENE THREE'),
    ),
  ];
}

/// Sizes the test surface so tap coordinates match [_viewportSize].
void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = _viewportSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _shell(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: _viewportSize),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

/// A scene that ticks at 4 Hz and honors the rest beacon, proving the
/// runner freezes scene-owned timers via [SceneRestFreeze].
final class _ProbeScene extends StatefulWidget {
  const _ProbeScene();

  @override
  State<_ProbeScene> createState() => _ProbeSceneState();
}

final class _ProbeSceneState extends State<_ProbeScene> with SceneRestFreeze {
  Timer? _timer;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (Timer timer) {
      setState(() {
        _ticks += 1;
      });
    });
  }

  @override
  void freezeForRest() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text('PROBE $_ticks');
  }
}

void main() {
  testWidgets('auto mode advances on the wall clock, rests, and wraps', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(_shell(SceneRunner(scenes: _threeScenes())));

    expect(find.text('SCENE ONE'), findsOneWidget);
    expect(find.text('S01/03 one'), findsOneWidget);
    expect(find.text('N=0001 C=01'), findsOneWidget);

    // The pacing is wall-clock: each pump below is a single frame spanning
    // seconds, so advancing cannot depend on how many frames are produced.
    await tester.pump(const Duration(milliseconds: 1050));
    // Dwell elapsed, but the rest beacon holds scene one on glass.
    expect(find.text('SCENE ONE'), findsOneWidget);
    expect(find.text('N=0001 C=01'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('SCENE TWO'), findsOneWidget);
    expect(find.text('S02/03 two'), findsOneWidget);
    expect(find.text('N=0002 C=01'), findsOneWidget);

    await tester.pump(_scenePeriod);
    expect(find.text('SCENE THREE'), findsOneWidget);

    // Wrap-around: back to scene one, monotonic counter keeps growing and
    // the cycle counter increments.
    await tester.pump(_scenePeriod);
    expect(find.text('SCENE ONE'), findsOneWidget);
    expect(find.text('N=0004 C=02'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the rest beacon freezes the scene and the HUD clock', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(
        SceneRunner(
          scenes: <SceneSpec>[
            SceneSpec(
              id: 'probe',
              title: 'Probe',
              duration: const Duration(seconds: 1),
              builder: (_) => const _ProbeScene(),
            ),
            SceneSpec(
              id: 'two',
              title: 'Two',
              duration: const Duration(seconds: 1),
              builder: (_) => const Text('SCENE TWO'),
            ),
          ],
        ),
      ),
    );
    expect(find.text('PROBE 0'), findsOneWidget);

    // Dwell ends at 1.0 s; the freeze frame lands with four 250 ms ticks
    // and one HUD second on the board.
    await tester.pump(const Duration(milliseconds: 1050));
    expect(find.text('PROBE 4'), findsOneWidget);
    expect(find.textContaining('T=0001s'), findsOneWidget);

    // Deep inside the rest beacon nothing moves: scene timers are
    // cancelled, the HUD clock is stopped, the banner is untouched.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('PROBE 4'), findsOneWidget);
    expect(find.textContaining('T=0001s'), findsOneWidget);
    expect(find.text('N=0001 C=01'), findsOneWidget);
    // The app schedules ZERO frames during rest: no ticker is live and no
    // timer callback has queued a build — quiescence settles can fire.
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.binding.transientCallbackCount, 0);

    // Rest over at 3.5 s: the next scene enters and the HUD clock resets
    // and resumes.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('SCENE TWO'), findsOneWidget);
    expect(find.text('N=0002 C=01'), findsOneWidget);
    expect(find.textContaining('T=0000s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('T=0001s'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a zero rest duration advances directly between scenes', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(SceneRunner(scenes: _threeScenes(), restDuration: Duration.zero)),
    );
    expect(find.text('SCENE ONE'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1050));
    expect(find.text('SCENE TWO'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual mode advances with right taps and goes back with left', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(SceneRunner(scenes: _threeScenes(), mode: SceneRunnerMode.manual)),
    );
    expect(find.text('SCENE ONE'), findsOneWidget);

    // Manual mode never auto-advances (and never rests).
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('SCENE ONE'), findsOneWidget);

    await tester.tapAt(
      Offset(_viewportSize.width * 0.75, _viewportSize.height * 0.5),
    );
    await tester.pump();
    expect(find.text('SCENE TWO'), findsOneWidget);
    expect(find.text('N=0002 C=01'), findsOneWidget);

    await tester.tapAt(
      Offset(_viewportSize.width * 0.25, _viewportSize.height * 0.5),
    );
    await tester.pump();
    expect(find.text('SCENE ONE'), findsOneWidget);
    // Going back still increments the monotonic counter.
    expect(find.text('N=0003 C=01'), findsOneWidget);

    // Backward wrap-around reaches the last scene.
    await tester.tapAt(
      Offset(_viewportSize.width * 0.25, _viewportSize.height * 0.5),
    );
    await tester.pump();
    expect(find.text('SCENE THREE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual mode ignores taps in reserved chrome corners', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(SceneRunner(scenes: _threeScenes(), mode: SceneRunnerMode.manual)),
    );

    // Bottom-left banner corner: reserved.
    await tester.tapAt(Offset(30, _viewportSize.height - 30));
    await tester.pump();
    expect(find.text('SCENE ONE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('single mode stays pinned to the requested scene', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(
        SceneRunner(
          scenes: _threeScenes(),
          mode: SceneRunnerMode.single,
          initialSceneId: 'two',
        ),
      ),
    );
    expect(find.text('SCENE TWO'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('SCENE TWO'), findsOneWidget);
    expect(find.text('N=0001 C=01'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unknown initial scene id throws an ArgumentError', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(
        SceneRunner(scenes: _threeScenes(), initialSceneId: 'nonexistent'),
      ),
    );
    expect(tester.takeException(), isArgumentError);
  });

  testWidgets('stats HUD shows frame and scene time and toggles off', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(SceneRunner(scenes: _threeScenes(), mode: SceneRunnerMode.single)),
    );
    expect(find.textContaining('F='), findsOneWidget);
    expect(find.textContaining('T=0000s'), findsOneWidget);

    // The scene clock ticks at 1 Hz.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('T=0002s'), findsOneWidget);

    await tester.tap(find.text('HUD'));
    await tester.pump();
    expect(find.textContaining('F='), findsNothing);

    await tester.tap(find.text('HUD'));
    await tester.pump();
    expect(find.textContaining('F='), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HUD can start hidden via showHud: false', (
    WidgetTester tester,
  ) async {
    _setViewport(tester);
    await tester.pumpWidget(
      _shell(
        SceneRunner(
          scenes: _threeScenes(),
          mode: SceneRunnerMode.single,
          showHud: false,
        ),
      ),
    );
    expect(find.textContaining('F='), findsNothing);
    expect(find.text('HUD'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ValidationLabApp wires config through to the runner', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(954, 1696);
    tester.view.devicePixelRatio = 1.65;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ValidationLabApp(
        config: ValidationLabConfig(
          mode: SceneRunnerMode.single,
          initialSceneId: 'gradient-ramps',
        ),
      ),
    );
    expect(find.text('S06/10 gradient-ramps'), findsOneWidget);
    expect(find.text('GRADIENT RAMPS'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    expect(find.text('S06/10 gradient-ramps'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
