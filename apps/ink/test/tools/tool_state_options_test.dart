import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/model/tool_state.dart';

void main() {
  group('WP5 typed tool options', () {
    test('defaults match the binding ranges and uniform transform policy', () {
      const Wp5ToolOptions options = Wp5ToolOptions();

      expect(options.selectionGeometry, SelectionGeometry.rectangle);
      expect(options.selectionTolerance, inInclusiveRange(0, 64));
      expect(options.selectionGapClose, inInclusiveRange(0, 4));
      expect(options.transformAspect, TransformAspect.uniform);
      expect(options.fillGrow, 0);
      expect(options.eyedropperRadiusDpx, 5);
      expect(options.paletteSnapDeltaE, 10);
    });

    test('one atomic option change advances the persistent revision', () {
      final ToolState state = ToolState();
      final Wp5ToolOptions changed = state.wp5Options.copyWith(
        selectionGeometry: SelectionGeometry.wand,
        selectionTolerance: 42,
      );

      state.setWp5Options(changed);

      expect(state.wp5Options, changed);
      expect(state.persistentRevision, 1);
    });

    test('equivalent option replacement is a notifier no-op', () {
      final ToolState state = ToolState();
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.setWp5Options(const Wp5ToolOptions());

      expect(notifications, 0);
      expect(state.persistentRevision, 0);
    });

    test('typed values round trip in the forward-compatible field', () {
      final ToolState source = ToolState(
        wp5Options: const Wp5ToolOptions(
          selectionGeometry: SelectionGeometry.lasso,
          selectionCombine: SelectionCombine.subtract,
          fillStyle: FillStyle.dotScreen,
          dotScreenDensity: DotScreenDensity.bayer8,
          shapeType: ShapeType.polygon,
          polygonSides: 9,
          textFont: InkTextFont.jetBrainsMono,
          symmetryMode: InkSymmetryMode.quad,
        ),
      );

      final ToolState restored = ToolState.fromPersisted(source.toPersisted());

      expect(restored.wp5Options, source.wp5Options);
      expect(restored.presets, isEmpty);
    });

    test(
      'unknown future option names fall back without losing the payload',
      () {
        final InkToolState persisted = InkToolState(
          toolId: 'guides',
          brushId: 'fineliner',
          color: '#000000',
          size: 4,
          unknownFields: const <String, Object?>{
            'future': 7,
            'wp5Options': <String, Object?>{
              'gridStyle': 'futureGrid',
              'symmetryMode': 'futureMirror',
            },
          },
        );

        final ToolState state = ToolState.fromPersisted(persisted);

        expect(state.wp5Options.gridStyle, GuideGridStyle.off);
        expect(state.wp5Options.symmetryMode, InkSymmetryMode.off);
        expect(state.toPersisted().unknownFields['future'], 7);
      },
    );

    test('out-of-range persisted numbers use safe defaults', () {
      final InkToolState persisted = InkToolState(
        toolId: 'fill',
        brushId: 'fineliner',
        color: '#000000',
        size: 4,
        unknownFields: const <String, Object?>{
          'wp5Options': <String, Object?>{
            'fillTolerance': 1000,
            'fillGapClose': -2,
            'fillGrow': 9,
            'textSize': 999,
            'referenceOpacity': 4,
          },
        },
      );

      final Wp5ToolOptions options = ToolState.fromPersisted(
        persisted,
      ).wp5Options;

      expect(options.fillTolerance, 16);
      expect(options.fillGapClose, 0);
      expect(options.fillGrow, 0);
      expect(options.textSize, 32);
      expect(options.referenceOpacity, 0.5);
    });

    test('brush presets remain separate from interaction-tool options', () {
      final ToolState state = ToolState(
        presets: const <String, Object?>{
          'pencilhb': <String, Object?>{'grain': 0.5},
        },
      );
      state.setWp5Options(
        state.wp5Options.copyWith(
          straightedgeEnabled: true,
          gridStyle: GuideGridStyle.dots,
          gridSpacingDpx: 64,
        ),
      );

      final InkToolState persisted = state.toPersisted();

      expect(persisted.presets.keys, <String>['pencilhb']);
      expect(persisted.unknownFields, contains('wp5Options'));
    });
  });
}
