import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../document/document.dart';
import '../document/export.dart';
import '../document/document_io.dart';
import '../document/tile_store.dart';
import '../document/undo_journal.dart';
import '../engine/brush_presets.dart';
import '../engine/canvas_ops.dart';
import '../engine/stroke_recipe_replay.dart';
import '../model/editor_model.dart';
import '../model/gallery_model.dart';
import '../model/tool_state.dart';
import '../services.dart';
import '../tools/eraser_tool.dart';
import '../tools/reference_tool.dart';
import 'bench/bench.dart';
import 'canvas_grow_controls.dart';
import 'canvas_view.dart';
import 'dock/contextual_dock.dart';
import 'panels/brush_panel.dart';
import 'panels/color_panel.dart';
import 'panels/export_panel.dart';
import 'panels/layers_panel.dart';
import 'reference_layer_opacity.dart';
import 'responsive_layout.dart';
import 'status_chips.dart';

/// Loads the external services used by the temporary WP2 editor host.
typedef InkServicesLoader = Future<InkServices> Function();

const int _maximumEncodedReferenceBytes = 32 * 1024 * 1024;

/// Builds the additive WP5 dock/overlay layer above the canvas.
///
/// The coordinator owns the final editor composition. This seam keeps that
/// merge out of [CanvasView]'s input and raster core while allowing the tool
/// layer to share the loaded model and canvas handle.
typedef InkToolLayerBuilder =
    Widget Function(
      BuildContext context,
      EditorModel model,
      CanvasViewHandle canvasHandle,
    );

/// Builds one placed reference without forcing real codec work in tests.
typedef ReferenceImageWidgetBuilder =
    Widget Function(BuildContext context, ReferenceImageDescriptor image);

/// Full editor host for the tile canvas, drafting bench, sheets, and status.
final class EditorPage extends StatefulWidget {
  /// Creates the editor, optionally using injected services for tests.
  const EditorPage({
    this.session,
    this.services,
    this.servicesLoader,
    this.toolLayerBuilder,
    this.artworkId,
    this.benchDock = InkBenchDock.left,
    this.onBenchDockChanged,
    this.onBack,
    this.onOpenSettings,
    this.transfers,
    this.initialReferenceImport,
    this.referenceDecoder = const ReferenceImageDecoder(),
    this.referenceController,
    this.referenceImageBuilder = _buildFileReferenceImage,
    this.markerMissingOverride,
    super.key,
  });

  /// Already-open session owned by the application shell.
  final InkEditorSession? session;

  /// Explicit services, when the caller already owns a bundle.
  final InkServices? services;

  /// Optional asynchronous service seam.
  final InkServicesLoader? servicesLoader;

  /// Optional synchronous contextual dock and direct-paint overlay builder.
  final InkToolLayerBuilder? toolLayerBuilder;

  /// Artwork selected by the gallery when this page owns session loading.
  final String? artworkId;

  /// Global dock preference loaded from settings.
  final InkBenchDock benchDock;

  /// Persists a dock edge chosen by grip drag.
  final ValueChanged<InkBenchDock>? onBenchDockChanged;

  /// Flushes and returns to the gallery.
  final FutureOr<void> Function()? onBack;

  /// Opens the settings page while retaining this editor session.
  final VoidCallback? onOpenSettings;

  /// Shared WP8 transfer service, or a service derived from [services].
  final InkDocumentTransferService? transfers;

  /// Optional image selected from the gallery import affordance.
  final GalleryImportCandidate? initialReferenceImport;

  /// Bounded PNG/JPEG decoder, injectable for codec-free tests.
  final ReferenceImageDecoder referenceDecoder;

  /// Existing WP5 placement controller, injectable for flow verification.
  final ReferenceToolController? referenceController;

  /// Reference renderer, injectable to keep widget tests codec-free.
  final ReferenceImageWidgetBuilder referenceImageBuilder;

  /// Deterministic marker-banner seam for tests and goldens.
  final bool? markerMissingOverride;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

final class _EditorPageState extends State<EditorPage> {
  final CanvasViewHandle _canvasHandle = CanvasViewHandle();
  late Future<InkEditorSession> _sessionFuture;
  InkEditorSession? _session;
  int _openGeneration = 0;
  int _canvasGeneration = 0;
  int _activeCanvasPointers = 0;
  int _activeCanvasTouchPointers = 0;
  bool _ownsSession = false;
  InkBenchDock? _localDock;
  BrushPanelOptions _brushOptions = const BrushPanelOptions();
  InkSavePhase _savePhase = InkSavePhase.quiet;
  DateTime? _savedAt;
  Timer? _dryingTimer;
  Timer? _savedTimer;
  Timer? _historyTimer;
  Timer? _markerTimer;
  StreamSubscription<PenEvent>? _penPresenceSubscription;
  CanvasHistoryFeedback? _historyFeedback;
  bool _sawPenEvent = false;
  bool _markerMissing = false;
  String? _renameLayerId;
  String? _renameText;
  String? _operationError;
  late ReferenceToolController _referenceController;
  String? _handledInitialReferencePath;
  String? _referenceDragLayerId;
  Offset? _referenceDragStartGlobal;
  ReferencePlacement? _referenceDragStartPlacement;
  bool _availabilityRebuildScheduled = false;
  CanvasResizeAnchor _canvasResizeAnchor = CanvasResizeAnchor.center;

  @override
  void initState() {
    super.initState();
    _canvasHandle.onAvailabilityChanged = _handleCanvasAvailabilityChanged;
    _referenceController =
        widget.referenceController ?? ReferenceToolController();
    _localDock = widget.benchDock;
    _sessionFuture = _resolveSession(++_openGeneration);
  }

  @override
  void didUpdateWidget(EditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.services != widget.services ||
        oldWidget.servicesLoader != widget.servicesLoader ||
        oldWidget.artworkId != widget.artworkId) {
      final InkEditorSession? previous = _session;
      _session = null;
      if (previous != null && _ownsSession) {
        unawaited(previous.dispose());
      }
      _sessionFuture = _resolveSession(++_openGeneration);
    }
    if (oldWidget.benchDock != widget.benchDock &&
        _localDock == oldWidget.benchDock) {
      _localDock = widget.benchDock;
    }
    if (oldWidget.initialReferenceImport?.path !=
        widget.initialReferenceImport?.path) {
      _handledInitialReferencePath = null;
      final InkEditorSession? session = _session;
      if (session != null) {
        _scheduleInitialReferenceImport(session);
      }
    }
  }

  Future<InkEditorSession> _resolveSession(int generation) async {
    final InkEditorSession? injected = widget.session;
    if (injected != null) {
      _ownsSession = false;
      _session = injected;
      _startMarkerHeuristic(injected);
      _scheduleInitialReferenceImport(injected);
      return injected;
    }
    final InkServices services =
        widget.services ??
        await (widget.servicesLoader ?? InkServices.createReal)();
    final InkEditorSession session = await openInkEditorSession(
      services,
      artworkId: widget.artworkId,
    );
    if (!mounted || generation != _openGeneration) {
      await session.dispose();
      throw StateError('Editor session was superseded while opening.');
    }
    _ownsSession = true;
    _session = session;
    _startMarkerHeuristic(session);
    _scheduleInitialReferenceImport(session);
    return session;
  }

  @override
  void dispose() {
    _openGeneration += 1;
    _dryingTimer?.cancel();
    _savedTimer?.cancel();
    _historyTimer?.cancel();
    _markerTimer?.cancel();
    unawaited(_penPresenceSubscription?.cancel());
    _canvasHandle.onAvailabilityChanged = null;
    _canvasHandle.detach();
    final InkEditorSession? session = _session;
    if (session != null && _ownsSession) {
      unawaited(session.dispose());
    }
    super.dispose();
  }

  void _handleCanvasAvailabilityChanged() {
    if (!mounted || _availabilityRebuildScheduled) {
      return;
    }
    _availabilityRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _availabilityRebuildScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InkEditorSession>(
      future: _sessionFuture,
      builder:
          (BuildContext context, AsyncSnapshot<InkEditorSession> snapshot) {
            final InkEditorSession? session = snapshot.data;
            if (session == null) {
              return _EditorBootState(error: snapshot.error);
            }
            final Widget canvas = Listener(
              key: const ValueKey<String>('ink-editor-canvas-host'),
              onPointerDown: _trackCanvasPointerDown,
              onPointerUp: _trackCanvasPointerEnd,
              onPointerCancel: _trackCanvasPointerEnd,
              child: CanvasView(
                key: ValueKey<(EditorModel, int)>((
                  session.model,
                  _canvasGeneration,
                )),
                model: session.model,
                services: session.services,
                handle: _canvasHandle,
                onToggleChrome: session.model.toggleChrome,
                onHistoryFeedback: _showHistoryFeedback,
                contentTransformEnabled:
                    _referenceController.placingLayerId == null,
              ),
            );
            return ListenableBuilder(
              listenable: session.model,
              child: canvas,
              builder: (BuildContext context, Widget? child) {
                return ColoredBox(
                  color: PaperTheme.of(context).palette.paper,
                  child: Stack(
                    key: const ValueKey<String>('ink-editor-surface'),
                    fit: StackFit.expand,
                    children: <Widget>[
                      child!,
                      if (_referenceController.layers.isNotEmpty &&
                          _activeCanvasTouchPointers < 2)
                        _buildReferenceOverlay(session.model),
                      if (widget.toolLayerBuilder case final builder?)
                        builder(context, session.model, _canvasHandle),
                      if (session.model.chromeVisible) ...<Widget>[
                        _buildChrome(context, session),
                        if (session.model.openPanel != null)
                          _buildPanelVeil(session.model),
                        if (session.model.openPanel != null)
                          _buildPanel(context, session),
                        if (_feedbackChip(session.model) case final Widget chip)
                          Positioned(
                            top: _scaled(
                              context,
                              inkStatusBandDesignHeight + 12,
                            ),
                            left: _scaled(context, 176),
                            child: chip,
                          ),
                        if (_markerMissing)
                          Positioned(
                            top: _scaled(context, inkStatusBandDesignHeight),
                            left: 0,
                            right: 0,
                            child: InkMarkerMissingBanner(
                              onDismiss: () => setState(() {
                                _markerMissing = false;
                              }),
                            ),
                          ),
                      ],
                      if (_renameText != null)
                        _RenameKeyboardSheet(
                          value: _renameText!,
                          onChanged: (String value) => setState(() {
                            _renameText = value;
                          }),
                          onCancel: _cancelRename,
                          onDone: () => _finishRename(session),
                        ),
                    ],
                  ),
                );
              },
            );
          },
    );
  }

  void _trackCanvasPointerDown(PointerDownEvent event) {
    _activeCanvasPointers += 1;
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    _activeCanvasTouchPointers += 1;
    if (_activeCanvasTouchPointers == 2) {
      setState(() {});
    }
  }

  void _trackCanvasPointerEnd(PointerEvent event) {
    _activeCanvasPointers = math.max(0, _activeCanvasPointers - 1);
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    final bool wasSuppressed = _activeCanvasTouchPointers >= 2;
    _activeCanvasTouchPointers = math.max(0, _activeCanvasTouchPointers - 1);
    if (wasSuppressed && _activeCanvasTouchPointers < 2) {
      setState(() {});
    }
  }

  Widget _buildChrome(BuildContext context, InkEditorSession session) {
    final EditorModel model = session.model;
    final ToolState tools = model.toolState;
    final BrushSpec brush = drawingBrushesById[tools.brushId] ?? finelinerBrush;
    final InkBenchDock dock = _localDock ?? widget.benchDock;
    final ContextualDockMode? dockMode = _contextModeForTool(
      tools.activeToolId,
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Align(
          alignment: Alignment.topCenter,
          child: InkEditorStatusBand(
            artworkName: model.document.name,
            zoomPercent: (model.viewState.scale * 100).round().clamp(10, 1600),
            activeLayerName: model.activeLayer.name,
            savePhase: model.isCompositing ? InkSavePhase.drying : _savePhase,
            savedAt: _savedAt,
            rotationDegrees: model.viewState.rotationDeg,
            heavyArtwork: model.contentLayers.length >= maxInkContentLayers,
            onBack: () => unawaited(_back(session)),
            onArtworkPressed: () => _beginArtworkRename(model),
            onZoomPressed: _canvasHandle.cycleZoom,
            onRotationReset: model.viewState.rotationDeg == 0
                ? null
                : _canvasHandle.resetRotation,
            onLayerPressed: () => model.showPanel(EditorPanel.layers),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            top: _scaled(context, inkStatusBandDesignHeight),
          ),
          child: Align(
            alignment: dock.alignment,
            child: InkBench(
              dock: dock,
              collapsed: model.benchCollapsed,
              activeToolId: tools.activeToolId,
              activeBrush: brush,
              brushSize: tools.size,
              brushFlow: tools.flow,
              currentColor: Color(tools.inkColor?.argb ?? 0xff000000),
              activeLayerOrdinal: model.activeLayerOrdinal,
              canUndo: model.journal.canUndo,
              canRedo: model.journal.canRedo,
              onToggleCollapsed: () =>
                  model.setBenchCollapsed(!model.benchCollapsed),
              onToolSelected: (String toolId) {
                if (toolId != 'transform' &&
                    _referenceController.placingLayerId != null) {
                  _referenceController.cancel();
                  _clearReferenceDrag();
                }
                tools.selectTool(toolId);
                model.closePanel();
                unawaited(_saveChromeState());
              },
              onBrushPressed: () => model.showPanel(EditorPanel.brush),
              onSizeChanged: (double value) {
                tools.setSize(value);
                unawaited(_saveChromeState());
              },
              onFlowChanged: (double value) {
                tools.setFlow(value);
                unawaited(_saveChromeState());
              },
              onColorPressed: () => model.showPanel(EditorPanel.color),
              onUndo: () => unawaited(_canvasHandle.undo()),
              onRedo: () => unawaited(_canvasHandle.redo()),
              onLayersPressed: () => model.showPanel(EditorPanel.layers),
              onMenuPressed: () => model.showPanel(EditorPanel.menu),
              onDockChanged: (InkBenchDock value) {
                setState(() => _localDock = value);
                widget.onBenchDockChanged?.call(value);
              },
            ),
          ),
        ),
        if (dockMode != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: ContextualDock(
              mode: dockMode,
              selectedActions: _selectedDockActions(
                tools.wp5Options,
                tools.selectedToolId,
                _canvasHandle.eraserMode,
              ),
              actionLabels: <ContextualDockAction, String>{
                ...selectionDockValueLabels(
                  tolerance: tools.wp5Options.selectionTolerance,
                  gapClose: tools.wp5Options.selectionGapClose,
                ),
                ...fillDockValueLabels(
                  tolerance: tools.wp5Options.fillTolerance,
                  gapClose: tools.wp5Options.fillGapClose,
                  grow: tools.wp5Options.fillGrow,
                ),
                ...shapeDockValueLabels(
                  polygonSides: tools.wp5Options.polygonSides,
                ),
              },
              disabledActions: <ContextualDockAction>{
                if (!model.canAddContentLayer) ContextualDockAction.toNewLayer,
                if (!_canvasHandle.canPaste) ContextualDockAction.paste,
                if (_referenceController.placingLayerId != null)
                  ContextualDockAction.aspect,
                if (tools.selectedToolId == 'select' &&
                    !_canvasHandle.hasSelection) ...<ContextualDockAction>{
                  ContextualDockAction.move,
                  ContextualDockAction.duplicate,
                  ContextualDockAction.flipHorizontal,
                  ContextualDockAction.flipVertical,
                  ContextualDockAction.cut,
                  ContextualDockAction.copy,
                  ContextualDockAction.clear,
                  ContextualDockAction.fill,
                  ContextualDockAction.toNewLayer,
                },
                if (tools.selectedToolId == 'transform' &&
                    !_canvasHandle.hasTransformDraft &&
                    _referenceController.placingLayerId ==
                        null) ...<ContextualDockAction>{
                  ContextualDockAction.rotateDetent,
                  ContextualDockAction.flipHorizontal,
                  ContextualDockAction.flipVertical,
                  ContextualDockAction.reset,
                  ContextualDockAction.apply,
                },
                if (tools.selectedToolId == 'crop' &&
                    !_canvasHandle.hasCropDraft) ...<ContextualDockAction>{
                  ContextualDockAction.reset,
                  ContextualDockAction.apply,
                },
                if (tools.selectedToolId == 'shape' &&
                    !_canvasHandle.hasShapeDraft)
                  ContextualDockAction.perfect,
                if (tools.selectedToolId == 'text' &&
                    !_canvasHandle.hasTextDraft) ...<ContextualDockAction>{
                  ContextualDockAction.move,
                  ContextualDockAction.textResize,
                },
                if (tools.selectedToolId == 'text' &&
                    !_canvasHandle.canFinishText)
                  ContextualDockAction.done,
              },
              onAction: (ContextualDockAction action) {
                unawaited(_handleDockAction(model, action));
              },
            ),
          ),
      ],
    );
  }

  Widget _buildPanelVeil(EditorModel model) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: model.closePanel,
        child: ColoredBox(color: const Color(0xffffffff).withAlpha(224)),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, InkEditorSession session) {
    final EditorModel model = session.model;
    final InkBenchDock dock = _localDock ?? widget.benchDock;
    final Alignment alignment = dock == InkBenchDock.left
        ? Alignment.bottomLeft
        : Alignment.bottomRight;
    final Widget panel = switch (model.openPanel) {
      EditorPanel.brush => _brushPanel(model),
      EditorPanel.color => _colorPanel(session),
      EditorPanel.layers => _layersPanel(session),
      EditorPanel.menu => _EditorMenuSheet(
        onClose: model.closePanel,
        onExport: () => model.showPanel(EditorPanel.export),
        onImportReference: () => unawaited(_showReferenceImport(session)),
        onSettings: widget.onOpenSettings,
        onFlipHorizontal: () => unawaited(_flipCanvas(session)),
        resizeAnchor: _canvasResizeAnchor,
        onResizeAnchorChanged: (CanvasResizeAnchor anchor) {
          setState(() => _canvasResizeAnchor = anchor);
        },
        onGrowCanvas: (CanvasResizeAnchor anchor) =>
            unawaited(_growCanvas(session, anchor)),
        onClearLayer: () =>
            unawaited(_clearLayer(session, model.activeLayer.id)),
        onDeepClean: () =>
            unawaited(session.services.system.requestFullRefresh()),
      ),
      EditorPanel.export => ExportPanel(
        artworkId: model.document.id,
        onExport:
            ({
              required String artworkId,
              required InkExportKind kind,
              InkExportProgressCallback? onProgress,
            }) => _exportArtwork(
              session,
              artworkId: artworkId,
              kind: kind,
              onProgress: onProgress,
            ),
        onClose: model.closePanel,
      ),
      null => const SizedBox.shrink(),
    };
    return Align(alignment: alignment, child: panel);
  }

  Widget _brushPanel(EditorModel model) {
    final ToolState tools = model.toolState;
    return BrushPanel(
      activeBrushId: tools.brushId,
      brushSizes: <String, double>{
        for (final BrushSpec brush in drawingBrushes)
          brush.id: tools.sizeForBrush(brush.id, fallback: brush.sizeDefault),
      },
      options: _brushOptions,
      onClose: model.closePanel,
      onBrushSelected: (BrushSpec brush) {
        tools.selectBrush(
          brush.id,
          size: tools.sizeForBrush(brush.id, fallback: brush.sizeDefault),
        );
        unawaited(_saveChromeState());
      },
      onOptionsChanged: (BrushPanelOptions value) {
        setState(() => _brushOptions = value);
        tools.setBrushPreset('wp7Options', _brushOptionsToJson(value));
        unawaited(_saveChromeState());
      },
    );
  }

  Widget _colorPanel(InkEditorSession session) {
    final ToolState tools = session.model.toolState;
    return ColorPanel(
      selectedColor: Color(tools.inkColor?.argb ?? 0xff000000),
      recents: <Color>[
        for (final InkColor color in tools.recentColors) Color(color.argb),
      ],
      presenterDrivesColor: session.services.display.presenterDrivesColor,
      onClose: session.model.closePanel,
      onColorSelected: (Color color) {
        tools.selectInkColor(InkColor.fromArgb(color.toARGB32()));
        unawaited(_saveChromeState());
      },
    );
  }

  Widget _layersPanel(InkEditorSession session) {
    final EditorModel model = session.model;
    final List<ReferenceLayer> references = _referenceController.layers;
    bool isReference(String id) =>
        references.any((ReferenceLayer layer) => layer.id == id);
    return LayersPanel(
      activeLayerId: model.activeLayer.id,
      referenceLayers: <LayerPanelItem>[
        for (final ReferenceLayer layer in references.reversed)
          LayerPanelItem(
            id: layer.id,
            name: layer.image.sourceId.split(Platform.pathSeparator).last,
            opacityPercent: (layer.opacity * 100).round(),
            isVisible: layer.isVisible,
            isLocked: layer.isLocked,
            thumbnailSeed: layer.id.hashCode,
          ),
      ],
      layers: <LayerPanelItem>[
        for (final InkLayer layer in model.contentLayers.reversed)
          LayerPanelItem(
            id: layer.id,
            name: layer.name,
            opacityPercent: layer.opacity,
            isVisible: layer.visible,
            isLocked: layer.locked,
            thumbnailSeed: layer.id.hashCode,
          ),
      ],
      onClose: model.closePanel,
      onLayerSelected: (String layerId) {
        if (isReference(layerId)) {
          _referenceController.beginPlacement(layerId);
          model.toolState.selectTool('transform');
          model.closePanel();
          setState(() {
            _operationError = 'reference selected — transform active';
          });
          return;
        }
        model.selectActiveLayer(layerId);
        unawaited(_saveChromeState());
      },
      onAddLayer: model.canAddContentLayer
          ? () => unawaited(_addLayer(session))
          : null,
      onVisibilityChanged: (String id, bool visible) {
        if (isReference(id)) {
          _referenceController.setVisible(id, visible);
          setState(() {});
          return;
        }
        unawaited(_updateLayer(session, id, visible: visible));
      },
      onLockChanged: (String id, bool locked) {
        if (isReference(id)) {
          setState(() {
            _operationError = 'references stay locked';
          });
          return;
        }
        unawaited(_updateLayer(session, id, locked: locked));
      },
      onOpacityChanged: (String id, int opacity) {
        if (isReference(id)) {
          final double normalized = opacity / 100;
          _referenceController.setOpacity(id, normalized);
          model.toolState.setWp5Options(
            model.toolState.wp5Options.copyWith(referenceOpacity: normalized),
          );
          setState(() {
            _operationError = 'reference opacity · $opacity%';
          });
          unawaited(_saveChromeState());
          return;
        }
        unawaited(_updateLayer(session, id, opacity: opacity));
      },
      onLayerReordered: (String id, int panelIndex) => unawaited(
        _reorderLayer(session, id, model.contentLayers.length - 1 - panelIndex),
      ),
      onReferenceReordered: (String id, int panelIndex) {
        _referenceController.reorder(id, references.length - 1 - panelIndex);
        setState(() {});
      },
      onRenameLayer: (String id) => _beginLayerRename(model, id),
      onDuplicateLayer: (String id) => unawaited(_duplicateLayer(session, id)),
      onMergeLayerDown: (String id) => unawaited(_mergeLayer(session, id)),
      onClearLayer: (String id) => unawaited(_clearLayer(session, id)),
      onDeleteLayer: model.contentLayers.length > 1
          ? (String id) => unawaited(_deleteLayer(session, id))
          : null,
      onDeleteReference: (String id) {
        _referenceController.remove(id);
        setState(() {
          _operationError = 'reference removed';
        });
      },
    );
  }

  Widget? _feedbackChip(EditorModel model) {
    if (_operationError case final String error) {
      return InkMarginNoteChip(
        message: error,
        onDismiss: () => setState(() => _operationError = null),
      );
    }
    if (model.layerActionChip case final LayerActionChip chip) {
      return InkLayerStatusChip(
        message: chip.message,
        onDismiss: model.dismissLayerActionChip,
      );
    }
    if (_historyFeedback case final CanvasHistoryFeedback feedback) {
      return InkUndoToast(
        message: feedback.message,
        onDismiss: _clearHistoryFeedback,
      );
    }
    return null;
  }

  Future<InkExportResult> _exportArtwork(
    InkEditorSession session, {
    required String artworkId,
    required InkExportKind kind,
    InkExportProgressCallback? onProgress,
  }) async {
    if (session.model.isCompositing) {
      return InkExportFailure(
        kind: kind,
        reason: 'canvas is still compositing — retry',
      );
    }
    InkExportFailure? saveFailure;
    var restartCanvas = false;
    try {
      if ((session.model.dirty || _activeCanvasPointers > 0) &&
          _canvasHandle.isAttached) {
        restartCanvas = true;
        await _canvasHandle.save();
      }
      if (session.model.dirty) {
        final InkDocument persisted = await session.services.store.saveDocument(
          session.model.documentSnapshot,
          session.model.tiles,
        );
        session.model.markSaved(persisted);
      }
    } on Object catch (error) {
      saveFailure = InkExportFailure(
        kind: kind,
        reason: 'save failed — $error',
      );
    } finally {
      if (restartCanvas && mounted) {
        setState(() {
          _canvasGeneration += 1;
          _activeCanvasPointers = 0;
          _activeCanvasTouchPointers = 0;
        });
      }
    }
    if (saveFailure != null) {
      return saveFailure;
    }
    final InkDocumentTransferService transfers =
        widget.transfers ??
        InkDocumentTransferService(
          store: session.services.store,
          exportsDirectory: session.services.paths.exports,
          nowMilliseconds: session.services.clock.nowMilliseconds,
        );
    return transfers.export(
      artworkId: artworkId,
      kind: kind,
      onProgress: onProgress,
    );
  }

  void _scheduleInitialReferenceImport(InkEditorSession session) {
    final GalleryImportCandidate? candidate = widget.initialReferenceImport;
    if (candidate == null ||
        candidate.kind != GalleryImportKind.image ||
        _handledInitialReferencePath == candidate.path) {
      return;
    }
    _handledInitialReferencePath = candidate.path;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) {
        unawaited(_placeReferenceCandidate(session, candidate));
      }
    });
  }

  Future<void> _showReferenceImport(InkEditorSession session) async {
    session.model.closePanel();
    final DocumentGalleryOperations operations = DocumentGalleryOperations(
      store: session.services.store,
      documentsRoot: session.services.paths.root,
      nowMilliseconds: session.services.clock.nowMilliseconds,
    );
    late final List<GalleryImportCandidate> candidates;
    try {
      candidates = <GalleryImportCandidate>[
        for (final GalleryImportCandidate candidate
            in await operations.scanImports())
          if (candidate.kind == GalleryImportKind.image) candidate,
      ];
    } on Object catch (error) {
      if (mounted) {
        setState(() => _operationError = 'reference scan failed — $error');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final GalleryImportCandidate? selected =
        await PaperDialogs.showSheet<GalleryImportCandidate>(
          context,
          builder: (BuildContext sheetContext) => _ReferenceImportSheet(
            candidates: candidates,
            onCancel: () => Navigator.of(sheetContext).pop(),
            onSelected: (GalleryImportCandidate candidate) =>
                Navigator.of(sheetContext).pop(candidate),
          ),
        );
    if (selected != null && mounted) {
      await _placeReferenceCandidate(session, selected);
    }
  }

  Future<void> _placeReferenceCandidate(
    InkEditorSession session,
    GalleryImportCandidate candidate,
  ) async {
    if (!_referenceController.canAddReference) {
      setState(() => _operationError = 'reference stack is full');
      return;
    }
    final File source = File(candidate.path);
    try {
      final int encodedLength = await source.length();
      if (encodedLength <= 0 || encodedLength > _maximumEncodedReferenceBytes) {
        throw const FormatException('reference file exceeds the size cap');
      }
      final ReferenceDecodeResult result = await widget.referenceDecoder.decode(
        sourceId: source.absolute.path,
        fileName: candidate.name,
        encodedBytes: await source.readAsBytes(),
        maxWidth: session.model.document.canvas.width,
        maxHeight: session.model.document.canvas.height,
      );
      if (!mounted) {
        return;
      }
      switch (result) {
        case ReferenceDecodeFailure(:final String reason):
          setState(() {
            _operationError = 'skipped ${candidate.name} — $reason';
          });
        case ReferenceDecodeSuccess(:final ReferenceDecode decode):
          final String layerId =
              'R${session.services.clock.nowMilliseconds()}-'
              '${_referenceController.layers.length + 1}';
          _referenceController.addReference(
            layerId: layerId,
            image: decode.descriptor,
            opacity: session.model.toolState.wp5Options.referenceOpacity,
            viewportCenter: Offset(
              session.model.document.canvas.width / 2,
              session.model.document.canvas.height / 2,
            ),
          );
          session.model.toolState.selectTool('transform');
          session.model.closePanel();
          setState(() {
            _operationError = 'reference ready — transform active';
          });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _operationError = 'skipped ${candidate.name} — $error';
        });
      }
    }
  }

  Widget _buildReferenceOverlay(EditorModel model) {
    final InkViewState view = model.viewState;
    final double radians = view.rotationDeg * math.pi / 180;
    final Matrix4 viewMatrix = Matrix4.identity()
      ..translateByDouble(view.tx, view.ty, 0, 1)
      ..rotateZ(radians)
      ..scaleByDouble(view.scale, view.scale, 1, 1);
    final CanvasSpec canvas = model.document.canvas;
    final bool placementToolActive =
        model.toolState.activeToolId == 'transform';
    return Positioned(
      left: 0,
      top: 0,
      width: canvas.width.toDouble(),
      height: canvas.height.toDouble(),
      child: Transform(
        alignment: Alignment.topLeft,
        transform: viewMatrix,
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              for (final ReferenceLayer layer in _referenceController.layers)
                if (layer.isVisible)
                  Positioned(
                    left: layer.placement.topLeft.dx,
                    top: layer.placement.topLeft.dy,
                    width: layer.placedSize.width,
                    height: layer.placedSize.height,
                    child: IgnorePointer(
                      ignoring: !placementToolActive,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..rotateZ(layer.placement.rotationRadians)
                          ..scaleByDouble(
                            layer.placement.isFlippedHorizontally ? -1 : 1,
                            layer.placement.isFlippedVertically ? -1 : 1,
                            1,
                            1,
                          ),
                        child: ReferenceLayerOpacity(
                          layer: layer,
                          child: GestureDetector(
                            key: ValueKey<String>(
                              'reference-layer-${layer.id}',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onScaleStart: (ScaleStartDetails details) =>
                                _beginReferenceDrag(layer, details),
                            onScaleUpdate: (ScaleUpdateDetails details) =>
                                _updateReferenceDrag(view, details),
                            onScaleEnd: (ScaleEndDetails details) =>
                                _finishReferenceDrag(),
                            child: widget.referenceImageBuilder(
                              context,
                              layer.image,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  void _beginReferenceDrag(ReferenceLayer layer, ScaleStartDetails details) {
    _referenceController.beginPlacement(layer.id);
    _referenceDragLayerId = layer.id;
    _referenceDragStartGlobal = details.focalPoint;
    _referenceDragStartPlacement = layer.placement;
  }

  void _updateReferenceDrag(InkViewState view, ScaleUpdateDetails details) {
    final String? layerId = _referenceDragLayerId;
    final Offset? startGlobal = _referenceDragStartGlobal;
    final ReferencePlacement? startPlacement = _referenceDragStartPlacement;
    if (layerId == null || startGlobal == null || startPlacement == null) {
      return;
    }
    final Offset viewportDelta = details.focalPoint - startGlobal;
    final double radians = view.rotationDeg * math.pi / 180;
    final double cosine = math.cos(radians);
    final double sine = math.sin(radians);
    final Offset documentDelta = Offset(
      (viewportDelta.dx * cosine + viewportDelta.dy * sine) / view.scale,
      (-viewportDelta.dx * sine + viewportDelta.dy * cosine) / view.scale,
    );
    _referenceController.updatePlacement(
      startPlacement.copyWith(
        topLeft: startPlacement.topLeft + documentDelta,
        scale: startPlacement.scale * details.scale,
        rotationRadians: startPlacement.rotationRadians + details.rotation,
      ),
    );
    setState(() {});
  }

  void _finishReferenceDrag() {
    if (_referenceDragLayerId == null) {
      return;
    }
    _referenceController.commitPlacement();
    _session?.model.toolState.selectTool('draw');
    _clearReferenceDrag();
    setState(() {
      _operationError = 'reference placed';
    });
  }

  void _clearReferenceDrag() {
    _referenceDragLayerId = null;
    _referenceDragStartGlobal = null;
    _referenceDragStartPlacement = null;
  }

  Future<void> _back(InkEditorSession session) async {
    await _saveChromeState();
    final FutureOr<void> Function()? callback = widget.onBack;
    if (callback == null) {
      await session.services.system.exitToLauncher();
      return;
    }
    await callback();
  }

  Future<void> _saveChromeState() async {
    if (!_canvasHandle.isAttached) {
      return;
    }
    _dryingTimer?.cancel();
    _savedTimer?.cancel();
    _dryingTimer = Timer(inkDryingIndicatorDelay, () {
      if (mounted) {
        setState(() => _savePhase = InkSavePhase.drying);
      }
    });
    try {
      await _canvasHandle.save();
      if (!mounted) {
        return;
      }
      _dryingTimer?.cancel();
      setState(() {
        _savedAt = _session?.services.clock.now();
        _savePhase = InkSavePhase.saved;
      });
      _savedTimer = Timer(inkSavedIndicatorDuration, () {
        if (mounted) {
          setState(() => _savePhase = InkSavePhase.quiet);
        }
      });
    } on Object catch (error) {
      _dryingTimer?.cancel();
      if (mounted) {
        setState(() {
          _savePhase = InkSavePhase.quiet;
          _operationError = 'save failed — $error';
        });
      }
    }
  }

  void _showHistoryFeedback(CanvasHistoryFeedback feedback) {
    _historyTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() => _historyFeedback = feedback);
    _historyTimer = Timer(inkUndoToastDuration, _clearHistoryFeedback);
  }

  void _clearHistoryFeedback() {
    _historyTimer?.cancel();
    if (mounted && _historyFeedback != null) {
      setState(() => _historyFeedback = null);
    }
  }

  void _beginArtworkRename(EditorModel model) {
    setState(() {
      _renameLayerId = null;
      _renameText = model.document.name;
    });
  }

  void _beginLayerRename(EditorModel model, String layerId) {
    final InkLayer layer = model.contentLayers.firstWhere(
      (InkLayer candidate) => candidate.id == layerId,
    );
    setState(() {
      _renameLayerId = layerId;
      _renameText = layer.name;
    });
  }

  void _cancelRename() {
    setState(() {
      _renameLayerId = null;
      _renameText = null;
    });
  }

  Future<void> _finishRename(InkEditorSession session) async {
    final String next = _renameText?.trim() ?? '';
    if (next.isEmpty) {
      return;
    }
    final String? layerId = _renameLayerId;
    _cancelRename();
    if (layerId == null) {
      session.model.renameArtwork(next);
      await _saveChromeState();
      return;
    }
    await _updateLayer(session, layerId, name: next);
  }

  void _startMarkerHeuristic(InkEditorSession session) {
    _markerTimer?.cancel();
    unawaited(_penPresenceSubscription?.cancel());
    _sawPenEvent = false;
    final bool? override = widget.markerMissingOverride;
    if (override != null) {
      _markerMissing = override;
      if (override) {
        session.model.toolState.setFingerDrawEnabled(true);
      }
      return;
    }
    _penPresenceSubscription = session.services.pen.events.listen(
      (_) => _sawPenEvent = true,
      onError: (_) {},
    );
    _markerTimer = Timer(const Duration(seconds: 4), () async {
      var rawPressureMax = 0;
      final PenEvents pen = session.services.pen;
      if (pen is PlutoPen) {
        try {
          rawPressureMax = (await pen.capabilities()).rawPressureMax;
        } on Object {
          rawPressureMax = 0;
        }
      }
      if (!mounted || _sawPenEvent || rawPressureMax > 0) {
        return;
      }
      session.model.toolState.setFingerDrawEnabled(true);
      setState(() => _markerMissing = true);
    });
  }

  Future<void> _applyOperation(
    InkEditorSession session,
    JournaledEngineOperation operation, {
    String? activeLayerId,
  }) async {
    try {
      await session.model.applyEngineOperation(
        operation,
        activeLayerId: activeLayerId,
      );
      _canvasHandle.refreshRaster();
      await _saveChromeState();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _operationError = 'action failed — $error');
      }
    }
  }

  JournalDocumentState _journalState(EditorModel model) => JournalDocumentState(
    tiles: model.tiles,
    layers: model.contentLayers,
    canvas: model.document.canvas,
  );

  Future<void> _addLayer(InkEditorSession session) async {
    final EditorModel model = session.model;
    final int now = session.services.clock.nowMilliseconds();
    final String id = 'L$now';
    await _applyOperation(
      session,
      addLayer(
        state: _journalState(model),
        layer: InkLayer(
          id: id,
          name: 'Layer ${model.contentLayers.length + 1}',
        ),
        sequence: model.journal.nextSequence,
        timestampMs: now,
      ),
      activeLayerId: id,
    );
  }

  Future<void> _updateLayer(
    InkEditorSession session,
    String layerId, {
    String? name,
    bool? visible,
    bool? locked,
    int? opacity,
  }) => _applyOperation(
    session,
    updateLayerProperties(
      state: _journalState(session.model),
      layerId: layerId,
      sequence: session.model.journal.nextSequence,
      timestampMs: session.services.clock.nowMilliseconds(),
      name: name,
      visible: visible,
      locked: locked,
      opacity: opacity,
    ),
  );

  Future<void> _reorderLayer(
    InkEditorSession session,
    String layerId,
    int index,
  ) => _applyOperation(
    session,
    reorderLayer(
      state: _journalState(session.model),
      layerId: layerId,
      index: index,
      sequence: session.model.journal.nextSequence,
      timestampMs: session.services.clock.nowMilliseconds(),
    ),
  );

  Future<void> _duplicateLayer(InkEditorSession session, String layerId) {
    final EditorModel model = session.model;
    final InkLayer source = model.contentLayers.firstWhere(
      (InkLayer layer) => layer.id == layerId,
    );
    final int now = session.services.clock.nowMilliseconds();
    final String id = 'L$now';
    return _applyOperation(
      session,
      duplicateLayer(
        state: _journalState(model),
        sourceLayerId: layerId,
        newLayerId: id,
        newName: '${source.name} copy',
        sequence: model.journal.nextSequence,
        timestampMs: now,
      ),
      activeLayerId: id,
    );
  }

  Future<void> _deleteLayer(InkEditorSession session, String layerId) =>
      _applyOperation(
        session,
        removeLayer(
          state: _journalState(session.model),
          layerId: layerId,
          sequence: session.model.journal.nextSequence,
          timestampMs: session.services.clock.nowMilliseconds(),
        ),
      );

  Future<void> _clearLayer(InkEditorSession session, String layerId) async {
    final LayerOperationResult result = clearLayer(
      state: _journalState(session.model),
      layerId: layerId,
      sequence: session.model.journal.nextSequence,
      timestampMs: session.services.clock.nowMilliseconds(),
    );
    if (result.operation case final JournaledEngineOperation operation) {
      await _applyOperation(session, operation);
      return;
    }
    session.model.runLayerAction(layerId: result.layerId, action: () {});
  }

  Future<void> _mergeLayer(InkEditorSession session, String layerId) async {
    final LayerOperationResult result = mergeLayerDown(
      state: _journalState(session.model),
      topLayerId: layerId,
      sequence: session.model.journal.nextSequence,
      timestampMs: session.services.clock.nowMilliseconds(),
    );
    if (result.operation case final JournaledEngineOperation operation) {
      await _applyOperation(session, operation);
      return;
    }
    session.model.runLayerAction(layerId: result.layerId, action: () {});
  }

  Future<void> _flipCanvas(InkEditorSession session) => _applyOperation(
    session,
    flipCanvasHorizontally(
      state: _journalState(session.model),
      sequence: session.model.journal.nextSequence,
      timestampMs: session.services.clock.nowMilliseconds(),
    ),
  );

  Future<void> _growCanvas(
    InkEditorSession session,
    CanvasResizeAnchor anchor,
  ) async {
    final CanvasSpec canvas = session.model.document.canvas;
    final int width = math.min(
      maxInkCanvasDimension,
      (canvas.width * 1.25).ceil(),
    );
    final int height = math.min(
      maxInkCanvasDimension,
      (canvas.height * 1.25).ceil(),
    );
    if (width == canvas.width && height == canvas.height) {
      if (mounted) {
        setState(() => _operationError = 'canvas already at maximum size');
      }
      return;
    }
    await _applyOperation(
      session,
      resizeCanvas(
        state: _journalState(session.model),
        width: width,
        height: height,
        anchor: anchor,
        sequence: session.model.journal.nextSequence,
        timestampMs: session.services.clock.nowMilliseconds(),
      ),
    );
  }

  Future<void> _handleDockAction(
    EditorModel model,
    ContextualDockAction action,
  ) async {
    final ToolState tools = model.toolState;
    final Wp5ToolOptions current = tools.wp5Options;
    final EraserMode? selectedEraserMode = switch (action) {
      ContextualDockAction.eraserPixel => EraserMode.pixel,
      ContextualDockAction.eraserStroke => EraserMode.stroke,
      ContextualDockAction.eraserLasso => EraserMode.lasso,
      _ => null,
    };
    if (selectedEraserMode != null) {
      _canvasHandle.selectEraserMode(selectedEraserMode);
      if (mounted) {
        setState(() {});
      }
      await _saveChromeState();
      return;
    }
    if (_handleReferenceDockAction(tools, action)) {
      if (mounted) {
        setState(() {});
      }
      await _saveChromeState();
      return;
    }
    final CanvasToolCommand? command = inkCanvasToolCommandForDockAction(
      action,
    );
    if (command != null) {
      await _canvasHandle.runToolCommand(command);
      if (action == ContextualDockAction.dismiss) {
        tools.selectTool('draw');
      }
      if (mounted) {
        setState(() {});
      }
      await _saveChromeState();
      return;
    }
    final Wp5ToolOptions next = switch (action) {
      ContextualDockAction.selectRect => current.copyWith(
        selectionGeometry: SelectionGeometry.rectangle,
      ),
      ContextualDockAction.selectLasso => current.copyWith(
        selectionGeometry: SelectionGeometry.lasso,
      ),
      ContextualDockAction.selectWand => current.copyWith(
        selectionGeometry: SelectionGeometry.wand,
      ),
      ContextualDockAction.selectAdd => current.copyWith(
        selectionCombine: SelectionCombine.add,
      ),
      ContextualDockAction.selectSubtract => current.copyWith(
        selectionCombine: SelectionCombine.subtract,
      ),
      ContextualDockAction.selectionTolerance => current.copyWith(
        selectionTolerance: nextSelectionTolerance(current.selectionTolerance),
      ),
      ContextualDockAction.selectionGapClose => current.copyWith(
        selectionGapClose: nextSelectionGapClose(current.selectionGapClose),
      ),
      ContextualDockAction.aspect => switch (tools.selectedToolId) {
        'shape' => current.copyWith(
          shapeConstraint: current.shapeConstraint == ShapeConstraint.aspect
              ? ShapeConstraint.free
              : ShapeConstraint.aspect,
        ),
        'transform' || 'crop' => current.copyWith(
          transformAspect: current.transformAspect == TransformAspect.uniform
              ? TransformAspect.free
              : TransformAspect.uniform,
        ),
        _ => current,
      },
      ContextualDockAction.fillTolerance => current.copyWith(
        fillTolerance: current.fillTolerance > 48
            ? 0
            : current.fillTolerance + 16,
      ),
      ContextualDockAction.fillGapClose => current.copyWith(
        fillGapClose: current.fillGapClose >= 4 ? 0 : current.fillGapClose + 1,
      ),
      ContextualDockAction.fillGrow => current.copyWith(
        fillGrow: current.fillGrow >= 0 && current.fillGrow < 4
            ? current.fillGrow + 1
            : 0,
      ),
      ContextualDockAction.fillContract => current.copyWith(
        fillGrow: current.fillGrow <= 0 && current.fillGrow > -4
            ? current.fillGrow - 1
            : 0,
      ),
      ContextualDockAction.fillSampleActive => current.copyWith(
        fillSampleSource: RasterSampleSource.activeLayer,
      ),
      ContextualDockAction.fillSampleComposite => current.copyWith(
        fillSampleSource: RasterSampleSource.composite,
      ),
      ContextualDockAction.fillSolid => current.copyWith(
        fillStyle: FillStyle.solid,
      ),
      ContextualDockAction.fillHatch => current.copyWith(
        fillStyle: FillStyle.hatch,
      ),
      ContextualDockAction.fillDotScreen => current.copyWith(
        fillStyle: FillStyle.dotScreen,
      ),
      ContextualDockAction.fillBayer4 => current.copyWith(
        dotScreenDensity: DotScreenDensity.bayer4,
      ),
      ContextualDockAction.fillBayer8 => current.copyWith(
        dotScreenDensity: DotScreenDensity.bayer8,
      ),
      ContextualDockAction.shapeLine => current.copyWith(
        shapeType: ShapeType.line,
      ),
      ContextualDockAction.shapeArrow => current.copyWith(
        shapeType: ShapeType.arrow,
      ),
      ContextualDockAction.shapeRect => current.copyWith(
        shapeType: ShapeType.rectangle,
      ),
      ContextualDockAction.shapeEllipse => current.copyWith(
        shapeType: ShapeType.ellipse,
      ),
      ContextualDockAction.shapePolygon => current.copyWith(
        shapeType: ShapeType.polygon,
      ),
      ContextualDockAction.polygonSides => current.copyWith(
        polygonSides: nextPolygonSides(current.polygonSides),
      ),
      ContextualDockAction.fromCenter => current.copyWith(
        shapeOrigin: current.shapeOrigin == ShapeOrigin.center
            ? ShapeOrigin.corner
            : ShapeOrigin.center,
      ),
      ContextualDockAction.textInter => current.copyWith(
        textFont: InkTextFont.inter,
      ),
      ContextualDockAction.textMono => current.copyWith(
        textFont: InkTextFont.jetBrainsMono,
      ),
      ContextualDockAction.straightedge => current.copyWith(
        straightedgeEnabled: true,
      ),
      ContextualDockAction.straightedgeOff => current.copyWith(
        straightedgeEnabled: false,
      ),
      ContextualDockAction.gridDots => current.copyWith(
        gridStyle: GuideGridStyle.dots,
      ),
      ContextualDockAction.gridLines => current.copyWith(
        gridStyle: GuideGridStyle.lines,
      ),
      ContextualDockAction.grid8 => current.copyWith(gridSpacingDpx: 8),
      ContextualDockAction.grid16 => current.copyWith(gridSpacingDpx: 16),
      ContextualDockAction.grid32 => current.copyWith(gridSpacingDpx: 32),
      ContextualDockAction.grid64 => current.copyWith(gridSpacingDpx: 64),
      ContextualDockAction.gridOff => current.copyWith(
        gridStyle: GuideGridStyle.off,
      ),
      ContextualDockAction.symmetryVertical => current.copyWith(
        symmetryMode: InkSymmetryMode.vertical,
      ),
      ContextualDockAction.symmetryHorizontal => current.copyWith(
        symmetryMode: InkSymmetryMode.horizontal,
      ),
      ContextualDockAction.symmetryQuad => current.copyWith(
        symmetryMode: InkSymmetryMode.quad,
      ),
      ContextualDockAction.symmetryOff => current.copyWith(
        symmetryMode: InkSymmetryMode.off,
      ),
      ContextualDockAction.eraserPixel ||
      ContextualDockAction.eraserStroke ||
      ContextualDockAction.eraserLasso => current,
      ContextualDockAction.move ||
      ContextualDockAction.transform ||
      ContextualDockAction.duplicate ||
      ContextualDockAction.flipHorizontal ||
      ContextualDockAction.flipVertical ||
      ContextualDockAction.cut ||
      ContextualDockAction.copy ||
      ContextualDockAction.paste ||
      ContextualDockAction.clear ||
      ContextualDockAction.fill ||
      ContextualDockAction.toNewLayer ||
      ContextualDockAction.rotateDetent ||
      ContextualDockAction.reset ||
      ContextualDockAction.apply ||
      ContextualDockAction.perfect ||
      ContextualDockAction.textSize ||
      ContextualDockAction.textWeight ||
      ContextualDockAction.textResize ||
      ContextualDockAction.done ||
      ContextualDockAction.dismiss => throw StateError(
        'Command action ${action.name} was not routed to the canvas.',
      ),
    };
    tools.setWp5Options(next);
    await _saveChromeState();
  }

  bool _handleReferenceDockAction(
    ToolState tools,
    ContextualDockAction action,
  ) {
    final String? layerId = _referenceController.placingLayerId;
    if (tools.selectedToolId != 'transform' || layerId == null) {
      return false;
    }
    final ReferenceLayer layer = _referenceController.layers.firstWhere(
      (ReferenceLayer candidate) => candidate.id == layerId,
    );
    switch (action) {
      case ContextualDockAction.apply:
        _referenceController.commitPlacement();
        _clearReferenceDrag();
        tools.selectTool('draw');
        return true;
      case ContextualDockAction.reset:
        _referenceController
          ..cancel()
          ..beginPlacement(layerId);
        _clearReferenceDrag();
        return true;
      case ContextualDockAction.rotateDetent:
        _referenceController.updatePlacement(
          layer.placement.copyWith(
            rotationRadians: layer.placement.rotationRadians + math.pi / 12,
          ),
        );
        return true;
      case ContextualDockAction.flipHorizontal:
        _referenceController.updatePlacement(
          layer.placement.copyWith(
            isFlippedHorizontally: !layer.placement.isFlippedHorizontally,
          ),
        );
        return true;
      case ContextualDockAction.flipVertical:
        _referenceController.updatePlacement(
          layer.placement.copyWith(
            isFlippedVertically: !layer.placement.isFlippedVertically,
          ),
        );
        return true;
      case ContextualDockAction.dismiss:
        _referenceController.cancel();
        _clearReferenceDrag();
        tools.selectTool('draw');
        return true;
      default:
        return false;
    }
  }
}

/// Maps command-bearing dock actions onto the live canvas command seam.
CanvasToolCommand? inkCanvasToolCommandForDockAction(
  ContextualDockAction action,
) => switch (action) {
  ContextualDockAction.move => CanvasToolCommand.move,
  ContextualDockAction.transform => CanvasToolCommand.transform,
  ContextualDockAction.duplicate => CanvasToolCommand.duplicate,
  ContextualDockAction.flipHorizontal => CanvasToolCommand.flipHorizontal,
  ContextualDockAction.flipVertical => CanvasToolCommand.flipVertical,
  ContextualDockAction.cut => CanvasToolCommand.cut,
  ContextualDockAction.copy => CanvasToolCommand.copy,
  ContextualDockAction.paste => CanvasToolCommand.paste,
  ContextualDockAction.clear => CanvasToolCommand.clear,
  ContextualDockAction.fill => CanvasToolCommand.fill,
  ContextualDockAction.toNewLayer => CanvasToolCommand.toNewLayer,
  ContextualDockAction.perfect => CanvasToolCommand.perfect,
  ContextualDockAction.rotateDetent => CanvasToolCommand.rotateDetent,
  ContextualDockAction.reset => CanvasToolCommand.reset,
  ContextualDockAction.apply => CanvasToolCommand.apply,
  ContextualDockAction.textSize => CanvasToolCommand.textSize,
  ContextualDockAction.textWeight => CanvasToolCommand.textWeight,
  ContextualDockAction.textResize => CanvasToolCommand.textResize,
  ContextualDockAction.done => CanvasToolCommand.done,
  ContextualDockAction.dismiss => CanvasToolCommand.dismiss,
  ContextualDockAction.eraserPixel ||
  ContextualDockAction.eraserStroke ||
  ContextualDockAction.eraserLasso ||
  ContextualDockAction.selectRect ||
  ContextualDockAction.selectLasso ||
  ContextualDockAction.selectWand ||
  ContextualDockAction.selectAdd ||
  ContextualDockAction.selectSubtract ||
  ContextualDockAction.selectionTolerance ||
  ContextualDockAction.selectionGapClose ||
  ContextualDockAction.aspect ||
  ContextualDockAction.fillTolerance ||
  ContextualDockAction.fillGapClose ||
  ContextualDockAction.fillGrow ||
  ContextualDockAction.fillContract ||
  ContextualDockAction.fillSampleActive ||
  ContextualDockAction.fillSampleComposite ||
  ContextualDockAction.fillSolid ||
  ContextualDockAction.fillHatch ||
  ContextualDockAction.fillDotScreen ||
  ContextualDockAction.fillBayer4 ||
  ContextualDockAction.fillBayer8 ||
  ContextualDockAction.shapeLine ||
  ContextualDockAction.shapeArrow ||
  ContextualDockAction.shapeRect ||
  ContextualDockAction.shapeEllipse ||
  ContextualDockAction.shapePolygon ||
  ContextualDockAction.polygonSides ||
  ContextualDockAction.fromCenter ||
  ContextualDockAction.textInter ||
  ContextualDockAction.textMono ||
  ContextualDockAction.straightedge ||
  ContextualDockAction.straightedgeOff ||
  ContextualDockAction.gridDots ||
  ContextualDockAction.gridLines ||
  ContextualDockAction.grid8 ||
  ContextualDockAction.grid16 ||
  ContextualDockAction.grid32 ||
  ContextualDockAction.grid64 ||
  ContextualDockAction.gridOff ||
  ContextualDockAction.symmetryVertical ||
  ContextualDockAction.symmetryHorizontal ||
  ContextualDockAction.symmetryQuad ||
  ContextualDockAction.symmetryOff => null,
};

Widget _buildFileReferenceImage(
  BuildContext _,
  ReferenceImageDescriptor image,
) {
  final File file = File(image.sourceId);
  var cacheScale = 1.0;
  try {
    final FileStat stat = file.statSync();
    final int revision =
        stat.modified.microsecondsSinceEpoch ^
        stat.changed.microsecondsSinceEpoch ^
        stat.size;
    cacheScale += (revision & 0xfffff) / 1000000000;
  } on FileSystemException {
    // Image.file's error builder owns the user-facing missing-file fallback.
  }
  return Image.file(
    file,
    scale: cacheScale,
    fit: BoxFit.fill,
    filterQuality: FilterQuality.none,
    gaplessPlayback: true,
    cacheWidth: image.pixelWidth,
    cacheHeight: image.pixelHeight,
    errorBuilder:
        (BuildContext context, Object error, StackTrace? stackTrace) =>
            ColoredBox(color: PaperTheme.of(context).palette.grayDD),
  );
}

double _scaled(BuildContext context, double designPixels) {
  return designPixels * inkViewportFitScaleOf(context);
}

ContextualDockMode? _contextModeForTool(String toolId) => switch (toolId) {
  'erase' => ContextualDockMode.erase,
  'select' => ContextualDockMode.selection,
  'transform' => ContextualDockMode.transform,
  'fill' => ContextualDockMode.fill,
  'shape' => ContextualDockMode.shape,
  'text' => ContextualDockMode.text,
  'crop' => ContextualDockMode.crop,
  'guides' => ContextualDockMode.guides,
  _ => null,
};

Set<ContextualDockAction> _selectedDockActions(
  Wp5ToolOptions options,
  String toolId,
  EraserMode eraserMode,
) => <ContextualDockAction>{
  switch (eraserMode) {
    EraserMode.pixel => ContextualDockAction.eraserPixel,
    EraserMode.stroke => ContextualDockAction.eraserStroke,
    EraserMode.lasso => ContextualDockAction.eraserLasso,
  },
  switch (options.selectionGeometry) {
    SelectionGeometry.rectangle => ContextualDockAction.selectRect,
    SelectionGeometry.lasso => ContextualDockAction.selectLasso,
    SelectionGeometry.wand => ContextualDockAction.selectWand,
  },
  if (options.selectionCombine == SelectionCombine.add)
    ContextualDockAction.selectAdd,
  if (options.selectionCombine == SelectionCombine.subtract)
    ContextualDockAction.selectSubtract,
  if (toolId == 'shape' && options.shapeConstraint == ShapeConstraint.aspect ||
      (toolId == 'transform' || toolId == 'crop') &&
          options.transformAspect == TransformAspect.uniform)
    ContextualDockAction.aspect,
  options.fillSampleSource == RasterSampleSource.activeLayer
      ? ContextualDockAction.fillSampleActive
      : ContextualDockAction.fillSampleComposite,
  switch (options.fillStyle) {
    FillStyle.solid => ContextualDockAction.fillSolid,
    FillStyle.hatch => ContextualDockAction.fillHatch,
    FillStyle.dotScreen => ContextualDockAction.fillDotScreen,
  },
  options.dotScreenDensity == DotScreenDensity.bayer4
      ? ContextualDockAction.fillBayer4
      : ContextualDockAction.fillBayer8,
  switch (options.shapeType) {
    ShapeType.line => ContextualDockAction.shapeLine,
    ShapeType.arrow => ContextualDockAction.shapeArrow,
    ShapeType.rectangle => ContextualDockAction.shapeRect,
    ShapeType.ellipse => ContextualDockAction.shapeEllipse,
    ShapeType.polygon => ContextualDockAction.shapePolygon,
  },
  if (options.shapeOrigin == ShapeOrigin.center)
    ContextualDockAction.fromCenter,
  options.textFont == InkTextFont.inter
      ? ContextualDockAction.textInter
      : ContextualDockAction.textMono,
  if (options.straightedgeEnabled) ContextualDockAction.straightedge,
  switch (options.gridStyle) {
    GuideGridStyle.off => ContextualDockAction.gridOff,
    GuideGridStyle.dots => ContextualDockAction.gridDots,
    GuideGridStyle.lines => ContextualDockAction.gridLines,
  },
  switch (options.gridSpacingDpx) {
    8 => ContextualDockAction.grid8,
    16 => ContextualDockAction.grid16,
    32 => ContextualDockAction.grid32,
    _ => ContextualDockAction.grid64,
  },
  switch (options.symmetryMode) {
    InkSymmetryMode.off => ContextualDockAction.symmetryOff,
    InkSymmetryMode.vertical => ContextualDockAction.symmetryVertical,
    InkSymmetryMode.horizontal => ContextualDockAction.symmetryHorizontal,
    InkSymmetryMode.quad => ContextualDockAction.symmetryQuad,
  },
};

Map<String, Object?> _brushOptionsToJson(BrushPanelOptions options) =>
    <String, Object?>{
      'toneShaderDirection': options.toneShaderDirection.name,
      'hatcherMode': options.hatcherMode.name,
      'sprayDensity': options.sprayDensity,
      'stippleDensity': options.stippleDensity,
      'pencilHbGrain': options.pencilHbGrain,
      'pencil6bGrain': options.pencil6bGrain,
      'charcoalGrain': options.charcoalGrain,
    };

final class _RenameKeyboardSheet extends StatelessWidget {
  const _RenameKeyboardSheet({
    required this.value,
    required this.onChanged,
    required this.onCancel,
    required this.onDone,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCancel,
            child: const ColoredBox(color: Color(0xe6ffffff)),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: PaperSurface(
              radius: 0,
              plateShadow: true,
              padding: const EdgeInsets.all(PaperSpacing.space12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          value.isEmpty ? 'name your artwork' : value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.heading.copyWith(
                            fontFamily: 'Inter',
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 96,
                        child: PaperButton.ghost(
                          label: 'cancel',
                          onPressed: onCancel,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: PaperSpacing.space8),
                  SizedBox(
                    height: 280,
                    child: PaperKeyboard(
                      onText: (String inserted) => onChanged('$value$inserted'),
                      onBackspace: () {
                        if (value.isNotEmpty) {
                          onChanged(value.substring(0, value.length - 1));
                        }
                      },
                      onSubmit: onDone,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ReferenceImportSheet extends StatelessWidget {
  const _ReferenceImportSheet({
    required this.candidates,
    required this.onCancel,
    required this.onSelected,
  });

  final List<GalleryImportCandidate> candidates;
  final VoidCallback onCancel;
  final ValueChanged<GalleryImportCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('import reference', style: theme.type.heading),
                  ),
                  PaperButton.ghost(label: 'cancel', onPressed: onCancel),
                ],
              ),
              const SizedBox(height: PaperSpacing.space12),
              if (candidates.isEmpty)
                Text(
                  'drop PNG or JPEG files into documents/imports over USB',
                  style: theme.type.body,
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: SingleChildScrollView(
                    child: Column(
                      children: <Widget>[
                        for (final GalleryImportCandidate candidate
                            in candidates)
                          PaperListItem(
                            key: ValueKey<String>(
                              'reference-import-${candidate.name}',
                            ),
                            title: candidate.name,
                            subtitle: 'place as locked reference',
                            onTap: () => onSelected(candidate),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _EditorMenuSheet extends StatelessWidget {
  const _EditorMenuSheet({
    required this.onClose,
    required this.onExport,
    required this.onImportReference,
    required this.onSettings,
    required this.onFlipHorizontal,
    required this.resizeAnchor,
    required this.onResizeAnchorChanged,
    required this.onGrowCanvas,
    required this.onClearLayer,
    required this.onDeepClean,
  });

  final VoidCallback onClose;
  final VoidCallback onExport;
  final VoidCallback onImportReference;
  final VoidCallback? onSettings;
  final VoidCallback onFlipHorizontal;
  final CanvasResizeAnchor resizeAnchor;
  final ValueChanged<CanvasResizeAnchor> onResizeAnchorChanged;
  final ValueChanged<CanvasResizeAnchor> onGrowCanvas;
  final VoidCallback onClearLayer;
  final VoidCallback onDeepClean;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _scaled(context, 400),
      child: PaperSurface(
        radius: 0,
        plateShadow: true,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MenuRow(label: 'close menu', onPressed: onClose),
            _MenuRow(label: 'export', onPressed: onExport),
            _MenuRow(label: 'flip canvas H', onPressed: onFlipHorizontal),
            InkCanvasGrowControls(
              selectedAnchor: resizeAnchor,
              onAnchorSelected: onResizeAnchorChanged,
              onGrow: onGrowCanvas,
            ),
            _MenuRow(label: 'clear active layer', onPressed: onClearLayer),
            _MenuRow(
              label: 'import reference · documents/imports',
              onPressed: onImportReference,
            ),
            _MenuRow(label: 'settings', onPressed: onSettings),
            _MenuRow(label: 'deep clean', onPressed: onDeepClean),
            _MenuRow(
              label: 'Ink 0.1 · help',
              onPressed: () => unawaited(
                PaperDialogs.showSheet<void>(
                  context,
                  builder: (BuildContext sheetContext) => _EditorHelpSheet(
                    onDone: () => Navigator.of(sheetContext).pop(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _EditorHelpSheet extends StatelessWidget {
  const _EditorHelpSheet({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text('Ink 0.1.0', style: theme.type.heading)),
                  PaperButton.ghost(label: 'done', onPressed: onDone),
                ],
              ),
              const SizedBox(height: PaperSpacing.space12),
              Text('drawing app for Pluto', style: theme.type.body),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: PaperButton.ghost(label: label, onPressed: onPressed),
    );
  }
}

final class _EditorBootState extends StatelessWidget {
  const _EditorBootState({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Ink',
              style: theme.type.display.copyWith(
                color: theme.palette.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: PaperSpacing.space12),
            Text(
              error == null ? 'opening canvas…' : 'could not open canvas',
              style: theme.type.body.copyWith(
                color: error == null ? theme.palette.gray33 : theme.palette.ink,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: PaperSpacing.space12),
            PaperButton.ghost(
              label: 'exit',
              onPressed: () => unawaited(SystemNavigator.pop()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loaded editor resources shared by the application shell and [EditorPage].
final class InkEditorSession {
  /// Creates an editor session around one model and service bundle.
  InkEditorSession({required this.services, required this.model});

  final InkServices services;
  final EditorModel model;
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await model.journal.close();
    model.dispose();
  }
}

/// Opens [artworkId], recovers its journal, and returns a ready editor model.
///
/// When no readable artwork exists, this creates the first-run `start here`
/// page so the application never boots into a dead editor.
Future<InkEditorSession> openInkEditorSession(
  InkServices services, {
  String? artworkId,
}) async {
  LoadedInkDocument? loaded;
  if (artworkId != null) {
    loaded = await services.store.openDocument(artworkId);
  } else {
    final List<GalleryEntry> gallery = await services.store.loadGallery();
    for (final GalleryEntry entry in gallery) {
      loaded = await services.store.openDocument(entry.id);
      if (loaded != null) {
        break;
      }
    }
  }
  if (loaded == null) {
    final int nowMs = services.clock.nowMilliseconds();
    final InkDocument document = InkDocument.blank(
      id: 'ink-$nowMs',
      nowMs: nowMs,
      name: 'start here',
    );
    final TileStore tiles = TileStore();
    final InkDocument persisted = await services.store.saveDocument(
      document,
      tiles,
    );
    loaded = LoadedInkDocument(
      document: persisted,
      tiles: tiles,
      issues: const <DocumentLoadIssue>[],
    );
  }
  final FileJournalStorage journalStorage = FileJournalStorage(
    root: Directory(
      '${services.store.artworkDirectory(loaded.document.id).path}/journal',
    ),
    nowMilliseconds: services.clock.nowMilliseconds,
  );
  final UndoJournal journal = await UndoJournal.open(
    storage: journalStorage,
    recipeRenderer: replayJournalStrokeRecipe,
    now: services.clock.now,
  );
  final JournalRecovery recovery = await journal.recoverFromManifest(
    manifestState: JournalDocumentState(
      tiles: loaded.tiles,
      layers: loaded.document.layers,
      canvas: loaded.document.canvas,
    ),
    manifestHeadSeq: loaded.document.journalHeadSeq,
  );
  final List<InkLayer> recoveredLayers = recovery.state.layers;
  final String recoveredActiveLayerId =
      recoveredLayers.any(
        (InkLayer layer) => layer.id == loaded!.document.activeLayerId,
      )
      ? loaded.document.activeLayerId
      : recoveredLayers.last.id;
  final InkDocument recoveredDocument = loaded.document.copyWith(
    canvas: recovery.state.canvas,
    layers: recoveredLayers,
    activeLayerId: recoveredActiveLayerId,
    journalHeadSeq: recovery.reconciledHeadSeq,
  );
  return InkEditorSession(
    services: services,
    model: EditorModel(
      document: recoveredDocument,
      tiles: recovery.state.tiles,
      journal: journal,
    ),
  );
}
