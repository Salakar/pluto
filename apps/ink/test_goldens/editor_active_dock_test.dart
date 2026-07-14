import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/bench/bench.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:paper_ink/src/ui/status_chips.dart';
import 'package:pluto_ui/pluto_ui.dart';

// Regression: the REAL ContextualDock over the FULL editor chrome (status band +
// bench + canvas). The dock painters once used `canvas.drawColor`, which fills
// the whole canvas rather than the dock's rect, whiting out every sibling —
// on device the editor opened blank with only the dock's mode cell visible.
// The tool goldens never caught this because they reimplement the dock with a
// bounded drawRect; this scene uses the production widget.
void main() {
  testWidgets('real contextual dock does not white out the editor', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(954, 1696);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQueryData.fromView(View.of(context)),
            child: PaperTheme(
              data: const PaperThemeData(isColorPanel: false),
              child: RepaintBoundary(
                key: const ValueKey<String>('scene'),
                child: ColoredBox(
                  color: const Color(0xffffffff),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      const ColoredBox(color: Color(0xffe6e6e6)),
                      Align(
                        alignment: Alignment.topCenter,
                        child: InkEditorStatusBand(
                          artworkName: 'start here',
                          zoomPercent: 100,
                          activeLayerName: 'sketch',
                          savePhase: InkSavePhase.quiet,
                          onBack: () {},
                          onArtworkPressed: () {},
                          onZoomPressed: () {},
                          onLayerPressed: () {},
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(
                          top: inkStatusBandDesignHeight,
                        ),
                        child: Align(
                          alignment: InkBenchDock.right.alignment,
                          child: InkBench(
                            dock: InkBenchDock.right,
                            collapsed: false,
                            activeToolId: 'fill',
                            activeBrush: finelinerBrush,
                            brushSize: finelinerBrush.sizeDefault,
                            brushFlow: 1,
                            currentColor: const Color(0xff000000),
                            activeLayerOrdinal: 1,
                            canUndo: false,
                            canRedo: false,
                            onToggleCollapsed: () {},
                            onToolSelected: (_) {},
                            onBrushPressed: () {},
                            onSizeChanged: (_) {},
                            onFlowChanged: (_) {},
                            onColorPressed: () {},
                            onUndo: () {},
                            onRedo: () {},
                            onLayersPressed: () {},
                            onMenuPressed: () {},
                            onDockChanged: (_) {},
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: ContextualDock(
                          mode: ContextualDockMode.fill,
                          onAction: (_) {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The bench must still be present and painted (the drawColor bug removed it).
    expect(
      find.byKey(const ValueKey<String>('ink-bench-right')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('ink-status-band')),
      findsOneWidget,
    );

    // The bench sits on the right edge, below the status band, at full height.
    final Rect benchRect = tester.getRect(
      find.byKey(const ValueKey<String>('ink-bench-right')),
    );
    expect(benchRect.right, closeTo(954, 1));
    expect(benchRect.height, greaterThan(400));

    // Visual guard: the golden must show the full editor + dock, not a white
    // screen with only the dock cell.
    await expectLater(
      find.byKey(const ValueKey<String>('scene')),
      matchesGoldenFile('goldens/g24_editor_fill_dock.png'),
    );
  });
}
