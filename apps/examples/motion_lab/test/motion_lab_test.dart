import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_motion_lab_example/main.dart';

void main() {
  testWidgets('motion lab builds and animation ticks', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MotionLabApp());

    expect(find.text('Motion Lab'), findsOneWidget);
    final int before = _frameCount(tester);

    await tester.pump(const Duration(milliseconds: 250));

    expect(_frameCount(tester), greaterThan(before));
  });
}

int _frameCount(WidgetTester tester) {
  final Text readout = tester.widget<Text>(find.byKey(motionFrameReadoutKey));
  final String text = readout.data ?? '';
  final RegExpMatch? match = RegExp(r'Frames (\d+)').firstMatch(text);
  return int.parse(match!.group(1)!);
}
