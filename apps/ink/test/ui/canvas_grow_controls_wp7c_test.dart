import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/engine/canvas_ops.dart';
import 'package:paper_ink/src/ui/canvas_grow_controls.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  testWidgets('nine-grid selection reaches the grow action', (
    WidgetTester tester,
  ) async {
    var selected = CanvasResizeAnchor.center;
    final List<CanvasResizeAnchor> growRequests = <CanvasResizeAnchor>[];
    await _pumpControls(
      tester,
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return InkCanvasGrowControls(
            selectedAnchor: selected,
            onAnchorSelected: (CanvasResizeAnchor anchor) {
              setState(() => selected = anchor);
            },
            onGrow: growRequests.add,
          );
        },
      ),
    );

    for (final CanvasResizeAnchor anchor in CanvasResizeAnchor.values) {
      expect(
        find.byKey(ValueKey<String>('canvas-anchor-${anchor.name}')),
        findsOneWidget,
      );
    }
    expect(find.text('• center'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-anchor-bottomRight')),
    );
    await tester.pump(const Duration(milliseconds: 81));

    expect(selected, CanvasResizeAnchor.bottomRight);
    expect(find.text('• bottom right'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-grow-125')));
    await tester.pump(const Duration(milliseconds: 81));

    expect(growRequests, <CanvasResizeAnchor>[CanvasResizeAnchor.bottomRight]);
  });
}

Future<void> _pumpControls(WidgetTester tester, Widget controls) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(954, 1696)),
      child: PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 400, child: controls)),
        ),
      ),
    ),
  );
}
