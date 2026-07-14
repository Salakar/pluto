import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'document.dart';
import 'document_io.dart';
import 'tile_store.dart';

/// Long edge, in pixels, of every persisted gallery thumbnail.
const int inkThumbnailLongEdge = 424;

/// Maximum accepted `.inkpack` size.
const int maximumInkpackBytes = 1024 * 1024 * 1024;

const int _tarBlockLength = 512;
const int _maximumTarEntryCount = 4096;
const int _maximumManifestBytes = 16 * 1024 * 1024;
const int _maximumThumbnailBytes = 32 * 1024 * 1024;
const int _maximumImportedLayerCount = 12;
const int _maximumImportedTileCount = _maximumTarEntryCount - 2;
const int _fnv64Mask = 0xffffffffffffffff;

/// User-selectable export payloads.
enum InkExportKind {
  /// Canvas-sized flattened PNG.
  png1x,

  /// Two-times flattened PNG.
  png2x,

  /// Deterministic USTAR backup containing the artwork manifest and raster.
  inkpack,
}

/// Discrete progress phases rendered by the export panel.
enum InkExportPhase {
  /// Raster layers are being flattened away from the root isolate.
  flattening,

  /// Encoded bytes are being staged and atomically published.
  writing,

  /// The requested file and current thumbnail are durable.
  done,
}

/// Receives a discrete [InkExportPhase] transition.
typedef InkExportProgressCallback = void Function(InkExportPhase phase);

/// Injectable export operation used by the editor panel.
typedef InkExportRunner =
    Future<InkExportResult> Function({
      required String artworkId,
      required InkExportKind kind,
      InkExportProgressCallback? onProgress,
    });

/// Explicit success-or-failure result of one user export.
sealed class InkExportResult {
  const InkExportResult({required this.kind});

  /// Payload requested by the user.
  final InkExportKind kind;
}

/// Successfully published export file.
final class InkExportSuccess extends InkExportResult {
  /// Creates a successful export result.
  InkExportSuccess({required super.kind, required this.path}) {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'must not be blank');
    }
  }

  /// Absolute path in `documents/exports/`.
  final String path;
}

/// Recoverable export failure suitable for a static retry row.
final class InkExportFailure extends InkExportResult {
  /// Creates a failed export result with an actionable [reason].
  InkExportFailure({required super.kind, required this.reason}) {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be blank');
    }
  }

  /// User-presentable disk, codec, or document failure reason.
  final String reason;
}

/// Exception bridge used when a caller requires throwing export semantics.
final class InkExportException implements Exception {
  /// Creates an export exception with a non-empty [reason].
  InkExportException(this.reason) {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be blank');
    }
  }

  /// User-presentable failure reason.
  final String reason;

  @override
  String toString() => 'InkExportException: $reason';
}

/// Exact integer raster dimensions.
final class InkPixelSize {
  /// Creates a positive pixel size.
  InkPixelSize({required this.width, required this.height}) {
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be positive');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'must be positive');
    }
  }

  /// Horizontal pixel count.
  final int width;

  /// Vertical pixel count.
  final int height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InkPixelSize && width == other.width && height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'InkPixelSize($width, $height)';
}

/// Computes an aspect-preserving thumbnail size with an exact [longEdge].
InkPixelSize inkThumbnailSize({
  required int width,
  required int height,
  int longEdge = inkThumbnailLongEdge,
}) {
  if (width <= 0) {
    throw ArgumentError.value(width, 'width', 'must be positive');
  }
  if (height <= 0) {
    throw ArgumentError.value(height, 'height', 'must be positive');
  }
  if (longEdge <= 0) {
    throw ArgumentError.value(longEdge, 'longEdge', 'must be positive');
  }
  if (width >= height) {
    return InkPixelSize(
      width: longEdge,
      height: math.max(1, (height * longEdge / width).round()),
    );
  }
  return InkPixelSize(
    width: math.max(1, (width * longEdge / height).round()),
    height: longEdge,
  );
}

/// Immutable raw premultiplied RGBA8888 image.
final class InkRasterImage {
  /// Creates an image by defensively copying [pixels].
  factory InkRasterImage({
    required int width,
    required int height,
    required Uint8List pixels,
  }) => InkRasterImage.takeOwnership(
    width: width,
    height: height,
    pixels: Uint8List.fromList(pixels),
  );

  /// Creates an image and takes ownership of [pixels].
  factory InkRasterImage.takeOwnership({
    required int width,
    required int height,
    required Uint8List pixels,
  }) {
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be positive');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'must be positive');
    }
    final int expected = width * height * 4;
    if (pixels.lengthInBytes != expected) {
      throw ArgumentError.value(
        pixels.lengthInBytes,
        'pixels.lengthInBytes',
        'must equal $expected for ${width}x$height RGBA8888',
      );
    }
    return InkRasterImage._(
      width: width,
      height: height,
      pixels: pixels.asUnmodifiableView(),
    );
  }

  const InkRasterImage._({
    required this.width,
    required this.height,
    required this.pixels,
  });

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Premultiplied RGBA8888 bytes in row-major order.
  final Uint8List pixels;
}

/// Worker output containing an optional requested export and one thumbnail.
final class InkFlattenedDocument {
  /// Creates worker-prepared raster output.
  const InkFlattenedDocument({required this.exportImage, required this.thumb});

  /// Requested flattened source image, absent for archive-only preparation.
  ///
  /// The root-isolate encoder performs the 2x upload so the worker never
  /// allocates and transfers a second 256 MiB buffer for a maximum canvas.
  final InkRasterImage? exportImage;

  /// Aspect-preserving thumbnail raster.
  final InkRasterImage thumb;
}

/// Off-root-isolate full-document raster preparation seam.
abstract interface class InkRasterFlattener {
  /// Flattens visible document layers and prepares the current thumbnail.
  Future<InkFlattenedDocument> flatten({
    required InkDocument document,
    required TileStore tiles,
    required int exportScale,
  });
}

/// Production flattener that transfers tile bytes through a short-lived isolate.
final class IsolateInkRasterFlattener implements InkRasterFlattener {
  /// Creates the production export flattener.
  const IsolateInkRasterFlattener();

  @override
  Future<InkFlattenedDocument> flatten({
    required InkDocument document,
    required TileStore tiles,
    required int exportScale,
  }) async {
    if (exportScale < 0 || exportScale > 2) {
      throw ArgumentError.value(
        exportScale,
        'exportScale',
        'must be 0, 1, or 2',
      );
    }
    final _FlattenRequest request = _buildFlattenRequest(
      document: document,
      tiles: tiles,
      exportScale: exportScale,
    );
    final _FlattenResponse response = await Isolate.run<_FlattenResponse>(
      () => _flattenDocumentOnWorker(request),
      debugName: 'ink-export-raster',
    );
    final InkRasterImage? exportImage = response.exportPixels == null
        ? null
        : InkRasterImage.takeOwnership(
            width: response.exportWidth,
            height: response.exportHeight,
            pixels: response.exportPixels!.materialize().asUint8List(),
          );
    return InkFlattenedDocument(
      exportImage: exportImage,
      thumb: InkRasterImage.takeOwnership(
        width: response.thumbWidth,
        height: response.thumbHeight,
        pixels: response.thumbPixels.materialize().asUint8List(),
      ),
    );
  }
}

/// Root-isolate PNG encoder seam.
typedef InkPngEncoder =
    Future<Uint8List> Function(InkRasterImage image, {required int scale});

/// Encodes [image] as a real PNG through root-isolate `dart:ui` APIs.
Future<Uint8List> encodeInkPng(
  InkRasterImage image, {
  required int scale,
}) async {
  if (scale != 1 && scale != 2) {
    throw ArgumentError.value(scale, 'scale', 'must be 1 or 2');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? uploaded;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(image.pixels);
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: image.width,
      height: image.height,
      rowBytes: image.width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: image.width * scale,
      targetHeight: image.height * scale,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    uploaded = frame.image;
    final ByteData? encoded = await uploaded.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (encoded == null) {
      throw InkExportException('PNG encoder returned no bytes');
    }
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } finally {
    uploaded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Explicit result of one `.inkpack` import attempt.
sealed class InkpackImportResult {
  const InkpackImportResult();
}

/// Successfully imported and freshly identified artwork.
final class InkpackImportSuccess extends InkpackImportResult {
  /// Creates a successful archive import result.
  const InkpackImportSuccess({required this.entry});

  /// Gallery metadata inserted at the front.
  final GalleryEntry entry;
}

/// Safely skipped malformed or unsupported archive.
final class InkpackImportFailure extends InkpackImportResult {
  /// Creates an archive skip with a non-empty [reason].
  InkpackImportFailure({required this.reason}) {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must not be blank');
    }
  }

  /// User-presentable validation or IO reason.
  final String reason;
}

/// End-to-end export, archive import, and thumbnail service.
final class InkDocumentTransferService {
  /// Creates a transfer service over the landed [DocumentStore].
  InkDocumentTransferService({
    required this.store,
    required this.exportsDirectory,
    required this.nowMilliseconds,
    this.idGenerator,
    this.rasterFlattener = const IsolateInkRasterFlattener(),
    this.pngEncoder = encodeInkPng,
  });

  /// Crash-safe document storage.
  final DocumentStore store;

  /// User-visible `documents/exports/` directory.
  final Directory exportsDirectory;

  /// Injectable wall clock for staging and fresh-id generation.
  final int Function() nowMilliseconds;

  /// Optional deterministic fresh-id source.
  final String Function()? idGenerator;

  /// Pure-pixel worker implementation.
  final InkRasterFlattener rasterFlattener;

  /// Root-isolate PNG encoder, injectable for non-codec tests.
  final InkPngEncoder pngEncoder;

  int _idSequence = 0;
  int _stageSequence = 0;
  String? _lastImportFailureReason;

  /// Reason from the latest skipped archive, or null after a success.
  String? get lastImportFailureReason => _lastImportFailureReason;

  /// Exports one payload and converts operational failures to a typed result.
  Future<InkExportResult> export({
    required String artworkId,
    required InkExportKind kind,
    InkExportProgressCallback? onProgress,
  }) async {
    if (artworkId.isEmpty) {
      throw ArgumentError.value(artworkId, 'artworkId', 'must not be empty');
    }
    try {
      onProgress?.call(InkExportPhase.flattening);
      final LoadedInkDocument loaded = await _loadComplete(artworkId);
      final int scale = switch (kind) {
        InkExportKind.png1x => 1,
        InkExportKind.png2x => 2,
        InkExportKind.inkpack => 0,
      };
      final InkFlattenedDocument flattened = await rasterFlattener.flatten(
        document: loaded.document,
        tiles: loaded.tiles,
        exportScale: scale,
      );
      onProgress?.call(InkExportPhase.writing);
      await _writeThumbnail(artworkId, flattened.thumb);
      final File published = switch (kind) {
        InkExportKind.png1x || InkExportKind.png2x => await _writePngExport(
          document: loaded.document,
          kind: kind,
          image:
              flattened.exportImage ??
              (throw StateError('Raster worker omitted the PNG payload.')),
        ),
        InkExportKind.inkpack => await _writeInkpackExport(loaded.document),
      };
      onProgress?.call(InkExportPhase.done);
      return InkExportSuccess(kind: kind, path: published.path);
    } on Object catch (error) {
      return InkExportFailure(kind: kind, reason: _exportFailureReason(error));
    }
  }

  /// Exports one payload, throwing [InkExportException] on typed failure.
  Future<String> exportOrThrow({
    required String artworkId,
    required InkExportKind kind,
    InkExportProgressCallback? onProgress,
  }) async {
    final InkExportResult result = await export(
      artworkId: artworkId,
      kind: kind,
      onProgress: onProgress,
    );
    return switch (result) {
      InkExportSuccess(:final String path) => path,
      InkExportFailure(:final String reason) => throw InkExportException(
        reason,
      ),
    };
  }

  /// Rebuilds and atomically publishes one artwork's `thumb.png`.
  Future<File> regenerateThumbnail(String artworkId) async {
    if (artworkId.isEmpty) {
      throw ArgumentError.value(artworkId, 'artworkId', 'must not be empty');
    }
    final LoadedInkDocument loaded = await _loadComplete(artworkId);
    final InkFlattenedDocument flattened = await rasterFlattener.flatten(
      document: loaded.document,
      tiles: loaded.tiles,
      exportScale: 0,
    );
    return _writeThumbnail(artworkId, flattened.thumb);
  }

  /// Refreshes absent or manifest-stale thumbnails without failing the sweep.
  Future<List<String>> regenerateStaleThumbnails(
    Iterable<GalleryEntry> entries, {
    void Function(GalleryEntry entry)? onRegenerated,
  }) async {
    final List<String> failedIds = <String>[];
    for (final GalleryEntry entry in entries) {
      final File manifest = store.manifestFile(entry.id);
      final File thumb = File(
        '${store.artworkDirectory(entry.id).path}/thumb.png',
      );
      try {
        final bool stale =
            !thumb.existsSync() ||
            (manifest.existsSync() &&
                manifest.statSync().modified.isAfter(
                  thumb.statSync().modified,
                ));
        if (stale) {
          await regenerateThumbnail(entry.id);
          onRegenerated?.call(entry);
        }
      } on Object {
        failedIds.add(entry.id);
      }
    }
    return List<String>.unmodifiable(failedIds);
  }

  /// Imports one archive, returning null after a safely reported skip.
  Future<GalleryEntry?> importInkpack(File archive) async =>
      switch (await importInkpackResult(archive)) {
        InkpackImportSuccess(:final GalleryEntry entry) => entry,
        InkpackImportFailure() => null,
      };

  /// Imports one deterministic USTAR archive with a typed detailed result.
  Future<InkpackImportResult> importInkpackResult(File archive) async {
    if (archive.path.isEmpty) {
      throw ArgumentError.value(archive.path, 'archive', 'must not be empty');
    }
    Directory? staging;
    Directory? publishedDirectory;
    try {
      staging = await _createImportStagingDirectory();
      final Set<String> extracted = await _extractUstar(
        archive: archive,
        destination: staging,
      );
      final InkDocument source = await _validateExtractedArtwork(
        staging,
        extracted,
      );
      final String freshId = _freshArtworkId();
      final InkDocument imported = source.copyWith(id: freshId);
      await _atomicWriteBytes(
        File('${staging.path}/manifest.json'),
        Uint8List.fromList(utf8.encode(jsonEncode(imported.toJson()))),
      );

      final List<GalleryEntry> before = await store.loadGallery();
      publishedDirectory = store.artworkDirectory(freshId);
      await publishedDirectory.parent.create(recursive: true);
      await staging.rename(publishedDirectory.path);
      staging = null;
      final GalleryEntry entry = GalleryEntry.fromDocument(imported);
      await store.saveGallery(<GalleryEntry>[
        entry,
        for (final GalleryEntry existing in before)
          if (existing.id != freshId) existing,
      ]);
      _lastImportFailureReason = null;
      return InkpackImportSuccess(entry: entry);
    } on Object catch (error) {
      final String reason = _importFailureReason(error);
      _lastImportFailureReason = reason;
      if (publishedDirectory != null && publishedDirectory.existsSync()) {
        try {
          await publishedDirectory.delete(recursive: true);
        } on Object {
          // The gallery cache remains unchanged and a later rebuild can recover.
        }
      }
      return InkpackImportFailure(reason: reason);
    } finally {
      if (staging != null && staging.existsSync()) {
        try {
          await staging.delete(recursive: true);
        } on Object {
          // A stale hidden staging directory is never treated as an artwork.
        }
      }
    }
  }

  Future<LoadedInkDocument> _loadComplete(String artworkId) async {
    final LoadedInkDocument? loaded = await store.openDocument(artworkId);
    if (loaded == null) {
      throw InkExportException('artwork could not be opened');
    }
    await loaded.loadRemaining();
    if (loaded.issues.isNotEmpty) {
      throw InkExportException('artwork has missing or corrupt tile data');
    }
    return loaded;
  }

  Future<File> _writeThumbnail(String artworkId, InkRasterImage thumb) async {
    final Uint8List bytes = await pngEncoder(thumb, scale: 1);
    final File target = File(
      '${store.artworkDirectory(artworkId).path}/thumb.png',
    );
    await _atomicWriteBytes(target, bytes);
    return target;
  }

  Future<File> _writePngExport({
    required InkDocument document,
    required InkExportKind kind,
    required InkRasterImage image,
  }) async {
    final String scale = kind == InkExportKind.png1x ? '1x' : '2x';
    final Uint8List bytes = await pngEncoder(
      image,
      scale: kind == InkExportKind.png1x ? 1 : 2,
    );
    final String name = '${_exportStem(document)}-$scale.png';
    final Directory stagingDirectory = Directory(
      '${store.artworkDirectory(document.id).path}/export',
    );
    final File staged = File('${stagingDirectory.path}/$name');
    await _atomicWriteBytes(staged, bytes);
    return _publishStagedFile(staged, File('${exportsDirectory.path}/$name'));
  }

  Future<File> _writeInkpackExport(InkDocument document) async {
    final String name = '${_exportStem(document)}-backup.inkpack';
    final Directory artwork = store.artworkDirectory(document.id);
    final Directory stagingDirectory = Directory('${artwork.path}/export');
    final File staged = File('${stagingDirectory.path}/$name');
    final List<_TarSource> sources = <_TarSource>[
      _TarSource(name: 'manifest.json', file: store.manifestFile(document.id)),
      for (final InkLayer layer in document.layers)
        for (final TileKey key in (List<TileKey>.of(layer.tiles)..sort()))
          _TarSource(
            name: 'layers/${layer.id}/${key.fileName}',
            file: store.tileFile(
              document.id,
              TileLocation(layerId: layer.id, key: key),
            ),
          ),
      _TarSource(name: 'thumb.png', file: File('${artwork.path}/thumb.png')),
    ];
    await _writeUstar(target: staged, sources: sources);
    return _publishStagedFile(staged, File('${exportsDirectory.path}/$name'));
  }

  Future<File> _publishStagedFile(File staged, File destination) async {
    await destination.parent.create(recursive: true);
    final File publication = File(
      '${staged.path}.publishing-${nowMilliseconds()}-${_stageSequence++}',
    );
    await _deleteFileIfPresent(publication);
    try {
      await _copyFileFlushed(staged, publication);
      await publication.rename(destination.path);
      return destination;
    } on Object {
      await _deleteFileIfPresent(publication);
      rethrow;
    }
  }

  Future<Directory> _createImportStagingDirectory() async {
    final Directory parent = Directory('${store.root.path}/.inkpack-staging');
    await parent.create(recursive: true);
    while (true) {
      final Directory candidate = Directory(
        '${parent.path}/import-${nowMilliseconds()}-${_stageSequence++}',
      );
      if (!candidate.existsSync()) {
        await candidate.create();
        return candidate;
      }
    }
  }

  String _freshArtworkId() {
    final String base =
        idGenerator?.call() ??
        'ink-import-${nowMilliseconds()}-${_idSequence++}';
    final String safeBase = _safeGeneratedId(base);
    var candidate = safeBase;
    var suffix = 1;
    while (store.artworkDirectory(candidate).existsSync() ||
        Directory('${store.trashDirectory.path}/$candidate').existsSync()) {
      candidate = '$safeBase-$suffix';
      suffix += 1;
    }
    return candidate;
  }
}

final class _FlattenRequest {
  const _FlattenRequest({
    required this.width,
    required this.height,
    required this.exportScale,
    required this.layers,
  });

  final int width;
  final int height;
  final int exportScale;
  final List<_FlattenLayer> layers;
}

final class _FlattenLayer {
  const _FlattenLayer({
    required this.opacity,
    required this.multiply,
    required this.tiles,
  });

  final int opacity;
  final bool multiply;
  final List<_FlattenTile> tiles;
}

final class _FlattenTile {
  const _FlattenTile({required this.x, required this.y, required this.pixels});

  final int x;
  final int y;
  final TransferableTypedData pixels;
}

final class _FlattenResponse {
  const _FlattenResponse({
    required this.exportWidth,
    required this.exportHeight,
    required this.exportPixels,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.thumbPixels,
  });

  final int exportWidth;
  final int exportHeight;
  final TransferableTypedData? exportPixels;
  final int thumbWidth;
  final int thumbHeight;
  final TransferableTypedData thumbPixels;
}

_FlattenRequest _buildFlattenRequest({
  required InkDocument document,
  required TileStore tiles,
  required int exportScale,
}) => _FlattenRequest(
  width: document.canvas.width,
  height: document.canvas.height,
  exportScale: exportScale,
  layers: <_FlattenLayer>[
    for (final InkLayer layer in document.layers)
      if (layer.visible && layer.opacity > 0)
        _FlattenLayer(
          opacity: layer.opacity,
          multiply: layer.blend == 'multiply',
          tiles: <_FlattenTile>[
            for (final TileKey key in tiles.occupiedKeys(layer.id))
              if (_tileIntersectsCanvas(
                key,
                width: document.canvas.width,
                height: document.canvas.height,
              ))
                _FlattenTile(
                  x: key.x,
                  y: key.y,
                  pixels: TransferableTypedData.fromList(<TypedData>[
                    tiles.tile(layer.id, key)!.pixels,
                  ]),
                ),
          ],
        ),
  ],
);

bool _tileIntersectsCanvas(
  TileKey key, {
  required int width,
  required int height,
}) {
  final int left = key.x * Tile.edge;
  final int top = key.y * Tile.edge;
  return left < width &&
      top < height &&
      left + Tile.edge > 0 &&
      top + Tile.edge > 0;
}

_FlattenResponse _flattenDocumentOnWorker(_FlattenRequest request) {
  final Uint8List canvas = Uint8List(request.width * request.height * 4);
  Uint32List.sublistView(
    canvas,
  ).fillRange(0, request.width * request.height, 0xffffffff);
  for (final _FlattenLayer layer in request.layers) {
    for (final _FlattenTile input in layer.tiles) {
      final Uint8List source = input.pixels.materialize().asUint8List();
      if (source.lengthInBytes != Tile.byteLength) {
        throw const FormatException('Raster worker received a truncated tile');
      }
      _blendFlattenTile(
        destination: canvas,
        canvasWidth: request.width,
        canvasHeight: request.height,
        tileX: input.x,
        tileY: input.y,
        source: source,
        opacity: layer.opacity,
        multiply: layer.multiply,
      );
    }
  }

  final InkPixelSize thumbSize = inkThumbnailSize(
    width: request.width,
    height: request.height,
  );
  final Uint8List thumb = _resizeNearest(
    source: canvas,
    sourceWidth: request.width,
    sourceHeight: request.height,
    targetWidth: thumbSize.width,
    targetHeight: thumbSize.height,
  );
  final Uint8List? export = switch (request.exportScale) {
    0 => null,
    1 => canvas,
    2 => canvas,
    _ => throw StateError('Unsupported export scale ${request.exportScale}'),
  };
  return _FlattenResponse(
    exportWidth: request.exportScale == 0 ? 0 : request.width,
    exportHeight: request.exportScale == 0 ? 0 : request.height,
    exportPixels: export == null
        ? null
        : TransferableTypedData.fromList(<TypedData>[export]),
    thumbWidth: thumbSize.width,
    thumbHeight: thumbSize.height,
    thumbPixels: TransferableTypedData.fromList(<TypedData>[thumb]),
  );
}

void _blendFlattenTile({
  required Uint8List destination,
  required int canvasWidth,
  required int canvasHeight,
  required int tileX,
  required int tileY,
  required Uint8List source,
  required int opacity,
  required bool multiply,
}) {
  final int tileLeft = tileX * Tile.edge;
  final int tileTop = tileY * Tile.edge;
  final int left = math.max(0, tileLeft);
  final int top = math.max(0, tileTop);
  final int right = math.min(canvasWidth, tileLeft + Tile.edge);
  final int bottom = math.min(canvasHeight, tileTop + Tile.edge);
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      final int sourceOffset = ((y - tileTop) * Tile.edge + x - tileLeft) * 4;
      final int destinationOffset = (y * canvasWidth + x) * 4;
      final int sourceAlpha = (source[sourceOffset + 3] * opacity + 50) ~/ 100;
      if (sourceAlpha == 0) {
        continue;
      }
      final int sourceRed = (source[sourceOffset] * opacity + 50) ~/ 100;
      final int sourceGreen = (source[sourceOffset + 1] * opacity + 50) ~/ 100;
      final int sourceBlue = (source[sourceOffset + 2] * opacity + 50) ~/ 100;
      final int inverseSourceAlpha = 255 - sourceAlpha;
      final int destinationAlpha = destination[destinationOffset + 3];
      if (multiply) {
        destination[destinationOffset] = _multiplyChannel(
          sourceRed,
          sourceAlpha,
          destination[destinationOffset],
          destinationAlpha,
        );
        destination[destinationOffset + 1] = _multiplyChannel(
          sourceGreen,
          sourceAlpha,
          destination[destinationOffset + 1],
          destinationAlpha,
        );
        destination[destinationOffset + 2] = _multiplyChannel(
          sourceBlue,
          sourceAlpha,
          destination[destinationOffset + 2],
          destinationAlpha,
        );
      } else {
        destination[destinationOffset] = _byte(
          sourceRed +
              (destination[destinationOffset] * inverseSourceAlpha + 127) ~/
                  255,
        );
        destination[destinationOffset + 1] = _byte(
          sourceGreen +
              (destination[destinationOffset + 1] * inverseSourceAlpha + 127) ~/
                  255,
        );
        destination[destinationOffset + 2] = _byte(
          sourceBlue +
              (destination[destinationOffset + 2] * inverseSourceAlpha + 127) ~/
                  255,
        );
      }
      destination[destinationOffset + 3] = _byte(
        sourceAlpha + (destinationAlpha * inverseSourceAlpha + 127) ~/ 255,
      );
    }
  }
}

int _multiplyChannel(
  int source,
  int sourceAlpha,
  int destination,
  int destinationAlpha,
) => _byte(
  (source * (255 - destinationAlpha) +
          destination * (255 - sourceAlpha) +
          source * destination +
          127) ~/
      255,
);

int _byte(int value) => value > 255 ? 255 : value;

Uint8List _resizeNearest({
  required Uint8List source,
  required int sourceWidth,
  required int sourceHeight,
  required int targetWidth,
  required int targetHeight,
}) {
  if (source.lengthInBytes != sourceWidth * sourceHeight * 4) {
    throw const FormatException('Resize source dimensions do not match bytes');
  }
  final Uint8List output = Uint8List(targetWidth * targetHeight * 4);
  for (var y = 0; y < targetHeight; y += 1) {
    final int sourceY = math.min(
      sourceHeight - 1,
      y * sourceHeight ~/ targetHeight,
    );
    for (var x = 0; x < targetWidth; x += 1) {
      final int sourceX = math.min(
        sourceWidth - 1,
        x * sourceWidth ~/ targetWidth,
      );
      final int sourceOffset = (sourceY * sourceWidth + sourceX) * 4;
      final int targetOffset = (y * targetWidth + x) * 4;
      output[targetOffset] = source[sourceOffset];
      output[targetOffset + 1] = source[sourceOffset + 1];
      output[targetOffset + 2] = source[sourceOffset + 2];
      output[targetOffset + 3] = source[sourceOffset + 3];
    }
  }
  return output;
}

final class _TarSource {
  const _TarSource({required this.name, required this.file});

  final String name;
  final File file;
}

final class _TarPathFields {
  const _TarPathFields({required this.name, required this.prefix});

  final Uint8List name;
  final Uint8List prefix;
}

Future<void> _writeUstar({
  required File target,
  required List<_TarSource> sources,
}) async {
  if (sources.isEmpty || sources.length > _maximumTarEntryCount) {
    throw ArgumentError.value(
      sources.length,
      'sources',
      'must contain 1 through $_maximumTarEntryCount files',
    );
  }
  await target.parent.create(recursive: true);
  final File temporary = File('${target.path}.tmp');
  await _deleteFileIfPresent(temporary);
  RandomAccessFile? output;
  try {
    output = await temporary.open(mode: FileMode.write);
    var archiveLength = _tarBlockLength * 2;
    for (final _TarSource source in sources) {
      if (!source.file.existsSync()) {
        throw FileSystemException(
          'Archive source is missing',
          source.file.path,
        );
      }
      final int length = await source.file.length();
      archiveLength += _tarBlockLength + length + _tarPaddingLength(length);
      if (archiveLength > maximumInkpackBytes) {
        throw const FormatException('Inkpack exceeds the archive-size bound');
      }
      await output.writeFrom(_ustarHeader(source.name, length));
      final RandomAccessFile input = await source.file.open();
      try {
        var remaining = length;
        while (remaining > 0) {
          final Uint8List chunk = await input.read(
            math.min(64 * 1024, remaining),
          );
          if (chunk.isEmpty) {
            throw FileSystemException(
              'Archive source was truncated while reading',
              source.file.path,
            );
          }
          await output.writeFrom(chunk);
          remaining -= chunk.length;
        }
      } finally {
        await input.close();
      }
      final int padding = _tarPaddingLength(length);
      if (padding > 0) {
        await output.writeFrom(Uint8List(padding));
      }
    }
    await output.writeFrom(Uint8List(_tarBlockLength * 2));
    await output.flush();
    await output.close();
    output = null;
    await temporary.rename(target.path);
  } on Object {
    await output?.close();
    await _deleteFileIfPresent(temporary);
    rethrow;
  }
}

Uint8List _ustarHeader(String path, int length) {
  final _TarPathFields pathFields = _splitTarPath(path);
  final Uint8List header = Uint8List(_tarBlockLength);
  header.setRange(0, pathFields.name.length, pathFields.name);
  _writeTarOctal(header, offset: 100, length: 8, value: 0x1a4);
  _writeTarOctal(header, offset: 108, length: 8, value: 0);
  _writeTarOctal(header, offset: 116, length: 8, value: 0);
  _writeTarOctal(header, offset: 124, length: 12, value: length);
  _writeTarOctal(header, offset: 136, length: 12, value: 0);
  header.fillRange(148, 156, 0x20);
  header[156] = 0x30;
  header.setRange(257, 263, const <int>[0x75, 0x73, 0x74, 0x61, 0x72, 0]);
  header.setRange(263, 265, const <int>[0x30, 0x30]);
  header.setRange(345, 345 + pathFields.prefix.length, pathFields.prefix);
  _writeTarOctal(header, offset: 329, length: 8, value: 0);
  _writeTarOctal(header, offset: 337, length: 8, value: 0);
  final int checksum = header.fold<int>(0, (int sum, int byte) => sum + byte);
  final String encodedChecksum = checksum.toRadixString(8).padLeft(6, '0');
  header.setRange(148, 154, ascii.encode(encodedChecksum));
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

_TarPathFields _splitTarPath(String path) {
  _validateArchivePath(path);
  final Uint8List encoded = Uint8List.fromList(utf8.encode(path));
  if (encoded.length <= 100) {
    return _TarPathFields(name: encoded, prefix: Uint8List(0));
  }
  final List<String> segments = path.split('/');
  for (var split = segments.length - 1; split > 0; split -= 1) {
    final Uint8List prefix = Uint8List.fromList(
      utf8.encode(segments.take(split).join('/')),
    );
    final Uint8List name = Uint8List.fromList(
      utf8.encode(segments.skip(split).join('/')),
    );
    if (prefix.length <= 155 && name.length <= 100) {
      return _TarPathFields(name: name, prefix: prefix);
    }
  }
  throw FormatException('USTAR path is too long: $path');
}

void _writeTarOctal(
  Uint8List target, {
  required int offset,
  required int length,
  required int value,
}) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'must not be negative');
  }
  final String digits = value.toRadixString(8);
  if (digits.length > length - 1) {
    throw ArgumentError.value(value, 'value', 'does not fit the USTAR field');
  }
  final String field = digits.padLeft(length - 1, '0');
  target.setRange(offset, offset + length - 1, ascii.encode(field));
  target[offset + length - 1] = 0;
}

int _tarPaddingLength(int length) =>
    (_tarBlockLength - length % _tarBlockLength) % _tarBlockLength;

Future<Set<String>> _extractUstar({
  required File archive,
  required Directory destination,
}) async {
  if (!archive.existsSync()) {
    throw FileSystemException('Archive does not exist', archive.path);
  }
  final int archiveLength = await archive.length();
  if (archiveLength < _tarBlockLength * 2 ||
      archiveLength > maximumInkpackBytes ||
      archiveLength % _tarBlockLength != 0) {
    throw const FormatException('Invalid .inkpack byte length');
  }
  final RandomAccessFile input = await archive.open();
  final Set<String> extracted = <String>{};
  try {
    var entryCount = 0;
    while (true) {
      final Uint8List header = await _readExactly(input, _tarBlockLength);
      if (_allZero(header)) {
        final Uint8List second = await _readExactly(input, _tarBlockLength);
        if (!_allZero(second)) {
          throw const FormatException('USTAR end marker is truncated');
        }
        while (await input.position() < archiveLength) {
          final int remaining = archiveLength - await input.position();
          final Uint8List trailing = await _readExactly(
            input,
            math.min(64 * 1024, remaining),
          );
          if (!_allZero(trailing)) {
            throw const FormatException('USTAR has non-zero trailing bytes');
          }
        }
        break;
      }
      entryCount += 1;
      if (entryCount > _maximumTarEntryCount) {
        throw const FormatException('USTAR has too many entries');
      }
      _validateUstarHeader(header);
      final String name = _tarEntryPath(header);
      _validateArchivePath(name);
      if (!_isAllowedInkpackPath(name)) {
        throw FormatException('Unexpected .inkpack entry: $name');
      }
      if (!extracted.add(name)) {
        throw FormatException('Duplicate .inkpack entry: $name');
      }
      final int length = _parseTarOctal(header, offset: 124, length: 12);
      final int maximumLength = switch (name) {
        'manifest.json' => _maximumManifestBytes,
        'thumb.png' => _maximumThumbnailBytes,
        _ => InkTileCodec.maxEncodedLength,
      };
      if (length > maximumLength) {
        throw FormatException('$name exceeds its size bound');
      }

      final File target = File('${destination.path}/$name');
      await target.parent.create(recursive: true);
      final RandomAccessFile output = await target.open(mode: FileMode.write);
      try {
        var remaining = length;
        while (remaining > 0) {
          final Uint8List chunk = await _readExactly(
            input,
            math.min(64 * 1024, remaining),
          );
          await output.writeFrom(chunk);
          remaining -= chunk.length;
        }
        await output.flush();
      } finally {
        await output.close();
      }
      final int paddingLength = _tarPaddingLength(length);
      if (paddingLength > 0) {
        final Uint8List padding = await _readExactly(input, paddingLength);
        if (!_allZero(padding)) {
          throw FormatException('$name has non-zero USTAR padding');
        }
      }
    }
  } finally {
    await input.close();
  }
  return Set<String>.unmodifiable(extracted);
}

void _validateUstarHeader(Uint8List header) {
  const List<int> magic = <int>[0x75, 0x73, 0x74, 0x61, 0x72, 0];
  for (var index = 0; index < magic.length; index += 1) {
    if (header[257 + index] != magic[index]) {
      throw const FormatException('Archive is not a USTAR stream');
    }
  }
  if (header[263] != 0x30 || header[264] != 0x30) {
    throw const FormatException('Unsupported USTAR version');
  }
  final int type = header[156];
  if (type != 0 && type != 0x30) {
    throw const FormatException(
      'USTAR links and special entries are forbidden',
    );
  }
  final int expected = _parseTarOctal(header, offset: 148, length: 8);
  var actual = 0;
  for (var index = 0; index < header.length; index += 1) {
    actual += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  if (actual != expected) {
    throw const FormatException('USTAR header checksum is invalid');
  }
}

String _tarEntryPath(Uint8List header) {
  final String name = _decodeTarText(header, offset: 0, length: 100);
  final String prefix = _decodeTarText(header, offset: 345, length: 155);
  if (name.isEmpty) {
    throw const FormatException('USTAR entry name is empty');
  }
  return prefix.isEmpty ? name : '$prefix/$name';
}

String _decodeTarText(
  Uint8List bytes, {
  required int offset,
  required int length,
}) {
  var end = offset;
  final int limit = offset + length;
  while (end < limit && bytes[end] != 0) {
    end += 1;
  }
  for (var index = end; index < limit; index += 1) {
    if (bytes[index] != 0) {
      throw const FormatException('USTAR text field is not NUL padded');
    }
  }
  try {
    return utf8.decode(bytes.sublist(offset, end));
  } on FormatException {
    throw const FormatException('USTAR path is not valid UTF-8');
  }
}

int _parseTarOctal(
  Uint8List bytes, {
  required int offset,
  required int length,
}) {
  final String raw = ascii.decode(
    bytes.sublist(offset, offset + length),
    allowInvalid: true,
  );
  final String trimmed = raw.replaceAll('\u0000', '').trim();
  if (trimmed.isEmpty) {
    return 0;
  }
  if (!RegExp(r'^[0-7]+$').hasMatch(trimmed)) {
    throw const FormatException('USTAR numeric field is invalid');
  }
  final int? value = int.tryParse(trimmed, radix: 8);
  if (value == null || value < 0) {
    throw const FormatException('USTAR numeric field is out of range');
  }
  return value;
}

bool _isAllowedInkpackPath(String path) =>
    path == 'manifest.json' ||
    path == 'thumb.png' ||
    RegExp(r'^layers/[^/]+/-?\d+_-?\d+\.tile$').hasMatch(path);

void _validateArchivePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\u0000')) {
    throw FormatException('Unsafe archive path: $path');
  }
  for (final String segment in path.split('/')) {
    if (!_isSafePathComponent(segment)) {
      throw FormatException('Unsafe archive path: $path');
    }
  }
}

bool _isSafePathComponent(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains('\\') &&
    !value.contains('\u0000');

bool _isDocumentStoreComponent(String value) =>
    value != '.' &&
    value != '..' &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

Future<InkDocument> _validateExtractedArtwork(
  Directory staging,
  Set<String> extracted,
) async {
  if (!extracted.contains('manifest.json')) {
    throw const FormatException('Archive is missing manifest.json');
  }
  if (!extracted.contains('thumb.png')) {
    throw const FormatException('Archive is missing thumb.png');
  }
  final Uint8List manifestBytes = await _readFileBounded(
    File('${staging.path}/manifest.json'),
    maximumLength: _maximumManifestBytes,
  );
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(manifestBytes));
  } on Object catch (error) {
    throw FormatException('Manifest JSON is malformed', error);
  }
  final Map<String, Object?> manifest = _jsonObject(decoded, 'manifest');
  if (manifest['schema'] != inkDocumentSchema) {
    throw const FormatException('Unsupported manifest schema');
  }
  final InkDocument document = InkDocument.fromJson(manifest);
  if (!_isDocumentStoreComponent(document.id)) {
    throw const FormatException('Manifest artwork id is unsafe');
  }
  if (document.layers.length > _maximumImportedLayerCount) {
    throw const FormatException('Manifest exceeds the twelve-layer limit');
  }
  final Set<String> expected = <String>{'manifest.json', 'thumb.png'};
  final Set<String> layerIds = <String>{};
  var tileCount = 0;
  for (final InkLayer layer in document.layers) {
    if (!_isDocumentStoreComponent(layer.id)) {
      throw FormatException('Unsafe layer id: ${layer.id}');
    }
    if (!layerIds.add(layer.id)) {
      throw FormatException('Duplicate layer id: ${layer.id}');
    }
    final Set<TileKey> layerKeys = <TileKey>{};
    for (final TileKey key in layer.tiles) {
      if (!layerKeys.add(key)) {
        throw FormatException(
          'Layer ${layer.id} contains duplicate tile coordinates',
        );
      }
      tileCount += 1;
      if (tileCount > _maximumImportedTileCount) {
        throw const FormatException('Manifest exceeds the tile-count limit');
      }
      expected.add('layers/${layer.id}/${key.fileName}');
    }
  }
  if (expected.length != extracted.length ||
      !expected.every(extracted.contains)) {
    throw const FormatException(
      'Archive tiles do not match the manifest exactly',
    );
  }
  for (final String path in expected) {
    if (!path.endsWith('.tile')) {
      continue;
    }
    final Uint8List bytes = await _readFileBounded(
      File('${staging.path}/$path'),
      maximumLength: InkTileCodec.maxEncodedLength,
    );
    InkTileCodec.decodeTile(bytes);
  }
  final Uint8List thumbnailBytes = await _readFileBounded(
    File('${staging.path}/thumb.png'),
    maximumLength: _maximumThumbnailBytes,
  );
  await _validateThumbnailPng(
    thumbnailBytes,
    expected: inkThumbnailSize(
      width: document.canvas.width,
      height: document.canvas.height,
    ),
  );
  return document;
}

Future<void> _validateThumbnailPng(
  Uint8List bytes, {
  required InkPixelSize expected,
}) async {
  const List<int> signature = <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ];
  if (bytes.lengthInBytes < 24) {
    throw const FormatException('Archive thumbnail is not a PNG');
  }
  for (var index = 0; index < signature.length; index += 1) {
    if (bytes[index] != signature[index]) {
      throw const FormatException('Archive thumbnail is not a PNG');
    }
  }
  final ByteData header = ByteData.sublistView(bytes);
  final bool hasIhdr =
      header.getUint32(8, Endian.big) == 13 &&
      bytes[12] == 0x49 &&
      bytes[13] == 0x48 &&
      bytes[14] == 0x44 &&
      bytes[15] == 0x52;
  if (!hasIhdr ||
      header.getUint32(16, Endian.big) != expected.width ||
      header.getUint32(20, Endian.big) != expected.height) {
    throw const FormatException('Archive thumbnail dimensions are invalid');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width != expected.width ||
        descriptor.height != expected.height) {
      throw const FormatException('Archive thumbnail dimensions are invalid');
    }
    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final ui.FrameInfo frame = await codec.getNextFrame();
    decoded = frame.image;
  } on Object catch (error) {
    throw FormatException('Archive thumbnail is corrupt', error);
  } finally {
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Map<String, Object?> _jsonObject(Object? value, String label) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('$label must be a JSON object');
  }
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw FormatException('$label keys must be strings');
    }
    result[key] = entry.value;
  }
  return result;
}

Future<Uint8List> _readExactly(RandomAccessFile input, int length) async {
  final Uint8List result = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    final Uint8List chunk = await input.read(length - offset);
    if (chunk.isEmpty) {
      throw const FormatException('Archive is truncated');
    }
    result.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return result;
}

bool _allZero(Uint8List bytes) {
  for (final int byte in bytes) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

Future<Uint8List> _readFileBounded(
  File file, {
  required int maximumLength,
}) async {
  final int length = await file.length();
  if (length < 0 || length > maximumLength) {
    throw FormatException('${file.path} exceeds its size bound');
  }
  return file.readAsBytes();
}

Future<void> _atomicWriteBytes(File target, Uint8List bytes) async {
  await target.parent.create(recursive: true);
  final File temporary = File('${target.path}.tmp');
  await _deleteFileIfPresent(temporary);
  RandomAccessFile? output;
  try {
    output = await temporary.open(mode: FileMode.write);
    await output.writeFrom(bytes);
    await output.flush();
    await output.close();
    output = null;
    await temporary.rename(target.path);
  } on Object {
    await output?.close();
    await _deleteFileIfPresent(temporary);
    rethrow;
  }
}

Future<void> _copyFileFlushed(File source, File destination) async {
  final RandomAccessFile input = await source.open();
  RandomAccessFile? output;
  try {
    output = await destination.open(mode: FileMode.write);
    while (true) {
      final Uint8List chunk = await input.read(64 * 1024);
      if (chunk.isEmpty) {
        break;
      }
      await output.writeFrom(chunk);
    }
    await output.flush();
    await output.close();
    output = null;
  } finally {
    await output?.close();
    await input.close();
  }
}

Future<void> _deleteFileIfPresent(File file) async {
  try {
    if (file.existsSync()) {
      await file.delete();
    }
  } on FileSystemException {
    if (file.existsSync()) {
      rethrow;
    }
  }
}

String _exportStem(InkDocument document) {
  final String normalized = document.name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final String name = normalized.isEmpty ? 'artwork' : normalized;
  final String clipped = name.length <= 48 ? name : name.substring(0, 48);
  return '$clipped-${_fnv64Hex(document.id)}';
}

String _fnv64Hex(String value) {
  var hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & _fnv64Mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

String _safeGeneratedId(String value) {
  if (_isDocumentStoreComponent(value)) {
    return value;
  }
  return 'ink-import-${_fnv64Hex(value)}';
}

String _exportFailureReason(Object error) => switch (error) {
  InkExportException(:final String reason) => reason,
  FileSystemException(:final String message, :final OSError? osError) =>
    osError?.message.isNotEmpty == true ? osError!.message : message,
  FormatException(:final String message) => message,
  StateError(:final String message) => message,
  _ => error.toString(),
};

String _importFailureReason(Object error) {
  final String detail = switch (error) {
    FileSystemException(:final String message, :final OSError? osError) =>
      osError?.message.isNotEmpty == true ? osError!.message : message,
    FormatException(:final String message) => message,
    ArgumentError(:final String message) => message,
    _ => error.toString(),
  };
  return 'skipped .inkpack — $detail';
}
