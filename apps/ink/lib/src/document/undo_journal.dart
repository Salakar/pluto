import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'document.dart';
import 'document_io.dart';
import 'tile_store.dart';

/// Every user-action kind persisted by Ink's undo journal.
enum JournalKind {
  stroke,
  erase,
  fill,
  shape,
  text,
  floatCommit,
  layerAdd,
  layerRemove,
  layerReorder,
  layerProps,
  layerClear,
  canvasResize,
  canvasFlip,
  merge,
}

extension on JournalKind {
  bool get isRecipeAction =>
      this == JournalKind.stroke || this == JournalKind.erase;

  bool get isStructural => switch (this) {
    JournalKind.layerAdd ||
    JournalKind.layerRemove ||
    JournalKind.layerReorder ||
    JournalKind.layerProps ||
    JournalKind.canvasResize ||
    JournalKind.merge => true,
    _ => false,
  };
}

/// Integer document-space bounds used by replay and stroke-erase hit testing.
final class JournalBounds {
  const JournalBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  bool intersects(JournalBounds other) =>
      x < other.x + other.width &&
      other.x < x + width &&
      y < other.y + other.height &&
      other.y < y + height;

  List<int> toJson() => [x, y, width, height];

  factory JournalBounds.fromJson(List<Object?> json) {
    if (json.length != 4 || json.any((value) => value is! int)) {
      throw const FormatException('Journal bbox must contain four integers');
    }
    final result = JournalBounds(
      x: json[0]! as int,
      y: json[1]! as int,
      width: json[2]! as int,
      height: json[3]! as int,
    );
    if (result.width < 0 || result.height < 0) {
      throw const FormatException('Journal bbox dimensions must be positive');
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JournalBounds &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// Deterministic reconstruction data carried by every stroke and erase.
final class StrokeRecipe {
  StrokeRecipe({
    required this.brushId,
    required this.colorArgb,
    required this.size,
    required this.seed,
    required Iterable<double> transform,
    required Uint8List samples,
  }) : transform = List<double>.unmodifiable(transform),
       _samples = Uint8List.fromList(samples) {
    if (brushId.isEmpty) {
      throw ArgumentError.value(brushId, 'brushId', 'must not be empty');
    }
    if (!size.isFinite || size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be finite and positive');
    }
    if (this.transform.length != 6 ||
        this.transform.any((value) => !value.isFinite)) {
      throw ArgumentError.value(
        transform,
        'transform',
        'must be a finite six-number affine matrix',
      );
    }
  }

  final String brushId;
  final int colorArgb;
  final double size;
  final int seed;
  final List<double> transform;
  final Uint8List _samples;

  /// Packed x, y, pressure, tilt, and timestamp samples.
  Uint8List get samples => Uint8List.fromList(_samples);

  int get encodedByteLength => utf8.encode(jsonEncode(toJson())).length;

  Map<String, Object?> toJson() => {
    'brushId': brushId,
    'colorArgb': colorArgb,
    'size': size,
    'seed': seed,
    'transform': transform,
    'samples': base64Encode(_samples),
  };

  factory StrokeRecipe.fromJson(Map<String, Object?> json) {
    try {
      final rawTransform = json['transform'];
      if (rawTransform is! List<Object?>) {
        throw const FormatException('recipe.transform is not a list');
      }
      final encodedSamples = json['samples'];
      if (encodedSamples is! String) {
        throw const FormatException('recipe.samples is not a string');
      }
      return StrokeRecipe(
        brushId: json['brushId']! as String,
        colorArgb: json['colorArgb']! as int,
        size: (json['size']! as num).toDouble(),
        seed: json['seed']! as int,
        transform: [
          for (final value in rawTransform) (value! as num).toDouble(),
        ],
        samples: base64Decode(encodedSamples),
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid stroke recipe', error);
    }
  }
}

/// One durable user action, including hot COW refs and cold snapshot refs.
final class JournalEntry {
  JournalEntry({
    required this.seq,
    required this.timestampMs,
    required this.kind,
    this.layerId,
    this.bounds,
    this.recipe,
    this.recipeCompacted = false,
    Iterable<TileKey> affectedKeys = const [],
    Map<String, String?> beforeReferences = const {},
    Map<String, String?> afterReferences = const {},
    Map<TileKey, Tile?> beforeTiles = const {},
    Map<TileKey, Tile?> afterTiles = const {},
    Map<String, Map<String, String?>> beforeLayerReferences = const {},
    Map<String, Map<String, String?>> afterLayerReferences = const {},
    Map<String, Map<TileKey, Tile?>> beforeLayerTiles = const {},
    Map<String, Map<TileKey, Tile?>> afterLayerTiles = const {},
    this.completeLayerSnapshots = false,
    Map<String, Object?>? beforeState,
    Map<String, Object?>? afterState,
    Map<String, Object?> unknownFields = const {},
  }) : affectedKeys = List<TileKey>.unmodifiable(
         ({...affectedKeys, ...beforeTiles.keys, ...afterTiles.keys}.toList()
           ..sort()),
       ),
       beforeReferences = Map<String, String?>.unmodifiable(beforeReferences),
       afterReferences = Map<String, String?>.unmodifiable(afterReferences),
       beforeTiles = Map<TileKey, Tile?>.unmodifiable(beforeTiles),
       afterTiles = Map<TileKey, Tile?>.unmodifiable(afterTiles),
       beforeLayerReferences = _freezeLayerReferences(beforeLayerReferences),
       afterLayerReferences = _freezeLayerReferences(afterLayerReferences),
       beforeLayerTiles = _freezeLayerTiles(beforeLayerTiles),
       afterLayerTiles = _freezeLayerTiles(afterLayerTiles),
       beforeState = beforeState == null ? null : _freezeJsonMap(beforeState),
       afterState = afterState == null ? null : _freezeJsonMap(afterState),
       unknownFields = _freezeJsonMap(unknownFields) {
    if (seq < 0) {
      throw ArgumentError.value(seq, 'seq', 'must not be negative');
    }
    if (layerId != null && layerId!.isEmpty) {
      throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
    }
    if (kind.isRecipeAction && recipe == null && !recipeCompacted) {
      throw ArgumentError('${kind.name} entries must carry a recipe');
    }
    final needsCompleteRaster =
        kind == JournalKind.layerRemove ||
        kind == JournalKind.merge ||
        kind == JournalKind.canvasResize;
    if (needsCompleteRaster && !completeLayerSnapshots) {
      throw ArgumentError(
        '${kind.name} entries require complete multi-layer snapshots',
      );
    }
    if (kind.isStructural && (beforeState == null || afterState == null)) {
      throw ArgumentError('${kind.name} entries require before/after state');
    }
    if (completeLayerSnapshots) {
      if (!_isCompleteRasterSnapshot(
            _structuralLayerTiles(this.beforeState),
            this.beforeLayerReferences,
            this.beforeLayerTiles,
          ) ||
          !_isCompleteRasterSnapshot(
            _structuralLayerTiles(this.afterState),
            this.afterLayerReferences,
            this.afterLayerTiles,
          )) {
        throw ArgumentError(
          'Complete layer snapshots must exactly cover occupied structural '
          'tiles with non-null values',
        );
      }
    }
  }

  final int seq;
  final int timestampMs;
  final JournalKind kind;
  final String? layerId;
  final JournalBounds? bounds;
  final StrokeRecipe? recipe;
  final bool recipeCompacted;
  final List<TileKey> affectedKeys;
  final Map<String, String?> beforeReferences;
  final Map<String, String?> afterReferences;
  final Map<TileKey, Tile?> beforeTiles;
  final Map<TileKey, Tile?> afterTiles;
  final Map<String, Map<String, String?>> beforeLayerReferences;
  final Map<String, Map<String, String?>> afterLayerReferences;
  final Map<String, Map<TileKey, Tile?>> beforeLayerTiles;
  final Map<String, Map<TileKey, Tile?>> afterLayerTiles;
  final bool completeLayerSnapshots;
  final Map<String, Object?>? beforeState;
  final Map<String, Object?>? afterState;
  final Map<String, Object?> unknownFields;

  Map<String, Object?> toJson() => {
    ...unknownFields,
    'seq': seq,
    't': timestampMs,
    'kind': kind.name,
    if (layerId != null) 'layerId': layerId,
    if (bounds != null) 'bbox': bounds!.toJson(),
    if (affectedKeys.isNotEmpty)
      'affected': [
        for (final key in affectedKeys) [key.x, key.y],
      ],
    if (beforeReferences.isNotEmpty) 'before': beforeReferences,
    if (afterReferences.isNotEmpty) 'after': afterReferences,
    if (beforeLayerReferences.isNotEmpty) 'beforeLayers': beforeLayerReferences,
    if (afterLayerReferences.isNotEmpty) 'afterLayers': afterLayerReferences,
    if (completeLayerSnapshots) 'fullLayerSnapshots': true,
    if (beforeState != null) 'beforeState': beforeState,
    if (afterState != null) 'afterState': afterState,
    if (recipe != null) 'recipe': recipe!.toJson(),
    if (recipeCompacted) 'recipeCompacted': true,
  };

  factory JournalEntry.fromJson(Map<String, Object?> json) {
    try {
      final kindName = json['kind'];
      if (kindName is! String) {
        throw const FormatException('Journal kind is missing');
      }
      final known = <String>{
        'seq',
        't',
        'kind',
        'layerId',
        'bbox',
        'affected',
        'before',
        'after',
        'beforeLayers',
        'afterLayers',
        'fullLayerSnapshots',
        'beforeState',
        'afterState',
        'recipe',
        'recipeCompacted',
      };
      return JournalEntry(
        seq: json['seq']! as int,
        timestampMs: json['t']! as int,
        kind: JournalKind.values.byName(kindName),
        layerId: json['layerId'] as String?,
        bounds: _optionalBounds(json['bbox']),
        affectedKeys: _decodeKeys(json['affected']),
        beforeReferences: _decodeReferences(json['before']),
        afterReferences: _decodeReferences(json['after']),
        beforeLayerReferences: _decodeLayerReferences(json['beforeLayers']),
        afterLayerReferences: _decodeLayerReferences(json['afterLayers']),
        completeLayerSnapshots: json['fullLayerSnapshots'] == true,
        beforeState: _optionalJsonMap(json['beforeState']),
        afterState: _optionalJsonMap(json['afterState']),
        recipe: json['recipe'] == null
            ? null
            : StrokeRecipe.fromJson(_requiredJsonMap(json['recipe'])),
        recipeCompacted: json['recipeCompacted'] == true,
        unknownFields: {
          for (final entry in json.entries)
            if (!known.contains(entry.key)) entry.key: entry.value,
        },
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid journal entry', error);
    }
  }

  JournalEntry copyWith({
    StrokeRecipe? Function()? recipe,
    bool? recipeCompacted,
    Map<String, String?>? beforeReferences,
    Map<String, String?>? afterReferences,
    Map<TileKey, Tile?>? beforeTiles,
    Map<TileKey, Tile?>? afterTiles,
    Map<String, Map<String, String?>>? beforeLayerReferences,
    Map<String, Map<String, String?>>? afterLayerReferences,
    Map<String, Map<TileKey, Tile?>>? beforeLayerTiles,
    Map<String, Map<TileKey, Tile?>>? afterLayerTiles,
  }) => JournalEntry(
    seq: seq,
    timestampMs: timestampMs,
    kind: kind,
    layerId: layerId,
    bounds: bounds,
    recipe: recipe == null ? this.recipe : recipe(),
    recipeCompacted: recipeCompacted ?? this.recipeCompacted,
    affectedKeys: affectedKeys,
    beforeReferences: beforeReferences ?? this.beforeReferences,
    afterReferences: afterReferences ?? this.afterReferences,
    beforeTiles: beforeTiles ?? this.beforeTiles,
    afterTiles: afterTiles ?? this.afterTiles,
    beforeLayerReferences: beforeLayerReferences ?? this.beforeLayerReferences,
    afterLayerReferences: afterLayerReferences ?? this.afterLayerReferences,
    beforeLayerTiles: beforeLayerTiles ?? this.beforeLayerTiles,
    afterLayerTiles: afterLayerTiles ?? this.afterLayerTiles,
    completeLayerSnapshots: completeLayerSnapshots,
    beforeState: beforeState,
    afterState: afterState,
    unknownFields: unknownFields,
  );
}

/// A content-hashed, complete snapshot of one layer at a replay boundary.
final class JournalCheckpoint {
  JournalCheckpoint({
    required this.layerId,
    required this.throughSeq,
    required this.timestampMs,
    required Map<String, String> tileReferences,
  }) : tileReferences = Map<String, String>.unmodifiable(tileReferences);

  final String layerId;
  final int throughSeq;
  final int timestampMs;
  final Map<String, String> tileReferences;

  Map<String, Object?> toJson() => {
    'type': 'checkpoint',
    'layerId': layerId,
    'throughSeq': throughSeq,
    't': timestampMs,
    'tiles': tileReferences,
  };

  factory JournalCheckpoint.fromJson(Map<String, Object?> json) {
    final rawTiles = _requiredJsonMap(json['tiles']);
    return JournalCheckpoint(
      layerId: json['layerId']! as String,
      throughSeq: json['throughSeq']! as int,
      timestampMs: json['t']! as int,
      tileReferences: {
        for (final entry in rawTiles.entries) entry.key: entry.value! as String,
      },
    );
  }
}

final class _AbandonedJournalEntry {
  const _AbandonedJournalEntry({
    required this.groupId,
    required this.baseHeadSeq,
    required this.entry,
  });

  final String groupId;
  final int baseHeadSeq;
  final JournalEntry entry;

  Map<String, Object?> toJson() => {
    'type': 'abandoned',
    'groupId': groupId,
    'baseHeadSeq': baseHeadSeq,
    'entry': entry.toJson(),
  };
}

/// Filesystem-free persistence seam used by [UndoJournal].
abstract interface class JournalStorage {
  Future<void> appendJsonLine(String line);

  Future<void> flush();

  Future<List<String>> readJsonLines();

  /// Discards and quarantines records from [validLineCount] onward.
  Future<void> quarantineJsonTail(int validLineCount);

  Future<void> replaceJsonLines(List<String> lines);

  Future<String> putSnapshot(Tile tile);

  Future<Tile?> readSnapshot(String reference);

  Future<Set<String>> listSnapshotReferences();

  Future<void> removeSnapshot(String reference);

  Future<void> close();
}

/// Deterministic in-memory journal storage with an explicit durability edge.
final class InMemoryJournalStorage implements JournalStorage {
  InMemoryJournalStorage({
    Iterable<String> durableLines = const [],
    Map<String, Tile> snapshots = const {},
  }) : _durableLines = List<String>.of(durableLines),
       _snapshots = Map<String, Tile>.of(snapshots);

  final List<String> _durableLines;
  final List<String> _pendingLines = [];
  final Map<String, Tile> _snapshots;
  final Map<Tile, String> _snapshotReferencesByIdentity =
      HashMap<Tile, String>.identity();

  int appendCount = 0;
  int flushCount = 0;
  int snapshotWriteCount = 0;
  int snapshotDeleteCount = 0;

  List<String> get durableLines => List<String>.unmodifiable(_durableLines);

  InMemoryJournalStorage crashClone() => InMemoryJournalStorage(
    durableLines: _durableLines,
    snapshots: _snapshots,
  );

  @override
  Future<void> appendJsonLine(String line) async {
    if (line.contains('\n')) {
      throw ArgumentError.value(line, 'line', 'must be one JSONL record');
    }
    appendCount += 1;
    _pendingLines.add(line);
  }

  @override
  Future<void> flush() async {
    flushCount += 1;
    _durableLines.addAll(_pendingLines);
    _pendingLines.clear();
  }

  @override
  Future<List<String>> readJsonLines() async => List.of(_durableLines);

  @override
  Future<void> quarantineJsonTail(int validLineCount) async {
    if (validLineCount < 0 || validLineCount > _durableLines.length) {
      throw RangeError.range(
        validLineCount,
        0,
        _durableLines.length,
        'validLineCount',
      );
    }
    _durableLines.removeRange(validLineCount, _durableLines.length);
    _pendingLines.clear();
  }

  @override
  Future<void> replaceJsonLines(List<String> lines) async {
    _durableLines
      ..clear()
      ..addAll(lines);
    _pendingLines.clear();
    flushCount += 1;
  }

  @override
  Future<String> putSnapshot(Tile tile) async {
    final cached = _snapshotReferencesByIdentity[tile];
    if (cached != null && _snapshots.containsKey(cached)) {
      return cached;
    }
    final reference = 'snapshots/${_sha256Hex(tile.pixels)}.tile';
    _snapshotReferencesByIdentity[tile] = reference;
    if (!_snapshots.containsKey(reference)) {
      _snapshots[reference] = tile;
      snapshotWriteCount += 1;
    }
    return reference;
  }

  @override
  Future<Tile?> readSnapshot(String reference) async => _snapshots[reference];

  @override
  Future<Set<String>> listSnapshotReferences() async => _snapshots.keys.toSet();

  @override
  Future<void> removeSnapshot(String reference) async {
    if (_snapshots.remove(reference) != null) {
      _snapshotReferencesByIdentity.removeWhere(
        (tile, cachedReference) => cachedReference == reference,
      );
      snapshotDeleteCount += 1;
    }
  }

  @override
  Future<void> close() async {}
}

/// Transaction boundaries exposed for deterministic rewrite crash tests.
enum FileJournalRewritePoint {
  afterBackups,
  afterDescriptor,
  afterSegmentOne,
  afterHigherSegmentsDeleted,
}

typedef FileJournalRewriteInterrupt =
    FutureOr<void> Function(FileJournalRewritePoint point);

/// JSONL-segment and `.tile` snapshot storage rooted at an artwork journal.
final class FileJournalStorage implements JournalStorage {
  FileJournalStorage({
    required this.root,
    this.segmentEntryLimit = 128,
    int Function()? nowMilliseconds,
    this.rewriteInterrupt,
  }) : nowMilliseconds = nowMilliseconds ?? _systemNowMilliseconds {
    if (segmentEntryLimit <= 0) {
      throw ArgumentError.value(
        segmentEntryLimit,
        'segmentEntryLimit',
        'must be positive',
      );
    }
  }

  final Directory root;
  final int segmentEntryLimit;
  final int Function() nowMilliseconds;
  final FileJournalRewriteInterrupt? rewriteInterrupt;

  static const int _maxSegmentBytes = 16 * 1024 * 1024;
  static const int _maxJsonLineBytes = 1024 * 1024;
  static const int _maxSnapshotBytes = Tile.byteLength + 64 * 1024;
  static int _nextRewriteSerial = 0;

  RandomAccessFile? _appendHandle;
  int _appendSegment = 0;
  int _appendSegmentEntries = 0;
  int _appendSegmentBytes = 0;

  Directory get _snapshots => Directory('${root.path}/snapshots');
  File get _rewriteDescriptor => File('${root.path}/.rewrite.json');

  @override
  Future<void> appendJsonLine(String line) async {
    final encoded = utf8.encode(line);
    if (line.contains('\n') || encoded.length > _maxJsonLineBytes) {
      throw ArgumentError.value(line, 'line', 'must be one JSONL record');
    }
    await _ensureAppendHandle();
    if (_appendSegmentEntries >= segmentEntryLimit ||
        _appendSegmentBytes + encoded.length + 1 > _maxSegmentBytes) {
      await _appendHandle!.flush();
      await _appendHandle!.close();
      _appendHandle = null;
      _appendSegment += 1;
      _appendSegmentEntries = 0;
      _appendSegmentBytes = 0;
      _appendHandle = await _segmentFile(
        _appendSegment,
      ).open(mode: FileMode.append);
    }
    await _appendHandle!.writeString('$line\n');
    _appendSegmentEntries += 1;
    _appendSegmentBytes += encoded.length + 1;
  }

  @override
  Future<void> flush() async => _appendHandle?.flush();

  @override
  Future<List<String>> readJsonLines() async {
    await _recoverRewriteIfNeeded();
    final result = <String>[];
    final files = await _segmentFiles();
    for (var fileIndex = 0; fileIndex < files.length; fileIndex += 1) {
      final file = files[fileIndex];
      try {
        final segment = await _readSegment(file);
        for (
          var lineIndex = 0;
          lineIndex < segment.lines.length;
          lineIndex += 1
        ) {
          final line = segment.lines[lineIndex];
          if (utf8.encode(line).length > _maxJsonLineBytes) {
            await _quarantineGap(
              file,
              segment.lines.take(lineIndex).toList(),
              files.skip(fileIndex + 1),
            );
            return result..addAll(segment.lines.take(lineIndex));
          }
          try {
            jsonDecode(line);
          } on Object {
            await _quarantineGap(
              file,
              segment.lines.take(lineIndex).toList(),
              files.skip(fileIndex + 1),
            );
            return result..addAll(segment.lines.take(lineIndex));
          }
        }
        result.addAll(segment.lines);
        if (segment.hadPartialTail) {
          await _quarantineGap(file, segment.lines, files.skip(fileIndex + 1));
          return result;
        }
      } on Object {
        await _quarantineGap(file, const [], files.skip(fileIndex + 1));
        return result;
      }
    }
    return result;
  }

  @override
  Future<void> quarantineJsonTail(int validLineCount) async {
    if (validLineCount < 0) {
      throw RangeError.value(validLineCount, 'validLineCount');
    }
    await _closeAppendHandle();
    await _recoverRewriteIfNeeded();
    final files = await _segmentFiles();
    var remaining = validLineCount;
    for (var index = 0; index < files.length; index += 1) {
      final segment = await _readSegment(files[index]);
      if (remaining >= segment.lines.length) {
        remaining -= segment.lines.length;
        continue;
      }
      await _quarantineGap(
        files[index],
        segment.lines.take(remaining).toList(),
        files.skip(index + 1),
      );
      return;
    }
    if (remaining != 0) {
      throw RangeError.value(validLineCount, 'validLineCount');
    }
  }

  @override
  Future<void> replaceJsonLines(List<String> lines) async {
    await _closeAppendHandle();
    root.createSync(recursive: true);
    await _recoverRewriteIfNeeded();
    for (final line in lines) {
      if (line.contains('\n') || utf8.encode(line).length > _maxJsonLineBytes) {
        throw ArgumentError.value(line, 'lines', 'invalid JSONL record');
      }
    }
    final revision = '${nowMilliseconds()}-$pid-${_nextRewriteSerial++}';
    final segments = await _segmentFiles();
    final segmentNames = [
      for (final segment in segments) segment.uri.pathSegments.last,
    ];
    for (final segment in segments) {
      final backup = _backupFile(revision, segment);
      await _atomicWriteBytes(backup, await _boundedFileBytes(segment));
    }
    await rewriteInterrupt?.call(FileJournalRewritePoint.afterBackups);
    final descriptor = <String, Object?>{
      'revision': revision,
      'segments': segmentNames,
    };
    await _atomicWriteBytes(
      _rewriteDescriptor,
      Uint8List.fromList(utf8.encode(jsonEncode(descriptor))),
    );
    await rewriteInterrupt?.call(FileJournalRewritePoint.afterDescriptor);

    final replacementLines = [
      ...lines,
      jsonEncode({'type': 'storageRevision', 'revision': revision}),
    ];
    final bytes = Uint8List.fromList(
      utf8.encode('${replacementLines.join('\n')}\n'),
    );
    if (bytes.length > _maxSegmentBytes) {
      throw StateError('Compacted journal exceeds $_maxSegmentBytes bytes');
    }
    await _atomicWriteBytes(_segmentFile(1), bytes);
    await rewriteInterrupt?.call(FileJournalRewritePoint.afterSegmentOne);
    for (final segment in await _segmentFiles()) {
      if (_segmentIndex(segment) > 1) {
        await segment.delete();
      }
    }
    await rewriteInterrupt?.call(
      FileJournalRewritePoint.afterHigherSegmentsDeleted,
    );
    await _finishCommittedRewrite(revision, segmentNames);
  }

  @override
  Future<String> putSnapshot(Tile tile) async {
    final reference = 'snapshots/${_sha256Hex(tile.pixels)}.tile';
    final file = _snapshotFile(reference);
    if (file.existsSync()) {
      if (await readSnapshot(reference) != null) {
        return reference;
      }
    }
    _snapshots.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    final handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeFrom(InkTileCodec.encodeTile(tile));
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (file.existsSync()) {
      await temporary.delete();
    } else {
      await temporary.rename(file.path);
    }
    return reference;
  }

  @override
  Future<Tile?> readSnapshot(String reference) async {
    final file = _snapshotFile(reference);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final encoded = await _boundedFileBytes(file, maximum: _maxSnapshotBytes);
      final tile = InkTileCodec.decodeTile(encoded);
      final expected = reference.substring(
        'snapshots/'.length,
        reference.length - '.tile'.length,
      );
      if (_sha256Hex(tile.pixels) != expected) {
        throw const FormatException(
          'Snapshot content hash does not match path',
        );
      }
      return tile;
    } on Object {
      try {
        final stamp = nowMilliseconds();
        await file.rename('${file.path}.corrupt-$stamp');
      } on Object {
        // Quarantine failure must not block recovery.
      }
      return null;
    }
  }

  @override
  Future<Set<String>> listSnapshotReferences() async {
    if (!_snapshots.existsSync()) {
      return {};
    }
    final result = <String>{};
    await for (final entity in _snapshots.list(followLinks: false)) {
      if (entity is File) {
        final reference = 'snapshots/${entity.uri.pathSegments.last}';
        if (RegExp(r'^snapshots/[0-9a-f]{64}\.tile$').hasMatch(reference)) {
          result.add(reference);
        }
      }
    }
    return result;
  }

  @override
  Future<void> removeSnapshot(String reference) async {
    final file = _snapshotFile(reference);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<void> close() => _closeAppendHandle();

  Future<_SegmentRead> _readSegment(File file) async {
    final bytes = await _boundedFileBytes(file);
    final text = utf8.decode(bytes, allowMalformed: false);
    final hadPartialTail = text.isNotEmpty && !text.endsWith('\n');
    final pieces = text.split('\n');
    if (pieces.isNotEmpty) {
      pieces.removeLast();
    }
    return _SegmentRead(lines: pieces, hadPartialTail: hadPartialTail);
  }

  Future<Uint8List> _boundedFileBytes(
    File file, {
    int maximum = _maxSegmentBytes,
  }) async {
    final length = await file.length();
    if (length < 0 || length > maximum) {
      throw FormatException('Journal file size $length exceeds $maximum');
    }
    return file.readAsBytes();
  }

  Future<void> _quarantineGap(
    File file,
    List<String> validLines,
    Iterable<File> laterFiles,
  ) async {
    if (_appendHandle != null) {
      await _closeAppendHandle();
    }
    await _quarantine(file);
    if (validLines.isNotEmpty) {
      await _atomicWriteBytes(
        file,
        Uint8List.fromList(utf8.encode('${validLines.join('\n')}\n')),
      );
    }
    for (final later in laterFiles) {
      await _quarantine(later);
    }
  }

  Future<void> _recoverRewriteIfNeeded() async {
    if (!_rewriteDescriptor.existsSync()) {
      return;
    }
    final raw = await _boundedFileBytes(_rewriteDescriptor, maximum: 64 * 1024);
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, Object?> ||
        decoded['revision'] is! String ||
        decoded['segments'] is! List<Object?>) {
      throw const FormatException('Invalid journal rewrite descriptor');
    }
    final revision = decoded['revision']! as String;
    final segmentNames = <String>[
      for (final value in decoded['segments']! as List<Object?>)
        value! as String,
    ];
    if (!RegExp(r'^\d+-\d+-\d+$').hasMatch(revision) ||
        segmentNames.any(
          (name) => !RegExp(r'^segment-\d{6}\.jsonl$').hasMatch(name),
        )) {
      throw const FormatException('Unsafe journal rewrite descriptor');
    }

    final committed = await _segmentHasRevision(_segmentFile(1), revision);
    if (committed) {
      for (final segment in await _segmentFiles()) {
        if (_segmentIndex(segment) > 1) {
          await segment.delete();
        }
      }
      await _finishCommittedRewrite(revision, segmentNames);
      return;
    }

    final oldNames = segmentNames.toSet();
    for (final segment in await _segmentFiles()) {
      if (!oldNames.contains(segment.uri.pathSegments.last)) {
        await segment.delete();
      }
    }
    for (final name in segmentNames) {
      final target = File('${root.path}/$name');
      final backup = _backupFile(revision, target);
      if (!backup.existsSync()) {
        throw StateError('Missing journal rewrite backup $name');
      }
      await _atomicWriteBytes(target, await _boundedFileBytes(backup));
    }
    await _finishRolledBackRewrite(revision, segmentNames);
  }

  Future<bool> _segmentHasRevision(File file, String revision) async {
    if (!file.existsSync()) {
      return false;
    }
    try {
      final segment = await _readSegment(file);
      if (segment.hadPartialTail || segment.lines.isEmpty) {
        return false;
      }
      final last = jsonDecode(segment.lines.last);
      return last is Map<String, Object?> &&
          last['type'] == 'storageRevision' &&
          last['revision'] == revision;
    } on Object {
      return false;
    }
  }

  Future<void> _finishCommittedRewrite(
    String revision,
    Iterable<String> segmentNames,
  ) async {
    for (final name in segmentNames) {
      final backup = _backupFile(revision, File('${root.path}/$name'));
      if (backup.existsSync()) {
        await backup.delete();
      }
    }
    if (_rewriteDescriptor.existsSync()) {
      await _rewriteDescriptor.delete();
    }
  }

  Future<void> _finishRolledBackRewrite(
    String revision,
    Iterable<String> segmentNames,
  ) async {
    if (_rewriteDescriptor.existsSync()) {
      await _rewriteDescriptor.delete();
    }
    for (final name in segmentNames) {
      final backup = _backupFile(revision, File('${root.path}/$name'));
      try {
        if (backup.existsSync()) {
          await backup.delete();
        }
      } on Object {
        // The restored canonical segments are authoritative after descriptor
        // deletion; stale backups are harmless and can be swept later.
      }
    }
  }

  File _backupFile(String revision, File segment) => File(
    '${root.path}/.rewrite-$revision-'
    '${segment.uri.pathSegments.last}.bak',
  );

  Future<void> _atomicWriteBytes(File target, Uint8List bytes) async {
    final temporary = File('${target.path}.tmp');
    final handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(target.path);
  }

  Future<void> _ensureAppendHandle() async {
    if (_appendHandle != null) {
      return;
    }
    root.createSync(recursive: true);
    await _recoverRewriteIfNeeded();
    final segments = await _segmentFiles();
    if (segments.isEmpty) {
      _appendSegment = 1;
      _appendSegmentEntries = 0;
      _appendSegmentBytes = 0;
    } else {
      final latest = segments.last;
      _appendSegment = _segmentIndex(latest);
      try {
        final segment = await _readSegment(latest);
        if (segment.hadPartialTail) {
          await _quarantineGap(latest, segment.lines, const []);
        }
        _appendSegmentEntries = segment.lines.length;
        _appendSegmentBytes = await latest.length();
      } on Object {
        await _quarantine(latest);
        _appendSegment += 1;
        _appendSegmentEntries = 0;
        _appendSegmentBytes = 0;
      }
    }
    _appendHandle = await _segmentFile(
      _appendSegment,
    ).open(mode: FileMode.append);
  }

  Future<void> _closeAppendHandle() async {
    final handle = _appendHandle;
    _appendHandle = null;
    if (handle != null) {
      await handle.flush();
      await handle.close();
    }
    _appendSegment = 0;
    _appendSegmentEntries = 0;
    _appendSegmentBytes = 0;
  }

  Future<List<File>> _segmentFiles() async {
    if (!root.existsSync()) {
      return [];
    }
    final result = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && _segmentIndex(entity) > 0) {
        result.add(entity);
      }
    }
    result.sort(
      (left, right) => _segmentIndex(left).compareTo(_segmentIndex(right)),
    );
    return result;
  }

  File _segmentFile(int index) =>
      File('${root.path}/segment-${index.toString().padLeft(6, '0')}.jsonl');

  int _segmentIndex(File file) {
    final name = file.uri.pathSegments.last;
    final match = RegExp(r'^segment-(\d{6})\.jsonl$').firstMatch(name);
    return match == null ? -1 : int.parse(match.group(1)!);
  }

  File _snapshotFile(String reference) {
    if (!RegExp(r'^snapshots/[0-9a-f]{64}\.tile$').hasMatch(reference)) {
      throw FormatException('Unsafe snapshot reference: $reference');
    }
    return File('${root.path}/$reference');
  }

  Future<void> _quarantine(File file) async {
    try {
      final stamp = nowMilliseconds();
      await file.rename('${file.path}.corrupt-$stamp');
    } on Object {
      // Quarantine failure must not hide readable records in other segments.
    }
  }

  static int _systemNowMilliseconds() => DateTime.now().millisecondsSinceEpoch;
}

final class _SegmentRead {
  const _SegmentRead({required this.lines, required this.hadPartialTail});

  final List<String> lines;
  final bool hadPartialTail;
}

/// An immutable view of the document parts changed by journal operations.
final class JournalDocumentState {
  JournalDocumentState({
    required this.tiles,
    required Iterable<InkLayer> layers,
    required this.canvas,
  }) : layers = List<InkLayer>.unmodifiable(layers);

  final TileStore tiles;
  final List<InkLayer> layers;
  final CanvasSpec canvas;

  JournalDocumentState fork() =>
      JournalDocumentState(tiles: tiles.fork(), layers: layers, canvas: canvas);

  /// Full structural state suitable for an entry's before/after JSON.
  Map<String, Object?> structuralJson() => {
    'canvas': canvas.toJson(),
    'layers': [for (final layer in layers) layer.toJson()],
  };
}

/// Whether a pure journal operation applies or reverses an entry.
enum JournalDirection { forward, reverse }

/// Applies already-materialized entry data without performing any I/O.
JournalDocumentState applyJournalEntry(
  JournalDocumentState state,
  JournalEntry entry, {
  required JournalDirection direction,
  Map<TileKey, Tile?> tiles = const {},
  Map<String, Map<TileKey, Tile?>> layerTiles = const {},
  Set<String> preserveCompleteLayerIds = const {},
}) {
  if (entry.kind == JournalKind.canvasFlip) {
    return _flipCanvas(state);
  }

  var result = _applyStructuralState(
    state,
    direction == JournalDirection.forward
        ? entry.afterState
        : entry.beforeState,
  );
  final store = result.tiles.fork();
  if (entry.kind.isStructural && !entry.completeLayerSnapshots) {
    final structuralLayerIds = result.layers.map((layer) => layer.id).toSet();
    for (final layerId in store.layerIds.toList()) {
      if (!structuralLayerIds.contains(layerId)) {
        store.removeLayer(layerId);
      }
    }
    for (final layerId in structuralLayerIds) {
      store.ensureLayer(layerId);
    }
  }
  final preservedLayers = <String, Map<TileKey, Tile>>{
    if (entry.completeLayerSnapshots)
      for (final layerId in preserveCompleteLayerIds)
        layerId: store.layerTiles(layerId),
  };
  if (entry.completeLayerSnapshots) {
    store.clear();
  }
  for (final layer in layerTiles.entries) {
    if (entry.completeLayerSnapshots) {
      store.replaceLayer(layer.key, {
        for (final tile in layer.value.entries)
          if (tile.value != null) tile.key: tile.value!,
      });
    } else {
      store.publishAll(layer.key, layer.value);
    }
  }
  for (final layer in preservedLayers.entries) {
    store.replaceLayer(layer.key, layer.value);
  }
  final layerId = entry.layerId;
  if (layerId == null) {
    if (tiles.isNotEmpty) {
      throw StateError('Tile changes require a layerId');
    }
    return JournalDocumentState(
      tiles: store,
      layers: _syncLayerTiles(result.layers, store),
      canvas: result.canvas,
    );
  }

  if (entry.kind == JournalKind.layerClear &&
      direction == JournalDirection.forward &&
      tiles.isEmpty) {
    store.clearLayer(layerId);
  } else if (tiles.isNotEmpty) {
    store.publishAll(layerId, tiles);
  }
  result = JournalDocumentState(
    tiles: store,
    layers: _syncLayerTiles(result.layers, store),
    canvas: result.canvas,
  );
  return result;
}

/// Input passed to the brush engine seam when snapshots are unavailable.
final class RecipeReplayRequest {
  RecipeReplayRequest({
    required this.state,
    required this.entry,
    Iterable<TileKey> clipKeys = const [],
  }) : clipKeys = List<TileKey>.unmodifiable(clipKeys);

  final JournalDocumentState state;
  final JournalEntry entry;
  final List<TileKey> clipKeys;
}

/// Deterministic brush renderer supplied by the engine in later work packages.
typedef RecipeRenderer =
    FutureOr<Map<TileKey, Tile?>> Function(RecipeReplayRequest request);

/// Crash-injection boundaries around the write-ahead commit.
enum JournalInterruptionPoint { afterAppend, afterFlush }

typedef JournalInterrupt =
    FutureOr<void> Function(JournalInterruptionPoint point);

/// Result of one successful undo or redo operation.
final class JournalStep {
  const JournalStep({required this.state, required this.entry});

  final JournalDocumentState state;
  final JournalEntry entry;
}

/// Result of replaying write-ahead entries newer than a manifest head.
final class JournalRecovery {
  JournalRecovery({
    required this.state,
    required Iterable<int> recoveredSequences,
    required Iterable<int> skippedSequences,
    required this.reconciledHeadSeq,
    Iterable<int> reversedSequences = const [],
  }) : recoveredSequences = List<int>.unmodifiable(recoveredSequences),
       skippedSequences = List<int>.unmodifiable(skippedSequences),
       reversedSequences = List<int>.unmodifiable(reversedSequences);

  final JournalDocumentState state;
  final List<int> recoveredSequences;
  final List<int> skippedSequences;
  final List<int> reversedSequences;
  final int reconciledHeadSeq;

  int get recoveredHeadSeq => reconciledHeadSeq;
}

/// A persisted, crash-recoverable undo/redo ring.
final class UndoJournal {
  UndoJournal({
    required JournalStorage storage,
    RecipeRenderer? recipeRenderer,
    int checkpointInterval = 32,
    int recipeByteBudget = 1024 * 1024,
    int maxDepth = 128,
    Duration retention = const Duration(days: 7),
    DateTime Function()? now,
    JournalInterrupt? interrupt,
  }) : this._(
         storage: storage,
         recipeRenderer: recipeRenderer,
         checkpointInterval: checkpointInterval,
         recipeByteBudget: recipeByteBudget,
         maxDepth: maxDepth,
         retention: retention,
         now: now ?? DateTime.now,
         interrupt: interrupt,
         entries: const [],
         checkpoints: const {},
         abandonedEntries: const [],
         appliedHeadSeq: null,
         lastIssuedSeq: 0,
         baseHeadSeq: 0,
       );

  UndoJournal._({
    required this.storage,
    required this.recipeRenderer,
    required this.checkpointInterval,
    required this.recipeByteBudget,
    required this.maxDepth,
    required this.retention,
    required this.now,
    required this.interrupt,
    required Iterable<JournalEntry> entries,
    required Map<String, JournalCheckpoint> checkpoints,
    required Iterable<_AbandonedJournalEntry> abandonedEntries,
    required int? appliedHeadSeq,
    required int lastIssuedSeq,
    required int baseHeadSeq,
  }) : _entries = List<JournalEntry>.of(entries),
       _checkpoints = Map<String, JournalCheckpoint>.of(checkpoints),
       _abandonedEntries = List<_AbandonedJournalEntry>.of(abandonedEntries),
       // Private field in a named constructor: an initializing formal would
       // force a private named argument at the call sites, so assign here.
       // ignore: prefer_initializing_formals
       _baseHeadSeq = baseHeadSeq {
    if (checkpointInterval <= 0) {
      throw ArgumentError.value(
        checkpointInterval,
        'checkpointInterval',
        'must be positive',
      );
    }
    if (recipeByteBudget <= 0) {
      throw ArgumentError.value(
        recipeByteBudget,
        'recipeByteBudget',
        'must be positive',
      );
    }
    if (maxDepth < 64) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'must be at least 64');
    }
    _cursor = appliedHeadSeq == null
        ? _entries.length
        : _entries.indexWhere((entry) => entry.seq > appliedHeadSeq);
    if (_cursor < 0) {
      _cursor = _entries.length;
    }
    final retainedMaximum = _entries.isEmpty ? 0 : _entries.last.seq;
    _lastIssuedSeq = max(lastIssuedSeq, retainedMaximum);
  }

  final JournalStorage storage;
  final RecipeRenderer? recipeRenderer;
  final int checkpointInterval;
  final int recipeByteBudget;
  final int maxDepth;
  final Duration retention;
  final DateTime Function() now;
  final JournalInterrupt? interrupt;

  List<JournalEntry> _entries;
  Map<String, JournalCheckpoint> _checkpoints;
  List<_AbandonedJournalEntry> _abandonedEntries;
  late int _cursor;
  late int _lastIssuedSeq;
  int _baseHeadSeq;

  Object? lastMaintenanceError;

  List<JournalEntry> get entries => List<JournalEntry>.unmodifiable(_entries);

  Map<String, JournalCheckpoint> get checkpoints =>
      Map<String, JournalCheckpoint>.unmodifiable(_checkpoints);

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _entries.length;
  int get cursor => _cursor;
  int get headSeq => _cursor == 0 ? _baseHeadSeq : _entries[_cursor - 1].seq;
  int get nextSequence => _lastIssuedSeq + 1;

  int get hotBytesHeld {
    final unique = Set<Tile>.identity();
    for (final entry in _entries) {
      unique.addAll(entry.beforeTiles.values.whereType<Tile>());
      unique.addAll(entry.afterTiles.values.whereType<Tile>());
      for (final layer in entry.beforeLayerTiles.values) {
        unique.addAll(layer.values.whereType<Tile>());
      }
      for (final layer in entry.afterLayerTiles.values) {
        unique.addAll(layer.values.whereType<Tile>());
      }
    }
    for (final abandoned in _abandonedEntries) {
      final entry = abandoned.entry;
      unique.addAll(entry.beforeTiles.values.whereType<Tile>());
      unique.addAll(entry.afterTiles.values.whereType<Tile>());
      for (final layer in entry.beforeLayerTiles.values) {
        unique.addAll(layer.values.whereType<Tile>());
      }
      for (final layer in entry.afterLayerTiles.values) {
        unique.addAll(layer.values.whereType<Tile>());
      }
    }
    return unique.length * Tile.byteLength;
  }

  static Future<UndoJournal> open({
    required JournalStorage storage,
    RecipeRenderer? recipeRenderer,
    int checkpointInterval = 32,
    int recipeByteBudget = 1024 * 1024,
    int maxDepth = 128,
    Duration retention = const Duration(days: 7),
    DateTime Function()? now,
    JournalInterrupt? interrupt,
  }) async {
    final bySequence = <int, JournalEntry>{};
    final checkpoints = <String, JournalCheckpoint>{};
    final abandonedEntries = <_AbandonedJournalEntry>[];
    int? appliedHeadSeq;
    var lastIssuedSeq = 0;
    var baseHeadSeq = 0;
    var validLineCount = 0;
    var lastActionSeq = -1;
    for (final line in await storage.readJsonLines()) {
      if (line.trim().isEmpty) {
        await storage.quarantineJsonTail(validLineCount);
        break;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('Journal record is not an object');
        }
        if (decoded['type'] == 'checkpoint') {
          final checkpoint = JournalCheckpoint.fromJson(decoded);
          final previous = checkpoints[checkpoint.layerId];
          if (previous == null ||
              checkpoint.throughSeq >= previous.throughSeq) {
            checkpoints[checkpoint.layerId] = checkpoint;
          }
        } else if (decoded['type'] == 'cursor') {
          appliedHeadSeq = decoded['headSeq']! as int;
        } else if (decoded['type'] == 'metadata') {
          final persisted = decoded['lastIssuedSeq']! as int;
          if (persisted > lastIssuedSeq) {
            lastIssuedSeq = persisted;
          }
          baseHeadSeq = (decoded['baseHeadSeq'] as int?) ?? baseHeadSeq;
        } else if (decoded['type'] == 'storageRevision') {
          // FileJournalStorage commit marker, not a user action.
        } else if (decoded['type'] == 'abandoned') {
          final entry = JournalEntry.fromJson(
            _requiredJsonMap(decoded['entry']),
          );
          abandonedEntries.add(
            _AbandonedJournalEntry(
              groupId: decoded['groupId']! as String,
              baseHeadSeq: decoded['baseHeadSeq']! as int,
              entry: entry,
            ),
          );
          if (entry.seq > lastIssuedSeq) {
            lastIssuedSeq = entry.seq;
          }
        } else {
          final entry = JournalEntry.fromJson(decoded);
          if (entry.seq <= lastActionSeq) {
            throw FormatException(
              'Journal sequence ${entry.seq} is not monotonic',
            );
          }
          lastActionSeq = entry.seq;
          bySequence[entry.seq] = entry;
          appliedHeadSeq = entry.seq;
          if (entry.seq > lastIssuedSeq) {
            lastIssuedSeq = entry.seq;
          }
        }
        validLineCount += 1;
      } on Object {
        await storage.quarantineJsonTail(validLineCount);
        break;
      }
    }
    final entries = bySequence.values.toList()
      ..sort((left, right) => left.seq.compareTo(right.seq));
    return UndoJournal._(
      storage: storage,
      recipeRenderer: recipeRenderer,
      checkpointInterval: checkpointInterval,
      recipeByteBudget: recipeByteBudget,
      maxDepth: maxDepth,
      retention: retention,
      now: now ?? DateTime.now,
      interrupt: interrupt,
      entries: entries,
      checkpoints: checkpoints,
      abandonedEntries: abandonedEntries,
      appliedHeadSeq: appliedHeadSeq,
      lastIssuedSeq: lastIssuedSeq,
      baseHeadSeq: baseHeadSeq,
    );
  }

  /// Appends and flushes [entry] before doing any heavier snapshot work.
  Future<void> commit(JournalEntry entry, {TileStore? checkpointStore}) async {
    if (entry.seq <= _lastIssuedSeq) {
      throw StateError(
        'Journal sequence ${entry.seq} is not newer than $_lastIssuedSeq',
      );
    }
    if (_cursor < _entries.length) {
      await _discardRedoBranch();
    }
    entry = await _prepareDurableEntry(entry);
    await storage.appendJsonLine(jsonEncode(entry.toJson()));
    await interrupt?.call(JournalInterruptionPoint.afterAppend);
    await storage.flush();
    _entries.add(entry);
    _cursor = _entries.length;
    _lastIssuedSeq = entry.seq;
    await interrupt?.call(JournalInterruptionPoint.afterFlush);

    if (checkpointStore != null && entry.kind.isRecipeAction) {
      try {
        await _maybeCreateCheckpoint(entry.layerId!, checkpointStore);
      } on Object catch (error) {
        // The write-ahead entry is already durable. Checkpointing is best-effort.
        lastMaintenanceError = error;
      }
    }
  }

  /// Persists hot COW refs and releases them from journal memory.
  Future<void> spillSnapshots() async {
    final next = <JournalEntry>[];
    for (final entry in _entries) {
      final before = Map<String, String?>.of(entry.beforeReferences);
      for (final tile in entry.beforeTiles.entries) {
        before[_tileReferenceKey(tile.key)] = tile.value == null
            ? null
            : await storage.putSnapshot(tile.value!);
      }
      final after = Map<String, String?>.of(entry.afterReferences);
      for (final tile in entry.afterTiles.entries) {
        after[_tileReferenceKey(tile.key)] = tile.value == null
            ? null
            : await storage.putSnapshot(tile.value!);
      }
      final beforeLayers = _mutableLayerReferences(entry.beforeLayerReferences);
      for (final layer in entry.beforeLayerTiles.entries) {
        final references = beforeLayers.putIfAbsent(layer.key, () => {});
        for (final tile in layer.value.entries) {
          references[_tileReferenceKey(tile.key)] = tile.value == null
              ? null
              : await storage.putSnapshot(tile.value!);
        }
      }
      final afterLayers = _mutableLayerReferences(entry.afterLayerReferences);
      for (final layer in entry.afterLayerTiles.entries) {
        final references = afterLayers.putIfAbsent(layer.key, () => {});
        for (final tile in layer.value.entries) {
          references[_tileReferenceKey(tile.key)] = tile.value == null
              ? null
              : await storage.putSnapshot(tile.value!);
        }
      }
      next.add(
        entry.copyWith(
          beforeReferences: before,
          afterReferences: after,
          beforeTiles: const {},
          afterTiles: const {},
          beforeLayerReferences: beforeLayers,
          afterLayerReferences: afterLayers,
          beforeLayerTiles: const {},
          afterLayerTiles: const {},
        ),
      );
    }
    final nextAbandoned = [
      for (final abandoned in _abandonedEntries)
        _AbandonedJournalEntry(
          groupId: abandoned.groupId,
          baseHeadSeq: abandoned.baseHeadSeq,
          entry: abandoned.entry.copyWith(
            beforeTiles: const {},
            afterTiles: const {},
            beforeLayerTiles: const {},
            afterLayerTiles: const {},
          ),
        ),
    ];
    await storage.replaceJsonLines(
      _recordLines(
        next,
        _checkpoints,
        nextAbandoned,
        cursorHeadSeq: headSeq,
        lastIssuedSeq: _lastIssuedSeq,
        baseHeadSeq: _baseHeadSeq,
      ),
    );
    _entries = next;
    _abandonedEntries = nextAbandoned;
    await garbageCollectSnapshots();
  }

  Future<JournalStep?> undo(
    JournalDocumentState state, {
    JournalDocumentState? replayBaseState,
    int replayBaseHeadSeq = 0,
  }) async {
    if (!canUndo) {
      return null;
    }
    final index = _cursor - 1;
    var entry = _entries[index];
    if (entry.layerId != null && entry.affectedKeys.isNotEmpty) {
      entry = await _captureAfterOnFirstUndo(entry, state);
      _entries[index] = entry;
    }
    final materialized = await _materialize(entry, forward: false);
    final materializedLayers = await _materializeLayerTiles(
      entry,
      forward: false,
    );
    var beforeTiles = materialized.tiles;
    if (materialized.missing.isNotEmpty &&
        replayBaseState != null &&
        entry.recipe != null) {
      beforeTiles = await _reconstructBeforeFromRecipes(
        entry,
        baseState: replayBaseState,
        baseHeadSeq: replayBaseHeadSeq,
      );
    } else if (materialized.missing.isNotEmpty) {
      throw StateError(
        'Missing before snapshots for seq ${entry.seq}: '
        '${materialized.missing.join(', ')}',
      );
    }
    if (materializedLayers.missing.isNotEmpty) {
      throw StateError(
        'Missing structural snapshots for seq ${entry.seq}: '
        '${materializedLayers.missing.join(', ')}',
      );
    }
    final result = applyJournalEntry(
      state,
      entry,
      direction: JournalDirection.reverse,
      tiles: beforeTiles,
      layerTiles: materializedLayers.layers,
    );
    await _persistCursor(index);
    _cursor = index;
    return JournalStep(state: result, entry: entry);
  }

  Future<JournalStep?> redo(JournalDocumentState state) async {
    if (!canRedo) {
      return null;
    }
    final entry = _entries[_cursor];
    final materialized = await _materialize(entry, forward: true);
    final materializedLayers = await _materializeLayerTiles(
      entry,
      forward: true,
    );
    Map<TileKey, Tile?> tiles = materialized.tiles;
    if (materialized.missing.isNotEmpty ||
        (tiles.isEmpty && entry.recipe != null)) {
      tiles = await _renderRecipe(state, entry);
    }
    if (materializedLayers.missing.isNotEmpty) {
      throw StateError(
        'Missing structural snapshots for seq ${entry.seq}: '
        '${materializedLayers.missing.join(', ')}',
      );
    }
    final result = applyJournalEntry(
      state,
      entry,
      direction: JournalDirection.forward,
      tiles: tiles,
      layerTiles: materializedLayers.layers,
    );
    final nextCursor = _cursor + 1;
    await _persistCursor(nextCursor);
    _cursor = nextCursor;
    return JournalStep(state: result, entry: entry);
  }

  /// Replays every durable action newer than [manifestHeadSeq].
  Future<JournalRecovery> recoverFromManifest({
    required JournalDocumentState manifestState,
    required int manifestHeadSeq,
  }) async {
    var state = manifestState;
    final recovered = <int>[];
    final skipped = <int>[];
    final reversed = <int>[];
    var effectiveManifestHead = manifestHeadSeq;
    var stateHeadSeq = manifestHeadSeq;

    _AbandonedJournalEntry? abandonedTip;
    for (final abandoned in _abandonedEntries) {
      if (abandoned.entry.seq == effectiveManifestHead) {
        abandonedTip = abandoned;
      }
    }
    final tip = abandonedTip;
    if (tip != null) {
      final branch =
          _abandonedEntries
              .where(
                (abandoned) =>
                    abandoned.groupId == tip.groupId &&
                    abandoned.entry.seq <= effectiveManifestHead,
              )
              .toList()
            ..sort((left, right) => right.entry.seq.compareTo(left.entry.seq));
      for (var index = 0; index < branch.length; index += 1) {
        final abandoned = branch[index];
        try {
          state = await _reverseRecoveredEntry(state, abandoned.entry);
          reversed.add(abandoned.entry.seq);
          stateHeadSeq = index + 1 < branch.length
              ? branch[index + 1].entry.seq
              : tip.baseHeadSeq;
        } on Object {
          skipped.addAll(branch.map((item) => item.entry.seq));
          return JournalRecovery(
            state: state,
            recoveredSequences: recovered,
            skippedSequences: skipped,
            reversedSequences: reversed,
            reconciledHeadSeq: stateHeadSeq,
          );
        }
      }
      effectiveManifestHead = tip.baseHeadSeq;
    }

    if (effectiveManifestHead > headSeq) {
      final toReverse =
          _entries
              .where(
                (entry) =>
                    entry.seq > headSeq && entry.seq <= effectiveManifestHead,
              )
              .toList()
            ..sort((left, right) => right.seq.compareTo(left.seq));
      for (var index = 0; index < toReverse.length; index += 1) {
        final entry = toReverse[index];
        try {
          state = await _reverseRecoveredEntry(state, entry);
          reversed.add(entry.seq);
          stateHeadSeq = index + 1 < toReverse.length
              ? toReverse[index + 1].seq
              : headSeq;
        } on Object {
          skipped.addAll(toReverse.map((candidate) => candidate.seq));
          return JournalRecovery(
            state: state,
            recoveredSequences: recovered,
            skippedSequences: skipped,
            reversedSequences: reversed,
            reconciledHeadSeq: stateHeadSeq,
          );
        }
      }
      effectiveManifestHead = headSeq;
    }
    final checkpointThrough = <String, int>{};

    for (final checkpoint in _checkpoints.values) {
      if (checkpoint.throughSeq <= effectiveManifestHead) {
        continue;
      }
      if (checkpoint.throughSeq > headSeq) {
        continue;
      }
      final replacement = <TileKey, Tile>{};
      var complete = true;
      for (final reference in checkpoint.tileReferences.entries) {
        final key = _tileKeyFromReference(reference.key);
        final tile = await storage.readSnapshot(reference.value);
        if (key == null || tile == null) {
          complete = false;
          break;
        }
        replacement[key] = tile;
      }
      if (complete) {
        final store = state.tiles.fork()
          ..replaceLayer(checkpoint.layerId, replacement);
        state = JournalDocumentState(
          tiles: store,
          layers: _syncLayerTiles(state.layers, store),
          canvas: state.canvas,
        );
        checkpointThrough[checkpoint.layerId] = checkpoint.throughSeq;
      }
    }
    for (final entry in _entries.take(_cursor)) {
      if (entry.seq <= effectiveManifestHead) {
        continue;
      }
      final flattenedThrough = entry.layerId == null
          ? null
          : checkpointThrough[entry.layerId!];
      if (flattenedThrough != null &&
          entry.seq <= flattenedThrough &&
          !entry.kind.isStructural &&
          entry.kind != JournalKind.canvasFlip) {
        recovered.add(entry.seq);
        stateHeadSeq = entry.seq;
        continue;
      }
      if (entry.kind == JournalKind.canvasFlip) {
        final layers =
            <String>{
              ...state.tiles.layerIds,
              ...state.layers.map((layer) => layer.id),
            }.where(
              (layerId) =>
                  (checkpointThrough[layerId] ?? effectiveManifestHead) <
                  entry.seq,
            );
        state = _flipCanvas(state, onlyLayerIds: layers);
        recovered.add(entry.seq);
        stateHeadSeq = entry.seq;
        continue;
      }
      try {
        final materialized = await _materialize(entry, forward: true);
        final materializedLayers = await _materializeLayerTiles(
          entry,
          forward: true,
        );
        var tiles = materialized.tiles;
        if (materialized.missing.isNotEmpty ||
            (tiles.isEmpty && entry.recipe != null)) {
          tiles = await _renderRecipe(state, entry);
        }
        if (materializedLayers.missing.isNotEmpty) {
          throw StateError('Missing structural snapshots for seq ${entry.seq}');
        }
        state = applyJournalEntry(
          state,
          entry,
          direction: JournalDirection.forward,
          tiles: tiles,
          layerTiles: materializedLayers.layers,
          preserveCompleteLayerIds: _checkpointPreservedLayers(
            entry,
            state,
            checkpointThrough,
          ),
        );
        recovered.add(entry.seq);
        stateHeadSeq = entry.seq;
      } on Object {
        skipped.add(entry.seq);
        skipped.addAll(
          _entries
              .take(_cursor)
              .where(
                (candidate) =>
                    candidate.seq > entry.seq &&
                    candidate.seq > effectiveManifestHead,
              )
              .map((candidate) => candidate.seq),
        );
        break;
      }
    }
    return JournalRecovery(
      state: state,
      recoveredSequences: recovered,
      skippedSequences: skipped,
      reversedSequences: reversed,
      reconciledHeadSeq: stateHeadSeq,
    );
  }

  Future<JournalDocumentState> _reverseRecoveredEntry(
    JournalDocumentState state,
    JournalEntry entry,
  ) async {
    final tiles = await _materialize(entry, forward: false);
    final layers = await _materializeLayerTiles(entry, forward: false);
    if (tiles.missing.isNotEmpty || layers.missing.isNotEmpty) {
      throw StateError('Missing inverse snapshots for seq ${entry.seq}');
    }
    return applyJournalEntry(
      state,
      entry,
      direction: JournalDirection.reverse,
      tiles: tiles.tiles,
      layerTiles: layers.layers,
    );
  }

  Set<String> _checkpointPreservedLayers(
    JournalEntry entry,
    JournalDocumentState state,
    Map<String, int> checkpointThrough,
  ) {
    if (!entry.completeLayerSnapshots) {
      return const {};
    }
    final targetLayerIds = <String>{};
    final rawLayers = entry.afterState?['layers'];
    if (rawLayers is List<Object?>) {
      for (final rawLayer in rawLayers) {
        targetLayerIds.add(InkLayer.fromJson(_requiredJsonMap(rawLayer)).id);
      }
    } else {
      targetLayerIds.addAll(state.layers.map((layer) => layer.id));
    }
    return {
      for (final checkpoint in checkpointThrough.entries)
        if (checkpoint.value >= entry.seq &&
            targetLayerIds.contains(checkpoint.key))
          checkpoint.key,
    };
  }

  /// Entries eligible for bounded stroke erasure in the newest checkpoint tail.
  List<JournalEntry> strokeEraseCandidates({
    required String layerId,
    JournalBounds? intersecting,
  }) {
    final through = _strokeEraseBarrier(layerId);
    final Set<int> erasedSequences = _appliedStrokeEraseSequences();
    return List<JournalEntry>.unmodifiable([
      for (final entry in _entries.take(_cursor))
        if (entry.seq > through &&
            entry.layerId == layerId &&
            entry.kind == JournalKind.stroke &&
            entry.recipe != null &&
            !erasedSequences.contains(entry.seq) &&
            (intersecting == null ||
                (entry.bounds?.intersects(intersecting) ?? false)))
          entry,
    ]);
  }

  Set<int> _appliedStrokeEraseSequences() => <int>{
    for (final JournalEntry entry in _entries.take(_cursor))
      if (entry.unknownFields['strokeEraseSequences']
          case final List<Object?> sequences)
        for (final Object? sequence in sequences)
          if (sequence is int) sequence,
  };

  bool _isStrokeEraseCommit(JournalEntry entry) =>
      entry.kind == JournalKind.erase &&
      entry.unknownFields['strokeEraseSequences'] is List<Object?>;

  int _strokeEraseBarrier(String layerId, {int? beforeSequence}) {
    var barrier = _checkpoints[layerId]?.throughSeq ?? _baseHeadSeq;
    for (final entry in _entries.take(_cursor)) {
      if (beforeSequence != null && entry.seq >= beforeSequence) {
        break;
      }
      final global =
          entry.kind == JournalKind.canvasFlip ||
          entry.kind == JournalKind.canvasResize ||
          entry.kind == JournalKind.merge;
      final bool localRasterBarrier =
          entry.layerId == layerId &&
          !_isStrokeEraseCommit(entry) &&
          (entry.recipe != null &&
                  entry.unknownFields['strokeReplayVersion'] != 1 ||
              entry.unknownFields['strokeSelectionClipped'] == true ||
              switch (entry.kind) {
                JournalKind.fill ||
                JournalKind.shape ||
                JournalKind.text ||
                JournalKind.floatCommit ||
                JournalKind.layerAdd ||
                JournalKind.layerRemove ||
                JournalKind.layerClear => true,
                JournalKind.erase => entry.recipe == null,
                _ => false,
              });
      if ((global || localRasterBarrier) && entry.seq > barrier) {
        barrier = entry.seq;
      }
    }
    return barrier;
  }

  bool canStrokeErase(int sequence) {
    for (final entry in _entries) {
      if (entry.seq != sequence || entry.layerId == null) {
        continue;
      }
      return strokeEraseCandidates(
        layerId: entry.layerId!,
      ).any((candidate) => candidate.seq == sequence);
    }
    return false;
  }

  /// Rebuilds touched tiles while omitting one batch of replayable strokes.
  ///
  /// Reconstruction first reverses the bounded tail to its latest checkpoint
  /// or structural barrier. Recipe entries are then deterministically
  /// re-rendered, while snapshot-only actions apply only their changed pixels.
  /// This prevents a later whole-tile snapshot from resurrecting an omitted
  /// stroke that happened to share the tile.
  Future<JournalDocumentState> replayWithoutStrokes({
    required JournalDocumentState currentState,
    required Iterable<int> sequences,
  }) async {
    final Set<int> targets = sequences.toSet();
    if (targets.isEmpty || targets.any((int sequence) => sequence <= 0)) {
      throw ArgumentError.value(
        sequences,
        'sequences',
        'must contain positive journal sequences',
      );
    }
    final Map<int, JournalEntry> candidates = <int, JournalEntry>{
      for (final InkLayer layer in currentState.layers)
        for (final JournalEntry entry in strokeEraseCandidates(
          layerId: layer.id,
        ))
          entry.seq: entry,
    };
    final List<JournalEntry> targetEntries = <JournalEntry>[];
    for (final int sequence in targets) {
      final JournalEntry? entry = candidates[sequence];
      if (entry == null) {
        throw StateError('Sequence $sequence is outside the stroke-erase tail');
      }
      targetEntries.add(entry);
    }
    final String layerId = targetEntries.first.layerId!;
    if (targetEntries.any((JournalEntry entry) => entry.layerId != layerId)) {
      throw ArgumentError.value(
        sequences,
        'sequences',
        'must belong to one layer',
      );
    }
    final Set<TileKey> clipKeys = <TileKey>{
      for (final JournalEntry entry in targetEntries) ...entry.affectedKeys,
    };
    if (clipKeys.isEmpty) {
      throw StateError('Stroke-erase targets have no affected tiles');
    }
    final int barrier = _strokeEraseBarrier(layerId);
    final Set<int> omittedSequences = <int>{
      ...targets,
      ..._appliedStrokeEraseSequences(),
    };
    final List<JournalEntry> tail = <JournalEntry>[
      for (final JournalEntry entry in _entries.take(_cursor))
        if (entry.seq > barrier &&
            entry.layerId == layerId &&
            entry.affectedKeys.any(clipKeys.contains))
          entry,
    ];

    var replayState = currentState;
    for (final JournalEntry entry in tail.reversed) {
      final _MaterializedTiles materialized = await _materialize(
        entry,
        forward: false,
      );
      if (materialized.missing.isNotEmpty) {
        throw StateError(
          'Missing stroke-erase before snapshots for seq ${entry.seq}',
        );
      }
      replayState = applyJournalEntry(
        replayState,
        entry,
        direction: JournalDirection.reverse,
        tiles: <TileKey, Tile?>{
          for (final MapEntry<TileKey, Tile?> tile
              in materialized.tiles.entries)
            if (clipKeys.contains(tile.key)) tile.key: tile.value,
        },
      );
    }

    for (final JournalEntry entry in tail) {
      if (omittedSequences.contains(entry.seq) || _isStrokeEraseCommit(entry)) {
        continue;
      }
      final Map<TileKey, Tile?> tiles = entry.recipe != null
          ? await _renderRecipe(replayState, entry, clipKeys: clipKeys)
          : await _replayRasterDelta(replayState, entry, clipKeys);
      replayState = applyJournalEntry(
        replayState,
        entry,
        direction: JournalDirection.forward,
        tiles: tiles,
      );
    }
    final TileStore store = currentState.tiles.fork()
      ..publishAll(layerId, <TileKey, Tile?>{
        for (final TileKey key in clipKeys)
          key: replayState.tiles.tile(layerId, key),
      });
    return JournalDocumentState(
      tiles: store,
      layers: _syncLayerTiles(currentState.layers, store),
      canvas: currentState.canvas,
    );
  }

  /// Rebuilds the affected tiles while omitting one stroke in the live tail.
  Future<JournalDocumentState> replayWithoutStroke({
    required JournalDocumentState currentState,
    required int sequence,
    required JournalDocumentState replayBaseState,
    int replayBaseHeadSeq = 0,
  }) async {
    JournalEntry? target;
    for (final entry in _entries) {
      if (entry.seq == sequence) {
        target = entry;
        break;
      }
    }
    if (target == null || !canStrokeErase(sequence)) {
      throw StateError('Sequence $sequence is outside the stroke-erase tail');
    }
    final layerId = target.layerId!;
    final clipKeys = target.affectedKeys.toSet();
    var replayState = replayBaseState;
    var replayAfter = replayBaseHeadSeq;
    final checkpoint = _checkpoints[layerId];
    if (checkpoint != null && checkpoint.throughSeq > replayBaseHeadSeq) {
      final replacement = <TileKey, Tile>{};
      for (final reference in checkpoint.tileReferences.entries) {
        final key = _tileKeyFromReference(reference.key);
        final tile = await storage.readSnapshot(reference.value);
        if (key == null || tile == null) {
          throw StateError('Checkpoint ${checkpoint.throughSeq} is incomplete');
        }
        replacement[key] = tile;
      }
      final store = replayState.tiles.fork()
        ..replaceLayer(layerId, replacement);
      replayState = JournalDocumentState(
        tiles: store,
        layers: _syncLayerTiles(replayState.layers, store),
        canvas: replayState.canvas,
      );
      replayAfter = checkpoint.throughSeq;
    }
    if (replayAfter <
        _strokeEraseBarrier(layerId, beforeSequence: target.seq)) {
      throw StateError('Replay base predates a global stroke-erase barrier');
    }

    for (final entry in _entries) {
      if (entry.seq <= replayAfter ||
          entry.seq > headSeq ||
          entry.seq == sequence ||
          entry.layerId != layerId ||
          !entry.affectedKeys.any(clipKeys.contains)) {
        continue;
      }
      final materialized = await _materialize(entry, forward: true);
      var tiles = materialized.tiles;
      if (materialized.missing.isNotEmpty ||
          (tiles.isEmpty && entry.recipe != null)) {
        tiles = await _renderRecipe(replayState, entry, clipKeys: clipKeys);
      }
      replayState = applyJournalEntry(
        replayState,
        entry,
        direction: JournalDirection.forward,
        tiles: {
          for (final tile in tiles.entries)
            if (clipKeys.contains(tile.key)) tile.key: tile.value,
        },
      );
    }
    final store = currentState.tiles.fork()
      ..publishAll(layerId, {
        for (final key in clipKeys) key: replayState.tiles.tile(layerId, key),
      });
    return JournalDocumentState(
      tiles: store,
      layers: _syncLayerTiles(currentState.layers, store),
      canvas: currentState.canvas,
    );
  }

  /// Truncates autosaved history to the configured depth/age and runs GC.
  Future<void> compact({required int manifestHeadSeq}) async {
    final cutoff = now().subtract(retention).millisecondsSinceEpoch;
    final durable = _entries
        .where(
          (entry) =>
              entry.seq <= manifestHeadSeq && entry.timestampMs >= cutoff,
        )
        .toList();
    final keepDurable = durable.length <= maxDepth
        ? durable
        : durable.sublist(durable.length - maxDepth);
    final pending = _entries
        .where((entry) => entry.seq > manifestHeadSeq)
        .toList();
    final keep = [...keepDurable, ...pending]
      ..sort((left, right) => left.seq.compareTo(right.seq));
    final previousHead = headSeq;
    final nextBaseHeadSeq = keep.isEmpty ? previousHead : keep.first.seq - 1;
    final abandonedToKeep = <_AbandonedJournalEntry>[
      for (final abandoned in _abandonedEntries)
        if (_abandonedEntries.any(
          (candidate) =>
              candidate.groupId == abandoned.groupId &&
              candidate.entry.seq == manifestHeadSeq,
        ))
          abandoned,
    ];
    await storage.replaceJsonLines(
      _recordLines(
        keep,
        _checkpoints,
        abandonedToKeep,
        cursorHeadSeq: previousHead,
        lastIssuedSeq: _lastIssuedSeq,
        baseHeadSeq: nextBaseHeadSeq,
      ),
    );
    _entries = keep;
    _baseHeadSeq = nextBaseHeadSeq;
    _abandonedEntries = abandonedToKeep;
    _cursor = _entries.indexWhere((entry) => entry.seq > previousHead);
    if (_cursor < 0) {
      _cursor = _entries.length;
    }
    await garbageCollectSnapshots();
  }

  Future<void> garbageCollectSnapshots() async {
    final referenced = <String>{};
    for (final entry in _entries) {
      referenced.addAll(entry.beforeReferences.values.whereType<String>());
      referenced.addAll(entry.afterReferences.values.whereType<String>());
    }
    for (final checkpoint in _checkpoints.values) {
      referenced.addAll(checkpoint.tileReferences.values);
    }
    for (final entry in _entries) {
      for (final layer in entry.beforeLayerReferences.values) {
        referenced.addAll(layer.values.whereType<String>());
      }
      for (final layer in entry.afterLayerReferences.values) {
        referenced.addAll(layer.values.whereType<String>());
      }
    }
    for (final abandoned in _abandonedEntries) {
      final entry = abandoned.entry;
      referenced.addAll(entry.beforeReferences.values.whereType<String>());
      referenced.addAll(entry.afterReferences.values.whereType<String>());
      for (final layer in entry.beforeLayerReferences.values) {
        referenced.addAll(layer.values.whereType<String>());
      }
      for (final layer in entry.afterLayerReferences.values) {
        referenced.addAll(layer.values.whereType<String>());
      }
    }
    for (final existing in await storage.listSnapshotReferences()) {
      if (!referenced.contains(existing)) {
        await storage.removeSnapshot(existing);
      }
    }
  }

  Future<void> close() => storage.close();

  Future<void> _maybeCreateCheckpoint(String layerId, TileStore store) async {
    final through = _checkpoints[layerId]?.throughSeq ?? 0;
    final tail = _entries
        .where(
          (entry) =>
              entry.layerId == layerId &&
              entry.seq > through &&
              entry.recipe != null,
        )
        .toList();
    final bytes = tail.fold<int>(
      0,
      (total, entry) => total + entry.recipe!.encodedByteLength,
    );
    if (tail.length < checkpointInterval && bytes <= recipeByteBudget) {
      return;
    }

    final references = <String, String>{};
    for (final tile in store.layerTiles(layerId).entries) {
      references[_tileReferenceKey(tile.key)] = await storage.putSnapshot(
        tile.value,
      );
    }
    final checkpoint = JournalCheckpoint(
      layerId: layerId,
      throughSeq: tail.last.seq,
      timestampMs: now().millisecondsSinceEpoch,
      tileReferences: references,
    );
    final nextEntries = <JournalEntry>[
      for (final entry in _entries)
        if (entry.layerId == layerId &&
            entry.seq <= checkpoint.throughSeq &&
            entry.recipe != null)
          entry.copyWith(recipe: () => null, recipeCompacted: true)
        else
          entry,
    ];
    final nextCheckpoints = Map<String, JournalCheckpoint>.of(_checkpoints)
      ..[layerId] = checkpoint;
    await storage.replaceJsonLines(
      _recordLines(
        nextEntries,
        nextCheckpoints,
        _abandonedEntries,
        cursorHeadSeq: headSeq,
        lastIssuedSeq: _lastIssuedSeq,
        baseHeadSeq: _baseHeadSeq,
      ),
    );
    _entries = nextEntries;
    _checkpoints = nextCheckpoints;
    await garbageCollectSnapshots();
  }

  Future<JournalEntry> _prepareDurableEntry(JournalEntry entry) async {
    final before = Map<String, String?>.of(entry.beforeReferences);
    for (final tile in entry.beforeTiles.entries) {
      before[_tileReferenceKey(tile.key)] = tile.value == null
          ? null
          : await storage.putSnapshot(tile.value!);
    }
    final after = Map<String, String?>.of(entry.afterReferences);
    for (final tile in entry.afterTiles.entries) {
      after[_tileReferenceKey(tile.key)] = tile.value == null
          ? null
          : await storage.putSnapshot(tile.value!);
    }
    if (entry.layerId != null && entry.affectedKeys.isNotEmpty) {
      final missingBefore = entry.affectedKeys.where(
        (key) =>
            !before.containsKey(_tileReferenceKey(key)) &&
            !before.containsKey(key.fileName),
      );
      if (missingBefore.isNotEmpty) {
        throw StateError(
          '${entry.kind.name} seq ${entry.seq} has no durable before-image for '
          '${missingBefore.map(_tileReferenceKey).join(', ')}',
        );
      }
    }
    final beforeLayers = _mutableLayerReferences(entry.beforeLayerReferences);
    for (final layer in entry.beforeLayerTiles.entries) {
      final references = beforeLayers.putIfAbsent(layer.key, () => {});
      for (final tile in layer.value.entries) {
        references[_tileReferenceKey(tile.key)] = tile.value == null
            ? null
            : await storage.putSnapshot(tile.value!);
      }
    }
    final afterLayers = _mutableLayerReferences(entry.afterLayerReferences);
    for (final layer in entry.afterLayerTiles.entries) {
      final references = afterLayers.putIfAbsent(layer.key, () => {});
      for (final tile in layer.value.entries) {
        references[_tileReferenceKey(tile.key)] = tile.value == null
            ? null
            : await storage.putSnapshot(tile.value!);
      }
    }

    final needsAfterImage =
        entry.layerId != null &&
        entry.affectedKeys.isNotEmpty &&
        !entry.kind.isRecipeAction &&
        !entry.kind.isStructural &&
        entry.kind != JournalKind.layerClear &&
        entry.kind != JournalKind.canvasFlip;
    if (needsAfterImage) {
      final missing = entry.affectedKeys.where(
        (key) =>
            !after.containsKey(_tileReferenceKey(key)) &&
            !after.containsKey(key.fileName),
      );
      if (missing.isNotEmpty) {
        throw StateError(
          '${entry.kind.name} seq ${entry.seq} has no durable after-image for '
          '${missing.map(_tileReferenceKey).join(', ')}',
        );
      }
    }
    return entry.copyWith(
      beforeReferences: before,
      afterReferences: after,
      beforeLayerReferences: beforeLayers,
      afterLayerReferences: afterLayers,
    );
  }

  Future<JournalEntry> _captureAfterOnFirstUndo(
    JournalEntry entry,
    JournalDocumentState state,
  ) async {
    if (entry.afterTiles.isNotEmpty || entry.afterReferences.isNotEmpty) {
      return entry;
    }
    final layerId = entry.layerId!;
    final captured = <TileKey, Tile?>{
      for (final key in entry.affectedKeys) key: state.tiles.tile(layerId, key),
    };
    final references = <String, String?>{};
    for (final tile in captured.entries) {
      references[_tileReferenceKey(tile.key)] = tile.value == null
          ? null
          : await storage.putSnapshot(tile.value!);
    }
    final updated = entry.copyWith(
      afterReferences: references,
      afterTiles: captured,
    );
    final next = List<JournalEntry>.of(_entries)
      ..[_entries.indexWhere((candidate) => candidate.seq == entry.seq)] =
          updated;
    await storage.replaceJsonLines(
      _recordLines(
        next,
        _checkpoints,
        _abandonedEntries,
        cursorHeadSeq: headSeq,
        lastIssuedSeq: _lastIssuedSeq,
        baseHeadSeq: _baseHeadSeq,
      ),
    );
    return updated;
  }

  Future<_MaterializedTiles> _materialize(
    JournalEntry entry, {
    required bool forward,
  }) async {
    if (forward && entry.kind == JournalKind.layerClear) {
      return _MaterializedTiles(
        tiles: {for (final key in entry.affectedKeys) key: null},
        missing: const [],
      );
    }
    final hot = forward ? entry.afterTiles : entry.beforeTiles;
    final refs = forward ? entry.afterReferences : entry.beforeReferences;
    final keys = <TileKey>{...entry.affectedKeys, ...hot.keys};
    for (final name in refs.keys) {
      final key = _tileKeyFromReference(name);
      if (key != null) {
        keys.add(key);
      }
    }
    final tiles = <TileKey, Tile?>{};
    final missing = <TileKey>[];
    for (final key in keys) {
      if (hot.containsKey(key)) {
        tiles[key] = hot[key];
        continue;
      }
      final canonicalName = _tileReferenceKey(key);
      final legacyName = key.fileName;
      if (!refs.containsKey(canonicalName) && !refs.containsKey(legacyName)) {
        missing.add(key);
        continue;
      }
      final reference = refs.containsKey(canonicalName)
          ? refs[canonicalName]
          : refs[legacyName];
      if (reference == null) {
        tiles[key] = null;
        continue;
      }
      final tile = await storage.readSnapshot(reference);
      if (tile == null) {
        missing.add(key);
      } else {
        tiles[key] = tile;
      }
    }
    return _MaterializedTiles(tiles: tiles, missing: missing);
  }

  Future<_MaterializedLayerTiles> _materializeLayerTiles(
    JournalEntry entry, {
    required bool forward,
  }) async {
    final hot = forward ? entry.afterLayerTiles : entry.beforeLayerTiles;
    final refs = forward
        ? entry.afterLayerReferences
        : entry.beforeLayerReferences;
    final layerIds = <String>{...hot.keys, ...refs.keys};
    final layers = <String, Map<TileKey, Tile?>>{};
    final missing = <TileLocation>[];
    for (final layerId in layerIds) {
      final hotLayer = hot[layerId] ?? const <TileKey, Tile?>{};
      final refLayer = refs[layerId] ?? const <String, String?>{};
      final keys = <TileKey>{...hotLayer.keys};
      for (final name in refLayer.keys) {
        final key = _tileKeyFromReference(name);
        if (key != null) {
          keys.add(key);
        }
      }
      final tiles = <TileKey, Tile?>{};
      for (final key in keys) {
        if (hotLayer.containsKey(key)) {
          tiles[key] = hotLayer[key];
          continue;
        }
        final canonical = _tileReferenceKey(key);
        final legacy = key.fileName;
        if (!refLayer.containsKey(canonical) && !refLayer.containsKey(legacy)) {
          missing.add(TileLocation(layerId: layerId, key: key));
          continue;
        }
        final reference = refLayer.containsKey(canonical)
            ? refLayer[canonical]
            : refLayer[legacy];
        if (reference == null) {
          tiles[key] = null;
          continue;
        }
        final tile = await storage.readSnapshot(reference);
        if (tile == null) {
          missing.add(TileLocation(layerId: layerId, key: key));
        } else {
          tiles[key] = tile;
        }
      }
      layers[layerId] = tiles;
    }
    return _MaterializedLayerTiles(layers: layers, missing: missing);
  }

  Future<Map<TileKey, Tile?>> _renderRecipe(
    JournalDocumentState state,
    JournalEntry entry, {
    Iterable<TileKey>? clipKeys,
  }) async {
    final renderer = recipeRenderer;
    if (renderer == null || entry.recipe == null) {
      throw StateError('No replay data for journal sequence ${entry.seq}');
    }
    return Map<TileKey, Tile?>.unmodifiable(
      await renderer(
        RecipeReplayRequest(
          state: state,
          entry: entry,
          clipKeys: clipKeys ?? entry.affectedKeys,
        ),
      ),
    );
  }

  Future<Map<TileKey, Tile?>> _replayRasterDelta(
    JournalDocumentState state,
    JournalEntry entry,
    Set<TileKey> clipKeys,
  ) async {
    final _MaterializedTiles before = await _materialize(entry, forward: false);
    final _MaterializedTiles after = await _materialize(entry, forward: true);
    if (before.missing.isNotEmpty || after.missing.isNotEmpty) {
      throw StateError('Missing stroke-erase snapshots for seq ${entry.seq}');
    }
    final String layerId = entry.layerId!;
    final Map<TileKey, Tile?> result = <TileKey, Tile?>{};
    for (final TileKey key in entry.affectedKeys) {
      if (!clipKeys.contains(key)) {
        continue;
      }
      final Uint8List oldPixels =
          before.tiles[key]?.pixels ?? Uint8List(Tile.byteLength);
      final Uint8List newPixels =
          after.tiles[key]?.pixels ?? Uint8List(Tile.byteLength);
      final Uint8List output =
          state.tiles.tile(layerId, key)?.mutableCopy() ??
          Uint8List(Tile.byteLength);
      var changed = false;
      for (var offset = 0; offset < Tile.byteLength; offset += 4) {
        final bool actionChangedPixel =
            oldPixels[offset] != newPixels[offset] ||
            oldPixels[offset + 1] != newPixels[offset + 1] ||
            oldPixels[offset + 2] != newPixels[offset + 2] ||
            oldPixels[offset + 3] != newPixels[offset + 3];
        if (!actionChangedPixel) {
          continue;
        }
        output.setRange(offset, offset + 4, newPixels, offset);
        changed = true;
      }
      if (!changed) {
        continue;
      }
      final Tile tile = Tile.takeOwnership(output);
      result[key] = tile.isTransparent ? null : tile;
    }
    return result;
  }

  Future<Map<TileKey, Tile?>> _reconstructBeforeFromRecipes(
    JournalEntry target, {
    required JournalDocumentState baseState,
    required int baseHeadSeq,
  }) async {
    final layerId = target.layerId!;
    var state = baseState;
    var replayAfter = baseHeadSeq;
    final checkpoint = _checkpoints[layerId];
    if (checkpoint != null &&
        checkpoint.throughSeq > baseHeadSeq &&
        checkpoint.throughSeq < target.seq) {
      final replacement = <TileKey, Tile>{};
      for (final reference in checkpoint.tileReferences.entries) {
        final key = _tileKeyFromReference(reference.key);
        final tile = await storage.readSnapshot(reference.value);
        if (key == null || tile == null) {
          throw StateError('Checkpoint ${checkpoint.throughSeq} is incomplete');
        }
        replacement[key] = tile;
      }
      final store = state.tiles.fork()..replaceLayer(layerId, replacement);
      state = JournalDocumentState(
        tiles: store,
        layers: _syncLayerTiles(state.layers, store),
        canvas: state.canvas,
      );
      replayAfter = checkpoint.throughSeq;
    }
    if (replayAfter <
        _strokeEraseBarrier(layerId, beforeSequence: target.seq)) {
      throw StateError('Replay base predates a global reconstruction barrier');
    }
    for (final entry in _entries) {
      if (entry.seq <= replayAfter || entry.seq >= target.seq) {
        continue;
      }
      if (entry.layerId != layerId) {
        continue;
      }
      final materialized = await _materialize(entry, forward: true);
      var tiles = materialized.tiles;
      if (materialized.missing.isNotEmpty ||
          (tiles.isEmpty && entry.recipe != null)) {
        tiles = await _renderRecipe(state, entry);
      }
      state = applyJournalEntry(
        state,
        entry,
        direction: JournalDirection.forward,
        tiles: tiles,
      );
    }
    return {
      for (final key in target.affectedKeys)
        key: state.tiles.tile(layerId, key),
    };
  }

  Future<void> _discardRedoBranch() async {
    final kept = _entries.sublist(0, _cursor);
    final head = kept.isEmpty ? 0 : kept.last.seq;
    final abandoned = <_AbandonedJournalEntry>[
      ..._abandonedEntries,
      for (final entry in _entries.skip(_cursor))
        _AbandonedJournalEntry(
          groupId: '$head-$_lastIssuedSeq',
          baseHeadSeq: head,
          entry: entry,
        ),
    ];
    final checkpoints = <String, JournalCheckpoint>{
      for (final entry in _checkpoints.entries)
        if (entry.value.throughSeq <= head) entry.key: entry.value,
    };
    await storage.replaceJsonLines(
      _recordLines(
        kept,
        checkpoints,
        abandoned,
        cursorHeadSeq: head,
        lastIssuedSeq: _lastIssuedSeq,
        baseHeadSeq: _baseHeadSeq,
      ),
    );
    _entries = kept;
    _checkpoints = checkpoints;
    _abandonedEntries = abandoned;
    await garbageCollectSnapshots();
  }

  Future<void> _persistCursor(int cursor) => storage.replaceJsonLines(
    _recordLines(
      _entries,
      _checkpoints,
      _abandonedEntries,
      cursorHeadSeq: cursor == 0 ? _baseHeadSeq : _entries[cursor - 1].seq,
      lastIssuedSeq: _lastIssuedSeq,
      baseHeadSeq: _baseHeadSeq,
    ),
  );
}

final class _MaterializedTiles {
  const _MaterializedTiles({required this.tiles, required this.missing});

  final Map<TileKey, Tile?> tiles;
  final List<TileKey> missing;
}

final class _MaterializedLayerTiles {
  const _MaterializedLayerTiles({required this.layers, required this.missing});

  final Map<String, Map<TileKey, Tile?>> layers;
  final List<TileLocation> missing;
}

List<String> _recordLines(
  Iterable<JournalEntry> entries,
  Map<String, JournalCheckpoint> checkpoints,
  Iterable<_AbandonedJournalEntry> abandonedEntries, {
  int? cursorHeadSeq,
  required int lastIssuedSeq,
  required int baseHeadSeq,
}) {
  final records =
      <({int seq, int order, Map<String, Object?> json})>[
        for (final entry in entries)
          (seq: entry.seq, order: 0, json: entry.toJson()),
        for (final checkpoint in checkpoints.values)
          (seq: checkpoint.throughSeq, order: 1, json: checkpoint.toJson()),
      ]..sort((left, right) {
        final sequence = left.seq.compareTo(right.seq);
        return sequence != 0 ? sequence : left.order.compareTo(right.order);
      });
  return [
    for (final record in records) jsonEncode(record.json),
    for (final abandoned in abandonedEntries) jsonEncode(abandoned.toJson()),
    jsonEncode({
      'type': 'metadata',
      'lastIssuedSeq': lastIssuedSeq,
      'baseHeadSeq': baseHeadSeq,
    }),
    if (cursorHeadSeq != null)
      jsonEncode({'type': 'cursor', 'headSeq': cursorHeadSeq}),
  ];
}

JournalDocumentState _applyStructuralState(
  JournalDocumentState state,
  Map<String, Object?>? payload,
) {
  if (payload == null) {
    return state;
  }
  final rawCanvas = payload['canvas'];
  final canvas = rawCanvas == null
      ? state.canvas
      : CanvasSpec.fromJson(_requiredJsonMap(rawCanvas));
  final rawLayers = payload['layers'];
  final layers = rawLayers == null
      ? state.layers
      : [
          for (final value in rawLayers as List<Object?>)
            InkLayer.fromJson(_requiredJsonMap(value)),
        ];
  return JournalDocumentState(
    tiles: state.tiles.fork(),
    layers: layers,
    canvas: canvas,
  );
}

List<InkLayer> _syncLayerTiles(List<InkLayer> layers, TileStore store) => [
  for (final layer in layers)
    layer.copyWith(tiles: store.occupiedKeys(layer.id)),
];

JournalDocumentState _flipCanvas(
  JournalDocumentState state, {
  Iterable<String>? onlyLayerIds,
}) {
  final store = state.tiles.fork();
  final layerIds =
      onlyLayerIds?.toSet() ??
      <String>{...store.layerIds, ...state.layers.map((e) => e.id)};
  for (final layerId in layerIds) {
    final output = <TileKey, Uint8List>{};
    for (final source in store.layerTiles(layerId).entries) {
      final sourcePixels = source.value.pixels;
      for (var localY = 0; localY < Tile.edge; localY += 1) {
        final globalY = source.key.y * Tile.edge + localY;
        final destinationTileY = _tileCoordinateForPixel(globalY);
        final destinationLocalY = globalY - destinationTileY * Tile.edge;
        for (var localX = 0; localX < Tile.edge; localX += 1) {
          final sourceOffset =
              (localY * Tile.edge + localX) * Tile.bytesPerPixel;
          if (sourcePixels[sourceOffset + 3] == 0) {
            continue;
          }
          final globalX = source.key.x * Tile.edge + localX;
          final destinationX = state.canvas.width - 1 - globalX;
          final destinationTileX = _tileCoordinateForPixel(destinationX);
          final destinationLocalX = destinationX - destinationTileX * Tile.edge;
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
    store.replaceLayer(layerId, <TileKey, Tile>{
      for (final entry in ordered) entry.key: Tile.takeOwnership(entry.value),
    });
  }
  return JournalDocumentState(
    tiles: store,
    layers: _syncLayerTiles(state.layers, store),
    canvas: state.canvas,
  );
}

int _tileCoordinateForPixel(int pixel) =>
    pixel >= 0 ? pixel ~/ Tile.edge : -((-pixel + Tile.edge - 1) ~/ Tile.edge);

JournalBounds? _optionalBounds(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! List<Object?>) {
    throw const FormatException('Journal bbox is not a list');
  }
  return JournalBounds.fromJson(value);
}

List<TileKey> _decodeKeys(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is! List<Object?>) {
    throw const FormatException('Journal affected keys are not a list');
  }
  final result = <TileKey>[];
  for (final pair in value) {
    if (pair is! List<Object?> ||
        pair.length != 2 ||
        pair[0] is! int ||
        pair[1] is! int) {
      throw const FormatException('Invalid affected tile key');
    }
    result.add(TileKey(pair[0]! as int, pair[1]! as int));
  }
  return result;
}

Map<String, String?> _decodeReferences(Object? value) {
  if (value == null) {
    return const {};
  }
  final map = _requiredJsonMap(value);
  final result = <String, String?>{};
  for (final entry in map.entries) {
    if (entry.value != null && entry.value is! String) {
      throw const FormatException('Invalid tile snapshot reference');
    }
    result[entry.key] = entry.value as String?;
  }
  return result;
}

Map<String, Map<String, String?>> _decodeLayerReferences(Object? value) {
  if (value == null) {
    return const {};
  }
  final layers = _requiredJsonMap(value);
  return {
    for (final layer in layers.entries)
      layer.key: _decodeReferences(layer.value),
  };
}

Map<String, Map<String, String?>> _freezeLayerReferences(
  Map<String, Map<String, String?>> source,
) => Map<String, Map<String, String?>>.unmodifiable({
  for (final layer in source.entries)
    layer.key: Map<String, String?>.unmodifiable(layer.value),
});

Map<String, Map<String, String?>> _mutableLayerReferences(
  Map<String, Map<String, String?>> source,
) => {
  for (final layer in source.entries)
    layer.key: Map<String, String?>.of(layer.value),
};

Map<String, Map<TileKey, Tile?>> _freezeLayerTiles(
  Map<String, Map<TileKey, Tile?>> source,
) => Map<String, Map<TileKey, Tile?>>.unmodifiable({
  for (final layer in source.entries)
    layer.key: Map<TileKey, Tile?>.unmodifiable(layer.value),
});

String _tileReferenceKey(TileKey key) => '${key.x}_${key.y}';

TileKey? _tileKeyFromReference(String reference) => TileKey.tryFromFileName(
  reference.endsWith('.tile') ? reference : '$reference.tile',
);

Map<String, Object?>? _optionalJsonMap(Object? value) =>
    value == null ? null : _requiredJsonMap(value);

Map<String, Set<TileKey>> _structuralLayerTiles(Map<String, Object?>? state) {
  final rawLayers = state?['layers'];
  if (rawLayers is! List<Object?>) {
    throw const FormatException('Structural state requires a layers list');
  }
  return {
    for (final value in rawLayers)
      if (InkLayer.fromJson(_requiredJsonMap(value)) case final layer)
        layer.id: layer.tiles.toSet(),
  };
}

bool _isCompleteRasterSnapshot(
  Map<String, Set<TileKey>> expected,
  Map<String, Map<String, String?>> references,
  Map<String, Map<TileKey, Tile?>> hot,
) {
  final actualLayerIds = <String>{...references.keys, ...hot.keys};
  if (expected.length != actualLayerIds.length ||
      !expected.keys.every(actualLayerIds.contains)) {
    return false;
  }
  for (final layer in expected.entries) {
    final refLayer = references[layer.key] ?? const <String, String?>{};
    final hotLayer = hot[layer.key] ?? const <TileKey, Tile?>{};
    final actual = <TileKey, bool>{};
    for (final reference in refLayer.entries) {
      final key = _tileKeyFromReference(reference.key);
      if (key == null) {
        return false;
      }
      actual[key] = reference.value != null;
    }
    for (final tile in hotLayer.entries) {
      actual[tile.key] = tile.value != null;
    }
    if (actual.length != layer.value.length ||
        !layer.value.every((key) => actual[key] == true)) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _requiredJsonMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, Object?>();
  }
  throw const FormatException('Expected a JSON object');
}

Map<String, Object?> _freezeJsonMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeJson(entry.value),
    });

Object? _freezeJson(Object? value) {
  if (value is Map<String, Object?>) {
    return _freezeJsonMap(value);
  }
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return _freezeJsonMap(value.cast<String, Object?>());
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  return value;
}

String _sha256Hex(Uint8List input) {
  const initial = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  const constants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final bitLength = input.length * 8;
  final paddedLength = ((input.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, input.length, input);
  padded[input.length] = 0x80;
  final tail = ByteData.sublistView(padded);
  tail.setUint32(paddedLength - 8, bitLength ~/ 0x100000000, Endian.big);
  tail.setUint32(paddedLength - 4, bitLength & 0xffffffff, Endian.big);
  final hash = List<int>.of(initial);
  final words = List<int>.filled(64, 0);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var index = 0; index < 16; index += 1) {
      words[index] = tail.getUint32(offset + index * 4, Endian.big);
    }
    for (var index = 16; index < 64; index += 1) {
      final s0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }
    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var index = 0; index < 64; index += 1) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choice = (e & f) ^ ((~e) & g);
      final temp1 =
          (h + sum1 + choice + constants[index] + words[index]) & 0xffffffff;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    hash[0] = (hash[0] + a) & 0xffffffff;
    hash[1] = (hash[1] + b) & 0xffffffff;
    hash[2] = (hash[2] + c) & 0xffffffff;
    hash[3] = (hash[3] + d) & 0xffffffff;
    hash[4] = (hash[4] + e) & 0xffffffff;
    hash[5] = (hash[5] + f) & 0xffffffff;
    hash[6] = (hash[6] + g) & 0xffffffff;
    hash[7] = (hash[7] + h) & 0xffffffff;
  }
  return hash.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}

int _rotateRight(int value, int count) =>
    ((value >> count) | (value << (32 - count))) & 0xffffffff;
