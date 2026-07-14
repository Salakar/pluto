import 'package:flutter/foundation.dart';

import '../document/document.dart';
import '../document/tile_store.dart';
import '../document/undo_journal.dart';
import '../engine/canvas_ops.dart';
import '../tools/tool.dart' show ToolActionBlockReason;
import 'tool_state.dart';

/// Maximum number of content layers in one Ink artwork.
const int maxInkContentLayers = 12;

/// Binding lifetime of a locked/hidden-layer feedback chip.
const Duration inkLayerActionChipDuration = Duration(milliseconds: 800);

/// Supported, typed content-layer blend choices.
enum InkLayerBlendMode {
  /// Standard source-over compositing.
  normal,

  /// Source color multiplies the accumulated destination.
  multiply,
}

/// Immutable metadata for one non-silent refused layer action.
final class LayerActionChip {
  /// Creates canonical feedback shown from [shownAtMilliseconds].
  const LayerActionChip({
    required this.reason,
    required this.shownAtMilliseconds,
  });

  /// Why the layer-local action was refused.
  final ToolActionBlockReason reason;

  /// Monotonic or wall-clock timestamp supplied by the editor host.
  final int shownAtMilliseconds;

  /// Canonical status-chip copy.
  String get message => switch (reason) {
    ToolActionBlockReason.layerLocked => 'layer locked',
    ToolActionBlockReason.layerHidden => 'layer hidden',
  };

  /// Static lifetime required by the interaction specification.
  Duration get duration => inkLayerActionChipDuration;

  /// Timestamp at which the chip is no longer visible.
  int get expiresAtMilliseconds =>
      shownAtMilliseconds + inkLayerActionChipDuration.inMilliseconds;

  /// Whether the chip is visible at [milliseconds].
  bool isVisibleAt(int milliseconds) =>
      milliseconds >= shownAtMilliseconds &&
      milliseconds < expiresAtMilliseconds;
}

/// The editor's single-raster-commit state.
enum CommitPhase {
  /// No raster commit is in flight.
  idle,

  /// The worker is compositing a completed action into document tiles.
  compositing,
}

/// Mutually exclusive editor sheets anchored to the temporary or final bench.
enum EditorPanel {
  /// Brush selection and brush-specific options.
  brush,

  /// Color selection and recent colors.
  color,

  /// Content and reference layer controls.
  layers,

  /// Artwork export controls.
  export,

  /// Less-frequent editor and canvas actions.
  menu,
}

/// Chrome-facing state for one open Ink artwork.
///
/// Raster pixels remain in [tiles], undo truth remains in [journal], and
/// stroke-time canvas repaints are owned by the engine rather than this
/// notifier.
final class EditorModel extends ChangeNotifier {
  /// Creates state for one loaded artwork.
  EditorModel({
    required InkDocument document,
    required this.tiles,
    required this.journal,
    ToolState? toolState,
    int Function()? nowMilliseconds,
  }) : _document = document,
       _viewState = document.view,
       toolState = toolState ?? ToolState.fromPersisted(document.tool),
       _ownsToolState = toolState == null,
       _nowMilliseconds = nowMilliseconds ?? _systemNowMilliseconds {
    _lastToolPersistentRevision = this.toolState.persistentRevision;
    this.toolState.addListener(_handleToolStateChanged);
  }

  InkDocument _document;
  InkViewState _viewState;
  CommitPhase _commitPhase = CommitPhase.idle;
  EditorPanel? _openPanel;
  bool _chromeVisible = true;
  bool _benchCollapsed = false;
  bool _dirty = false;
  final bool _ownsToolState;
  final int Function() _nowMilliseconds;
  late int _lastToolPersistentRevision;
  LayerActionChip? _lastLayerActionChip;

  /// Mutable raster truth for this artwork.
  final TileStore tiles;

  /// Persisted undo and redo history for this artwork.
  final UndoJournal journal;

  /// Current tool, brush, color, and session input settings.
  final ToolState toolState;

  /// The latest immutable document metadata published by an editor action.
  InkDocument get document => _document;

  /// Content layers in bottom-to-top compositing order.
  List<InkLayer> get contentLayers => _document.layers;

  /// Currently selected content layer.
  InkLayer get activeLayer => _document.layers.firstWhere(
    (InkLayer layer) => layer.id == _document.activeLayerId,
  );

  /// Zero-based active-layer position in bottom-to-top order.
  int get activeLayerIndex => _document.layers.indexWhere(
    (InkLayer layer) => layer.id == _document.activeLayerId,
  );

  /// One-based active-layer ordinal suitable for chrome labels.
  int get activeLayerOrdinal => activeLayerIndex + 1;

  /// Whether another content layer may be added below the binding cap.
  bool get canAddContentLayer => _document.layers.length < maxInkContentLayers;

  /// Typed blend mode of the active layer, or null for a future blend id.
  InkLayerBlendMode? get activeLayerBlendMode => switch (activeLayer.blend) {
    'normal' => InkLayerBlendMode.normal,
    'multiply' => InkLayerBlendMode.multiply,
    _ => null,
  };

  /// Most recently emitted layer-action chip, including an expired one.
  LayerActionChip? get lastLayerActionChip => _lastLayerActionChip;

  /// Current locked/hidden feedback, or null after its 800 ms lifetime.
  LayerActionChip? get layerActionChip {
    final LayerActionChip? chip = _lastLayerActionChip;
    if (chip == null || !chip.isVisibleAt(_nowMilliseconds())) {
      return null;
    }
    return chip;
  }

  /// The settled view transform persisted when the artwork is saved.
  InkViewState get viewState => _viewState;

  /// Current single-commit state.
  CommitPhase get commitPhase => _commitPhase;

  /// Whether a raster commit is currently in flight.
  bool get isCompositing => _commitPhase == CommitPhase.compositing;

  /// The one open editor sheet, or null when every sheet is closed.
  EditorPanel? get openPanel => _openPanel;

  /// Whether editor chrome is visible over the full-bleed canvas.
  bool get chromeVisible => _chromeVisible;

  /// Whether the bench itself is folded down to its grip tab.
  bool get benchCollapsed => _benchCollapsed;

  /// Whether session state differs from the last acknowledged save.
  bool get dirty => _dirty;

  /// Builds a save-ready manifest snapshot from current editor state.
  InkDocument get documentSnapshot => _document.copyWith(
    view: _viewState,
    tool: toolState.toPersisted(),
    journalHeadSeq: journal.headSeq,
  );

  /// Renames the open artwork as one manifest-facing chrome action.
  void renameArtwork(String name) {
    final String next = name.trim();
    if (next.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be blank');
    }
    if (_document.name == next) {
      return;
    }
    _document = _document.copyWith(
      name: next,
      modifiedAtMs: _nowMilliseconds(),
    );
    _dirty = true;
    notifyListeners();
  }

  /// Selects one content layer without mutating its pixels or properties.
  void selectActiveLayer(String layerId) {
    if (!_document.layers.any((InkLayer layer) => layer.id == layerId)) {
      throw ArgumentError.value(
        layerId,
        'layerId',
        'must identify a content layer',
      );
    }
    if (_document.activeLayerId == layerId) {
      return;
    }
    _document = _document.copyWith(activeLayerId: layerId);
    _dirty = true;
    notifyListeners();
  }

  /// Commits and publishes one WP6 engine transition without replacing the
  /// [TileStore] object already observed by the canvas.
  ///
  /// The journal append is flushed before raster truth is published. This is
  /// the shared integration path for layer controls and canvas operations.
  Future<void> applyEngineOperation(
    JournaledEngineOperation operation, {
    String? activeLayerId,
  }) async {
    if (_commitPhase != CommitPhase.idle) {
      throw StateError('A raster commit is already in flight.');
    }
    _commitPhase = CommitPhase.compositing;
    notifyListeners();
    try {
      await journal.commit(operation.entry);
      final List<InkLayer> layers = operation.state.layers;
      _replaceTiles(operation.state.tiles, layers);
      final String resolvedActive = _resolvedActiveLayerId(
        layers,
        requested: activeLayerId,
      );
      _document = _document.copyWith(
        canvas: operation.state.canvas,
        layers: layers,
        activeLayerId: resolvedActive,
        modifiedAtMs: _nowMilliseconds(),
        journalHeadSeq: journal.headSeq,
      );
      _commitPhase = CommitPhase.idle;
      _dirty = true;
      notifyListeners();
    } on Object {
      _commitPhase = CommitPhase.idle;
      notifyListeners();
      rethrow;
    }
  }

  /// Records a settled engine view transform.
  ///
  /// Gesture-frame transforms stay engine-local; callers invoke this once
  /// when navigation settles.
  void setViewState(InkViewState viewState) {
    if (_sameView(_viewState, viewState)) {
      return;
    }
    _viewState = viewState;
    _dirty = true;
    notifyListeners();
  }

  /// Publishes immutable metadata produced by a non-commit editor action.
  void publishDocument(InkDocument document, {bool markDirty = true}) {
    _requireSameDocument(document);
    _document = document;
    if (markDirty) {
      _dirty = true;
    }
    notifyListeners();
  }

  /// Runs a layer-local action only when its target is visible and unlocked.
  ///
  /// Hidden takes precedence over locked, matching the interaction-tool gate.
  /// A refusal never invokes [action] and emits a canonical 800 ms chip. The
  /// lock bypass is reserved for reference placement transforms; visibility
  /// is never bypassed.
  bool runLayerAction({
    required VoidCallback action,
    String? layerId,
    bool bypassLock = false,
  }) {
    final InkLayer layer = layerId == null
        ? activeLayer
        : _document.layers.firstWhere(
            (InkLayer candidate) => candidate.id == layerId,
            orElse: () => throw ArgumentError.value(
              layerId,
              'layerId',
              'must identify a content layer',
            ),
          );
    final ToolActionBlockReason? reason = !layer.visible
        ? ToolActionBlockReason.layerHidden
        : layer.locked && !bypassLock
        ? ToolActionBlockReason.layerLocked
        : null;
    if (reason != null) {
      _lastLayerActionChip = LayerActionChip(
        reason: reason,
        shownAtMilliseconds: _nowMilliseconds(),
      );
      notifyListeners();
      return false;
    }
    action();
    return true;
  }

  /// Dismisses locked/hidden feedback before its natural expiry.
  void dismissLayerActionChip() {
    if (_lastLayerActionChip == null) {
      return;
    }
    _lastLayerActionChip = null;
    notifyListeners();
  }

  /// Opens one sheet, closing any previously open sheet in the same action.
  void showPanel(EditorPanel panel) {
    if (_openPanel == panel) {
      return;
    }
    _openPanel = panel;
    notifyListeners();
  }

  /// Closes the current editor sheet.
  void closePanel() {
    if (_openPanel == null) {
      return;
    }
    _openPanel = null;
    notifyListeners();
  }

  /// Shows or hides all editor chrome without affecting canvas state.
  void setChromeVisible(bool visible) {
    if (_chromeVisible == visible) {
      return;
    }
    _chromeVisible = visible;
    notifyListeners();
  }

  /// Toggles the four-finger collapse state for all editor chrome.
  void toggleChrome() {
    _chromeVisible = !_chromeVisible;
    notifyListeners();
  }

  /// Folds or unfolds the bench while leaving other chrome visible.
  void setBenchCollapsed(bool collapsed) {
    if (_benchCollapsed == collapsed) {
      return;
    }
    _benchCollapsed = collapsed;
    notifyListeners();
  }

  /// Begins the one allowed in-flight raster commit.
  void beginCommit() {
    if (_commitPhase != CommitPhase.idle) {
      throw StateError('A raster commit is already in flight.');
    }
    _commitPhase = CommitPhase.compositing;
    notifyListeners();
  }

  /// Completes the active raster commit and optionally publishes metadata.
  void finishCommit({InkDocument? document}) {
    if (_commitPhase != CommitPhase.compositing) {
      throw StateError('No raster commit is in flight.');
    }
    if (document != null) {
      _requireSameDocument(document);
      _document = document;
    }
    _commitPhase = CommitPhase.idle;
    _dirty = true;
    notifyListeners();
  }

  /// Returns to idle after a failed or abandoned raster commit.
  void abandonCommit() {
    if (_commitPhase != CommitPhase.compositing) {
      return;
    }
    _commitPhase = CommitPhase.idle;
    notifyListeners();
  }

  /// Acknowledges a successfully persisted manifest.
  void markSaved(InkDocument persistedDocument) {
    _requireSameDocument(persistedDocument);
    _document = persistedDocument;
    _viewState = persistedDocument.view;
    _dirty = false;
    notifyListeners();
  }

  void _handleToolStateChanged() {
    final int revision = toolState.persistentRevision;
    if (revision == _lastToolPersistentRevision) {
      return;
    }
    _lastToolPersistentRevision = revision;
    _dirty = true;
    notifyListeners();
  }

  void _requireSameDocument(InkDocument candidate) {
    if (candidate.id != _document.id) {
      throw ArgumentError.value(
        candidate.id,
        'document',
        'must keep the open artwork id ${_document.id}',
      );
    }
  }

  void _replaceTiles(TileStore source, Iterable<InkLayer> layers) {
    tiles.clear();
    for (final TileLocation location in source.locations) {
      tiles.publish(
        location.layerId,
        location.key,
        source.tile(location.layerId, location.key),
      );
    }
    for (final InkLayer layer in layers) {
      tiles.ensureLayer(layer.id);
    }
  }

  String _resolvedActiveLayerId(List<InkLayer> layers, {String? requested}) {
    if (layers.isEmpty) {
      throw StateError('An editor operation removed every content layer.');
    }
    final String candidate = requested ?? _document.activeLayerId;
    return layers.any((InkLayer layer) => layer.id == candidate)
        ? candidate
        : layers.last.id;
  }

  @override
  void dispose() {
    toolState.removeListener(_handleToolStateChanged);
    if (_ownsToolState) {
      toolState.dispose();
    }
    super.dispose();
  }
}

bool _sameView(InkViewState left, InkViewState right) =>
    left.tx == right.tx &&
    left.ty == right.ty &&
    left.scale == right.scale &&
    left.rotationDeg == right.rotationDeg;

int _systemNowMilliseconds() => DateTime.now().millisecondsSinceEpoch;
