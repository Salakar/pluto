import 'dart:typed_data';

import '../document/document.dart';
import '../document/tile_store.dart';
import '../document/undo_journal.dart';
import 'compositor.dart';

const int _maxInkContentLayers = 12;

/// The stationary point used when the finite canvas bounds change size.
enum CanvasResizeAnchor {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

/// Blend modes that WP6 layer operations can create or flatten.
///
/// The manifest parser remains forward-compatible and may retain an unknown
/// string. An operation that needs to interpret a blend rejects that string
/// instead of silently treating it as `normal`.
enum LayerBlendMode {
  normal,
  multiply;

  /// Stable schema identifier stored by [InkLayer.blend].
  String get id => name;
}

/// A synchronously prepared state transition and its write-ahead entry.
///
/// Callers publish [state] and commit [entry] through [UndoJournal]. The entry
/// already owns every hot before/after tile reference needed for immediate
/// undo and for durable snapshot preparation.
final class JournaledEngineOperation {
  /// Creates a prepared engine operation.
  const JournaledEngineOperation({required this.state, required this.entry});

  /// Resulting document/raster state.
  final JournalDocumentState state;

  /// Journal entry corresponding exactly to [state].
  final JournalEntry entry;
}

/// Why a content-changing layer operation was intentionally not applied.
enum LayerOperationBlock { locked, hidden }

/// Typed applied-or-blocked result used to drive the 800 ms layer chip.
final class LayerOperationResult {
  const LayerOperationResult._({this.operation, this.block, this.layerId})
    : assert(
        (operation == null) != (block == null),
        'Exactly one operation or block must be present.',
      );

  /// Creates a successful layer operation result.
  factory LayerOperationResult.applied(JournaledEngineOperation operation) =>
      LayerOperationResult._(operation: operation);

  /// Creates a no-op result for the locked or hidden [layerId].
  factory LayerOperationResult.blocked({
    required LayerOperationBlock block,
    required String layerId,
  }) => LayerOperationResult._(block: block, layerId: layerId);

  /// Prepared transition, or null when blocked.
  final JournaledEngineOperation? operation;

  /// Typed no-op reason, or null when applied.
  final LayerOperationBlock? block;

  /// Layer responsible for [block], or null when applied.
  final String? layerId;

  /// Whether [operation] is available for publication and commit.
  bool get isApplied => operation != null;
}

/// Resizes canvas bounds and translates every backing pixel for [anchor].
///
/// Shrinking never deletes raster data. Pixels translated outside the new
/// `0..width` / `0..height` bounds remain in sparse tiles and are merely
/// clipped by canvas presentation/export. Center anchoring uses truncation
/// toward zero for half deltas, so opposite resize deltas are exact inverses.
JournaledEngineOperation resizeCanvas({
  required JournalDocumentState state,
  required int width,
  required int height,
  required CanvasResizeAnchor anchor,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  final nextCanvas = before.canvas.copyWith(width: width, height: height);
  if (width == before.canvas.width && height == before.canvas.height) {
    throw StateError('Canvas dimensions are unchanged.');
  }
  final deltaX = width - before.canvas.width;
  final deltaY = height - before.canvas.height;
  final offsetX = _horizontalResizeOffset(anchor, deltaX);
  final offsetY = _verticalResizeOffset(anchor, deltaY);
  final translated = _translateStore(
    before.tiles,
    before.layers.map((layer) => layer.id),
    offsetX: offsetX,
    offsetY: offsetY,
  );
  final after = _stateFrom(
    tiles: translated,
    layers: before.layers,
    canvas: nextCanvas,
  );
  return _structuralOperation(
    kind: JournalKind.canvasResize,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    completeLayerSnapshots: true,
  );
}

/// Horizontally flips every backing pixel around the current canvas width.
///
/// The transform is `x -> canvas.width - 1 - x` for in-bounds and off-bounds
/// pixels alike; y is unchanged. The journal transform is involutive and
/// therefore stores no raster snapshots.
JournaledEngineOperation flipCanvasHorizontally({
  required JournalDocumentState state,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  final entry = JournalEntry(
    seq: sequence,
    timestampMs: timestampMs,
    kind: JournalKind.canvasFlip,
  );
  final after = applyJournalEntry(
    before,
    entry,
    direction: JournalDirection.forward,
  );
  return JournaledEngineOperation(state: after, entry: entry);
}

/// Clears [layerId], or returns a typed no-op when it is locked or hidden.
LayerOperationResult clearLayer({
  required JournalDocumentState state,
  required String layerId,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  final layer = _requireLayer(before.layers, layerId);
  final blocked = _contentBlock(layer);
  if (blocked != null) {
    return LayerOperationResult.blocked(block: blocked, layerId: layerId);
  }
  final beforeTiles = before.tiles.layerTiles(layerId);
  final store = before.tiles.fork()..clearLayer(layerId);
  final after = _stateFrom(
    tiles: store,
    layers: before.layers,
    canvas: before.canvas,
  );
  final entry = JournalEntry(
    seq: sequence,
    timestampMs: timestampMs,
    kind: JournalKind.layerClear,
    layerId: layerId,
    affectedKeys: beforeTiles.keys,
    beforeTiles: <TileKey, Tile?>{...beforeTiles},
  );
  return LayerOperationResult.applied(
    JournaledEngineOperation(state: after, entry: entry),
  );
}

/// Adds an empty content [layer] at [index], or at the top when omitted.
JournaledEngineOperation addLayer({
  required JournalDocumentState state,
  required InkLayer layer,
  required int sequence,
  required int timestampMs,
  int? index,
}) {
  final before = _normalizeState(state);
  _checkLayerCapacity(before.layers);
  _checkSupportedBlend(layer.blend);
  if (layer.tiles.isNotEmpty) {
    throw ArgumentError.value(
      layer.tiles,
      'layer.tiles',
      'addLayer accepts an empty layer; use duplicateLayer for raster data',
    );
  }
  if (before.layers.any((candidate) => candidate.id == layer.id)) {
    throw ArgumentError.value(layer.id, 'layer.id', 'must be unique');
  }
  final insertionIndex = index ?? before.layers.length;
  if (insertionIndex < 0 || insertionIndex > before.layers.length) {
    throw RangeError.range(insertionIndex, 0, before.layers.length, 'index');
  }
  final layers = List<InkLayer>.of(before.layers)
    ..insert(insertionIndex, layer.copyWith(tiles: const <TileKey>[]));
  final store = before.tiles.fork()..ensureLayer(layer.id);
  final after = _stateFrom(tiles: store, layers: layers, canvas: before.canvas);
  return _structuralOperation(
    kind: JournalKind.layerAdd,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    layerId: layer.id,
  );
}

/// Duplicates [sourceLayerId] immediately above it using shared COW tiles.
JournaledEngineOperation duplicateLayer({
  required JournalDocumentState state,
  required String sourceLayerId,
  required String newLayerId,
  required String newName,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  _checkLayerCapacity(before.layers);
  final sourceIndex = _layerIndex(before.layers, sourceLayerId);
  final source = before.layers[sourceIndex];
  _checkSupportedBlend(source.blend);
  if (before.layers.any((layer) => layer.id == newLayerId)) {
    throw ArgumentError.value(newLayerId, 'newLayerId', 'must be unique');
  }
  final duplicate = source.copyWith(
    id: newLayerId,
    name: newName,
    tiles: before.tiles.occupiedKeys(sourceLayerId),
  );
  final layers = List<InkLayer>.of(before.layers)
    ..insert(sourceIndex + 1, duplicate);
  final store = before.tiles.fork()
    ..replaceLayer(newLayerId, before.tiles.layerTiles(sourceLayerId));
  final after = _stateFrom(tiles: store, layers: layers, canvas: before.canvas);
  return _structuralOperation(
    kind: JournalKind.layerAdd,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    layerId: newLayerId,
    completeLayerSnapshots: true,
  );
}

/// Removes [layerId] while retaining complete before/after raster snapshots.
JournaledEngineOperation removeLayer({
  required JournalDocumentState state,
  required String layerId,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  if (before.layers.length == 1) {
    throw StateError('The last content layer cannot be removed.');
  }
  final index = _layerIndex(before.layers, layerId);
  final layers = List<InkLayer>.of(before.layers)..removeAt(index);
  final store = before.tiles.fork()..removeLayer(layerId);
  final after = _stateFrom(tiles: store, layers: layers, canvas: before.canvas);
  return _structuralOperation(
    kind: JournalKind.layerRemove,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    layerId: layerId,
    completeLayerSnapshots: true,
  );
}

/// Moves [layerId] to [index] in bottom-to-top z-order.
JournaledEngineOperation reorderLayer({
  required JournalDocumentState state,
  required String layerId,
  required int index,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  if (index < 0 || index >= before.layers.length) {
    throw RangeError.range(index, 0, before.layers.length - 1, 'index');
  }
  final sourceIndex = _layerIndex(before.layers, layerId);
  if (sourceIndex == index) {
    throw StateError('Layer is already at index $index.');
  }
  final layers = List<InkLayer>.of(before.layers);
  final layer = layers.removeAt(sourceIndex);
  layers.insert(index, layer);
  final after = _stateFrom(
    tiles: before.tiles.fork(),
    layers: layers,
    canvas: before.canvas,
  );
  return _structuralOperation(
    kind: JournalKind.layerReorder,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    layerId: layerId,
  );
}

/// Updates persisted properties for [layerId].
JournaledEngineOperation updateLayerProperties({
  required JournalDocumentState state,
  required String layerId,
  required int sequence,
  required int timestampMs,
  String? name,
  bool? visible,
  bool? locked,
  int? opacity,
  LayerBlendMode? blend,
}) {
  final before = _normalizeState(state);
  final index = _layerIndex(before.layers, layerId);
  final layers = List<InkLayer>.of(before.layers);
  final current = layers[index];
  final updated = current.copyWith(
    name: name,
    visible: visible,
    locked: locked,
    opacity: opacity,
    blend: blend?.id,
  );
  if (updated.name == current.name &&
      updated.visible == current.visible &&
      updated.locked == current.locked &&
      updated.opacity == current.opacity &&
      updated.blend == current.blend) {
    throw StateError('Layer properties are unchanged.');
  }
  layers[index] = updated;
  final after = _stateFrom(
    tiles: before.tiles.fork(),
    layers: layers,
    canvas: before.canvas,
  );
  return _structuralOperation(
    kind: JournalKind.layerProps,
    before: before,
    after: after,
    sequence: sequence,
    timestampMs: timestampMs,
    layerId: layerId,
  );
}

/// Flattens [topLayerId] into its immediate lower neighbour.
///
/// Both source layers must be visible and unlocked. Their current opacity and
/// `normal`/`multiply` blend semantics are baked into pixels. The lower layer
/// keeps its id/name/unknown metadata but becomes visible, unlocked, opacity
/// 100, and normal blend; the top layer is removed. Complete snapshots make
/// the operation exactly undoable even though its metadata is normalized.
LayerOperationResult mergeLayerDown({
  required JournalDocumentState state,
  required String topLayerId,
  required int sequence,
  required int timestampMs,
}) {
  final before = _normalizeState(state);
  final topIndex = _layerIndex(before.layers, topLayerId);
  if (topIndex == 0) {
    throw StateError('The bottom layer has no lower neighbour to merge into.');
  }
  final top = before.layers[topIndex];
  final bottom = before.layers[topIndex - 1];
  for (final layer in <InkLayer>[top, bottom]) {
    final blocked = _contentBlock(layer);
    if (blocked != null) {
      return LayerOperationResult.blocked(block: blocked, layerId: layer.id);
    }
  }
  _checkSupportedBlend(bottom.blend);
  _checkSupportedBlend(top.blend);
  final mergedTiles = compositeLayerStack(
    layers: <InkLayer>[bottom, top],
    tiles: before.tiles,
  );
  final survivor = bottom.copyWith(
    visible: true,
    locked: false,
    opacity: 100,
    blend: LayerBlendMode.normal.id,
    tiles: mergedTiles.keys,
  );
  final layers = List<InkLayer>.of(before.layers)
    ..[topIndex - 1] = survivor
    ..removeAt(topIndex);
  final store = before.tiles.fork()
    ..replaceLayer(bottom.id, mergedTiles)
    ..removeLayer(top.id);
  final after = _stateFrom(tiles: store, layers: layers, canvas: before.canvas);
  return LayerOperationResult.applied(
    _structuralOperation(
      kind: JournalKind.merge,
      before: before,
      after: after,
      sequence: sequence,
      timestampMs: timestampMs,
      layerId: topLayerId,
      completeLayerSnapshots: true,
    ),
  );
}

JournaledEngineOperation _structuralOperation({
  required JournalKind kind,
  required JournalDocumentState before,
  required JournalDocumentState after,
  required int sequence,
  required int timestampMs,
  String? layerId,
  bool completeLayerSnapshots = false,
}) {
  final entry = JournalEntry(
    seq: sequence,
    timestampMs: timestampMs,
    kind: kind,
    layerId: layerId,
    beforeState: before.structuralJson(),
    afterState: after.structuralJson(),
    beforeLayerTiles: completeLayerSnapshots
        ? _completeRasterSnapshot(before)
        : const {},
    afterLayerTiles: completeLayerSnapshots
        ? _completeRasterSnapshot(after)
        : const {},
    completeLayerSnapshots: completeLayerSnapshots,
  );
  return JournaledEngineOperation(state: after, entry: entry);
}

Map<String, Map<TileKey, Tile?>> _completeRasterSnapshot(
  JournalDocumentState state,
) => <String, Map<TileKey, Tile?>>{
  for (final layer in state.layers)
    layer.id: <TileKey, Tile?>{
      for (final entry in state.tiles.layerTiles(layer.id).entries)
        entry.key: entry.value,
    },
};

JournalDocumentState _normalizeState(JournalDocumentState state) {
  final store = TileStore();
  for (final layer in state.layers) {
    store.replaceLayer(layer.id, state.tiles.layerTiles(layer.id));
  }
  return _stateFrom(tiles: store, layers: state.layers, canvas: state.canvas);
}

JournalDocumentState _stateFrom({
  required TileStore tiles,
  required Iterable<InkLayer> layers,
  required CanvasSpec canvas,
}) => JournalDocumentState(
  tiles: tiles,
  layers: <InkLayer>[
    for (final layer in layers)
      layer.copyWith(tiles: tiles.occupiedKeys(layer.id)),
  ],
  canvas: canvas,
);

TileStore _translateStore(
  TileStore source,
  Iterable<String> layerIds, {
  required int offsetX,
  required int offsetY,
}) {
  if (offsetX == 0 && offsetY == 0) {
    final result = TileStore();
    for (final layerId in layerIds) {
      result.replaceLayer(layerId, source.layerTiles(layerId));
    }
    return result;
  }
  final result = TileStore();
  for (final layerId in layerIds) {
    final output = <TileKey, Uint8List>{};
    for (final sourceEntry in source.layerTiles(layerId).entries) {
      final sourcePixels = sourceEntry.value.pixels;
      for (var localY = 0; localY < Tile.edge; localY += 1) {
        final globalY = sourceEntry.key.y * Tile.edge + localY + offsetY;
        final destinationTileY = _tileCoordinate(globalY);
        final destinationLocalY = globalY - destinationTileY * Tile.edge;
        for (var localX = 0; localX < Tile.edge; localX += 1) {
          final sourceOffset =
              (localY * Tile.edge + localX) * Tile.bytesPerPixel;
          if (sourcePixels[sourceOffset + 3] == 0) {
            continue;
          }
          final globalX = sourceEntry.key.x * Tile.edge + localX + offsetX;
          final destinationTileX = _tileCoordinate(globalX);
          final destinationLocalX = globalX - destinationTileX * Tile.edge;
          final destinationKey = TileKey(destinationTileX, destinationTileY);
          final destination = output.putIfAbsent(
            destinationKey,
            () => Uint8List(Tile.byteLength),
          );
          final destinationOffset =
              (destinationLocalY * Tile.edge + destinationLocalX) *
              Tile.bytesPerPixel;
          destination.setRange(
            destinationOffset,
            destinationOffset + Tile.bytesPerPixel,
            sourcePixels,
            sourceOffset,
          );
        }
      }
    }
    final ordered = output.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    result.replaceLayer(layerId, <TileKey, Tile>{
      for (final entry in ordered) entry.key: Tile.takeOwnership(entry.value),
    });
  }
  return result;
}

int _horizontalResizeOffset(CanvasResizeAnchor anchor, int delta) =>
    switch (anchor) {
      CanvasResizeAnchor.topLeft ||
      CanvasResizeAnchor.centerLeft ||
      CanvasResizeAnchor.bottomLeft => 0,
      CanvasResizeAnchor.topCenter ||
      CanvasResizeAnchor.center ||
      CanvasResizeAnchor.bottomCenter => delta ~/ 2,
      CanvasResizeAnchor.topRight ||
      CanvasResizeAnchor.centerRight ||
      CanvasResizeAnchor.bottomRight => delta,
    };

int _verticalResizeOffset(CanvasResizeAnchor anchor, int delta) =>
    switch (anchor) {
      CanvasResizeAnchor.topLeft ||
      CanvasResizeAnchor.topCenter ||
      CanvasResizeAnchor.topRight => 0,
      CanvasResizeAnchor.centerLeft ||
      CanvasResizeAnchor.center ||
      CanvasResizeAnchor.centerRight => delta ~/ 2,
      CanvasResizeAnchor.bottomLeft ||
      CanvasResizeAnchor.bottomCenter ||
      CanvasResizeAnchor.bottomRight => delta,
    };

int _tileCoordinate(int pixel) =>
    pixel >= 0 ? pixel ~/ Tile.edge : -((-pixel + Tile.edge - 1) ~/ Tile.edge);

InkLayer _requireLayer(Iterable<InkLayer> layers, String layerId) {
  for (final layer in layers) {
    if (layer.id == layerId) {
      return layer;
    }
  }
  throw ArgumentError.value(layerId, 'layerId', 'does not exist');
}

int _layerIndex(List<InkLayer> layers, String layerId) {
  final index = layers.indexWhere((layer) => layer.id == layerId);
  if (index < 0) {
    throw ArgumentError.value(layerId, 'layerId', 'does not exist');
  }
  return index;
}

LayerOperationBlock? _contentBlock(InkLayer layer) {
  if (!layer.visible) {
    return LayerOperationBlock.hidden;
  }
  if (layer.locked) {
    return LayerOperationBlock.locked;
  }
  return null;
}

void _checkLayerCapacity(List<InkLayer> layers) {
  if (layers.length >= _maxInkContentLayers) {
    throw StateError('Content layer cap of $_maxInkContentLayers reached.');
  }
}

void _checkSupportedBlend(String blend) {
  if (!LayerBlendMode.values.any((mode) => mode.id == blend)) {
    throw ArgumentError.value(
      blend,
      'blend',
      'must be normal or multiply for an engine layer operation',
    );
  }
}
