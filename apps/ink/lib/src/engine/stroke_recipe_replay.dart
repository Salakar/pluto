import 'dart:math' as math;
import 'dart:ui';

import '../document/tile_store.dart';
import '../document/undo_journal.dart';
import 'brush_engine.dart';
import 'brush_presets.dart';
import 'brush_tool_hooks.dart';
import 'compositor.dart';
import 'geometry.dart';
import 'raster_worker.dart';
import 'stroke_pipeline.dart';
import 'symmetry.dart';

/// Re-renders one deterministic journal recipe against its current layer.
///
/// This is shared by crash recovery and bounded whole-stroke erasure. Recipe
/// strokes are recomposited instead of restoring whole after-tiles, so an
/// omitted earlier stroke cannot leak back through a later tile snapshot.
Future<Map<TileKey, Tile?>> replayJournalStrokeRecipe(
  RecipeReplayRequest request,
) async {
  final StrokeRecipe recipe = request.entry.recipe!;
  final String layerId = request.entry.layerId!;
  final BrushSpec brush = brushById(recipe.brushId);
  final List<StrokeSample> samples = StrokeRecipeCodec.decode(recipe.samples);
  if (samples.isEmpty) {
    return const <TileKey, Tile?>{};
  }
  final Size documentSize = Size(
    request.state.canvas.width.toDouble(),
    request.state.canvas.height.toDouble(),
  );
  final StrokeBuffer buffer = StrokeBuffer(documentSize: documentSize);
  final Object? storedFlow = request.entry.unknownFields['strokeFlow'];
  final double flowMultiplier = storedFlow is num && storedFlow.isFinite
      ? storedFlow.toDouble().clamp(0.0, 1.0)
      : 1;
  final SymmetryMode symmetryMode =
      switch (request.entry.unknownFields['strokeSymmetry']) {
        'vertical' => SymmetryMode.vertical,
        'horizontal' => SymmetryMode.horizontal,
        'quad' => SymmetryMode.quad,
        _ => SymmetryMode.off,
      };
  BrushStampTarget target = StrokeBufferBrushTarget(
    buffer: buffer,
    flowMultiplier: flowMultiplier,
  );
  if (symmetryMode != SymmetryMode.off) {
    target = SymmetryBrushStampTarget(
      target: target,
      configuration: SymmetryConfiguration(
        mode: symmetryMode,
        axisX: documentSize.width / 2,
        axisY: documentSize.height / 2,
      ),
    );
  }
  final BrushEngine engine = BrushEngine(
    spec: brush,
    target: target,
    seed: recipe.seed,
    colorArgb: recipe.colorArgb,
    size: recipe.size,
  );
  final StrokePipeline pipeline = StrokePipeline(
    smoothing: brush.smoothing,
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
  if (brush.quantizeLevels > 0) {
    buffer.quantizeAlphaLevels(brush.quantizeLevels);
  }
  final StrokeBufferSnapshot stroke = buffer.seal();
  if (stroke.isEmpty) {
    return const <TileKey, Tile?>{};
  }
  final Set<TileKey> clipKeys = request.clipKeys.toSet();
  if (brush.blend.isClear) {
    final ClearCompositeResult result = compositeClearMask(
      tiles: request.state.tiles,
      layerId: layerId,
      candidateKeys: tileKeysCoveringRect(
        stroke.inkBounds,
        documentSize,
      ).where(clipKeys.contains),
      maskPixels: stroke.pixels,
      maskOriginX: stroke.originX,
      maskOriginY: stroke.originY,
      maskWidth: stroke.width,
      maskHeight: stroke.height,
    );
    return result.afterTiles;
  }
  final RasterCommitResult result = await const InlineRasterCompositor()
      .compositeDebugStroke(
        stroke: stroke,
        tiles: request.state.tiles,
        layerId: layerId,
        documentSize: documentSize,
      );
  return <TileKey, Tile?>{
    for (final MapEntry<TileKey, Tile> entry in result.changedTiles.entries)
      if (clipKeys.contains(entry.key)) entry.key: entry.value,
  };
}
