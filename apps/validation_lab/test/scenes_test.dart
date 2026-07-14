import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_validation_lab/main.dart';

void _setDeviceViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1.65;
  addTearDown(tester.view.reset);
}

Future<void> _pumpScene(WidgetTester tester, WidgetBuilder builder) async {
  _setDeviceViewport(tester);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: Builder(builder: builder),
        ),
      ),
    ),
  );
}

/// Pumps a scene under a toggleable [SceneRest] scope, as the runner does,
/// so tests can flip the rest beacon and assert the scene freezes.
Future<void> _pumpRestableScene(
  WidgetTester tester,
  WidgetBuilder builder,
  ValueNotifier<bool> resting,
) async {
  _setDeviceViewport(tester);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: ValueListenableBuilder<bool>(
            valueListenable: resting,
            builder: (BuildContext context, bool isResting, Widget? child) {
              return SceneRest(isResting: isResting, child: child!);
            },
            child: Builder(builder: builder),
          ),
        ),
      ),
    ),
  );
}

ValueNotifier<bool> _restSwitch() {
  final ValueNotifier<bool> resting = ValueNotifier<bool>(false);
  addTearDown(resting.dispose);
  return resting;
}

SceneSpec _sceneById(String id) {
  return buildValidationScenes().firstWhere(
    (SceneSpec scene) => scene.id == id,
  );
}

void main() {
  testWidgets('every scene builds and survives scripted pumping', (
    WidgetTester tester,
  ) async {
    for (final SceneSpec scene in buildValidationScenes()) {
      await _pumpScene(tester, scene.builder);
      for (int step = 0; step < 6; step += 1) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull, reason: 'scene ${scene.id}');
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('static-text renders the dense typographic page', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('static-text').builder);
    expect(find.text('Sphinx of black quartz, judge my vow.'), findsOneWidget);
    expect(find.text('STATIC TEXT'), findsOneWidget);

    // Static scene: nothing changes over time.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Sphinx of black quartz, judge my vow.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('counter-tick counts at exactly 2 Hz', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('counter-tick').builder);
    expect(find.text('0000'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0004'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('0005'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scroll-list scrolls at constant velocity then holds', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('scroll-list').builder);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(scrollable.position.pixels, 0);

    // One zero-duration pump so the scroll ticker takes its start tick.
    await tester.pump();

    // Halfway through the 6 s leg: 240 px/s * 3 s.
    await tester.pump(const Duration(seconds: 3));
    expect(scrollable.position.pixels, moreOrLessEquals(720, epsilon: 1));

    // Leg complete: 1440 px.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 50));
    expect(scrollable.position.pixels, moreOrLessEquals(1440, epsilon: 1));

    // Pause phase: the offset holds so the panel can settle.
    await tester.pump(const Duration(seconds: 2));
    expect(scrollable.position.pixels, moreOrLessEquals(1440, epsilon: 1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('page-turn alternates layouts every two seconds', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('page-turn').builder);
    expect(find.text('PAGE A-000'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('PAGE B-001'), findsOneWidget);
    expect(find.text('PAGE A-000'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('PAGE A-002'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('color-swatches blink tiles toggle on even steps', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('color-swatches').builder);
    expect(find.text('BLINK-1'), findsOneWidget);
    expect(find.text('RED'), findsOneWidget);
    expect(find.textContaining('STEP 000'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('BLINK-1'), findsNothing);
    expect(find.textContaining('STEP 001'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('BLINK-1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gradient-ramps is fully static', (WidgetTester tester) async {
    await _pumpScene(tester, _sceneById('gradient-ramps').builder);
    expect(find.text('GRAY RAMP — SMOOTH HORIZONTAL'), findsOneWidget);
    expect(find.text('GRAY STEPS — 16 QUANTIZED LEVELS'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('GRAY RAMP — SMOOTH HORIZONTAL'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('animation-stress alternates motion and rest phases', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('animation-stress').builder);
    expect(find.textContaining('PHASE MOTION'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('PHASE REST'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('PHASE MOTION'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ghost-torture alternates blocks then clears to white', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('ghost-torture').builder);
    expect(find.text('GHOST TORTURE 0123456789 ABCDEF'), findsNWidgets(4));

    // Steps 0-9 torture (800 ms each); step 10 enters the white hold.
    await tester.pump(const Duration(milliseconds: 8000));
    expect(find.textContaining('WHITE HOLD'), findsOneWidget);
    expect(find.text('GHOST TORTURE 0123456789 ABCDEF'), findsNothing);

    // Step 15 wraps back into torture.
    await tester.pump(const Duration(milliseconds: 4000));
    expect(find.text('GHOST TORTURE 0123456789 ABCDEF'), findsNWidgets(4));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen-scribble records strokes and clears them', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('pen-scribble').builder);
    expect(find.text('STROKES 000 INK IDLE'), findsOneWidget);

    final TestGesture gesture = await tester.startGesture(
      const Offset(200, 400),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(60, 20));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-30, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    expect(find.text('STROKES 001 INK LIVE'), findsOneWidget);

    final TestGesture secondGesture = await tester.startGesture(
      const Offset(300, 500),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await secondGesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 16));
    await secondGesture.up();
    await tester.pump();
    expect(find.text('STROKES 002 INK LIVE'), findsOneWidget);

    await tester.tap(find.text('CLEAR'));
    await tester.pump();
    expect(find.text('STROKES 000 INK LIVE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen-scribble draws itself after three idle seconds', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('pen-scribble').builder);
    expect(find.text('STROKES 000 INK IDLE'), findsOneWidget);

    // Still inside the idle window: nothing draws.
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('STROKES 000 INK IDLE'), findsOneWidget);

    // The idle trigger fires at 3 s and the zigzag stroke begins.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('STROKES 001 INK AUTO'), findsOneWidget);

    // The script keeps appending points at the simulated pen cadence.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('STROKES 001 INK AUTO'), findsOneWidget);

    // Both strokes (zigzag, then spiral) complete and the script stops on
    // its own well within the scene dwell.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('STROKES 002 INK DONE'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('STROKES 002 INK DONE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen-scribble live input before the idle window wins', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('pen-scribble').builder);

    final TestGesture gesture = await tester.startGesture(
      const Offset(200, 400),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(50, 30));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    expect(find.text('STROKES 001 INK LIVE'), findsOneWidget);

    // The auto script never starts, even long past the idle window.
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('STROKES 001 INK LIVE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen-scribble live input stops a running auto script', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('pen-scribble').builder);

    // Let the script get underway (zigzag stroke in progress).
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('STROKES 001 INK AUTO'), findsOneWidget);

    // A live pointer takes over: the partial auto stroke stays on the
    // canvas and the live stroke is recorded.
    final TestGesture gesture = await tester.startGesture(
      const Offset(120, 700),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(40, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();
    expect(find.text('STROKES 002 INK LIVE'), findsOneWidget);

    // The spiral never draws: the script does not re-arm.
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('STROKES 002 INK LIVE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('concurrent-regions tick and image update independently', (
    WidgetTester tester,
  ) async {
    await _pumpScene(tester, _sceneById('concurrent-regions').builder);
    expect(find.text('T=0000'), findsOneWidget);
    expect(find.text('IMG 000'), findsOneWidget);

    // 4 Hz fast region; slow region untouched.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('T=0004'), findsOneWidget);
    expect(find.text('IMG 000'), findsOneWidget);

    // Slow region advances at 5 s while the fast region keeps ticking.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('T=0024'), findsOneWidget);
    expect(find.text('IMG 001'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('counter-tick freezes in place for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('counter-tick').builder,
      resting,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0002'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0002'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('page-turn freezes in place for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(tester, _sceneById('page-turn').builder, resting);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('PAGE B-001'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('PAGE B-001'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('color-swatches freezes in place for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('color-swatches').builder,
      resting,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('STEP 001'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.textContaining('STEP 001'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ghost-torture freezes and never reaches the white hold', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('ghost-torture').builder,
      resting,
    );

    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('GHOST TORTURE 0123456789 ABCDEF'), findsNWidgets(4));

    resting.value = true;
    await tester.pump();
    // Well past the step-10 white hold: a live scene would have cleared,
    // a frozen one holds the torture board.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('GHOST TORTURE 0123456789 ABCDEF'), findsNWidgets(4));
    expect(find.textContaining('WHITE HOLD'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('animation-stress freezes mid-motion for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('animation-stress').builder,
      resting,
    );

    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('PHASE MOTION'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    // The controller is stopped: no ticker remains to schedule frames.
    expect(tester.binding.transientCallbackCount, 0);
    // Without the freeze the scene would flip to PHASE REST at the 8 s
    // mark.
    await tester.pump(const Duration(seconds: 10));
    expect(find.textContaining('PHASE MOTION'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scroll-list halts its leg for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('scroll-list').builder,
      resting,
    );
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    expect(scrollable.position.pixels, moreOrLessEquals(720, epsilon: 1));

    resting.value = true;
    await tester.pump();
    // The driven scroll activity is gone: no ticker remains to schedule
    // frames.
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(scrollable.position.pixels, moreOrLessEquals(720, epsilon: 1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('concurrent-regions freezes both regions for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('concurrent-regions').builder,
      resting,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('T=0004'), findsOneWidget);
    expect(find.text('IMG 000'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('T=0004'), findsOneWidget);
    expect(find.text('IMG 000'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen-scribble cancels the auto script for the rest beacon', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> resting = _restSwitch();
    await _pumpRestableScene(
      tester,
      _sceneById('pen-scribble').builder,
      resting,
    );

    // The script is underway when the rest beacon lands.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('STROKES 001 INK AUTO'), findsOneWidget);

    resting.value = true;
    await tester.pump();
    final String frozen = 'STROKES 001';
    await tester.pump(const Duration(seconds: 10));
    expect(find.textContaining(frozen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
