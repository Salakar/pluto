import 'package:flutter/foundation.dart';

import '../document/document.dart';

/// Geometry used to create a selection mask.
enum SelectionGeometry { rectangle, lasso, wand }

/// How newly created selection pixels combine with the existing mask.
enum SelectionCombine { replace, add, subtract }

/// Aspect-ratio policy used by transform handles.
enum TransformAspect { uniform, free }

/// Pixel source sampled by wand and fill operations.
enum RasterSampleSource { activeLayer, composite }

/// Surface applied to pixels admitted by a fill operation.
enum FillStyle { solid, hatch, dotScreen }

/// Ordered-screen density used by dot-screen fills.
enum DotScreenDensity { bayer4, bayer8 }

/// Primitive emitted by the shape tool.
enum ShapeType { line, arrow, rectangle, ellipse, polygon }

/// Origin policy for shape drags.
enum ShapeOrigin { corner, center }

/// Constraint applied to shape drags.
enum ShapeConstraint { free, aspect }

/// Raster font supported by the text tool.
enum InkTextFont { inter, jetBrainsMono }

/// Non-exporting grid presentation.
enum GuideGridStyle { off, dots, lines }

/// Stroke-only mirror mode configured by the guides tool.
enum InkSymmetryMode { off, vertical, horizontal, quad }

/// Maximum number of colors retained by the color panel's recent row.
const int maxInkRecentColors = 8;

/// An opaque, typed Ink color with a canonical manifest representation.
final class InkColor {
  /// Creates an opaque color from `0xAARRGGBB`.
  const InkColor.fromArgb(this.argb)
    : assert(argb >= 0xff000000 && argb <= 0xffffffff);

  /// Parses a canonical `#RRGGBB` manifest color.
  factory InkColor.fromHex(String value) {
    final InkColor? parsed = InkColor.tryParse(value);
    if (parsed == null) {
      throw FormatException('Ink color must be encoded as #RRGGBB: $value');
    }
    return parsed;
  }

  /// Parses [value], returning null for legacy or future non-hex identifiers.
  static InkColor? tryParse(String value) {
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      return null;
    }
    return InkColor.fromArgb(
      0xff000000 | int.parse(value.substring(1), radix: 16),
    );
  }

  /// Opaque color encoded as `0xAARRGGBB`.
  final int argb;

  /// Canonical uppercase manifest encoding.
  String get hex =>
      '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  bool operator ==(Object other) => other is InkColor && other.argb == argb;

  @override
  int get hashCode => argb.hashCode;

  @override
  String toString() => 'InkColor($hex)';
}

/// Typed, manifest-round-trippable options for WP5 interaction tools.
///
/// The document schema deliberately has no top-level WP5 fields. Options are
/// therefore carried in `InkToolState`'s forward-compatible unknown-field
/// map under `wp5Options`, leaving the existing brush-preset payload intact.
final class Wp5ToolOptions {
  /// Creates validated interaction-tool options.
  const Wp5ToolOptions({
    this.selectionGeometry = SelectionGeometry.rectangle,
    this.selectionCombine = SelectionCombine.replace,
    this.selectionTolerance = 16,
    this.selectionGapClose = 0,
    this.transformAspect = TransformAspect.uniform,
    this.fillTolerance = 16,
    this.fillGapClose = 0,
    this.fillGrow = 0,
    this.fillSampleSource = RasterSampleSource.activeLayer,
    this.fillStyle = FillStyle.solid,
    this.dotScreenDensity = DotScreenDensity.bayer4,
    this.shapeType = ShapeType.line,
    this.polygonSides = 5,
    this.shapeOrigin = ShapeOrigin.corner,
    this.shapeConstraint = ShapeConstraint.free,
    this.textFont = InkTextFont.inter,
    this.textSize = 32,
    this.textWeight = 600,
    this.eyedropperRadiusDpx = 5,
    this.paletteSnapDeltaE = 10,
    this.straightedgeEnabled = false,
    this.gridStyle = GuideGridStyle.off,
    this.gridSpacingDpx = 16,
    this.symmetryMode = InkSymmetryMode.off,
    this.referenceOpacity = 0.5,
  }) : assert(selectionTolerance >= 0 && selectionTolerance <= 64),
       assert(selectionGapClose >= 0 && selectionGapClose <= 4),
       assert(fillTolerance >= 0 && fillTolerance <= 64),
       assert(fillGapClose >= 0 && fillGapClose <= 4),
       assert(fillGrow >= -4 && fillGrow <= 4),
       assert(polygonSides >= 3 && polygonSides <= 32),
       assert(textSize >= 16 && textSize <= 96),
       assert(textWeight >= 500 && textWeight <= 800),
       assert(eyedropperRadiusDpx > 0),
       assert(paletteSnapDeltaE >= 0),
       assert(
         gridSpacingDpx == 8 ||
             gridSpacingDpx == 16 ||
             gridSpacingDpx == 32 ||
             gridSpacingDpx == 64,
       ),
       assert(referenceOpacity >= 0 && referenceOpacity <= 1);

  /// Selection geometry.
  final SelectionGeometry selectionGeometry;

  /// Selection mask combine operation.
  final SelectionCombine selectionCombine;

  /// Wand color tolerance in the inclusive 0–64 range.
  final int selectionTolerance;

  /// Wand boundary close radius in the inclusive 0–4 range.
  final int selectionGapClose;

  /// Transform aspect-ratio policy.
  final TransformAspect transformAspect;

  /// Flood-fill color tolerance in the inclusive 0–64 range.
  final int fillTolerance;

  /// Fill boundary close radius in the inclusive 0–4 range.
  final int fillGapClose;

  /// Signed fill-mask grow amount in the inclusive -4–4 range.
  final int fillGrow;

  /// Raster source sampled by fill.
  final RasterSampleSource fillSampleSource;

  /// Pattern applied by fill.
  final FillStyle fillStyle;

  /// Dot-screen matrix density.
  final DotScreenDensity dotScreenDensity;

  /// Shape primitive.
  final ShapeType shapeType;

  /// Polygon vertex count.
  final int polygonSides;

  /// Shape drag origin policy.
  final ShapeOrigin shapeOrigin;

  /// Shape drag constraint.
  final ShapeConstraint shapeConstraint;

  /// Text rasterization font.
  final InkTextFont textFont;

  /// Text size in design pixels.
  final double textSize;

  /// Text font weight.
  final int textWeight;

  /// Eyedropper averaging radius in design pixels.
  final double eyedropperRadiusDpx;

  /// Palette snap threshold in approximate Delta-E units.
  final double paletteSnapDeltaE;

  /// Whether the persistent straightedge is visible.
  final bool straightedgeEnabled;

  /// Persistent grid presentation.
  final GuideGridStyle gridStyle;

  /// Grid spacing in design pixels.
  final int gridSpacingDpx;

  /// Stroke-only mirror mode.
  final InkSymmetryMode symmetryMode;

  /// Reference-layer preview opacity.
  final double referenceOpacity;

  /// Returns a copy with selected values changed.
  Wp5ToolOptions copyWith({
    SelectionGeometry? selectionGeometry,
    SelectionCombine? selectionCombine,
    int? selectionTolerance,
    int? selectionGapClose,
    TransformAspect? transformAspect,
    int? fillTolerance,
    int? fillGapClose,
    int? fillGrow,
    RasterSampleSource? fillSampleSource,
    FillStyle? fillStyle,
    DotScreenDensity? dotScreenDensity,
    ShapeType? shapeType,
    int? polygonSides,
    ShapeOrigin? shapeOrigin,
    ShapeConstraint? shapeConstraint,
    InkTextFont? textFont,
    double? textSize,
    int? textWeight,
    double? eyedropperRadiusDpx,
    double? paletteSnapDeltaE,
    bool? straightedgeEnabled,
    GuideGridStyle? gridStyle,
    int? gridSpacingDpx,
    InkSymmetryMode? symmetryMode,
    double? referenceOpacity,
  }) => Wp5ToolOptions(
    selectionGeometry: selectionGeometry ?? this.selectionGeometry,
    selectionCombine: selectionCombine ?? this.selectionCombine,
    selectionTolerance: selectionTolerance ?? this.selectionTolerance,
    selectionGapClose: selectionGapClose ?? this.selectionGapClose,
    transformAspect: transformAspect ?? this.transformAspect,
    fillTolerance: fillTolerance ?? this.fillTolerance,
    fillGapClose: fillGapClose ?? this.fillGapClose,
    fillGrow: fillGrow ?? this.fillGrow,
    fillSampleSource: fillSampleSource ?? this.fillSampleSource,
    fillStyle: fillStyle ?? this.fillStyle,
    dotScreenDensity: dotScreenDensity ?? this.dotScreenDensity,
    shapeType: shapeType ?? this.shapeType,
    polygonSides: polygonSides ?? this.polygonSides,
    shapeOrigin: shapeOrigin ?? this.shapeOrigin,
    shapeConstraint: shapeConstraint ?? this.shapeConstraint,
    textFont: textFont ?? this.textFont,
    textSize: textSize ?? this.textSize,
    textWeight: textWeight ?? this.textWeight,
    eyedropperRadiusDpx: eyedropperRadiusDpx ?? this.eyedropperRadiusDpx,
    paletteSnapDeltaE: paletteSnapDeltaE ?? this.paletteSnapDeltaE,
    straightedgeEnabled: straightedgeEnabled ?? this.straightedgeEnabled,
    gridStyle: gridStyle ?? this.gridStyle,
    gridSpacingDpx: gridSpacingDpx ?? this.gridSpacingDpx,
    symmetryMode: symmetryMode ?? this.symmetryMode,
    referenceOpacity: referenceOpacity ?? this.referenceOpacity,
  );

  /// Decodes options written by [toJson].
  factory Wp5ToolOptions.fromJson(Map<String, Object?> json) => Wp5ToolOptions(
    selectionGeometry: _enumByName(
      SelectionGeometry.values,
      json['selectionGeometry'],
      SelectionGeometry.rectangle,
    ),
    selectionCombine: _enumByName(
      SelectionCombine.values,
      json['selectionCombine'],
      SelectionCombine.replace,
    ),
    selectionTolerance: _boundedInt(json['selectionTolerance'], 0, 64, 16),
    selectionGapClose: _boundedInt(json['selectionGapClose'], 0, 4, 0),
    transformAspect: _enumByName(
      TransformAspect.values,
      json['transformAspect'],
      TransformAspect.uniform,
    ),
    fillTolerance: _boundedInt(json['fillTolerance'], 0, 64, 16),
    fillGapClose: _boundedInt(json['fillGapClose'], 0, 4, 0),
    fillGrow: _boundedInt(json['fillGrow'], -4, 4, 0),
    fillSampleSource: _enumByName(
      RasterSampleSource.values,
      json['fillSampleSource'],
      RasterSampleSource.activeLayer,
    ),
    fillStyle: _enumByName(
      FillStyle.values,
      json['fillStyle'],
      FillStyle.solid,
    ),
    dotScreenDensity: _enumByName(
      DotScreenDensity.values,
      json['dotScreenDensity'],
      DotScreenDensity.bayer4,
    ),
    shapeType: _enumByName(ShapeType.values, json['shapeType'], ShapeType.line),
    polygonSides: _boundedInt(json['polygonSides'], 3, 32, 5),
    shapeOrigin: _enumByName(
      ShapeOrigin.values,
      json['shapeOrigin'],
      ShapeOrigin.corner,
    ),
    shapeConstraint: _enumByName(
      ShapeConstraint.values,
      json['shapeConstraint'],
      ShapeConstraint.free,
    ),
    textFont: _enumByName(
      InkTextFont.values,
      json['textFont'],
      InkTextFont.inter,
    ),
    textSize: _boundedDouble(json['textSize'], 16, 96, 32),
    textWeight: _boundedInt(json['textWeight'], 500, 800, 600),
    eyedropperRadiusDpx: _positiveDouble(json['eyedropperRadiusDpx'], 5),
    paletteSnapDeltaE: _nonNegativeDouble(json['paletteSnapDeltaE'], 10),
    straightedgeEnabled: json['straightedgeEnabled'] == true,
    gridStyle: _enumByName(
      GuideGridStyle.values,
      json['gridStyle'],
      GuideGridStyle.off,
    ),
    gridSpacingDpx: switch (json['gridSpacingDpx']) {
      8 || 16 || 32 || 64 => json['gridSpacingDpx']! as int,
      _ => 16,
    },
    symmetryMode: _enumByName(
      InkSymmetryMode.values,
      json['symmetryMode'],
      InkSymmetryMode.off,
    ),
    referenceOpacity: _boundedDouble(json['referenceOpacity'], 0, 1, 0.5),
  );

  /// Encodes options as finite JSON data.
  Map<String, Object?> toJson() => <String, Object?>{
    'selectionGeometry': selectionGeometry.name,
    'selectionCombine': selectionCombine.name,
    'selectionTolerance': selectionTolerance,
    'selectionGapClose': selectionGapClose,
    'transformAspect': transformAspect.name,
    'fillTolerance': fillTolerance,
    'fillGapClose': fillGapClose,
    'fillGrow': fillGrow,
    'fillSampleSource': fillSampleSource.name,
    'fillStyle': fillStyle.name,
    'dotScreenDensity': dotScreenDensity.name,
    'shapeType': shapeType.name,
    'polygonSides': polygonSides,
    'shapeOrigin': shapeOrigin.name,
    'shapeConstraint': shapeConstraint.name,
    'textFont': textFont.name,
    'textSize': textSize,
    'textWeight': textWeight,
    'eyedropperRadiusDpx': eyedropperRadiusDpx,
    'paletteSnapDeltaE': paletteSnapDeltaE,
    'straightedgeEnabled': straightedgeEnabled,
    'gridStyle': gridStyle.name,
    'gridSpacingDpx': gridSpacingDpx,
    'symmetryMode': symmetryMode.name,
    'referenceOpacity': referenceOpacity,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Wp5ToolOptions &&
          listEquals(_equalityValues, other._equalityValues);

  @override
  int get hashCode => Object.hashAll(_equalityValues);

  List<Object?> get _equalityValues => <Object?>[
    selectionGeometry,
    selectionCombine,
    selectionTolerance,
    selectionGapClose,
    transformAspect,
    fillTolerance,
    fillGapClose,
    fillGrow,
    fillSampleSource,
    fillStyle,
    dotScreenDensity,
    shapeType,
    polygonSides,
    shapeOrigin,
    shapeConstraint,
    textFont,
    textSize,
    textWeight,
    eyedropperRadiusDpx,
    paletteSnapDeltaE,
    straightedgeEnabled,
    gridStyle,
    gridSpacingDpx,
    symmetryMode,
    referenceOpacity,
  ];
}

/// Mutable editor-tool state used by Ink's chrome and input routing.
///
/// The persisted portion mirrors [InkToolState]. Session-only input policy,
/// such as finger drawing and temporary pen overrides, deliberately remains
/// outside the document manifest.
final class ToolState extends ChangeNotifier {
  /// Creates tool state from explicit values.
  ToolState({
    String selectedToolId = 'draw',
    String brushId = 'fineliner',
    String color = '#1D3E74',
    double size = 4,
    Map<String, Object?> presets = const <String, Object?>{},
    Wp5ToolOptions wp5Options = const Wp5ToolOptions(),
    Iterable<InkColor> recentColors = const <InkColor>[],
    bool fingerDrawEnabled = false,
  }) : _selectedToolId = _requireId(selectedToolId, 'selectedToolId'),
       _brushId = _requireId(brushId, 'brushId'),
       _color = _requireId(color, 'color'),
       _size = _requireSize(size),
       _presets = _freezePresets(presets),
       // The public parameter intentionally omits the private field prefix.
       // ignore: prefer_initializing_formals
       _wp5Options = wp5Options,
       _recentColors = _normalizeRecentColors(recentColors),
       // The public parameter intentionally omits the private field prefix.
       // ignore: prefer_initializing_formals
       _fingerDrawEnabled = fingerDrawEnabled,
       _unknownFields = const <String, Object?>{};

  ToolState._fromPersisted(InkToolState state, this._fingerDrawEnabled)
    : _selectedToolId = state.toolId,
      _brushId = state.brushId,
      _color = state.color,
      _size = state.size,
      _presets = _freezePresets(state.presets),
      _wp5Options = _wp5OptionsFromUnknown(state.unknownFields),
      _recentColors = _recentColorsFromUnknown(state.unknownFields),
      _unknownFields = state.unknownFields;

  /// Creates mutable tool state from a document manifest value.
  factory ToolState.fromPersisted(
    InkToolState state, {
    bool fingerDrawEnabled = false,
  }) => ToolState._fromPersisted(state, fingerDrawEnabled);

  String _selectedToolId;
  String _brushId;
  String _color;
  double _size;
  Map<String, Object?> _presets;
  Wp5ToolOptions _wp5Options;
  List<InkColor> _recentColors;
  bool _colorHistoryTouched = false;
  bool _fingerDrawEnabled;
  String? _temporaryToolId;
  Map<String, Object?> _unknownFields;
  int _persistentRevision = 0;

  /// The tool explicitly selected on the bench.
  String get selectedToolId => _selectedToolId;

  /// The effective tool after a pen-tail or barrel-button override.
  String get activeToolId => _temporaryToolId ?? _selectedToolId;

  /// The current temporary override, or null when the selected tool is used.
  String? get temporaryToolId => _temporaryToolId;

  /// The stable identifier of the selected brush preset.
  String get brushId => _brushId;

  /// The current manifest color string, normally `#RRGGBB`.
  String get color => _color;

  /// Typed current color, or null for a forward-compatible non-hex value.
  InkColor? get inkColor => InkColor.tryParse(_color);

  /// Most-recent-first color history used by the fixed eight-slot row.
  List<InkColor> get recentColors => _recentColors;

  /// The current brush diameter in document pixels.
  double get size => _size;

  /// Current per-brush flow multiplier used by the bench's sixteen notches.
  double get flow => flowForBrush(_brushId);

  /// Last-used option payloads keyed by brush identifier.
  Map<String, Object?> get presets => _presets;

  /// Returns the stored flow multiplier for [brushId], defaulting to full.
  double flowForBrush(String brushId) {
    final String id = _requireId(brushId, 'brushId');
    final Object? encoded = _presets['wp7Flow:$id'];
    return encoded is num && encoded.isFinite && encoded >= 0 && encoded <= 1
        ? encoded.toDouble()
        : 1;
  }

  /// Typed selection, transform, fill, shape, text, picker, and guide options.
  Wp5ToolOptions get wp5Options => _wp5Options;

  /// Whether a single finger may drive the draw tool for this session.
  bool get fingerDrawEnabled => _fingerDrawEnabled;

  /// Monotonic revision changed only by manifest-persisted tool actions.
  int get persistentRevision => _persistentRevision;

  /// Selects a bench tool and clears any temporary pen override.
  void selectTool(String toolId) {
    final next = _requireId(toolId, 'toolId');
    if (_selectedToolId == next) {
      if (_temporaryToolId == null) {
        return;
      }
      _temporaryToolId = null;
      notifyListeners();
      return;
    }
    _selectedToolId = next;
    _temporaryToolId = null;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Selects a brush, optionally changing its current size in the same action.
  void selectBrush(String brushId, {double? size}) {
    final nextBrush = _requireId(brushId, 'brushId');
    final nextSize = size == null ? _size : _requireSize(size);
    if (_brushId == nextBrush && _size == nextSize) {
      return;
    }
    final Map<String, Object?> nextPresets = Map<String, Object?>.of(_presets)
      ..['wp7Size:$_brushId'] = _size
      ..['wp7Size:$nextBrush'] = nextSize;
    _presets = _freezePresets(nextPresets);
    _brushId = nextBrush;
    _size = nextSize;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Changes the current manifest color.
  void setColor(String color) {
    final next = _requireId(color, 'color');
    if (_color == next) {
      return;
    }
    _color = next;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Selects a typed color and remembers it in the eight-slot recent row.
  ///
  /// The color and history advance the persistent revision atomically. The
  /// legacy [setColor] API intentionally keeps its WP0–WP5 behavior and does
  /// not infer color-history policy.
  void selectInkColor(InkColor color, {bool remember = true}) {
    final List<InkColor> nextRecents = remember
        ? _normalizeRecentColors(<InkColor>[color, ..._recentColors])
        : _recentColors;
    final bool historyChanged = !listEquals(_recentColors, nextRecents);
    if (_color == color.hex && !historyChanged) {
      return;
    }
    _color = color.hex;
    _recentColors = nextRecents;
    _colorHistoryTouched = _colorHistoryTouched || historyChanged;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Clears only the persisted recent-color row.
  void clearRecentColors() {
    if (_recentColors.isEmpty) {
      return;
    }
    _recentColors = const <InkColor>[];
    _colorHistoryTouched = true;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Changes the current brush diameter in document pixels.
  void setSize(double size) {
    final next = _requireSize(size);
    if (_size == next) {
      return;
    }
    _size = next;
    _presets = _freezePresets(
      Map<String, Object?>.of(_presets)..['wp7Size:$_brushId'] = next,
    );
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Returns the last stored size for [brushId], or [fallback].
  double sizeForBrush(String brushId, {required double fallback}) {
    final String id = _requireId(brushId, 'brushId');
    final double checkedFallback = _requireSize(fallback);
    if (id == _brushId) {
      return _size;
    }
    final Object? encoded = _presets['wp7Size:$id'];
    return encoded is num && encoded.isFinite && encoded > 0
        ? encoded.toDouble()
        : checkedFallback;
  }

  /// Stores the current brush's normalized flow multiplier.
  void setFlow(double flow) {
    if (!flow.isFinite || flow < 0 || flow > 1) {
      throw RangeError.range(flow, 0, 1, 'flow');
    }
    if (this.flow == flow) {
      return;
    }
    final Map<String, Object?> next = Map<String, Object?>.of(_presets)
      ..['wp7Flow:$_brushId'] = flow;
    _presets = _freezePresets(next);
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Stores one last-used brush option payload.
  void setBrushPreset(String brushId, Object? value) {
    final key = _requireId(brushId, 'brushId');
    final next = Map<String, Object?>.of(_presets)
      ..[key] = _freezeToolJson(value);
    _presets = _freezePresets(next);
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Removes a stored brush option payload.
  void removeBrushPreset(String brushId) {
    final key = _requireId(brushId, 'brushId');
    if (!_presets.containsKey(key)) {
      return;
    }
    final next = Map<String, Object?>.of(_presets)..remove(key);
    _presets = _freezePresets(next);
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Replaces the typed WP5 interaction options as one atomic editor action.
  void setWp5Options(Wp5ToolOptions options) {
    if (_wp5Options == options) {
      return;
    }
    _wp5Options = options;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Enables or disables session-only single-finger drawing.
  void setFingerDrawEnabled(bool enabled) {
    if (_fingerDrawEnabled == enabled) {
      return;
    }
    _fingerDrawEnabled = enabled;
    notifyListeners();
  }

  /// Applies or clears a temporary tool override from pen metadata.
  void setTemporaryTool(String? toolId) {
    final next = toolId == null ? null : _requireId(toolId, 'toolId');
    if (_temporaryToolId == next) {
      return;
    }
    _temporaryToolId = next;
    notifyListeners();
  }

  /// Replaces the persisted portion while retaining session-only settings.
  void restorePersisted(InkToolState state) {
    _selectedToolId = state.toolId;
    _brushId = state.brushId;
    _color = state.color;
    _size = state.size;
    _presets = _freezePresets(state.presets);
    _wp5Options = _wp5OptionsFromUnknown(state.unknownFields);
    _recentColors = _recentColorsFromUnknown(state.unknownFields);
    _colorHistoryTouched = false;
    _unknownFields = state.unknownFields;
    _temporaryToolId = null;
    _persistentRevision += 1;
    notifyListeners();
  }

  /// Returns the manifest representation of the current persistent values.
  InkToolState toPersisted() => InkToolState(
    toolId: _selectedToolId,
    brushId: _brushId,
    color: _color,
    size: _size,
    presets: _presets,
    unknownFields: <String, Object?>{
      ..._unknownFields,
      'wp5Options': _wp5Options.toJson(),
      if (_recentColors.isNotEmpty || _colorHistoryTouched)
        'wp6Color': _wp6ColorToPersisted(
          _unknownFields['wp6Color'],
          _recentColors,
        ),
    },
  );
}

Map<String, Object?> _wp6ColorToPersisted(
  Object? original,
  List<InkColor> recents,
) {
  final Map<String, Object?> result = <String, Object?>{};
  if (original is Map<Object?, Object?>) {
    for (final MapEntry<Object?, Object?> entry in original.entries) {
      final Object? key = entry.key;
      if (key is String && key != 'recents') {
        result[key] = entry.value;
      }
    }
  }
  result['recents'] = <String>[for (final InkColor color in recents) color.hex];
  return result;
}

List<InkColor> _recentColorsFromUnknown(Map<String, Object?> unknownFields) {
  final Object? value = unknownFields['wp6Color'];
  if (value is! Map<Object?, Object?>) {
    return const <InkColor>[];
  }
  final Object? recents = value['recents'];
  if (recents is! List<Object?>) {
    return const <InkColor>[];
  }
  final List<InkColor> parsed = <InkColor>[];
  for (final Object? encoded in recents) {
    if (encoded is! String) {
      continue;
    }
    final InkColor? color = InkColor.tryParse(encoded);
    if (color != null) {
      parsed.add(color);
    }
  }
  return _normalizeRecentColors(parsed);
}

List<InkColor> _normalizeRecentColors(Iterable<InkColor> source) {
  final List<InkColor> result = <InkColor>[];
  final Set<int> seenArgb = <int>{};
  for (final InkColor color in source) {
    if (!seenArgb.add(color.argb)) {
      continue;
    }
    result.add(color);
    if (result.length == maxInkRecentColors) {
      break;
    }
  }
  return List<InkColor>.unmodifiable(result);
}

Wp5ToolOptions _wp5OptionsFromUnknown(Map<String, Object?> unknownFields) {
  final Object? value = unknownFields['wp5Options'];
  if (value is! Map<Object?, Object?>) {
    return const Wp5ToolOptions();
  }
  final Map<String, Object?> json = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is String) {
      json[key] = entry.value;
    }
  }
  return Wp5ToolOptions.fromJson(json);
}

T _enumByName<T extends Enum>(List<T> values, Object? encoded, T fallback) {
  if (encoded is String) {
    for (final T value in values) {
      if (value.name == encoded) {
        return value;
      }
    }
  }
  return fallback;
}

int _boundedInt(Object? value, int minimum, int maximum, int fallback) =>
    value is int && value >= minimum && value <= maximum ? value : fallback;

double _boundedDouble(
  Object? value,
  double minimum,
  double maximum,
  double fallback,
) {
  if (value is num && value.isFinite && value >= minimum && value <= maximum) {
    return value.toDouble();
  }
  return fallback;
}

double _positiveDouble(Object? value, double fallback) =>
    value is num && value.isFinite && value > 0 ? value.toDouble() : fallback;

double _nonNegativeDouble(Object? value, double fallback) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : fallback;

String _requireId(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return value;
}

double _requireSize(double value) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, 'size', 'must be finite and positive');
  }
  return value;
}

Map<String, Object?> _freezePresets(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final MapEntry<String, Object?> entry in source.entries)
        entry.key: _freezeToolJson(entry.value),
    });

Object? _freezeToolJson(Object? value) => switch (value) {
  null || bool() || String() => value,
  final num number when number.isFinite => number,
  final List<Object?> list => List<Object?>.unmodifiable(
    list.map<Object?>(_freezeToolJson),
  ),
  final Map<Object?, Object?> map => _freezeToolMap(map),
  _ => throw ArgumentError.value(
    value,
    'preset value',
    'must be finite JSON data with string map keys',
  ),
};

Map<String, Object?> _freezeToolMap(Map<Object?, Object?> source) {
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in source.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw ArgumentError.value(key, 'preset map key', 'must be a string');
    }
    result[key] = _freezeToolJson(entry.value);
  }
  return Map<String, Object?>.unmodifiable(result);
}
