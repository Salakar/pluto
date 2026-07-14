import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/app.dart';
import 'package:paper_codex/src/app_model.dart';
import 'package:paper_codex/src/codex/fake_bridge.dart';
import 'package:paper_codex/src/models.dart';
import 'package:paper_codex/src/paper/layout.dart';
import 'package:paper_codex/src/services.dart';
import 'package:paper_codex/src/store.dart';
import 'package:paper_codex/src/ui/chat_page.dart';
import 'package:paper_codex/src/ui/composer.dart';
import 'package:paper_codex/src/ui/ink_canvas.dart';
import 'package:paper_codex/src/ui/settings_page.dart';
import 'package:paper_codex/src/ui/shelf_overlay.dart';
import 'package:paper_codex/src/ui/transcript_view.dart';

final class _RecordingSystem implements SystemBridge {
  int exits = 0;

  @override
  Future<void> exitToLauncher() async {
    exits += 1;
  }

  @override
  Future<double?> frontlightFraction() async => 0.4;

  @override
  Future<void> setFrontlightFraction(double fraction) async {}

  @override
  Future<WifiSummary> wifiSummary() async =>
      const WifiSummary(line: 'wi-fi: testnet', connected: true);
}

void main() {
  late Directory dir;
  late _RecordingSystem system;

  CodexServices services({FakeCodexBridge? bridge}) {
    final paths = AppPaths(root: dir)..ensure();
    system = _RecordingSystem();
    return CodexServices(
      bridge: bridge ?? FakeCodexBridge(),
      store: TranscriptStore(stateDir: paths.state),
      paths: paths,
      panel: const PanelInfo(isColor: true),
      system: system,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('codex-widget-test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  Future<void> setViewport(
    WidgetTester tester, {
    Size physicalSize = const Size(954, 1696),
    double devicePixelRatio = 2.0,
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.reset);
  }

  /// Maps a design-pixel page point to a logical tap position.
  Offset at(double dx, double dy) =>
      Offset(dx * 477 / PageDesign.pageW, dy * 477 / PageDesign.pageW);

  Future<CodexAppModel> pumpApp(
    WidgetTester tester, {
    FakeCodexBridge? bridge,
    Size physicalSize = const Size(954, 1696),
    double devicePixelRatio = 2.0,
  }) async {
    await setViewport(
      tester,
      physicalSize: physicalSize,
      devicePixelRatio: devicePixelRatio,
    );
    await tester.pumpWidget(PaperCodexApp(services: services(bridge: bridge)));
    await tester.pump();
    final state = tester.state<State<ChatPage>>(find.byType(ChatPage));
    return state.widget.model;
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Drains mixed fake-async timers (the fake bridge) and real IO (the
  /// store persist) until the model leaves the busy phase.
  Future<void> settleTurn(WidgetTester tester, CodexAppModel model) async {
    for (var i = 0; i < 50 && model.phase == TurnPhase.busy; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pump();
  }

  Future<void> settleQueue(WidgetTester tester, CodexAppModel model) async {
    for (
      var i = 0;
      i < 100 && (model.phase == TurnPhase.busy || model.queuedCount > 0);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pump();
  }

  for (final viewport in [
    (name: 'Paper Pro Move', physical: const Size(954, 1696), dpr: 264 / 160),
    (name: 'reMarkable 1/2', physical: const Size(1404, 1872), dpr: 226 / 160),
  ]) {
    testWidgets(
      '${viewport.name} uses its full responsive viewport without overlap',
      (tester) async {
        final model = await pumpApp(
          tester,
          physicalSize: viewport.physical,
          devicePixelRatio: viewport.dpr,
        );
        final logical = Size(
          viewport.physical.width / viewport.dpr,
          viewport.physical.height / viewport.dpr,
        );
        final metrics = PageScale.forViewport(
          logical,
          devicePixelRatio: viewport.dpr,
        );

        expect(
          metrics.physicalSize.width,
          closeTo(viewport.physical.width, 0.001),
        );
        expect(
          metrics.physicalSize.height,
          closeTo(viewport.physical.height, 0.001),
        );
        expect(tester.getSize(find.byType(ChatPage)), logical);

        final transcript = tester.getRect(find.byType(TranscriptView));
        final composer = tester.getRect(find.byKey(const ValueKey('composer')));
        final separatorY = metrics.u(
          Composer.sepYFor(AuthorMode.keyboard, metrics),
        );
        expect(composer.bottom, closeTo(logical.height, 0.001));
        expect(transcript.bottom, lessThan(separatorY));
        expect(transcript.width, closeTo(logical.width - metrics.u(28), 0.001));
        if (viewport.physical.width > PageDesign.pageW) {
          expect(metrics.designContentW, greaterThan(PageDesign.contentW));
          expect(transcript.width, greaterThan(metrics.u(PageDesign.pageW)));
        }

        final viewportRect = Offset.zero & logical;
        final settingsButton = tester.getRect(
          find.byKey(const ValueKey('settings-button')),
        );
        expect(viewportRect.contains(settingsButton.topLeft), isTrue);
        expect(viewportRect.contains(settingsButton.bottomRight), isTrue);
        final shelfTab = tester.getRect(
          find.byKey(const ValueKey('shelf-tab')),
        );
        expect(viewportRect.overlaps(shelfTab), isTrue);
        expect(viewportRect.contains(shelfTab.center), isTrue);

        // The wider keyboard consumes the real width and remains interactive.
        final q = Offset(
          PageDesign.kbX0 + metrics.designKeyboardPitch * 0.43,
          metrics.designKbTopY + PageDesign.keyH / 2,
        );
        await tester.tapAt(metrics.uo(q));
        await tester.pump();
        expect(model.keyboardDraft, 'q');

        await tester.tap(find.byKey(const ValueKey('settings-button')));
        await tester.pump();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('settings-back')));
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('page-mind-button')));
        await tester.pump();
        expect(find.byKey(const ValueKey('page-mind-sheet')), findsOneWidget);
        expect(tester.takeException(), isNull);
        model.closePageMind();
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('shelf-tab')));
        await tester.pump();
        expect(find.byType(ShelfOverlay), findsOneWidget);
        expect(tester.takeException(), isNull);
        model.closeShelf();
        model.toggleMode();
        await tester.pump();

        final handwritingComposer = tester.getRect(
          find.byKey(const ValueKey('composer')),
        );
        final handwritingTranscript = tester.getRect(
          find.byType(TranscriptView),
        );
        final handwritingSeparatorY = metrics.u(
          Composer.sepYFor(AuthorMode.handwriting, metrics),
        );
        expect(handwritingComposer.bottom, closeTo(logical.height, 0.001));
        expect(handwritingTranscript.bottom, lessThan(handwritingSeparatorY));
        expect(find.byType(InkCanvas), findsOneWidget);
        expect(
          viewportRect.contains(
            metrics.uo(metrics.designSendMarkRectHw.center),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await teardownTree(tester);
      },
    );
  }

  testWidgets('idle page keeps a visible caret without repainting', (
    WidgetTester tester,
  ) async {
    await setViewport(tester);
    final GlobalKey boundaryKey = GlobalKey();
    await tester.pumpWidget(
      _PaintCountingBoundary(
        key: boundaryKey,
        child: PaperCodexApp(services: services()),
      ),
    );
    await tester.pump();
    // Let the intentional one-shot boot sweep finish before measuring idle.
    await tester.pump(const Duration(milliseconds: 600));

    final _PaintCountingRenderBoundary boundary = tester.renderObject(
      find.byKey(boundaryKey),
    );
    final Uint8List baseline = await _captureTestPixels(tester, boundary);
    final int baselinePaintCount = boundary.paintCount;
    final PageScale metrics = PageScale.forViewport(
      tester.view.physicalSize / tester.view.devicePixelRatio,
      devicePixelRatio: tester.view.devicePixelRatio,
    );
    expect(
      _darkCaretPixels(baseline, boundary.size, metrics),
      greaterThanOrEqualTo(8),
      reason: 'the steady caret must remain visible on the entry rule',
    );

    for (int interval = 0; interval < 3; interval += 1) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        boundary.paintCount,
        baselinePaintCount,
        reason: 'idle interval ${interval + 1} triggered a repaint',
      );
      expect(
        await _captureTestPixels(tester, boundary),
        orderedEquals(baseline),
        reason: 'idle pixels changed after ${(interval + 1) * 500} ms',
      );
    }

    await teardownTree(tester);
  });

  testWidgets('typing on the sketch keyboard edits the draft', (tester) async {
    final model = await pumpApp(tester);
    // 'q' key: row 0 col 0 → design rect (61,1352,55,56).
    await tester.tapAt(at(88, 1380));
    await tester.pump(const Duration(milliseconds: 50));
    // 'space' row 3 spans cols 2.55..7.55 → tap its middle.
    await tester.tapAt(at(61 + 5.0 * 64, 1352 + 3 * 64 + 28));
    await tester.pump(const Duration(milliseconds: 50));
    // 'i' key: row 0 col 7 → x 61+448..;
    await tester.tapAt(at(61 + 7 * 64 + 27, 1380));
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.keyboardDraft, 'q i');
    // Backspace: row 0, col 11 span 1.45.
    await tester.tapAt(at(61 + 11 * 64 + 46, 1380));
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.keyboardDraft, 'q ');
    await teardownTree(tester);
  });

  testWidgets('send flourish runs a turn and the answer writes itself', (
    tester,
  ) async {
    final model = await pumpApp(
      tester,
      bridge: FakeCodexBridge(
        answer: 'Short and calm.',
        stepDelay: const Duration(milliseconds: 10),
      ),
    );
    model.keyTap('h');
    model.keyTap('i');
    await tester.pump();
    // Send mark (keyboard): design rect (838,1244,64,64).
    await tester.tapAt(at(870, 1276));
    await tester.pump(const Duration(milliseconds: 30));
    expect(model.phase, TurnPhase.busy);
    // Let the fake bridge resolve and the reveal play out.
    await settleTurn(tester, model);
    expect(model.phase, TurnPhase.idle);
    expect(model.active.messages, hasLength(2));
    expect(model.active.messages[1].text, 'Short and calm.');
    // Pump through the quill reveal until its ticker stops.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 130));
    }
    await teardownTree(tester);
  });

  testWidgets('sending handwriting clears the composer canvas immediately', (
    tester,
  ) async {
    final model = await pumpApp(
      tester,
      bridge: FakeCodexBridge(
        answer: 'I read the drawing.',
        stepDelay: const Duration(milliseconds: 150),
      ),
    );
    model.toggleMode();
    model.addStroke(
      const InkStroke(
        points: [InkPoint(100, 1420, 0.5), InkPoint(300, 1460, 0.8)],
      ),
    );
    await tester.pump();
    expect(model.handwritingDraft, hasLength(1));
    expect(
      tester.widget<InkCanvas>(find.byType(InkCanvas)).strokes,
      hasLength(1),
    );

    await tester.tapAt(at(870, 1632));
    await tester.pump();

    expect(model.handwritingDraft, isEmpty);
    expect(tester.widget<InkCanvas>(find.byType(InkCanvas)).strokes, isEmpty);
    for (var i = 0; i < 50 && model.active.messages.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await settleTurn(tester, model);
    expect(model.active.messages.first.isHandwritten, isTrue);
    await teardownTree(tester);
  });

  testWidgets('mode marks swap composer modes', (tester) async {
    final model = await pumpApp(tester);
    expect(model.inputMode, AuthorMode.keyboard);
    // Nib mark in keyboard mode: (44,1192,40,40).
    await tester.tapAt(at(64, 1212));
    await tester.pump();
    expect(model.inputMode, AuthorMode.handwriting);
    // Keys mark in handwriting mode: (96,1312,40,40).
    await tester.tapAt(at(116, 1332));
    await tester.pump();
    expect(model.inputMode, AuthorMode.keyboard);
    await teardownTree(tester);
  });

  testWidgets('shelf tab opens the shelf; veil closes it', (tester) async {
    final model = await pumpApp(tester);
    await tester.tapAt(at(944, 430));
    await tester.pump();
    expect(model.shelfOpen, isTrue);
    expect(find.byType(ShelfOverlay), findsOneWidget);
    // Tap the veiled page area (left of the shelf).
    await tester.tapAt(at(100, 800));
    await tester.pump();
    expect(model.shelfOpen, isFalse);
    await teardownTree(tester);
  });

  testWidgets('settings sun opens settings; return line exits to launcher', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tapAt(at(908, 50));
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    // 'return to the launcher' occupies rule 3's band.
    await tester.tapAt(at(400, 150 + 3 * 56 - 20));
    await tester.pump();
    expect(system.exits, 1);
    await teardownTree(tester);
  });

  testWidgets('busy send queues visibly and steer now promotes it', (
    tester,
  ) async {
    final model = await pumpApp(
      tester,
      bridge: FakeCodexBridge(
        answer: 'slow',
        stepDelay: const Duration(milliseconds: 300),
      ),
    );
    model.keyTap('a');
    await tester.pump();
    await tester.tapAt(at(870, 1276));
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.phase, TurnPhase.busy);
    model.keyTap('b');
    await tester.pump();
    await tester.tapAt(at(870, 1276));
    await tester.pump(const Duration(milliseconds: 20));
    expect(model.keyboardDraft, isEmpty);
    expect(model.queuedCount, 1);
    final queued = model.active.messages.last;
    expect(queued.state, MessageState.queued);
    final steer = find.byKey(ValueKey('steer-${queued.id}'));
    expect(steer, findsOneWidget);
    await tester.tap(steer);
    await tester.pump(const Duration(milliseconds: 20));
    // Resolve everything before teardown.
    await settleQueue(tester, model);
    expect(model.queuedCount, 0);
    expect(model.active.messages[1].error, FailureKind.stopped);
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 130));
    }
    await teardownTree(tester);
  });

  testWidgets('the labeled divider stop control stops the active turn', (
    tester,
  ) async {
    final model = await pumpApp(
      tester,
      bridge: FakeCodexBridge(
        answer: 'slow',
        stepDelay: const Duration(milliseconds: 300),
      ),
    );
    model.keyTap('a');
    await tester.pump();
    await tester.tapAt(at(870, 1276));
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.phase, TurnPhase.busy);

    // Right edge of the divider: the outlined square + "stop" control.
    await tester.tapAt(at(825, 1184));
    await settleTurn(tester, model);
    expect(model.phase, TurnPhase.idle);
    expect(model.active.messages[1].error, FailureKind.stopped);
    await teardownTree(tester);
  });
  testWidgets('goal: flag sets it, ribbon wells pause and finish it', (
    tester,
  ) async {
    final model = await pumpApp(tester);
    // The strip flag (right of pen/keyboard on the divider) opens goal mode.
    await tester.tapAt(at(210, 1186));
    await tester.pump();
    expect(model.goalEditing, isTrue);
    model.keyTap('s');
    model.keyTap('h');
    model.keyTap('i');
    model.keyTap('p');
    await tester.pump();
    // Send commits the goal rather than a turn.
    await tester.tapAt(at(870, 1276));
    await settleTurn(tester, model);
    expect(model.active.goalText, 'ship');
    expect(model.active.goalStatus, GoalStatus.active);
    expect(model.active.messages, isEmpty);
    await tester.pump();
    // With a goal pinned, the ribbon owns it: the strip flag slot is inert.
    await tester.tapAt(at(210, 1186));
    await tester.pump();
    expect(model.goalEditing, isFalse);
    // Pause well (first of the three wells on the ribbon).
    await tester.tapAt(at(910 - 168 + 28, 122));
    await settleTurn(tester, model);
    expect(model.active.goalStatus, GoalStatus.paused);
    // Done well.
    await tester.tapAt(at(910 - 48 + 28, 122));
    await settleTurn(tester, model);
    expect(model.active.goalStatus, GoalStatus.done);
    await teardownTree(tester);
  });
}

final class _PaintCountingBoundary extends SingleChildRenderObjectWidget {
  const _PaintCountingBoundary({required super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PaintCountingRenderBoundary();
}

final class _PaintCountingRenderBoundary extends RenderRepaintBoundary {
  int paintCount = 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    paintCount += 1;
    super.paint(context, offset);
  }
}

Future<Uint8List> _capturePixels(_PaintCountingRenderBoundary boundary) async {
  final ui.Image image = await boundary.toImage();
  try {
    final ByteData data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    return Uint8List.fromList(data.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _captureTestPixels(
  WidgetTester tester,
  _PaintCountingRenderBoundary boundary,
) async {
  return (await tester.runAsync(() => _capturePixels(boundary)))!;
}

int _darkCaretPixels(Uint8List pixels, Size size, PageScale metrics) {
  final int width = size.width.round();
  final int x0 = metrics.u(PageDesign.contentX0 + 7).floor();
  final int x1 = metrics.u(PageDesign.contentX0 + 12).ceil();
  final int y0 = metrics.u(metrics.designKbEntryRulesY.first - 29).floor();
  final int y1 = metrics.u(metrics.designKbEntryRulesY.first - 5).ceil();
  int darkPixels = 0;
  for (int y = y0; y < y1; y += 1) {
    for (int x = x0; x < x1; x += 1) {
      final int offset = (y * width + x) * 4;
      if (pixels[offset] < 100 &&
          pixels[offset + 1] < 100 &&
          pixels[offset + 2] < 100) {
        darkPixels += 1;
      }
    }
  }
  return darkPixels;
}
