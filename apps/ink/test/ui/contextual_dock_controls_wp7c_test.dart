import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/selection_tool.dart';
import 'package:paper_ink/src/tools/shape_tool.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  group('WP7c contextual dock controls', () {
    test('selection and shape docks expose their value controls', () {
      expect(
        contextualDockActionsFor(ContextualDockMode.erase),
        <ContextualDockAction>[
          ContextualDockAction.eraserPixel,
          ContextualDockAction.eraserStroke,
          ContextualDockAction.eraserLasso,
        ],
      );
      expect(
        contextualDockActionsFor(ContextualDockMode.selection),
        containsAllInOrder(<ContextualDockAction>[
          ContextualDockAction.selectWand,
          ContextualDockAction.selectionTolerance,
          ContextualDockAction.selectionGapClose,
        ]),
      );
      expect(
        contextualDockActionsFor(ContextualDockMode.shape),
        containsAllInOrder(<ContextualDockAction>[
          ContextualDockAction.shapePolygon,
          ContextualDockAction.polygonSides,
        ]),
      );
    });

    test('selection tolerance follows the complete supported cycle', () {
      _expectCycle(selectionToleranceDockValues, nextSelectionTolerance);
      expect(nextSelectionTolerance(9), 16);
    });

    test('selection gap-close follows the complete supported cycle', () {
      _expectCycle(selectionGapCloseDockValues, nextSelectionGapClose);
      expect(nextSelectionGapClose(3), 4);
    });

    test('polygon sides follow the complete supported cycle', () {
      _expectCycle(polygonSidesDockValues, nextPolygonSides);
      expect(nextPolygonSides(7), 8);
    });

    test('cycled wand values reach the next worker request', () {
      final SelectionToolController controller = SelectionToolController()
        ..setOptions(
          SelectionOptions(
            mode: SelectionMode.wand,
            wandTolerance: nextSelectionTolerance(16),
            wandGapClose: nextSelectionGapClose(0),
          ),
        );

      final WandSelectionRequest request = controller.requestWand(
        const Offset(4, 5),
        layerId: 'ink',
      );

      expect(request.tolerance, 32);
      expect(request.gapClose, 1);
    });

    test('cycled polygon count reaches fitted shape geometry', () {
      final ShapeGeometry geometry = fitShape(
        start: Offset.zero,
        end: const Offset(20, 20),
        options: ShapeOptions(
          kind: ShapeKind.polygon,
          polygonSides: nextPolygonSides(6),
        ),
      );

      expect((geometry as PolygonShapeGeometry).vertices, hasLength(8));
    });

    test('value labels report selection, fill, and polygon state', () {
      expect(
        selectionDockValueLabels(tolerance: 32, gapClose: 2),
        <ContextualDockAction, String>{
          ContextualDockAction.selectionTolerance: 'tol 32',
          ContextualDockAction.selectionGapClose: 'gap 2',
        },
      );
      expect(
        fillDockValueLabels(tolerance: 48, gapClose: 4, grow: 3),
        <ContextualDockAction, String>{
          ContextualDockAction.fillTolerance: 'tol 48',
          ContextualDockAction.fillGapClose: 'gap 4',
          ContextualDockAction.fillGrow: 'grow +3',
          ContextualDockAction.fillContract: 'contract −0',
        },
      );
      expect(
        fillDockValueLabels(tolerance: 8, gapClose: 1, grow: -2),
        <ContextualDockAction, String>{
          ContextualDockAction.fillTolerance: 'tol 8',
          ContextualDockAction.fillGapClose: 'gap 1',
          ContextualDockAction.fillGrow: 'grow +0',
          ContextualDockAction.fillContract: 'contract −2',
        },
      );
      expect(
        shapeDockValueLabels(polygonSides: 6),
        <ContextualDockAction, String>{
          ContextualDockAction.shapePolygon: 'polygon 6',
          ContextualDockAction.polygonSides: 'sides 6',
        },
      );
    });

    testWidgets('renders and dispatches a current-value label', (
      WidgetTester tester,
    ) async {
      final List<ContextualDockAction> dispatched = <ContextualDockAction>[];
      await _pumpDock(
        tester,
        ContextualDock(
          mode: ContextualDockMode.selection,
          actionLabels: selectionDockValueLabels(tolerance: 32, gapClose: 2),
          onAction: dispatched.add,
        ),
      );

      expect(find.text('tol 32'), findsOneWidget);
      expect(find.text('gap 2'), findsOneWidget);
      expect(find.text('tol 0–64'), findsNothing);
      await tester.tap(find.text('tol 32'));
      await tester.pump();

      expect(dispatched, <ContextualDockAction>[
        ContextualDockAction.selectionTolerance,
      ]);
    });

    testWidgets('selected eraser mode is exposed to semantics', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await _pumpDock(
          tester,
          ContextualDock(
            mode: ContextualDockMode.erase,
            selectedActions: const <ContextualDockAction>{
              ContextualDockAction.eraserStroke,
            },
            onAction: (_) {},
          ),
        );

        expect(
          tester.getSemantics(find.text('stroke')).flagsCollection.isSelected,
          ui.Tristate.isTrue,
        );
      } finally {
        semantics.dispose();
      }
    });
  });
}

void _expectCycle(List<int> values, int Function(int) nextValue) {
  for (var index = 0; index < values.length; index += 1) {
    expect(nextValue(values[index]), values[(index + 1) % values.length]);
  }
}

Future<void> _pumpDock(WidgetTester tester, Widget dock) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(954, 1696), devicePixelRatio: 1),
      child: PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(alignment: Alignment.bottomCenter, child: dock),
        ),
      ),
    ),
  );
}
