import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Current persisted settings schema.
const int inkSettingsSchema = 1;

/// Global default edge used by the editor bench.
enum BenchDockPreference {
  /// Dock the vertical bench to the left edge.
  left,

  /// Dock the vertical bench to the right edge.
  right,

  /// Reflow the bench into a horizontal strip below the status band.
  top,
}

/// Eraser interaction selected for newly opened artworks.
enum EraserDefaultPreference {
  /// Stamp destination-out pixels.
  pixel,

  /// Remove replayable strokes as complete journal actions.
  stroke,

  /// Clear a closed freehand region.
  lasso,
}

/// Default non-exporting grid mark.
enum GridStylePreference {
  /// Draw continuous grid rules.
  line,

  /// Draw intersections as dots.
  dot,
}

/// Global pressure response applied before brush-local pressure maps.
enum PressureCurvePreference {
  /// Reaches useful pressure sooner for a light hand.
  soft,

  /// Preserves the device's normalized pressure.
  normal,

  /// Requires a firmer hand to reach the same response.
  firm;

  /// Maps a device pressure into the normalized global brush response.
  double mapPressure(double pressure) {
    final double normalized = pressure.clamp(0.0, 1.0);
    return switch (this) {
      PressureCurvePreference.soft => math.pow(normalized, 0.65).toDouble(),
      PressureCurvePreference.normal => normalized,
      PressureCurvePreference.firm => math.pow(normalized, 1.55).toDouble(),
    };
  }
}

/// Decodes the editor preset used by live strokes, defaulting to linear.
PressureCurvePreference pressureCurveFromPreset(Object? value) =>
    switch (value) {
      'soft' => PressureCurvePreference.soft,
      'firm' => PressureCurvePreference.firm,
      _ => PressureCurvePreference.normal,
    };

/// Maps a live input sample using the editor preset consumed by the canvas.
double mapPressureFromPreset(
  Object? preset,
  double? pressure, {
  double fallback = 0.6,
}) => pressureCurveFromPreset(preset).mapPressure(pressure ?? fallback);

/// Immutable, schema-versioned settings stored in `state/settings.json`.
final class InkSettings {
  /// Creates a validated settings snapshot.
  InkSettings({
    this.fingerDrawing = false,
    this.benchDock = BenchDockPreference.left,
    this.eraserDefault = EraserDefaultPreference.pixel,
    this.gridEnabled = false,
    this.gridStyle = GridStylePreference.line,
    this.gridSpacing = 16,
    this.pressureCurve = PressureCurvePreference.normal,
    Map<String, Object?> unknownFields = const <String, Object?>{},
  }) : unknownFields = Map<String, Object?>.unmodifiable(unknownFields) {
    if (!inkGridSpacings.contains(gridSpacing)) {
      throw ArgumentError.value(
        gridSpacing,
        'gridSpacing',
        'must be one of $inkGridSpacings',
      );
    }
  }

  /// Supported square-grid spacings in document pixels.
  static const List<int> inkGridSpacings = <int>[8, 16, 32, 64];

  /// Whether finger contacts may draw when no pen is in proximity.
  final bool fingerDrawing;

  /// Preferred global bench edge.
  final BenchDockPreference benchDock;

  /// Eraser mode selected for a fresh editor session.
  final EraserDefaultPreference eraserDefault;

  /// Whether new editor sessions show the guide grid.
  final bool gridEnabled;

  /// Line or dot rendering for the guide grid.
  final GridStylePreference gridStyle;

  /// Square-grid spacing in document pixels.
  final int gridSpacing;

  /// Global pressure response.
  final PressureCurvePreference pressureCurve;

  /// Forward-compatible fields retained across a read/write cycle.
  final Map<String, Object?> unknownFields;

  /// Decodes a settings payload, rejecting malformed known fields.
  factory InkSettings.fromJson(Map<String, Object?> json) {
    if (json['schema'] != inkSettingsSchema) {
      throw const FormatException('Unsupported Ink settings schema');
    }
    const Set<String> known = <String>{
      'schema',
      'fingerDrawing',
      'benchDock',
      'eraserDefault',
      'gridEnabled',
      'gridStyle',
      'gridSpacing',
      'pressureCurve',
    };
    final Object? fingerDrawing = json['fingerDrawing'];
    final Object? gridEnabled = json['gridEnabled'];
    final Object? gridSpacing = json['gridSpacing'];
    if (fingerDrawing is! bool || gridEnabled is! bool || gridSpacing is! int) {
      throw const FormatException('Invalid Ink settings value');
    }
    try {
      return InkSettings(
        fingerDrawing: fingerDrawing,
        benchDock: BenchDockPreference.values.byName(
          _requiredString(json, 'benchDock'),
        ),
        eraserDefault: EraserDefaultPreference.values.byName(
          _requiredString(json, 'eraserDefault'),
        ),
        gridEnabled: gridEnabled,
        gridStyle: GridStylePreference.values.byName(
          _requiredString(json, 'gridStyle'),
        ),
        gridSpacing: gridSpacing,
        pressureCurve: PressureCurvePreference.values.byName(
          _requiredString(json, 'pressureCurve'),
        ),
        unknownFields: <String, Object?>{
          for (final MapEntry<String, Object?> entry in json.entries)
            if (!known.contains(entry.key)) entry.key: entry.value,
        },
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Ink settings value', error);
    }
  }

  /// Encodes this snapshot while retaining unknown fields.
  Map<String, Object?> toJson() => <String, Object?>{
    ...unknownFields,
    'schema': inkSettingsSchema,
    'fingerDrawing': fingerDrawing,
    'benchDock': benchDock.name,
    'eraserDefault': eraserDefault.name,
    'gridEnabled': gridEnabled,
    'gridStyle': gridStyle.name,
    'gridSpacing': gridSpacing,
    'pressureCurve': pressureCurve.name,
  };

  /// Returns a snapshot with selected values replaced.
  InkSettings copyWith({
    bool? fingerDrawing,
    BenchDockPreference? benchDock,
    EraserDefaultPreference? eraserDefault,
    bool? gridEnabled,
    GridStylePreference? gridStyle,
    int? gridSpacing,
    PressureCurvePreference? pressureCurve,
  }) => InkSettings(
    fingerDrawing: fingerDrawing ?? this.fingerDrawing,
    benchDock: benchDock ?? this.benchDock,
    eraserDefault: eraserDefault ?? this.eraserDefault,
    gridEnabled: gridEnabled ?? this.gridEnabled,
    gridStyle: gridStyle ?? this.gridStyle,
    gridSpacing: gridSpacing ?? this.gridSpacing,
    pressureCurve: pressureCurve ?? this.pressureCurve,
    unknownFields: unknownFields,
  );
}

String _requiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String) {
    throw FormatException('$key must be a string');
  }
  return value;
}

/// Persistence seam used by [InkSettingsModel].
abstract interface class InkSettingsStore {
  /// Loads the current settings or defaults when no state has been written.
  Future<InkSettings> load();

  /// Atomically stores one complete settings snapshot.
  Future<void> save(InkSettings settings);
}

/// Atomic JSON-file implementation rooted at Ink's documents directory.
final class JsonFileInkSettingsStore implements InkSettingsStore {
  /// Creates a store for `<documents>/state/settings.json`.
  JsonFileInkSettingsStore({required Directory documentsRoot})
    : _file = File('${documentsRoot.path}/state/settings.json');

  final File _file;

  /// Exact settings file used by this adapter.
  File get file => _file;

  @override
  Future<InkSettings> load() async {
    if (!_file.existsSync()) {
      return InkSettings();
    }
    try {
      final String source = await _file.readAsString();
      final Object? decoded = jsonDecode(source);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Ink settings must be a JSON object');
      }
      return InkSettings.fromJson(decoded);
    } on Object {
      await _quarantineBrokenFile();
      return InkSettings();
    }
  }

  @override
  Future<void> save(InkSettings settings) async {
    await _file.parent.create(recursive: true);
    final File temporary = File('${_file.path}.tmp');
    final RandomAccessFile handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeString(jsonEncode(settings.toJson()));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(_file.path);
  }

  Future<void> _quarantineBrokenFile() async {
    if (!_file.existsSync()) {
      return;
    }
    final String suffix = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      await _file.rename('${_file.path}.corrupt-$suffix');
    } on Object {
      // A bad settings file never prevents the app from opening with defaults.
    }
  }
}

/// Settings loading state shown by the settings surface.
enum InkSettingsPhase {
  /// No load has been requested.
  uninitialized,

  /// A settings read is active.
  loading,

  /// Settings are ready for editing.
  ready,
}

/// Chrome-facing settings owner with recoverable persistence failures.
final class InkSettingsModel extends ChangeNotifier {
  /// Creates a settings owner backed by [store].
  InkSettingsModel({required this.store, InkSettings? initial})
    : _settings = initial ?? InkSettings(),
      _phase = initial == null
          ? InkSettingsPhase.uninitialized
          : InkSettingsPhase.ready;

  /// Injected persistence adapter.
  final InkSettingsStore store;
  InkSettings _settings;
  InkSettingsPhase _phase;
  String? _persistenceMessage;
  Future<void> _saveGate = Future<void>.value();
  int _settingsRevision = 0;

  /// Current immutable settings.
  InkSettings get settings => _settings;

  /// Current loading phase.
  InkSettingsPhase get phase => _phase;

  /// Recoverable persistence feedback, or null after a successful write.
  String? get persistenceMessage => _persistenceMessage;

  /// Loads settings before the settings page is presented.
  Future<void> load() async {
    if (_phase == InkSettingsPhase.loading) {
      return;
    }
    _phase = InkSettingsPhase.loading;
    _persistenceMessage = null;
    notifyListeners();
    try {
      _settings = await store.load();
      _phase = InkSettingsPhase.ready;
    } on Object {
      _settings = InkSettings();
      _phase = InkSettingsPhase.ready;
      _persistenceMessage = 'settings reset to defaults';
    }
    notifyListeners();
  }

  /// Enables or disables finger drawing and persists the preference.
  Future<void> setFingerDrawing(bool enabled) =>
      _replace(_settings.copyWith(fingerDrawing: enabled));

  /// Changes the global bench edge and persists it.
  Future<void> setBenchDock(BenchDockPreference dock) =>
      _replace(_settings.copyWith(benchDock: dock));

  /// Changes the default eraser interaction and persists it.
  Future<void> setEraserDefault(EraserDefaultPreference mode) =>
      _replace(_settings.copyWith(eraserDefault: mode));

  /// Changes whether new editor sessions show a grid.
  Future<void> setGridEnabled(bool enabled) =>
      _replace(_settings.copyWith(gridEnabled: enabled));

  /// Changes the default grid mark.
  Future<void> setGridStyle(GridStylePreference style) =>
      _replace(_settings.copyWith(gridStyle: style));

  /// Changes the default square-grid spacing.
  Future<void> setGridSpacing(int spacing) =>
      _replace(_settings.copyWith(gridSpacing: spacing));

  /// Changes the global pressure response.
  Future<void> setPressureCurve(PressureCurvePreference curve) =>
      _replace(_settings.copyWith(pressureCurve: curve));

  /// Dismisses recoverable persistence feedback.
  void dismissPersistenceMessage() {
    if (_persistenceMessage == null) {
      return;
    }
    _persistenceMessage = null;
    notifyListeners();
  }

  Future<void> _replace(InkSettings next) async {
    if (_sameSettings(_settings, next)) {
      return;
    }
    _settings = next;
    _phase = InkSettingsPhase.ready;
    _persistenceMessage = null;
    final int revision = ++_settingsRevision;
    notifyListeners();
    final Future<void> save = _saveGate.then((_) => store.save(next));
    _saveGate = save.onError((Object _, StackTrace _) {});
    try {
      await save;
    } on Object {
      if (revision != _settingsRevision) {
        return;
      }
      _persistenceMessage = 'could not save settings — will retry';
      notifyListeners();
    }
  }
}

bool _sameSettings(InkSettings left, InkSettings right) =>
    left.fingerDrawing == right.fingerDrawing &&
    left.benchDock == right.benchDock &&
    left.eraserDefault == right.eraserDefault &&
    left.gridEnabled == right.gridEnabled &&
    left.gridStyle == right.gridStyle &&
    left.gridSpacing == right.gridSpacing &&
    left.pressureCurve == right.pressureCurve;
