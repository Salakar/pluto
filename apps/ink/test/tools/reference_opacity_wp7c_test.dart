import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/tools/reference_tool.dart';

void main() {
  group('WP7c reference-layer opacity', () {
    test('defaults to half opacity and accepts both endpoints', () {
      expect(_layer().opacity, referenceLayerOpacity);
      expect(_layer(opacity: 0).opacity, 0);
      expect(_layer(opacity: 1).opacity, 1);
    });

    test('rejects non-finite and out-of-range values', () {
      for (final double opacity in <double>[
        -0.01,
        1.01,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => _layer(opacity: opacity),
          throwsArgumentError,
          reason: '$opacity must not enter the reference stack',
        );
      }
    });

    test('copyWith preserves opacity unless explicitly replaced', () {
      final ReferenceLayer layer = _layer(opacity: 0.25);

      expect(layer.copyWith(isVisible: false).opacity, 0.25);
      expect(
        layer
            .copyWith(
              placement: ReferencePlacement(topLeft: const Offset(10, 20)),
            )
            .opacity,
        0.25,
      );
      expect(layer.copyWith(opacity: 0.75).opacity, 0.75);
      expect(layer.opacity, 0.25);
    });

    test('controller seeds and updates one layer independently', () {
      final ReferenceToolController controller = ReferenceToolController();
      final ReferenceAddCommand first = controller.addReference(
        layerId: 'R1',
        image: _image('first.png'),
        viewportCenter: Offset.zero,
        opacity: 0.2,
      );
      controller.commitPlacement();
      controller.addReference(
        layerId: 'R2',
        image: _image('second.png'),
        viewportCenter: Offset.zero,
        opacity: 0.8,
      );
      controller.commitPlacement();

      expect(first.layer.opacity, 0.2);
      controller.setOpacity('R1', 0.65);

      expect(
        controller.layers.map((ReferenceLayer layer) => layer.opacity),
        <double>[0.65, 0.8],
      );
      expect(controller.layers.first.isLocked, isTrue);
    });

    test('invalid controller updates leave the layer unchanged', () {
      final ReferenceToolController controller = ReferenceToolController();
      controller.addReference(
        layerId: 'R1',
        image: _image('reference.png'),
        viewportCenter: Offset.zero,
        opacity: 0.4,
      );

      expect(
        () => controller.setOpacity('R1', double.nan),
        throwsArgumentError,
      );
      expect(controller.layers.single.opacity, 0.4);
      expect(() => controller.setOpacity('missing', 0.5), throwsArgumentError);
      expect(controller.layers.single.opacity, 0.4);
    });
  });
}

ReferenceLayer _layer({double opacity = referenceLayerOpacity}) {
  return ReferenceLayer(
    id: 'R1',
    image: _image('reference.png'),
    placement: ReferencePlacement(topLeft: Offset.zero),
    opacity: opacity,
  );
}

ReferenceImageDescriptor _image(String sourceId) {
  return ReferenceImageDescriptor(
    sourceId: sourceId,
    pixelWidth: 100,
    pixelHeight: 50,
  );
}
