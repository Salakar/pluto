import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/ui/bench/bench.dart';
import 'package:paper_ink/src/ui/bench/contextual_dock_host.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:paper_ink/src/ui/panels/brush_panel.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  group('WP7 bench authored geometry', () {
    test('side, top, collapsed, and touch geometry stay canonical', () {
      expect(inkBenchSideDesignWidth, 160);
      expect(inkBenchSideDesignHeight, 1056);
      expect(inkBenchTopDesignHeight, 120);
      expect(inkBenchCollapsedDesignWidth, 80);
      expect(inkBenchCollapsedDesignHeight, 96);
      expect(inkBenchGripDesignHeight, 80);
      expect(inkBenchToolCellDesignSize, 80);
      expect(inkBenchBrushChipDesignHeight, 96);
      expect(inkBenchSliderNotchCount, 16);
    });

    test('ten-tool grid order matches the persisted router ids', () {
      expect(
        InkBenchTool.values.map((InkBenchTool tool) => tool.id),
        orderedEquals(<String>[
          'draw',
          'erase',
          'select',
          'transform',
          'fill',
          'shape',
          'text',
          'picker',
          'guides',
          'crop',
        ]),
      );
      expect(
        InkBenchTool.values.map((InkBenchTool tool) => tool.id),
        isNot(contains('reference')),
      );
    });

    test('dock layout exposes top reflow and composition alignment', () {
      expect(InkBenchDock.left.isTop, isFalse);
      expect(InkBenchDock.right.isTop, isFalse);
      expect(InkBenchDock.top.isTop, isTrue);
      expect(InkBenchDock.left.alignment, Alignment.topLeft);
      expect(InkBenchDock.right.alignment, Alignment.topRight);
      expect(InkBenchDock.top.alignment, Alignment.topCenter);
    });
  });

  group('WP7 bench parameter rails', () {
    test('size endpoints map exactly to logarithmic endpoint notches', () {
      expect(inkBenchSizeNotch(value: 2, minimum: 2, maximum: 32), 0);
      expect(inkBenchSizeNotch(value: 32, minimum: 2, maximum: 32), 15);
      expect(inkBenchSizeForNotch(notch: 0, minimum: 2, maximum: 32), 2);
      expect(
        inkBenchSizeForNotch(notch: 15, minimum: 2, maximum: 32),
        closeTo(32, 0.000001),
      );
    });

    test('size midpoint is logarithmic rather than arithmetic', () {
      final double value = inkBenchSizeForNotch(
        notch: 5,
        minimum: 1,
        maximum: 64,
      );

      expect(value, closeTo(4, 0.000001));
      expect(inkBenchSizeNotch(value: value, minimum: 1, maximum: 64), 5);
    });

    test('size input clamps for lookup but rejects invalid domains', () {
      expect(inkBenchSizeNotch(value: 0.5, minimum: 1, maximum: 8), 0);
      expect(inkBenchSizeNotch(value: 20, minimum: 1, maximum: 8), 15);
      expect(
        () => inkBenchSizeNotch(value: 0, minimum: 1, maximum: 8),
        throwsArgumentError,
      );
      expect(
        () => inkBenchSizeForNotch(notch: 16, minimum: 1, maximum: 8),
        throwsRangeError,
      );
      expect(
        () => inkBenchSizeForNotch(notch: 0, minimum: 0, maximum: 8),
        throwsArgumentError,
      );
    });

    test('degenerate brush ranges remain stable', () {
      expect(inkBenchSizeNotch(value: 5, minimum: 5, maximum: 5), 0);
      expect(inkBenchSizeForNotch(notch: 12, minimum: 5, maximum: 5), 5);
    });

    test('flow uses all sixteen linear positions', () {
      expect(inkBenchFlowNotch(0), 0);
      expect(inkBenchFlowNotch(1), 15);
      expect(inkBenchFlowNotch(0.5), 8);
      expect(inkBenchFlowForNotch(0), 0);
      expect(inkBenchFlowForNotch(15), 1);
      expect(inkBenchFlowForNotch(8), closeTo(8 / 15, 0.000001));
    });

    test('flow rejects non-normalized values and invalid notches', () {
      expect(() => inkBenchFlowNotch(-0.01), throwsRangeError);
      expect(() => inkBenchFlowNotch(1.01), throwsRangeError);
      expect(() => inkBenchFlowForNotch(-1), throwsRangeError);
      expect(() => inkBenchFlowForNotch(16), throwsRangeError);
    });

    test('size readout is compact and validates values', () {
      expect(inkBenchSizeLabel(3), '3');
      expect(inkBenchSizeLabel(3.25), '3.3');
      expect(inkBenchSizeLabel(3.02), '3');
      expect(() => inkBenchSizeLabel(double.nan), throwsArgumentError);
    });
  });

  group('WP7 dock drag intent', () {
    const Size viewport = Size(954, 1696);

    test('short drag retains the current edge', () {
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.left,
          start: const Offset(40, 128),
          end: const Offset(50, 130),
          viewport: viewport,
        ),
        InkBenchDock.left,
      );
    });

    test('side grip moves upward to the top dock', () {
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.left,
          start: const Offset(80, 500),
          end: const Offset(100, 120),
          viewport: viewport,
        ),
        InkBenchDock.top,
      );
    });

    test('horizontal side drag chooses the destination half', () {
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.left,
          start: const Offset(80, 400),
          end: const Offset(900, 420),
          viewport: viewport,
        ),
        InkBenchDock.right,
      );
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.right,
          start: const Offset(900, 400),
          end: const Offset(40, 420),
          viewport: viewport,
        ),
        InkBenchDock.left,
      );
    });

    test('downward top drag chooses a side from release position', () {
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.top,
          start: const Offset(400, 100),
          end: const Offset(300, 500),
          viewport: viewport,
        ),
        InkBenchDock.left,
      );
      expect(
        inkBenchDockForDrag(
          current: InkBenchDock.top,
          start: const Offset(500, 100),
          end: const Offset(800, 500),
          viewport: viewport,
        ),
        InkBenchDock.right,
      );
    });
  });

  group('WP7 contextual dock composition hook', () {
    test('maps only tools with contextual action sets', () {
      expect(
        inkContextualDockModeForTool('select'),
        ContextualDockMode.selection,
      );
      expect(
        inkContextualDockModeForTool('transform'),
        ContextualDockMode.transform,
      );
      expect(inkContextualDockModeForTool('fill'), ContextualDockMode.fill);
      expect(inkContextualDockModeForTool('shape'), ContextualDockMode.shape);
      expect(inkContextualDockModeForTool('text'), ContextualDockMode.text);
      expect(inkContextualDockModeForTool('crop'), ContextualDockMode.crop);
      expect(inkContextualDockModeForTool('guides'), ContextualDockMode.guides);
      expect(inkContextualDockModeForTool('draw'), isNull);
      expect(inkContextualDockModeForTool('erase'), ContextualDockMode.erase);
      expect(inkContextualDockModeForTool('picker'), isNull);
    });

    testWidgets('swaps the whole dock away without live state', (
      WidgetTester tester,
    ) async {
      await _pumpBench(
        tester,
        InkContextualDockHost(
          activeToolId: 'select',
          hasLiveState: false,
          onAction: (_) {},
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('ink-contextual-dock-hidden')),
        findsOneWidget,
      );
      expect(find.byType(ContextualDock), findsNothing);
    });

    testWidgets('visible host forwards stable contextual actions', (
      WidgetTester tester,
    ) async {
      final List<ContextualDockAction> actions = <ContextualDockAction>[];
      await _pumpBench(
        tester,
        InkContextualDockHost(
          activeToolId: 'crop',
          hasLiveState: true,
          onAction: actions.add,
        ),
      );

      expect(find.byType(ContextualDock), findsOneWidget);
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey<String>('ink-contextual-dock-visible')),
            )
            .height,
        contextualDockDesignHeight,
      );
      await tester.tap(find.text('apply'));
      await tester.pump();

      expect(actions, <ContextualDockAction>[ContextualDockAction.apply]);
    });
  });

  group('WP7 bench widgets', () {
    testWidgets('left side renders exact structure and real brush proof', (
      WidgetTester tester,
    ) async {
      await _pumpBench(tester, _bench(dock: InkBenchDock.left));

      expect(
        tester.getSize(find.byKey(const ValueKey<String>('ink-bench-left'))),
        const Size(160, 1056),
      );
      expect(_toolFinders(), everyElement(findsOneWidget));
      expect(find.byType(BrushMiniProofPainter), findsNothing);
      final CustomPaint proof = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is CustomPaint && widget.painter is BrushMiniProofPainter,
        ),
      );
      expect(proof.painter, isA<BrushMiniProofPainter>());
      expect(find.byKey(const ValueKey<String>('bench-size')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('bench-flow')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('bench-color')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('bench-layers')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('bench-menu')), findsOneWidget);
    });

    testWidgets('right side mirrors edge without changing authored size', (
      WidgetTester tester,
    ) async {
      await _pumpBench(tester, _bench(dock: InkBenchDock.right));

      expect(
        tester.getSize(find.byKey(const ValueKey<String>('ink-bench-right'))),
        const Size(160, 1056),
      );
      expect(_toolFinders(), everyElement(findsOneWidget));
    });

    testWidgets('top dock reflows ten tools into one 120-dpx strip', (
      WidgetTester tester,
    ) async {
      await _pumpBench(tester, _bench(dock: InkBenchDock.top));

      expect(
        tester.getSize(find.byKey(const ValueKey<String>('ink-bench-top'))),
        const Size(954, 120),
      );
      for (final InkBenchTool tool in InkBenchTool.values) {
        expect(
          tester.getSize(find.byKey(ValueKey<String>('bench-tool-${tool.id}'))),
          const Size(80, 120),
        );
      }
    });

    testWidgets('collapsed dock is an 80-by-96 active-tool grip tab', (
      WidgetTester tester,
    ) async {
      await _pumpBench(
        tester,
        _bench(dock: InkBenchDock.right, collapsed: true, activeToolId: 'crop'),
      );

      expect(
        tester.getSize(
          find.byKey(const ValueKey<String>('ink-bench-collapsed')),
        ),
        const Size(80, 96),
      );
      expect(
        find.bySemanticsLabel('Restore bench, active tool crop'),
        findsOneWidget,
      );
      expect(_toolFinders(), everyElement(findsNothing));
    });

    testWidgets('all ten tool cells emit stable ids', (
      WidgetTester tester,
    ) async {
      final List<String> selected = <String>[];
      await _pumpBench(tester, _bench(onToolSelected: selected.add));

      for (final InkBenchTool tool in InkBenchTool.values) {
        await tester.tap(find.byKey(ValueKey<String>('bench-tool-${tool.id}')));
        await tester.pump();
      }

      expect(
        selected,
        orderedEquals(InkBenchTool.values.map((InkBenchTool tool) => tool.id)),
      );
    });

    testWidgets('selected tool is exposed through semantics', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _pumpBench(tester, _bench(activeToolId: 'transform'));

      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey<String>('bench-tool-transform')),
            )
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey<String>('bench-tool-draw')))
            .flagsCollection
            .isSelected,
        ui.Tristate.isFalse,
      );
      semantics.dispose();
    });

    testWidgets('brush, color, layers, and menu callbacks stay disjoint', (
      WidgetTester tester,
    ) async {
      final List<String> actions = <String>[];
      await _pumpBench(
        tester,
        _bench(
          onBrushPressed: () => actions.add('brush'),
          onColorPressed: () => actions.add('color'),
          onLayersPressed: () => actions.add('layers'),
          onMenuPressed: () => actions.add('menu'),
        ),
      );

      for (final String key in <String>[
        'bench-brush',
        'bench-color',
        'bench-layers',
        'bench-menu',
      ]) {
        await tester.tap(find.byKey(ValueKey<String>(key)));
        await tester.pump();
      }

      expect(actions, <String>['brush', 'color', 'layers', 'menu']);
    });

    testWidgets('disabled undo is inert while enabled redo emits', (
      WidgetTester tester,
    ) async {
      var undoCount = 0;
      var redoCount = 0;
      await _pumpBench(
        tester,
        _bench(
          canUndo: false,
          canRedo: true,
          onUndo: () => undoCount += 1,
          onRedo: () => redoCount += 1,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('bench-undo')));
      await tester.tap(find.byKey(const ValueKey<String>('bench-redo')));
      await tester.pump();

      expect(undoCount, 0);
      expect(redoCount, 1);
    });

    testWidgets('size rail emits the active brush logarithmic maximum', (
      WidgetTester tester,
    ) async {
      double? selected;
      await _pumpBench(
        tester,
        _bench(onSizeChanged: (double value) => selected = value),
      );
      final Finder rail = find.byKey(const ValueKey<String>('bench-size'));
      final Offset topLeft = tester.getTopLeft(rail);
      final Size size = tester.getSize(rail);

      await tester.tapAt(topLeft + Offset(size.width - 1, size.height / 2));
      await tester.pump();

      expect(selected, finelinerBrush.sizeMax);
    });

    testWidgets('flow rail emits exact normalized endpoints', (
      WidgetTester tester,
    ) async {
      final List<double> selected = <double>[];
      await _pumpBench(tester, _bench(onFlowChanged: selected.add));
      final Finder rail = find.byKey(const ValueKey<String>('bench-flow'));
      final Offset topLeft = tester.getTopLeft(rail);
      final Size size = tester.getSize(rail);

      await tester.tapAt(topLeft + Offset(1, size.height / 2));
      await tester.tapAt(topLeft + Offset(size.width - 1, size.height / 2));
      await tester.pump();

      expect(selected, <double>[0, 1]);
    });

    testWidgets('grip tap collapses and grip drag requests another edge', (
      WidgetTester tester,
    ) async {
      var collapseCount = 0;
      final List<InkBenchDock> docks = <InkBenchDock>[];
      await _pumpBench(
        tester,
        _bench(
          onToggleCollapsed: () => collapseCount += 1,
          onDockChanged: docks.add,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('bench-grip')));
      await tester.pump();
      expect(collapseCount, 1);

      await tester.drag(
        find.byKey(const ValueKey<String>('bench-grip')),
        const Offset(700, 10),
      );
      await tester.pump();

      expect(docks, <InkBenchDock>[InkBenchDock.right]);
    });

    testWidgets('80 dpx tool cell scales to the 48-lp device target', (
      WidgetTester tester,
    ) async {
      const Size deviceViewport = Size(572.4, 1017.6);
      await _pumpBench(tester, _bench(), mediaSize: deviceViewport);

      expect(
        tester.getSize(find.byKey(const ValueKey<String>('bench-tool-draw'))),
        const Size(48, 48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('bench-grip'))).height,
        48,
      );
    });
  });
}

Iterable<Finder> _toolFinders() => InkBenchTool.values.map(
  (InkBenchTool tool) => find.byKey(ValueKey<String>('bench-tool-${tool.id}')),
);

InkBench _bench({
  InkBenchDock dock = InkBenchDock.left,
  bool collapsed = false,
  String activeToolId = 'draw',
  bool canUndo = true,
  bool canRedo = true,
  VoidCallback? onToggleCollapsed,
  ValueChanged<String>? onToolSelected,
  VoidCallback? onBrushPressed,
  ValueChanged<double>? onSizeChanged,
  ValueChanged<double>? onFlowChanged,
  VoidCallback? onColorPressed,
  VoidCallback? onUndo,
  VoidCallback? onRedo,
  VoidCallback? onLayersPressed,
  VoidCallback? onMenuPressed,
  ValueChanged<InkBenchDock>? onDockChanged,
}) {
  return InkBench(
    dock: dock,
    collapsed: collapsed,
    activeToolId: activeToolId,
    activeBrush: finelinerBrush,
    brushSize: finelinerBrush.sizeDefault,
    brushFlow: 0.8,
    currentColor: const Color(0xff1d3e74),
    activeLayerOrdinal: 2,
    canUndo: canUndo,
    canRedo: canRedo,
    onToggleCollapsed: onToggleCollapsed ?? () {},
    onToolSelected: onToolSelected ?? (_) {},
    onBrushPressed: onBrushPressed ?? () {},
    onSizeChanged: onSizeChanged ?? (_) {},
    onFlowChanged: onFlowChanged ?? (_) {},
    onColorPressed: onColorPressed ?? () {},
    onUndo: onUndo ?? () {},
    onRedo: onRedo ?? () {},
    onLayersPressed: onLayersPressed ?? () {},
    onMenuPressed: onMenuPressed ?? () {},
    onDockChanged: onDockChanged,
  );
}

Future<void> _pumpBench(
  WidgetTester tester,
  Widget bench, {
  Size mediaSize = const Size(954, 1696),
}) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: mediaSize, devicePixelRatio: 1),
      child: PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(alignment: Alignment.topLeft, child: bench),
        ),
      ),
    ),
  );
}
