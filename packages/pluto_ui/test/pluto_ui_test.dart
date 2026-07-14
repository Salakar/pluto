import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  testWidgets('PaperTheme tokens can style a widget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: const Padding(
          padding: EdgeInsets.all(PaperTheme.space16),
          child: Text('Pluto'),
        ),
      ),
    );

    expect(find.text('Pluto'), findsOneWidget);
  });

  testWidgets('status bar distinguishes truthful network and power states', (
    WidgetTester tester,
  ) async {
    Future<void> pump(StatusSnapshot snapshot) {
      return tester.pumpWidget(
        PaperTheme(
          data: const PaperThemeData(isColorPanel: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: StatusBar(snapshot: snapshot),
          ),
        ),
      );
    }

    final DateTime time = DateTime.utc(2026, 7, 10, 14, 32);
    await pump(
      StatusSnapshot(
        time: time,
        battery: const StatusBattery(levelPercent: 73),
        penBattery: const StatusPenBattery(levelPercent: 81),
        isWifiEnabled: false,
        frontlightRaw: 1024,
        frontlightMaxRaw: 2048,
      ),
    );
    expect(find.text('14:32'), findsOneWidget);
    expect(find.text('73%'), findsOneWidget);
    expect(find.text('81%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.bySemanticsLabel('Wi-Fi off'), findsOneWidget);
    expect(find.text('USB'), findsNothing);
    expect(find.bySemanticsLabel('Battery charging'), findsNothing);

    await pump(
      StatusSnapshot(
        time: time,
        battery: const StatusBattery(levelPercent: 73),
        isWifiEnabled: true,
      ),
    );
    expect(find.bySemanticsLabel('Wi-Fi disconnected'), findsOneWidget);

    await pump(
      StatusSnapshot(
        time: time,
        battery: const StatusBattery(levelPercent: 73, isCharging: true),
        wifi: const StatusWifi(ssid: 'HomeNet', signalPercent: 82),
        isUsbTethered: true,
      ),
    );
    expect(
      find.bySemanticsLabel('Wi-Fi connected to HomeNet, 82% signal'),
      findsOneWidget,
    );
    expect(find.text('USB'), findsOneWidget);
    expect(find.bySemanticsLabel('Battery charging'), findsOneWidget);
  });
}
