import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/model/tool_state.dart';

void main() {
  group('WP7 sixteen-brush lookup', () {
    test('drawing catalog has the binding order and no eraser slot', () {
      expect(
        drawingBrushes.map((BrushSpec brush) => brush.id),
        _drawingLookups.map(((String, BrushSpec) pair) => pair.$1),
      );
      expect(drawingBrushes, hasLength(16));
      expect(drawingBrushesById, hasLength(16));
      expect(drawingBrushesById, isNot(contains('eraserpixel')));
    });

    for (var index = 0; index < _drawingLookups.length; index += 1) {
      final (String id, BrushSpec expected) = _drawingLookups[index];
      test('$id resolves to its canonical catalog object', () {
        expect(drawingBrushes[index], same(expected));
        expect(drawingBrushesById[id], same(expected));
        expect(brushById(id), same(expected));
        expect(expected.id, id);
        expect(
          expected.sizeDefault,
          inInclusiveRange(expected.sizeMin, expected.sizeMax),
        );
      });
    }

    test('pixel eraser remains available only through complete lookup', () {
      expect(brushesById, hasLength(17));
      expect(brushById('eraserpixel'), same(eraserPixelBrush));
      expect(drawingBrushesById['eraserpixel'], isNull);
    });

    test('complete lookup rejects unknown, blank, and case-drifted ids', () {
      for (final String id in <String>['missing', '', 'FineLiner']) {
        expect(() => brushById(id), throwsArgumentError, reason: id);
      }
    });
  });

  group('WP7 per-brush bench persistence', () {
    test('defaults expose current size and full flow', () {
      final ToolState state = ToolState();

      expect(state.size, 4);
      expect(state.sizeForBrush('fineliner', fallback: 99), 4);
      expect(state.sizeForBrush('technical', fallback: 2), 2);
      expect(state.flow, 1);
      expect(state.flowForBrush('technical'), 1);
    });

    test('size change is stored under the current stable brush id', () {
      final ToolState state = ToolState();
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.setSize(7.5);

      expect(state.size, 7.5);
      expect(state.presets['wp7Size:fineliner'], 7.5);
      expect(state.persistentRevision, 1);
      expect(notifications, 1);
    });

    test('switching brushes restores each last-used size', () {
      final ToolState state = ToolState();
      state.setSize(7);

      state.selectBrush(
        'technical',
        size: state.sizeForBrush(
          'technical',
          fallback: technicalBrush.sizeDefault,
        ),
      );
      expect(state.size, technicalBrush.sizeDefault);
      state.setSize(2.5);

      state.selectBrush(
        'fineliner',
        size: state.sizeForBrush(
          'fineliner',
          fallback: finelinerBrush.sizeDefault,
        ),
      );
      expect(state.size, 7);

      state.selectBrush(
        'technical',
        size: state.sizeForBrush(
          'technical',
          fallback: technicalBrush.sizeDefault,
        ),
      );
      expect(state.size, 2.5);
    });

    test('flow remains independent for every selected brush', () {
      final ToolState state = ToolState();
      state.setFlow(0.25);
      state.selectBrush('technical', size: technicalBrush.sizeDefault);
      state.setFlow(0.75);

      expect(state.flow, 0.75);
      expect(state.flowForBrush('fineliner'), 0.25);
      expect(state.flowForBrush('technical'), 0.75);

      state.selectBrush('fineliner', size: finelinerBrush.sizeDefault);
      expect(state.flow, 0.25);
    });

    test(
      'size and flow survive a manifest round trip for active and inactive brushes',
      () {
        final ToolState source = ToolState();
        source
          ..setSize(6)
          ..setFlow(0.4)
          ..selectBrush('technical', size: 2.25)
          ..setFlow(0.8);

        final InkToolState persisted = source.toPersisted();
        final ToolState restored = ToolState.fromPersisted(persisted);

        expect(restored.brushId, 'technical');
        expect(restored.size, 2.25);
        expect(restored.flow, 0.8);
        expect(restored.sizeForBrush('fineliner', fallback: 1), 6);
        expect(restored.flowForBrush('fineliner'), 0.4);
        expect(persisted.presets['wp7Size:technical'], 2.25);
        expect(persisted.presets['wp7Flow:technical'], 0.8);
      },
    );

    test('valid numeric persisted values decode as doubles', () {
      final ToolState state = ToolState.fromPersisted(
        InkToolState(
          toolId: 'draw',
          brushId: 'fineliner',
          color: '#000000',
          size: 4,
          presets: const <String, Object?>{
            'wp7Size:technical': 3,
            'wp7Flow:technical': 0.5,
          },
        ),
      );

      expect(state.sizeForBrush('technical', fallback: 8), 3.0);
      expect(state.flowForBrush('technical'), 0.5);
    });

    test('malformed persisted size and flow use safe call-site defaults', () {
      final ToolState state = ToolState(
        presets: const <String, Object?>{
          'wp7Size:technical': -3,
          'wp7Size:marker': 'large',
          'wp7Flow:technical': 2,
          'wp7Flow:marker': 'wet',
        },
      );

      expect(state.sizeForBrush('technical', fallback: 2), 2);
      expect(state.sizeForBrush('marker', fallback: 12), 12);
      expect(state.flowForBrush('technical'), 1);
      expect(state.flowForBrush('marker'), 1);
    });

    test('zero and one are valid flow endpoints', () {
      final ToolState state = ToolState();

      state.setFlow(0);
      expect(state.flow, 0);
      state.setFlow(1);
      expect(state.flow, 1);
      expect(state.persistentRevision, 2);
    });

    test('equivalent size, flow, and brush selections are no-ops', () {
      final ToolState state = ToolState();
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.setSize(4);
      state.setFlow(1);
      state.selectBrush('fineliner', size: 4);

      expect(state.persistentRevision, 0);
      expect(state.presets, isEmpty);
      expect(notifications, 0);
    });

    test('brush selection changes id and size in one notification', () {
      final ToolState state = ToolState();
      var notifications = 0;
      state.addListener(() => notifications += 1);

      state.selectBrush('marker', size: markerBrush.sizeDefault);

      expect(state.brushId, 'marker');
      expect(state.size, markerBrush.sizeDefault);
      expect(state.presets['wp7Size:fineliner'], 4);
      expect(state.presets['wp7Size:marker'], markerBrush.sizeDefault);
      expect(state.persistentRevision, 1);
      expect(notifications, 1);
    });

    test('unrelated preset payloads survive bench size and flow changes', () {
      final ToolState state = ToolState(
        presets: const <String, Object?>{
          'wp7Options': <String, Object?>{'grain': 2},
          'futureBrushData': <Object?>[true, 'keep'],
        },
      );

      state
        ..setSize(5)
        ..setFlow(0.6);

      expect(state.presets['wp7Options'], <String, Object?>{'grain': 2});
      expect(state.presets['futureBrushData'], <Object?>[true, 'keep']);
      expect(state.toPersisted().presets, containsPair('wp7Size:fineliner', 5));
      expect(
        state.toPersisted().presets,
        containsPair('wp7Flow:fineliner', 0.6),
      );
    });

    test('forward-compatible nonempty brush ids still round trip', () {
      final ToolState state = ToolState();

      state.selectBrush('future-brush', size: 11);
      final ToolState restored = ToolState.fromPersisted(state.toPersisted());

      expect(restored.brushId, 'future-brush');
      expect(restored.size, 11);
    });
  });

  group('WP7 bench value validation', () {
    test('constructor rejects nonpositive and nonfinite sizes', () {
      for (final double value in <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => ToolState(size: value), throwsArgumentError);
      }
    });

    test('setSize rejects nonpositive and nonfinite values atomically', () {
      final ToolState state = ToolState();

      for (final double value in <double>[
        0,
        -0.01,
        double.nan,
        double.infinity,
      ]) {
        expect(() => state.setSize(value), throwsArgumentError);
      }

      expect(state.size, 4);
      expect(state.presets, isEmpty);
      expect(state.persistentRevision, 0);
    });

    test('selectBrush rejects invalid optional sizes before mutation', () {
      final ToolState state = ToolState();

      for (final double value in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () => state.selectBrush('technical', size: value),
          throwsArgumentError,
        );
      }

      expect(state.brushId, 'fineliner');
      expect(state.size, 4);
      expect(state.persistentRevision, 0);
    });

    test('size lookup rejects an invalid fallback even for another brush', () {
      final ToolState state = ToolState();

      for (final double value in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () => state.sizeForBrush('technical', fallback: value),
          throwsArgumentError,
        );
      }
    });

    test('setFlow rejects values outside the normalized finite range', () {
      final ToolState state = ToolState();

      for (final double value in <double>[
        -0.01,
        1.01,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => state.setFlow(value), throwsRangeError);
      }

      expect(state.flow, 1);
      expect(state.presets, isEmpty);
      expect(state.persistentRevision, 0);
    });

    test('blank brush ids are rejected by every bench-facing API', () {
      final ToolState state = ToolState();

      expect(() => state.selectBrush(''), throwsArgumentError);
      expect(() => state.sizeForBrush('', fallback: 4), throwsArgumentError);
      expect(() => state.flowForBrush(''), throwsArgumentError);
    });

    test('preset maps reject nonfinite JSON values', () {
      expect(
        () => ToolState(
          presets: <String, Object?>{'wp7Flow:fineliner': double.nan},
        ),
        throwsArgumentError,
      );
      expect(
        () => ToolState(
          presets: <String, Object?>{'wp7Size:fineliner': double.infinity},
        ),
        throwsArgumentError,
      );
    });

    test('published preset state is deeply immutable', () {
      final ToolState state = ToolState(
        presets: const <String, Object?>{
          'wp7Options': <String, Object?>{
            'grain': <Object?>[1, 2],
          },
        },
      );

      expect(() => state.presets['another'] = 3, throwsUnsupportedError);
      final Map<String, Object?> options =
          state.presets['wp7Options']! as Map<String, Object?>;
      expect(() => options['grain'] = 4, throwsUnsupportedError);
      final List<Object?> grain = options['grain']! as List<Object?>;
      expect(() => grain.add(3), throwsUnsupportedError);
    });
  });
}

const List<(String, BrushSpec)> _drawingLookups = <(String, BrushSpec)>[
  ('fineliner', finelinerBrush),
  ('technical', technicalBrush),
  ('ballpoint', ballpointBrush),
  ('fountain', fountainBrush),
  ('calligraphy', calligraphyBrush),
  ('brushpen', brushpenBrush),
  ('pencilhb', pencilHbBrush),
  ('pencil6b', pencil6bBrush),
  ('mechanical', mechanicalBrush),
  ('charcoal', charcoalBrush),
  ('marker', markerBrush),
  ('highlighter', highlighterBrush),
  ('spray', sprayBrush),
  ('stipple', stippleBrush),
  ('hatcher', hatcherBrush),
  ('toneshader', toneshaderBrush),
];
