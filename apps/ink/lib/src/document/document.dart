import 'tile_store.dart';

/// The current manifest schema written by Ink.
const int inkDocumentSchema = 1;

/// The largest supported canvas edge in document pixels.
const int maxInkCanvasDimension = 4096;

/// Immutable canvas metadata from a document manifest.
final class CanvasSpec {
  /// Creates a canvas description.
  CanvasSpec({
    required this.width,
    required this.height,
    this.background = 'paper',
    Map<String, Object?> unknownFields = const {},
  }) : unknownFields = _freezeJsonMap(
         _withoutKnownFields(unknownFields, _knownFields),
       ) {
    if (width <= 0 || width > maxInkCanvasDimension) {
      throw ArgumentError.value(
        width,
        'width',
        'must be between 1 and $maxInkCanvasDimension',
      );
    }
    if (height <= 0 || height > maxInkCanvasDimension) {
      throw ArgumentError.value(
        height,
        'height',
        'must be between 1 and $maxInkCanvasDimension',
      );
    }
    if (background.isEmpty) {
      throw ArgumentError.value(background, 'background', 'must not be empty');
    }
  }

  static const Set<String> _knownFields = {'width', 'height', 'background'};

  /// Canvas width in document pixels.
  final int width;

  /// Canvas height in document pixels.
  final int height;

  /// Identifier for the procedural background, normally `paper`.
  final String background;

  /// Forward-compatible fields not understood by this version of Ink.
  final Map<String, Object?> unknownFields;

  /// Decodes canvas metadata from manifest JSON.
  factory CanvasSpec.fromJson(Map<String, Object?> json) {
    try {
      return CanvasSpec(
        width: _requiredInt(json, 'width'),
        height: _requiredInt(json, 'height'),
        background: _requiredString(json, 'background'),
        unknownFields: json,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid canvas: $error');
    }
  }

  /// Encodes this canvas while re-emitting unknown fields.
  Map<String, Object?> toJson() => {
    ..._thawJsonMap(unknownFields),
    'width': width,
    'height': height,
    'background': background,
  };

  /// Returns a copy with the requested fields replaced.
  CanvasSpec copyWith({
    int? width,
    int? height,
    String? background,
    Map<String, Object?>? unknownFields,
  }) => CanvasSpec(
    width: width ?? this.width,
    height: height ?? this.height,
    background: background ?? this.background,
    unknownFields: unknownFields ?? this.unknownFields,
  );
}

/// One raster layer in bottom-to-top document z-order.
final class InkLayer {
  /// Creates immutable layer metadata.
  InkLayer({
    required this.id,
    required this.name,
    this.visible = true,
    this.locked = false,
    this.opacity = 100,
    this.blend = 'normal',
    Iterable<TileKey> tiles = const [],
    Map<String, Object?> unknownFields = const {},
  }) : tiles = List<TileKey>.unmodifiable(tiles),
       unknownFields = _freezeJsonMap(
         _withoutKnownFields(unknownFields, _knownFields),
       ) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (opacity < 0 || opacity > 100) {
      throw RangeError.range(opacity, 0, 100, 'opacity');
    }
    if (blend.isEmpty) {
      throw ArgumentError.value(blend, 'blend', 'must not be empty');
    }
  }

  static const Set<String> _knownFields = {
    'id',
    'name',
    'visible',
    'locked',
    'opacity',
    'blend',
    'tiles',
  };

  /// Opaque stable layer identifier.
  final String id;

  /// User-facing layer name.
  final String name;

  /// Whether this layer participates in compositing.
  final bool visible;

  /// Whether editing actions are permitted on this layer.
  final bool locked;

  /// Composite opacity from 0 through 100.
  final int opacity;

  /// Composite blend identifier, currently `normal` or `multiply`.
  final String blend;

  /// Occupied tile coordinates recorded by the manifest.
  final List<TileKey> tiles;

  /// Forward-compatible fields not understood by this version of Ink.
  final Map<String, Object?> unknownFields;

  /// Decodes layer metadata from manifest JSON.
  factory InkLayer.fromJson(Map<String, Object?> json) {
    try {
      final rawTiles = _requiredList(json, 'tiles');
      return InkLayer(
        id: _requiredString(json, 'id'),
        name: _requiredString(json, 'name'),
        visible: _requiredBool(json, 'visible'),
        locked: _requiredBool(json, 'locked'),
        opacity: _requiredInt(json, 'opacity'),
        blend: _requiredString(json, 'blend'),
        tiles: [
          for (var index = 0; index < rawTiles.length; index++)
            _tileKeyFromJson(rawTiles[index], index: index),
        ],
        unknownFields: json,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid layer: $error');
    }
  }

  /// Encodes this layer while re-emitting unknown fields.
  Map<String, Object?> toJson() => {
    ..._thawJsonMap(unknownFields),
    'id': id,
    'name': name,
    'visible': visible,
    'locked': locked,
    'opacity': opacity,
    'blend': blend,
    'tiles': [
      for (final key in tiles) [key.x, key.y],
    ],
  };

  /// Returns a copy with the requested fields replaced.
  InkLayer copyWith({
    String? id,
    String? name,
    bool? visible,
    bool? locked,
    int? opacity,
    String? blend,
    Iterable<TileKey>? tiles,
    Map<String, Object?>? unknownFields,
  }) => InkLayer(
    id: id ?? this.id,
    name: name ?? this.name,
    visible: visible ?? this.visible,
    locked: locked ?? this.locked,
    opacity: opacity ?? this.opacity,
    blend: blend ?? this.blend,
    tiles: tiles ?? this.tiles,
    unknownFields: unknownFields ?? this.unknownFields,
  );
}

/// Persisted document-to-viewport transform.
final class InkViewState {
  /// Creates a persisted view transform.
  InkViewState({
    this.tx = 0,
    this.ty = 0,
    this.scale = 1,
    this.rotationDeg = 0,
    Map<String, Object?> unknownFields = const {},
  }) : unknownFields = _freezeJsonMap(
         _withoutKnownFields(unknownFields, _knownFields),
       ) {
    if (!tx.isFinite || !ty.isFinite) {
      throw ArgumentError('View translation must be finite.');
    }
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    if (!rotationDeg.isFinite) {
      throw ArgumentError.value(rotationDeg, 'rotationDeg', 'must be finite');
    }
  }

  static const Set<String> _knownFields = {'tx', 'ty', 'scale', 'rotationDeg'};

  /// Horizontal translation in viewport logical pixels.
  final double tx;

  /// Vertical translation in viewport logical pixels.
  final double ty;

  /// Uniform document scale.
  final double scale;

  /// Clockwise canvas rotation in degrees.
  final double rotationDeg;

  /// Forward-compatible fields not understood by this version of Ink.
  final Map<String, Object?> unknownFields;

  /// Decodes a persisted view from manifest JSON.
  factory InkViewState.fromJson(Map<String, Object?> json) {
    try {
      return InkViewState(
        tx: _requiredDouble(json, 'tx'),
        ty: _requiredDouble(json, 'ty'),
        scale: _requiredDouble(json, 'scale'),
        rotationDeg: _requiredDouble(json, 'rotationDeg'),
        unknownFields: json,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid view: $error');
    }
  }

  /// Encodes this view while re-emitting unknown fields.
  Map<String, Object?> toJson() => {
    ..._thawJsonMap(unknownFields),
    'tx': tx,
    'ty': ty,
    'scale': scale,
    'rotationDeg': rotationDeg,
  };

  /// Returns a copy with the requested fields replaced.
  InkViewState copyWith({
    double? tx,
    double? ty,
    double? scale,
    double? rotationDeg,
    Map<String, Object?>? unknownFields,
  }) => InkViewState(
    tx: tx ?? this.tx,
    ty: ty ?? this.ty,
    scale: scale ?? this.scale,
    rotationDeg: rotationDeg ?? this.rotationDeg,
    unknownFields: unknownFields ?? this.unknownFields,
  );
}

/// Persisted active tool and per-brush settings.
final class InkToolState {
  /// Creates persisted tool state.
  InkToolState({
    required this.toolId,
    required this.brushId,
    required this.color,
    required this.size,
    Map<String, Object?> presets = const {},
    Map<String, Object?> unknownFields = const {},
  }) : presets = _freezeJsonMap(presets),
       unknownFields = _freezeJsonMap(
         _withoutKnownFields(unknownFields, _knownFields),
       ) {
    if (toolId.isEmpty) {
      throw ArgumentError.value(toolId, 'toolId', 'must not be empty');
    }
    if (brushId.isEmpty) {
      throw ArgumentError.value(brushId, 'brushId', 'must not be empty');
    }
    if (color.isEmpty) {
      throw ArgumentError.value(color, 'color', 'must not be empty');
    }
    if (!size.isFinite || size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be finite and positive');
    }
  }

  static const Set<String> _knownFields = {
    'toolId',
    'brushId',
    'color',
    'size',
    'presets',
  };

  /// Active interaction tool identifier.
  final String toolId;

  /// Active brush identifier.
  final String brushId;

  /// Active color string, normally `#RRGGBB`.
  final String color;

  /// Brush size in document pixels.
  final double size;

  /// Last-used settings keyed by brush identifier.
  final Map<String, Object?> presets;

  /// Forward-compatible fields not understood by this version of Ink.
  final Map<String, Object?> unknownFields;

  /// Decodes persisted tool state from manifest JSON.
  factory InkToolState.fromJson(Map<String, Object?> json) {
    try {
      return InkToolState(
        toolId: _requiredString(json, 'toolId'),
        brushId: _requiredString(json, 'brushId'),
        color: _requiredString(json, 'color'),
        size: _requiredDouble(json, 'size'),
        presets: _requiredMap(json, 'presets'),
        unknownFields: json,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid tool: $error');
    }
  }

  /// Encodes this tool state while re-emitting unknown fields.
  Map<String, Object?> toJson() => {
    ..._thawJsonMap(unknownFields),
    'toolId': toolId,
    'brushId': brushId,
    'color': color,
    'size': size,
    'presets': _thawJsonMap(presets),
  };

  /// Returns a copy with the requested fields replaced.
  InkToolState copyWith({
    String? toolId,
    String? brushId,
    String? color,
    double? size,
    Map<String, Object?>? presets,
    Map<String, Object?>? unknownFields,
  }) => InkToolState(
    toolId: toolId ?? this.toolId,
    brushId: brushId ?? this.brushId,
    color: color ?? this.color,
    size: size ?? this.size,
    presets: presets ?? this.presets,
    unknownFields: unknownFields ?? this.unknownFields,
  );
}

/// Immutable, forward-compatible Ink artwork manifest.
final class InkDocument {
  /// Creates a complete Ink document description.
  InkDocument({
    this.schema = inkDocumentSchema,
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.modifiedAtMs,
    required this.canvas,
    required Iterable<InkLayer> layers,
    required this.activeLayerId,
    required this.view,
    required this.tool,
    this.journalHeadSeq = 0,
    Map<String, Object?> unknownFields = const {},
  }) : layers = List<InkLayer>.unmodifiable(layers),
       unknownFields = _freezeJsonMap(
         _withoutKnownFields(unknownFields, _knownFields),
       ) {
    if (schema != inkDocumentSchema) {
      throw ArgumentError.value(
        schema,
        'schema',
        'only schema $inkDocumentSchema is supported',
      );
    }
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (createdAtMs < 0) {
      throw ArgumentError.value(
        createdAtMs,
        'createdAtMs',
        'must not be negative',
      );
    }
    if (modifiedAtMs < 0) {
      throw ArgumentError.value(
        modifiedAtMs,
        'modifiedAtMs',
        'must not be negative',
      );
    }
    if (journalHeadSeq < 0) {
      throw ArgumentError.value(
        journalHeadSeq,
        'journalHeadSeq',
        'must not be negative',
      );
    }
    final layerIds = <String>{};
    for (final layer in this.layers) {
      if (!layerIds.add(layer.id)) {
        throw ArgumentError.value(
          layer.id,
          'layers',
          'contains a duplicate id',
        );
      }
    }
    if (!layerIds.contains(activeLayerId)) {
      throw ArgumentError.value(
        activeLayerId,
        'activeLayerId',
        'must identify one of the document layers',
      );
    }
  }

  static const Set<String> _knownFields = {
    'schema',
    'id',
    'name',
    'createdAtMs',
    'modifiedAtMs',
    'canvas',
    'layers',
    'activeLayerId',
    'view',
    'tool',
    'journalHeadSeq',
  };

  /// Manifest schema number.
  final int schema;

  /// Opaque stable artwork identifier.
  final String id;

  /// User-facing artwork name.
  final String name;

  /// Creation timestamp in Unix epoch milliseconds.
  final int createdAtMs;

  /// Last modification timestamp in Unix epoch milliseconds.
  final int modifiedAtMs;

  /// Canvas metadata.
  final CanvasSpec canvas;

  /// Layers ordered bottom to top.
  final List<InkLayer> layers;

  /// Identifier of the active layer.
  final String activeLayerId;

  /// Persisted viewport state.
  final InkViewState view;

  /// Persisted active tool state.
  final InkToolState tool;

  /// Last sequence committed to the undo journal.
  final int journalHeadSeq;

  /// Forward-compatible fields not understood by this version of Ink.
  final Map<String, Object?> unknownFields;

  /// Creates a new empty artwork with one default layer.
  factory InkDocument.blank({
    required String id,
    required int nowMs,
    String name = 'Untitled',
  }) => InkDocument(
    id: id,
    name: name,
    createdAtMs: nowMs,
    modifiedAtMs: nowMs,
    canvas: CanvasSpec(width: 1908, height: 3392),
    layers: [InkLayer(id: 'L1', name: 'Layer 1')],
    activeLayerId: 'L1',
    view: InkViewState(),
    tool: InkToolState(
      toolId: 'draw',
      brushId: 'fineliner',
      color: '#1D3E74',
      size: 4,
    ),
  );

  /// Decodes a complete manifest from JSON.
  factory InkDocument.fromJson(Map<String, Object?> json) {
    try {
      final rawLayers = _requiredList(json, 'layers');
      return InkDocument(
        schema: _requiredInt(json, 'schema'),
        id: _requiredString(json, 'id'),
        name: _requiredString(json, 'name'),
        createdAtMs: _requiredInt(json, 'createdAtMs'),
        modifiedAtMs: _requiredInt(json, 'modifiedAtMs'),
        canvas: CanvasSpec.fromJson(_requiredMap(json, 'canvas')),
        layers: [
          for (var index = 0; index < rawLayers.length; index++)
            InkLayer.fromJson(_mapValue(rawLayers[index], 'layers[$index]')),
        ],
        activeLayerId: _requiredString(json, 'activeLayerId'),
        view: InkViewState.fromJson(_requiredMap(json, 'view')),
        tool: InkToolState.fromJson(_requiredMap(json, 'tool')),
        journalHeadSeq: _requiredInt(json, 'journalHeadSeq'),
        unknownFields: json,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid document: $error');
    }
  }

  /// Encodes this manifest while re-emitting unknown fields at every level.
  Map<String, Object?> toJson() => {
    ..._thawJsonMap(unknownFields),
    'schema': schema,
    'id': id,
    'name': name,
    'createdAtMs': createdAtMs,
    'modifiedAtMs': modifiedAtMs,
    'canvas': canvas.toJson(),
    'layers': [for (final layer in layers) layer.toJson()],
    'activeLayerId': activeLayerId,
    'view': view.toJson(),
    'tool': tool.toJson(),
    'journalHeadSeq': journalHeadSeq,
  };

  /// Returns a copy with the requested fields replaced.
  InkDocument copyWith({
    int? schema,
    String? id,
    String? name,
    int? createdAtMs,
    int? modifiedAtMs,
    CanvasSpec? canvas,
    Iterable<InkLayer>? layers,
    String? activeLayerId,
    InkViewState? view,
    InkToolState? tool,
    int? journalHeadSeq,
    Map<String, Object?>? unknownFields,
  }) => InkDocument(
    schema: schema ?? this.schema,
    id: id ?? this.id,
    name: name ?? this.name,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    modifiedAtMs: modifiedAtMs ?? this.modifiedAtMs,
    canvas: canvas ?? this.canvas,
    layers: layers ?? this.layers,
    activeLayerId: activeLayerId ?? this.activeLayerId,
    view: view ?? this.view,
    tool: tool ?? this.tool,
    journalHeadSeq: journalHeadSeq ?? this.journalHeadSeq,
    unknownFields: unknownFields ?? this.unknownFields,
  );
}

TileKey _tileKeyFromJson(Object? value, {required int index}) {
  if (value is! List<Object?> || value.length != 2) {
    throw FormatException('tiles[$index] must be an [x, y] pair.');
  }
  final x = value[0];
  final y = value[1];
  if (x is! int || y is! int) {
    throw FormatException('tiles[$index] coordinates must be integers.');
  }
  return TileKey(x, y);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('$key must be a string.');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key must be an integer.');
  }
  return value;
}

double _requiredDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number.');
  }
  return value.toDouble();
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$key must be a boolean.');
  }
  return value;
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('$key must be an array.');
  }
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) =>
    _mapValue(json[key], key);

Map<String, Object?> _mapValue(Object? value, String path) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('$path must be an object.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings.');
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}

Map<String, Object?> _withoutKnownFields(
  Map<String, Object?> source,
  Set<String> knownFields,
) => {
  for (final entry in source.entries)
    if (!knownFields.contains(entry.key)) entry.key: entry.value,
};

Map<String, Object?> _freezeJsonMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeJson(entry.value),
    });

Object? _freezeJson(Object? value) => switch (value) {
  null || bool() || String() => value,
  final num number when number.isFinite => number,
  final List<Object?> list => List<Object?>.unmodifiable(
    list.map<Object?>(_freezeJson),
  ),
  final Map<Object?, Object?> map => _freezeJsonMap(
    _mapValue(map, 'JSON value'),
  ),
  _ => throw ArgumentError.value(value, 'JSON value', 'is not encodable'),
};

Map<String, Object?> _thawJsonMap(Map<String, Object?> source) => {
  for (final entry in source.entries) entry.key: _thawJson(entry.value),
};

Object? _thawJson(Object? value) => switch (value) {
  final List<Object?> list => [for (final item in list) _thawJson(item)],
  final Map<String, Object?> map => _thawJsonMap(map),
  _ => value,
};
