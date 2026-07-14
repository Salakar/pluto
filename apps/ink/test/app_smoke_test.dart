import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/main.dart';
import 'package:paper_ink/src/probe/isolate_probe.dart';
import 'package:paper_ink/src/probe/probe_page.dart';
import 'package:paper_ink/src/services.dart';
import 'package:pluto_pen/pluto_pen.dart';

void main() {
  testWidgets('placeholder InkApp shows its wordmark and exit action', (
    WidgetTester tester,
  ) async {
    final Completer<InkServices> services = Completer<InkServices>();
    await tester.pumpWidget(InkApp(servicesLoader: () => services.future));

    expect(find.text('Ink'), findsOneWidget);
    expect(find.text('exit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('probe page builds every probe control with fake services', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      InkProbeApp(
        isolateRunner: _FakeIsolateProbeRunner(),
        penEvents: const _FakePenEvents(),
      ),
    );

    for (final String label in <String>[
      'P-rate',
      'P-frame',
      'P-upload',
      'P-isolate',
      'P-caps',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byKey(const ValueKey<String>('probe-log')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('P-isolate uses the injected runner and writes its result', (
    WidgetTester tester,
  ) async {
    final _FakeIsolateProbeRunner runner = _FakeIsolateProbeRunner();
    await tester.pumpWidget(
      InkProbeApp(isolateRunner: runner, penEvents: const _FakePenEvents()),
    );

    await tester.tap(find.text('P-isolate'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(runner.calls, 1);
    expect(find.textContaining('P-isolate result'), findsOneWidget);
    expect(find.textContaining('roundTripMs p50=2.00'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _FakeIsolateProbeRunner implements IsolateProbeRunner {
  var calls = 0;

  @override
  Future<IsolateProbeResult> run() async {
    calls++;
    return IsolateProbeResult(
      roundTripMilliseconds: <double>[1, 2, 3],
      blendMilliseconds: <double>[0.5, 0.75, 1],
    );
  }
}

final class _FakePenEvents implements PenEvents {
  const _FakePenEvents();

  @override
  Stream<PenEvent> get events => const Stream<PenEvent>.empty();
}
