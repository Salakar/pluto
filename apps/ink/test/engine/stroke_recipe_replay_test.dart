import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/document/tile_store.dart';
import 'package:paper_ink/src/document/undo_journal.dart';
import 'package:paper_ink/src/engine/brush_engine.dart';
import 'package:paper_ink/src/engine/brush_presets.dart';
import 'package:paper_ink/src/engine/brush_tool_hooks.dart';
import 'package:paper_ink/src/engine/compositor.dart';
import 'package:paper_ink/src/engine/raster_worker.dart';
import 'package:paper_ink/src/engine/stroke_pipeline.dart';
import 'package:paper_ink/src/engine/stroke_recipe_replay.dart';
import 'package:paper_ink/src/engine/symmetry.dart';

void main() {
  test(
    'recipe replay matches live flow, symmetry, and final quantization',
    () async {
      const String layerId = 'ink';
      const double flowMultiplier = 0.5;
      final List<StrokeSample> samples = <StrokeSample>[
        _sample(20, 28, pressure: 0.45, milliseconds: 0),
        _sample(25, 30, pressure: 0.65, milliseconds: 8),
        _sample(30, 28, pressure: 0.85, milliseconds: 16),
      ];
      final JournalDocumentState state = JournalDocumentState(
        tiles: TileStore()..ensureLayer(layerId),
        layers: <InkLayer>[InkLayer(id: layerId, name: 'Ink')],
        canvas: CanvasSpec(width: 128, height: 64),
      );
      final Map<TileKey, Tile?> live = await _renderLive(
        state: state,
        samples: samples,
        flowMultiplier: flowMultiplier,
      );
      final JournalEntry entry = JournalEntry(
        seq: 1,
        timestampMs: 1,
        kind: JournalKind.stroke,
        layerId: layerId,
        recipe: StrokeRecipe(
          brushId: pencilHbBrush.id,
          colorArgb: 0xff1d3e74,
          size: 8,
          seed: 37,
          transform: const <double>[1, 0, 0, 1, 0, 0],
          samples: StrokeRecipeCodec.encode(samples),
        ),
        affectedKeys: live.keys,
        unknownFields: const <String, Object?>{
          'strokeReplayVersion': 1,
          'strokeFlow': flowMultiplier,
          'strokeSymmetry': 'vertical',
        },
      );

      final Map<TileKey, Tile?> replayed = await replayJournalStrokeRecipe(
        RecipeReplayRequest(state: state, entry: entry, clipKeys: live.keys),
      );

      expect(replayed.keys, unorderedEquals(live.keys));
      for (final TileKey key in live.keys) {
        expect(replayed[key]?.pixels, orderedEquals(live[key]?.pixels ?? []));
      }
      expect(_alphaAt(replayed, 25, 30), greaterThan(0));
      expect(_alphaAt(replayed, 103, 30), greaterThan(0));
      final Set<int> visibleAlphas = <int>{
        for (final Tile? tile in replayed.values)
          if (tile != null)
            for (var offset = 3; offset < tile.pixels.length; offset += 4)
              if (tile.pixels[offset] != 0) tile.pixels[offset],
      };
      expect(visibleAlphas.length, lessThanOrEqualTo(4));
    },
  );
}

Future<Map<TileKey, Tile?>> _renderLive({
  required JournalDocumentState state,
  required List<StrokeSample> samples,
  required double flowMultiplier,
}) async {
  const Size documentSize = Size(128, 64);
  final StrokeBuffer buffer = StrokeBuffer(documentSize: documentSize);
  final BrushStampTarget target = SymmetryBrushStampTarget(
    target: StrokeBufferBrushTarget(
      buffer: buffer,
      flowMultiplier: flowMultiplier,
    ),
    configuration: SymmetryConfiguration(
      mode: SymmetryMode.vertical,
      axisX: documentSize.width / 2,
      axisY: documentSize.height / 2,
    ),
  );
  final BrushEngine engine = BrushEngine(
    spec: pencilHbBrush,
    target: target,
    seed: 37,
    colorArgb: 0xff1d3e74,
    size: 8,
  );
  final StrokePipeline pipeline = StrokePipeline(
    smoothing: pencilHbBrush.smoothing,
    onPath: (List<FittedStrokeSample> path, {required bool isFinal}) {
      if (path.isNotEmpty) {
        engine.stampAlong(
          path.map<BrushPoint>(
            (FittedStrokeSample fitted) => BrushPoint(
              point: fitted.point,
              pressure: fitted.pressure,
              tilt: (fitted.tilt.distance / (math.pi / 2))
                  .clamp(0.0, 1.0)
                  .toDouble(),
              timestamp: fitted.timestamp,
            ),
          ),
        );
      }
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
  buffer.quantizeAlphaLevels(pencilHbBrush.quantizeLevels);
  final RasterCommitResult result = await const InlineRasterCompositor()
      .compositeDebugStroke(
        stroke: buffer.seal(),
        tiles: state.tiles,
        layerId: 'ink',
        documentSize: documentSize,
      );
  return <TileKey, Tile?>{
    for (final MapEntry<TileKey, Tile> tile in result.changedTiles.entries)
      tile.key: tile.value,
  };
}

StrokeSample _sample(
  double x,
  double y, {
  required double pressure,
  required int milliseconds,
}) => StrokeSample(
  point: Offset(x, y),
  pressure: pressure,
  tilt: Offset.zero,
  timestamp: Duration(milliseconds: milliseconds),
);

int _alphaAt(Map<TileKey, Tile?> tiles, int x, int y) {
  final TileKey key = TileKey(x ~/ Tile.edge, y ~/ Tile.edge);
  final Tile? tile = tiles[key];
  if (tile == null) {
    return 0;
  }
  final int localX = x - key.x * Tile.edge;
  final int localY = y - key.y * Tile.edge;
  return tile.pixels[(localY * Tile.edge + localX) * Tile.bytesPerPixel + 3];
}
