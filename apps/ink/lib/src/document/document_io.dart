import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'document.dart';
import 'tile_store.dart';

const String _storageRevisionKey = '_storageRevision';
const int _maxManifestLength = 16 * 1024 * 1024;
const int _maxPendingDescriptorLength = 24 * 1024 * 1024;
const int _maxGalleryLength = 16 * 1024 * 1024;
final Map<String, Future<void>> _ioGates = <String, Future<void>>{};

/// A decoded INKT payload before it is constrained to Ink's 256px tile size.
final class DecodedInkTile {
  DecodedInkTile({
    required this.width,
    required this.height,
    required Uint8List pixels,
  }) : pixels = Uint8List.fromList(pixels);

  final int width;
  final int height;

  /// RGBA8888 pixels in row-major order.
  final Uint8List pixels;
}

/// Codec for Ink's 16-byte-header, zlib-deflated `.tile` format.
abstract final class InkTileCodec {
  static const int headerLength = 16;
  static const int version = 1;
  static const int rgba8888Format = 1;

  /// Conservative bound covering zlib's worst-case overhead for one tile.
  static const int maxEncodedLength = Tile.byteLength + headerLength + 4096;

  static const int _maxPixelCount = Tile.edge * Tile.edge;

  /// Encodes an arbitrary image no larger than one Ink tile.
  ///
  /// The generic form makes the header independently testable. Persisted
  /// document tiles use [encodeTile], and are always 256 by 256.
  static Uint8List encodePixels(
    Uint8List pixels, {
    int width = Tile.edge,
    int height = Tile.edge,
  }) {
    _validateDimensions(width, height);
    final expectedLength = width * height * 4;
    if (pixels.length != expectedLength) {
      throw ArgumentError.value(
        pixels.length,
        'pixels',
        'Expected $expectedLength RGBA8888 bytes for ${width}x$height',
      );
    }

    final compressed = ZLibCodec().encode(pixels);
    final encoded = Uint8List(headerLength + compressed.length);
    encoded.setRange(0, 4, const <int>[0x49, 0x4e, 0x4b, 0x54]);
    encoded[4] = version;
    encoded[5] = rgba8888Format;
    final header = ByteData.sublistView(encoded, 0, headerLength);
    header.setUint16(6, width, Endian.big);
    header.setUint16(8, height, Endian.big);
    // Bytes 10..15 are reserved and remain zero.
    encoded.setRange(headerLength, encoded.length, compressed);
    return encoded;
  }

  static Uint8List encodeTile(Tile tile) => encodePixels(tile.pixels);

  /// Decodes and validates an INKT payload, including its inflated byte count.
  static DecodedInkTile decodePixels(Uint8List encoded) {
    if (encoded.length <= headerLength) {
      throw const FormatException('INKT payload is truncated');
    }
    if (encoded.length > maxEncodedLength) {
      throw const FormatException(
        'INKT payload exceeds the encoded-size bound',
      );
    }
    if (encoded[0] != 0x49 ||
        encoded[1] != 0x4e ||
        encoded[2] != 0x4b ||
        encoded[3] != 0x54) {
      throw const FormatException('INKT magic is invalid');
    }
    if (encoded[4] != version) {
      throw FormatException('Unsupported INKT version ${encoded[4]}');
    }
    if (encoded[5] != rgba8888Format) {
      throw FormatException('Unsupported INKT format ${encoded[5]}');
    }
    for (var index = 10; index < headerLength; index += 1) {
      if (encoded[index] != 0) {
        throw const FormatException('INKT reserved bytes must be zero');
      }
    }

    final header = ByteData.sublistView(encoded, 0, headerLength);
    final width = header.getUint16(6, Endian.big);
    final height = header.getUint16(8, Endian.big);
    _validateDimensions(width, height, formatException: true);
    final expectedLength = width * height * 4;

    final output = _BoundedByteSink(expectedLength);
    try {
      final decoder = ZLibDecoder().startChunkedConversion(output);
      for (var offset = headerLength; offset < encoded.length; offset += 4096) {
        final end = offset + 4096 < encoded.length
            ? offset + 4096
            : encoded.length;
        decoder.addSlice(encoded, offset, end, false);
      }
      decoder.close();
    } on Object catch (error) {
      throw FormatException('INKT zlib payload is invalid', error);
    }
    if (output.length != expectedLength) {
      throw FormatException(
        'INKT payload has ${output.length} bytes; expected $expectedLength',
      );
    }
    return DecodedInkTile(width: width, height: height, pixels: output.bytes);
  }

  static Tile decodeTile(Uint8List encoded) {
    final decoded = decodePixels(encoded);
    if (decoded.width != Tile.edge || decoded.height != Tile.edge) {
      throw FormatException(
        'Document tiles must be ${Tile.edge}x${Tile.edge}; '
        'found ${decoded.width}x${decoded.height}',
      );
    }
    return Tile.takeOwnership(decoded.pixels);
  }

  static void _validateDimensions(
    int width,
    int height, {
    bool formatException = false,
  }) {
    final valid =
        width > 0 &&
        height > 0 &&
        width <= 0xffff &&
        height <= 0xffff &&
        width * height <= _maxPixelCount;
    if (valid) {
      return;
    }
    if (formatException) {
      throw FormatException('Invalid INKT dimensions ${width}x$height');
    }
    throw ArgumentError('Invalid INKT dimensions ${width}x$height');
  }
}

/// Points at which tests may simulate process interruption.
enum DocumentIoPoint {
  beforeTemporaryWrite,
  afterTemporaryFlush,
  beforeAtomicRename,
  afterAtomicRename,
  afterTileWritesBeforeManifest,
  afterManifestWrite,
}

typedef DocumentIoInterrupt =
    FutureOr<void> Function(DocumentIoPoint point, File target);

typedef InkTileEncoder = FutureOr<Uint8List> Function(Tile tile);
typedef InkTileDecoder = FutureOr<Tile> Function(Uint8List encoded);
typedef InitialTileSelector =
    Iterable<TileLocation> Function(InkDocument document);

enum DocumentLoadIssueKind { missingTile, corruptTile, orphanCleanupFailed }

final class DocumentLoadIssue {
  const DocumentLoadIssue({
    required this.kind,
    required this.path,
    required this.message,
  });

  final DocumentLoadIssueKind kind;
  final String path;
  final String message;
}

/// A manifest and all of the valid tiles that could be recovered from disk.
final class LoadedInkDocument {
  LoadedInkDocument({
    required this.document,
    required this.tiles,
    required List<DocumentLoadIssue> issues,
  }) : _issues = List<DocumentLoadIssue>.of(issues),
       _loader = null;

  LoadedInkDocument._(this.document, this.tiles, this._issues, this._loader);

  final InkDocument document;
  final TileStore tiles;
  final List<DocumentLoadIssue> _issues;
  final _DeferredTileLoader? _loader;

  List<DocumentLoadIssue> get issues =>
      List<DocumentLoadIssue>.unmodifiable(_issues);

  /// Number of manifest tiles not yet attempted by the lazy loader.
  int get remainingTileCount => _loader?.remainingCount ?? 0;

  /// Attempts up to [count] deferred tiles, with at most eight reads at once.
  Future<int> loadNext({int count = 8}) async {
    if (count <= 0) {
      throw RangeError.value(count, 'count', 'must be positive');
    }
    return _loader?.loadNext(count) ?? 0;
  }

  /// Attempts every deferred tile, still decoding at most eight concurrently.
  Future<void> loadRemaining() async {
    await _loader?.loadRemaining();
  }
}

/// Rebuildable gallery metadata kept in `gallery.json`.
final class GalleryEntry {
  GalleryEntry({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.modifiedAtMs,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : unknownFields = Map<String, Object?>.unmodifiable(unknownFields);

  factory GalleryEntry.fromDocument(InkDocument document) => GalleryEntry(
    id: document.id,
    name: document.name,
    createdAtMs: document.createdAtMs,
    modifiedAtMs: document.modifiedAtMs,
  );

  factory GalleryEntry.fromJson(Map<String, Object?> json) {
    const known = <String>{'id', 'name', 'createdAtMs', 'modifiedAtMs'};
    final id = json['id'];
    final name = json['name'];
    final createdAtMs = json['createdAtMs'];
    final modifiedAtMs = json['modifiedAtMs'];
    if (id is! String ||
        name is! String ||
        createdAtMs is! int ||
        modifiedAtMs is! int) {
      throw const FormatException('Invalid gallery entry');
    }
    _requireSafePathComponent(id, label: 'gallery artwork id');
    return GalleryEntry(
      id: id,
      name: name,
      createdAtMs: createdAtMs,
      modifiedAtMs: modifiedAtMs,
      unknownFields: <String, Object?>{
        for (final entry in json.entries)
          if (!known.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  final String id;
  final String name;
  final int createdAtMs;
  final int modifiedAtMs;
  final Map<String, Object?> unknownFields;

  Map<String, Object?> toJson() => <String, Object?>{
    ...unknownFields,
    'id': id,
    'name': name,
    'createdAtMs': createdAtMs,
    'modifiedAtMs': modifiedAtMs,
  };
}

/// Crash-safe persistence rooted at Ink's channel-provided documents folder.
final class DocumentStore {
  DocumentStore({
    required this.root,
    int Function()? clock,
    int Function()? nowMilliseconds,
    this.interrupt,
    this.tileEncoder = InkTileCodec.encodeTile,
    this.tileDecoder = InkTileCodec.decodeTile,
  }) : _clock = _resolveClock(clock, nowMilliseconds),
       assert(clock == null || nowMilliseconds == null);

  final Directory root;
  final int Function() _clock;
  final DocumentIoInterrupt? interrupt;
  final InkTileEncoder tileEncoder;
  final InkTileDecoder tileDecoder;

  Directory get artworksDirectory => Directory('${root.path}/artworks');
  Directory get trashDirectory => Directory('${root.path}/trash');
  File get galleryFile => File('${root.path}/gallery.json');

  Directory artworkDirectory(String id) {
    _requireSafePathComponent(id, label: 'artwork id');
    return Directory('${artworksDirectory.path}/$id');
  }

  File manifestFile(String id) =>
      File('${artworkDirectory(id).path}/manifest.json');

  File tileFile(String documentId, TileLocation location) =>
      _tileFile(documentId, location);

  Future<T> _withArtworkGate<T>(
    String documentId,
    Future<T> Function() action,
  ) => _withIoGate(artworkDirectory(documentId).absolute.path, action);

  Future<T> _withGalleryGate<T>(Future<T> Function() action) =>
      _withIoGate('gallery:${galleryFile.absolute.path}', action);

  /// Saves current occupied tiles first and publishes the manifest last.
  ///
  /// With [dirtyTiles], already-persisted unchanged tiles are skipped. Any
  /// occupied tile missing from disk is still written, preserving the rule
  /// that a committed manifest never references a missing file.
  /// Partially loaded documents must pass their changed locations in
  /// [dirtyTiles], which retains the manifest's unloaded tile baseline. A null
  /// value declares [tiles] to be the complete raster truth.
  Future<InkDocument> saveDocument(
    InkDocument document,
    TileStore tiles, {
    Iterable<TileLocation>? dirtyTiles,
    InkTileEncoder? tileEncoder,
  }) async {
    _requireSafePathComponent(document.id, label: 'artwork id');
    for (final layer in document.layers) {
      _requireSafePathComponent(layer.id, label: 'layer id');
    }
    // COW tiles are immutable, so this map-only fork freezes one coherent
    // generation without copying buffers or blocking subsequent strokes.
    final frozenTiles = tiles.fork();
    final dirty = dirtyTiles?.toSet();
    final encode = tileEncoder ?? this.tileEncoder;
    var insertGalleryAtFront = false;
    final persisted = await _withArtworkGate(document.id, () async {
      await _recoverPendingSave(document.id);
      final artwork = artworkDirectory(document.id);
      await artwork.create(recursive: true);
      insertGalleryAtFront = !manifestFile(document.id).existsSync();
      final storageRevision = await _nextStorageRevision(document.id);
      final retainedBaselineTiles = dirty == null
          ? null
          : _retainedBaselineTiles(document, frozenTiles);
      final manifest = _manifestWithOccupiedTiles(
        document,
        frozenTiles,
        storageRevision: storageRevision,
        dirtyTiles: dirty,
        retainedBaselineTiles: retainedBaselineTiles,
      );
      final manifestBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(manifest)),
      );
      final locations = <TileLocation>[];

      for (final layer in document.layers) {
        for (final key in frozenTiles.occupiedKeys(layer.id)) {
          final location = TileLocation(layerId: layer.id, key: key);
          final file = _tileFile(document.id, location);
          if (dirty == null || dirty.contains(location) || !file.existsSync()) {
            locations.add(location);
          }
        }
      }
      locations.sort(_compareLocations);

      await _preparePendingSave(document.id, locations, manifestBytes);

      for (var offset = 0; offset < locations.length; offset += 8) {
        final end = offset + 8 < locations.length
            ? offset + 8
            : locations.length;
        final encoded = await Future.wait(<Future<_EncodedTile>>[
          for (var index = offset; index < end; index += 1)
            Future<_EncodedTile>(() async {
              final location = locations[index];
              final tile = frozenTiles.tile(location.layerId, location.key)!;
              final bytes = await encode(tile);
              if (bytes.length > InkTileCodec.maxEncodedLength) {
                throw const FormatException(
                  'Encoded tile exceeds the size bound',
                );
              }
              return _EncodedTile(location: location, bytes: bytes);
            }),
        ]);
        for (final item in encoded) {
          await _atomicWrite(_tileFile(document.id, item.location), item.bytes);
        }
      }

      await _callInterrupt(
        DocumentIoPoint.afterTileWritesBeforeManifest,
        manifestFile(document.id),
      );
      await _atomicWrite(manifestFile(document.id), manifestBytes);
      await _callInterrupt(
        DocumentIoPoint.afterManifestWrite,
        manifestFile(document.id),
      );
      await _discardCommittedPendingSave(document.id);
      return InkDocument.fromJson(manifest);
    });
    // Gallery metadata is a cache. A failure here must not turn a completed
    // document commit into a failed save.
    try {
      await _upsertGallery(
        GalleryEntry.fromDocument(persisted),
        insertAtFront: insertGalleryAtFront,
      );
    } on Object {
      // loadGallery() will rebuild it when it is absent/corrupt.
    }
    return persisted;
  }

  /// Opens a document, quarantining bad components and retaining good ones.
  ///
  /// When [initialTiles] or [initialTileSelector] is supplied, only the chosen
  /// manifest locations are read before return. The selector runs after the
  /// saved view/canvas have been decoded. Call [LoadedInkDocument.loadNext] or
  /// [LoadedInkDocument.loadRemaining] during idle time for the rest. Omitting
  /// it retains the eager behavior used by existing callers.
  Future<LoadedInkDocument?> openDocument(
    String id, {
    Iterable<TileLocation>? initialTiles,
    InitialTileSelector? initialTileSelector,
    InkTileDecoder? tileDecoder,
  }) async {
    if (initialTiles != null && initialTileSelector != null) {
      throw ArgumentError(
        'Pass initialTiles or initialTileSelector, not both.',
      );
    }
    _requireSafePathComponent(id, label: 'artwork id');
    return _withArtworkGate(id, () async {
      try {
        await _recoverPendingSave(id);
      } on Object {
        // An incomplete transaction must never expose a mixed raster state.
        return null;
      }
      final manifest = manifestFile(id);
      if (!manifest.existsSync()) {
        return null;
      }

      late final InkDocument document;
      late final Map<String, Object?> manifestJson;
      late final List<_TileReference> references;
      try {
        final manifestBytes = await _readFileBounded(
          manifest,
          maxLength: _maxManifestLength,
        );
        manifestJson = _decodeJsonObject(utf8.decode(manifestBytes));
        document = InkDocument.fromJson(manifestJson);
        if (document.id != id) {
          throw const FormatException(
            'Manifest artwork id does not match its directory',
          );
        }
        references = _tileReferences(manifestJson);
      } on Object {
        await quarantine(manifest);
        return null;
      }

      final tiles = TileStore();
      final issues = <DocumentLoadIssue>[];
      final referencedPaths = <String>{
        for (final reference in references)
          _tileFile(id, reference.location).absolute.path,
      };
      final selectedInitialTiles =
          initialTileSelector?.call(document) ?? initialTiles;
      final decode = tileDecoder ?? this.tileDecoder;
      final partition = _partitionReferences(references, selectedInitialTiles);
      await _loadTileReferences(id, partition.initial, tiles, issues, decode);

      try {
        await _collectOrphans(id, referencedPaths);
        await _deleteIfPresent(File('${manifest.path}.tmp'));
      } on Object catch (error) {
        issues.add(
          DocumentLoadIssue(
            kind: DocumentLoadIssueKind.orphanCleanupFailed,
            path: artworkDirectory(id).path,
            message: '$error',
          ),
        );
      }

      final loader = partition.remaining.isEmpty
          ? null
          : _DeferredTileLoader(
              store: this,
              documentId: id,
              pending: partition.remaining,
              tiles: tiles,
              issues: issues,
              tileDecoder: decode,
            );
      return LoadedInkDocument._(document, tiles, issues, loader);
    });
  }

  Future<LoadedInkDocument?> loadDocument(
    String id, {
    Iterable<TileLocation>? initialTiles,
    InitialTileSelector? initialTileSelector,
    InkTileDecoder? tileDecoder,
  }) => openDocument(
    id,
    initialTiles: initialTiles,
    initialTileSelector: initialTileSelector,
    tileDecoder: tileDecoder,
  );

  /// Loads gallery ordering, rebuilding it by scanning manifests if needed.
  Future<List<GalleryEntry>> loadGallery({bool forceRebuild = false}) =>
      _withGalleryGate(() => _loadGalleryUnlocked(forceRebuild: forceRebuild));

  Future<List<GalleryEntry>> _loadGalleryUnlocked({
    required bool forceRebuild,
  }) async {
    if (!forceRebuild && galleryFile.existsSync()) {
      try {
        final bytes = await _readFileBounded(
          galleryFile,
          maxLength: _maxGalleryLength,
        );
        final json = _decodeJsonObject(utf8.decode(bytes));
        if (json['schema'] != 1) {
          throw const FormatException('Unsupported gallery schema');
        }
        final artworks = json['artworks'];
        if (artworks is! List<Object?>) {
          throw const FormatException('Gallery artworks is not a list');
        }
        final result = <GalleryEntry>[];
        final ids = <String>{};
        for (final raw in artworks) {
          if (raw is! Map<String, Object?>) {
            throw const FormatException('Gallery entry is not an object');
          }
          final entry = GalleryEntry.fromJson(raw);
          if (!ids.add(entry.id)) {
            throw const FormatException('Gallery contains duplicate ids');
          }
          result.add(entry);
        }
        await _deleteIfPresent(File('${galleryFile.path}.tmp'));
        return _reconcileGallery(result);
      } on Object {
        await quarantine(galleryFile);
      }
    }
    return _rebuildGalleryUnlocked();
  }

  Future<List<GalleryEntry>> rebuildGallery() =>
      _withGalleryGate(_rebuildGalleryUnlocked);

  Future<List<GalleryEntry>> _rebuildGalleryUnlocked() async {
    final scan = await _scanGalleryEntries();
    final entries = scan.entries;
    entries.sort((left, right) {
      final byModified = right.modifiedAtMs.compareTo(left.modifiedAtMs);
      return byModified != 0 ? byModified : left.id.compareTo(right.id);
    });
    if (scan.isComplete) {
      try {
        await _saveGalleryUnlocked(entries);
      } on Object {
        // gallery.json is only a cache; scanned metadata remains usable.
      }
    }
    return List<GalleryEntry>.unmodifiable(entries);
  }

  Future<_GalleryScan> _scanGalleryEntries() async {
    final entries = <GalleryEntry>[];
    var isComplete = true;
    try {
      if (!artworksDirectory.existsSync()) {
        return _GalleryScan(entries: entries, isComplete: true);
      }
      await for (final entity in artworksDirectory.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        final id = entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        try {
          _requireSafePathComponent(id, label: 'artwork directory');
          final result = await _scanGalleryEntry(id, entity);
          if (!result.isConclusive) {
            isComplete = false;
          } else if (result.entry != null) {
            entries.add(result.entry!);
          }
        } on Object {
          // Keep ambiguous transactions intact and continue with other art.
          isComplete = false;
        }
      }
    } on Object {
      isComplete = false;
    }
    return _GalleryScan(entries: entries, isComplete: isComplete);
  }

  Future<_GalleryEntryScan> _scanGalleryEntry(
    String documentId,
    Directory artwork,
  ) => _withArtworkGate(documentId, () async {
    try {
      await _recoverPendingSave(documentId);
    } on Object {
      return const _GalleryEntryScan.indeterminate();
    }
    final manifest = File('${artwork.path}/manifest.json');
    if (!manifest.existsSync()) {
      return const _GalleryEntryScan.absent();
    }
    try {
      final bytes = await _readFileBounded(
        manifest,
        maxLength: _maxManifestLength,
      );
      final json = _decodeJsonObject(utf8.decode(bytes));
      final document = InkDocument.fromJson(json);
      if (document.id != documentId) {
        throw const FormatException(
          'Manifest artwork id does not match its directory',
        );
      }
      return _GalleryEntryScan.found(GalleryEntry.fromDocument(document));
    } on Object {
      if (manifest.existsSync()) {
        await quarantine(manifest);
      }
      return const _GalleryEntryScan.absent();
    }
  });

  Future<List<GalleryEntry>> _reconcileGallery(
    List<GalleryEntry> cached,
  ) async {
    final scan = await _scanGalleryEntries();
    final byId = <String, GalleryEntry>{
      for (final entry in scan.entries) entry.id: entry,
    };
    final reconciled = <GalleryEntry>[];
    for (final cachedEntry in cached) {
      final current = byId.remove(cachedEntry.id);
      if (current == null) {
        if (!scan.isComplete) {
          reconciled.add(cachedEntry);
        }
        continue;
      }
      reconciled.add(
        GalleryEntry(
          id: current.id,
          name: current.name,
          createdAtMs: current.createdAtMs,
          modifiedAtMs: current.modifiedAtMs,
          unknownFields: cachedEntry.unknownFields,
        ),
      );
    }
    final additions = byId.values.toList()
      ..sort((left, right) {
        final byModified = right.modifiedAtMs.compareTo(left.modifiedAtMs);
        return byModified != 0 ? byModified : left.id.compareTo(right.id);
      });
    reconciled.addAll(additions);

    final changed =
        cached.length != reconciled.length ||
        <bool>[
          for (var index = 0; index < cached.length; index += 1)
            if (index >= reconciled.length ||
                !_sameGalleryMetadata(cached[index], reconciled[index]))
              true,
        ].isNotEmpty;
    if (changed) {
      try {
        await _saveGalleryUnlocked(reconciled);
      } on Object {
        // Reconciliation remains authoritative even when cache repair fails.
      }
    }
    return List<GalleryEntry>.unmodifiable(reconciled);
  }

  Future<void> saveGallery(List<GalleryEntry> entries) =>
      _withGalleryGate(() => _saveGalleryUnlocked(entries));

  Future<void> _saveGalleryUnlocked(List<GalleryEntry> entries) async {
    final ids = <String>{};
    for (final entry in entries) {
      _requireSafePathComponent(entry.id, label: 'gallery artwork id');
      if (!ids.add(entry.id)) {
        throw ArgumentError.value(entry.id, 'entries', 'Duplicate gallery id');
      }
    }
    final payload = <String, Object?>{
      'schema': 1,
      'artworks': <Object?>[for (final entry in entries) entry.toJson()],
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    if (bytes.length > _maxGalleryLength) {
      throw const FormatException('Gallery cache exceeds the size bound');
    }
    await _atomicWrite(galleryFile, bytes);
  }

  /// Moves [file] aside without allowing a rename failure to block opening.
  Future<File?> quarantine(File file) async {
    if (!file.existsSync()) {
      return null;
    }
    final basePath = '${file.path}.corrupt-${_clock()}';
    var candidate = File(basePath);
    var suffix = 1;
    while (candidate.existsSync()) {
      candidate = File('$basePath.$suffix');
      suffix += 1;
    }
    try {
      return await file.rename(candidate.path);
    } on Object {
      return null;
    }
  }

  Future<int> _loadTileReferences(
    String documentId,
    List<_TileReference> references,
    TileStore tiles,
    List<DocumentLoadIssue> issues,
    InkTileDecoder decoder,
  ) async {
    for (var offset = 0; offset < references.length; offset += 8) {
      final end = offset + 8 < references.length
          ? offset + 8
          : references.length;
      final batch = await Future.wait(<Future<_LoadedTile?>>[
        for (var index = offset; index < end; index += 1)
          _readTile(documentId, references[index], issues, decoder),
      ]);
      for (final loaded in batch) {
        if (loaded != null) {
          tiles.publish(
            loaded.location.layerId,
            loaded.location.key,
            loaded.tile,
          );
        }
      }
    }
    return references.length;
  }

  Future<_LoadedTile?> _readTile(
    String documentId,
    _TileReference reference,
    List<DocumentLoadIssue> issues,
    InkTileDecoder decoder,
  ) async {
    final file = _tileFile(documentId, reference.location);
    if (!file.existsSync()) {
      issues.add(
        DocumentLoadIssue(
          kind: DocumentLoadIssueKind.missingTile,
          path: file.path,
          message: 'Referenced tile is missing',
        ),
      );
      return null;
    }
    try {
      final encoded = await _readFileBounded(
        file,
        maxLength: InkTileCodec.maxEncodedLength,
      );
      final tile = await decoder(encoded);
      return _LoadedTile(location: reference.location, tile: tile);
    } on Object catch (error) {
      await quarantine(file);
      issues.add(
        DocumentLoadIssue(
          kind: DocumentLoadIssueKind.corruptTile,
          path: file.path,
          message: '$error',
        ),
      );
      return null;
    }
  }

  Future<void> _upsertGallery(
    GalleryEntry entry, {
    required bool insertAtFront,
  }) => _withGalleryGate(() async {
    final entries = (await _loadGalleryUnlocked(forceRebuild: false)).toList();
    final existing = entries.indexWhere(
      (candidate) => candidate.id == entry.id,
    );
    final previous = existing < 0 ? null : entries[existing];
    final updated = GalleryEntry(
      id: entry.id,
      name: entry.name,
      createdAtMs: entry.createdAtMs,
      modifiedAtMs: entry.modifiedAtMs,
      unknownFields: previous?.unknownFields ?? const <String, Object?>{},
    );
    if (insertAtFront) {
      if (existing >= 0) {
        entries.removeAt(existing);
      }
      entries.insert(0, updated);
    } else if (existing < 0) {
      entries.insert(0, updated);
    } else {
      entries[existing] = updated;
    }
    await _saveGalleryUnlocked(entries);
  });

  Future<int> _nextStorageRevision(String documentId) async {
    final manifest = manifestFile(documentId);
    if (!manifest.existsSync()) {
      return 1;
    }
    final bytes = await _readFileBounded(
      manifest,
      maxLength: _maxManifestLength,
    );
    final json = _decodeJsonObject(utf8.decode(bytes));
    final revision = json[_storageRevisionKey];
    if (revision == null) {
      return 1;
    }
    if (revision is! int || revision < 0) {
      throw const FormatException('Invalid manifest storage revision');
    }
    return revision + 1;
  }

  Future<void> _preparePendingSave(
    String documentId,
    List<TileLocation> locations,
    Uint8List intendedManifest,
  ) async {
    if (intendedManifest.length > _maxManifestLength) {
      throw const FormatException('Manifest exceeds the size bound');
    }
    final pending = _pendingSaveDirectory(documentId);
    if (pending.existsSync()) {
      await pending.delete(recursive: true);
    }
    await pending.create(recursive: true);

    final records = <_PendingTileRecord>[];
    for (var index = 0; index < locations.length; index += 1) {
      final location = locations[index];
      final target = _tileFile(documentId, location);
      final hadExisting = target.existsSync();
      if (hadExisting) {
        final oldBytes = await _readFileBounded(
          target,
          maxLength: InkTileCodec.maxEncodedLength,
        );
        await _atomicWrite(_pendingBackupFile(documentId, index), oldBytes);
      }
      records.add(
        _PendingTileRecord(location: location, hadExisting: hadExisting),
      );
    }

    final descriptor = _PendingSaveDescriptor(
      documentId: documentId,
      intendedManifest: intendedManifest,
      tiles: records,
    );
    await _atomicWrite(
      _pendingDescriptorFile(documentId),
      Uint8List.fromList(utf8.encode(jsonEncode(descriptor.toJson()))),
    );
  }

  Future<void> _recoverPendingSave(String documentId) async {
    final pending = _pendingSaveDirectory(documentId);
    if (!pending.existsSync()) {
      return;
    }
    final descriptorFile = _pendingDescriptorFile(documentId);
    if (!descriptorFile.existsSync()) {
      // Tile publication starts only after the descriptor rename. A directory
      // without it therefore contains backup/temporary preparation debris.
      await pending.delete(recursive: true);
      return;
    }

    final descriptorBytes = await _readFileBounded(
      descriptorFile,
      maxLength: _maxPendingDescriptorLength,
    );
    final descriptor = _PendingSaveDescriptor.fromJson(
      _decodeJsonObject(utf8.decode(descriptorBytes)),
      expectedDocumentId: documentId,
    );
    final manifest = manifestFile(documentId);
    final currentManifest = manifest.existsSync()
        ? await _readFileBounded(manifest, maxLength: _maxManifestLength)
        : null;
    if (currentManifest != null &&
        _bytesEqual(currentManifest, descriptor.intendedManifest)) {
      await _discardCommittedPendingSave(documentId);
      return;
    }

    for (var index = 0; index < descriptor.tiles.length; index += 1) {
      final record = descriptor.tiles[index];
      final target = _tileFile(documentId, record.location);
      if (record.hadExisting) {
        final backup = _pendingBackupFile(documentId, index);
        if (!backup.existsSync()) {
          throw const FormatException('Pending save is missing a tile backup');
        }
        final oldBytes = await _readFileBounded(
          backup,
          maxLength: InkTileCodec.maxEncodedLength,
        );
        await _atomicWrite(target, oldBytes);
      } else {
        await _deleteStrictIfPresent(target);
        await _deleteStrictIfPresent(File('${target.path}.tmp'));
      }
    }
    await _deleteStrictIfPresent(File('${manifest.path}.tmp'));

    // Removing the descriptor is the rollback commit point. If restoration is
    // interrupted before here, every backup remains for an idempotent retry.
    await _deleteStrictIfPresent(descriptorFile);
    await _deleteDirectoryBestEffort(pending);
  }

  Future<void> _discardCommittedPendingSave(String documentId) async {
    final pending = _pendingSaveDirectory(documentId);
    if (!pending.existsSync()) {
      return;
    }
    await _deleteStrictIfPresent(_pendingDescriptorFile(documentId));
    await _deleteDirectoryBestEffort(pending);
  }

  Directory _pendingSaveDirectory(String documentId) =>
      Directory('${artworkDirectory(documentId).path}/.pending-save');

  File _pendingDescriptorFile(String documentId) =>
      File('${_pendingSaveDirectory(documentId).path}/descriptor.json');

  File _pendingBackupFile(String documentId, int index) => File(
    '${_pendingSaveDirectory(documentId).path}/backups/'
    '${index.toString().padLeft(6, '0')}.tile',
  );

  Map<String, Object?> _manifestWithOccupiedTiles(
    InkDocument document,
    TileStore tiles, {
    required int storageRevision,
    required Set<TileLocation>? dirtyTiles,
    required Set<TileLocation>? retainedBaselineTiles,
  }) {
    final manifest = _decodeJsonObject(jsonEncode(document.toJson()));
    manifest[_storageRevisionKey] = storageRevision;
    final layers = manifest['layers'];
    if (layers is! List<Object?> || layers.length != document.layers.length) {
      throw const FormatException('Document emitted an invalid layer list');
    }
    final documentLayers = <String, InkLayer>{
      for (final layer in document.layers) layer.id: layer,
    };
    for (final rawLayer in layers) {
      if (rawLayer is! Map<String, Object?>) {
        throw const FormatException('Document emitted an invalid layer');
      }
      final id = rawLayer['id'];
      if (id is! String) {
        throw const FormatException('Document emitted a layer without an id');
      }
      final keys = dirtyTiles == null
          ? tiles.occupiedKeys(id).toSet()
          : <TileKey>{
              for (final key in documentLayers[id]!.tiles)
                if (retainedBaselineTiles!.contains(
                  TileLocation(layerId: id, key: key),
                ))
                  key,
              ...tiles.occupiedKeys(id),
            };
      if (dirtyTiles != null) {
        for (final location in dirtyTiles) {
          if (location.layerId != id) {
            continue;
          }
          if (tiles.tile(id, location.key) == null) {
            keys.remove(location.key);
          } else {
            keys.add(location.key);
          }
        }
      }
      final sortedKeys = keys.toList()..sort();
      rawLayer['tiles'] = <Object?>[
        for (final key in sortedKeys) <int>[key.x, key.y],
      ];
    }
    return manifest;
  }

  Set<TileLocation> _retainedBaselineTiles(
    InkDocument document,
    TileStore tiles,
  ) => <TileLocation>{
    for (final layer in document.layers)
      for (final key in layer.tiles)
        if (tiles.tile(layer.id, key) != null ||
            _tileFile(
              document.id,
              TileLocation(layerId: layer.id, key: key),
            ).existsSync())
          TileLocation(layerId: layer.id, key: key),
  };

  List<_TileReference> _tileReferences(Map<String, Object?> manifest) {
    final layers = manifest['layers'];
    if (layers is! List<Object?>) {
      throw const FormatException('Manifest layers is not a list');
    }
    final references = <_TileReference>[];
    for (final rawLayer in layers) {
      if (rawLayer is! Map<String, Object?>) {
        throw const FormatException('Manifest layer is not an object');
      }
      final layerId = rawLayer['id'];
      if (layerId is! String) {
        throw const FormatException('Manifest layer has no id');
      }
      _requireSafePathComponent(layerId, label: 'layer id');
      final rawTiles = rawLayer['tiles'];
      if (rawTiles == null) {
        continue;
      }
      if (rawTiles is! List<Object?>) {
        throw const FormatException('Manifest tile list is invalid');
      }
      final seen = <TileKey>{};
      for (final rawTile in rawTiles) {
        if (rawTile is! List<Object?> ||
            rawTile.length != 2 ||
            rawTile[0] is! int ||
            rawTile[1] is! int) {
          throw const FormatException('Manifest tile coordinate is invalid');
        }
        final key = TileKey(rawTile[0]! as int, rawTile[1]! as int);
        if (!seen.add(key)) {
          throw const FormatException('Manifest tile coordinate is duplicated');
        }
        references.add(
          _TileReference(TileLocation(layerId: layerId, key: key)),
        );
      }
    }
    references.sort(
      (left, right) => _compareLocations(left.location, right.location),
    );
    return references;
  }

  Future<void> _collectOrphans(
    String documentId,
    Set<String> referencedPaths,
  ) async {
    final layers = Directory('${artworkDirectory(documentId).path}/layers');
    if (!layers.existsSync()) {
      return;
    }
    await for (final entity in layers.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final path = entity.absolute.path;
      if (path.endsWith('.tile') && !referencedPaths.contains(path)) {
        await _deleteIfPresent(entity);
      } else if (path.endsWith('.tile.tmp')) {
        await _deleteIfPresent(entity);
      }
    }
  }

  Future<void> _atomicWrite(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await _callInterrupt(DocumentIoPoint.beforeTemporaryWrite, target);
    final handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
      await _callInterrupt(DocumentIoPoint.afterTemporaryFlush, target);
    } finally {
      await handle.close();
    }
    await _callInterrupt(DocumentIoPoint.beforeAtomicRename, target);
    await temporary.rename(target.path);
    await _callInterrupt(DocumentIoPoint.afterAtomicRename, target);
  }

  Future<void> _callInterrupt(DocumentIoPoint point, File target) async {
    final callback = interrupt;
    if (callback != null) {
      await callback(point, target);
    }
  }

  File _tileFile(String documentId, TileLocation location) {
    _requireSafePathComponent(documentId, label: 'artwork id');
    _requireSafePathComponent(location.layerId, label: 'layer id');
    return File(
      '${artworkDirectory(documentId).path}/layers/${location.layerId}/'
      '${location.key.fileName}',
    );
  }
}

final class _TileReference {
  const _TileReference(this.location);

  final TileLocation location;
}

final class _LoadedTile {
  const _LoadedTile({required this.location, required this.tile});

  final TileLocation location;
  final Tile tile;
}

final class _EncodedTile {
  const _EncodedTile({required this.location, required this.bytes});

  final TileLocation location;
  final Uint8List bytes;
}

final class _ReferencePartition {
  const _ReferencePartition({required this.initial, required this.remaining});

  final List<_TileReference> initial;
  final List<_TileReference> remaining;
}

final class _GalleryScan {
  const _GalleryScan({required this.entries, required this.isComplete});

  final List<GalleryEntry> entries;
  final bool isComplete;
}

final class _GalleryEntryScan {
  const _GalleryEntryScan.found(this.entry) : isConclusive = true;

  const _GalleryEntryScan.absent() : entry = null, isConclusive = true;

  const _GalleryEntryScan.indeterminate() : entry = null, isConclusive = false;

  final GalleryEntry? entry;
  final bool isConclusive;
}

final class _DeferredTileLoader {
  _DeferredTileLoader({
    required this.store,
    required this.documentId,
    required List<_TileReference> pending,
    required this.tiles,
    required this.issues,
    required this.tileDecoder,
  }) : _pending = List<_TileReference>.of(pending);

  final DocumentStore store;
  final String documentId;
  final TileStore tiles;
  final List<DocumentLoadIssue> issues;
  final InkTileDecoder tileDecoder;
  final List<_TileReference> _pending;
  bool _isLoading = false;

  int get remainingCount => _pending.length;

  Future<int> loadNext(int count) async {
    if (_isLoading) {
      throw StateError('A deferred tile load is already active.');
    }
    if (_pending.isEmpty) {
      return 0;
    }
    _isLoading = true;
    final take = count < _pending.length ? count : _pending.length;
    final batch = _pending.sublist(0, take);
    _pending.removeRange(0, take);
    try {
      return await store._withArtworkGate(
        documentId,
        () => store._loadTileReferences(
          documentId,
          batch,
          tiles,
          issues,
          tileDecoder,
        ),
      );
    } on Object {
      _pending.insertAll(0, batch);
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  Future<void> loadRemaining() async {
    while (_pending.isNotEmpty) {
      await loadNext(_pending.length);
    }
  }
}

final class _PendingTileRecord {
  const _PendingTileRecord({required this.location, required this.hadExisting});

  factory _PendingTileRecord.fromJson(Map<String, Object?> json) {
    final layerId = json['layerId'];
    final x = json['x'];
    final y = json['y'];
    final hadExisting = json['hadExisting'];
    if (layerId is! String || x is! int || y is! int || hadExisting is! bool) {
      throw const FormatException('Invalid pending tile record');
    }
    _requireSafePathComponent(layerId, label: 'pending layer id');
    return _PendingTileRecord(
      location: TileLocation(layerId: layerId, key: TileKey(x, y)),
      hadExisting: hadExisting,
    );
  }

  final TileLocation location;
  final bool hadExisting;

  Map<String, Object?> toJson() => <String, Object?>{
    'layerId': location.layerId,
    'x': location.key.x,
    'y': location.key.y,
    'hadExisting': hadExisting,
  };
}

final class _PendingSaveDescriptor {
  _PendingSaveDescriptor({
    required this.documentId,
    required Uint8List intendedManifest,
    required List<_PendingTileRecord> tiles,
  }) : intendedManifest = Uint8List.fromList(intendedManifest),
       tiles = List<_PendingTileRecord>.unmodifiable(tiles);

  factory _PendingSaveDescriptor.fromJson(
    Map<String, Object?> json, {
    required String expectedDocumentId,
  }) {
    if (json['schema'] != 1 || json['documentId'] != expectedDocumentId) {
      throw const FormatException('Invalid pending save descriptor');
    }
    final encodedManifest = json['intendedManifest'];
    final rawTiles = json['tiles'];
    if (encodedManifest is! String || rawTiles is! List<Object?>) {
      throw const FormatException('Invalid pending save descriptor payload');
    }
    if (rawTiles.length > 4096) {
      throw const FormatException('Pending save has too many tile records');
    }
    late final Uint8List intendedManifest;
    try {
      intendedManifest = base64Decode(encodedManifest);
    } on Object catch (error) {
      throw FormatException('Invalid pending manifest encoding', error);
    }
    if (intendedManifest.length > _maxManifestLength) {
      throw const FormatException('Pending manifest exceeds the size bound');
    }
    final intendedJson = _decodeJsonObject(utf8.decode(intendedManifest));
    if (intendedJson['id'] != expectedDocumentId ||
        intendedJson[_storageRevisionKey] is! int) {
      throw const FormatException('Pending manifest commit token is invalid');
    }

    final records = <_PendingTileRecord>[];
    final locations = <TileLocation>{};
    for (final raw in rawTiles) {
      if (raw is! Map<String, Object?>) {
        throw const FormatException('Pending tile record is not an object');
      }
      final record = _PendingTileRecord.fromJson(raw);
      if (!locations.add(record.location)) {
        throw const FormatException('Pending tile record is duplicated');
      }
      records.add(record);
    }
    return _PendingSaveDescriptor(
      documentId: expectedDocumentId,
      intendedManifest: intendedManifest,
      tiles: records,
    );
  }

  final String documentId;
  final Uint8List intendedManifest;
  final List<_PendingTileRecord> tiles;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'documentId': documentId,
    'intendedManifest': base64Encode(intendedManifest),
    'tiles': <Object?>[for (final tile in tiles) tile.toJson()],
  };
}

_ReferencePartition _partitionReferences(
  List<_TileReference> references,
  Iterable<TileLocation>? initialTiles,
) {
  if (initialTiles == null) {
    return _ReferencePartition(
      initial: List<_TileReference>.of(references),
      remaining: const <_TileReference>[],
    );
  }
  final byLocation = <TileLocation, _TileReference>{
    for (final reference in references) reference.location: reference,
  };
  final selectedLocations = <TileLocation>{};
  final initial = <_TileReference>[];
  for (final location in initialTiles) {
    final reference = byLocation[location];
    if (reference != null && selectedLocations.add(location)) {
      initial.add(reference);
    }
  }
  return _ReferencePartition(
    initial: initial,
    remaining: <_TileReference>[
      for (final reference in references)
        if (!selectedLocations.contains(reference.location)) reference,
    ],
  );
}

final class _BoundedByteSink extends ByteConversionSink {
  _BoundedByteSink(this._limit) : _bytes = Uint8List(_limit);

  final int _limit;
  final Uint8List _bytes;
  int _length = 0;

  int get length => _length;
  Uint8List get bytes => _bytes;

  @override
  void add(List<int> chunk) {
    if (_length + chunk.length > _limit) {
      throw const FormatException(
        'INKT payload inflates beyond its dimensions',
      );
    }
    _bytes.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  @override
  void close() {}
}

int _compareLocations(TileLocation left, TileLocation right) {
  final byLayer = left.layerId.compareTo(right.layerId);
  return byLayer != 0 ? byLayer : left.key.compareTo(right.key);
}

bool _sameGalleryMetadata(GalleryEntry left, GalleryEntry right) =>
    left.id == right.id &&
    left.name == right.name &&
    left.createdAtMs == right.createdAtMs &&
    left.modifiedAtMs == right.modifiedAtMs;

Map<String, Object?> _decodeJsonObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('JSON root is not an object');
  }
  return decoded;
}

void _requireSafePathComponent(String value, {required String label}) {
  final safe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  if (!safe.hasMatch(value) || value == '.' || value == '..') {
    throw FormatException('Invalid $label');
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (file.existsSync()) {
      await file.delete();
    }
  } on Object {
    // Cleanup is best-effort; the authoritative committed file remains safe.
  }
}

Future<Uint8List> _readFileBounded(File file, {required int maxLength}) async {
  final length = await file.length();
  if (length > maxLength) {
    throw FormatException(
      '${file.path} has $length bytes; maximum is $maxLength',
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maxLength) {
    throw FormatException(
      '${file.path} grew beyond the $maxLength-byte bound while reading',
    );
  }
  return bytes;
}

Future<void> _deleteStrictIfPresent(File file) async {
  if (file.existsSync()) {
    await file.delete();
  }
}

Future<void> _deleteDirectoryBestEffort(Directory directory) async {
  try {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  } on Object {
    // The descriptor has already been removed; remaining backups are inert.
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

Future<T> _withIoGate<T>(String key, Future<T> Function() action) {
  final previous = _ioGates[key] ?? Future<void>.value();
  final result = Completer<T>();
  late final Future<void> tail;
  tail = previous.then((_) async {
    try {
      result.complete(await action());
    } on Object catch (error, stackTrace) {
      result.completeError(error, stackTrace);
    }
  });
  _ioGates[key] = tail;
  unawaited(
    tail.whenComplete(() {
      if (identical(_ioGates[key], tail)) {
        _ioGates.remove(key);
      }
    }),
  );
  return result.future;
}

int _systemClock() => DateTime.now().millisecondsSinceEpoch;

int Function() _resolveClock(
  int Function()? clock,
  int Function()? nowMilliseconds,
) {
  if (clock != null && nowMilliseconds != null) {
    throw ArgumentError('Pass only one clock function.');
  }
  return nowMilliseconds ?? clock ?? _systemClock;
}
