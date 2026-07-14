import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../document/document.dart';
import '../document/tile_store.dart';
import 'canvas_controller.dart';
import 'geometry.dart';

/// Upload function used by the composite cache and injectable in unit tests.
typedef CompositeImageUploader =
    Future<ui.Image> Function(Uint8List pixels, int width, int height);

/// Worker-backed flattening seam used when more than eight tiles rebuild.
typedef CompositeBatchBuilder =
    Future<Map<TileKey, Uint8List>> Function({
      required List<TileKey> keys,
      required InkDocument document,
      required TileStore tiles,
    });

/// Largest cache rebuild performed inline on the input/main isolate.
const int inlineCompositeTileLimit = 8;

/// Uploads premultiplied RGBA8888 bytes to a root-isolate [ui.Image].
Future<ui.Image> uploadRgbaImage(
  Uint8List pixels,
  int width,
  int height,
) async {
  if (width <= 0 || height <= 0 || pixels.lengthInBytes != width * height * 4) {
    throw ArgumentError('RGBA byte length must match positive dimensions.');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Engine-owned repaint signal, independent of application models.
final class CanvasRepaintSignal extends ChangeNotifier {
  /// Requests one canvas repaint after an engine state change.
  void requestRepaint() => notifyListeners();
}

/// Mutable document-space geometry for an isolated stylus-hover ring.
///
/// [update] and [hide] return the conservative union of the old and new ring
/// rectangles so callers can retain small-rectangle damage bookkeeping even
/// though Flutter's repaint signal itself is not rectangle-addressed.
final class BrushHoverCursor {
  Offset? _center;
  double _diameter = 0;
  double _strokeWidth = 1;

  /// Current document-space center, or null while the stylus is absent.
  Offset? get center => _center;

  /// Current brush diameter in document pixels.
  double get diameter => _diameter;

  /// Document-space width that maps to exactly one viewport logical pixel.
  double get strokeWidth => _strokeWidth;

  /// Whether a ring is currently visible.
  bool get isVisible => _center != null;

  /// Moves or resizes the ring and returns its old/new damage union.
  Rect update({
    required Offset center,
    required double diameter,
    required double viewScale,
  }) {
    if (!center.dx.isFinite || !center.dy.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    if (!diameter.isFinite || diameter <= 0) {
      throw ArgumentError.value(
        diameter,
        'diameter',
        'must be finite and positive',
      );
    }
    if (!viewScale.isFinite || viewScale <= 0) {
      throw ArgumentError.value(
        viewScale,
        'viewScale',
        'must be finite and positive',
      );
    }
    final Rect before = bounds;
    _center = center;
    _diameter = diameter;
    _strokeWidth = 1 / viewScale;
    return _unionNonEmpty(before, bounds);
  }

  /// Hides the ring and returns its former damage rectangle.
  Rect hide() {
    final Rect before = bounds;
    _center = null;
    return before;
  }

  /// Conservative document-space ring bounds including antialias fringe.
  Rect get bounds {
    final Offset? center = _center;
    if (center == null) {
      return Rect.zero;
    }
    return Rect.fromCircle(
      center: center,
      radius: _diameter / 2,
    ).inflate(_strokeWidth / 2);
  }
}

/// Paints procedural paper, cached composite tiles, and the live stroke slot.
final class CanvasPainter extends CustomPainter {
  /// Creates the document-space canvas painter.
  CanvasPainter({
    required this.controller,
    required this.cache,
    required this.overlay,
    required Listenable repaint,
    this.paperColor = const Color(0xffffffff),
    this.surroundColor = const Color(0xffffffff),
    this.borderColor = const Color(0xffb4b4b4),
  }) : super(repaint: repaint);

  /// Transform owner used for visibility and gesture filter quality.
  final CanvasController controller;

  /// Flattened visible-layer image cache.
  final CompositeTileCache cache;

  /// Active thresholded two-phase stroke slot.
  final StrokeOverlay overlay;

  /// Procedural canvas background color.
  final Color paperColor;

  /// Viewport color outside the finite artwork. Kept equal to [paperColor] so
  /// the out-of-bounds region does not force gray e-ink refreshes or ghost while
  /// panning; the artwork edge is instead marked by a faint dotted border.
  final Color surroundColor;

  /// Hairline color for the dotted artboard border shown while settled.
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = surroundColor);
    canvas.save();
    canvas.transform(controller.viewMatrix.storage);
    final documentRect = Offset.zero & controller.documentSize;

    canvas.save();
    canvas.clipRect(documentRect);
    canvas.drawRect(documentRect, Paint()..color = paperColor);

    final tilePaint = Paint()
      ..filterQuality = controller.gestureActive
          ? FilterQuality.none
          : FilterQuality.low;
    for (final key in controller.visibleTiles) {
      final entry = cache.lookup(key);
      final image = entry?.image;
      if (image == null) {
        continue;
      }
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        tileDocumentRect(key),
        tilePaint,
      );
    }
    overlay.paint(canvas);
    canvas.restore();

    // Delineate the artboard with a faint dotted border, but only when the view
    // is settled — hiding it during pan/zoom keeps gestures fast and ghost-free.
    if (!controller.gestureActive) {
      _paintArtboardBorder(canvas, documentRect, controller.scale);
    }
    canvas.restore();
  }

  void _paintArtboardBorder(Canvas canvas, Rect rect, double scale) {
    if (scale <= 0 || rect.isEmpty) {
      return;
    }
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / scale
      ..isAntiAlias = false;
    final dash = 9.0 / scale;
    final gap = 7.0 / scale;
    _dashedEdge(canvas, rect.topLeft, rect.topRight, dash, gap, border);
    _dashedEdge(canvas, rect.topRight, rect.bottomRight, dash, gap, border);
    _dashedEdge(canvas, rect.bottomRight, rect.bottomLeft, dash, gap, border);
    _dashedEdge(canvas, rect.bottomLeft, rect.topLeft, dash, gap, border);
  }

  void _dashedEdge(
    Canvas canvas,
    Offset a,
    Offset b,
    double dash,
    double gap,
    Paint paint,
  ) {
    final total = (b - a).distance;
    if (total <= 0) {
      return;
    }
    final direction = (b - a) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final segmentEnd = travelled + dash < total ? travelled + dash : total;
      canvas.drawLine(
        a + direction * travelled,
        a + direction * segmentEnd,
        paint,
      );
      travelled += dash + gap;
    }
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.cache != cache ||
      oldDelegate.overlay != overlay ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.surroundColor != surroundColor ||
      oldDelegate.borderColor != borderColor;
}

/// One flattened tile-position cache entry.
final class CompositeTile {
  CompositeTile._({
    required this.key,
    required Uint8List pixels,
    required this.image,
    required this.isTransparent,
    required this.sourceTiles,
  }) : pixels = pixels.asUnmodifiableView();

  /// Document tile coordinate shared across all source layers.
  final TileKey key;

  /// Flattened premultiplied RGBA8888 pixels.
  final Uint8List pixels;

  /// Lazily uploaded root-isolate image, absent for transparent entries.
  ui.Image? image;

  /// Whether every flattened alpha byte is zero.
  final bool isTransparent;

  /// Layer-order source references used to validate tile-granular freshness.
  final List<Tile?> sourceTiles;

  Future<ui.Image>? _pendingUpload;

  /// Full document-space destination rectangle.
  Rect get documentRect => tileDocumentRect(key);
}

/// Per-tile-position LRU cache of flattened visible Ink layers.
///
/// Layer visibility, opacity, blend, or reorder changes invalidate the entire
/// cache through a property signature. Published tile-reference changes only
/// rebuild the affected coordinate, even if the caller omitted an explicit
/// [invalidate] call.
final class CompositeTileCache {
  /// Creates a cache with a bounded number of tile positions.
  CompositeTileCache({
    this.maxEntries = 256,
    this.batchBuilder,
    CompositeImageUploader? imageUploader,
  }) : _imageUploader = imageUploader ?? uploadRgbaImage {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
  }

  /// Maximum resident composite count before least-recent use eviction.
  final int maxEntries;

  /// Long-lived worker operation used for cache rebuilds above eight tiles.
  final CompositeBatchBuilder? batchBuilder;
  final CompositeImageUploader _imageUploader;
  final LinkedHashMap<TileKey, CompositeTile> _entries = LinkedHashMap();
  int? _layerSignature;
  var _generation = 0;
  var _disposed = false;

  /// Current number of resident tile positions.
  int get length => _entries.length;

  /// Immutable least-to-most-recent key snapshot.
  List<TileKey> get keys => List<TileKey>.unmodifiable(_entries.keys);

  /// Returns a cached entry and promotes it to most-recently used.
  CompositeTile? lookup(TileKey key) {
    _checkNotDisposed();
    final entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry;
    }
    return entry;
  }

  /// Ensures [key] is flattened and, by default, uploaded as an image.
  ///
  /// Setting [uploadImage] false keeps tests and offscreen preparation in pure
  /// pixel space. A later call with true lazily uploads the same pixels.
  Future<CompositeTile> ensureTile({
    required TileKey key,
    required InkDocument document,
    required TileStore tiles,
    bool uploadImage = true,
  }) async {
    _checkNotDisposed();
    final signature = _signatureForLayers(document.layers);
    if (_layerSignature != null && _layerSignature != signature) {
      invalidateAll();
    }
    _layerSignature = signature;

    final sources = _visibleSourceTiles(key, document.layers, tiles);
    var entry = _entries.remove(key);
    if (entry != null && !_sameSources(entry.sourceTiles, sources)) {
      _disposeEntry(entry);
      entry = null;
    }
    if (entry == null) {
      final pixels = compositeVisibleTile(
        key: key,
        layers: document.layers,
        tiles: tiles,
      );
      entry = CompositeTile._(
        key: key,
        pixels: pixels,
        image: null,
        isTransparent: _pixelsAreTransparent(pixels),
        sourceTiles: List<Tile?>.unmodifiable(sources),
      );
    }
    _entries[key] = entry;
    _enforceCapacity();

    await _uploadIfNeeded(entry, uploadImage: uploadImage);
    return entry;
  }

  /// Builds at most eight missing coordinates inline, or delegates to a worker.
  Future<List<CompositeTile>> ensureTiles({
    required Iterable<TileKey> keys,
    required InkDocument document,
    required TileStore tiles,
    bool uploadImages = true,
  }) async {
    _checkNotDisposed();
    final requested = keys.toSet().toList(growable: false);
    final signature = _signatureForLayers(document.layers);
    if (_layerSignature != null && _layerSignature != signature) {
      invalidateAll();
    }
    _layerSignature = signature;
    final operationGeneration = _generation;

    final sourcesByKey = <TileKey, List<Tile?>>{};
    final resultByKey = <TileKey, CompositeTile>{};
    final rebuild = <TileKey>[];
    for (final key in requested) {
      final sources = _visibleSourceTiles(key, document.layers, tiles);
      sourcesByKey[key] = sources;
      var entry = _entries.remove(key);
      if (entry != null && !_sameSources(entry.sourceTiles, sources)) {
        _disposeEntry(entry);
        entry = null;
      }
      if (entry == null) {
        rebuild.add(key);
      } else {
        _entries[key] = entry;
        resultByKey[key] = entry;
      }
    }

    Map<TileKey, Uint8List>? workerPixels;
    if (rebuild.length > inlineCompositeTileLimit) {
      final builder = batchBuilder;
      if (builder == null) {
        throw StateError(
          'A CompositeBatchBuilder is required to rebuild more than '
          '$inlineCompositeTileLimit tiles.',
        );
      }
      workerPixels = Map<TileKey, Uint8List>.of(
        await builder(
          keys: List<TileKey>.unmodifiable(rebuild),
          document: document,
          tiles: tiles,
        ),
      );
      _ensureBatchCurrent(operationGeneration, signature);
      final stale = <TileKey>[];
      for (final key in rebuild) {
        final currentSources = _visibleSourceTiles(key, document.layers, tiles);
        if (!_sameSources(sourcesByKey[key]!, currentSources)) {
          sourcesByKey[key] = currentSources;
          stale.add(key);
        }
      }
      if (stale.length > inlineCompositeTileLimit) {
        workerPixels.addAll(
          await builder(keys: stale, document: document, tiles: tiles),
        );
        _ensureBatchCurrent(operationGeneration, signature);
      } else {
        for (final key in stale) {
          workerPixels[key] = compositeVisibleTile(
            key: key,
            layers: document.layers,
            tiles: tiles,
          );
        }
      }
      // Any key can change during the optional retry await, including keys
      // that were fresh after the first response. Revalidate the full batch.
      for (final key in rebuild) {
        final currentSources = _visibleSourceTiles(key, document.layers, tiles);
        if (!_sameSources(sourcesByKey[key]!, currentSources)) {
          sourcesByKey[key] = currentSources;
          workerPixels[key] = compositeVisibleTile(
            key: key,
            layers: document.layers,
            tiles: tiles,
          );
        }
      }
    }
    for (final key in rebuild) {
      final existing = _entries.remove(key);
      if (existing != null &&
          _sameSources(existing.sourceTiles, sourcesByKey[key]!)) {
        _entries[key] = existing;
        resultByKey[key] = existing;
        continue;
      }
      if (existing != null) {
        _disposeEntry(existing);
      }
      final pixels =
          workerPixels?[key] ??
          (workerPixels == null
              ? compositeVisibleTile(
                  key: key,
                  layers: document.layers,
                  tiles: tiles,
                )
              : throw StateError('Composite worker omitted $key.'));
      final entry = CompositeTile._(
        key: key,
        pixels: pixels,
        image: null,
        isTransparent: _pixelsAreTransparent(pixels),
        sourceTiles: List<Tile?>.unmodifiable(sourcesByKey[key]!),
      );
      _entries[key] = entry;
      resultByKey[key] = entry;
    }
    _enforceCapacity();

    final result = <CompositeTile>[];
    for (final key in requested) {
      final entry = resultByKey[key]!;
      await _uploadIfNeeded(entry, uploadImage: uploadImages);
      result.add(entry);
    }
    return List<CompositeTile>.unmodifiable(result);
  }

  /// Invalidates exactly one tile position and disposes its uploaded image.
  bool invalidate(TileKey key) {
    _checkNotDisposed();
    final entry = _entries.remove(key);
    if (entry == null) {
      return false;
    }
    _disposeEntry(entry);
    return true;
  }

  /// Invalidates a batch of tile positions.
  int invalidateTiles(Iterable<TileKey> keys) {
    var count = 0;
    for (final key in keys.toSet()) {
      if (invalidate(key)) {
        count += 1;
      }
    }
    return count;
  }

  /// Invalidates every composite, as required by layer property changes.
  void invalidateAll() {
    _checkNotDisposed();
    _generation += 1;
    for (final entry in _entries.values) {
      _disposeEntry(entry);
    }
    _entries.clear();
    _layerSignature = null;
  }

  /// Evicts cached positions beyond the current viewport tile neighborhood.
  ///
  /// [marginTiles] retains an optional grid ring for small subsequent pans.
  int evictOutsideViewport(
    Iterable<TileKey> visibleKeys, {
    int marginTiles = 0,
  }) {
    _checkNotDisposed();
    if (marginTiles < 0) {
      throw ArgumentError.value(
        marginTiles,
        'marginTiles',
        'must not be negative',
      );
    }
    final retained = <TileKey>{};
    for (final key in visibleKeys) {
      for (var y = key.y - marginTiles; y <= key.y + marginTiles; y += 1) {
        for (var x = key.x - marginTiles; x <= key.x + marginTiles; x += 1) {
          retained.add(TileKey(x, y));
        }
      }
    }
    final evicted = <TileKey>[
      for (final key in _entries.keys)
        if (!retained.contains(key)) key,
    ];
    for (final key in evicted) {
      invalidate(key);
    }
    return evicted.length;
  }

  /// Releases every root-isolate image and makes this cache unusable.
  void dispose() {
    if (_disposed) {
      return;
    }
    for (final entry in _entries.values) {
      _disposeEntry(entry);
    }
    _entries.clear();
    _generation += 1;
    _disposed = true;
  }

  void _enforceCapacity() {
    while (_entries.length > maxEntries) {
      final oldest = _entries.entries.first;
      _entries.remove(oldest.key);
      _disposeEntry(oldest.value);
    }
  }

  Future<void> _uploadIfNeeded(
    CompositeTile entry, {
    required bool uploadImage,
  }) async {
    if (!uploadImage || entry.isTransparent || entry.image != null) {
      return;
    }
    final existingUpload = entry._pendingUpload;
    if (existingUpload != null) {
      await existingUpload;
      return;
    }
    final upload = _imageUploader(entry.pixels, Tile.edge, Tile.edge);
    entry._pendingUpload = upload;
    try {
      final image = await upload;
      if (_disposed || !identical(_entries[entry.key], entry)) {
        image.dispose();
      } else {
        entry.image = image;
      }
    } finally {
      if (identical(entry._pendingUpload, upload)) {
        entry._pendingUpload = null;
      }
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('CompositeTileCache has been disposed.');
    }
  }

  void _ensureBatchCurrent(int generation, int signature) {
    if (_disposed) {
      throw StateError('CompositeTileCache was disposed during a rebuild.');
    }
    if (_generation != generation || _layerSignature != signature) {
      throw StateError('Composite tile rebuild was superseded.');
    }
  }

  static void _disposeEntry(CompositeTile entry) {
    entry.image?.dispose();
    entry.image = null;
  }
}

/// Flattens every visible layer at [key] into premultiplied RGBA8888.
Uint8List compositeVisibleTile({
  required TileKey key,
  required Iterable<InkLayer> layers,
  required TileStore tiles,
}) {
  final output = Uint8List(Tile.byteLength);
  for (final layer in layers) {
    if (!layer.visible || layer.opacity == 0) {
      continue;
    }
    final source = tiles.tile(layer.id, key);
    if (source == null) {
      continue;
    }
    _blendPremultiplied(
      destination: output,
      source: source.pixels,
      opacity: layer.opacity,
      multiply: layer.blend == 'multiply',
    );
  }
  return output;
}

/// Flattens [layers] into a sparse, immutable tile map.
///
/// Layer order, visibility, opacity, and the `normal`/`multiply` blend
/// identifiers use the same rules as [compositeVisibleTile]. Fully transparent
/// results are omitted so structural operations do not turn sparse content
/// into resident blank tiles.
Map<TileKey, Tile> compositeLayerStack({
  required Iterable<InkLayer> layers,
  required TileStore tiles,
}) {
  final orderedLayers = List<InkLayer>.of(layers);
  final keys = <TileKey>{
    for (final layer in orderedLayers) ...tiles.occupiedKeys(layer.id),
  }.toList()..sort();
  final output = <TileKey, Tile>{};
  for (final key in keys) {
    final tile = Tile.takeOwnership(
      compositeVisibleTile(key: key, layers: orderedLayers, tiles: tiles),
    );
    if (!tile.isTransparent) {
      output[key] = tile;
    }
  }
  return Map<TileKey, Tile>.unmodifiable(output);
}

List<Tile?> _visibleSourceTiles(
  TileKey key,
  Iterable<InkLayer> layers,
  TileStore tiles,
) => <Tile?>[
  for (final layer in layers)
    if (layer.visible && layer.opacity != 0) tiles.tile(layer.id, key),
];

int _signatureForLayers(Iterable<InkLayer> layers) => Object.hashAll(<Object>[
  for (final layer in layers)
    Object.hash(layer.id, layer.visible, layer.opacity, layer.blend),
]);

bool _sameSources(List<Tile?> left, List<Tile?> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!identical(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool _pixelsAreTransparent(Uint8List pixels) {
  for (var offset = 3; offset < pixels.length; offset += 4) {
    if (pixels[offset] != 0) {
      return false;
    }
  }
  return true;
}

void _blendPremultiplied({
  required Uint8List destination,
  required Uint8List source,
  required int opacity,
  required bool multiply,
}) {
  assert(destination.length == source.length);
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
      destination[offset] = _multiplyChannel(
        sourceRed,
        sourceAlpha,
        destination[offset],
        destinationAlpha,
      );
      destination[offset + 1] = _multiplyChannel(
        sourceGreen,
        sourceAlpha,
        destination[offset + 1],
        destinationAlpha,
      );
      destination[offset + 2] = _multiplyChannel(
        sourceBlue,
        sourceAlpha,
        destination[offset + 2],
        destinationAlpha,
      );
    } else {
      destination[offset] = math.min(
        255,
        sourceRed + (destination[offset] * inverseSourceAlpha + 127) ~/ 255,
      );
      destination[offset + 1] = math.min(
        255,
        sourceGreen +
            (destination[offset + 1] * inverseSourceAlpha + 127) ~/ 255,
      );
      destination[offset + 2] = math.min(
        255,
        sourceBlue +
            (destination[offset + 2] * inverseSourceAlpha + 127) ~/ 255,
      );
    }
    destination[offset + 3] = math.min(
      255,
      sourceAlpha + (destinationAlpha * inverseSourceAlpha + 127) ~/ 255,
    );
  }
}

int _multiplyChannel(
  int source,
  int sourceAlpha,
  int destination,
  int destinationAlpha,
) => math.min(
  255,
  (source * (255 - destinationAlpha) +
          destination * (255 - sourceAlpha) +
          source * destination +
          127) ~/
      255,
);

/// Optional per-pixel modifier for a generic brush stamp.
///
/// The callback receives integer document coordinates and antialiased nib
/// coverage, and returns the coverage that should be blended at that pixel.
typedef StrokeCoverageModifier =
    double Function(int documentX, int documentY, double coverage);

/// Mutable, tile-aligned document-space scratch raster for one active stroke.
final class StrokeBuffer {
  /// Creates an empty stroke scratch buffer, optionally clipped to a document.
  StrokeBuffer({Size? documentSize}) : _documentSize = documentSize {
    if (documentSize != null &&
        (!documentSize.width.isFinite ||
            !documentSize.height.isFinite ||
            documentSize.width <= 0 ||
            documentSize.height <= 0)) {
      throw ArgumentError.value(
        documentSize,
        'documentSize',
        'must be finite and non-empty',
      );
    }
  }

  final Size? _documentSize;
  Uint8List _pixels = Uint8List(0);
  var _left = 0;
  var _top = 0;
  var _width = 0;
  var _height = 0;
  var _sealed = false;
  Rect? _inkBounds;

  /// Whether no stamp has contributed visible alpha.
  bool get isEmpty => _inkBounds == null;

  /// Whether [seal] has made this buffer immutable.
  bool get isSealed => _sealed;

  /// Tile-aligned allocated document-space extent.
  Rect get bounds => Rect.fromLTWH(
    _left.toDouble(),
    _top.toDouble(),
    _width.toDouble(),
    _height.toDouble(),
  );

  /// Tight conservative union of submitted stamp rectangles.
  Rect get inkBounds => _inkBounds ?? Rect.zero;

  /// Allocated scratch width.
  int get width => _width;

  /// Allocated scratch height.
  int get height => _height;

  /// Read-only live pixel view for preview generation.
  Uint8List get pixels => _pixels.asUnmodifiableView();

  /// Copies and thresholds only [changedBounds] for an active preview frame.
  ///
  /// Unlike [snapshot], this never copies the tile-aligned scratch outside the
  /// dirty rectangle, keeping preview work independent of total stroke length.
  ThresholdedStrokeRegion thresholdedRegion(
    Rect changedBounds, {
    double alphaCutoff = 0.5,
    int previewColorArgb = 0xff000000,
  }) => _thresholdRegion(
    sourcePixels: _pixels,
    originX: _left,
    originY: _top,
    sourceWidth: _width,
    sourceHeight: _height,
    changedBounds: changedBounds,
    alphaCutoff: alphaCutoff,
    previewColorArgb: previewColorArgb,
  );

  /// Blends one anti-aliased round debug stamp and returns its clipped bounds.
  Rect stampRound({
    required Offset center,
    double diameter = 8,
    int colorArgb = 0xff000000,
    double flow = 1,
  }) {
    if (_sealed) {
      throw StateError('A sealed StrokeBuffer cannot accept more stamps.');
    }
    if (!center.dx.isFinite || !center.dy.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    if (!diameter.isFinite || diameter <= 0) {
      throw ArgumentError.value(
        diameter,
        'diameter',
        'must be finite and positive',
      );
    }
    if (!flow.isFinite || flow < 0 || flow > 1) {
      throw RangeError.range(flow, 0, 1, 'flow');
    }
    final radius = diameter / 2;
    var stampBounds = Rect.fromCircle(center: center, radius: radius + 0.5);
    if (_documentSize != null) {
      stampBounds = stampBounds.intersect(Offset.zero & _documentSize);
    }
    if (stampBounds.isEmpty || flow == 0 || (colorArgb >>> 24) == 0) {
      return Rect.zero;
    }
    _ensureAllocated(stampBounds);

    final startX = stampBounds.left.floor();
    final startY = stampBounds.top.floor();
    final endX = stampBounds.right.ceil();
    final endY = stampBounds.bottom.ceil();
    var wroteAlpha = false;
    for (var y = startY; y < endY; y += 1) {
      for (var x = startX; x < endX; x += 1) {
        final distance = (Offset(x + 0.5, y + 0.5) - center).distance;
        final coverage = (radius + 0.5 - distance).clamp(0.0, 1.0) * flow;
        if (coverage <= 0) {
          continue;
        }
        final sourceAlpha = (((colorArgb >>> 24) & 0xff) * coverage).round();
        if (sourceAlpha == 0) {
          continue;
        }
        final offset = ((y - _top) * _width + (x - _left)) * 4;
        _blendColorAt(offset, colorArgb, sourceAlpha);
        wroteAlpha = true;
      }
    }
    if (wroteAlpha) {
      _inkBounds = _inkBounds == null
          ? stampBounds
          : _inkBounds!.expandToInclude(stampBounds);
      return stampBounds;
    }
    return Rect.zero;
  }

  /// Blends one rotated elliptical stamp with an optional coverage modifier.
  ///
  /// A disc is represented by equal diameters. Grain implementations use
  /// [modifyCoverage] to attenuate the true settle-form alpha at fixed
  /// document coordinates without changing the live preview contract.
  Rect stampEllipse({
    required Offset center,
    required double diameterX,
    required double diameterY,
    double angleRadians = 0,
    int colorArgb = 0xff000000,
    double flow = 1,
    StrokeCoverageModifier? modifyCoverage,
  }) {
    if (_sealed) {
      throw StateError('A sealed StrokeBuffer cannot accept more stamps.');
    }
    if (!center.dx.isFinite || !center.dy.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    if (!diameterX.isFinite || diameterX <= 0) {
      throw ArgumentError.value(
        diameterX,
        'diameterX',
        'must be finite and positive',
      );
    }
    if (!diameterY.isFinite || diameterY <= 0) {
      throw ArgumentError.value(
        diameterY,
        'diameterY',
        'must be finite and positive',
      );
    }
    if (!angleRadians.isFinite) {
      throw ArgumentError.value(angleRadians, 'angleRadians', 'must be finite');
    }
    if (!flow.isFinite || flow < 0 || flow > 1) {
      throw RangeError.range(flow, 0, 1, 'flow');
    }
    if (flow == 0 || (colorArgb >>> 24) == 0) {
      return Rect.zero;
    }

    final double radiusX = diameterX / 2;
    final double radiusY = diameterY / 2;
    final double cosine = math.cos(angleRadians).abs();
    final double sine = math.sin(angleRadians).abs();
    final double axisAlignedRadiusX = math.sqrt(
      radiusX * radiusX * cosine * cosine + radiusY * radiusY * sine * sine,
    );
    final double axisAlignedRadiusY = math.sqrt(
      radiusX * radiusX * sine * sine + radiusY * radiusY * cosine * cosine,
    );
    var stampBounds = Rect.fromCenter(
      center: center,
      width: axisAlignedRadiusX * 2 + 1,
      height: axisAlignedRadiusY * 2 + 1,
    );
    if (_documentSize != null) {
      stampBounds = stampBounds.intersect(Offset.zero & _documentSize);
    }
    if (stampBounds.isEmpty) {
      return Rect.zero;
    }
    _ensureAllocated(stampBounds);

    final double cosineSigned = math.cos(angleRadians);
    final double sineSigned = math.sin(angleRadians);
    final int startX = stampBounds.left.floor();
    final int startY = stampBounds.top.floor();
    final int endX = stampBounds.right.ceil();
    final int endY = stampBounds.bottom.ceil();
    var wroteAlpha = false;
    for (var y = startY; y < endY; y += 1) {
      for (var x = startX; x < endX; x += 1) {
        final double deltaX = x + 0.5 - center.dx;
        final double deltaY = y + 0.5 - center.dy;
        final double localX = deltaX * cosineSigned + deltaY * sineSigned;
        final double localY = -deltaX * sineSigned + deltaY * cosineSigned;
        final double normalizedDistance = math.sqrt(
          localX * localX / (radiusX * radiusX) +
              localY * localY / (radiusY * radiusY),
        );
        final double gradientLength = normalizedDistance == 0
            ? 0
            : math.sqrt(
                    localX * localX / math.pow(radiusX, 4) +
                        localY * localY / math.pow(radiusY, 4),
                  ) /
                  normalizedDistance;
        final double signedEdgeDistance = gradientLength == 0
            ? math.min(radiusX, radiusY)
            : (1 - normalizedDistance) / gradientLength;
        var coverage = (signedEdgeDistance + 0.5).clamp(0.0, 1.0).toDouble();
        if (coverage <= 0) {
          continue;
        }
        coverage = (modifyCoverage?.call(x, y, coverage) ?? coverage)
            .clamp(0.0, 1.0)
            .toDouble();
        coverage *= flow;
        if (coverage <= 0) {
          continue;
        }
        final int sourceAlpha = (((colorArgb >>> 24) & 0xff) * coverage)
            .round();
        if (sourceAlpha == 0) {
          continue;
        }
        final int offset = ((y - _top) * _width + (x - _left)) * 4;
        _blendColorAt(offset, colorArgb, sourceAlpha);
        wroteAlpha = true;
      }
    }
    if (!wroteAlpha) {
      return Rect.zero;
    }
    _inkBounds = _inkBounds == null
        ? stampBounds
        : _inkBounds!.expandToInclude(stampBounds);
    return stampBounds;
  }

  /// Snaps settle-form coverage to [levels] nontransparent alpha steps.
  ///
  /// Premultiplied color channels are rescaled with alpha. This runs once at
  /// stroke finalization, after overlapping stamps have accumulated, so the
  /// published raster itself—not merely each individual stamp—honors the
  /// brush's `quantizeLevels` contract.
  void quantizeAlphaLevels(int levels) {
    if (_sealed) {
      throw StateError('A sealed StrokeBuffer cannot be quantized.');
    }
    if (levels <= 0 || levels > 255) {
      throw RangeError.range(levels, 1, 255, 'levels');
    }
    var hasVisiblePixel = false;
    for (var offset = 0; offset < _pixels.length; offset += 4) {
      final int alpha = _pixels[offset + 3];
      if (alpha == 0) {
        continue;
      }
      final int quantized = ((alpha * levels / 255).round() * 255 / levels)
          .round()
          .clamp(0, 255);
      if (quantized == 0) {
        _pixels[offset] = 0;
        _pixels[offset + 1] = 0;
        _pixels[offset + 2] = 0;
        _pixels[offset + 3] = 0;
        continue;
      }
      for (var channel = 0; channel < 3; channel += 1) {
        _pixels[offset +
            channel] = (_pixels[offset + channel] * quantized / alpha)
            .round()
            .clamp(0, quantized);
      }
      _pixels[offset + 3] = quantized;
      hasVisiblePixel = true;
    }
    if (!hasVisiblePixel) {
      _inkBounds = null;
    }
  }

  /// Returns an immutable copy without ending the active stroke.
  StrokeBufferSnapshot snapshot() => StrokeBufferSnapshot._(
    originX: _left,
    originY: _top,
    width: _width,
    height: _height,
    pixels: Uint8List.fromList(_pixels),
    inkBounds: inkBounds,
  );

  /// Seals the stroke and returns an immutable commit payload.
  StrokeBufferSnapshot seal() {
    _sealed = true;
    return StrokeBufferSnapshot._(
      originX: _left,
      originY: _top,
      width: _width,
      height: _height,
      pixels: _pixels,
      inkBounds: inkBounds,
    );
  }

  void _ensureAllocated(Rect requested) {
    final nextLeft = math.min(
      _width == 0 ? requested.left.floor() : _left,
      (requested.left / Tile.edge).floor() * Tile.edge,
    );
    final nextTop = math.min(
      _height == 0 ? requested.top.floor() : _top,
      (requested.top / Tile.edge).floor() * Tile.edge,
    );
    final requestedRight = (requested.right / Tile.edge).ceil() * Tile.edge;
    final requestedBottom = (requested.bottom / Tile.edge).ceil() * Tile.edge;
    final nextRight = math.max(_left + _width, requestedRight);
    final nextBottom = math.max(_top + _height, requestedBottom);
    final nextWidth = nextRight - nextLeft;
    final nextHeight = nextBottom - nextTop;
    if (nextLeft == _left &&
        nextTop == _top &&
        nextWidth == _width &&
        nextHeight == _height) {
      return;
    }
    final next = Uint8List(nextWidth * nextHeight * 4);
    if (_width != 0 && _height != 0) {
      final destinationX = _left - nextLeft;
      final destinationY = _top - nextTop;
      for (var row = 0; row < _height; row += 1) {
        final sourceStart = row * _width * 4;
        final destinationStart =
            ((row + destinationY) * nextWidth + destinationX) * 4;
        next.setRange(
          destinationStart,
          destinationStart + _width * 4,
          _pixels,
          sourceStart,
        );
      }
    }
    _left = nextLeft;
    _top = nextTop;
    _width = nextWidth;
    _height = nextHeight;
    _pixels = next;
  }

  void _blendColorAt(int offset, int colorArgb, int sourceAlpha) {
    final inverseSourceAlpha = 255 - sourceAlpha;
    final red = (colorArgb >>> 16) & 0xff;
    final green = (colorArgb >>> 8) & 0xff;
    final blue = colorArgb & 0xff;
    final sourceRed = (red * sourceAlpha + 127) ~/ 255;
    final sourceGreen = (green * sourceAlpha + 127) ~/ 255;
    final sourceBlue = (blue * sourceAlpha + 127) ~/ 255;
    _pixels[offset] = math.min(
      255,
      sourceRed + (_pixels[offset] * inverseSourceAlpha + 127) ~/ 255,
    );
    _pixels[offset + 1] = math.min(
      255,
      sourceGreen + (_pixels[offset + 1] * inverseSourceAlpha + 127) ~/ 255,
    );
    _pixels[offset + 2] = math.min(
      255,
      sourceBlue + (_pixels[offset + 2] * inverseSourceAlpha + 127) ~/ 255,
    );
    _pixels[offset + 3] = math.min(
      255,
      sourceAlpha + (_pixels[offset + 3] * inverseSourceAlpha + 127) ~/ 255,
    );
  }
}

/// Immutable stroke-buffer payload used by overlays and worker commits.
final class StrokeBufferSnapshot {
  StrokeBufferSnapshot._({
    required this.originX,
    required this.originY,
    required this.width,
    required this.height,
    required Uint8List pixels,
    required this.inkBounds,
  }) : pixels = pixels.asUnmodifiableView();

  /// Allocated document-space left edge.
  final int originX;

  /// Allocated document-space top edge.
  final int originY;

  /// Allocated pixel width.
  final int width;

  /// Allocated pixel height.
  final int height;

  /// Immutable premultiplied RGBA8888 payload.
  final Uint8List pixels;

  /// Tight conservative stroke extent.
  final Rect inkBounds;

  /// Tile-aligned allocated extent.
  Rect get bounds => Rect.fromLTWH(
    originX.toDouble(),
    originY.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );

  /// Whether the snapshot contains no visible stroke.
  bool get isEmpty => width == 0 || height == 0 || inkBounds.isEmpty;
}

/// WP2-only fixed-width round stamper used until real brush engines land.
final class DebugRoundStamper {
  /// Creates a deterministic debug stamper.
  const DebugRoundStamper({
    this.width = 8,
    this.colorArgb = 0xff000000,
    this.flow = 1,
    this.spacingFactor = 0.25,
  });

  /// Fixed document-pixel stamp diameter.
  final double width;

  /// Stamp color in ARGB form.
  final int colorArgb;

  /// Per-stamp opacity multiplier.
  final double flow;

  /// Center spacing as a fraction of [width].
  final double spacingFactor;

  /// Places one round stamp.
  Rect stamp(StrokeBuffer buffer, Offset point) => buffer.stampRound(
    center: point,
    diameter: width,
    colorArgb: colorArgb,
    flow: flow,
  );

  /// Places evenly spaced stamps along a document-space segment.
  void stampSegment(StrokeBuffer buffer, Offset from, Offset to) {
    final distance = (to - from).distance;
    final spacing = math.max(0.25, width * spacingFactor);
    final steps = math.max(1, (distance / spacing).ceil());
    for (var step = 1; step <= steps; step += 1) {
      stamp(buffer, Offset.lerp(from, to, step / steps)!);
    }
  }
}

/// Converts an RGBA stroke into the pure-black two-phase preview payload.
Uint8List thresholdStrokePixels(
  Uint8List pixels, {
  double alphaCutoff = 0.5,
  int previewColorArgb = 0xff000000,
}) {
  if (pixels.length % 4 != 0) {
    throw ArgumentError.value(
      pixels.length,
      'pixels.length',
      'must be a multiple of four',
    );
  }
  if (!alphaCutoff.isFinite || alphaCutoff < 0 || alphaCutoff > 1) {
    throw RangeError.range(alphaCutoff, 0, 1, 'alphaCutoff');
  }
  final cutoffByte = (alphaCutoff * 255).ceil();
  final result = Uint8List(pixels.length);
  for (var offset = 0; offset < pixels.length; offset += 4) {
    final int sourceAlpha = pixels[offset + 3];
    if (sourceAlpha != 0 && sourceAlpha >= cutoffByte) {
      _writeOpaquePreviewPixel(result, offset, previewColorArgb);
    }
  }
  return result;
}

/// One thresholded changed sub-rectangle ready for image upload.
final class ThresholdedStrokeRegion {
  /// Creates a thresholded preview region.
  ThresholdedStrokeRegion({
    required this.bounds,
    required this.width,
    required this.height,
    required Uint8List pixels,
  }) : pixels = pixels.asUnmodifiableView();

  /// Integer-aligned document-space patch bounds.
  final Rect bounds;

  /// Patch width in pixels.
  final int width;

  /// Patch height in pixels.
  final int height;

  /// Pure-black premultiplied RGBA8888 patch pixels.
  final Uint8List pixels;

  /// Whether the requested region did not intersect allocated stroke pixels.
  bool get isEmpty => width == 0 || height == 0;
}

/// Extracts and thresholds only [changedBounds] from [snapshot].
ThresholdedStrokeRegion thresholdStrokeRegion(
  StrokeBufferSnapshot snapshot,
  Rect changedBounds, {
  double alphaCutoff = 0.5,
  int previewColorArgb = 0xff000000,
}) => _thresholdRegion(
  sourcePixels: snapshot.pixels,
  originX: snapshot.originX,
  originY: snapshot.originY,
  sourceWidth: snapshot.width,
  sourceHeight: snapshot.height,
  changedBounds: changedBounds,
  alphaCutoff: alphaCutoff,
  previewColorArgb: previewColorArgb,
);

ThresholdedStrokeRegion _thresholdRegion({
  required Uint8List sourcePixels,
  required int originX,
  required int originY,
  required int sourceWidth,
  required int sourceHeight,
  required Rect changedBounds,
  required double alphaCutoff,
  required int previewColorArgb,
}) {
  if (!alphaCutoff.isFinite || alphaCutoff < 0 || alphaCutoff > 1) {
    throw RangeError.range(alphaCutoff, 0, 1, 'alphaCutoff');
  }
  final bufferBounds = Rect.fromLTWH(
    originX.toDouble(),
    originY.toDouble(),
    sourceWidth.toDouble(),
    sourceHeight.toDouble(),
  );
  final clipped = changedBounds.intersect(bufferBounds);
  if (clipped.isEmpty) {
    return ThresholdedStrokeRegion(
      bounds: Rect.zero,
      width: 0,
      height: 0,
      pixels: Uint8List(0),
    );
  }
  final left = math.max(originX, clipped.left.floor());
  final top = math.max(originY, clipped.top.floor());
  final right = math.min(originX + sourceWidth, clipped.right.ceil());
  final bottom = math.min(originY + sourceHeight, clipped.bottom.ceil());
  final patchWidth = right - left;
  final patchHeight = bottom - top;
  if (patchWidth <= 0 || patchHeight <= 0) {
    return ThresholdedStrokeRegion(
      bounds: Rect.zero,
      width: 0,
      height: 0,
      pixels: Uint8List(0),
    );
  }
  final patchPixels = Uint8List(patchWidth * patchHeight * 4);
  final cutoffByte = (alphaCutoff * 255).ceil();
  for (var row = 0; row < patchHeight; row += 1) {
    for (var column = 0; column < patchWidth; column += 1) {
      final sourceOffset =
          ((top - originY + row) * sourceWidth + left - originX + column) * 4;
      final int sourceAlpha = sourcePixels[sourceOffset + 3];
      if (sourceAlpha != 0 && sourceAlpha >= cutoffByte) {
        _writeOpaquePreviewPixel(
          patchPixels,
          (row * patchWidth + column) * 4,
          previewColorArgb,
        );
      }
    }
  }
  return ThresholdedStrokeRegion(
    bounds: Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      patchWidth.toDouble(),
      patchHeight.toDouble(),
    ),
    width: patchWidth,
    height: patchHeight,
    pixels: patchPixels,
  );
}

void _writeOpaquePreviewPixel(Uint8List pixels, int offset, int colorArgb) {
  pixels[offset] = (colorArgb >>> 16) & 0xff;
  pixels[offset + 1] = (colorArgb >>> 8) & 0xff;
  pixels[offset + 2] = colorArgb & 0xff;
  pixels[offset + 3] = 255;
}

final class _StrokeOverlayPatch {
  const _StrokeOverlayPatch({
    required this.tileKey,
    required this.bounds,
    required this.image,
  });

  final TileKey tileKey;
  final Rect bounds;
  final ui.Image image;
}

typedef _ThresholdRegionReader = ThresholdedStrokeRegion Function(Rect bounds);

/// Lazily uploaded thresholded images for the active two-phase stroke slot.
final class StrokeOverlay {
  /// Creates an overlay with a brush-class preview threshold.
  StrokeOverlay({
    double alphaCutoff = 0.5,
    int previewColorArgb = 0xff000000,
    bool outline = false,
    this.maxPatchesPerTile = 8,
    CompositeImageUploader? imageUploader,
  }) : _alphaCutoff = alphaCutoff,
       // Public named parameters intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _previewColorArgb = previewColorArgb,
       // ignore: prefer_initializing_formals
       _outline = outline,
       _imageUploader = imageUploader ?? uploadRgbaImage {
    if (!alphaCutoff.isFinite || alphaCutoff < 0 || alphaCutoff > 1) {
      throw RangeError.range(alphaCutoff, 0, 1, 'alphaCutoff');
    }
    if (maxPatchesPerTile < 2) {
      throw ArgumentError.value(
        maxPatchesPerTile,
        'maxPatchesPerTile',
        'must be at least two',
      );
    }
  }

  /// Normalized alpha cutoff for black preview pixels.
  double get alphaCutoff => _alphaCutoff;

  /// Opaque ARGB color used for threshold pixels and an optional contour.
  int get previewColorArgb => _previewColorArgb;

  /// Whether the tight stroke AABB receives a one-pixel contour.
  bool get drawsOutline => _outline;

  /// Per-tile draw-call bound before patches consolidate to one tile image.
  final int maxPatchesPerTile;
  final CompositeImageUploader _imageUploader;
  final List<_StrokeOverlayPatch> _patches = <_StrokeOverlayPatch>[];
  double _alphaCutoff;
  int _previewColorArgb;
  bool _outline;
  Rect _bounds = Rect.zero;
  Rect _outlineBounds = Rect.zero;
  var _generation = 0;
  var _disposed = false;
  Future<void> _refreshTail = Future<void>.value();

  /// Current allocated document-space image bounds.
  Rect get bounds => _bounds;

  /// Tight AABB used by outline-style previews.
  Rect get outlineBounds => _outlineBounds;

  /// Number of retained changed-region images for the active stroke.
  int get patchCount => _patches.length;

  /// Whether an uploaded preview is ready to paint.
  bool get hasImage => _patches.isNotEmpty;

  /// Configures the next stroke's threshold form.
  ///
  /// Reconfiguration clears any previous stroke patches so colors and cutoff
  /// values can never mix within one live overlay.
  void configure({
    required double alphaCutoff,
    required int previewColorArgb,
    required bool outline,
  }) {
    _checkNotDisposed();
    if (!alphaCutoff.isFinite || alphaCutoff < 0 || alphaCutoff > 1) {
      throw RangeError.range(alphaCutoff, 0, 1, 'alphaCutoff');
    }
    final bool unchanged =
        _alphaCutoff == alphaCutoff &&
        _previewColorArgb == previewColorArgb &&
        _outline == outline;
    if (unchanged && _patches.isEmpty && _outlineBounds.isEmpty) {
      return;
    }
    clear();
    _alphaCutoff = alphaCutoff;
    _previewColorArgb = previewColorArgb;
    _outline = outline;
  }

  /// Uploads and retains only the changed part of [snapshot].
  ///
  /// Callers should pass the union of stamp bounds added since their preceding
  /// frame. Omitting [changedBounds] is a safe first-frame fallback that uses
  /// the full ink extent, not the larger tile-aligned scratch allocation.
  /// Patches are split on tile boundaries and periodically consolidated per
  /// tile, bounding draw calls for a long stroke by spatial extent, not frames.
  Future<void> refresh(StrokeBufferSnapshot snapshot, {Rect? changedBounds}) {
    _checkNotDisposed();
    if (snapshot.isEmpty) {
      clear();
      return Future<void>.value();
    }
    _outlineBounds = snapshot.inkBounds;
    return _queueRefresh(
      bufferBounds: snapshot.bounds,
      dirty: changedBounds ?? snapshot.inkBounds,
      readRegion: (bounds) => thresholdStrokeRegion(
        snapshot,
        bounds,
        alphaCutoff: _alphaCutoff,
        previewColorArgb: _previewColorArgb,
      ),
    );
  }

  /// Uploads dirty bytes from [buffer] without copying its full scratch raster.
  Future<void> refreshBuffer(
    StrokeBuffer buffer, {
    required Rect changedBounds,
  }) {
    _checkNotDisposed();
    if (buffer.isEmpty) {
      clear();
      return Future<void>.value();
    }
    _outlineBounds = buffer.inkBounds;
    return _queueRefresh(
      bufferBounds: buffer.bounds,
      dirty: changedBounds,
      readRegion: (bounds) => buffer.thresholdedRegion(
        bounds,
        alphaCutoff: _alphaCutoff,
        previewColorArgb: _previewColorArgb,
      ),
    );
  }

  Future<void> _queueRefresh({
    required Rect bufferBounds,
    required Rect dirty,
    required _ThresholdRegionReader readRegion,
  }) {
    final generation = _generation;
    final result = _refreshTail.then<void>(
      (_) =>
          _refreshChangedRegions(bufferBounds, dirty, readRegion, generation),
    );
    _refreshTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _refreshChangedRegions(
    Rect bufferBounds,
    Rect dirty,
    _ThresholdRegionReader readRegion,
    int generation,
  ) async {
    if (_disposed || generation != _generation) {
      return;
    }
    final clippedDirty = dirty.intersect(bufferBounds);
    if (clippedDirty.isEmpty) {
      return;
    }
    final firstX = (clippedDirty.left / Tile.edge).floor();
    final firstY = (clippedDirty.top / Tile.edge).floor();
    final lastX = (clippedDirty.right / Tile.edge).ceil() - 1;
    final lastY = (clippedDirty.bottom / Tile.edge).ceil() - 1;
    for (var y = firstY; y <= lastY; y += 1) {
      for (var x = firstX; x <= lastX; x += 1) {
        final key = TileKey(x, y);
        final tilePatchCount = _patches
            .where((patch) => patch.tileKey == key)
            .length;
        final consolidate = tilePatchCount >= maxPatchesPerTile - 1;
        final requestedRegion = consolidate
            ? tileDocumentRect(key)
            : clippedDirty.intersect(tileDocumentRect(key));
        final region = readRegion(requestedRegion);
        if (region.isEmpty) {
          continue;
        }
        final image = await _imageUploader(
          region.pixels,
          region.width,
          region.height,
        );
        if (_disposed || generation != _generation) {
          image.dispose();
          return;
        }
        if (consolidate) {
          final oldPatches = <_StrokeOverlayPatch>[
            for (final patch in _patches)
              if (patch.tileKey == key) patch,
          ];
          for (final patch in oldPatches) {
            _patches.remove(patch);
            patch.image.dispose();
          }
        }
        _patches.add(
          _StrokeOverlayPatch(
            tileKey: key,
            bounds: region.bounds,
            image: image,
          ),
        );
      }
    }
    _recomputeBounds();
  }

  /// Paints the black threshold preview in document coordinates.
  void paint(ui.Canvas canvas) {
    final paint = ui.Paint();
    for (final patch in _patches) {
      canvas.drawImage(patch.image, patch.bounds.topLeft, paint);
    }
    if (_outline && !_outlineBounds.isEmpty) {
      canvas.drawRect(
        _outlineBounds,
        ui.Paint()
          ..color = ui.Color(_previewColorArgb | 0xff000000)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1
          ..isAntiAlias = false,
      );
    }
  }

  /// Removes the overlay after true committed tiles are ready.
  void clear() {
    _checkNotDisposed();
    _generation += 1;
    for (final patch in _patches) {
      patch.image.dispose();
    }
    _patches.clear();
    _bounds = Rect.zero;
    _outlineBounds = Rect.zero;
  }

  /// Releases the uploaded preview image.
  void dispose() {
    if (_disposed) {
      return;
    }
    _generation += 1;
    for (final patch in _patches) {
      patch.image.dispose();
    }
    _patches.clear();
    _outlineBounds = Rect.zero;
    _bounds = Rect.zero;
    _disposed = true;
  }

  void _recomputeBounds() {
    _bounds = Rect.zero;
    for (final patch in _patches) {
      _bounds = _bounds.isEmpty
          ? patch.bounds
          : _bounds.expandToInclude(patch.bounds);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('StrokeOverlay has been disposed.');
    }
  }
}

Rect _unionNonEmpty(Rect left, Rect right) {
  if (left.isEmpty) {
    return right;
  }
  if (right.isEmpty) {
    return left;
  }
  return left.expandToInclude(right);
}
