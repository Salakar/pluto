import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/reference_tool.dart';
import 'package:paper_ink/src/ui/reference_layer_opacity.dart';

void main() {
  testWidgets('reference layer opacity drives the production render boundary', (
    WidgetTester tester,
  ) async {
    final ReferenceLayer layer = _layer(opacity: 0.3);
    await tester.pumpWidget(
      ReferenceLayerOpacity(
        layer: layer,
        child: const SizedBox(key: ValueKey<String>('reference-image')),
      ),
    );

    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.3);
    expect(
      find.byKey(const ValueKey<String>('reference-image')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      ReferenceLayerOpacity(
        layer: layer.copyWith(opacity: 0.75),
        child: const SizedBox(key: ValueKey<String>('reference-image')),
      ),
    );

    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.75);
  });
}

ReferenceLayer _layer({required double opacity}) {
  return ReferenceLayer(
    id: 'R1',
    image: ReferenceImageDescriptor(
      sourceId: 'reference.png',
      pixelWidth: 100,
      pixelHeight: 50,
    ),
    placement: ReferencePlacement(topLeft: Offset.zero),
    opacity: opacity,
  );
}
