import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../document/document.dart';
import '../document/tile_store.dart';
import '../document/undo_journal.dart';
import '../engine/brush_engine.dart';
import '../engine/brush_presets.dart';
import '../engine/brush_tool_hooks.dart';
import '../engine/canvas_ops.dart';
import '../engine/canvas_controller.dart';
import '../engine/compositor.dart';
import '../engine/geometry.dart';
import '../engine/raster_ops.dart' as raster;
import '../engine/raster_worker.dart';
import '../engine/stroke_pipeline.dart';
import '../engine/symmetry.dart';
import '../engine/transform_resampler.dart' as resampler;
import '../input/palm_guard.dart';
import '../input/pen_router.dart';
import '../model/editor_model.dart';
import '../model/settings_model.dart';
import '../model/tool_state.dart';
import '../services.dart';
import '../tools/crop_tool.dart';
import '../tools/eraser_tool.dart';
import '../tools/eyedropper_tool.dart';
import '../tools/fill_tool.dart';
import '../tools/selection_tool.dart';
import '../tools/shape_tool.dart';
import '../tools/text_tool.dart';
import '../tools/tool_engine_adapter.dart';
import '../tools/transform_tool.dart';
import 'dock/tool_overlays.dart';
import 'text_input_sheet.dart';

/// RepaintBoundary isolating canvas damage from temporary editor chrome.
const Key inkCanvasBoundaryKey = Key('ink-canvas-boundary');

/// CustomPaint hosting cached tiles and the active stroke overlay.
const Key inkCanvasPaintKey = Key('ink-canvas-paint');

/// Minimum viewport hit target used by transform, crop, and text handles.
const double contextualToolHitTargetDesignPx = 80;

/// One successful history action surfaced by the editor's undo-toast slot.
final class CanvasHistoryFeedback {
  /// Creates feedback for [kind] in the undo or redo direction.
  const CanvasHistoryFeedback({required this.isRedo, required this.kind});

  /// Whether this was a redo rather than an undo.
  final bool isRedo;

  /// Durable action kind that changed the canvas.
  final JournalKind kind;

  /// Canonical short chip copy.
  String get message =>
      '${isRedo ? 'redid' : 'undid'} ${_historyKindLabel(kind)}';
}

/// Imperative contextual-dock operations executed by the live canvas tools.
enum CanvasToolCommand {
  /// Floats the selected pixels, or arms text-block movement.
  move,

  /// Enters the transform controller with the active selection or layer.
  transform,

  /// Creates an offset live copy of selected pixels.
  duplicate,

  /// Mirrors the active float or transform horizontally.
  flipHorizontal,

  /// Mirrors the active float or transform vertically.
  flipVertical,

  /// Copies selected pixels and clears them from the active layer.
  cut,

  /// Copies selected pixels to the session clipboard.
  copy,

  /// Floats the session clipboard at the document viewport center.
  paste,

  /// Clears selected pixels from the active layer.
  clear,

  /// Fills every selected pixel with the current color.
  fill,

  /// Copies selected pixels into a new content layer.
  toNewLayer,

  /// Forces the current shape draft through its perfect-geometry detent.
  perfect,

  /// Rotates the active transform clockwise by fifteen degrees.
  rotateDetent,

  /// Restores the active transform or cancels the crop draft.
  reset,

  /// Commits the active transform or crop.
  apply,

  /// Cycles the editable text size through the binding values.
  textSize,

  /// Cycles the editable text weight through w500–w800.
  textWeight,

  /// Arms corner-handle resizing for the editable text block.
  textResize,

  /// Commits or reopens the most recent editable text block.
  done,

  /// Cancels the active tool draft and returns control to the editor.
  dismiss,
}

/// Testable command seam used by [CanvasViewHandle] before a canvas mounts.
typedef CanvasToolCommandDispatcher =
    Future<void> Function(CanvasToolCommand command);

/// Builds the single structural journal operation represented by [command].
///
/// Arbitrary crop origins are expressed as a top-left clip followed by a
/// bottom-right resize. The intermediate state is never journaled; the final
/// entry retains complete before/after raster snapshots for exact undo and
/// reopen replay.
JournaledEngineOperation buildCropCanvasOperation({
  required CropCommand command,
  required JournalDocumentState state,
  required int sequence,
  required int timestampMs,
}) {
  final Rect artworkBounds = Rect.fromLTWH(
    0,
    0,
    state.canvas.width.toDouble(),
    state.canvas.height.toDouble(),
  );
  if (command.previousBounds != artworkBounds) {
    throw ArgumentError.value(
      command.previousBounds,
      'command.previousBounds',
      'must match the current canvas bounds',
    );
  }
  final int width = command.newBounds.width.round();
  final int height = command.newBounds.height.round();
  if (width == state.canvas.width &&
      height == state.canvas.height &&
      command.newBounds.topLeft == Offset.zero) {
    throw StateError('Crop bounds are unchanged.');
  }
  JournalDocumentState after = state;
  final int right = command.newBounds.right.round();
  final int bottom = command.newBounds.bottom.round();
  if (right != after.canvas.width || bottom != after.canvas.height) {
    after = resizeCanvas(
      state: after,
      width: right,
      height: bottom,
      anchor: CanvasResizeAnchor.topLeft,
      sequence: sequence,
      timestampMs: timestampMs,
    ).state;
  }
  if (width != after.canvas.width || height != after.canvas.height) {
    after = resizeCanvas(
      state: after,
      width: width,
      height: height,
      anchor: CanvasResizeAnchor.bottomRight,
      sequence: sequence,
      timestampMs: timestampMs,
    ).state;
  }
  final JournalEntry entry = JournalEntry(
    seq: sequence,
    timestampMs: timestampMs,
    kind: command.journalKind,
    beforeState: state.structuralJson(),
    afterState: after.structuralJson(),
    beforeLayerTiles: _completeStateRasterSnapshot(state),
    afterLayerTiles: _completeStateRasterSnapshot(after),
    completeLayerSnapshots: true,
  );
  return JournaledEngineOperation(state: after, entry: entry);
}

Map<String, Map<TileKey, Tile?>> _completeStateRasterSnapshot(
  JournalDocumentState state,
) => <String, Map<TileKey, Tile?>>{
  for (final InkLayer layer in state.layers)
    layer.id: <TileKey, Tile?>{
      for (final MapEntry<TileKey, Tile> entry
          in state.tiles.layerTiles(layer.id).entries)
        entry.key: entry.value,
    },
};

/// Creates a snapshot-backed tile journal entry for a committed tool command.
///
/// Selection clear and cut use `erase` without a replayable brush recipe, so
/// those entries are explicitly marked recipe-compacted while retaining their
/// exact before/after tiles for undo, redo, and reopen replay.
JournalEntry buildToolTileJournalEntry({
  required int sequence,
  required int timestampMs,
  required JournalKind kind,
  required String layerId,
  required Rect bounds,
  required Map<TileKey, Tile?> beforeTiles,
  required Map<TileKey, Tile?> afterTiles,
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  if (afterTiles.isEmpty) {
    throw ArgumentError.value(
      afterTiles,
      'afterTiles',
      'must contain at least one changed tile',
    );
  }
  return JournalEntry(
    seq: sequence,
    timestampMs: timestampMs,
    kind: kind,
    layerId: layerId,
    bounds: _journalBounds(bounds),
    recipeCompacted: kind == JournalKind.erase,
    affectedKeys: afterTiles.keys,
    beforeTiles: beforeTiles,
    afterTiles: afterTiles,
    unknownFields: metadata,
  );
}

/// Resolves a valid active layer after one structural journal step.
String resolveCanvasActiveLayerAfterJournalStep({
  required List<InkLayer> layers,
  required String currentActiveLayerId,
  required JournalEntry entry,
  required bool forward,
}) {
  if (layers.isEmpty) {
    throw ArgumentError.value(layers, 'layers', 'must not be empty');
  }
  if (forward &&
      entry.kind == JournalKind.layerAdd &&
      entry.layerId != null &&
      layers.any((InkLayer layer) => layer.id == entry.layerId)) {
    return entry.layerId!;
  }
  if (layers.any((InkLayer layer) => layer.id == currentActiveLayerId)) {
    return currentActiveLayerId;
  }
  final Object? recordedActiveLayerId =
      entry.unknownFields['activeLayerBefore'];
  if (recordedActiveLayerId is String &&
      layers.any((InkLayer layer) => layer.id == recordedActiveLayerId)) {
    return recordedActiveLayerId;
  }
  return layers.last.id;
}

/// Trims zero-coverage borders before a selection becomes a transform target.
SelectionMask trimSelectionMaskForTransform(SelectionMask mask) {
  int? left;
  int? top;
  int? right;
  int? bottom;
  for (var y = mask.top; y < mask.top + mask.height; y += 1) {
    for (var x = mask.left; x < mask.left + mask.width; x += 1) {
      if (mask.coverageAt(x, y) == 0) {
        continue;
      }
      left = left == null ? x : math.min(left, x);
      top = top == null ? y : math.min(top, y);
      right = right == null ? x + 1 : math.max(right, x + 1);
      bottom = bottom == null ? y + 1 : math.max(bottom, y + 1);
    }
  }
  if (left == null || top == null || right == null || bottom == null) {
    throw StateError('Cannot transform an empty selection mask.');
  }
  if (left == mask.left &&
      top == mask.top &&
      right == mask.left + mask.width &&
      bottom == mask.top + mask.height) {
    return mask;
  }
  final int width = right - left;
  final int height = bottom - top;
  final Uint8List coverage = Uint8List(width * height);
  for (var y = top; y < bottom; y += 1) {
    for (var x = left; x < right; x += 1) {
      coverage[(y - top) * width + x - left] = mask.coverageAt(x, y);
    }
  }
  return SelectionMask(
    left: left,
    top: top,
    width: width,
    height: height,
    coverage: coverage,
  );
}

/// Imperative commands exposed to the temporary WP2 debug toolbar.
///
/// The handle delegates to its mounted [CanvasView]. Calls made while detached
/// are harmless, which keeps asynchronous editor shutdown deterministic.
final class CanvasViewHandle {
  /// Creates a handle, optionally backed by an injected command dispatcher.
  CanvasViewHandle({CanvasToolCommandDispatcher? commandDispatcher})
    : // The public seam intentionally omits the private field prefix.
      // ignore: prefer_initializing_formals
      _commandDispatcher = commandDispatcher;

  final CanvasToolCommandDispatcher? _commandDispatcher;
  final SelectionClipboard _selectionClipboard = SelectionClipboard();
  final EraserModeState _eraserModeState = EraserModeState();
  _CanvasViewState? _state;
  EditorModel? _eraserModeModel;
  _CanvasToolAvailability? _availability;

  /// Invoked when command enablement changes after a canvas interaction.
  VoidCallback? onAvailabilityChanged;

  /// Whether a canvas is currently attached.
  bool get isAttached => _state != null;

  /// Eraser mode selected by the dock and reused by a flipped pen.
  EraserMode get eraserMode => _eraserModeState.lastSelectedMode;

  /// Selects the session's pixel, whole-stroke, or lasso eraser.
  void selectEraserMode(EraserMode mode) {
    if (_eraserModeState.lastSelectedMode == mode) {
      return;
    }
    _eraserModeState.selectMode(mode);
    onAvailabilityChanged?.call();
  }

  /// Undoes one WP1 journal entry when possible.
  Future<void> undo() => _state?._undo() ?? Future<void>.value();

  /// Redoes one WP1 journal entry when possible.
  Future<void> redo() => _state?._redo() ?? Future<void>.value();

  /// Fits the artwork to the current viewport and resets rotation.
  void fit() => _state?._fitCanvas();

  /// Cycles fit-to-screen, exact 100%, and the last manual view.
  void cycleZoom() => _state?._cycleZoom();

  /// Resets canvas rotation around the viewport center.
  void resetRotation() => _state?._resetRotation();

  /// Invalidates external layer/canvas mutations and requests a fresh frame.
  void refreshRaster() => _state?._refreshExternalRaster();

  /// Flushes the latest document/view snapshot before editor exit.
  Future<void> save() => _state?._saveNow() ?? Future<void>.value();

  /// Whether the selection clipboard currently contains pasteable pixels.
  bool get canPaste => _selectionClipboard.canPaste;

  /// Whether a static selection mask is active.
  bool get hasSelection => _state?._selectionTool.hasSelection ?? false;

  /// Whether a live selection float is awaiting placement.
  bool get hasSelectionFloat =>
      _state?._selectionTool.floatingSelection != null;

  /// Whether transform handles currently own an artwork target.
  bool get hasTransformDraft => _state?._transformTool.hasLiveState ?? false;

  /// Whether a crop rectangle is ready for adjustment or apply.
  bool get hasCropDraft => _state?._cropTool.hasLiveState ?? false;

  /// Whether a shape drag can be forced through the perfect detent.
  bool get hasShapeDraft => _state?._shapeTool.hasLiveState ?? false;

  /// Whether a text block is currently editable.
  bool get hasTextDraft => _state?._textTool.hasLiveState ?? false;

  /// Whether Done can commit a draft or reopen the journal-head text block.
  bool get canFinishText {
    final _CanvasViewState? state = _state;
    if (state == null) {
      return false;
    }
    final UndoJournal journal = state.widget.model.journal;
    return state._textTool.hasLiveState ||
        state._textTool.lastCommit != null &&
            journal.cursor > 0 &&
            journal.entries[journal.cursor - 1].kind == JournalKind.text;
  }

  /// Executes one contextual-dock command against the mounted tool state.
  Future<void> runToolCommand(CanvasToolCommand command) {
    final CanvasToolCommandDispatcher? dispatcher = _commandDispatcher;
    if (dispatcher != null) {
      return dispatcher(command);
    }
    return _state?._queueToolCommand(command) ?? Future<void>.value();
  }

  /// Detaches this handle from its current canvas, if any.
  void detach() {
    _state = null;
    _updateAvailability();
  }

  void _attach(_CanvasViewState state) {
    if (!identical(_eraserModeModel, state.widget.model)) {
      _eraserModeModel = state.widget.model;
      _eraserModeState.selectMode(
        eraserModeFromPreset(
          state.widget.model.toolState.presets['wp7EraserDefault'],
        ),
      );
    }
    _state = state;
    _updateAvailability();
  }

  void _detach(_CanvasViewState state) {
    if (identical(_state, state)) {
      _state = null;
      _updateAvailability();
    }
  }

  void _updateAvailability() {
    final _CanvasViewState? state = _state;
    final _CanvasToolAvailability next = (
      canPaste: _selectionClipboard.canPaste,
      hasSelection: state?._selectionTool.hasSelection ?? false,
      hasSelectionFloat: state?._selectionTool.floatingSelection != null,
      hasTransformDraft: state?._transformTool.hasLiveState ?? false,
      hasCropDraft: state?._cropTool.hasLiveState ?? false,
      hasShapeDraft: state?._shapeTool.hasLiveState ?? false,
      hasTextDraft: state?._textTool.hasLiveState ?? false,
      canFinishText: canFinishText,
    );
    if (next == _availability) {
      return;
    }
    _availability = next;
    onAvailabilityChanged?.call();
  }
}

typedef _CanvasToolAvailability = ({
  bool canPaste,
  bool hasSelection,
  bool hasSelectionFloat,
  bool hasTransformDraft,
  bool hasCropDraft,
  bool hasShapeDraft,
  bool hasTextDraft,
  bool canFinishText,
});

/// Full-bleed Ink canvas backed by WP1 tiles and journal state.
///
/// Raw pointer observation deliberately uses [Listener]. The custom
/// two-pointer tracker therefore never enters the gesture arena or claims a
/// single pointer. Stroke-time paints are driven only by [_repaint], never by
/// [EditorModel] notifications.
final class CanvasView extends StatefulWidget {
  /// Creates a canvas for one open editor model.
  const CanvasView({
    required this.model,
    required this.services,
    required this.handle,
    required this.onToggleChrome,
    this.onHistoryFeedback,
    this.contentTransformEnabled = true,
    this.compositorFactory,
    this.imageUploader,
    super.key,
  });

  /// Open artwork metadata, sparse tiles, tools, and WP1 journal.
  final EditorModel model;

  /// Injected pen source, clock, and persistence store.
  final InkServices services;

  /// Temporary toolbar command bridge.
  final CanvasViewHandle handle;

  /// Invoked by a classified four-finger tap.
  final VoidCallback onToggleChrome;

  /// Publishes one static undo/redo chip after a journal step succeeds.
  final ValueChanged<CanvasHistoryFeedback>? onHistoryFeedback;

  /// Whether `transform` targets artwork rather than an active reference.
  final bool contentTransformEnabled;

  /// Optional compositor factory; production defaults to [RasterWorker.start].
  final Future<RasterCompositor> Function()? compositorFactory;

  /// Optional composite-image uploader; production defaults to
  /// [uploadRgbaImage].
  final CompositeImageUploader? imageUploader;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

final class _CanvasViewState extends State<CanvasView>
    with WidgetsBindingObserver {
  final CanvasRepaintSignal _repaint = CanvasRepaintSignal();
  late final StrokeOverlay _overlay;
  final BrushHoverCursor _hoverCursor = BrushHoverCursor();
  final PalmGuard _palmGuard = PalmGuard();
  final Map<int, PalmTouchBirth> _touchBirths = <int, PalmTouchBirth>{};
  late final SelectionToolController _selectionTool;
  late final EraserTool _eraserTool;
  final FillToolController _fillTool = FillToolController();
  final ShapeToolController _shapeTool = ShapeToolController();
  final CropToolController _cropTool = CropToolController();
  final TransformToolController _transformTool = TransformToolController();
  final TextToolController _textTool = TextToolController();
  late final EyedropperToolController _eyedropperTool;
  int? _activeToolPointer;
  String? _activeInteractionToolId;
  final List<Offset> _toolGesturePoints = <Offset>[];
  Offset? _toolGestureStart;
  Offset? _lastToolDocumentPoint;
  bool _transformBodyDrag = false;
  bool _selectionFloatClearsSource = false;
  TextResizeHandle? _activeTextResizeHandle;
  bool _textResizeMode = false;
  bool _textSheetOpen = false;
  BuildContext? _textSheetContext;
  ui.Image? _transformPreviewImage;
  ui.Image? _selectionFloatImage;
  int _previewImageGeneration = 0;
  bool _transformPreviewRefreshRequested = false;
  bool _transformPreviewRefreshRunning = false;
  bool _selectionPreviewRefreshRequested = false;
  bool _selectionPreviewRefreshRunning = false;
  EyedropperSample? _eyedropperSample;
  Offset? _eyedropperViewportPoint;
  Offset? _straightedgeStartDocument;
  Offset? _straightedgeEndDocument;
  final List<StrokeEraseBatchRequest> _strokeEraseBatches =
      <StrokeEraseBatchRequest>[];
  final Set<int> _strokeEraseGestureTargets = <int>{};
  LassoClearRequest? _pendingLassoClear;

  late final CanvasController _controller;
  late final MultiTouchTapClassifier _tapClassifier;
  late TwoPointerNavigationTracker _navigation;

  RasterCompositor? _compositor;
  CompositeTileCache? _cache;
  PenRouter? _penRouter;
  StreamSubscription<PenMetadata>? _penMetadataSubscription;
  double? _penRouterDpr;
  int _penRouterGeneration = 0;
  bool _usingFlutterPenFallback = false;

  int? _activeStrokePointer;
  bool _activeStrokeIsTouch = false;
  bool _strokeFinalizing = false;
  Completer<void>? _strokeCompletion;
  String? _strokeLayerId;
  StrokeBuffer? _strokeBuffer;
  _ActiveBrushStroke? _strokeSession;
  Rect? _pendingOverlayDamage;
  Future<void>? _overlayDrain;
  Completer<void>? _overlayFrameScheduled;

  Size _viewportSize = const Size(1, 1);
  Size? _pendingViewportSize;
  Duration _latestPointerTimestamp = Duration.zero;
  Duration? _touchChordStartedAt;
  Offset? _navigationStartFocal;
  bool _navigationTransformAdmitted = false;
  bool _didInitialFit = false;
  bool _cacheSyncRequested = false;
  bool _cacheSyncRunning = false;
  bool _disposed = false;
  bool _quiescing = false;
  int _saveGeneration = 0;
  Future<void> _saveTail = Future<void>.value();
  Future<void> _historyTail = Future<void>.value();
  Future<void> _toolCommandTail = Future<void>.value();
  int _pendingHistoryActions = 0;
  int _pendingToolCommands = 0;
  Object? _lastEngineError;
  InkViewState? _lastManualView;
  int _zoomCycleIndex = 0;
  late String _selectedToolId;

  Size get _documentSize => Size(
    widget.model.document.canvas.width.toDouble(),
    widget.model.document.canvas.height.toDouble(),
  );

  @override
  void initState() {
    super.initState();
    if (!identical(widget.handle._eraserModeModel, widget.model)) {
      widget.handle._eraserModeModel = widget.model;
      widget.handle._eraserModeState.selectMode(
        eraserModeFromPreset(
          widget.model.toolState.presets['wp7EraserDefault'],
        ),
      );
    }
    _eraserTool = EraserTool(
      modeState: widget.handle._eraserModeState,
      onStrokeEraseBatch: _strokeEraseBatches.add,
      onLassoClear: (LassoClearRequest request) {
        _pendingLassoClear = request;
      },
    );
    _selectionTool = SelectionToolController(
      clipboard: widget.handle._selectionClipboard,
    );
    final Wp5ToolOptions toolOptions = widget.model.toolState.wp5Options;
    _selectedToolId = widget.model.toolState.selectedToolId;
    _syncControllerOptions(toolOptions);
    _eyedropperTool = EyedropperToolController(
      radius: toolOptions.eyedropperRadiusDpx,
      paletteSnapDeltaE: toolOptions.paletteSnapDeltaE,
      palette: widget.model.toolState.recentColors.map(
        (InkColor color) => color.argb,
      ),
    );
    widget.model.toolState.addListener(_handleToolStateChanged);
    _overlay = StrokeOverlay(imageUploader: widget.imageUploader);
    WidgetsBinding.instance.addObserver(this);
    _controller = CanvasController(
      documentSize: _documentSize,
      viewportSize: _viewportSize,
      initialView: widget.model.viewState,
      onChanged: _handleControllerChanged,
    );
    _tapClassifier = MultiTouchTapClassifier(onTap: _handleCommandTap);
    _navigation = _newNavigationTracker();
    widget.handle._attach(this);
    if (_selectedToolId == 'transform' && widget.contentTransformEnabled) {
      _beginTransform();
    }
    unawaited(_initializeEngine());
  }

  TwoPointerNavigationTracker _newNavigationTracker() {
    return TwoPointerNavigationTracker(
      canStart: _canStartNavigation,
      onUpdate: _handleNavigation,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollPenState());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final double dpr = View.of(context).devicePixelRatio;
    if (_penRouter == null || _penRouterDpr != dpr) {
      unawaited(_replacePenRouter(dpr));
    }
  }

  @override
  void didUpdateWidget(CanvasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.handle, widget.handle)) {
      oldWidget.handle._detach(this);
      widget.handle._attach(this);
    }
    assert(
      identical(oldWidget.model, widget.model),
      'CanvasView state cannot be moved between editor models.',
    );
    if (!identical(oldWidget.services.pen, widget.services.pen)) {
      final double dpr = _penRouterDpr ?? View.of(context).devicePixelRatio;
      unawaited(_replacePenRouter(dpr));
    }
    if (oldWidget.contentTransformEnabled != widget.contentTransformEnabled) {
      if (!widget.contentTransformEnabled) {
        _cancelTransform();
      } else if (widget.model.toolState.selectedToolId == 'transform') {
        _beginTransform();
      }
    }
  }

  void _handleToolStateChanged() {
    if (_disposed) {
      return;
    }
    final ToolState tools = widget.model.toolState;
    _syncControllerOptions(tools.wp5Options);
    final String nextToolId = tools.selectedToolId;
    if (nextToolId != _selectedToolId) {
      final String previousToolId = _selectedToolId;
      _selectedToolId = nextToolId;
      if (previousToolId == 'transform' && nextToolId != 'transform') {
        _cancelTransform();
      }
      if (previousToolId == 'text' &&
          nextToolId != 'text' &&
          _textTool.hasLiveState) {
        _textTool.cancel();
      }
      if (nextToolId == 'transform' && widget.contentTransformEnabled) {
        _beginTransform();
      }
    }
    _rebuildToolOverlay();
  }

  void _syncControllerOptions(Wp5ToolOptions options) {
    _transformTool.setLockAspect(
      options.transformAspect == TransformAspect.uniform,
    );
    _textTool.setOptions(
      TextOptions(
        fontFamily: options.textFont == InkTextFont.inter
            ? TextFontFamily.inter
            : TextFontFamily.jetBrainsMono,
        size: options.textSize,
        weight: switch (options.textWeight) {
          <= 500 => InkTextWeight.medium,
          <= 600 => InkTextWeight.semiBold,
          <= 700 => InkTextWeight.bold,
          _ => InkTextWeight.extraBold,
        },
        colorArgb: _parseBrushColor(widget.model.toolState.color),
      ),
    );
  }

  Future<void> _initializeEngine() async {
    try {
      final Future<RasterCompositor> Function() factory =
          widget.compositorFactory ?? RasterWorker.start;
      final RasterCompositor compositor = await factory();
      if (_disposed) {
        await compositor.dispose();
        return;
      }
      _compositor = compositor;
      _cache = CompositeTileCache(
        batchBuilder: compositor.compositeVisibleTiles,
        imageUploader: widget.imageUploader,
      );
      _requestVisibleCacheSync();
      if (mounted) {
        setState(() {});
      }
    } on Object catch (error) {
      _lastEngineError = error;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _replacePenRouter(double dpr) async {
    if (_disposed || _penRouterDpr == dpr && _penRouter != null) {
      return;
    }
    final int generation = ++_penRouterGeneration;
    final PenRouter? previous = _penRouter;
    final StreamSubscription<PenMetadata>? previousSubscription =
        _penMetadataSubscription;
    _penRouter = null;
    _penMetadataSubscription = null;
    await previousSubscription?.cancel();
    await previous?.dispose();
    if (_disposed || generation != _penRouterGeneration) {
      return;
    }
    final PenRouter router = PenRouter(
      penEvents: widget.services.pen,
      devicePixelRatio: dpr,
    )..start();
    _penRouterDpr = dpr;
    _penRouter = router;
    _penMetadataSubscription = router.metadataEvents.listen(
      _handlePenMetadata,
      onError: (Object error, StackTrace stackTrace) {
        _lastEngineError = error;
      },
    );
    await _pollPenState(expectedRouter: router);
  }

  Future<void> _pollPenState({PenRouter? expectedRouter}) async {
    final PenEvents pen = widget.services.pen;
    if (pen is! PlutoPen) {
      return;
    }
    try {
      final PenState state = await pen.currentState();
      final PenRouter? router = _penRouter;
      if (!_disposed &&
          router != null &&
          (expectedRouter == null || identical(expectedRouter, router))) {
        final Duration frameTime =
            WidgetsBinding.instance.currentSystemFrameTimeStamp;
        _palmGuard.synchronizePenState(
          state,
          timestamp: frameTime > Duration.zero
              ? frameTime
              : _latestPointerTimestamp,
        );
        _setTemporaryTool(
          tool: state.tool,
          buttons: state.buttons,
          isInProximity: state.isInProximity || state.isInContact,
        );
      }
    } on Object {
      // The event channel and Flutter hover remain the host-safe fallback.
    }
  }

  void _handlePenMetadata(PenMetadata metadata) {
    _usingFlutterPenFallback = false;
    _palmGuard.updatePenMetadata(metadata);
    _setTemporaryTool(
      tool: metadata.tool,
      buttons: metadata.buttons,
      isInProximity:
          metadata.phase != PenMetadataPhase.leftProximity &&
          metadata.isInProximity,
    );
    if (metadata.phase == PenMetadataPhase.leftProximity) {
      _hideHoverCursor();
    }
  }

  void _setTemporaryTool({
    required PenTool tool,
    required PenButtons buttons,
    required bool isInProximity,
  }) {
    final String? temporaryTool = !isInProximity
        ? null
        : switch ((tool, buttons)) {
            (PenTool.eraser, _) => 'erase',
            (_, final PenButtons buttons) when buttons.hasPrimary => 'picker',
            _ => null,
          };
    widget.model.toolState.setTemporaryTool(temporaryTool);
  }

  void _handleControllerChanged() {
    if (_disposed) {
      return;
    }
    _repaint.requestRepaint();
    _requestVisibleCacheSync();
    final Offset? hoverCenter = _hoverCursor.center;
    if (hoverCenter != null) {
      _hoverCursor.update(
        center: hoverCenter,
        diameter: _hoverCursor.diameter,
        viewScale: _controller.scale,
      );
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _scheduleViewport(Size size) {
    if (size.isEmpty || size == _controller.viewportSize) {
      _pendingViewportSize = null;
      return;
    }
    if (_pendingViewportSize == size) {
      return;
    }
    _pendingViewportSize = size;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (_disposed || _pendingViewportSize != size) {
        return;
      }
      _controller.setViewportSize(size);
      if (_controller.viewportSize != size) {
        return;
      }
      _viewportSize = size;
      _pendingViewportSize = null;
      if (!_didInitialFit && _shouldInitiallyFit()) {
        _didInitialFit = true;
        _controller.fitToViewport(padding: PaperSpacing.space16);
        widget.model.setViewState(_controller.toViewState());
      }
    });
  }

  bool _shouldInitiallyFit() {
    final InkViewState view = widget.model.viewState;
    return view.tx == 0 &&
        view.ty == 0 &&
        view.scale == 1 &&
        view.rotationDeg == 0 &&
        widget.model.document.journalHeadSeq == 0;
  }

  void _requestVisibleCacheSync() {
    if (_disposed || _cache == null || _compositor == null) {
      return;
    }
    _cacheSyncRequested = true;
    if (_cacheSyncRunning) {
      return;
    }
    _cacheSyncRunning = true;
    unawaited(_drainVisibleCacheSync());
  }

  Future<void> _drainVisibleCacheSync() async {
    try {
      while (!_disposed && _cacheSyncRequested) {
        _cacheSyncRequested = false;
        final CompositeTileCache cache = _cache!;
        final List<TileKey> keys = _controller.visibleTiles;
        // CanvasPainter only presents the uploaded image. Missing and
        // transparent entries both present no image and need no new frame.
        final Map<TileKey, Object?> previousImages = <TileKey, Object?>{
          for (final TileKey key in keys) key: cache.lookup(key)?.image,
        };
        final List<CompositeTile> ensured = await cache.ensureTiles(
          keys: keys,
          document: widget.model.document,
          tiles: widget.model.tiles,
        );
        if (_disposed || !identical(cache, _cache)) {
          return;
        }
        cache.evictOutsideViewport(keys, marginTiles: 1);
        final bool presentationChanged = ensured.any(
          (CompositeTile tile) =>
              !identical(previousImages[tile.key], tile.image),
        );
        if (presentationChanged) {
          _repaint.requestRepaint();
        }
      }
    } on Object catch (error) {
      if (!_disposed) {
        _lastEngineError = error;
      }
    } finally {
      _cacheSyncRunning = false;
      // A request can remain queued only when it arrived during an await that
      // then threw. Successful drains consume queued work in the loop above.
      if (!_disposed && _cacheSyncRequested) {
        _requestVisibleCacheSync();
      }
    }
  }

  void _handlePointerEvent(PointerEvent event) {
    _latestPointerTimestamp = event.timeStamp;
    final PenInputSample? penSample = _penRouter?.handlePointerEvent(event);
    if (penSample != null) {
      _handlePenSample(penSample);
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) {
      _handleDebugMouse(event);
      return;
    }
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    switch (event) {
      case PointerDownEvent():
        _handleTouchDown(event);
      case PointerMoveEvent():
        _handleTouchMove(event);
      case PointerUpEvent():
        _handleTouchUp(event);
      case PointerCancelEvent():
        _handleTouchCancel(event);
      default:
        break;
    }
  }

  void _handlePenSample(PenInputSample sample) {
    if (!sample.metadata.hasChannelSample) {
      _usingFlutterPenFallback = true;
      final bool contact =
          sample.phase == PenInputPhase.down ||
          sample.phase == PenInputPhase.move;
      _palmGuard.updatePenMetadata(
        PenMetadata(
          phase: switch (sample.phase) {
            PenInputPhase.hover => PenMetadataPhase.hover,
            PenInputPhase.down => PenMetadataPhase.down,
            PenInputPhase.move => PenMetadataPhase.move,
            PenInputPhase.up || PenInputPhase.cancel => PenMetadataPhase.up,
          },
          timestamp: sample.timestamp,
          logicalPosition: sample.localPosition,
          rawPosition: sample.metadata.rawPosition,
          tool: sample.metadata.tool,
          tilt: sample.metadata.tilt,
          rawTilt: sample.metadata.rawTilt,
          buttons: sample.metadata.buttons,
          hoverDistance: sample.metadata.hoverDistance,
          rawDistance: sample.metadata.rawDistance,
          isInProximity: true,
          isInContact: contact,
          hasChannelSample: true,
        ),
      );
    }
    _setTemporaryTool(
      tool: sample.metadata.tool,
      buttons: sample.metadata.buttons,
      isInProximity: true,
    );
    switch (sample.phase) {
      case PenInputPhase.down:
        _hideHoverCursor();
        final EraserMode? eraserMode = _eraserTool.modeForInput(
          eraserToolSelected: widget.model.toolState.selectedToolId == 'erase',
          penFlipped: sample.metadata.tool == PenTool.eraser,
        );
        if (_usesBrushStroke(eraserMode: eraserMode)) {
          _beginStroke(
            pointer: sample.pointer,
            viewportPoint: sample.localPosition,
            pressure: _mappedPressure(sample.normalizedPressure),
            tilt: sample.metadata.tilt,
            timestamp: sample.timestamp,
            isTouch: false,
          );
        } else {
          _beginToolInteraction(
            pointer: sample.pointer,
            viewportPoint: sample.localPosition,
            timestamp: sample.timestamp,
            eraserMode: eraserMode,
          );
        }
      case PenInputPhase.move:
        if (_activeToolPointer == sample.pointer) {
          _updateToolInteraction(
            pointer: sample.pointer,
            viewportPoint: sample.localPosition,
            timestamp: sample.timestamp,
          );
        } else {
          _appendStrokePoint(
            pointer: sample.pointer,
            viewportPoint: sample.localPosition,
            pressure: _mappedPressure(sample.normalizedPressure),
            tilt: sample.metadata.tilt,
            timestamp: sample.timestamp,
          );
        }
      case PenInputPhase.up:
        if (_activeToolPointer == sample.pointer) {
          unawaited(
            _endToolInteraction(
              pointer: sample.pointer,
              viewportPoint: sample.localPosition,
              timestamp: sample.timestamp,
            ),
          );
        } else {
          _appendStrokePoint(
            pointer: sample.pointer,
            viewportPoint: sample.localPosition,
            pressure: _mappedPressure(sample.normalizedPressure),
            tilt: sample.metadata.tilt,
            timestamp: sample.timestamp,
          );
          unawaited(_commitStroke(sample.pointer));
        }
      case PenInputPhase.cancel:
        if (_activeToolPointer == sample.pointer) {
          _cancelToolInteraction(sample.pointer);
        } else {
          _cancelStroke(sample.pointer);
        }
      case PenInputPhase.hover:
        _updateHoverCursor(sample.localPosition);
    }
  }

  void _handlePointerExit(PointerExitEvent event) {
    _hideHoverCursor();
    if (!_usingFlutterPenFallback ||
        event.kind != PointerDeviceKind.stylus &&
            event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    _usingFlutterPenFallback = false;
    _palmGuard.updatePenMetadata(
      PenMetadata(
        phase: PenMetadataPhase.leftProximity,
        timestamp: event.timeStamp,
        logicalPosition: event.localPosition,
        rawPosition: Offset.zero,
        tool: PenTool.pen,
        tilt: Offset.zero,
        rawTilt: Offset.zero,
        buttons: PenButtons.none,
        hoverDistance: 1,
        rawDistance: 0,
        isInProximity: false,
        isInContact: false,
        hasChannelSample: true,
      ),
    );
    widget.model.toolState.setTemporaryTool(null);
  }

  void _handleDebugMouse(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(buttons: kPrimaryMouseButton):
        if (_usesBrushStroke()) {
          _beginStroke(
            pointer: event.pointer,
            viewportPoint: event.localPosition,
            pressure: _mappedPressure(0.6),
            tilt: Offset.zero,
            timestamp: event.timeStamp,
            isTouch: false,
          );
        } else {
          _beginToolInteraction(
            pointer: event.pointer,
            viewportPoint: event.localPosition,
            timestamp: event.timeStamp,
          );
        }
      case PointerMoveEvent(buttons: kPrimaryMouseButton):
        if (_activeToolPointer == event.pointer) {
          _updateToolInteraction(
            pointer: event.pointer,
            viewportPoint: event.localPosition,
            timestamp: event.timeStamp,
          );
        } else {
          _appendStrokePoint(
            pointer: event.pointer,
            viewportPoint: event.localPosition,
            pressure: _mappedPressure(0.6),
            tilt: Offset.zero,
            timestamp: event.timeStamp,
          );
        }
      case PointerUpEvent():
        if (_activeToolPointer == event.pointer) {
          unawaited(
            _endToolInteraction(
              pointer: event.pointer,
              viewportPoint: event.localPosition,
              timestamp: event.timeStamp,
            ),
          );
        } else {
          _appendStrokePoint(
            pointer: event.pointer,
            viewportPoint: event.localPosition,
            pressure: _mappedPressure(0.6),
            tilt: Offset.zero,
            timestamp: event.timeStamp,
          );
          unawaited(_commitStroke(event.pointer));
        }
      case PointerCancelEvent():
        if (_activeToolPointer == event.pointer) {
          _cancelToolInteraction(event.pointer);
        } else {
          _cancelStroke(event.pointer);
        }
      case PointerHoverEvent():
        _updateHoverCursor(event.localPosition);
      default:
        break;
    }
  }

  void _updateHoverCursor(Offset viewportPoint) {
    if (_disposed || _activeStrokePointer != null || _strokeFinalizing) {
      return;
    }
    final ToolState tools = widget.model.toolState;
    final EraserMode? eraserMode = _eraserTool.modeForInput(
      eraserToolSelected: tools.selectedToolId == 'erase',
      penFlipped: tools.temporaryToolId == 'erase',
    );
    final double diameter;
    if (eraserMode == EraserMode.stroke) {
      diameter = strokeEraserCursorLogicalDiameter / _controller.scale;
    } else if (_usesBrushStroke(eraserMode: eraserMode)) {
      diameter = _effectiveBrushSize(_effectiveBrushSpec());
    } else {
      _hideHoverCursor();
      return;
    }
    _hoverCursor.update(
      center: _controller.docFromViewport(viewportPoint),
      diameter: diameter,
      viewScale: _controller.scale,
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _hideHoverCursor() {
    if (_hoverCursor.hide().isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleTouchDown(PointerDownEvent event) {
    if (_touchBirths.isEmpty) {
      _touchChordStartedAt = event.timeStamp;
      _navigationTransformAdmitted = false;
    } else if (event.timeStamp - _touchChordStartedAt! >
        multiTouchTapMaximumDuration) {
      _navigationTransformAdmitted = true;
    }
    final PalmTouchBirth birth = _palmGuard.classifyTouchBirth(
      pointer: event.pointer,
      position: event.localPosition,
    );
    _touchBirths[event.pointer] = birth;
    final bool chordEligible =
        !birth.isDropped && !_activeStrokeIsTouch && _activeToolPointer == null;
    _tapClassifier.pointerDown(
      pointer: event.pointer,
      position: event.localPosition,
      timestamp: event.timeStamp,
      isBirthEligible: chordEligible,
    );
    _navigation.pointerDown(
      pointer: event.pointer,
      position: event.localPosition,
      timestamp: event.timeStamp,
      isBirthEligible: chordEligible,
    );
    final bool usesBrushStroke = _usesBrushStroke();
    if (_touchBirths.length == 1 &&
        _palmGuard
            .decide(
              intent: usesBrushStroke
                  ? PalmTouchIntent.toolTouch
                  : PalmTouchIntent.passiveSingleFinger,
              touches: <PalmTouchBirth>[birth],
              now: event.timeStamp,
              fingerDrawEnabled: widget.model.toolState.fingerDrawEnabled,
            )
            .isAllowed) {
      if (usesBrushStroke) {
        _beginStroke(
          pointer: event.pointer,
          viewportPoint: event.localPosition,
          pressure: _mappedPressure(0.6),
          tilt: Offset.zero,
          timestamp: event.timeStamp,
          isTouch: true,
        );
      } else {
        _beginToolInteraction(
          pointer: event.pointer,
          viewportPoint: event.localPosition,
          timestamp: event.timeStamp,
        );
      }
    }
  }

  void _handleTouchMove(PointerMoveEvent event) {
    _tapClassifier.pointerMove(
      pointer: event.pointer,
      position: event.localPosition,
    );
    _admitNavigationForEvent(event);
    _navigation.pointerMove(
      pointer: event.pointer,
      position: event.localPosition,
      timestamp: event.timeStamp,
    );
    if (_activeToolPointer == event.pointer) {
      _updateToolInteraction(
        pointer: event.pointer,
        viewportPoint: event.localPosition,
        timestamp: event.timeStamp,
      );
    } else if (_activeStrokeIsTouch) {
      _appendStrokePoint(
        pointer: event.pointer,
        viewportPoint: event.localPosition,
        pressure: _mappedPressure(0.6),
        tilt: Offset.zero,
        timestamp: event.timeStamp,
      );
    }
  }

  void _handleTouchUp(PointerUpEvent event) {
    _admitNavigationForEvent(event);
    _tapClassifier.pointerUp(
      pointer: event.pointer,
      position: event.localPosition,
      timestamp: event.timeStamp,
    );
    _navigation.pointerUp(
      pointer: event.pointer,
      position: event.localPosition,
      timestamp: event.timeStamp,
    );
    _touchBirths.remove(event.pointer);
    _resetTouchChordWhenClear();
    if (_activeToolPointer == event.pointer) {
      unawaited(
        _endToolInteraction(
          pointer: event.pointer,
          viewportPoint: event.localPosition,
          timestamp: event.timeStamp,
        ),
      );
    } else if (_activeStrokeIsTouch && _activeStrokePointer == event.pointer) {
      _appendStrokePoint(
        pointer: event.pointer,
        viewportPoint: event.localPosition,
        pressure: _mappedPressure(0.6),
        tilt: Offset.zero,
        timestamp: event.timeStamp,
      );
      unawaited(_commitStroke(event.pointer));
    }
  }

  void _handleTouchCancel(PointerCancelEvent event) {
    _tapClassifier.pointerCancel(event.pointer);
    _navigation.pointerCancel(event.pointer);
    _touchBirths.remove(event.pointer);
    _resetTouchChordWhenClear();
    if (_activeToolPointer == event.pointer) {
      _cancelToolInteraction(event.pointer);
    } else if (_activeStrokeIsTouch) {
      _cancelStroke(event.pointer);
    }
  }

  void _admitNavigationForEvent(PointerEvent event) {
    if (_navigationTransformAdmitted) {
      return;
    }
    final PalmTouchBirth? birth = _touchBirths[event.pointer];
    final Duration? chordStartedAt = _touchChordStartedAt;
    if ((birth != null &&
            (event.localPosition - birth.position).distance >
                multiTouchTapMaximumTravel) ||
        (chordStartedAt != null &&
            event.timeStamp - chordStartedAt > multiTouchTapMaximumDuration)) {
      _navigationTransformAdmitted = true;
    }
  }

  bool _canStartNavigation(List<int> pointers) {
    final List<PalmTouchBirth> births = <PalmTouchBirth>[];
    for (final int pointer in pointers) {
      final PalmTouchBirth? birth = _touchBirths[pointer];
      if (birth == null) {
        return false;
      }
      births.add(birth);
    }
    return !widget.model.isCompositing &&
        !_quiescing &&
        _palmGuard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: births,
              now: _latestPointerTimestamp,
            )
            .isAllowed;
  }

  void _handleNavigation(TwoPointerNavigationUpdate update) {
    if (_disposed) {
      return;
    }
    switch (update.phase) {
      case TwoPointerNavigationPhase.start:
        _navigationStartFocal = update.focalPoint;
        if (_navigationTransformAdmitted) {
          _beginDeferredNavigation();
        }
      case TwoPointerNavigationPhase.update:
        if (_navigationTransformAdmitted && _beginDeferredNavigation()) {
          _controller.updateNavigation(
            focalPoint: update.focalPoint,
            scale: update.scale,
            rotation: update.rotation,
          );
        }
      case TwoPointerNavigationPhase.end:
        if (_navigationTransformAdmitted && _beginDeferredNavigation()) {
          _controller.updateNavigation(
            focalPoint: update.focalPoint,
            scale: update.scale,
            rotation: update.rotation,
          );
          _controller.endNavigation(twistVelocity: update.twistVelocity);
          _settleView();
        }
        _navigationStartFocal = null;
      case TwoPointerNavigationPhase.cancel:
        if (_controller.gestureActive) {
          _controller.cancelNavigation();
          _settleView();
        }
        _navigationStartFocal = null;
    }
  }

  bool _beginDeferredNavigation() {
    if (_controller.gestureActive) {
      return true;
    }
    final Offset? focal = _navigationStartFocal;
    return focal != null && _controller.beginNavigation(focal);
  }

  void _resetTouchChordWhenClear() {
    if (_touchBirths.isNotEmpty) {
      return;
    }
    _touchChordStartedAt = null;
    _navigationStartFocal = null;
    _navigationTransformAdmitted = false;
  }

  void _settleView() {
    final InkViewState settled = _controller.toViewState();
    _lastManualView = settled;
    _zoomCycleIndex = 0;
    widget.model.setViewState(settled);
    _requestVisibleCacheSync();
    unawaited(_enqueueSave(dirtyTiles: const <TileLocation>[]));
  }

  void _handleCommandTap(MultiTouchTap tap) {
    if (_disposed) {
      return;
    }
    switch (tap.kind) {
      case MultiTouchTapKind.undo:
        unawaited(_undo());
      case MultiTouchTapKind.redo:
        unawaited(_redo());
      case MultiTouchTapKind.toggleChrome:
        widget.onToggleChrome();
    }
  }

  bool _usesBrushStroke({EraserMode? eraserMode}) {
    final ToolState tools = widget.model.toolState;
    final String toolId = tools.activeToolId;
    if (toolId == 'draw' && eraserMode == null) {
      return true;
    }
    if (toolId != 'erase' && eraserMode == null) {
      return false;
    }
    final EraserMode? resolved =
        eraserMode ??
        _eraserTool.modeForInput(
          eraserToolSelected: tools.selectedToolId == 'erase',
          penFlipped: tools.temporaryToolId == 'erase',
        );
    return resolved == EraserMode.pixel;
  }

  double _mappedPressure(double? pressure) {
    return mapPressureFromPreset(
      widget.model.toolState.presets['wp7PressureCurve'],
      pressure,
    );
  }

  void _beginToolInteraction({
    required int pointer,
    required Offset viewportPoint,
    required Duration timestamp,
    EraserMode? eraserMode,
  }) {
    final String toolId = eraserMode == null
        ? widget.model.toolState.activeToolId
        : 'erase';
    if (_disposed ||
        _quiescing ||
        widget.model.isCompositing ||
        _strokeFinalizing ||
        _pendingHistoryActions != 0 ||
        _pendingToolCommands != 0 ||
        _activeStrokePointer != null ||
        _activeToolPointer != null ||
        !const <String>{
          'select',
          'fill',
          'shape',
          'transform',
          'text',
          'crop',
          'picker',
          'guides',
          'erase',
        }.contains(toolId)) {
      return;
    }
    if ((toolId == 'fill' || toolId == 'shape') &&
        !widget.model.runLayerAction(action: () {})) {
      return;
    }
    if (toolId == 'erase' && _editableActiveLayer() == null) {
      return;
    }

    final Offset documentPoint = _documentPoint(viewportPoint);
    _activeToolPointer = pointer;
    _activeInteractionToolId = toolId;
    _toolGestureStart = documentPoint;
    _toolGesturePoints
      ..clear()
      ..add(documentPoint);
    _lastToolDocumentPoint = documentPoint;
    _navigation.setLocked(true);

    try {
      switch (toolId) {
        case 'erase':
          final EraserMode? resolved =
              eraserMode ??
              _eraserTool.modeForInput(
                eraserToolSelected:
                    widget.model.toolState.selectedToolId == 'erase',
                penFlipped: widget.model.toolState.temporaryToolId == 'erase',
              );
          if (resolved == null || resolved == EraserMode.pixel) {
            _resetToolInteraction();
            return;
          }
          _activeInteractionToolId = resolved == EraserMode.stroke
              ? 'eraseStroke'
              : 'eraseLasso';
          _eraserTool.strokeKills.discard();
          _strokeEraseBatches.clear();
          _strokeEraseGestureTargets.clear();
          _pendingLassoClear = null;
          if (resolved == EraserMode.stroke) {
            _collectStrokeEraseHit(documentPoint, timestamp);
          }
        case 'select':
          if (_selectionTool.floatingSelection == null) {
            _selectionTool.setOptions(_selectionOptions());
          } else {
            _activeInteractionToolId = 'selectFloat';
          }
        case 'fill':
          _fillTool.setOptions(_fillOptions());
        case 'shape':
          _shapeTool
            ..setOptions(_shapeOptions())
            ..begin(
              point: documentPoint,
              timestamp: timestamp,
              brush: _shapeBrushSettings(),
            );
        case 'transform':
          if (!widget.contentTransformEnabled) {
            _resetToolInteraction();
            return;
          }
          if (!_transformTool.hasLiveState) {
            _beginTransform();
          }
          final TransformSnapshot? snapshot = _transformTool.snapshot;
          if (snapshot == null) {
            _resetToolInteraction();
            return;
          }
          final TransformHandle? handle = _hitTestTransformHandle(
            viewportPoint,
            snapshot,
          );
          if (handle != null) {
            _transformTool.beginHandleDrag(handle, documentPoint);
            _transformBodyDrag = false;
          } else if (_viewportBounds(snapshot.bounds)
              .inflate(contextualToolHitTargetDesignPx / 2)
              .contains(viewportPoint)) {
            _transformBodyDrag = true;
          } else {
            _resetToolInteraction();
            return;
          }
        case 'text':
          final TextBlockDraft? draft = _textTool.draft;
          if (draft == null) {
            _activeInteractionToolId = 'textPlace';
            _placeText(documentPoint);
          } else {
            final TextResizeHandle? handle = _hitTestTextHandle(
              viewportPoint,
              draft,
            );
            if (_textResizeMode && handle != null) {
              _activeTextResizeHandle = handle;
              _activeInteractionToolId = 'textResize';
            } else if (_viewportBounds(draft.bounds)
                .inflate(contextualToolHitTargetDesignPx / 2)
                .contains(viewportPoint)) {
              _activeInteractionToolId = 'textMove';
            } else {
              _resetToolInteraction();
              return;
            }
          }
        case 'crop':
          final CropHandle? handle = _hitTestCropHandle(viewportPoint);
          if (handle != null) {
            _cropTool.beginHandleDrag(handle);
            _activeInteractionToolId = 'cropHandle';
          } else {
            _cropTool.beginDrag(
              point: documentPoint,
              artworkBounds: Offset.zero & _documentSize,
            );
          }
        case 'picker':
          _eyedropperViewportPoint = viewportPoint;
          _eyedropperSample = _eyedropperTool.beginHold(
            activation: EyedropperActivation.fingerLongPress,
            documentPoint: documentPoint,
            samplePixel: _sampleVisibleArgb,
          );
        case 'guides':
          _straightedgeStartDocument = documentPoint;
          _straightedgeEndDocument = documentPoint;
      }
      _rebuildToolOverlay();
    } on Object catch (error) {
      _lastEngineError = error;
      _cancelToolInteraction(pointer);
    }
  }

  void _updateToolInteraction({
    required int pointer,
    required Offset viewportPoint,
    required Duration timestamp,
  }) {
    if (_activeToolPointer != pointer) {
      return;
    }
    final String? toolId = _activeInteractionToolId;
    if (toolId == null) {
      return;
    }
    final Offset documentPoint = _documentPoint(viewportPoint);
    if (_toolGesturePoints.isEmpty ||
        _toolGesturePoints.last != documentPoint) {
      _toolGesturePoints.add(documentPoint);
    }
    try {
      switch (toolId) {
        case 'selectFloat':
          final SelectionFloat? floating = _selectionTool.floatingSelection;
          final Offset? previous = _lastToolDocumentPoint;
          if (floating != null &&
              previous != null &&
              previous != documentPoint) {
            _selectionTool.updateFloat(
              floating.copyWith(
                topLeft: floating.topLeft + documentPoint - previous,
              ),
            );
          }
        case 'shape':
          _shapeTool.update(documentPoint, timestamp);
        case 'eraseStroke':
          _collectStrokeEraseHit(documentPoint, timestamp);
        case 'eraseLasso':
          break;
        case 'crop':
          _cropTool.updateDrag(_constrainedCropDragPoint(documentPoint));
        case 'cropHandle':
          _cropTool.updateHandleDrag(
            documentPoint,
            preserveAspect:
                widget.model.toolState.wp5Options.transformAspect ==
                TransformAspect.uniform,
          );
        case 'transform':
          if (_transformTool.activeHandle != null) {
            _transformTool.updateHandleDrag(documentPoint);
          } else if (_transformBodyDrag) {
            final Offset? previous = _lastToolDocumentPoint;
            if (previous != null && previous != documentPoint) {
              _transformTool.translateBy(documentPoint - previous);
            }
          }
        case 'textMove':
          final Offset? previous = _lastToolDocumentPoint;
          if (previous != null && previous != documentPoint) {
            _textTool.dragBy(documentPoint - previous);
          }
        case 'textResize':
          final TextResizeHandle? handle = _activeTextResizeHandle;
          if (handle != null) {
            _textTool.resize(handle, documentPoint);
          }
        case 'picker':
          _eyedropperViewportPoint = viewportPoint;
          _eyedropperSample = _eyedropperTool.updateHold(
            documentPoint: documentPoint,
            samplePixel: _sampleVisibleArgb,
          );
        case 'guides':
          _straightedgeEndDocument = documentPoint;
        case 'select' || 'fill' || 'textPlace':
          break;
      }
      _lastToolDocumentPoint = documentPoint;
      if (toolId == 'transform') {
        unawaited(_refreshTransformPreviewImage());
      } else if (toolId == 'selectFloat') {
        unawaited(_refreshSelectionFloatImage());
      }
      _rebuildToolOverlay();
    } on Object catch (error) {
      _lastEngineError = error;
      _cancelToolInteraction(pointer);
    }
  }

  Future<void> _endToolInteraction({
    required int pointer,
    required Offset viewportPoint,
    required Duration timestamp,
  }) async {
    if (_activeToolPointer != pointer) {
      return;
    }
    _updateToolInteraction(
      pointer: pointer,
      viewportPoint: viewportPoint,
      timestamp: timestamp,
    );
    if (_activeToolPointer != pointer) {
      return;
    }
    final String? toolId = _activeInteractionToolId;
    final Offset end = _documentPoint(viewportPoint);
    ShapeCommand? shapeCommand;
    Offset? fillSeed;
    List<StrokeEraseBatchRequest> strokeEraseBatches =
        const <StrokeEraseBatchRequest>[];
    LassoClearRequest? lassoClear;
    var commitSelectionFloat = false;
    try {
      switch (toolId) {
        case 'eraseStroke':
          _eraserTool.strokeKills.flush();
          strokeEraseBatches = List<StrokeEraseBatchRequest>.of(
            _strokeEraseBatches,
          );
        case 'eraseLasso':
          final List<Offset> points = List<Offset>.of(_toolGesturePoints);
          if (points.length >= 3 && !boundsOfPoints(points).isEmpty) {
            final LassoClearRequest request = LassoClearRequest(
              layerId: widget.model.document.activeLayerId,
              vertices: <LassoPoint>[
                for (final Offset point in points)
                  LassoPoint(x: point.dx, y: point.dy),
              ],
              requestedAt: timestamp,
            );
            _eraserTool.clearLasso(request);
            lassoClear = _pendingLassoClear;
          }
        case 'select':
          _finishSelectionGesture(end);
        case 'selectFloat':
          final Offset? start = _toolGestureStart;
          commitSelectionFloat =
              start != null && (end - start).distance * _controller.scale < 4;
        case 'fill':
          fillSeed = end;
        case 'shape':
          final ShapeDraft? draft = _shapeTool.draft;
          final bool isNonDegenerate =
              draft != null &&
              switch (draft.geometry) {
                LineShapeGeometry(:final start, :final end) => start != end,
                ArrowShapeGeometry(:final start, :final end) => start != end,
                RectangleShapeGeometry(:final rect) => !rect.isEmpty,
                EllipseShapeGeometry(:final rect) => !rect.isEmpty,
                PolygonShapeGeometry(:final bounds) => !bounds.isEmpty,
              };
          if (isNonDegenerate) {
            shapeCommand = _shapeTool.finish(timestamp);
          } else {
            _shapeTool.cancel();
          }
        case 'crop':
          _cropTool.endDrag();
        case 'cropHandle':
          _cropTool.endHandleDrag();
        case 'transform':
          if (_transformTool.hasLiveState) {
            _transformTool.endDrag();
            unawaited(_refreshTransformPreviewImage());
          }
        case 'picker':
          final int color = _eyedropperTool.endHold();
          widget.model.toolState.selectInkColor(
            InkColor.fromArgb(0xff000000 | (color & 0x00ffffff)),
          );
          _eyedropperSample = null;
          _eyedropperViewportPoint = null;
        case 'guides':
          final Offset? start = _straightedgeStartDocument;
          final Offset? finish = _straightedgeEndDocument;
          if (start == null || finish == null || start == finish) {
            _straightedgeStartDocument = null;
            _straightedgeEndDocument = null;
          } else if (!widget.model.toolState.wp5Options.straightedgeEnabled) {
            widget.model.toolState.setWp5Options(
              widget.model.toolState.wp5Options.copyWith(
                straightedgeEnabled: true,
              ),
            );
          }
        case 'textPlace' || 'textMove' || 'textResize' || null:
          break;
      }
    } on Object catch (error) {
      _lastEngineError = error;
      _shapeTool.cancel();
      _eyedropperTool.cancel();
      _eraserTool.strokeKills.discard();
      _strokeEraseBatches.clear();
      _pendingLassoClear = null;
    } finally {
      _resetToolInteraction();
    }

    if (fillSeed != null) {
      await _performFill(fillSeed);
    } else if (shapeCommand != null) {
      await _performShape(shapeCommand);
    } else if (commitSelectionFloat) {
      await _commitSelectionFloat();
    } else if (lassoClear != null) {
      final LassoClearRequest request = lassoClear;
      await _queueToolOperation(() => _performLassoErase(request));
    } else if (strokeEraseBatches.isNotEmpty) {
      await _queueToolOperation(() async {
        for (final StrokeEraseBatchRequest request in strokeEraseBatches) {
          await _performStrokeErase(request);
        }
      });
    }
  }

  void _cancelToolInteraction(int pointer) {
    if (_activeToolPointer != pointer) {
      return;
    }
    switch (_activeInteractionToolId) {
      case 'shape':
        _shapeTool.cancel();
      case 'crop':
        _cropTool.cancel();
      case 'cropHandle':
        _cropTool.endHandleDrag();
      case 'transform':
        if (_transformTool.hasLiveState) {
          _transformTool.endDrag();
        }
      case 'picker':
        _eyedropperTool.cancel();
        _eyedropperSample = null;
        _eyedropperViewportPoint = null;
      case 'guides':
        _straightedgeStartDocument = null;
        _straightedgeEndDocument = null;
      case 'eraseStroke':
        _eraserTool.strokeKills.discard();
        _strokeEraseBatches.clear();
        _strokeEraseGestureTargets.clear();
      case 'eraseLasso':
        _pendingLassoClear = null;
      case 'select' ||
          'selectFloat' ||
          'fill' ||
          'textPlace' ||
          'textMove' ||
          'textResize' ||
          null:
        break;
    }
    _resetToolInteraction();
  }

  void _resetToolInteraction() {
    _activeToolPointer = null;
    _activeInteractionToolId = null;
    _toolGesturePoints.clear();
    _toolGestureStart = null;
    _lastToolDocumentPoint = null;
    _transformBodyDrag = false;
    _activeTextResizeHandle = null;
    if (!_disposed) {
      _navigation.setLocked(false);
      _rebuildToolOverlay();
    }
  }

  void _rebuildToolOverlay() {
    widget.handle._updateAvailability();
    if (mounted && !_disposed) {
      setState(() {});
    }
  }

  Offset _documentPoint(Offset viewportPoint) {
    final Offset point = _controller.docFromViewport(viewportPoint);
    return Offset(
      point.dx.clamp(0.0, math.max(0.0, _documentSize.width - 0.001)),
      point.dy.clamp(0.0, math.max(0.0, _documentSize.height - 0.001)),
    );
  }

  Offset _constrainedCropDragPoint(Offset point) {
    final Offset? start = _toolGestureStart;
    if (start == null ||
        widget.model.toolState.wp5Options.transformAspect ==
            TransformAspect.free) {
      return point;
    }
    final double deltaX = point.dx - start.dx;
    final double deltaY = point.dy - start.dy;
    final double horizontalLimit = deltaX < 0
        ? start.dx
        : _documentSize.width - start.dx;
    final double verticalLimit = deltaY < 0
        ? start.dy
        : _documentSize.height - start.dy;
    final double extent = math.min(
      math.max(deltaX.abs(), deltaY.abs()),
      math.min(horizontalLimit, verticalLimit),
    );
    return Offset(
      start.dx + (deltaX < 0 ? -extent : extent),
      start.dy + (deltaY < 0 ? -extent : extent),
    );
  }

  TransformHandle? _hitTestTransformHandle(
    Offset viewportPoint,
    TransformSnapshot snapshot,
  ) {
    final Rect bounds = snapshot.bounds;
    final Map<TransformHandle, Offset> centers = <TransformHandle, Offset>{
      TransformHandle.rotateLug: Offset(
        bounds.center.dx,
        bounds.top - 42 / _controller.scale,
      ),
      TransformHandle.topLeft: bounds.topLeft,
      TransformHandle.topCenter: bounds.topCenter,
      TransformHandle.topRight: bounds.topRight,
      TransformHandle.middleLeft: bounds.centerLeft,
      TransformHandle.middleRight: bounds.centerRight,
      TransformHandle.bottomLeft: bounds.bottomLeft,
      TransformHandle.bottomCenter: bounds.bottomCenter,
      TransformHandle.bottomRight: bounds.bottomRight,
    };
    return _nearestHandle(
      viewportPoint,
      centers.map(
        (TransformHandle handle, Offset point) =>
            MapEntry<TransformHandle, Offset>(
              handle,
              _controller.viewportFromDoc(point),
            ),
      ),
    );
  }

  CropHandle? _hitTestCropHandle(Offset viewportPoint) {
    final CropDraft? draft = _cropTool.draft;
    if (draft == null || draft.cropRect.isEmpty) {
      return null;
    }
    final Rect bounds = draft.cropRect;
    final Map<CropHandle, Offset> centers = <CropHandle, Offset>{
      CropHandle.topLeft: bounds.topLeft,
      CropHandle.topCenter: bounds.topCenter,
      CropHandle.topRight: bounds.topRight,
      CropHandle.middleLeft: bounds.centerLeft,
      CropHandle.middleRight: bounds.centerRight,
      CropHandle.bottomLeft: bounds.bottomLeft,
      CropHandle.bottomCenter: bounds.bottomCenter,
      CropHandle.bottomRight: bounds.bottomRight,
    };
    return _nearestHandle(
      viewportPoint,
      centers.map(
        (CropHandle handle, Offset point) => MapEntry<CropHandle, Offset>(
          handle,
          _controller.viewportFromDoc(point),
        ),
      ),
    );
  }

  TextResizeHandle? _hitTestTextHandle(
    Offset viewportPoint,
    TextBlockDraft draft,
  ) {
    final Rect bounds = draft.bounds;
    return _nearestHandle(viewportPoint, <TextResizeHandle, Offset>{
      TextResizeHandle.topLeft: _controller.viewportFromDoc(bounds.topLeft),
      TextResizeHandle.topRight: _controller.viewportFromDoc(bounds.topRight),
      TextResizeHandle.bottomLeft: _controller.viewportFromDoc(
        bounds.bottomLeft,
      ),
      TextResizeHandle.bottomRight: _controller.viewportFromDoc(
        bounds.bottomRight,
      ),
    });
  }

  T? _nearestHandle<T>(Offset point, Map<T, Offset> centers) {
    T? nearest;
    var nearestDistance = contextualToolHitTargetDesignPx / 2;
    for (final MapEntry<T, Offset> entry in centers.entries) {
      final double distance = (entry.value - point).distance;
      if (distance <= nearestDistance) {
        nearest = entry.key;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  SelectionOptions _selectionOptions() {
    final Wp5ToolOptions options = widget.model.toolState.wp5Options;
    return SelectionOptions(
      mode: switch (options.selectionGeometry) {
        SelectionGeometry.rectangle => SelectionMode.rectangle,
        SelectionGeometry.lasso => SelectionMode.lasso,
        SelectionGeometry.wand => SelectionMode.wand,
      },
      combine: switch (options.selectionCombine) {
        SelectionCombine.replace => SelectionCombineMode.replace,
        SelectionCombine.add => SelectionCombineMode.add,
        SelectionCombine.subtract => SelectionCombineMode.subtract,
      },
      wandTolerance: options.selectionTolerance,
      wandGapClose: options.selectionGapClose,
    );
  }

  FillOptions _fillOptions() {
    final Wp5ToolOptions options = widget.model.toolState.wp5Options;
    final int color = _parseBrushColor(widget.model.toolState.color);
    final FillMaterial style = switch (options.fillStyle) {
      FillStyle.solid => SolidFillStyle(color),
      FillStyle.hatch => HatchFillStyle(colorArgb: color),
      FillStyle.dotScreen => DotScreenFillStyle(
        colorArgb: color,
        density: options.dotScreenDensity == DotScreenDensity.bayer4
            ? FillDotScreenDensity.bayer4
            : FillDotScreenDensity.bayer8,
      ),
    };
    return FillOptions(
      tolerance: options.fillTolerance,
      gapClose: options.fillGapClose,
      grow: options.fillGrow,
      sampleSource: options.fillSampleSource == RasterSampleSource.activeLayer
          ? FillSampleSource.activeLayer
          : FillSampleSource.composite,
      style: style,
    );
  }

  ShapeOptions _shapeOptions() {
    final Wp5ToolOptions options = widget.model.toolState.wp5Options;
    return ShapeOptions(
      kind: switch (options.shapeType) {
        ShapeType.line => ShapeKind.line,
        ShapeType.arrow => ShapeKind.arrow,
        ShapeType.rectangle => ShapeKind.rectangle,
        ShapeType.ellipse => ShapeKind.ellipse,
        ShapeType.polygon => ShapeKind.polygon,
      },
      polygonSides: options.polygonSides,
      fromCenter: options.shapeOrigin == ShapeOrigin.center,
      lockAspect: options.shapeConstraint == ShapeConstraint.aspect,
    );
  }

  ShapeBrushSettings _shapeBrushSettings() {
    final BrushSpec brush = _effectiveBrushSpec();
    return ShapeBrushSettings(
      brushId: brush.id,
      colorArgb: _parseBrushColor(widget.model.toolState.color),
      size: _effectiveBrushSize(brush),
      seed: widget.model.journal.nextSequence,
    );
  }

  Future<void> _queueToolCommand(CanvasToolCommand command) =>
      _queueToolOperation(() => _executeToolCommand(command));

  Future<void> _queueToolOperation(Future<void> Function() operation) {
    if (_disposed || _quiescing) {
      return Future<void>.value();
    }
    final Completer<void> completion = Completer<void>();
    _pendingToolCommands += 1;
    final Future<void> pendingTools = _toolCommandTail;
    final Future<void> pendingHistory = _historyTail;
    _toolCommandTail =
        Future.wait<void>(<Future<void>>[
          pendingTools,
          pendingHistory,
        ]).then<void>((_) async {
          try {
            final Future<void>? strokeDone = _strokeCompletion?.future;
            if (strokeDone != null) {
              await strokeDone;
            }
            if (!_disposed) {
              await operation();
            }
          } on Object catch (error) {
            if (!_disposed) {
              _lastEngineError = error;
              _rebuildToolOverlay();
            }
          } finally {
            _pendingToolCommands -= 1;
            if (!completion.isCompleted) {
              completion.complete();
            }
          }
        });
    return completion.future;
  }

  Future<void> _executeToolCommand(CanvasToolCommand command) async {
    final String toolId = widget.model.toolState.selectedToolId;
    switch ((toolId, command)) {
      case ('select', CanvasToolCommand.copy):
        _copySelection();
      case ('select', CanvasToolCommand.cut):
        await _clearSelection(cut: true);
      case ('select', CanvasToolCommand.clear):
        await _clearSelection(cut: false);
      case ('select', CanvasToolCommand.paste):
        _pasteSelection();
      case ('select', CanvasToolCommand.duplicate):
        _startSelectionFloat(duplicate: true);
      case ('select', CanvasToolCommand.move):
        _startSelectionFloat(duplicate: false);
      case ('select', CanvasToolCommand.flipHorizontal):
        _flipSelection(horizontal: true);
      case ('select', CanvasToolCommand.flipVertical):
        _flipSelection(horizontal: false);
      case ('select', CanvasToolCommand.fill):
        await _fillSelection();
      case ('select', CanvasToolCommand.toNewLayer):
        await _copySelectionToNewLayer();
      case ('select', CanvasToolCommand.transform):
        if (_selectionTool.floatingSelection != null) {
          await _commitSelectionFloat();
          if (_selectionTool.floatingSelection != null) {
            return;
          }
        }
        widget.model.toolState.selectTool('transform');
      case ('transform', CanvasToolCommand.apply):
        await _commitTransform();
      case ('transform', CanvasToolCommand.reset):
        if (_transformTool.hasLiveState) {
          _transformTool.reset();
          unawaited(_refreshTransformPreviewImage());
          _rebuildToolOverlay();
        }
      case ('transform', CanvasToolCommand.rotateDetent):
        if (_transformTool.hasLiveState) {
          _transformTool.rotateBy(math.pi / 12);
          unawaited(_refreshTransformPreviewImage());
          _rebuildToolOverlay();
        }
      case ('transform', CanvasToolCommand.flipHorizontal):
        if (_transformTool.hasLiveState) {
          _transformTool.flipHorizontal();
          unawaited(_refreshTransformPreviewImage());
          _rebuildToolOverlay();
        }
      case ('transform', CanvasToolCommand.flipVertical):
        if (_transformTool.hasLiveState) {
          _transformTool.flipVertical();
          unawaited(_refreshTransformPreviewImage());
          _rebuildToolOverlay();
        }
      case ('crop', CanvasToolCommand.apply):
        await _commitCrop();
      case ('crop', CanvasToolCommand.reset):
        _cropTool.cancel();
        _rebuildToolOverlay();
      case ('text', CanvasToolCommand.move):
        _textResizeMode = false;
        _rebuildToolOverlay();
      case ('text', CanvasToolCommand.textResize):
        _textResizeMode = true;
        _rebuildToolOverlay();
      case ('text', CanvasToolCommand.textSize):
        _cycleTextSize();
      case ('text', CanvasToolCommand.textWeight):
        _cycleTextWeight();
      case ('text', CanvasToolCommand.done):
        await _toggleTextDone();
      case ('shape', CanvasToolCommand.perfect):
        if (_shapeTool.hasLiveState) {
          _shapeTool.perfect();
          _rebuildToolOverlay();
        }
      case (_, CanvasToolCommand.dismiss):
        _dismissToolState(toolId);
      case _:
        break;
    }
  }

  InkLayer? _editableActiveLayer() {
    final InkLayer? layer = _activeLayer();
    if (layer == null ||
        !widget.model.runLayerAction(layerId: layer.id, action: () {})) {
      return null;
    }
    return layer;
  }

  RgbaFragment? _activeSelectionFragment(InkLayer layer) {
    final SelectionMask? mask = _selectionTool.mask;
    if (mask == null) {
      return null;
    }
    return extractSelectionFragment(
      source: _documentBitmap(layerId: layer.id),
      selection: mask,
      documentId: widget.model.document.id,
      layerId: layer.id,
    );
  }

  void _copySelection() {
    final InkLayer? layer = _editableActiveLayer();
    if (layer == null) {
      return;
    }
    final RgbaFragment? fragment = _activeSelectionFragment(layer);
    if (fragment == null) {
      return;
    }
    _selectionTool.copy(fragment);
    _rebuildToolOverlay();
  }

  Future<void> _clearSelection({required bool cut}) async {
    final InkLayer? layer = _editableActiveLayer();
    final SelectionMask? mask = _selectionTool.mask;
    if (layer == null || mask == null) {
      return;
    }
    final raster.RgbaBitmap before = _documentBitmap(layerId: layer.id);
    final SelectionClearCommand command;
    if (cut) {
      final RgbaFragment? fragment = _activeSelectionFragment(layer);
      if (fragment == null) {
        return;
      }
      command = _selectionTool.cut(fragment, layerId: layer.id);
    } else {
      command = _selectionTool.clear(layerId: layer.id);
    }
    final raster.RgbaBitmap after = _clearBitmapWithMask(before, command.mask);
    await _commitBitmapChange(
      kind: command.journalKind,
      layerId: layer.id,
      before: before,
      after: after,
      bounds: command.mask.bounds,
    );
  }

  void _pasteSelection() {
    final InkLayer? layer = _editableActiveLayer();
    if (layer == null || !_selectionTool.clipboard.canPaste) {
      return;
    }
    final Offset viewportCenter = _viewportSize.center(Offset.zero);
    final SelectionFloat? floating = _selectionTool.pasteAtViewportCenter(
      viewportCenter: _controller.docFromViewport(viewportCenter),
      activeLayerId: layer.id,
    );
    if (floating == null) {
      return;
    }
    _selectionFloatClearsSource = false;
    unawaited(_refreshSelectionFloatImage());
    _rebuildToolOverlay();
  }

  void _startSelectionFloat({required bool duplicate}) {
    final InkLayer? layer = _editableActiveLayer();
    if (layer == null) {
      return;
    }
    final RgbaFragment? fragment = _activeSelectionFragment(layer);
    if (fragment == null) {
      return;
    }
    if (duplicate) {
      _selectionTool.duplicate(fragment, activeLayerId: layer.id);
      _selectionFloatClearsSource = false;
    } else {
      _selectionTool.beginFloat(
        SelectionFloat(
          fragment: fragment,
          destinationLayerId: layer.id,
          topLeft: fragment.source.sourceBounds.topLeft,
        ),
      );
      _selectionFloatClearsSource = true;
    }
    unawaited(_refreshSelectionFloatImage());
    _rebuildToolOverlay();
  }

  void _flipSelection({required bool horizontal}) {
    if (_selectionTool.floatingSelection == null) {
      _startSelectionFloat(duplicate: false);
    }
    if (_selectionTool.floatingSelection == null) {
      return;
    }
    if (horizontal) {
      _selectionTool.flipFloatHorizontal();
    } else {
      _selectionTool.flipFloatVertical();
    }
    unawaited(_refreshSelectionFloatImage());
    _rebuildToolOverlay();
  }

  Future<void> _fillSelection() async {
    final InkLayer? layer = _editableActiveLayer();
    final SelectionMask? mask = _selectionTool.mask;
    if (layer == null || mask == null) {
      return;
    }
    final raster.RgbaBitmap before = _documentBitmap(layerId: layer.id);
    final raster.RgbaBitmap after = _fillBitmapWithMask(
      before,
      mask,
      _parseBrushColor(widget.model.toolState.color),
    );
    await _commitBitmapChange(
      kind: JournalKind.fill,
      layerId: layer.id,
      before: before,
      after: after,
      bounds: mask.bounds,
    );
  }

  Future<void> _commitSelectionFloat() async {
    final FloatCommitCommand? command = _selectionTool.handleCanvasTap();
    if (command == null) {
      return;
    }
    final SelectionFloat floating = command.floatingSelection;
    final bool clearsSource = _selectionFloatClearsSource;
    final raster.RgbaBitmap before = _documentBitmap(
      layerId: floating.destinationLayerId,
    );
    raster.RgbaBitmap base = before;
    final SelectionMask? mask = _selectionTool.mask;
    if (clearsSource && mask != null) {
      base = _clearBitmapWithMask(base, mask);
    }
    final raster.RgbaBitmap after = compositeSelectionFloat(
      floatingSelection: floating,
      target: base,
    );
    _selectionFloatClearsSource = false;
    _disposeSelectionFloatImage();
    final bool committed = await _commitBitmapChange(
      kind: command.journalKind,
      layerId: floating.destinationLayerId,
      before: before,
      after: after,
      bounds: floating.fragment.source.sourceBounds.expandToInclude(
        _selectionFloatBounds(floating),
      ),
    );
    if (committed) {
      final SelectionMask? nextMask = _selectionMaskForFloat(floating);
      if (nextMask == null) {
        _selectionTool.deselect();
      } else {
        _selectionTool.applyMask(nextMask);
      }
    } else {
      _selectionTool.beginFloat(floating);
      _selectionFloatClearsSource = clearsSource;
      unawaited(_refreshSelectionFloatImage());
    }
  }

  Future<void> _copySelectionToNewLayer() async {
    final InkLayer? sourceLayer = _editableActiveLayer();
    if (sourceLayer == null || !widget.model.canAddContentLayer) {
      return;
    }
    final RgbaFragment? fragment = _activeSelectionFragment(sourceLayer);
    if (fragment == null) {
      return;
    }
    final int now = widget.services.clock.nowMilliseconds();
    var suffix = 0;
    var newLayerId = 'L$now-selection';
    final Set<String> existingIds = widget.model.contentLayers
        .map((InkLayer layer) => layer.id)
        .toSet();
    while (existingIds.contains(newLayerId)) {
      suffix += 1;
      newLayerId = 'L$now-selection-$suffix';
    }
    final SelectionToNewLayerCommand command = _selectionTool.toNewLayer(
      sourceLayerId: sourceLayer.id,
      newLayerId: newLayerId,
    );
    final JournalDocumentState before = _journalState();
    final raster.RgbaBitmap transparent = raster.RgbaBitmap.transparent(
      width: widget.model.document.canvas.width,
      height: widget.model.document.canvas.height,
    );
    final raster.RgbaBitmap copied = compositeSelectionFloat(
      floatingSelection: SelectionFloat(
        fragment: fragment,
        destinationLayerId: newLayerId,
        topLeft: fragment.source.sourceBounds.topLeft,
      ),
      target: transparent,
    );
    final TileStore store = before.tiles.fork()
      ..replaceLayer(newLayerId, _tilesFromBitmap(copied));
    final int sourceIndex = before.layers.indexWhere(
      (InkLayer layer) => layer.id == sourceLayer.id,
    );
    final List<InkLayer> layers = List<InkLayer>.of(before.layers)
      ..insert(
        sourceIndex + 1,
        InkLayer(
          id: newLayerId,
          name: '${sourceLayer.name} selection',
          tiles: store.occupiedKeys(newLayerId),
        ),
      );
    final JournalDocumentState after = JournalDocumentState(
      tiles: store,
      layers: <InkLayer>[
        for (final InkLayer layer in layers)
          layer.copyWith(tiles: store.occupiedKeys(layer.id)),
      ],
      canvas: before.canvas,
    );
    final JournalEntry entry = JournalEntry(
      seq: widget.model.journal.nextSequence,
      timestampMs: now,
      kind: command.journalKind,
      layerId: newLayerId,
      beforeState: before.structuralJson(),
      afterState: after.structuralJson(),
      beforeLayerTiles: _completeRasterSnapshot(before),
      afterLayerTiles: _completeRasterSnapshot(after),
      completeLayerSnapshots: true,
      unknownFields: <String, Object?>{'activeLayerBefore': sourceLayer.id},
    );
    await _applyEngineToolOperation(
      JournaledEngineOperation(state: after, entry: entry),
      activeLayerId: newLayerId,
    );
  }

  void _beginTransform() {
    if (_disposed ||
        !widget.contentTransformEnabled ||
        _transformTool.hasLiveState) {
      return;
    }
    final InkLayer? layer = _editableActiveLayer();
    if (layer == null) {
      return;
    }
    final SelectionMask? selection = switch (_selectionTool.mask) {
      final SelectionMask mask => trimSelectionMaskForTransform(mask),
      null => null,
    };
    final Rect? layerBounds =
        selection?.bounds ?? _sparseLayerBitmap(layer.id)?.bounds;
    if (layerBounds == null) {
      return;
    }
    _transformTool.begin(
      activeLayerId: layer.id,
      activeLayerBounds: layerBounds,
      selection: selection,
    );
    unawaited(_refreshTransformPreviewImage());
    _rebuildToolOverlay();
  }

  ({raster.RgbaBitmap bitmap, Rect bounds})? _sparseLayerBitmap(
    String layerId,
  ) {
    int? left;
    int? top;
    int? right;
    int? bottom;
    final Map<TileKey, Tile> tiles = widget.model.tiles.layerTiles(layerId);
    for (final MapEntry<TileKey, Tile> entry in tiles.entries) {
      for (var localY = 0; localY < Tile.edge; localY += 1) {
        for (var localX = 0; localX < Tile.edge; localX += 1) {
          final int offset = (localY * Tile.edge + localX) * Tile.bytesPerPixel;
          if (entry.value.pixels[offset + 3] == 0) {
            continue;
          }
          final int x = entry.key.x * Tile.edge + localX;
          final int y = entry.key.y * Tile.edge + localY;
          left = left == null ? x : math.min(left, x);
          top = top == null ? y : math.min(top, y);
          right = right == null ? x + 1 : math.max(right, x + 1);
          bottom = bottom == null ? y + 1 : math.max(bottom, y + 1);
        }
      }
    }
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    final int width = right - left;
    final int height = bottom - top;
    final Uint8List pixels = Uint8List(width * height * 4);
    for (final MapEntry<TileKey, Tile> entry in tiles.entries) {
      for (var localY = 0; localY < Tile.edge; localY += 1) {
        final int y = entry.key.y * Tile.edge + localY;
        if (y < top || y >= bottom) {
          continue;
        }
        for (var localX = 0; localX < Tile.edge; localX += 1) {
          final int x = entry.key.x * Tile.edge + localX;
          if (x < left || x >= right) {
            continue;
          }
          final int sourceOffset =
              (localY * Tile.edge + localX) * Tile.bytesPerPixel;
          if (entry.value.pixels[sourceOffset + 3] == 0) {
            continue;
          }
          final int destinationOffset =
              ((y - top) * width + x - left) * Tile.bytesPerPixel;
          pixels.setRange(
            destinationOffset,
            destinationOffset + Tile.bytesPerPixel,
            entry.value.pixels,
            sourceOffset,
          );
        }
      }
    }
    final Rect bounds = Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
    return (
      bitmap: raster.RgbaBitmap.fromPremultipliedRgba(
        width: width,
        height: height,
        pixels: pixels,
      ),
      bounds: bounds,
    );
  }

  Future<void> _commitTransform() async {
    final TransformSnapshot? liveSnapshot = _transformTool.snapshot;
    if (liveSnapshot == null) {
      return;
    }
    final InkLayer layer = widget.model.contentLayers.firstWhere(
      (InkLayer candidate) => candidate.id == liveSnapshot.target.layerId,
    );
    if (!widget.model.runLayerAction(layerId: layer.id, action: () {})) {
      return;
    }
    final TransformCommitCommand command = _transformTool.commit();
    final TransformSnapshot snapshot = command.snapshot;
    if (snapshot.target is WholeLayerTransformTarget) {
      final Map<TileKey, Tile> transformedTiles = _renderWholeLayerTransform(
        snapshot,
      );
      final ({Map<TileKey, Tile?> after, Map<TileKey, Tile?> before}) changes =
          _completeLayerTileChanges(layer.id, transformedTiles);
      _disposeTransformPreviewImage();
      final bool committed =
          changes.after.isEmpty ||
          await _commitToolTiles(
            kind: command.journalKind,
            layerId: layer.id,
            afterTiles: changes.after,
            beforeTiles: changes.before,
            bounds: snapshot.target.sourceBounds.expandToInclude(
              _rotatedTransformBounds(snapshot),
            ),
          );
      if (committed) {
        widget.model.toolState.selectTool('draw');
      } else {
        _transformTool.restore(liveSnapshot);
        unawaited(_refreshTransformPreviewImage());
      }
      return;
    }
    final raster.RgbaBitmap before = _documentBitmap(layerId: layer.id);
    final raster.RgbaBitmap source = _transformSourceBitmap(snapshot, before);
    final raster.RgbaBitmap base = switch (snapshot.target) {
      SelectionTransformTarget(:final mask) => _clearBitmapWithMask(
        before,
        mask,
      ),
      WholeLayerTransformTarget() => raster.RgbaBitmap.transparent(
        width: before.width,
        height: before.height,
      ),
    };
    final raster.RgbaBitmap transformed = executeTransform(
      snapshot: snapshot,
      source: source,
      destinationWidth: before.width,
      destinationHeight: before.height,
    );
    final raster.RgbaBitmap after = _sourceOverBitmaps(transformed, base);
    _disposeTransformPreviewImage();
    final bool committed = await _commitBitmapChange(
      kind: command.journalKind,
      layerId: layer.id,
      before: before,
      after: after,
      bounds: snapshot.target.sourceBounds.expandToInclude(
        _rotatedTransformBounds(snapshot),
      ),
    );
    if (committed) {
      switch (snapshot.target) {
        case SelectionTransformTarget(:final mask):
          final SelectionMask? nextMask = _transformedSelectionMask(
            snapshot,
            mask,
          );
          if (nextMask == null) {
            _selectionTool.deselect();
          } else {
            _selectionTool.applyMask(nextMask);
          }
        case WholeLayerTransformTarget():
          _selectionTool.deselect();
      }
      widget.model.toolState.selectTool('draw');
    } else {
      _transformTool.restore(liveSnapshot);
      unawaited(_refreshTransformPreviewImage());
    }
  }

  raster.RgbaBitmap _transformSourceBitmap(
    TransformSnapshot snapshot,
    raster.RgbaBitmap layer,
  ) {
    switch (snapshot.target) {
      case SelectionTransformTarget(:final mask):
        final RgbaFragment fragment = extractSelectionFragment(
          source: layer,
          selection: mask,
          documentId: widget.model.document.id,
          layerId: snapshot.target.layerId,
        );
        return raster.RgbaBitmap.fromPremultipliedRgba(
          width: fragment.width,
          height: fragment.height,
          pixels: fragment.rgbaBytes,
        );
      case WholeLayerTransformTarget(:final sourceBounds):
        final ({raster.RgbaBitmap bitmap, Rect bounds})? sparse =
            _sparseLayerBitmap(snapshot.target.layerId);
        if (sparse == null || sparse.bounds != sourceBounds) {
          throw StateError('Whole-layer transform source changed.');
        }
        return sparse.bitmap;
    }
  }

  Map<TileKey, Tile> _renderWholeLayerTransform(TransformSnapshot snapshot) {
    final ({raster.RgbaBitmap bitmap, Rect bounds})? source =
        _sparseLayerBitmap(snapshot.target.layerId);
    if (source == null || source.bounds != snapshot.target.sourceBounds) {
      throw StateError('Whole-layer transform source changed.');
    }
    final Rect workBounds = source.bounds
        .expandToInclude(_rotatedTransformBounds(snapshot))
        .expandToInclude(snapshot.bounds);
    final int left = workBounds.left.floor();
    final int top = workBounds.top.floor();
    final int right = workBounds.right.ceil();
    final int bottom = workBounds.bottom.ceil();
    final TransformSnapshot localSnapshot = TransformSnapshot(
      target: snapshot.target,
      bounds: snapshot.bounds.shift(Offset(-left.toDouble(), -top.toDouble())),
      rotationRadians: snapshot.rotationRadians,
      resampling: snapshot.resampling,
      isFlippedHorizontally: snapshot.isFlippedHorizontally,
      isFlippedVertically: snapshot.isFlippedVertically,
    );
    final raster.RgbaBitmap transformed = executeTransform(
      snapshot: localSnapshot,
      source: source.bitmap,
      destinationWidth: right - left,
      destinationHeight: bottom - top,
    );
    return _tilesFromPositionedBitmap(transformed, originX: left, originY: top);
  }

  ({Map<TileKey, Tile?> after, Map<TileKey, Tile?> before})
  _completeLayerTileChanges(String layerId, Map<TileKey, Tile> replacement) {
    final Map<TileKey, Tile> current = widget.model.tiles.layerTiles(layerId);
    final Set<TileKey> keys = <TileKey>{...current.keys, ...replacement.keys};
    final Map<TileKey, Tile?> before = <TileKey, Tile?>{};
    final Map<TileKey, Tile?> after = <TileKey, Tile?>{};
    for (final TileKey key in keys) {
      final Tile? oldTile = current[key];
      final Tile? newTile = replacement[key];
      if (newTile == null && oldTile == null ||
          newTile != null && _sameBytes(newTile.pixels, oldTile?.pixels)) {
        continue;
      }
      before[key] = oldTile;
      after[key] = newTile;
    }
    return (after: after, before: before);
  }

  void _cancelTransform() {
    if (_transformTool.hasLiveState) {
      _transformTool.cancel();
    }
    _disposeTransformPreviewImage();
    _transformBodyDrag = false;
  }

  Future<void> _commitCrop() async {
    final CropDraft? draft = _cropTool.draft;
    if (draft == null) {
      return;
    }
    final CropCommand command = _cropTool.commit();
    final JournalDocumentState before = _journalState();
    if (command.newBounds == command.previousBounds) {
      return;
    }
    try {
      await _applyEngineToolOperation(
        buildCropCanvasOperation(
          command: command,
          state: before,
          sequence: widget.model.journal.nextSequence,
          timestampMs: widget.services.clock.nowMilliseconds(),
        ),
      );
    } on Object {
      _cropTool.restoreDraft(draft);
      rethrow;
    }
    _selectionTool.deselect();
    widget.model.toolState.selectTool('draw');
  }

  void _cycleTextSize() {
    const List<double> sizes = <double>[16, 24, 32, 48, 64, 96];
    final Wp5ToolOptions current = widget.model.toolState.wp5Options;
    final double next = sizes.firstWhere(
      (double size) => size > current.textSize,
      orElse: () => sizes.first,
    );
    widget.model.toolState.setWp5Options(current.copyWith(textSize: next));
  }

  void _cycleTextWeight() {
    const List<int> weights = <int>[500, 600, 700, 800];
    final Wp5ToolOptions current = widget.model.toolState.wp5Options;
    final int next = weights.firstWhere(
      (int weight) => weight > current.textWeight,
      orElse: () => weights.first,
    );
    widget.model.toolState.setWp5Options(current.copyWith(textWeight: next));
  }

  void _placeText(Offset point) {
    if (_textTool.hasLiveState) {
      return;
    }
    _syncControllerOptions(widget.model.toolState.wp5Options);
    _textTool.place(point: point);
    _textResizeMode = false;
    _rebuildToolOverlay();
    unawaited(_showTextSheet());
  }

  Future<void> _showTextSheet() async {
    final TextBlockDraft? draft = _textTool.draft;
    if (draft == null || _textSheetOpen || !mounted) {
      return;
    }
    _textSheetOpen = true;
    try {
      await PaperDialogs.showSheet<void>(
        context,
        builder: (BuildContext sheetContext) {
          _textSheetContext = sheetContext;
          return TextInputSheet(
            initialText: draft.text,
            font: draft.options.fontFamily == TextFontFamily.inter
                ? InkTextFontFamily.inter
                : InkTextFontFamily.jetBrainsMono,
            fontSizeDesignPx: draft.options.size,
            fontWeight: _fontWeight(draft.options.weight),
            currentColor: Color(draft.options.colorArgb),
            onChanged: (String value) {
              if (_textTool.hasLiveState) {
                _textTool.updateText(value);
                _rebuildToolOverlay();
              }
            },
            onDone: (String value) {
              if (!_textTool.hasLiveState || value.isEmpty) {
                return;
              }
              _textTool.updateText(value);
              Navigator.of(sheetContext).pop();
              unawaited(_queueToolCommand(CanvasToolCommand.done));
            },
          );
        },
      );
    } finally {
      _textSheetContext = null;
      _textSheetOpen = false;
    }
  }

  Future<void> _toggleTextDone() async {
    if (_textTool.hasLiveState) {
      final BuildContext? sheetContext = _textSheetContext;
      if (sheetContext != null && sheetContext.mounted) {
        Navigator.of(sheetContext).pop();
      }
      await _commitText();
      return;
    }
    final UndoJournal journal = widget.model.journal;
    final bool lastActionIsText =
        journal.cursor > 0 &&
        journal.entries[journal.cursor - 1].kind == JournalKind.text;
    if (_textTool.lastCommit != null && lastActionIsText) {
      await _stepJournal(forward: false);
    }
  }

  Future<void> _commitText() async {
    final InkLayer? layer = _editableActiveLayer();
    final TextBlockDraft? draft = _textTool.draft;
    if (layer == null || draft == null || draft.text.isEmpty) {
      return;
    }
    _strokeFinalizing = true;
    _navigation.setLocked(true);
    try {
      final TextCommitCommand previewCommand = TextCommitCommand(
        layerId: layer.id,
        draft: draft,
      );
      final RgbaFragment fragment = await _rasterizeText(previewCommand, draft);
      if (!identical(_textTool.draft, draft) || _disposed) {
        return;
      }
      final raster.RgbaBitmap before = _documentBitmap(layerId: layer.id);
      final TextCommitCommand command = _textTool.commit(
        activeLayerId: layer.id,
      );
      final raster.RgbaBitmap after = compositeSelectionFloat(
        floatingSelection: SelectionFloat(
          fragment: fragment,
          destinationLayerId: layer.id,
          topLeft: draft.bounds.topLeft,
        ),
        target: before,
      );
      final bool committed = await _commitBitmapChange(
        kind: command.journalKind,
        layerId: layer.id,
        before: before,
        after: after,
        bounds: draft.bounds,
        journalMetadata: <String, Object?>{
          'textMetadata': command.metadata.toJson(),
        },
      );
      if (!committed) {
        _textTool.restoreMetadataForEditing(command.metadata);
        unawaited(_showTextSheet());
      }
      _rebuildToolOverlay();
    } finally {
      _strokeFinalizing = false;
      if (!_disposed) {
        _navigation.setLocked(_activeToolPointer != null);
      }
    }
  }

  Future<RgbaFragment> _rasterizeText(
    TextCommitCommand command,
    TextBlockDraft draft,
  ) async {
    final int width = math.max(1, draft.bounds.width.ceil());
    final int height = math.max(1, draft.bounds.height.ceil());
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: draft.text,
        style: TextStyle(
          color: Color(draft.options.colorArgb),
          fontFamily: draft.options.fontFamily.familyName,
          fontFamilyFallback: const <String>['Arial', 'Menlo', 'sans-serif'],
          fontSize: draft.options.size,
          fontWeight: _fontWeight(draft.options.weight),
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width.toDouble());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder)
      ..clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    painter.paint(canvas, Offset.zero);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        throw StateError('Text rasterization returned no RGBA pixels.');
      }
      final Uint8List rgba = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _premultiplyIfStraight(rgba);
      return RgbaFragment(
        width: width,
        height: height,
        rgba: rgba,
        source: FragmentSourceMetadata(
          documentId: widget.model.document.id,
          layerId: command.layerId,
          sourceBounds: Rect.fromLTWH(
            draft.bounds.left,
            draft.bounds.top,
            width.toDouble(),
            height.toDouble(),
          ),
        ),
      );
    } finally {
      image.dispose();
    }
  }

  void _dismissToolState(String toolId) {
    switch (toolId) {
      case 'select':
        _selectionTool.deselect();
        _selectionFloatClearsSource = false;
        _disposeSelectionFloatImage();
      case 'transform':
        _cancelTransform();
      case 'text':
        _textTool.cancel();
        final BuildContext? sheetContext = _textSheetContext;
        if (sheetContext != null && sheetContext.mounted) {
          Navigator.of(sheetContext).pop();
        }
      case 'crop':
        _cropTool.cancel();
      case 'shape':
        _shapeTool.cancel();
      default:
        break;
    }
    _rebuildToolOverlay();
  }

  JournalDocumentState _journalState() => JournalDocumentState(
    tiles: widget.model.tiles,
    layers: widget.model.contentLayers,
    canvas: widget.model.document.canvas,
  );

  Future<void> _applyEngineToolOperation(
    JournaledEngineOperation operation, {
    String? activeLayerId,
  }) async {
    await widget.model.applyEngineOperation(
      operation,
      activeLayerId: activeLayerId,
    );
    _controller.setDocumentSize(_documentSize);
    _cache?.invalidateAll();
    _requestVisibleCacheSync();
    _repaint.requestRepaint();
    await _enqueueSave(dirtyTiles: null);
  }

  void _finishSelectionGesture(Offset end) {
    final Offset? start = _toolGestureStart;
    if (start == null) {
      return;
    }
    final SelectionRequest? request;
    final SelectionMask? result;
    switch (_selectionTool.options.mode) {
      case SelectionMode.rectangle:
        final Rect rect = Rect.fromPoints(
          start,
          end,
        ).intersect(Offset.zero & _documentSize);
        if (rect.isEmpty || rect.width < 1 || rect.height < 1) {
          return;
        }
        final RectangleSelectionRequest rectangle = _selectionTool
            .requestRectangle(rect);
        request = rectangle;
        result = executeRectangleSelection(rectangle);
      case SelectionMode.lasso:
        final List<Offset> points = List<Offset>.of(_toolGesturePoints);
        if (points.length < 3 || boundsOfPoints(points).isEmpty) {
          return;
        }
        final LassoSelectionRequest lasso = _selectionTool.requestLasso(points);
        request = lasso;
        result = executeLassoSelection(lasso);
      case SelectionMode.wand:
        final WandSelectionRequest wand = _selectionTool.requestWand(
          end,
          layerId: widget.model.document.activeLayerId,
        );
        request = wand;
        result = executeWandSelection(
          request: wand,
          source: _documentBitmap(layerId: wand.layerId),
        );
    }
    _selectionTool.completeRequest(request, result);
  }

  void _collectStrokeEraseHit(Offset point, Duration timestamp) {
    final InkLayer? layer = _activeLayer();
    if (layer == null) {
      return;
    }
    final SelectionMask? selection = _selectionTool.mask;
    if (selection != null &&
        selection.coverageAt(point.dx.floor(), point.dy.floor()) == 0) {
      return;
    }
    final double contactRadius =
        strokeEraserCursorLogicalDiameter / 2 / _controller.scale;
    final Rect contactBounds = Rect.fromCircle(
      center: point,
      radius: contactRadius,
    );
    final List<JournalEntry> candidates = widget.model.journal
        .strokeEraseCandidates(
          layerId: layer.id,
          intersecting: _journalBounds(contactBounds),
        )
        .where(
          (JournalEntry entry) =>
              !_strokeEraseGestureTargets.contains(entry.seq),
        )
        .toList(growable: false);
    final JournalEntry? hit = hitTestTopmostReplayableStroke(
      candidates: candidates,
      contact: LassoPoint(x: point.dx, y: point.dy),
      contactRadius: contactRadius,
      documentWidth: _documentSize.width,
      documentHeight: _documentSize.height,
    );
    if (hit == null || !_strokeEraseGestureTargets.add(hit.seq)) {
      return;
    }
    _eraserTool.strokeKills.addKill(
      StrokeKill(
        layerId: layer.id,
        strokeSequence: hit.seq,
        timestamp: timestamp,
      ),
    );
  }

  Future<void> _performStrokeErase(StrokeEraseBatchRequest request) async {
    if (_disposed || widget.model.isCompositing) {
      return;
    }
    final JournalDocumentState beforeState = _journalState();
    final JournalDocumentState afterState = await widget.model.journal
        .replayWithoutStrokes(
          currentState: beforeState,
          sequences: request.targetSequences,
        );
    if (_disposed) {
      return;
    }
    final Map<int, JournalEntry> entriesBySequence = <int, JournalEntry>{
      for (final JournalEntry entry in widget.model.journal.entries)
        entry.seq: entry,
    };
    final Set<TileKey> keys = <TileKey>{};
    Rect? bounds;
    for (final int sequence in request.targetSequences) {
      final JournalEntry? entry = entriesBySequence[sequence];
      if (entry == null) {
        continue;
      }
      keys.addAll(entry.affectedKeys);
      final JournalBounds? journalBounds = entry.bounds;
      if (journalBounds != null) {
        final Rect entryBounds = Rect.fromLTWH(
          journalBounds.x.toDouble(),
          journalBounds.y.toDouble(),
          journalBounds.width.toDouble(),
          journalBounds.height.toDouble(),
        );
        bounds = bounds == null
            ? entryBounds
            : bounds.expandToInclude(entryBounds);
      }
    }
    final Map<TileKey, Tile?> beforeTiles = <TileKey, Tile?>{};
    final Map<TileKey, Tile?> afterTiles = <TileKey, Tile?>{};
    for (final TileKey key in keys) {
      final Tile? before = beforeState.tiles.tile(request.layerId, key);
      final Tile? after = afterState.tiles.tile(request.layerId, key);
      if (after == null && before == null ||
          after != null && _sameBytes(after.pixels, before?.pixels)) {
        continue;
      }
      beforeTiles[key] = before;
      afterTiles[key] = after;
    }
    if (afterTiles.isEmpty) {
      return;
    }
    await _commitToolTiles(
      kind: request.journalKind,
      layerId: request.layerId,
      afterTiles: afterTiles,
      beforeTiles: beforeTiles,
      bounds: bounds ?? Offset.zero & _documentSize,
      journalMetadata: <String, Object?>{
        'strokeEraseSequences': request.targetSequences,
      },
    );
  }

  Future<void> _performLassoErase(LassoClearRequest request) async {
    final InkLayer? layer = _editableActiveLayer();
    if (layer == null || layer.id != request.layerId) {
      return;
    }
    SelectionMask mask = executeLassoSelection(
      LassoSelectionRequest(
        points: <Offset>[
          for (final LassoPoint point in request.vertices)
            Offset(point.x, point.y),
        ],
        combine: SelectionCombineMode.replace,
      ),
    );
    final SelectionMask? selection = _selectionTool.mask;
    if (selection != null) {
      final Uint8List coverage = mask.coverageBytes;
      for (var y = 0; y < mask.height; y += 1) {
        for (var x = 0; x < mask.width; x += 1) {
          final int index = y * mask.width + x;
          coverage[index] =
              (coverage[index] *
                      selection.coverageAt(mask.left + x, mask.top + y) +
                  127) ~/
              255;
        }
      }
      mask = SelectionMask(
        left: mask.left,
        top: mask.top,
        width: mask.width,
        height: mask.height,
        coverage: coverage,
      );
    }
    if (mask.isEmpty) {
      return;
    }
    final raster.RgbaBitmap before = _documentBitmap(layerId: layer.id);
    final raster.RgbaBitmap after = _clearBitmapWithMask(before, mask);
    await _commitBitmapChange(
      kind: request.journalKind,
      layerId: layer.id,
      before: before,
      after: after,
      bounds: mask.bounds,
      journalMetadata: const <String, Object?>{'eraserMode': 'lasso'},
    );
  }

  Future<void> _performFill(Offset seed) async {
    final InkLayer? layer = _activeLayer();
    if (layer == null || layer.locked || !layer.visible) {
      return;
    }
    try {
      final FillCommand command = _fillTool.tap(
        seed: seed,
        activeLayerId: layer.id,
        selectionClip: _selectionTool.mask,
      );
      final raster.RgbaBitmap result = executeFill(
        command: command,
        activeLayer: _documentBitmap(layerId: layer.id),
        composite: command.options.sampleSource == FillSampleSource.composite
            ? _documentBitmap(composite: true)
            : null,
      );
      final ({Map<TileKey, Tile?> after, Map<TileKey, Tile?> before}) changes =
          _tileChangesFromBitmap(layer.id, result);
      await _commitToolTiles(
        kind: command.journalKind,
        layerId: layer.id,
        afterTiles: changes.after,
        beforeTiles: changes.before,
        bounds: Offset.zero & _documentSize,
      );
    } on Object catch (error) {
      _lastEngineError = error;
      _rebuildToolOverlay();
    }
  }

  Future<void> _performShape(ShapeCommand command) async {
    final InkLayer? layer = _activeLayer();
    final RasterCompositor? compositor = _compositor;
    if (layer == null ||
        layer.locked ||
        !layer.visible ||
        compositor == null ||
        _disposed) {
      return;
    }
    _strokeFinalizing = true;
    _strokeCompletion = Completer<void>();
    try {
      final BrushSpec brush =
          drawingBrushesById[command.brush.brushId] ?? finelinerBrush;
      final StrokeBuffer buffer = StrokeBuffer(documentSize: _documentSize);
      final BrushStampTarget target = _brushTarget(buffer);
      final Rect damage = stampShapeThroughBrush(
        command: command,
        brush: brush,
        target: target,
      );
      final StrokeBufferSnapshot stroke = buffer.seal();
      if (stroke.isEmpty || damage.isEmpty) {
        return;
      }
      final RasterCommitResult rasterResult = await compositor
          .compositeDebugStroke(
            stroke: stroke,
            tiles: widget.model.tiles,
            layerId: layer.id,
            documentSize: _documentSize,
          );
      await _commitToolTiles(
        kind: command.journalKind,
        layerId: layer.id,
        afterTiles: <TileKey, Tile?>{
          for (final MapEntry<TileKey, Tile> entry
              in rasterResult.changedTiles.entries)
            entry.key: entry.value,
        },
        beforeTiles: rasterResult.beforeTiles,
        bounds: damage,
      );
    } on Object catch (error) {
      _lastEngineError = error;
      _rebuildToolOverlay();
    } finally {
      _strokeFinalizing = false;
      final Completer<void>? completion = _strokeCompletion;
      _strokeCompletion = null;
      if (completion != null && !completion.isCompleted) {
        completion.complete();
      }
    }
  }

  raster.RgbaBitmap _documentBitmap({String? layerId, bool composite = false}) {
    assert((layerId == null) == composite);
    final int width = widget.model.document.canvas.width;
    final int height = widget.model.document.canvas.height;
    final Uint8List pixels = Uint8List(width * height * 4);
    final Iterable<InkLayer> layers = widget.model.document.layers;
    for (final TileKey key in tileKeysCoveringRect(
      Offset.zero & _documentSize,
      _documentSize,
    )) {
      final Uint8List? source = composite
          ? compositeVisibleTile(
              key: key,
              layers: layers,
              tiles: widget.model.tiles,
            )
          : widget.model.tiles.tile(layerId!, key)?.pixels;
      if (source == null) {
        continue;
      }
      final int tileLeft = key.x * Tile.edge;
      final int tileTop = key.y * Tile.edge;
      final int copyWidth = math.min(Tile.edge, width - tileLeft);
      final int copyHeight = math.min(Tile.edge, height - tileTop);
      for (var localY = 0; localY < copyHeight; localY += 1) {
        final int sourceOffset = localY * Tile.edge * Tile.bytesPerPixel;
        final int destinationOffset =
            ((tileTop + localY) * width + tileLeft) * Tile.bytesPerPixel;
        pixels.setRange(
          destinationOffset,
          destinationOffset + copyWidth * Tile.bytesPerPixel,
          source,
          sourceOffset,
        );
      }
    }
    return raster.RgbaBitmap.fromPremultipliedRgba(
      width: width,
      height: height,
      pixels: pixels,
    );
  }

  ({Map<TileKey, Tile?> after, Map<TileKey, Tile?> before})
  _tileChangesFromBitmap(String layerId, raster.RgbaBitmap bitmap) {
    final Map<TileKey, Tile?> after = <TileKey, Tile?>{};
    final Map<TileKey, Tile?> before = <TileKey, Tile?>{};
    for (final TileKey key in tileKeysCoveringRect(
      Offset.zero & _documentSize,
      _documentSize,
    )) {
      final Tile? beforeTile = widget.model.tiles.tile(layerId, key);
      final Uint8List output =
          beforeTile?.mutableCopy() ?? Uint8List(Tile.byteLength);
      final int tileLeft = key.x * Tile.edge;
      final int tileTop = key.y * Tile.edge;
      final int copyWidth = math.min(Tile.edge, bitmap.width - tileLeft);
      final int copyHeight = math.min(Tile.edge, bitmap.height - tileTop);
      for (var localY = 0; localY < copyHeight; localY += 1) {
        final int sourceOffset =
            ((tileTop + localY) * bitmap.width + tileLeft) * Tile.bytesPerPixel;
        final int destinationOffset = localY * Tile.edge * Tile.bytesPerPixel;
        output.setRange(
          destinationOffset,
          destinationOffset + copyWidth * Tile.bytesPerPixel,
          bitmap.pixels,
          sourceOffset,
        );
      }
      if (_sameBytes(output, beforeTile?.pixels)) {
        continue;
      }
      final Tile next = Tile.takeOwnership(output);
      before[key] = beforeTile;
      after[key] = next.isTransparent ? null : next;
    }
    return (after: after, before: before);
  }

  Future<bool> _commitBitmapChange({
    required JournalKind kind,
    required String layerId,
    required raster.RgbaBitmap before,
    required raster.RgbaBitmap after,
    required Rect bounds,
    Map<String, Object?> journalMetadata = const <String, Object?>{},
  }) async {
    if (before.width != after.width || before.height != after.height) {
      throw ArgumentError.value(
        (before.width, before.height, after.width, after.height),
        'bitmap dimensions',
        'must match for a tile-local commit',
      );
    }
    final ({Map<TileKey, Tile?> after, Map<TileKey, Tile?> before}) changes =
        _tileChangesFromBitmap(layerId, after);
    if (changes.after.isEmpty) {
      return true;
    }
    return _commitToolTiles(
      kind: kind,
      layerId: layerId,
      afterTiles: changes.after,
      beforeTiles: changes.before,
      bounds: bounds,
      journalMetadata: journalMetadata,
    );
  }

  Map<TileKey, Tile> _tilesFromBitmap(raster.RgbaBitmap bitmap) {
    final Map<TileKey, Tile> result = <TileKey, Tile>{};
    for (final TileKey key in tileKeysCoveringRect(
      Rect.fromLTWH(0, 0, bitmap.width.toDouble(), bitmap.height.toDouble()),
      Size(bitmap.width.toDouble(), bitmap.height.toDouble()),
    )) {
      final Uint8List output = Uint8List(Tile.byteLength);
      final int tileLeft = key.x * Tile.edge;
      final int tileTop = key.y * Tile.edge;
      final int copyWidth = math.min(Tile.edge, bitmap.width - tileLeft);
      final int copyHeight = math.min(Tile.edge, bitmap.height - tileTop);
      for (var localY = 0; localY < copyHeight; localY += 1) {
        final int sourceOffset =
            ((tileTop + localY) * bitmap.width + tileLeft) * Tile.bytesPerPixel;
        final int destinationOffset = localY * Tile.edge * Tile.bytesPerPixel;
        output.setRange(
          destinationOffset,
          destinationOffset + copyWidth * Tile.bytesPerPixel,
          bitmap.pixels,
          sourceOffset,
        );
      }
      final Tile tile = Tile.takeOwnership(output);
      if (!tile.isTransparent) {
        result[key] = tile;
      }
    }
    return result;
  }

  Map<TileKey, Tile> _tilesFromPositionedBitmap(
    raster.RgbaBitmap bitmap, {
    required int originX,
    required int originY,
  }) {
    final Map<TileKey, Uint8List> output = <TileKey, Uint8List>{};
    for (var y = 0; y < bitmap.height; y += 1) {
      final int globalY = originY + y;
      final int tileY = _tileCoordinateForPixel(globalY);
      final int localY = globalY - tileY * Tile.edge;
      for (var x = 0; x < bitmap.width; x += 1) {
        final int sourceOffset = (y * bitmap.width + x) * Tile.bytesPerPixel;
        if (bitmap.pixels[sourceOffset + 3] == 0) {
          continue;
        }
        final int globalX = originX + x;
        final int tileX = _tileCoordinateForPixel(globalX);
        final int localX = globalX - tileX * Tile.edge;
        final TileKey key = TileKey(tileX, tileY);
        final Uint8List tile = output.putIfAbsent(
          key,
          () => Uint8List(Tile.byteLength),
        );
        final int destinationOffset =
            (localY * Tile.edge + localX) * Tile.bytesPerPixel;
        tile.setRange(
          destinationOffset,
          destinationOffset + Tile.bytesPerPixel,
          bitmap.pixels,
          sourceOffset,
        );
      }
    }
    return <TileKey, Tile>{
      for (final MapEntry<TileKey, Uint8List> entry in output.entries)
        entry.key: Tile.takeOwnership(entry.value),
    };
  }

  Map<String, Map<TileKey, Tile?>> _completeRasterSnapshot(
    JournalDocumentState state,
  ) => _completeStateRasterSnapshot(state);

  raster.RgbaBitmap _clearBitmapWithMask(
    raster.RgbaBitmap source,
    SelectionMask mask,
  ) => clearBitmapWithSelectionMask(source: source, selection: mask);

  raster.RgbaBitmap _fillBitmapWithMask(
    raster.RgbaBitmap source,
    SelectionMask mask,
    int colorArgb,
  ) {
    final Uint8List pixels = Uint8List.fromList(source.pixels);
    final int colorAlpha = colorArgb >>> 24;
    final int colorRed = colorArgb >>> 16 & 0xff;
    final int colorGreen = colorArgb >>> 8 & 0xff;
    final int colorBlue = colorArgb & 0xff;
    final int left = math.max(0, mask.left);
    final int top = math.max(0, mask.top);
    final int right = math.min(source.width, mask.left + mask.width);
    final int bottom = math.min(source.height, mask.top + mask.height);
    for (var y = top; y < bottom; y += 1) {
      for (var x = left; x < right; x += 1) {
        final int coverage = mask.coverageAt(x, y);
        final int sourceAlpha = (colorAlpha * coverage + 127) ~/ 255;
        if (sourceAlpha == 0) {
          continue;
        }
        final int inverse = 255 - sourceAlpha;
        final int offset = (y * source.width + x) * 4;
        pixels[offset] =
            (colorRed * sourceAlpha + pixels[offset] * inverse + 127) ~/ 255;
        pixels[offset + 1] =
            (colorGreen * sourceAlpha + pixels[offset + 1] * inverse + 127) ~/
            255;
        pixels[offset + 2] =
            (colorBlue * sourceAlpha + pixels[offset + 2] * inverse + 127) ~/
            255;
        pixels[offset + 3] =
            sourceAlpha + (pixels[offset + 3] * inverse + 127) ~/ 255;
      }
    }
    return raster.RgbaBitmap.fromPremultipliedRgba(
      width: source.width,
      height: source.height,
      pixels: pixels,
    );
  }

  SelectionMask? _selectionMaskForFloat(SelectionFloat floating) {
    final raster.RgbaBitmap transparent = raster.RgbaBitmap.transparent(
      width: widget.model.document.canvas.width,
      height: widget.model.document.canvas.height,
    );
    final raster.RgbaBitmap placed = compositeSelectionFloat(
      floatingSelection: floating,
      target: transparent,
    );
    return _selectionMaskFromBitmapAlpha(placed);
  }

  SelectionMask? _transformedSelectionMask(
    TransformSnapshot snapshot,
    SelectionMask source,
  ) {
    final Uint8List pixels = Uint8List(source.width * source.height * 4);
    for (var y = 0; y < source.height; y += 1) {
      for (var x = 0; x < source.width; x += 1) {
        pixels[(y * source.width + x) * 4 + 3] = source.coverageAt(
          source.left + x,
          source.top + y,
        );
      }
    }
    final raster.RgbaBitmap transformed = executeTransform(
      snapshot: snapshot,
      source: raster.RgbaBitmap.fromPremultipliedRgba(
        width: source.width,
        height: source.height,
        pixels: pixels,
      ),
      destinationWidth: widget.model.document.canvas.width,
      destinationHeight: widget.model.document.canvas.height,
    );
    return _selectionMaskFromBitmapAlpha(transformed);
  }

  SelectionMask? _selectionMaskFromBitmapAlpha(raster.RgbaBitmap bitmap) {
    int? left;
    int? top;
    int? right;
    int? bottom;
    for (var y = 0; y < bitmap.height; y += 1) {
      for (var x = 0; x < bitmap.width; x += 1) {
        if (bitmap.pixels[(y * bitmap.width + x) * 4 + 3] == 0) {
          continue;
        }
        left = left == null ? x : math.min(left, x);
        top = top == null ? y : math.min(top, y);
        right = right == null ? x + 1 : math.max(right, x + 1);
        bottom = bottom == null ? y + 1 : math.max(bottom, y + 1);
      }
    }
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    final int width = right - left;
    final int height = bottom - top;
    final Uint8List coverage = Uint8List(width * height);
    for (var y = top; y < bottom; y += 1) {
      for (var x = left; x < right; x += 1) {
        coverage[(y - top) * width + x - left] =
            bitmap.pixels[(y * bitmap.width + x) * 4 + 3];
      }
    }
    return SelectionMask(
      left: left,
      top: top,
      width: width,
      height: height,
      coverage: coverage,
    );
  }

  raster.RgbaBitmap _sourceOverBitmaps(
    raster.RgbaBitmap front,
    raster.RgbaBitmap back,
  ) {
    if (front.width != back.width || front.height != back.height) {
      throw ArgumentError.value(
        (front.width, front.height, back.width, back.height),
        'bitmap dimensions',
        'must match',
      );
    }
    final Uint8List output = Uint8List.fromList(back.pixels);
    for (var offset = 0; offset < output.length; offset += 4) {
      final int sourceAlpha = front.pixels[offset + 3];
      if (sourceAlpha == 0) {
        continue;
      }
      final int inverse = 255 - sourceAlpha;
      for (var channel = 0; channel < 3; channel += 1) {
        output[offset + channel] =
            front.pixels[offset + channel] +
            (output[offset + channel] * inverse + 127) ~/ 255;
      }
      output[offset + 3] =
          sourceAlpha + (output[offset + 3] * inverse + 127) ~/ 255;
    }
    return raster.RgbaBitmap.fromPremultipliedRgba(
      width: back.width,
      height: back.height,
      pixels: output,
    );
  }

  void _premultiplyIfStraight(Uint8List pixels) {
    var isStraight = false;
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final int alpha = pixels[offset + 3];
      if (pixels[offset] > alpha ||
          pixels[offset + 1] > alpha ||
          pixels[offset + 2] > alpha) {
        isStraight = true;
        break;
      }
    }
    if (!isStraight) {
      return;
    }
    for (var offset = 0; offset < pixels.length; offset += 4) {
      final int alpha = pixels[offset + 3];
      for (var channel = 0; channel < 3; channel += 1) {
        pixels[offset + channel] =
            (pixels[offset + channel] * alpha + 127) ~/ 255;
      }
    }
  }

  FontWeight _fontWeight(InkTextWeight weight) => switch (weight) {
    InkTextWeight.medium => FontWeight.w500,
    InkTextWeight.semiBold => FontWeight.w600,
    InkTextWeight.bold => FontWeight.w700,
    InkTextWeight.extraBold => FontWeight.w800,
  };

  Future<void> _refreshTransformPreviewImage() async {
    _transformPreviewRefreshRequested = true;
    if (_transformPreviewRefreshRunning || _disposed) {
      return;
    }
    _transformPreviewRefreshRunning = true;
    try {
      while (_transformPreviewRefreshRequested && !_disposed) {
        _transformPreviewRefreshRequested = false;
        final TransformSnapshot? snapshot = _transformTool.snapshot;
        if (snapshot == null) {
          return;
        }
        final raster.RgbaBitmap preview;
        if (snapshot.target is WholeLayerTransformTarget) {
          preview = _compositePreviewBitmap(
            layerId: snapshot.target.layerId,
            replacementTiles: _renderWholeLayerTransform(snapshot),
          );
        } else {
          final raster.RgbaBitmap layer = _documentBitmap(
            layerId: snapshot.target.layerId,
          );
          final raster.RgbaBitmap source = _transformSourceBitmap(
            snapshot,
            layer,
          );
          final SelectionTransformTarget target =
              snapshot.target as SelectionTransformTarget;
          final raster.RgbaBitmap base = _clearBitmapWithMask(
            layer,
            target.mask,
          );
          final raster.RgbaBitmap transformed = executeTransform(
            snapshot: snapshot,
            source: source,
            destinationWidth: layer.width,
            destinationHeight: layer.height,
          );
          preview = _compositePreviewBitmap(
            layerId: snapshot.target.layerId,
            replacement: _sourceOverBitmaps(transformed, base),
          );
        }
        final int generation = ++_previewImageGeneration;
        final ui.Image image = await _imageFromBitmap(preview);
        if (_disposed ||
            generation != _previewImageGeneration ||
            _transformTool.snapshot == null ||
            _transformPreviewRefreshRequested) {
          image.dispose();
          continue;
        }
        _transformPreviewImage?.dispose();
        _transformPreviewImage = image;
        _rebuildToolOverlay();
      }
    } on Object catch (error) {
      if (!_disposed) {
        _lastEngineError = error;
      }
    } finally {
      _transformPreviewRefreshRunning = false;
    }
  }

  Future<void> _refreshSelectionFloatImage() async {
    _selectionPreviewRefreshRequested = true;
    if (_selectionPreviewRefreshRunning || _disposed) {
      return;
    }
    _selectionPreviewRefreshRunning = true;
    try {
      while (_selectionPreviewRefreshRequested && !_disposed) {
        _selectionPreviewRefreshRequested = false;
        final SelectionFloat? floating = _selectionTool.floatingSelection;
        if (floating == null) {
          return;
        }
        final raster.RgbaBitmap before = _documentBitmap(
          layerId: floating.destinationLayerId,
        );
        raster.RgbaBitmap base = before;
        final SelectionMask? mask = _selectionTool.mask;
        if (_selectionFloatClearsSource && mask != null) {
          base = _clearBitmapWithMask(base, mask);
        }
        final raster.RgbaBitmap previewLayer = compositeSelectionFloat(
          floatingSelection: floating,
          target: base,
          sampling: resampler.RasterSampling.nearest,
        );
        final raster.RgbaBitmap preview = _compositePreviewBitmap(
          layerId: floating.destinationLayerId,
          replacement: previewLayer,
        );
        final int generation = ++_previewImageGeneration;
        final ui.Image image = await _imageFromBitmap(preview);
        if (_disposed ||
            generation != _previewImageGeneration ||
            _selectionTool.floatingSelection == null ||
            _selectionPreviewRefreshRequested) {
          image.dispose();
          continue;
        }
        _selectionFloatImage?.dispose();
        _selectionFloatImage = image;
        _rebuildToolOverlay();
      }
    } on Object catch (error) {
      if (!_disposed) {
        _lastEngineError = error;
      }
    } finally {
      _selectionPreviewRefreshRunning = false;
    }
  }

  raster.RgbaBitmap _compositePreviewBitmap({
    required String layerId,
    raster.RgbaBitmap? replacement,
    Map<TileKey, Tile>? replacementTiles,
  }) {
    if ((replacement == null) == (replacementTiles == null)) {
      throw ArgumentError(
        'Exactly one replacement bitmap or tile map is required.',
      );
    }
    final TileStore previewTiles = widget.model.tiles.fork()
      ..replaceLayer(
        layerId,
        replacementTiles ?? _tilesFromBitmap(replacement!),
      );
    final int width = widget.model.document.canvas.width;
    final int height = widget.model.document.canvas.height;
    final Uint8List pixels = Uint8List(width * height * 4);
    for (var offset = 0; offset < pixels.length; offset += 4) {
      pixels[offset] = 255;
      pixels[offset + 1] = 255;
      pixels[offset + 2] = 255;
      pixels[offset + 3] = 255;
    }
    for (final TileKey key in tileKeysCoveringRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Size(width.toDouble(), height.toDouble()),
    )) {
      final Uint8List composite = compositeVisibleTile(
        key: key,
        layers: widget.model.document.layers,
        tiles: previewTiles,
      );
      final int tileLeft = key.x * Tile.edge;
      final int tileTop = key.y * Tile.edge;
      final int copyWidth = math.min(Tile.edge, width - tileLeft);
      final int copyHeight = math.min(Tile.edge, height - tileTop);
      for (var localY = 0; localY < copyHeight; localY += 1) {
        for (var localX = 0; localX < copyWidth; localX += 1) {
          final int sourceOffset =
              (localY * Tile.edge + localX) * Tile.bytesPerPixel;
          final int destinationOffset =
              ((tileTop + localY) * width + tileLeft + localX) *
              Tile.bytesPerPixel;
          final int inverseAlpha = 255 - composite[sourceOffset + 3];
          pixels[destinationOffset] = composite[sourceOffset] + inverseAlpha;
          pixels[destinationOffset + 1] =
              composite[sourceOffset + 1] + inverseAlpha;
          pixels[destinationOffset + 2] =
              composite[sourceOffset + 2] + inverseAlpha;
        }
      }
    }
    return raster.RgbaBitmap.fromPremultipliedRgba(
      width: width,
      height: height,
      pixels: pixels,
    );
  }

  Future<ui.Image> _imageFromBitmap(raster.RgbaBitmap bitmap) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bitmap.pixels,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: bitmap.width,
      height: bitmap.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Rect _selectionFloatBounds(SelectionFloat floating) => Rect.fromLTWH(
    floating.topLeft.dx,
    floating.topLeft.dy,
    floating.fragment.width * floating.scaleX.abs(),
    floating.fragment.height * floating.scaleY.abs(),
  );

  Rect _rotatedTransformBounds(TransformSnapshot snapshot) {
    if (snapshot.rotationRadians == 0) {
      return snapshot.bounds;
    }
    final double cosine = math.cos(snapshot.rotationRadians);
    final double sine = math.sin(snapshot.rotationRadians);
    final Offset center = snapshot.bounds.center;
    final List<Offset> corners =
        <Offset>[
              snapshot.bounds.topLeft,
              snapshot.bounds.topRight,
              snapshot.bounds.bottomRight,
              snapshot.bounds.bottomLeft,
            ]
            .map((Offset point) {
              final Offset delta = point - center;
              return center +
                  Offset(
                    delta.dx * cosine - delta.dy * sine,
                    delta.dx * sine + delta.dy * cosine,
                  );
            })
            .toList(growable: false);
    return boundsOfPoints(corners);
  }

  void _disposeTransformPreviewImage() {
    _previewImageGeneration += 1;
    _transformPreviewImage?.dispose();
    _transformPreviewImage = null;
  }

  void _disposeSelectionFloatImage() {
    _previewImageGeneration += 1;
    _selectionFloatImage?.dispose();
    _selectionFloatImage = null;
  }

  int? _sampleVisibleArgb(int x, int y) {
    final int width = widget.model.document.canvas.width;
    final int height = widget.model.document.canvas.height;
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return null;
    }
    final TileKey key = TileKey(x ~/ Tile.edge, y ~/ Tile.edge);
    final Uint8List pixels =
        _cache?.lookup(key)?.pixels ??
        compositeVisibleTile(
          key: key,
          layers: widget.model.document.layers,
          tiles: widget.model.tiles,
        );
    final int offset =
        ((y - key.y * Tile.edge) * Tile.edge + x - key.x * Tile.edge) *
        Tile.bytesPerPixel;
    final int alpha = pixels[offset + 3];
    final int inverseAlpha = 255 - alpha;
    final int red = (pixels[offset] + inverseAlpha).clamp(0, 255);
    final int green = (pixels[offset + 1] + inverseAlpha).clamp(0, 255);
    final int blue = (pixels[offset + 2] + inverseAlpha).clamp(0, 255);
    return 0xff000000 | red << 16 | green << 8 | blue;
  }

  Future<bool> _commitToolTiles({
    required JournalKind kind,
    required String layerId,
    required Map<TileKey, Tile?> afterTiles,
    required Map<TileKey, Tile?> beforeTiles,
    required Rect bounds,
    Map<String, Object?> journalMetadata = const <String, Object?>{},
  }) async {
    final CompositeTileCache? cache = _cache;
    if (afterTiles.isEmpty ||
        cache == null ||
        _disposed ||
        widget.model.isCompositing) {
      return false;
    }
    widget.model.beginCommit();
    var published = false;
    var journalCommitted = false;
    try {
      widget.model.tiles.publishAll(layerId, afterTiles);
      published = true;
      cache.invalidateTiles(afterTiles.keys);
      final JournalEntry entry = buildToolTileJournalEntry(
        sequence: widget.model.journal.nextSequence,
        timestampMs: widget.services.clock.nowMilliseconds(),
        kind: kind,
        layerId: layerId,
        bounds: bounds.intersect(Offset.zero & _documentSize),
        beforeTiles: beforeTiles,
        afterTiles: afterTiles,
        metadata: journalMetadata,
      );
      await widget.model.journal.commit(
        entry,
        checkpointStore: widget.model.tiles,
      );
      journalCommitted = true;
      final InkDocument committed = _documentWithCurrentTiles().copyWith(
        modifiedAtMs: widget.services.clock.nowMilliseconds(),
        journalHeadSeq: widget.model.journal.headSeq,
      );
      widget.model.finishCommit(document: committed);
      await cache.ensureTiles(
        keys: afterTiles.keys,
        document: committed,
        tiles: widget.model.tiles,
      );
      _requestVisibleCacheSync();
      _repaint.requestRepaint();
      await _enqueueSave(
        dirtyTiles: <TileLocation>[
          for (final TileKey key in afterTiles.keys)
            TileLocation(layerId: layerId, key: key),
        ],
      );
      return true;
    } on Object catch (error) {
      _lastEngineError = error;
      if (!journalCommitted && published) {
        widget.model.tiles.publishAll(layerId, beforeTiles);
        cache.invalidateTiles(beforeTiles.keys);
      }
      if (widget.model.isCompositing) {
        if (journalCommitted) {
          widget.model.finishCommit(
            document: _documentWithCurrentTiles().copyWith(
              modifiedAtMs: widget.services.clock.nowMilliseconds(),
              journalHeadSeq: widget.model.journal.headSeq,
            ),
          );
        } else {
          widget.model.abandonCommit();
        }
      }
      if (journalCommitted && !widget.model.isCompositing) {
        unawaited(_enqueueSave(dirtyTiles: null));
      }
      _requestVisibleCacheSync();
      _repaint.requestRepaint();
      return false;
    }
  }

  BrushStampTarget _brushTarget(StrokeBuffer buffer) {
    BrushStampTarget target = _StrokeBufferBrushTarget(
      buffer,
      widget.model.toolState.flow,
      selection: _selectionTool.mask,
    );
    final SymmetryConfiguration symmetry = _symmetryConfiguration();
    if (symmetry.mode != SymmetryMode.off) {
      target = SymmetryBrushStampTarget(
        target: target,
        configuration: symmetry,
      );
    }
    return target;
  }

  SymmetryConfiguration _symmetryConfiguration() {
    final InkSymmetryMode mode = widget.model.toolState.wp5Options.symmetryMode;
    return SymmetryConfiguration(
      mode: switch (mode) {
        InkSymmetryMode.off => SymmetryMode.off,
        InkSymmetryMode.vertical => SymmetryMode.vertical,
        InkSymmetryMode.horizontal => SymmetryMode.horizontal,
        InkSymmetryMode.quad => SymmetryMode.quad,
      },
      axisX: _documentSize.width / 2,
      axisY: _documentSize.height / 2,
    );
  }

  Offset _strokeDocumentPoint(Offset viewportPoint) {
    final Offset point = _controller.docFromViewport(viewportPoint);
    final Wp5ToolOptions options = widget.model.toolState.wp5Options;
    final Offset? start = _straightedgeStartDocument;
    final Offset? end = _straightedgeEndDocument;
    if (!options.straightedgeEnabled ||
        start == null ||
        end == null ||
        start == end) {
      return point;
    }
    final Offset direction = end - start;
    final double projection =
        ((point.dx - start.dx) * direction.dx +
            (point.dy - start.dy) * direction.dy) /
        direction.distanceSquared;
    final Offset onLine = start + direction * projection;
    return (point - onLine).distance * _controller.scale <= 24 ? onLine : point;
  }

  void _beginStroke({
    required int pointer,
    required Offset viewportPoint,
    required double pressure,
    required Offset tilt,
    required Duration timestamp,
    required bool isTouch,
  }) {
    final InkLayer? activeLayer = _activeLayer();
    final String activeToolId = widget.model.toolState.activeToolId;
    if (_disposed ||
        _compositor == null ||
        _cache == null ||
        widget.model.isCompositing ||
        _quiescing ||
        _strokeFinalizing ||
        _pendingHistoryActions != 0 ||
        _pendingToolCommands != 0 ||
        _activeStrokePointer != null ||
        _activeToolPointer != null ||
        activeToolId != 'draw' && activeToolId != 'erase' ||
        activeLayer == null ||
        activeLayer.locked ||
        !activeLayer.visible) {
      return;
    }
    _activeStrokePointer = pointer;
    _activeStrokeIsTouch = isTouch;
    _strokeLayerId = activeLayer.id;
    _strokeCompletion = Completer<void>();
    final BrushSpec brush = _effectiveBrushSpec();
    final StrokeBuffer buffer = StrokeBuffer(documentSize: _documentSize);
    final _ActiveBrushStroke session = _ActiveBrushStroke(
      spec: brush,
      target: _brushTarget(buffer),
      seed: widget.model.journal.nextSequence,
      colorArgb: _parseBrushColor(widget.model.toolState.color),
      size: _effectiveBrushSize(brush),
      transform: _currentRecipeTransform(),
      flowMultiplier: widget.model.toolState.flow,
      symmetryMode: widget.model.toolState.wp5Options.symmetryMode,
      selectionClipped: _selectionTool.mask != null,
    );
    _strokeBuffer = buffer;
    _strokeSession = session;
    _overlay.configure(
      alphaCutoff: brush.previewAlphaCutoff,
      previewColorArgb: brush.blend.isClear ? 0xffffffff : 0xff000000,
      outline: brush.preview == PreviewStyle.outline,
    );
    _navigation.setLocked(true);
    _controller.lockForStroke();
    final Rect damage = session.begin(
      StrokeSample(
        point: _strokeDocumentPoint(viewportPoint),
        pressure: pressure.clamp(0.0, 1.0),
        tilt: tilt,
        timestamp: timestamp,
      ),
    );
    _queueOverlayDamage(damage);
  }

  InkLayer? _activeLayer() {
    final String activeId = widget.model.document.activeLayerId;
    for (final InkLayer layer in widget.model.document.layers) {
      if (layer.id == activeId) {
        return layer;
      }
    }
    return null;
  }

  BrushSpec _effectiveBrushSpec() {
    if (widget.model.toolState.activeToolId == 'erase') {
      return eraserPixelBrush;
    }
    return drawingBrushesById[widget.model.toolState.brushId] ?? finelinerBrush;
  }

  double _effectiveBrushSize(BrushSpec brush) => widget.model.toolState.size
      .clamp(brush.sizeMin, brush.sizeMax)
      .toDouble();

  List<double> _currentRecipeTransform() {
    final Float64List matrix = _controller.viewMatrix.storage;
    return <double>[
      matrix[0],
      matrix[1],
      matrix[4],
      matrix[5],
      matrix[12],
      matrix[13],
    ];
  }

  void _appendStrokePoint({
    required int pointer,
    required Offset viewportPoint,
    required double pressure,
    required Offset tilt,
    required Duration timestamp,
  }) {
    final _ActiveBrushStroke? session = _strokeSession;
    if (_activeStrokePointer != pointer || session == null) {
      return;
    }
    final Rect damage = session.add(
      StrokeSample(
        point: _strokeDocumentPoint(viewportPoint),
        pressure: pressure.clamp(0.0, 1.0),
        tilt: tilt,
        timestamp: timestamp,
      ),
    );
    _queueOverlayDamage(damage);
  }

  void _queueOverlayDamage(Rect damage) {
    if (_disposed || damage.isEmpty || _strokeBuffer == null) {
      return;
    }
    _pendingOverlayDamage = _pendingOverlayDamage == null
        ? damage
        : _pendingOverlayDamage!.expandToInclude(damage);
    _scheduleOverlayFrame();
  }

  void _scheduleOverlayFrame() {
    if (_disposed || _overlayFrameScheduled != null || _overlayDrain != null) {
      return;
    }
    final Completer<void> scheduled = Completer<void>();
    _overlayFrameScheduled = scheduled;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_uploadOverlayFrame(scheduled));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _uploadOverlayFrame(Completer<void> scheduled) async {
    try {
      final Rect? damage = _pendingOverlayDamage;
      _pendingOverlayDamage = null;
      final StrokeBuffer? buffer = _strokeBuffer;
      if (!_disposed && damage != null && buffer != null) {
        final Future<void> upload = _overlay.refreshBuffer(
          buffer,
          changedBounds: damage,
        );
        _overlayDrain = upload;
        await upload;
        if (!_disposed) {
          _repaint.requestRepaint();
        }
      }
    } on Object catch (error) {
      if (!_disposed) {
        _lastEngineError = error;
      }
    } finally {
      _overlayDrain = null;
      if (!scheduled.isCompleted) {
        scheduled.complete();
      }
      if (identical(_overlayFrameScheduled, scheduled)) {
        _overlayFrameScheduled = null;
      }
      if (!_disposed && _pendingOverlayDamage != null) {
        _scheduleOverlayFrame();
      }
    }
  }

  Future<void> _flushOverlayDamage() async {
    while (_overlayFrameScheduled != null || _overlayDrain != null) {
      final Completer<void>? scheduled = _overlayFrameScheduled;
      if (scheduled != null) {
        await scheduled.future;
      } else {
        await _overlayDrain;
      }
    }
  }

  Future<void> _commitStroke(int pointer) async {
    final StrokeBuffer? buffer = _strokeBuffer;
    final _ActiveBrushStroke? session = _strokeSession;
    if (_activeStrokePointer != pointer || buffer == null || session == null) {
      return;
    }
    final String? layerId = _strokeLayerId;
    if (layerId == null) {
      _cancelStroke(pointer);
      return;
    }
    _strokeFinalizing = true;
    _activeStrokePointer = null;
    _activeStrokeIsTouch = false;
    try {
      _queueOverlayDamage(session.end());
      if (session.spec.quantizeLevels > 0) {
        buffer.quantizeAlphaLevels(session.spec.quantizeLevels);
        _queueOverlayDamage(buffer.inkBounds);
      }
    } on Object catch (error) {
      _lastEngineError = error;
      _finishStrokePresentation();
      return;
    }
    final StrokeBufferSnapshot stroke = buffer.seal();
    await _flushOverlayDamage();
    if (stroke.isEmpty) {
      _finishStrokePresentation();
      return;
    }

    final RasterCompositor? compositor = _compositor;
    final CompositeTileCache? cache = _cache;
    if (compositor == null || cache == null || _disposed) {
      _finishStrokePresentation();
      return;
    }

    widget.model.beginCommit();
    var published = false;
    var journalCommitted = false;
    Map<TileKey, Tile?>? afterTiles;
    Map<TileKey, Tile?>? beforeTiles;
    try {
      if (session.spec.blend.isClear) {
        final ClearCompositeResult clear = compositeClearMask(
          tiles: widget.model.tiles,
          layerId: layerId,
          candidateKeys: tileKeysCoveringRect(stroke.inkBounds, _documentSize),
          maskPixels: stroke.pixels,
          maskOriginX: stroke.originX,
          maskOriginY: stroke.originY,
          maskWidth: stroke.width,
          maskHeight: stroke.height,
        );
        afterTiles = clear.afterTiles;
        beforeTiles = clear.beforeTiles;
      } else {
        final RasterCommitResult result = await compositor.compositeDebugStroke(
          stroke: stroke,
          tiles: widget.model.tiles,
          layerId: layerId,
          documentSize: _documentSize,
        );
        afterTiles = <TileKey, Tile?>{
          for (final MapEntry<TileKey, Tile> tile
              in result.changedTiles.entries)
            tile.key: tile.value,
        };
        beforeTiles = result.beforeTiles;
      }
      if (_disposed) {
        return;
      }
      if (afterTiles.isEmpty) {
        widget.model.abandonCommit();
        _finishStrokePresentation();
        return;
      }

      widget.model.tiles.publishAll(layerId, afterTiles);
      published = true;
      cache.invalidateTiles(afterTiles.keys);

      final JournalEntry entry = JournalEntry(
        seq: widget.model.journal.nextSequence,
        timestampMs: widget.services.clock.nowMilliseconds(),
        kind: session.spec.blend.isClear
            ? JournalKind.erase
            : JournalKind.stroke,
        layerId: layerId,
        bounds: _journalBounds(stroke.inkBounds),
        recipe: StrokeRecipe(
          brushId: session.spec.id,
          colorArgb: session.colorArgb,
          size: session.size,
          seed: session.seed,
          transform: session.transform,
          samples: session.recipeSamples,
        ),
        unknownFields: <String, Object?>{
          'strokeReplayVersion': 1,
          'strokeFlow': session.flowMultiplier,
          'strokeSymmetry': session.symmetryMode.name,
          'strokeSelectionClipped': session.selectionClipped,
        },
        affectedKeys: afterTiles.keys,
        beforeTiles: beforeTiles,
        afterTiles: afterTiles,
      );
      await widget.model.journal.commit(
        entry,
        checkpointStore: widget.model.tiles,
      );
      journalCommitted = true;

      final InkDocument committed = _documentWithCurrentTiles().copyWith(
        modifiedAtMs: widget.services.clock.nowMilliseconds(),
        journalHeadSeq: widget.model.journal.headSeq,
      );
      widget.model.finishCommit(document: committed);
      await cache.ensureTiles(
        keys: afterTiles.keys,
        document: committed,
        tiles: widget.model.tiles,
      );
      _finishStrokePresentation();
      final Iterable<TileLocation> dirty = <TileLocation>[
        for (final TileKey key in afterTiles.keys)
          TileLocation(layerId: layerId, key: key),
      ];
      await _enqueueSave(dirtyTiles: dirty);
    } on Object catch (error) {
      _lastEngineError = error;
      if (!journalCommitted && published && beforeTiles != null) {
        widget.model.tiles.publishAll(layerId, beforeTiles);
        cache.invalidateTiles(beforeTiles.keys);
        _requestVisibleCacheSync();
      }
      if (widget.model.isCompositing) {
        if (journalCommitted) {
          final InkDocument committed = _documentWithCurrentTiles().copyWith(
            modifiedAtMs: widget.services.clock.nowMilliseconds(),
            journalHeadSeq: widget.model.journal.headSeq,
          );
          widget.model.finishCommit(document: committed);
        } else {
          widget.model.abandonCommit();
        }
      }
      if (journalCommitted && !widget.model.isCompositing) {
        unawaited(_enqueueSave(dirtyTiles: null));
      }
      _finishStrokePresentation();
    }
  }

  void _cancelStroke(int pointer) {
    if (_activeStrokePointer != pointer) {
      return;
    }
    _strokeSession?.cancel();
    _activeStrokePointer = null;
    _activeStrokeIsTouch = false;
    _finishStrokePresentation();
  }

  void _finishStrokePresentation() {
    _strokeFinalizing = false;
    _strokeLayerId = null;
    _strokeBuffer = null;
    _strokeSession = null;
    _pendingOverlayDamage = null;
    final Completer<void>? strokeCompletion = _strokeCompletion;
    _strokeCompletion = null;
    if (strokeCompletion != null && !strokeCompletion.isCompleted) {
      strokeCompletion.complete();
    }
    if (!_disposed) {
      _overlay.clear();
      _controller.unlockAfterStrokeCommit();
      final Size? pendingViewport = _pendingViewportSize;
      if (pendingViewport != null) {
        _controller.setViewportSize(pendingViewport);
        if (_controller.viewportSize == pendingViewport) {
          _viewportSize = pendingViewport;
          _pendingViewportSize = null;
        }
      }
      _navigation.setLocked(false);
      _repaint.requestRepaint();
      _requestVisibleCacheSync();
    }
  }

  Future<void> _undo() => _queueHistory(forward: false);

  Future<void> _redo() => _queueHistory(forward: true);

  Future<void> _queueHistory({required bool forward}) {
    if (_disposed || _quiescing) {
      return Future<void>.value();
    }
    final Completer<void> completion = Completer<void>();
    _pendingHistoryActions += 1;
    final Future<void> pendingHistory = _historyTail;
    final Future<void> pendingTools = _toolCommandTail;
    _historyTail =
        Future.wait<void>(<Future<void>>[
          pendingHistory,
          pendingTools,
        ]).then<void>((_) async {
          try {
            final Future<void>? strokeDone = _strokeCompletion?.future;
            if (strokeDone != null) {
              await strokeDone;
            }
            if (_disposed || widget.model.isCompositing) {
              return;
            }
            await _stepJournal(forward: forward);
          } on Object catch (error) {
            if (!_disposed) {
              _lastEngineError = error;
            }
          } finally {
            _pendingHistoryActions -= 1;
            if (!completion.isCompleted) {
              completion.complete();
            }
          }
        });
    return completion.future;
  }

  Future<void> _stepJournal({required bool forward}) async {
    if (_disposed) {
      return;
    }
    final JournalDocumentState state = JournalDocumentState(
      tiles: widget.model.tiles,
      layers: widget.model.document.layers,
      canvas: widget.model.document.canvas,
    );
    final JournalStep? step = forward
        ? await widget.model.journal.redo(state)
        : await widget.model.journal.undo(state);
    if (step == null || _disposed) {
      return;
    }
    final TileStore destination = widget.model.tiles;
    final String? layerId = step.entry.layerId;
    final bool isTileLocal =
        layerId != null &&
        step.entry.affectedKeys.isNotEmpty &&
        !step.entry.completeLayerSnapshots;
    Iterable<TileLocation>? dirtyTiles;
    if (isTileLocal) {
      for (final TileKey key in step.entry.affectedKeys) {
        destination.publish(layerId, key, step.state.tiles.tile(layerId, key));
      }
      _cache?.invalidateTiles(step.entry.affectedKeys);
      dirtyTiles = <TileLocation>[
        for (final TileKey key in step.entry.affectedKeys)
          TileLocation(layerId: layerId, key: key),
      ];
    } else {
      destination.clear();
      for (final TileLocation location in step.state.tiles.locations) {
        destination.publish(
          location.layerId,
          location.key,
          step.state.tiles.tile(location.layerId, location.key),
        );
      }
      _cache?.invalidateAll();
    }
    final List<InkLayer> nextLayers = step.state.layers;
    final String currentActiveLayerId = widget.model.document.activeLayerId;
    final String resolvedActiveLayerId =
        resolveCanvasActiveLayerAfterJournalStep(
          layers: nextLayers,
          currentActiveLayerId: currentActiveLayerId,
          entry: step.entry,
          forward: forward,
        );
    final InkDocument document = widget.model.document.copyWith(
      canvas: step.state.canvas,
      layers: nextLayers,
      activeLayerId: resolvedActiveLayerId,
      modifiedAtMs: widget.services.clock.nowMilliseconds(),
      journalHeadSeq: widget.model.journal.headSeq,
    );
    widget.model.publishDocument(document);
    if (step.entry.kind == JournalKind.text) {
      if (forward) {
        _textTool.cancel();
      } else {
        final String? textLayerId = step.entry.layerId;
        if (textLayerId != null &&
            nextLayers.any((InkLayer layer) => layer.id == textLayerId)) {
          widget.model.selectActiveLayer(textLayerId);
        }
        widget.model.toolState.selectTool('text');
        final Object? rawMetadata = step.entry.unknownFields['textMetadata'];
        final bool restored = rawMetadata is Map<String, Object?>
            ? () {
                _textTool.restoreMetadataForEditing(
                  TextJournalMetadata.fromJson(rawMetadata),
                );
                return true;
              }()
            : _textTool.restoreLastCommitForEditing();
        if (restored) {
          _rebuildToolOverlay();
          unawaited(_showTextSheet());
        }
      }
    }
    widget.onHistoryFeedback?.call(
      CanvasHistoryFeedback(isRedo: forward, kind: step.entry.kind),
    );
    _controller.setDocumentSize(
      Size(
        step.state.canvas.width.toDouble(),
        step.state.canvas.height.toDouble(),
      ),
    );
    _requestVisibleCacheSync();
    _repaint.requestRepaint();
    await _enqueueSave(dirtyTiles: dirtyTiles);
  }

  InkDocument _documentWithCurrentTiles() {
    return widget.model.document.copyWith(
      layers: <InkLayer>[
        for (final InkLayer layer in widget.model.document.layers)
          layer.copyWith(tiles: widget.model.tiles.occupiedKeys(layer.id)),
      ],
    );
  }

  void _fitCanvas() {
    if (_disposed || _quiescing || _controller.strokeLocked) {
      return;
    }
    _controller.fitToViewport(padding: PaperSpacing.space16);
    _settleView();
    _zoomCycleIndex = 1;
  }

  void _cycleZoom() {
    if (_disposed || _quiescing || _controller.strokeLocked) {
      return;
    }
    switch (_zoomCycleIndex) {
      case 0:
        _controller.fitToViewport(padding: PaperSpacing.space16);
        _zoomCycleIndex = 1;
      case 1:
        _controller.resetScale();
        _zoomCycleIndex = 2;
      default:
        final InkViewState? manual = _lastManualView;
        if (manual == null) {
          _controller.fitToViewport(padding: PaperSpacing.space16);
        } else {
          _controller.setView(
            translation: Offset(manual.tx, manual.ty),
            scale: manual.scale,
            rotation: manual.rotationDeg * math.pi / 180,
            snapScale: false,
          );
        }
        _zoomCycleIndex = 0;
    }
    widget.model.setViewState(_controller.toViewState());
    _requestVisibleCacheSync();
    unawaited(_enqueueSave(dirtyTiles: const <TileLocation>[]));
  }

  void _resetRotation() {
    if (_disposed || _quiescing || _controller.strokeLocked) {
      return;
    }
    _controller.resetRotation();
    widget.model.setViewState(_controller.toViewState());
    _requestVisibleCacheSync();
    unawaited(_enqueueSave(dirtyTiles: const <TileLocation>[]));
  }

  void _refreshExternalRaster() {
    if (_disposed) {
      return;
    }
    _controller.setDocumentSize(_documentSize);
    _cache?.invalidateAll();
    _requestVisibleCacheSync();
    _repaint.requestRepaint();
  }

  Future<void> _saveNow() async {
    if (_disposed) {
      return;
    }
    _quiescing = true;
    _navigation.setLocked(true);
    try {
      final Future<void>? strokeDone = _strokeCompletion?.future;
      if (strokeDone != null) {
        await strokeDone;
      }
      await _toolCommandTail;
      await _historyTail;
      await _saveTail;
      await _enqueueSave(dirtyTiles: null);
    } finally {
      if (!_disposed) {
        _quiescing = false;
        _navigation.setLocked(
          _activeStrokePointer != null || _activeToolPointer != null,
        );
      }
    }
  }

  Future<void> _enqueueSave({Iterable<TileLocation>? dirtyTiles}) {
    final int generation = ++_saveGeneration;
    final List<TileLocation>? dirtySnapshot = dirtyTiles?.toList(
      growable: false,
    );
    final InkDocument snapshot = widget.model.documentSnapshot;
    final TileStore frozenTiles = widget.model.tiles.fork();
    _saveTail = _saveTail.then<void>((_) async {
      try {
        final InkDocument persisted = await widget.services.store.saveDocument(
          snapshot,
          frozenTiles,
          dirtyTiles: dirtySnapshot,
        );
        if (!_disposed && generation == _saveGeneration) {
          widget.model.markSaved(persisted);
        }
      } on Object catch (error) {
        _lastEngineError = error;
      }
    });
    return _saveTail;
  }

  List<Widget> _toolOverlays() => <Widget>[
    if (_selectionFloatOverlay() case final Widget overlay) overlay,
    if (_transformContentOverlay() case final Widget overlay) overlay,
    if (_guidesOverlay() case final Widget overlay) overlay,
    if (_selectionOverlay() case final Widget overlay) overlay,
    if (_shapeOverlay() case final Widget overlay) overlay,
    if (_cropOverlay() case final Widget overlay) overlay,
    if (_transformOverlay() case final Widget overlay) overlay,
    if (_textOverlay() case final Widget overlay) overlay,
    if (_eyedropperOverlay() case final Widget overlay) overlay,
  ];

  Widget? _selectionOverlay() {
    Path? documentPath;
    final SelectionMask? mask = _selectionTool.mask;
    if (mask != null) {
      documentPath = Path()..addRect(mask.bounds);
    }
    if (_activeInteractionToolId == 'select' &&
        _toolGestureStart != null &&
        _toolGesturePoints.isNotEmpty) {
      final Offset start = _toolGestureStart!;
      final Offset end = _toolGesturePoints.last;
      switch (_selectionTool.options.mode) {
        case SelectionMode.rectangle:
          documentPath = Path()..addRect(Rect.fromPoints(start, end));
        case SelectionMode.lasso:
          if (_toolGesturePoints.length >= 2) {
            documentPath = Path()
              ..moveTo(
                _toolGesturePoints.first.dx,
                _toolGesturePoints.first.dy,
              );
            for (final Offset point in _toolGesturePoints.skip(1)) {
              documentPath.lineTo(point.dx, point.dy);
            }
            if (_toolGesturePoints.length >= 3) {
              documentPath.close();
            }
          }
        case SelectionMode.wand:
          break;
      }
    }
    if (_activeInteractionToolId == 'eraseLasso' &&
        _toolGesturePoints.length >= 2) {
      documentPath = Path()
        ..moveTo(_toolGesturePoints.first.dx, _toolGesturePoints.first.dy);
      for (final Offset point in _toolGesturePoints.skip(1)) {
        documentPath.lineTo(point.dx, point.dy);
      }
      if (_toolGesturePoints.length >= 3) {
        documentPath.close();
      }
    }
    if (documentPath == null) {
      return null;
    }
    return SelectionMaskOverlay(
      outline: documentPath.transform(_controller.viewMatrix.storage),
    );
  }

  Widget? _shapeOverlay() {
    final ShapeDraft? draft = _shapeTool.draft;
    if (draft == null) {
      return null;
    }
    final (LiveShapeKind, Offset, Offset) presentation =
        switch (draft.geometry) {
          LineShapeGeometry(:final start, :final end) => (
            LiveShapeKind.line,
            start,
            end,
          ),
          ArrowShapeGeometry(:final start, :final end) => (
            LiveShapeKind.arrow,
            start,
            end,
          ),
          RectangleShapeGeometry(:final rect) => (
            LiveShapeKind.rectangle,
            rect.topLeft,
            rect.bottomRight,
          ),
          EllipseShapeGeometry(:final rect) => (
            LiveShapeKind.ellipse,
            rect.topLeft,
            rect.bottomRight,
          ),
          PolygonShapeGeometry(:final bounds) => (
            LiveShapeKind.polygon,
            bounds.topLeft,
            bounds.bottomRight,
          ),
        };
    return LiveShapeOverlay(
      kind: presentation.$1,
      start: _controller.viewportFromDoc(presentation.$2),
      end: _controller.viewportFromDoc(presentation.$3),
      polygonSides: widget.model.toolState.wp5Options.polygonSides,
      color: Color(_parseBrushColor(widget.model.toolState.color)),
      strokeWidth: math.max(1, draft.brush.size * _controller.scale),
      perfected: draft.isPerfected,
    );
  }

  Widget? _selectionFloatOverlay() {
    final ui.Image? image = _selectionFloatImage;
    if (_selectionTool.floatingSelection == null || image == null) {
      return null;
    }
    return _RasterPlacementOverlay(
      image: image,
      documentBounds: Offset.zero & _documentSize,
      documentToViewport: Matrix4.copy(_controller.viewMatrix),
      rotationRadians: 0,
      flipHorizontal: false,
      flipVertical: false,
      filterQuality: FilterQuality.none,
    );
  }

  Widget? _transformContentOverlay() {
    final TransformSnapshot? snapshot = _transformTool.snapshot;
    final ui.Image? image = _transformPreviewImage;
    if (snapshot == null || image == null) {
      return null;
    }
    return _RasterPlacementOverlay(
      image: image,
      documentBounds: Offset.zero & _documentSize,
      documentToViewport: Matrix4.copy(_controller.viewMatrix),
      rotationRadians: 0,
      flipHorizontal: false,
      flipVertical: false,
      filterQuality: snapshot.resampling == TransformResampling.nearest
          ? FilterQuality.none
          : FilterQuality.medium,
    );
  }

  Widget? _transformOverlay() {
    final TransformSnapshot? snapshot = _transformTool.snapshot;
    if (snapshot == null ||
        widget.model.toolState.selectedToolId != 'transform' ||
        !widget.contentTransformEnabled) {
      return null;
    }
    return TransformOverlay(bounds: _viewportBounds(snapshot.bounds));
  }

  Widget? _textOverlay() {
    final TextBlockDraft? draft = _textTool.draft;
    if (draft == null) {
      return null;
    }
    return TextDraftOverlay(
      bounds: _viewportBounds(draft.bounds),
      text: draft.text,
      color: Color(draft.options.colorArgb),
      fontFamily: draft.options.fontFamily.familyName,
      fontSize: draft.options.size * _controller.scale,
      fontWeight: _fontWeight(draft.options.weight),
      resizeMode: _textResizeMode,
    );
  }

  Widget? _cropOverlay() {
    final CropDraft? draft = _cropTool.draft;
    if (draft == null) {
      return null;
    }
    final Rect viewportCrop = _viewportBounds(draft.cropRect);
    final Rect viewportArtwork = _viewportBounds(draft.artworkBounds);
    return CropOverlay(
      cropRect: viewportCrop,
      artworkBounds: viewportArtwork,
      label:
          '${draft.cropRect.width.round()} × ${draft.cropRect.height.round()}',
    );
  }

  Widget? _guidesOverlay() {
    final Wp5ToolOptions options = widget.model.toolState.wp5Options;
    final bool hasStraightedge =
        (options.straightedgeEnabled || _activeInteractionToolId == 'guides') &&
        _straightedgeStartDocument != null &&
        _straightedgeEndDocument != null;
    if (!hasStraightedge &&
        options.gridStyle == GuideGridStyle.off &&
        options.symmetryMode == InkSymmetryMode.off) {
      return null;
    }
    return GuidesSymmetryOverlay(
      gridSpacing: options.gridStyle == GuideGridStyle.off
          ? null
          : options.gridSpacingDpx * _controller.scale,
      dotGrid: options.gridStyle == GuideGridStyle.dots,
      gridOrigin: _controller.viewportFromDoc(Offset.zero),
      straightedgeStart: hasStraightedge
          ? _controller.viewportFromDoc(_straightedgeStartDocument!)
          : null,
      straightedgeEnd: hasStraightedge
          ? _controller.viewportFromDoc(_straightedgeEndDocument!)
          : null,
      symmetry: switch (options.symmetryMode) {
        InkSymmetryMode.off => GuideSymmetryMode.off,
        InkSymmetryMode.vertical => GuideSymmetryMode.vertical,
        InkSymmetryMode.horizontal => GuideSymmetryMode.horizontal,
        InkSymmetryMode.quad => GuideSymmetryMode.quad,
      },
      verticalAxis: _controller
          .viewportFromDoc(Offset(_documentSize.width / 2, 0))
          .dx,
      horizontalAxis: _controller
          .viewportFromDoc(Offset(0, _documentSize.height / 2))
          .dy,
    );
  }

  Widget? _eyedropperOverlay() {
    final EyedropperSample? sample = _eyedropperSample;
    final Offset? viewportPoint = _eyedropperViewportPoint;
    if (sample == null || viewportPoint == null) {
      return null;
    }
    final int channel = (sample.latticeGrayLevel / 30 * 255).round().clamp(
      0,
      255,
    );
    return EyedropperLoupeOverlay(
      sampleCenter: viewportPoint,
      loupeCenter: viewportPoint + const Offset(52, -52),
      sampledColor: Color(sample.selectedArgb),
      todayGray: Color(0xff000000 | channel << 16 | channel << 8 | channel),
      sampleRadius: _eyedropperTool.radius * _controller.scale,
    );
  }

  Rect _viewportBounds(Rect documentRect) => boundsOfPoints(<Offset>[
    _controller.viewportFromDoc(documentRect.topLeft),
    _controller.viewportFromDoc(documentRect.topRight),
    _controller.viewportFromDoc(documentRect.bottomRight),
    _controller.viewportFromDoc(documentRect.bottomLeft),
  ]);

  Widget? _hoverRing() {
    final Offset? documentCenter = _hoverCursor.center;
    if (documentCenter == null) {
      return null;
    }
    final Offset viewportCenter = _controller.viewportFromDoc(documentCenter);
    final double logicalDiameter = _hoverCursor.diameter * _controller.scale;
    const double fringe = 2;
    final double extent = logicalDiameter + fringe * 2;
    return Positioned(
      left: viewportCenter.dx - extent / 2,
      top: viewportCenter.dy - extent / 2,
      width: extent,
      height: extent,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _HoverRingPainter(diameter: logicalDiameter),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    widget.model.toolState.removeListener(_handleToolStateChanged);
    _shapeTool.cancel();
    _cropTool.cancel();
    _transformTool.cancel();
    _textTool.cancel();
    _eyedropperTool.cancel();
    _transformPreviewImage?.dispose();
    _selectionFloatImage?.dispose();
    _toolGesturePoints.clear();
    WidgetsBinding.instance.removeObserver(this);
    widget.handle._detach(this);
    _tapClassifier.dispose();
    _navigation.dispose();
    _touchBirths.clear();
    final Completer<void>? strokeCompletion = _strokeCompletion;
    if (strokeCompletion != null && !strokeCompletion.isCompleted) {
      strokeCompletion.complete();
    }
    final Completer<void>? overlayScheduled = _overlayFrameScheduled;
    if (overlayScheduled != null && !overlayScheduled.isCompleted) {
      overlayScheduled.complete();
    }
    unawaited(_penMetadataSubscription?.cancel());
    final PenRouter? router = _penRouter;
    if (router != null) {
      unawaited(router.dispose());
    }
    _cache?.dispose();
    _overlay.dispose();
    _repaint.dispose();
    final RasterCompositor? compositor = _compositor;
    if (compositor != null) {
      unawaited(compositor.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        _scheduleViewport(size);
        final CompositeTileCache? cache = _cache;
        if (cache == null) {
          return ColoredBox(
            color: theme.palette.grayDD,
            child: Center(
              child: Text(
                _lastEngineError == null
                    ? 'starting canvas…'
                    : 'canvas worker unavailable',
                style: theme.type.body.copyWith(
                  color: theme.palette.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }
        return MouseRegion(
          onExit: _handlePointerExit,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _handlePointerEvent,
            onPointerMove: _handlePointerEvent,
            onPointerUp: _handlePointerEvent,
            onPointerCancel: _handlePointerEvent,
            onPointerHover: _handlePointerEvent,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: <Widget>[
                RepaintBoundary(
                  key: inkCanvasBoundaryKey,
                  child: CustomPaint(
                    key: inkCanvasPaintKey,
                    isComplex: true,
                    willChange: true,
                    painter: CanvasPainter(
                      controller: _controller,
                      cache: cache,
                      overlay: _overlay,
                      repaint: _repaint,
                      paperColor: theme.palette.paper,
                      surroundColor: theme.palette.paper,
                    ),
                    size: Size.infinite,
                  ),
                ),
                ..._toolOverlays(),
                if (_hoverRing() case final Widget ring) ring,
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _RasterPlacementOverlay extends StatelessWidget {
  const _RasterPlacementOverlay({
    required this.image,
    required this.documentBounds,
    required this.documentToViewport,
    required this.rotationRadians,
    required this.flipHorizontal,
    required this.flipVertical,
    required this.filterQuality,
  });

  final ui.Image image;
  final Rect documentBounds;
  final Matrix4 documentToViewport;
  final double rotationRadians;
  final bool flipHorizontal;
  final bool flipVertical;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _RasterPlacementPainter(
            image: image,
            documentBounds: documentBounds,
            documentToViewport: documentToViewport,
            rotationRadians: rotationRadians,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical,
            filterQuality: filterQuality,
          ),
        ),
      ),
    );
  }
}

final class _RasterPlacementPainter extends CustomPainter {
  const _RasterPlacementPainter({
    required this.image,
    required this.documentBounds,
    required this.documentToViewport,
    required this.rotationRadians,
    required this.flipHorizontal,
    required this.flipVertical,
    required this.filterQuality,
  });

  final ui.Image image;
  final Rect documentBounds;
  final Matrix4 documentToViewport;
  final double rotationRadians;
  final bool flipHorizontal;
  final bool flipVertical;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..transform(documentToViewport.storage)
      ..translate(documentBounds.center.dx, documentBounds.center.dy)
      ..rotate(rotationRadians)
      ..scale(flipHorizontal ? -1 : 1, flipVertical ? -1 : 1);
    paintImage(
      canvas: canvas,
      rect: Rect.fromCenter(
        center: Offset.zero,
        width: documentBounds.width,
        height: documentBounds.height,
      ),
      image: image,
      fit: BoxFit.fill,
      filterQuality: filterQuality,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RasterPlacementPainter oldDelegate) =>
      !identical(oldDelegate.image, image) ||
      oldDelegate.documentBounds != documentBounds ||
      oldDelegate.documentToViewport != documentToViewport ||
      oldDelegate.rotationRadians != rotationRadians ||
      oldDelegate.flipHorizontal != flipHorizontal ||
      oldDelegate.flipVertical != flipVertical ||
      oldDelegate.filterQuality != filterQuality;
}

final class _ActiveBrushStroke {
  _ActiveBrushStroke({
    required this.spec,
    required BrushStampTarget target,
    required this.seed,
    required this.colorArgb,
    required double size,
    required Iterable<double> transform,
    required this.flowMultiplier,
    required this.symmetryMode,
    required this.selectionClipped,
  }) : size = size,
       transform = List<double>.unmodifiable(transform) {
    _engine = BrushEngine(
      spec: spec,
      target: target,
      seed: seed,
      colorArgb: colorArgb,
      size: size,
    );
    _pipeline = StrokePipeline(onPath: _receivePath, smoothing: spec.smoothing);
  }

  final BrushSpec spec;
  final int seed;
  final int colorArgb;
  final double size;
  final List<double> transform;
  final double flowMultiplier;
  final InkSymmetryMode symmetryMode;
  final bool selectionClipped;
  late final BrushEngine _engine;
  late final StrokePipeline _pipeline;
  Rect? _damage;

  Uint8List get recipeSamples => _pipeline.encodeRecipe();

  Rect begin(StrokeSample sample) {
    _damage = null;
    _pipeline.begin(sample);
    return _takeDamage();
  }

  Rect add(StrokeSample sample) {
    _damage = null;
    _pipeline.add(sample);
    return _takeDamage();
  }

  Rect end() {
    _damage = null;
    _pipeline.end();
    return _takeDamage();
  }

  void cancel() => _pipeline.cancel();

  void _receivePath(List<FittedStrokeSample> samples, {required bool isFinal}) {
    if (samples.isNotEmpty) {
      _includeDamage(
        _engine.stampAlong(
          samples.map<BrushPoint>(
            (FittedStrokeSample fitted) => BrushPoint(
              point: fitted.point,
              pressure: fitted.pressure,
              tilt: (fitted.tilt.distance / (math.pi / 2))
                  .clamp(0.0, 1.0)
                  .toDouble(),
              timestamp: fitted.timestamp,
            ),
          ),
        ),
      );
    }
    if (isFinal) {
      _includeDamage(_engine.finalize());
    }
  }

  void _includeDamage(Rect damage) {
    if (damage.isEmpty) {
      return;
    }
    _damage = _damage == null ? damage : _damage!.expandToInclude(damage);
  }

  Rect _takeDamage() => _damage ?? Rect.zero;
}

final class _StrokeBufferBrushTarget implements BrushStampTarget {
  const _StrokeBufferBrushTarget(
    this.buffer,
    this.flowMultiplier, {
    this.selection,
  });

  final StrokeBuffer buffer;
  final double flowMultiplier;
  final SelectionMask? selection;

  @override
  Rect stamp(ResolvedBrushStamp stamp) {
    final ResolvedBrushGrain? grain = stamp.grain;
    return buffer.stampEllipse(
      center: stamp.center,
      diameterX: stamp.diameterX,
      diameterY: stamp.diameterY,
      angleRadians: stamp.angleRadians,
      colorArgb: stamp.colorArgb,
      flow: (stamp.flow * flowMultiplier).clamp(0.0, 1.0),
      modifyCoverage: grain == null && selection == null
          ? null
          : (int x, int y, double coverage) {
              final SelectionMask? mask = selection;
              if (mask != null && mask.coverageAt(x, y) == 0) {
                return 0;
              }
              final double selectedCoverage = mask == null
                  ? coverage
                  : coverage * mask.coverageAt(x, y) / 255;
              return grain == null
                  ? selectedCoverage
                  : selectedCoverage *
                        grain.coverageAt(
                          Offset(x + 0.5, y + 0.5),
                          stampCenter: stamp.center,
                        );
            },
    );
  }
}

final class _HoverRingPainter extends CustomPainter {
  const _HoverRingPainter({required this.diameter});

  final double diameter;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      diameter / 2,
      Paint()
        ..color = const Color(0xff000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_HoverRingPainter oldDelegate) =>
      oldDelegate.diameter != diameter;
}

int _tileCoordinateForPixel(int pixel) =>
    pixel >= 0 ? pixel ~/ Tile.edge : -((-pixel + Tile.edge - 1) ~/ Tile.edge);

int _parseBrushColor(String value) {
  final String digits = value.startsWith('#') ? value.substring(1) : value;
  final int? parsed = int.tryParse(digits, radix: 16);
  if (parsed == null) {
    return 0xff000000;
  }
  return switch (digits.length) {
    6 => 0xff000000 | parsed,
    8 => parsed,
    _ => 0xff000000,
  };
}

bool _sameBytes(Uint8List left, Uint8List? right) {
  if (right == null) {
    return !left.any((int value) => value != 0);
  }
  if (left.lengthInBytes != right.lengthInBytes) {
    return false;
  }
  for (var index = 0; index < left.lengthInBytes; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

JournalBounds _journalBounds(Rect bounds) {
  final int left = bounds.left.floor();
  final int top = bounds.top.floor();
  return JournalBounds(
    x: left,
    y: top,
    width: math.max(0, bounds.right.ceil() - left),
    height: math.max(0, bounds.bottom.ceil() - top),
  );
}

String _historyKindLabel(JournalKind kind) => switch (kind) {
  JournalKind.stroke => 'stroke',
  JournalKind.erase => 'erase',
  JournalKind.fill => 'fill',
  JournalKind.shape => 'shape',
  JournalKind.text => 'text',
  JournalKind.floatCommit => 'move',
  JournalKind.layerAdd => 'layer add',
  JournalKind.layerRemove => 'layer delete',
  JournalKind.layerReorder => 'layer reorder',
  JournalKind.layerProps => 'layer change',
  JournalKind.layerClear => 'layer clear',
  JournalKind.canvasResize => 'canvas resize',
  JournalKind.canvasFlip => 'canvas flip',
  JournalKind.merge => 'layer merge',
};
