import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_ink_lab_example/main.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_pen/pluto_pen_testing.dart';
import 'package:pluto_touch/pluto_touch.dart';
import 'package:pluto_touch/pluto_touch_testing.dart';

void main() {
  test('strokeWidthFor maps pressure and degrades to a fixed width', () {
    expect(
      strokeWidthFor(isPressureMapped: false, normalizedPressure: 0.8),
      fixedInkStrokeWidth,
    );
    expect(
      strokeWidthFor(isPressureMapped: true, normalizedPressure: null),
      fixedInkStrokeWidth,
    );
    expect(
      strokeWidthFor(isPressureMapped: true, normalizedPressure: 0),
      minInkStrokeWidth,
    );
    expect(
      strokeWidthFor(isPressureMapped: true, normalizedPressure: 1),
      maxInkStrokeWidth,
    );
    expect(
      strokeWidthFor(isPressureMapped: true, normalizedPressure: 0.5),
      (minInkStrokeWidth + maxInkStrokeWidth) / 2,
    );
  });

  testWidgets('stylus drag paints strokes and clear removes them', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);

    expect(find.text('Strokes 0'), findsOneWidget);
    expect(find.text('Pressure map on (max 4096)'), findsOneWidget);

    await _drawLine(tester, from: const Offset(-60, -40));
    expect(find.text('Strokes 1'), findsOneWidget);
    expect(_canvasPainter(tester).strokeCount, 1);

    await _drawLine(tester, from: const Offset(40, 60));
    expect(find.text('Strokes 2'), findsOneWidget);

    await tester.tap(find.byKey(inkClearButtonKey));
    await tester.pump();
    expect(find.text('Strokes 0'), findsOneWidget);
    expect(_canvasPainter(tester).strokeCount, 0);
  });

  testWidgets('stylus hover is app-owned and clears on canvas exit', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);

    final TestGesture stylus = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
    );
    await stylus.addPointer();
    addTearDown(stylus.removePointer);

    await stylus.moveTo(tester.getCenter(find.byKey(inkCanvasPaintKey)));
    await tester.pump();
    expect(_canvasPainter(tester).hasHover, isTrue);
    expect(_canvasPainter(tester).strokeCount, 0);

    await stylus.moveTo(Offset.zero);
    await tester.pump();
    expect(_canvasPainter(tester).hasHover, isFalse);
    expect(_canvasPainter(tester).strokeCount, 0);
  });

  testWidgets('eraser toggle erases instead of drawing', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);
    expect(find.text('Mode DRAW'), findsOneWidget);

    await tester.tap(find.byKey(inkEraserToggleKey));
    await tester.pump();
    expect(find.text('Mode ERASE'), findsOneWidget);

    // Dragging over the stroke removes it and paints nothing new.
    await _drawLine(tester);
    expect(find.text('Strokes 0'), findsOneWidget);
    expect(_canvasPainter(tester).strokeCount, 0);

    // Toggling back returns to drawing.
    await tester.tap(find.byKey(inkEraserToggleKey));
    await tester.pump();
    expect(find.text('Mode DRAW'), findsOneWidget);
    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);
  });

  testWidgets('physical eraser tool from the pen stream erases strokes', (
    WidgetTester tester,
  ) async {
    final StreamController<PenEvent> penController =
        StreamController<PenEvent>.broadcast();
    addTearDown(penController.close);
    await _pumpApp(tester, penEvents: FakePenEvents(penController.stream));

    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);

    penController.add(
      PenDownEvent(
        sample: _sample(
          const Offset(300, 400),
          pressure: 0.8,
          tool: PenTool.eraser,
        ),
      ),
    );
    await _pumpStream(tester);
    expect(find.text('Tool eraser'), findsOneWidget);
    expect(find.text('Mode ERASE'), findsOneWidget);

    await _drawLine(tester);
    expect(find.text('Strokes 0'), findsOneWidget);

    penController.add(
      PenLeftProximityEvent(
        sample: _sample(const Offset(300, 400), pressure: 0),
      ),
    );
    await _pumpStream(tester);
    expect(find.text('Tool --'), findsOneWidget);
    expect(find.text('Mode DRAW'), findsOneWidget);

    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);
  });

  testWidgets('capability probe failure degrades to fixed-width ink', (
    WidgetTester tester,
  ) async {
    await _pumpApp(
      tester,
      penCapabilitiesProbe: () async => throw StateError('no pen stack'),
    );

    expect(find.text('Pressure map off'), findsOneWidget);

    // Drawing still works without pressure support.
    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);
  });

  testWidgets('pen stream errors surface as a degraded readout', (
    WidgetTester tester,
  ) async {
    final StreamController<PenEvent> penController =
        StreamController<PenEvent>.broadcast();
    addTearDown(penController.close);
    await _pumpApp(tester, penEvents: FakePenEvents(penController.stream));

    penController.addError(StateError('transport gone'));
    await _pumpStream(tester);
    expect(find.text('Tool stream off'), findsOneWidget);

    // Pointer drawing is unaffected.
    await _drawLine(tester);
    expect(find.text('Strokes 1'), findsOneWidget);
  });

  testWidgets('touch palm rejection updates the ink HUD', (
    WidgetTester tester,
  ) async {
    final StreamController<TouchEvent> touchController =
        StreamController<TouchEvent>.broadcast();
    addTearDown(touchController.close);
    await _pumpApp(
      tester,
      touchEvents: FakeTouchEvents(touchController.stream),
    );

    touchController.add(
      TouchRejectedEvent(
        timestamp: const Duration(milliseconds: 1),
        contact: const TouchContact(
          slot: 0,
          trackingId: 7,
          position: Offset(100, 100),
          rawPosition: Offset(100, 100),
          touchMajor: 0.9,
          pressure: 0.5,
          toolType: TouchToolType.palm,
        ),
        reason: PalmRejectionReason.kernelToolType,
      ),
    );
    await _pumpStream(tester);

    expect(find.text('Palm rejected 1'), findsOneWidget);
  });

  testWidgets('corner exit affordance invokes the exit callback', (
    WidgetTester tester,
  ) async {
    bool exited = false;
    await _pumpApp(tester, onExit: () => exited = true);

    await tester.tap(find.byKey(inkExitButtonKey));
    expect(exited, isTrue);
  });
}

Future<void> _pumpApp(
  WidgetTester tester, {
  PenEvents? penEvents,
  TouchEvents? touchEvents,
  PenCapabilitiesProbe? penCapabilitiesProbe,
  VoidCallback? onExit,
}) async {
  await tester.pumpWidget(
    InkLabApp(
      penEvents: penEvents ?? FakePenEvents(const Stream<PenEvent>.empty()),
      touchEvents:
          touchEvents ?? FakeTouchEvents(const Stream<TouchEvent>.empty()),
      penCapabilitiesProbe: penCapabilitiesProbe ?? _supportedCapabilities,
      onExit: onExit ?? () {},
    ),
  );
  // Let the capability probe future complete.
  await tester.pump();
}

/// Pumps twice: one frame delivers the async stream event, one rebuilds.
Future<void> _pumpStream(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<PenCapabilities> _supportedCapabilities() async {
  return const PenCapabilities(
    rawXMax: 11180,
    rawYMax: 15340,
    rawPressureMax: 4096,
    rawDistanceMax: 65535,
    rawTiltMaxCentiDegrees: 9000,
    estimatedSampleRateHz: 240,
  );
}

/// Draws (or erases, in erase mode) a short stylus drag across the canvas
/// center; the same path is reused so erase passes hit earlier strokes.
Future<void> _drawLine(
  WidgetTester tester, {
  Offset from = const Offset(-40, -30),
}) async {
  final Offset center = tester.getCenter(find.byKey(inkCanvasPaintKey));
  final TestGesture gesture = await tester.startGesture(
    center + from,
    kind: PointerDeviceKind.stylus,
  );
  await gesture.moveTo(center);
  await gesture.moveTo(center - from);
  await gesture.up();
  await tester.pump();
}

PenSample _sample(
  Offset position, {
  required double pressure,
  PenTool tool = PenTool.pen,
  PenButtons buttons = PenButtons.none,
}) {
  return PenSample(
    timestamp: const Duration(milliseconds: 1),
    position: position,
    rawPosition: position,
    pressure: pressure,
    rawPressure: (pressure * 4096).round(),
    tilt: const Offset(0.18, -0.12),
    rawTilt: const Offset(1031, -688),
    distance: tool == PenTool.eraser ? 0 : 0.12,
    rawDistance: tool == PenTool.eraser ? 0 : 7864,
    tool: tool,
    buttons: buttons,
  );
}

InkLabCanvasPainter _canvasPainter(WidgetTester tester) {
  final CustomPaint canvas = tester.widget<CustomPaint>(
    find.byKey(inkCanvasPaintKey),
  );
  return canvas.painter! as InkLabCanvasPainter;
}
