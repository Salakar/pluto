import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/models.dart';
import 'package:paper_codex/src/paper/theme.dart';
import 'package:paper_codex/src/ui/ink_canvas.dart';

void main() {
  testWidgets('palm touch cannot ink while stylus still draws', (tester) async {
    final strokes = <InkStroke>[];
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 300)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: PaperCodexTheme(
            ink: const PaperInk.color(),
            child: SizedBox(
              width: 400,
              height: 300,
              child: InkCanvas(
                strokes: const <InkStroke>[],
                onStroke: strokes.add,
              ),
            ),
          ),
        ),
      ),
    );

    final touch = TestPointer(1, PointerDeviceKind.touch);
    await tester.sendEventToBinding(touch.down(const Offset(80, 90)));
    await tester.sendEventToBinding(touch.move(const Offset(140, 130)));
    await tester.sendEventToBinding(touch.up());
    await tester.pump();
    expect(strokes, isEmpty);

    final stylus = TestPointer(2, PointerDeviceKind.stylus);
    await tester.sendEventToBinding(stylus.down(const Offset(80, 90)));
    await tester.sendEventToBinding(stylus.move(const Offset(140, 130)));
    await tester.sendEventToBinding(stylus.up());
    await tester.pump();
    expect(strokes, hasLength(1));
    expect(strokes.single.points, hasLength(2));
  });
}
