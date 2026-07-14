import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/ui/canvas_view.dart';
import 'package:paper_ink/src/ui/dock/contextual_dock.dart';
import 'package:paper_ink/src/ui/editor_page.dart';

void main() {
  const Map<ContextualDockAction, CanvasToolCommand> expectedCommands =
      <ContextualDockAction, CanvasToolCommand>{
        ContextualDockAction.move: CanvasToolCommand.move,
        ContextualDockAction.transform: CanvasToolCommand.transform,
        ContextualDockAction.duplicate: CanvasToolCommand.duplicate,
        ContextualDockAction.flipHorizontal: CanvasToolCommand.flipHorizontal,
        ContextualDockAction.flipVertical: CanvasToolCommand.flipVertical,
        ContextualDockAction.cut: CanvasToolCommand.cut,
        ContextualDockAction.copy: CanvasToolCommand.copy,
        ContextualDockAction.paste: CanvasToolCommand.paste,
        ContextualDockAction.clear: CanvasToolCommand.clear,
        ContextualDockAction.fill: CanvasToolCommand.fill,
        ContextualDockAction.toNewLayer: CanvasToolCommand.toNewLayer,
        ContextualDockAction.perfect: CanvasToolCommand.perfect,
        ContextualDockAction.rotateDetent: CanvasToolCommand.rotateDetent,
        ContextualDockAction.reset: CanvasToolCommand.reset,
        ContextualDockAction.apply: CanvasToolCommand.apply,
        ContextualDockAction.textSize: CanvasToolCommand.textSize,
        ContextualDockAction.textWeight: CanvasToolCommand.textWeight,
        ContextualDockAction.textResize: CanvasToolCommand.textResize,
        ContextualDockAction.done: CanvasToolCommand.done,
        ContextualDockAction.dismiss: CanvasToolCommand.dismiss,
      };
  const Set<ContextualDockAction> expectedOptions = <ContextualDockAction>{
    ContextualDockAction.eraserPixel,
    ContextualDockAction.eraserStroke,
    ContextualDockAction.eraserLasso,
    ContextualDockAction.selectRect,
    ContextualDockAction.selectLasso,
    ContextualDockAction.selectWand,
    ContextualDockAction.selectAdd,
    ContextualDockAction.selectSubtract,
    ContextualDockAction.selectionTolerance,
    ContextualDockAction.selectionGapClose,
    ContextualDockAction.aspect,
    ContextualDockAction.fillTolerance,
    ContextualDockAction.fillGapClose,
    ContextualDockAction.fillGrow,
    ContextualDockAction.fillContract,
    ContextualDockAction.fillSampleActive,
    ContextualDockAction.fillSampleComposite,
    ContextualDockAction.fillSolid,
    ContextualDockAction.fillHatch,
    ContextualDockAction.fillDotScreen,
    ContextualDockAction.fillBayer4,
    ContextualDockAction.fillBayer8,
    ContextualDockAction.shapeLine,
    ContextualDockAction.shapeArrow,
    ContextualDockAction.shapeRect,
    ContextualDockAction.shapeEllipse,
    ContextualDockAction.shapePolygon,
    ContextualDockAction.polygonSides,
    ContextualDockAction.fromCenter,
    ContextualDockAction.textInter,
    ContextualDockAction.textMono,
    ContextualDockAction.straightedge,
    ContextualDockAction.straightedgeOff,
    ContextualDockAction.gridDots,
    ContextualDockAction.gridLines,
    ContextualDockAction.grid8,
    ContextualDockAction.grid16,
    ContextualDockAction.grid32,
    ContextualDockAction.grid64,
    ContextualDockAction.gridOff,
    ContextualDockAction.symmetryVertical,
    ContextualDockAction.symmetryHorizontal,
    ContextualDockAction.symmetryQuad,
    ContextualDockAction.symmetryOff,
  };

  group('WP7b contextual dock command routing', () {
    test('maps every command-bearing action to its canvas command', () {
      for (final MapEntry<ContextualDockAction, CanvasToolCommand> entry
          in expectedCommands.entries) {
        expect(
          inkCanvasToolCommandForDockAction(entry.key),
          entry.value,
          reason: '${entry.key.name} must reach ${entry.value.name}',
        );
      }
    });

    test('classifies every dock action as exactly command or option', () {
      expect(
        expectedCommands.keys.toSet().intersection(expectedOptions),
        isEmpty,
      );
      expect(<ContextualDockAction>{
        ...expectedCommands.keys,
        ...expectedOptions,
      }, unorderedEquals(ContextualDockAction.values));

      for (final ContextualDockAction action in expectedOptions) {
        expect(
          inkCanvasToolCommandForDockAction(action),
          isNull,
          reason: '${action.name} must remain an option change',
        );
      }
    });

    test(
      'CanvasViewHandle dispatches commands through the injected seam',
      () async {
        final List<CanvasToolCommand> dispatched = <CanvasToolCommand>[];
        final CanvasViewHandle handle = CanvasViewHandle(
          commandDispatcher: (CanvasToolCommand command) async {
            dispatched.add(command);
          },
        );

        for (final CanvasToolCommand command in CanvasToolCommand.values) {
          await handle.runToolCommand(command);
        }

        expect(dispatched, orderedEquals(CanvasToolCommand.values));
      },
    );
  });
}
