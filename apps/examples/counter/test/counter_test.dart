import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_counter_example/main.dart';

void main() {
  testWidgets('counter increments', (WidgetTester tester) async {
    await tester.pumpWidget(const CounterApp());

    expect(find.text('0'), findsOneWidget);
    await tester.tap(find.text('+'));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
  });
}
