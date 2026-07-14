import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/stroke_pipeline.dart';
import 'package:paper_ink/src/tools/eraser_tool.dart';

void main() {
  group('EraserModeState', () {
    test('stroke eraser uses the specified 14 logical-pixel cursor', () {
      expect(strokeEraserCursorLogicalDiameter, 14);
    });

    test('catalog exposes pixel, stroke, and lasso exactly', () {
      expect(EraserMode.values, <EraserMode>[
        EraserMode.pixel,
        EraserMode.stroke,
        EraserMode.lasso,
      ]);
    });

    test('defaults to pixel for the selected eraser tool', () {
      final EraserModeState state = EraserModeState();

      expect(state.lastSelectedMode, EraserMode.pixel);
      expect(
        state.modeForInput(eraserToolSelected: true, penFlipped: false),
        EraserMode.pixel,
      );
    });

    test('normal pen remains with another selected tool', () {
      final EraserModeState state = EraserModeState(
        initialMode: EraserMode.lasso,
      );

      expect(
        state.modeForInput(eraserToolSelected: false, penFlipped: false),
        isNull,
      );
    });

    test('flipped pen routes to the last selected mode', () {
      final EraserModeState state = EraserModeState();

      for (final EraserMode mode in EraserMode.values) {
        state.selectMode(mode);
        expect(state.lastSelectedMode, mode);
        expect(
          state.modeForInput(eraserToolSelected: false, penFlipped: true),
          mode,
        );
      }
    });

    test('persisted default seeds every supported initial mode', () {
      expect(eraserModeFromPreset('pixel'), EraserMode.pixel);
      expect(eraserModeFromPreset('stroke'), EraserMode.stroke);
      expect(eraserModeFromPreset('lasso'), EraserMode.lasso);
      expect(eraserModeFromPreset('future-mode'), EraserMode.pixel);
    });
  });

  group('StrokeKill and StrokeEraseBatchRequest', () {
    test('kill validates layer, sequence, and timestamp', () {
      expect(() => _kill(1, 0, layerId: '   '), throwsArgumentError);
      expect(() => _kill(0, 0), throwsArgumentError);
      expect(() => _kill(1, -1), throwsArgumentError);
    });

    test('request canonicalizes target order and duplicates', () {
      final StrokeEraseBatchRequest request = StrokeEraseBatchRequest(
        layerId: 'ink',
        targetSequences: <int>[9, 2, 9, 4],
        startedAt: const Duration(milliseconds: 10),
        endedAt: const Duration(milliseconds: 25),
      );

      expect(request.targetSequences, <int>[2, 4, 9]);
      expect(() => request.targetSequences.add(11), throwsUnsupportedError);
      expect(request.startedAt, const Duration(milliseconds: 10));
      expect(request.endedAt, const Duration(milliseconds: 25));
      expect(request.journalKind, JournalKind.erase);
    });

    test('request rejects empty targets, bad sequence, and reversed time', () {
      expect(
        () => StrokeEraseBatchRequest(
          layerId: 'ink',
          targetSequences: const <int>[],
          startedAt: Duration.zero,
          endedAt: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => StrokeEraseBatchRequest(
          layerId: 'ink',
          targetSequences: const <int>[-1],
          startedAt: Duration.zero,
          endedAt: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => StrokeEraseBatchRequest(
          layerId: 'ink',
          targetSequences: const <int>[1],
          startedAt: const Duration(milliseconds: 2),
          endedAt: const Duration(milliseconds: 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('StrokeKillBatcher', () {
    test('batches, de-duplicates, and sorts kills before 120 ms', () {
      final List<StrokeEraseBatchRequest> output = <StrokeEraseBatchRequest>[];
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: output.add);

      batcher.addKill(_kill(9, 0));
      batcher.addKill(_kill(2, 50));
      batcher.addKill(_kill(9, 119));

      expect(batcher.hasPendingBatch, isTrue);
      expect(batcher.pendingTargetCount, 2);
      expect(output, isEmpty);

      batcher.flush();

      expect(output, hasLength(1));
      expect(output.single.layerId, 'ink');
      expect(output.single.targetSequences, <int>[2, 9]);
      expect(output.single.startedAt, Duration.zero);
      expect(output.single.endedAt, const Duration(milliseconds: 119));
      expect(batcher.hasPendingBatch, isFalse);
    });

    test('kill at the exact 120 ms boundary starts a new batch', () {
      final List<StrokeEraseBatchRequest> output = <StrokeEraseBatchRequest>[];
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: output.add);

      batcher.addKill(_kill(7, 0));
      batcher.addKill(_kill(8, 120));

      expect(output, hasLength(1));
      expect(output.single.targetSequences, <int>[7]);
      expect(batcher.pendingTargetCount, 1);

      batcher.flush();
      expect(output, hasLength(2));
      expect(output.last.targetSequences, <int>[8]);
      expect(output.last.startedAt, const Duration(milliseconds: 120));
    });

    test('idle advancement flushes at, but not before, the boundary', () {
      final List<StrokeEraseBatchRequest> output = <StrokeEraseBatchRequest>[];
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: output.add)
        ..addKill(_kill(3, 20));

      batcher.flushThrough(const Duration(milliseconds: 139));
      expect(output, isEmpty);

      batcher.flushThrough(const Duration(milliseconds: 140));
      expect(output.single.targetSequences, <int>[3]);
      expect(batcher.hasPendingBatch, isFalse);
    });

    test('switching active layers closes the layer-local command', () {
      final List<StrokeEraseBatchRequest> output = <StrokeEraseBatchRequest>[];
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: output.add);

      batcher.addKill(_kill(2, 10, layerId: 'foreground'));
      batcher.addKill(_kill(5, 11, layerId: 'notes'));

      expect(output.single.layerId, 'foreground');
      expect(output.single.targetSequences, <int>[2]);
      batcher.flush();
      expect(output.last.layerId, 'notes');
      expect(output.last.targetSequences, <int>[5]);
    });

    test('rejects non-monotonic hit and clock input', () {
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: (_) {})
        ..addKill(_kill(1, 20));

      expect(() => batcher.addKill(_kill(2, 19)), throwsArgumentError);
      expect(
        () => batcher.flushThrough(const Duration(milliseconds: 19)),
        throwsArgumentError,
      );
      expect(batcher.pendingTargetCount, 1);
    });

    test('rejects non-positive windows', () {
      expect(
        () => StrokeKillBatcher(onBatch: (_) {}, batchWindow: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => StrokeKillBatcher(
          onBatch: (_) {},
          batchWindow: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('same kill stream produces byte-for-byte-equivalent fields', () {
      List<String> run() {
        final List<String> result = <String>[];
        final StrokeKillBatcher batcher = StrokeKillBatcher(
          onBatch: (StrokeEraseBatchRequest request) {
            result.add(
              '${request.layerId}|${request.targetSequences.join(',')}|'
              '${request.startedAt.inMicroseconds}|'
              '${request.endedAt.inMicroseconds}',
            );
          },
        );
        for (final StrokeKill kill in <StrokeKill>[
          _kill(11, 0),
          _kill(4, 8),
          _kill(11, 30),
          _kill(6, 120),
        ]) {
          batcher.addKill(kill);
        }
        batcher.flush();
        return result;
      }

      expect(run(), run());
    });

    test('discard cancels a gesture without publishing it', () {
      final List<StrokeEraseBatchRequest> output = <StrokeEraseBatchRequest>[];
      final StrokeKillBatcher batcher = StrokeKillBatcher(onBatch: output.add)
        ..addKill(_kill(3, 0))
        ..discard()
        ..flush();

      expect(output, isEmpty);
      expect(batcher.hasPendingBatch, isFalse);
    });
  });

  group('LassoClearRequest', () {
    test('normalizes explicit closure and computes document bounds', () {
      final LassoPoint first = LassoPoint(x: -2, y: 4);
      final LassoClearRequest request = LassoClearRequest(
        layerId: 'ink',
        vertices: <LassoPoint>[
          first,
          LassoPoint(x: 8, y: 1),
          LassoPoint(x: 6, y: 12),
          first,
        ],
        requestedAt: const Duration(milliseconds: 90),
      );

      expect(request.vertices, hasLength(3));
      expect(request.closedVertices, hasLength(4));
      expect(request.closedVertices.first, same(first));
      expect(request.closedVertices.last, same(first));
      expect(
        (
          request.bounds.left,
          request.bounds.top,
          request.bounds.right,
          request.bounds.bottom,
        ),
        (-2, 1, 8, 12),
      );
      expect(request.bounds.width, 10);
      expect(request.bounds.height, 11);
      expect(request.journalKind, JournalKind.erase);
    });

    test('geometry collections are immutable', () {
      final LassoClearRequest request = _triangle();

      expect(
        () => request.vertices.add(LassoPoint(x: 3, y: 3)),
        throwsUnsupportedError,
      );
      expect(() => request.closedVertices.removeLast(), throwsUnsupportedError);
    });

    test('allows self-intersection for even-odd region filling', () {
      final LassoClearRequest request = LassoClearRequest(
        layerId: 'ink',
        vertices: <LassoPoint>[
          LassoPoint(x: 0, y: 0),
          LassoPoint(x: 4, y: 4),
          LassoPoint(x: 0, y: 4),
          LassoPoint(x: 4, y: 0),
        ],
        requestedAt: Duration.zero,
      );

      expect(request.vertices, hasLength(4));
      expect(request.bounds.width, 4);
      expect(request.bounds.height, 4);
    });

    test('rejects non-finite, insufficient, and collinear geometry', () {
      expect(() => LassoPoint(x: double.nan, y: 0), throwsArgumentError);
      expect(
        () => LassoClearRequest(
          layerId: 'ink',
          vertices: <LassoPoint>[
            LassoPoint(x: 0, y: 0),
            LassoPoint(x: 1, y: 1),
          ],
          requestedAt: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => LassoClearRequest(
          layerId: 'ink',
          vertices: <LassoPoint>[
            LassoPoint(x: 0, y: 0),
            LassoPoint(x: 1, y: 1),
            LassoPoint(x: 2, y: 2),
          ],
          requestedAt: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test('rejects blank layer and negative request time', () {
      expect(() => _triangle(layerId: ' '), throwsArgumentError);
      expect(() => _triangle(milliseconds: -1), throwsArgumentError);
    });
  });

  test('EraserTool forwards typed stroke and lasso commands', () {
    final List<StrokeEraseBatchRequest> strokeOutput =
        <StrokeEraseBatchRequest>[];
    final List<LassoClearRequest> lassoOutput = <LassoClearRequest>[];
    final EraserTool tool = EraserTool(
      onStrokeEraseBatch: strokeOutput.add,
      onLassoClear: lassoOutput.add,
      initialMode: EraserMode.stroke,
    );

    expect(tool.lastSelectedMode, EraserMode.stroke);
    expect(
      tool.modeForInput(eraserToolSelected: false, penFlipped: true),
      EraserMode.stroke,
    );

    tool.strokeKills.addKill(_kill(5, 0));
    tool.strokeKills.flush();
    final LassoClearRequest lasso = _triangle();
    tool.clearLasso(lasso);

    expect(strokeOutput.single.targetSequences, <int>[5]);
    expect(lassoOutput.single, same(lasso));
  });

  test('stroke hit test chooses the topmost contacted recipe', () {
    final JournalEntry bottom = _strokeEntry(
      sequence: 1,
      samples: <StrokeSample>[_sample(0, 0), _sample(20, 0, milliseconds: 10)],
    );
    final JournalEntry top = _strokeEntry(
      sequence: 2,
      samples: <StrokeSample>[_sample(0, 1), _sample(20, 1, milliseconds: 10)],
    );

    expect(
      hitTestTopmostReplayableStroke(
        candidates: <JournalEntry>[bottom, top],
        contact: LassoPoint(x: 10, y: 0.5),
        contactRadius: 1,
        documentWidth: 100,
        documentHeight: 100,
      ),
      same(top),
    );
    expect(
      hitTestTopmostReplayableStroke(
        candidates: <JournalEntry>[bottom, top],
        contact: LassoPoint(x: 10, y: 20),
        contactRadius: 1,
        documentWidth: 100,
        documentHeight: 100,
      ),
      isNull,
    );
  });

  test('stroke hit test includes every captured symmetry copy', () {
    final JournalEntry symmetric = _strokeEntry(
      sequence: 1,
      samples: <StrokeSample>[
        _sample(10, 20),
        _sample(20, 20, milliseconds: 10),
      ],
      unknownFields: const <String, Object?>{'strokeSymmetry': 'quad'},
    );

    for (final LassoPoint contact in <LassoPoint>[
      LassoPoint(x: 15, y: 20),
      LassoPoint(x: 85, y: 20),
      LassoPoint(x: 15, y: 60),
      LassoPoint(x: 85, y: 60),
    ]) {
      expect(
        hitTestTopmostReplayableStroke(
          candidates: <JournalEntry>[symmetric],
          contact: contact,
          contactRadius: 0,
          documentWidth: 100,
          documentHeight: 80,
        ),
        same(symmetric),
      );
    }
  });
}

JournalEntry _strokeEntry({
  required int sequence,
  required List<StrokeSample> samples,
  Map<String, Object?> unknownFields = const <String, Object?>{},
}) => JournalEntry(
  seq: sequence,
  timestampMs: sequence,
  kind: JournalKind.stroke,
  layerId: 'ink',
  bounds: const JournalBounds(x: 0, y: 0, width: 24, height: 4),
  recipe: StrokeRecipe(
    brushId: 'fineliner',
    colorArgb: 0xff000000,
    size: 2,
    seed: sequence,
    transform: const <double>[1, 0, 0, 1, 0, 0],
    samples: StrokeRecipeCodec.encode(samples),
  ),
  unknownFields: unknownFields,
  affectedKeys: const <TileKey>[],
);

StrokeSample _sample(double x, double y, {int milliseconds = 0}) =>
    StrokeSample(
      point: Offset(x, y),
      pressure: 1,
      tilt: Offset.zero,
      timestamp: Duration(milliseconds: milliseconds),
    );

StrokeKill _kill(int sequence, int milliseconds, {String layerId = 'ink'}) =>
    StrokeKill(
      layerId: layerId,
      strokeSequence: sequence,
      timestamp: Duration(milliseconds: milliseconds),
    );

LassoClearRequest _triangle({String layerId = 'ink', int milliseconds = 0}) =>
    LassoClearRequest(
      layerId: layerId,
      vertices: <LassoPoint>[
        LassoPoint(x: 0, y: 0),
        LassoPoint(x: 8, y: 0),
        LassoPoint(x: 2, y: 6),
      ],
      requestedAt: Duration(milliseconds: milliseconds),
    );
