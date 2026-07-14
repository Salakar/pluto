import 'dart:collection';
import 'dart:typed_data';

/// One coordinate in Ink's sparse tile grid.
final class TileKey implements Comparable<TileKey> {
  /// Creates a tile coordinate.
  const TileKey(this.x, this.y);

  static final RegExp _fileNamePattern = RegExp(r'^(-?\d+)_(-?\d+)\.tile$');

  /// Horizontal tile coordinate.
  final int x;

  /// Vertical tile coordinate.
  final int y;

  /// Canonical on-disk file name for this coordinate.
  String get fileName => '${x}_$y.tile';

  /// Parses a canonical `<x>_<y>.tile` file name.
  factory TileKey.fromFileName(String fileName) {
    final parsed = tryFromFileName(fileName);
    if (parsed == null) {
      throw FormatException('Invalid tile file name: $fileName');
    }
    return parsed;
  }

  /// Parses [fileName], returning null when it is not canonical tile syntax.
  static TileKey? tryFromFileName(String fileName) {
    final match = _fileNamePattern.firstMatch(fileName);
    if (match == null) {
      return null;
    }
    final x = int.tryParse(match.group(1)!);
    final y = int.tryParse(match.group(2)!);
    return x == null || y == null ? null : TileKey(x, y);
  }

  /// Orders keys by x and then y for deterministic manifests and disk scans.
  @override
  int compareTo(TileKey other) {
    final xOrder = x.compareTo(other.x);
    return xOrder != 0 ? xOrder : y.compareTo(other.y);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TileKey && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'TileKey($x, $y)';
}

/// A layer-qualified tile coordinate.
final class TileLocation implements Comparable<TileLocation> {
  /// Creates a layer-qualified tile coordinate.
  const TileLocation({required this.layerId, required this.key});

  /// Opaque layer identifier.
  final String layerId;

  /// Coordinate within the layer.
  final TileKey key;

  @override
  int compareTo(TileLocation other) {
    final layerOrder = layerId.compareTo(other.layerId);
    return layerOrder != 0 ? layerOrder : key.compareTo(other.key);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TileLocation && layerId == other.layerId && key == other.key;

  @override
  int get hashCode => Object.hash(layerId, key);

  @override
  String toString() => 'TileLocation($layerId, $key)';
}

/// A published-immutable 256 by 256 RGBA8888 raster tile.
///
/// The default constructor takes a defensive copy. [takeOwnership] avoids that
/// copy for worker-produced buffers; its caller must relinquish every mutable
/// reference to the input list after construction.
final class Tile {
  /// Creates a tile by defensively copying [pixels].
  factory Tile(Uint8List pixels) {
    _validateLength(pixels);
    return Tile.takeOwnership(Uint8List.fromList(pixels));
  }

  /// Creates a tile and takes ownership of [pixels] without copying it.
  factory Tile.takeOwnership(Uint8List pixels) {
    _validateLength(pixels);
    return Tile._(pixels.asUnmodifiableView());
  }

  const Tile._(this.pixels);

  /// Tile width and height in pixels.
  static const int edge = 256;

  /// Bytes per RGBA8888 pixel.
  static const int bytesPerPixel = 4;

  /// Byte count of every full-size tile.
  static const int byteLength = edge * edge * bytesPerPixel;

  /// Immutable-view RGBA8888 pixels in row-major order.
  final Uint8List pixels;

  /// Returns a mutable copy suitable for a new COW commit.
  Uint8List mutableCopy() => Uint8List.fromList(pixels);

  /// Whether every pixel is fully transparent.
  bool get isTransparent {
    for (var alpha = 3; alpha < pixels.length; alpha += bytesPerPixel) {
      if (pixels[alpha] != 0) {
        return false;
      }
    }
    return true;
  }

  static void _validateLength(Uint8List pixels) {
    if (pixels.lengthInBytes != byteLength) {
      throw ArgumentError.value(
        pixels.lengthInBytes,
        'pixels.lengthInBytes',
        'must be exactly $byteLength',
      );
    }
  }
}

/// Current memory accounting for one [TileStore].
final class TileStoreMemoryUsage {
  /// Creates an accounting snapshot.
  const TileStoreMemoryUsage({
    required this.layerCount,
    required this.tileCount,
    required this.uniqueTileCount,
    required this.bytesHeld,
  });

  /// Number of layer maps explicitly held by the store.
  final int layerCount;

  /// Number of occupied layer/key slots.
  final int tileCount;

  /// Number of distinct immutable [Tile] references held.
  final int uniqueTileCount;

  /// Raw RGBA bytes held by distinct tile references.
  final int bytesHeld;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TileStoreMemoryUsage &&
          layerCount == other.layerCount &&
          tileCount == other.tileCount &&
          uniqueTileCount == other.uniqueTileCount &&
          bytesHeld == other.bytesHeld;

  @override
  int get hashCode =>
      Object.hash(layerCount, tileCount, uniqueTileCount, bytesHeld);

  @override
  String toString() =>
      'TileStoreMemoryUsage(layers: $layerCount, slots: $tileCount, '
      'unique: $uniqueTileCount, bytes: $bytesHeld)';
}

/// Receives memory snapshots after effective store mutations.
typedef TileStoreMemoryListener = void Function(TileStoreMemoryUsage usage);

/// Sparse raster truth, partitioned by opaque layer identifier.
///
/// Publishing replaces whole immutable [Tile] references. There is no
/// automatic eviction or LRU policy: engine code explicitly calls [evict] or
/// [evictAll] after it has made the tile recoverable elsewhere.
final class TileStore {
  /// Creates an empty sparse tile store.
  TileStore({this.onMemoryChanged});

  /// Creates an independent map structure sharing immutable tile references.
  factory TileStore.from(
    TileStore source, {
    TileStoreMemoryListener? onMemoryChanged,
  }) {
    final result = TileStore(onMemoryChanged: onMemoryChanged);
    for (final layerEntry in source._layers.entries) {
      final destination = <TileKey, Tile>{};
      result._layers[layerEntry.key] = destination;
      for (final tileEntry in layerEntry.value.entries) {
        destination[tileEntry.key] = tileEntry.value;
        result._trackAdded(tileEntry.value);
      }
    }
    return result;
  }

  final Map<String, Map<TileKey, Tile>> _layers = {};
  final Map<Tile, int> _referenceCounts = HashMap<Tile, int>.identity();

  /// Optional accounting hook invoked once after each effective mutation.
  final TileStoreMemoryListener? onMemoryChanged;

  /// Sorted snapshot of layer identifiers represented by this store.
  Iterable<String> get layerIds {
    final result = _layers.keys.toList()..sort();
    return List<String>.unmodifiable(result);
  }

  /// Sorted snapshot of all occupied layer/key locations.
  Iterable<TileLocation> get locations {
    final result = <TileLocation>[
      for (final layerEntry in _layers.entries)
        for (final key in layerEntry.value.keys)
          TileLocation(layerId: layerEntry.key, key: key),
    ]..sort();
    return List<TileLocation>.unmodifiable(result);
  }

  /// Number of occupied layer/key slots.
  int get tileCount =>
      _layers.values.fold(0, (count, tiles) => count + tiles.length);

  /// Number of distinct immutable tile references held by this store.
  int get uniqueTileCount => _referenceCounts.length;

  /// Raw byte count held by distinct immutable tile references.
  int get bytesHeld => uniqueTileCount * Tile.byteLength;

  /// Current memory accounting snapshot.
  TileStoreMemoryUsage get memoryUsage => TileStoreMemoryUsage(
    layerCount: _layers.length,
    tileCount: tileCount,
    uniqueTileCount: uniqueTileCount,
    bytesHeld: bytesHeld,
  );

  /// Whether [layerId] has an explicitly represented layer map.
  bool containsLayer(String layerId) => _layers.containsKey(layerId);

  /// Ensures an empty layer map exists, returning whether it was created.
  bool ensureLayer(String layerId) {
    _checkLayerId(layerId);
    if (_layers.containsKey(layerId)) {
      return false;
    }
    _layers[layerId] = {};
    _notifyMemoryChanged();
    return true;
  }

  /// Returns the published tile at [key], or null for transparent absence.
  Tile? tile(String layerId, TileKey key) => _layers[layerId]?[key];

  /// Returns an immutable sorted snapshot of occupied keys for [layerId].
  Iterable<TileKey> occupiedKeys(String layerId) {
    final result = _layers[layerId]?.keys.toList() ?? <TileKey>[];
    result.sort();
    return List<TileKey>.unmodifiable(result);
  }

  /// Returns an immutable snapshot of the occupied tiles for [layerId].
  Map<TileKey, Tile> layerTiles(String layerId) =>
      Map<TileKey, Tile>.unmodifiable(_layers[layerId] ?? const {});

  /// Number of occupied tile slots in [layerId].
  int tileCountForLayer(String layerId) => _layers[layerId]?.length ?? 0;

  /// Raw bytes represented by occupied slots in [layerId].
  ///
  /// Unlike [bytesHeld], this per-layer number deliberately counts a shared
  /// tile once per slot because it describes the layer's standalone cost.
  int bytesHeldForLayer(String layerId) =>
      tileCountForLayer(layerId) * Tile.byteLength;

  /// Publishes [next] at [key] and returns the previous immutable reference.
  ///
  /// Passing null removes the coordinate. A non-null publish creates the
  /// layer map on demand.
  Tile? publish(String layerId, TileKey key, Tile? next) {
    _checkLayerId(layerId);
    final before = tile(layerId, key);
    if (identical(before, next)) {
      return before;
    }
    _publishWithoutNotification(layerId, key, next);
    _notifyMemoryChanged();
    return before;
  }

  /// Publishes a COW batch and returns every corresponding before-reference.
  Map<TileKey, Tile?> publishAll(String layerId, Map<TileKey, Tile?> changes) {
    _checkLayerId(layerId);
    if (changes.isEmpty) {
      return const {};
    }
    var changed = false;
    final before = <TileKey, Tile?>{};
    for (final entry in changes.entries) {
      final previous = tile(layerId, entry.key);
      before[entry.key] = previous;
      if (identical(previous, entry.value)) {
        continue;
      }
      _publishWithoutNotification(layerId, entry.key, entry.value);
      changed = true;
    }
    if (changed) {
      _notifyMemoryChanged();
    }
    return Map<TileKey, Tile?>.unmodifiable(before);
  }

  /// Removes [key], returning its previous immutable reference.
  Tile? remove(String layerId, TileKey key) => publish(layerId, key, null);

  /// Replaces all content in [layerId], returning its previous tile snapshot.
  Map<TileKey, Tile> replaceLayer(
    String layerId,
    Map<TileKey, Tile> replacement,
  ) {
    _checkLayerId(layerId);
    final before = layerTiles(layerId);
    final previous = _layers[layerId];
    if (previous != null) {
      for (final tile in previous.values) {
        _trackRemoved(tile);
      }
    }
    final next = Map<TileKey, Tile>.of(replacement);
    _layers[layerId] = next;
    for (final tile in next.values) {
      _trackAdded(tile);
    }
    _notifyMemoryChanged();
    return before;
  }

  /// Clears [layerId] but keeps its empty layer map represented.
  Map<TileKey, Tile> clearLayer(String layerId) {
    _checkLayerId(layerId);
    final tiles = _layers[layerId];
    if (tiles == null) {
      return const {};
    }
    final before = Map<TileKey, Tile>.unmodifiable(Map.of(tiles));
    if (tiles.isEmpty) {
      return before;
    }
    for (final tile in tiles.values) {
      _trackRemoved(tile);
    }
    tiles.clear();
    _notifyMemoryChanged();
    return before;
  }

  /// Removes a complete layer map, returning its former tiles.
  Map<TileKey, Tile> removeLayer(String layerId) {
    final tiles = _layers.remove(layerId);
    if (tiles == null) {
      return const {};
    }
    for (final tile in tiles.values) {
      _trackRemoved(tile);
    }
    _notifyMemoryChanged();
    return Map<TileKey, Tile>.unmodifiable(tiles);
  }

  /// Explicitly evicts one tile and returns the evicted immutable reference.
  Tile? evict(String layerId, TileKey key) => remove(layerId, key);

  /// Explicitly evicts [requested] locations and returns those that existed.
  Map<TileLocation, Tile> evictAll(Iterable<TileLocation> requested) {
    final evicted = <TileLocation, Tile>{};
    var changed = false;
    for (final location in requested) {
      final before = tile(location.layerId, location.key);
      if (before == null) {
        continue;
      }
      _publishWithoutNotification(location.layerId, location.key, null);
      evicted[location] = before;
      changed = true;
    }
    if (changed) {
      _notifyMemoryChanged();
    }
    return Map<TileLocation, Tile>.unmodifiable(evicted);
  }

  /// Removes all represented layers and tiles.
  void clear() {
    if (_layers.isEmpty) {
      return;
    }
    _layers.clear();
    _referenceCounts.clear();
    _notifyMemoryChanged();
  }

  /// Creates a new store whose maps are independent but tile refs are shared.
  TileStore fork({TileStoreMemoryListener? onMemoryChanged}) =>
      TileStore.from(this, onMemoryChanged: onMemoryChanged);

  /// Throws if internal sparse-map and memory-accounting state disagree.
  void verifyInvariants() {
    final expected = HashMap<Tile, int>.identity();
    for (final tiles in _layers.values) {
      for (final tile in tiles.values) {
        expected[tile] = (expected[tile] ?? 0) + 1;
      }
    }
    if (expected.length != _referenceCounts.length) {
      throw StateError('Tile reference accounting has the wrong cardinality.');
    }
    for (final entry in expected.entries) {
      if (_referenceCounts[entry.key] != entry.value) {
        throw StateError('Tile reference accounting has an incorrect count.');
      }
    }
  }

  void _publishWithoutNotification(String layerId, TileKey key, Tile? next) {
    final layer = _layers[layerId];
    final before = layer?[key];
    if (before != null) {
      _trackRemoved(before);
    }
    if (next == null) {
      layer?.remove(key);
      return;
    }
    final destination = layer ?? (_layers[layerId] = {});
    destination[key] = next;
    _trackAdded(next);
  }

  void _trackAdded(Tile tile) {
    _referenceCounts[tile] = (_referenceCounts[tile] ?? 0) + 1;
  }

  void _trackRemoved(Tile tile) {
    final count = _referenceCounts[tile];
    if (count == null || count <= 0) {
      throw StateError('Removing an untracked tile reference.');
    }
    if (count == 1) {
      _referenceCounts.remove(tile);
    } else {
      _referenceCounts[tile] = count - 1;
    }
  }

  void _notifyMemoryChanged() => onMemoryChanged?.call(memoryUsage);

  static void _checkLayerId(String layerId) {
    if (layerId.isEmpty) {
      throw ArgumentError.value(layerId, 'layerId', 'must not be empty');
    }
  }
}
