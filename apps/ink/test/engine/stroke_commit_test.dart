import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/engine/compositor.dart';
import 'package:paper_ink/src/engine/geometry.dart';
import 'package:paper_ink/src/engine/raster_worker.dart';
import 'package:paper_ink/src/engine/stroke_pipeline.dart';

void main() {
  group('stroke commit and recipe journal', () {
    test(
      'real pipeline commit survives write-ahead recipe round-trip',
      () async {
        final InkDocument document = InkDocument.blank(id: 'commit', nowMs: 1);
        final String layerId = document.activeLayerId;
        final TileStore tiles = TileStore();
        final _RenderedStroke rendered = _renderStroke(
          spec: finelinerBrush,
          size: 3,
          seed: 17,
          samples: <StrokeSample>[
            _sample(8, 8, pressure: 0.2, micros: 0),
            _sample(24, 12, pressure: 0.6, micros: 8000),
            _sample(40, 10, pressure: 1, micros: 16000),
          ],
        );
        final StrokeBufferSnapshot stroke = rendered.buffer.seal();
        const InlineRasterCompositor compositor = InlineRasterCompositor();
        final RasterCommitResult result = await compositor.compositeDebugStroke(
          stroke: stroke,
          tiles: tiles,
          layerId: layerId,
          documentSize: const Size(954, 1696),
        );
        expect(result.isEmpty, isFalse);
        tiles.publishAll(layerId, result.changedTiles);

        final InMemoryJournalStorage storage = InMemoryJournalStorage();
        final UndoJournal journal = UndoJournal(storage: storage);
        final StrokeRecipe recipe = StrokeRecipe(
          brushId: finelinerBrush.id,
          colorArgb: 0xff1d3e74,
          size: 3,
          seed: 17,
          transform: const <double>[1.25, 0, 0, 1.25, 12, 18],
          samples: rendered.recipe,
        );
        await journal.commit(
          JournalEntry(
            seq: journal.nextSequence,
            timestampMs: 42,
            kind: JournalKind.stroke,
            layerId: layerId,
            bounds: _bounds(stroke.inkBounds),
            recipe: recipe,
            affectedKeys: result.changedTiles.keys,
            beforeTiles: result.beforeTiles,
            afterTiles: result.changedTiles,
          ),
          checkpointStore: tiles,
        );

        expect(storage.appendCount, 1);
        expect(storage.flushCount, 1);
        final UndoJournal reopened = await UndoJournal.open(
          storage: storage.crashClone(),
        );
        final StrokeRecipe recovered = reopened.entries.single.recipe!;
        expect(recovered.brushId, finelinerBrush.id);
        expect(recovered.colorArgb, 0xff1d3e74);
        expect(recovered.size, 3);
        expect(recovered.seed, 17);
        expect(recovered.transform, recipe.transform);
        expect(
          StrokeRecipeCodec.decode(recovered.samples),
          orderedEquals(StrokeRecipeCodec.decode(rendered.recipe)),
        );
        await journal.close();
        await reopened.close();
      },
    );

    test('clear commit journals erase and undo restores exact tile', () async {
      final InkDocument document = InkDocument.blank(id: 'erase', nowMs: 1);
      final String layerId = document.activeLayerId;
      final TileStore tiles = TileStore();
      final Uint8List beforePixels = Uint8List(Tile.byteLength);
      final int pixelOffset = (10 * Tile.edge + 10) * 4;
      beforePixels.setRange(pixelOffset, pixelOffset + 4, const <int>[
        20,
        30,
        40,
        255,
      ]);
      final Tile beforeTile = Tile.takeOwnership(beforePixels);
      tiles.publish(layerId, const TileKey(0, 0), beforeTile);
      final _RenderedStroke rendered = _renderStroke(
        spec: eraserPixelBrush,
        size: 16,
        seed: 23,
        samples: <StrokeSample>[_sample(10.5, 10.5, pressure: 1, micros: 0)],
      );
      final StrokeBufferSnapshot stroke = rendered.buffer.seal();

      final ClearCompositeResult result = compositeClearMask(
        tiles: tiles,
        layerId: layerId,
        candidateKeys: tileKeysCoveringRect(
          stroke.inkBounds,
          const Size(954, 1696),
        ),
        maskPixels: stroke.pixels,
        maskOriginX: stroke.originX,
        maskOriginY: stroke.originY,
        maskWidth: stroke.width,
        maskHeight: stroke.height,
      );
      expect(result.beforeTiles[const TileKey(0, 0)], same(beforeTile));
      expect(result.afterTiles[const TileKey(0, 0)], isNull);
      tiles.publishAll(layerId, result.afterTiles);

      final InMemoryJournalStorage storage = InMemoryJournalStorage();
      final UndoJournal journal = UndoJournal(storage: storage);
      await journal.commit(
        JournalEntry(
          seq: journal.nextSequence,
          timestampMs: 50,
          kind: JournalKind.erase,
          layerId: layerId,
          bounds: _bounds(stroke.inkBounds),
          recipe: StrokeRecipe(
            brushId: eraserPixelBrush.id,
            colorArgb: 0xff000000,
            size: 16,
            seed: 23,
            transform: const <double>[1, 0, 0, 1, 0, 0],
            samples: rendered.recipe,
          ),
          affectedKeys: result.afterTiles.keys,
          beforeTiles: result.beforeTiles,
          afterTiles: result.afterTiles,
        ),
        checkpointStore: tiles,
      );
      expect(journal.entries.single.kind, JournalKind.erase);

      final JournalDocumentState committed = JournalDocumentState(
        tiles: tiles,
        layers: document.layers,
        canvas: document.canvas,
      );
      final JournalStep undo = (await journal.undo(committed))!;
      expect(
        undo.state.tiles.tile(layerId, const TileKey(0, 0)),
        same(beforeTile),
      );
      final JournalStep redo = (await journal.redo(undo.state))!;
      expect(redo.state.tiles.tile(layerId, const TileKey(0, 0)), isNull);
      await journal.close();
    });
  });
}

final class _RenderedStroke {
  const _RenderedStroke({required this.buffer, required this.recipe});

  final StrokeBuffer buffer;
  final Uint8List recipe;
}

_RenderedStroke _renderStroke({
  required BrushSpec spec,
  required double size,
  required int seed,
  required List<StrokeSample> samples,
}) {
  final StrokeBuffer buffer = StrokeBuffer(documentSize: const Size(954, 1696));
  final BrushEngine engine = BrushEngine(
    spec: spec,
    target: _TestStrokeTarget(buffer),
    seed: seed,
    colorArgb: 0xff1d3e74,
    size: size,
  );
  final StrokePipeline pipeline = StrokePipeline(
    smoothing: spec.smoothing,
    onPath: (List<FittedStrokeSample> fitted, {required bool isFinal}) {
      engine.stampAlong(
        fitted.map<BrushPoint>(
          (FittedStrokeSample value) => BrushPoint(
            point: value.point,
            pressure: value.pressure,
            tilt: (value.tilt.distance / (math.pi / 2))
                .clamp(0.0, 1.0)
                .toDouble(),
            timestamp: value.timestamp,
          ),
        ),
      );
      if (isFinal) {
        engine.finalize();
      }
    },
  );
  pipeline.begin(samples.first);
  for (final StrokeSample sample in samples.skip(1)) {
    pipeline.add(sample);
  }
  pipeline.end();
  if (spec.quantizeLevels > 0) {
    buffer.quantizeAlphaLevels(spec.quantizeLevels);
  }
  return _RenderedStroke(buffer: buffer, recipe: pipeline.encodeRecipe());
}

final class _TestStrokeTarget implements BrushStampTarget {
  const _TestStrokeTarget(this.buffer);

  final StrokeBuffer buffer;

  @override
  Rect stamp(ResolvedBrushStamp stamp) {
    final ResolvedBrushGrain? grain = stamp.grain;
    return buffer.stampEllipse(
      center: stamp.center,
      diameterX: stamp.diameterX,
      diameterY: stamp.diameterY,
      angleRadians: stamp.angleRadians,
      colorArgb: stamp.colorArgb,
      flow: stamp.flow,
      modifyCoverage: grain == null
          ? null
          : (int x, int y, double coverage) =>
                coverage *
                grain.coverageAt(
                  Offset(x + 0.5, y + 0.5),
                  stampCenter: stamp.center,
                ),
    );
  }
}

StrokeSample _sample(
  double x,
  double y, {
  required double pressure,
  required int micros,
}) => StrokeSample(
  point: Offset(x, y),
  pressure: pressure,
  tilt: const Offset(0.1, -0.2),
  timestamp: Duration(microseconds: micros),
);

JournalBounds _bounds(Rect rect) {
  final int left = rect.left.floor();
  final int top = rect.top.floor();
  return JournalBounds(
    x: left,
    y: top,
    width: rect.right.ceil() - left,
    height: rect.bottom.ceil() - top,
  );
}
