import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../document/document.dart';
import '../document/tile_store.dart';
import 'compositor.dart';
import 'geometry.dart';

const Duration _defaultWorkerTimeout = Duration(seconds: 10);

/// Extensible command union accepted by Ink's one long-lived raster isolate.
sealed class RasterCommand {
  const RasterCommand({required this.replyPort});

  /// Per-command response channel owned by the requesting main isolate.
  final SendPort replyPort;
}

/// Worker-side description of one target layer tile.
final class RasterTileInput {
  /// Creates a transferable tile payload; null pixels mean transparent absence.
  const RasterTileInput({
    required this.x,
    required this.y,
    required this.beforePixels,
  });

  /// Horizontal tile coordinate.
  final int x;

  /// Vertical tile coordinate.
  final int y;

  /// Existing immutable tile bytes copied into transferable storage.
  final TransferableTypedData? beforePixels;
}

/// Composites one sealed debug stroke into a batch of COW layer tiles.
final class CompositeDebugStrokeCommand extends RasterCommand {
  /// Creates a stroke-composite command.
  const CompositeDebugStrokeCommand({
    required super.replyPort,
    required this.strokeOriginX,
    required this.strokeOriginY,
    required this.strokeWidth,
    required this.strokeHeight,
    required this.strokePixels,
    required this.tiles,
  });

  /// Allocated stroke-buffer document-space left edge.
  final int strokeOriginX;

  /// Allocated stroke-buffer document-space top edge.
  final int strokeOriginY;

  /// Allocated stroke-buffer width.
  final int strokeWidth;

  /// Allocated stroke-buffer height.
  final int strokeHeight;

  /// Premultiplied RGBA8888 stroke bytes.
  final TransferableTypedData strokePixels;

  /// Affected layer tiles, including transparent absences.
  final List<RasterTileInput> tiles;
}

/// One visible layer contribution to a cache-tile flatten operation.
final class RasterCompositeLayerInput {
  /// Creates a transferable visible-layer payload.
  const RasterCompositeLayerInput({
    required this.opacity,
    required this.multiply,
    required this.pixels,
  });

  /// Layer opacity from 0 through 100.
  final int opacity;

  /// Whether this layer uses Ink's multiply blend.
  final bool multiply;

  /// Premultiplied RGBA8888 tile bytes.
  final TransferableTypedData pixels;
}

/// One tile-position input for a worker cache rebuild.
final class RasterCompositeTileInput {
  /// Creates a tile-position input in bottom-to-top layer order.
  const RasterCompositeTileInput({
    required this.x,
    required this.y,
    required this.layers,
  });

  /// Horizontal tile coordinate.
  final int x;

  /// Vertical tile coordinate.
  final int y;

  /// Visible, occupied layers in document order.
  final List<RasterCompositeLayerInput> layers;
}

/// Flattens a cache rebuild batch away from the input/main isolate.
final class CompositeCacheBatchCommand extends RasterCommand {
  /// Creates a cache-batch command.
  const CompositeCacheBatchCommand({
    required super.replyPort,
    required this.tiles,
  });

  /// Tile positions to flatten.
  final List<RasterCompositeTileInput> tiles;
}

/// Requests orderly worker shutdown after all prior commands finish.
final class StopRasterWorkerCommand extends RasterCommand {
  /// Creates a shutdown command.
  const StopRasterWorkerCommand({required super.replyPort});
}

/// Extensible response union emitted by the raster worker.
sealed class RasterResponse {
  const RasterResponse();
}

/// One changed tile produced by a worker command.
final class RasterTileOutput {
  /// Creates a transferable changed-tile payload.
  const RasterTileOutput({
    required this.x,
    required this.y,
    required this.pixels,
  });

  /// Horizontal tile coordinate.
  final int x;

  /// Vertical tile coordinate.
  final int y;

  /// New COW tile bytes.
  final TransferableTypedData pixels;
}

/// Successful debug-stroke composite response.
final class CompositeDebugStrokeResponse extends RasterResponse {
  /// Creates a successful response.
  const CompositeDebugStrokeResponse({required this.changedTiles});

  /// Only tiles whose bytes differ from their input.
  final List<RasterTileOutput> changedTiles;
}

/// Successful worker cache-batch response.
final class CompositeCacheBatchResponse extends RasterResponse {
  /// Creates a successful cache response.
  const CompositeCacheBatchResponse({required this.tiles});

  /// Flattened tile pixels, including transparent positions.
  final List<RasterTileOutput> tiles;
}

/// Failure response that keeps the long-lived worker available.
final class RasterFailureResponse extends RasterResponse {
  /// Creates a serializable worker failure.
  const RasterFailureResponse({required this.message, required this.stack});

  /// Error description.
  final String message;

  /// Worker stack trace text.
  final String stack;
}

/// Acknowledges orderly worker shutdown.
final class RasterStoppedResponse extends RasterResponse {
  /// Creates a shutdown acknowledgement.
  const RasterStoppedResponse();
}

/// Main-isolate COW result ready for publication and WP1 journaling.
final class RasterCommitResult {
  /// Creates an immutable commit result.
  RasterCommitResult({
    required Map<TileKey, Tile> changedTiles,
    required Map<TileKey, Tile?> beforeTiles,
  }) : changedTiles = Map<TileKey, Tile>.unmodifiable(changedTiles),
       beforeTiles = Map<TileKey, Tile?>.unmodifiable(beforeTiles);

  /// Worker-produced immutable replacement tiles.
  final Map<TileKey, Tile> changedTiles;

  /// Original store references for undo; values preserve reference identity.
  final Map<TileKey, Tile?> beforeTiles;

  /// Whether the debug stroke changed no destination pixels.
  bool get isEmpty => changedTiles.isEmpty;
}

/// Pixel compositor used by the canvas UI without prescribing an isolate.
///
/// Production uses [RasterWorker], while widget tests can use
/// [InlineRasterCompositor] without leaving isolate ports alive at teardown.
abstract interface class RasterCompositor {
  /// Composites a sealed debug stroke without mutating [tiles].
  Future<RasterCommitResult> compositeDebugStroke({
    required StrokeBufferSnapshot stroke,
    required TileStore tiles,
    required String layerId,
    required Size documentSize,
  });

  /// Flattens the visible layers at every requested tile position.
  Future<Map<TileKey, Uint8List>> compositeVisibleTiles({
    required List<TileKey> keys,
    required InkDocument document,
    required TileStore tiles,
  });

  /// Releases resources owned by this compositor.
  Future<void> dispose();
}

/// Result of the pure tile-composite primitive.
final class DebugTileComposite {
  /// Creates a pure pixel result.
  const DebugTileComposite({required this.pixels, required this.changed});

  /// New mutable tile bytes.
  final Uint8List pixels;

  /// Whether any source-alpha pixel changed the destination.
  final bool changed;
}

/// Pure worker-safe blend of [strokePixels] into one layer tile.
DebugTileComposite compositeDebugStrokeTile({
  required TileKey key,
  required Uint8List beforePixels,
  required Uint8List strokePixels,
  required int strokeOriginX,
  required int strokeOriginY,
  required int strokeWidth,
  required int strokeHeight,
}) {
  if (beforePixels.lengthInBytes != Tile.byteLength) {
    throw ArgumentError.value(
      beforePixels.lengthInBytes,
      'beforePixels.lengthInBytes',
      'must equal ${Tile.byteLength}',
    );
  }
  if (strokeWidth < 0 ||
      strokeHeight < 0 ||
      strokePixels.lengthInBytes != strokeWidth * strokeHeight * 4) {
    throw ArgumentError('Stroke dimensions do not match its RGBA payload.');
  }
  final output = Uint8List.fromList(beforePixels);
  var changed = false;
  final tileLeft = key.x * Tile.edge;
  final tileTop = key.y * Tile.edge;
  final overlapLeft = tileLeft > strokeOriginX ? tileLeft : strokeOriginX;
  final overlapTop = tileTop > strokeOriginY ? tileTop : strokeOriginY;
  final tileRight = tileLeft + Tile.edge;
  final tileBottom = tileTop + Tile.edge;
  final strokeRight = strokeOriginX + strokeWidth;
  final strokeBottom = strokeOriginY + strokeHeight;
  final overlapRight = tileRight < strokeRight ? tileRight : strokeRight;
  final overlapBottom = tileBottom < strokeBottom ? tileBottom : strokeBottom;
  if (overlapLeft >= overlapRight || overlapTop >= overlapBottom) {
    return DebugTileComposite(pixels: output, changed: false);
  }

  for (var documentY = overlapTop; documentY < overlapBottom; documentY += 1) {
    for (
      var documentX = overlapLeft;
      documentX < overlapRight;
      documentX += 1
    ) {
      final sourceOffset =
          ((documentY - strokeOriginY) * strokeWidth +
              documentX -
              strokeOriginX) *
          4;
      final sourceAlpha = strokePixels[sourceOffset + 3];
      if (sourceAlpha == 0) {
        continue;
      }
      final destinationOffset =
          ((documentY - tileTop) * Tile.edge + documentX - tileLeft) * 4;
      final inverseSourceAlpha = 255 - sourceAlpha;
      for (var channel = 0; channel < 3; channel += 1) {
        final next =
            strokePixels[sourceOffset + channel] +
            (output[destinationOffset + channel] * inverseSourceAlpha + 127) ~/
                255;
        final constrained = next > 255 ? 255 : next;
        if (output[destinationOffset + channel] != constrained) {
          changed = true;
          output[destinationOffset + channel] = constrained;
        }
      }
      final nextAlpha =
          sourceAlpha +
          (output[destinationOffset + 3] * inverseSourceAlpha + 127) ~/ 255;
      final constrainedAlpha = nextAlpha > 255 ? 255 : nextAlpha;
      if (output[destinationOffset + 3] != constrainedAlpha) {
        changed = true;
        output[destinationOffset + 3] = constrainedAlpha;
      }
    }
  }
  return DebugTileComposite(pixels: output, changed: changed);
}

/// Current-isolate compositor for tests and other isolate-free environments.
///
/// It delegates all pixel math to the same pure tile primitives used by the
/// cache and raster worker, and owns no ports, timers, or background isolate.
final class InlineRasterCompositor implements RasterCompositor {
  /// Creates an isolate-free compositor.
  const InlineRasterCompositor();

  @override
  Future<RasterCommitResult> compositeDebugStroke({
    required StrokeBufferSnapshot stroke,
    required TileStore tiles,
    required String layerId,
    required Size documentSize,
  }) {
    if (layerId.isEmpty) {
      throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
    }
    if (stroke.isEmpty) {
      return Future<RasterCommitResult>.value(
        RasterCommitResult(changedTiles: const {}, beforeTiles: const {}),
      );
    }
    final affectedKeys = tileKeysCoveringRect(stroke.inkBounds, documentSize);
    final before = <TileKey, Tile?>{
      for (final key in affectedKeys) key: tiles.tile(layerId, key),
    };
    final changed = <TileKey, Tile>{};
    final changedBefore = <TileKey, Tile?>{};
    for (final key in affectedKeys) {
      final Tile? beforeTile = before[key];
      final DebugTileComposite result = compositeDebugStrokeTile(
        key: key,
        beforePixels: beforeTile?.pixels ?? Uint8List(Tile.byteLength),
        strokePixels: stroke.pixels,
        strokeOriginX: stroke.originX,
        strokeOriginY: stroke.originY,
        strokeWidth: stroke.width,
        strokeHeight: stroke.height,
      );
      if (result.changed) {
        changed[key] = Tile.takeOwnership(result.pixels);
        changedBefore[key] = beforeTile;
      }
    }
    return Future<RasterCommitResult>.value(
      RasterCommitResult(changedTiles: changed, beforeTiles: changedBefore),
    );
  }

  @override
  Future<Map<TileKey, Uint8List>> compositeVisibleTiles({
    required List<TileKey> keys,
    required InkDocument document,
    required TileStore tiles,
  }) => Future<Map<TileKey, Uint8List>>.value(
    Map<TileKey, Uint8List>.unmodifiable(<TileKey, Uint8List>{
      for (final key in keys)
        key: compositeVisibleTile(
          key: key,
          layers: document.layers,
          tiles: tiles,
        ),
    }),
  );

  @override
  Future<void> dispose() => Future<void>.value();
}

/// Main-isolate handle for Ink's single reusable raster worker.
final class RasterWorker implements RasterCompositor {
  RasterWorker._({
    required this._isolate,
    required this._commandPort,
    required this._responseTimeout,
  });

  final Isolate _isolate;
  final SendPort _commandPort;
  final Duration _responseTimeout;
  var _disposed = false;

  /// Starts the one long-lived pure-pixel worker isolate.
  static Future<RasterWorker> start({
    Duration responseTimeout = _defaultWorkerTimeout,
  }) async {
    if (responseTimeout <= Duration.zero) {
      throw ArgumentError.value(
        responseTimeout,
        'responseTimeout',
        'must be positive',
      );
    }
    final handshake = ReceivePort('ink-raster-worker-handshake');
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<SendPort>(
        _rasterWorkerMain,
        handshake.sendPort,
        debugName: 'ink-raster-worker',
      );
      final message = await handshake.first.timeout(responseTimeout);
      if (message is! SendPort) {
        throw StateError('Raster worker returned an invalid command port.');
      }
      return RasterWorker._(
        isolate: isolate,
        commandPort: message,
        responseTimeout: responseTimeout,
      );
    } on Object {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      handshake.close();
    }
  }

  /// Composites a sealed debug stroke without mutating [tiles].
  ///
  /// The returned before map contains the exact immutable references currently
  /// in [tiles]. Callers publish [RasterCommitResult.changedTiles], invalidate
  /// those cache keys, then append both maps to the WP1 journal.
  @override
  Future<RasterCommitResult> compositeDebugStroke({
    required StrokeBufferSnapshot stroke,
    required TileStore tiles,
    required String layerId,
    required Size documentSize,
  }) async {
    _checkNotDisposed();
    if (layerId.isEmpty) {
      throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
    }
    if (stroke.isEmpty) {
      return RasterCommitResult(changedTiles: const {}, beforeTiles: const {});
    }
    final affectedKeys = tileKeysCoveringRect(stroke.inkBounds, documentSize);
    final before = <TileKey, Tile?>{
      for (final key in affectedKeys) key: tiles.tile(layerId, key),
    };
    final reply = ReceivePort('ink-raster-composite-reply');
    try {
      _commandPort.send(
        CompositeDebugStrokeCommand(
          replyPort: reply.sendPort,
          strokeOriginX: stroke.originX,
          strokeOriginY: stroke.originY,
          strokeWidth: stroke.width,
          strokeHeight: stroke.height,
          strokePixels: TransferableTypedData.fromList(<TypedData>[
            stroke.pixels,
          ]),
          tiles: <RasterTileInput>[
            for (final key in affectedKeys)
              RasterTileInput(
                x: key.x,
                y: key.y,
                beforePixels: before[key] == null
                    ? null
                    : TransferableTypedData.fromList(<TypedData>[
                        before[key]!.pixels,
                      ]),
              ),
          ],
        ),
      );
      final response = await reply.first.timeout(_responseTimeout);
      if (response case RasterFailureResponse(:final message, :final stack)) {
        throw StateError('Raster worker failed: $message\n$stack');
      }
      if (response is! CompositeDebugStrokeResponse) {
        throw StateError('Raster worker returned an invalid response.');
      }
      final changed = <TileKey, Tile>{};
      final changedBefore = <TileKey, Tile?>{};
      for (final output in response.changedTiles) {
        final key = TileKey(output.x, output.y);
        final pixels = output.pixels.materialize().asUint8List();
        changed[key] = Tile.takeOwnership(pixels);
        changedBefore[key] = before[key];
      }
      return RasterCommitResult(
        changedTiles: changed,
        beforeTiles: changedBefore,
      );
    } finally {
      reply.close();
    }
  }

  /// Flattens more-than-eight visible cache tiles on the long-lived worker.
  ///
  /// This method matches [CompositeBatchBuilder] and can be passed directly to
  /// [CompositeTileCache.batchBuilder]. Image upload remains on the main
  /// isolate after these pure bytes return.
  @override
  Future<Map<TileKey, Uint8List>> compositeVisibleTiles({
    required List<TileKey> keys,
    required InkDocument document,
    required TileStore tiles,
  }) async {
    _checkNotDisposed();
    if (keys.isEmpty) {
      return const <TileKey, Uint8List>{};
    }
    final reply = ReceivePort('ink-raster-cache-reply');
    try {
      _commandPort.send(
        CompositeCacheBatchCommand(
          replyPort: reply.sendPort,
          tiles: <RasterCompositeTileInput>[
            for (final key in keys)
              RasterCompositeTileInput(
                x: key.x,
                y: key.y,
                layers: <RasterCompositeLayerInput>[
                  for (final layer in document.layers)
                    if (layer.visible && layer.opacity != 0)
                      if (tiles.tile(layer.id, key) case final Tile tile)
                        RasterCompositeLayerInput(
                          opacity: layer.opacity,
                          multiply: layer.blend == 'multiply',
                          pixels: TransferableTypedData.fromList(<TypedData>[
                            tile.pixels,
                          ]),
                        ),
                ],
              ),
          ],
        ),
      );
      final response = await reply.first.timeout(_responseTimeout);
      if (response case RasterFailureResponse(:final message, :final stack)) {
        throw StateError('Raster worker failed: $message\n$stack');
      }
      if (response is! CompositeCacheBatchResponse) {
        throw StateError('Raster worker returned an invalid cache response.');
      }
      return Map<TileKey, Uint8List>.unmodifiable(<TileKey, Uint8List>{
        for (final output in response.tiles)
          TileKey(output.x, output.y): output.pixels
              .materialize()
              .asUint8List(),
      });
    } finally {
      reply.close();
    }
  }

  /// Stops the worker after earlier queued commands and releases its isolate.
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final reply = ReceivePort('ink-raster-stop-reply');
    try {
      _commandPort.send(StopRasterWorkerCommand(replyPort: reply.sendPort));
      final response = await reply.first.timeout(_responseTimeout);
      if (response is! RasterStoppedResponse) {
        throw StateError('Raster worker did not acknowledge shutdown.');
      }
    } finally {
      reply.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('RasterWorker has been disposed.');
    }
  }
}

@pragma('vm:entry-point')
void _rasterWorkerMain(SendPort parentPort) {
  final commands = ReceivePort('ink-raster-worker-commands');
  parentPort.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message is StopRasterWorkerCommand) {
      message.replyPort.send(const RasterStoppedResponse());
      commands.close();
      return;
    }
    if (message is CompositeCacheBatchCommand) {
      try {
        final outputs = <RasterTileOutput>[];
        for (final input in message.tiles) {
          final output = Uint8List(Tile.byteLength);
          for (final layer in input.layers) {
            final source = layer.pixels.materialize().asUint8List();
            if (source.lengthInBytes != Tile.byteLength) {
              throw StateError('Worker received a truncated layer tile.');
            }
            _blendWorkerLayer(
              destination: output,
              source: source,
              opacity: layer.opacity,
              multiply: layer.multiply,
            );
          }
          outputs.add(
            RasterTileOutput(
              x: input.x,
              y: input.y,
              pixels: TransferableTypedData.fromList(<TypedData>[output]),
            ),
          );
        }
        message.replyPort.send(CompositeCacheBatchResponse(tiles: outputs));
      } on Object catch (error, stackTrace) {
        message.replyPort.send(
          RasterFailureResponse(
            message: error.toString(),
            stack: stackTrace.toString(),
          ),
        );
      }
      return;
    }
    if (message is! CompositeDebugStrokeCommand) {
      if (message is RasterCommand) {
        message.replyPort.send(
          const RasterFailureResponse(
            message: 'Unsupported raster command',
            stack: '',
          ),
        );
      }
      return;
    }
    try {
      final stroke = message.strokePixels.materialize().asUint8List();
      if (stroke.lengthInBytes !=
          message.strokeWidth * message.strokeHeight * 4) {
        throw StateError('Worker received a truncated stroke payload.');
      }
      final outputs = <RasterTileOutput>[];
      for (final input in message.tiles) {
        final before = input.beforePixels == null
            ? Uint8List(Tile.byteLength)
            : input.beforePixels!.materialize().asUint8List();
        final result = compositeDebugStrokeTile(
          key: TileKey(input.x, input.y),
          beforePixels: before,
          strokePixels: stroke,
          strokeOriginX: message.strokeOriginX,
          strokeOriginY: message.strokeOriginY,
          strokeWidth: message.strokeWidth,
          strokeHeight: message.strokeHeight,
        );
        if (result.changed) {
          outputs.add(
            RasterTileOutput(
              x: input.x,
              y: input.y,
              pixels: TransferableTypedData.fromList(<TypedData>[
                result.pixels,
              ]),
            ),
          );
        }
      }
      message.replyPort.send(
        CompositeDebugStrokeResponse(changedTiles: outputs),
      );
    } on Object catch (error, stackTrace) {
      message.replyPort.send(
        RasterFailureResponse(
          message: error.toString(),
          stack: stackTrace.toString(),
        ),
      );
    }
  });
}

void _blendWorkerLayer({
  required Uint8List destination,
  required Uint8List source,
  required int opacity,
  required bool multiply,
}) {
  for (var offset = 0; offset < destination.length; offset += 4) {
    final sourceAlpha = (source[offset + 3] * opacity + 50) ~/ 100;
    if (sourceAlpha == 0) {
      continue;
    }
    final sourceRed = (source[offset] * opacity + 50) ~/ 100;
    final sourceGreen = (source[offset + 1] * opacity + 50) ~/ 100;
    final sourceBlue = (source[offset + 2] * opacity + 50) ~/ 100;
    final inverseSourceAlpha = 255 - sourceAlpha;
    final destinationAlpha = destination[offset + 3];
    if (multiply) {
      destination[offset] = _workerMultiplyChannel(
        sourceRed,
        sourceAlpha,
        destination[offset],
        destinationAlpha,
      );
      destination[offset + 1] = _workerMultiplyChannel(
        sourceGreen,
        sourceAlpha,
        destination[offset + 1],
        destinationAlpha,
      );
      destination[offset + 2] = _workerMultiplyChannel(
        sourceBlue,
        sourceAlpha,
        destination[offset + 2],
        destinationAlpha,
      );
    } else {
      destination[offset] = _constrainByte(
        sourceRed + (destination[offset] * inverseSourceAlpha + 127) ~/ 255,
      );
      destination[offset + 1] = _constrainByte(
        sourceGreen +
            (destination[offset + 1] * inverseSourceAlpha + 127) ~/ 255,
      );
      destination[offset + 2] = _constrainByte(
        sourceBlue +
            (destination[offset + 2] * inverseSourceAlpha + 127) ~/ 255,
      );
    }
    destination[offset + 3] = _constrainByte(
      sourceAlpha + (destinationAlpha * inverseSourceAlpha + 127) ~/ 255,
    );
  }
}

int _workerMultiplyChannel(
  int source,
  int sourceAlpha,
  int destination,
  int destinationAlpha,
) => _constrainByte(
  (source * (255 - destinationAlpha) +
          destination * (255 - sourceAlpha) +
          source * destination +
          127) ~/
      255,
);

int _constrainByte(int value) => value > 255 ? 255 : value;
