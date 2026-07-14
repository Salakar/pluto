import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../glyphs.dart';
import '../responsive_layout.dart';

/// Width of the layers sheet in the 954 x 1696 authored coordinate space.
const double layersPanelDesignWidth = 437;

/// Full layers-sheet height below the authored 88-dpx status band.
const double layersPanelDesignHeight = 1608;

/// Height of every content, reference, add, and menu action row.
const double layersPanelRowDesignHeight = 80;

/// Maximum number of document content layers.
const int layersPanelContentCap = 12;

/// Maximum number of separately composited reference layers.
const int layersPanelReferenceCap = 2;

/// Number of opacity positions on each inline layer rail.
const int layersPanelOpacityNotchCount = 16;

const double _headerDesignHeight = 80;
const double _sectionDesignHeight = 40;
const double _thumbnailCellDesignWidth = 80;
const double _actionCellDesignWidth = 80;
const double _infoDesignWidth =
    layersPanelDesignWidth -
    _thumbnailCellDesignWidth -
    _actionCellDesignWidth * 3;
const double _menuDesignWidth = 320;

/// Callback for an operation addressed to one stable layer id.
typedef LayerIdCallback = void Function(String layerId);

/// Callback for a visibility replacement on one stable layer id.
typedef LayerVisibilityChanged = void Function(String layerId, bool isVisible);

/// Callback for a lock replacement on one stable layer id.
typedef LayerLockChanged = void Function(String layerId, bool isLocked);

/// Callback for a lattice-safe opacity replacement from zero through 100.
typedef LayerOpacityChanged = void Function(String layerId, int opacityPercent);

/// Callback for a drag reorder within one layer stack.
typedef LayerReorderCallback = void Function(String layerId, int newIndex);

/// Immutable values needed to synchronously paint one layers-panel row.
final class LayerPanelItem {
  /// Creates one content or reference row description.
  const LayerPanelItem({
    required this.id,
    required this.name,
    this.opacityPercent = 100,
    this.isVisible = true,
    this.isLocked = false,
    this.thumbnailPainter,
    this.thumbnailSeed = 0,
  }) : assert(opacityPercent >= 0 && opacityPercent <= 100);

  /// Stable layer identity used by every callback.
  final String id;

  /// User-visible layer name.
  final String name;

  /// Layer opacity from zero through 100.
  final int opacityPercent;

  /// Whether this layer participates in composition.
  final bool isVisible;

  /// Whether mutating drawing operations are blocked for this layer.
  final bool isLocked;

  /// Optional synchronous painter for the 64-by-64 live thumbnail.
  ///
  /// Hosts should supply a tile-backed painter, never an image-decoding widget.
  final CustomPainter? thumbnailPainter;

  /// Stable fallback thumbnail variation when [thumbnailPainter] is absent.
  final int thumbnailSeed;
}

/// A fixed-height layer manager with separate reference and content stacks.
///
/// All menus, thumbnails, rails, and drag ghosts paint synchronously. The host
/// owns document mutations and journal entries; this widget emits typed intents.
final class LayersPanel extends StatefulWidget {
  /// Creates the layers sheet.
  const LayersPanel({
    required this.layers,
    required this.activeLayerId,
    required this.onClose,
    required this.onLayerSelected,
    this.referenceLayers = const <LayerPanelItem>[],
    this.onAddLayer,
    this.onVisibilityChanged,
    this.onLockChanged,
    this.onOpacityChanged,
    this.onLayerReordered,
    this.onReferenceReordered,
    this.onRenameLayer,
    this.onDuplicateLayer,
    this.onMergeLayerDown,
    this.onClearLayer,
    this.onDeleteLayer,
    this.onDeleteReference,
    super.key,
  }) : assert(layers.length <= layersPanelContentCap),
       assert(referenceLayers.length <= layersPanelReferenceCap);

  /// Content layers in front-to-back panel order.
  final List<LayerPanelItem> layers;

  /// Reference layers in their independent front-to-back order.
  final List<LayerPanelItem> referenceLayers;

  /// Stable id of the active content layer.
  final String activeLayerId;

  /// Closes this sheet without changing the active layer.
  final VoidCallback onClose;

  /// Selects a content or reference row.
  final LayerIdCallback onLayerSelected;

  /// Adds a content layer when below the cap; null disables the add row.
  final VoidCallback? onAddLayer;

  /// Replaces one layer's visibility.
  final LayerVisibilityChanged? onVisibilityChanged;

  /// Replaces one layer's lock state.
  final LayerLockChanged? onLockChanged;

  /// Replaces one layer's opacity with a 16-notch snapped value.
  final LayerOpacityChanged? onOpacityChanged;

  /// Reorders a content layer within the content stack.
  final LayerReorderCallback? onLayerReordered;

  /// Reorders a reference within the separate reference stack.
  final LayerReorderCallback? onReferenceReordered;

  /// Starts the host's rename flow from the long-press action menu.
  final LayerIdCallback? onRenameLayer;

  /// Duplicates the addressed content layer.
  final LayerIdCallback? onDuplicateLayer;

  /// Merges the addressed content layer into the row below it.
  final LayerIdCallback? onMergeLayerDown;

  /// Clears all marks from the addressed content layer.
  final LayerIdCallback? onClearLayer;

  /// Deletes the addressed content layer.
  final LayerIdCallback? onDeleteLayer;

  /// Deletes the addressed reference layer.
  final LayerIdCallback? onDeleteReference;

  @override
  State<LayersPanel> createState() => _LayersPanelState();
}

final class _LayersPanelState extends State<LayersPanel> {
  String? _menuLayerId;

  void _showMenu(String layerId) {
    setState(() {
      _menuLayerId = layerId;
    });
  }

  void _hideMenu() {
    if (_menuLayerId == null) {
      return;
    }
    setState(() {
      _menuLayerId = null;
    });
  }

  void _runMenuAction(LayerIdCallback? callback, String layerId) {
    _hideMenu();
    callback?.call(layerId);
  }

  @override
  Widget build(BuildContext context) {
    _validateLayers(
      layers: widget.layers,
      references: widget.referenceLayers,
      activeLayerId: widget.activeLayerId,
    );
    final _LayersPanelScale scale = _LayersPanelScale.of(context);
    final String? menuLayerId = _menuLayerId;
    final int menuLayerIndex = menuLayerId == null
        ? -1
        : widget.layers.indexWhere(
            (LayerPanelItem item) => item.id == menuLayerId,
          );
    final LayerPanelItem? menuLayer = menuLayerIndex < 0
        ? null
        : widget.layers[menuLayerIndex];

    return SizedBox(
      width: scale.u(layersPanelDesignWidth),
      height: scale.u(layersPanelDesignHeight),
      child: PaperSurface(
        plateShadow: true,
        radius: 0,
        padding: EdgeInsets.zero,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label:
              'Layers panel, ${widget.layers.length} content layers, '
              '${widget.referenceLayers.length} references',
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Column(
                children: <Widget>[
                  _LayersPanelHeader(scale: scale, onClose: widget.onClose),
                  _SectionRow(
                    label:
                        'REFERENCES  ${widget.referenceLayers.length}/$layersPanelReferenceCap',
                    glyph: InkGlyph.markPin,
                    scale: scale,
                  ),
                  for (
                    int index = 0;
                    index < widget.referenceLayers.length;
                    index += 1
                  )
                    _LayerRow(
                      item: widget.referenceLayers[index],
                      active:
                          widget.referenceLayers[index].id ==
                          widget.activeLayerId,
                      isReference: true,
                      targetIndex: index,
                      scale: scale,
                      onSelected: widget.onLayerSelected,
                      onVisibilityChanged: widget.onVisibilityChanged,
                      onLockChanged: widget.onLockChanged,
                      onOpacityChanged: widget.onOpacityChanged,
                      onReordered: widget.onReferenceReordered,
                      onLongPress: widget.onDeleteReference == null
                          ? null
                          : () => widget.onDeleteReference?.call(
                              widget.referenceLayers[index].id,
                            ),
                    ),
                  _SectionRow(
                    label:
                        'CONTENT  ${widget.layers.length}/$layersPanelContentCap',
                    glyph: InkGlyph.markLayers,
                    scale: scale,
                  ),
                  _AddLayerRow(
                    atCap: widget.layers.length >= layersPanelContentCap,
                    scale: scale,
                    onAdd: widget.layers.length >= layersPanelContentCap
                        ? null
                        : widget.onAddLayer,
                  ),
                  for (int index = 0; index < widget.layers.length; index += 1)
                    _LayerRow(
                      item: widget.layers[index],
                      active: widget.layers[index].id == widget.activeLayerId,
                      isReference: false,
                      targetIndex: index,
                      scale: scale,
                      onSelected: widget.onLayerSelected,
                      onVisibilityChanged: widget.onVisibilityChanged,
                      onLockChanged: widget.onLockChanged,
                      onOpacityChanged: widget.onOpacityChanged,
                      onReordered: widget.onLayerReordered,
                      onLongPress: () => _showMenu(widget.layers[index].id),
                    ),
                  const Spacer(),
                ],
              ),
              if (menuLayer != null)
                _MenuVeil(
                  layer: menuLayer,
                  canMergeDown: menuLayerIndex < widget.layers.length - 1,
                  canDelete: widget.layers.length > 1,
                  scale: scale,
                  onDismiss: _hideMenu,
                  onRename: widget.onRenameLayer == null
                      ? null
                      : () =>
                            _runMenuAction(widget.onRenameLayer, menuLayer.id),
                  onDuplicate: widget.onDuplicateLayer == null
                      ? null
                      : () => _runMenuAction(
                          widget.onDuplicateLayer,
                          menuLayer.id,
                        ),
                  onMergeDown:
                      widget.onMergeLayerDown == null ||
                          menuLayerIndex >= widget.layers.length - 1
                      ? null
                      : () => _runMenuAction(
                          widget.onMergeLayerDown,
                          menuLayer.id,
                        ),
                  onClear: widget.onClearLayer == null
                      ? null
                      : () => _runMenuAction(widget.onClearLayer, menuLayer.id),
                  onDelete:
                      widget.onDeleteLayer == null || widget.layers.length <= 1
                      ? null
                      : () =>
                            _runMenuAction(widget.onDeleteLayer, menuLayer.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _LayersPanelHeader extends StatelessWidget {
  const _LayersPanelHeader({required this.scale, required this.onClose});

  final _LayersPanelScale scale;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      height: scale.u(_headerDesignHeight),
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: scale.u(_headerDesignHeight),
              child: CustomPaint(
                painter: InkGlyphPainter(
                  glyph: InkGlyph.markLayers,
                  color: theme.palette.ink,
                  strokeWidth: scale.rule,
                ),
              ),
            ),
            Expanded(
              child: Text(
                'LAYERS',
                maxLines: 1,
                style: theme.type.heading.copyWith(
                  color: theme.palette.ink,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            _CloseButton(scale: scale, onPressed: onClose),
          ],
        ),
      ),
    );
  }
}

final class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.label,
    required this.glyph,
    required this.scale,
  });

  final String label;
  final InkGlyph glyph;
  final _LayersPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      height: scale.u(_sectionDesignHeight),
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: scale.u(28),
                child: CustomPaint(
                  painter: InkGlyphPainter(
                    glyph: glyph,
                    color: theme.palette.ink,
                    strokeWidth: scale.rule,
                  ),
                ),
              ),
              SizedBox(width: scale.u(8)),
              Text(
                label,
                maxLines: 1,
                style: theme.type.caption.copyWith(
                  color: theme.palette.ink,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AddLayerRow extends StatefulWidget {
  const _AddLayerRow({
    required this.atCap,
    required this.scale,
    required this.onAdd,
  });

  final bool atCap;
  final _LayersPanelScale scale;
  final VoidCallback? onAdd;

  @override
  State<_AddLayerRow> createState() => _AddLayerRowState();
}

final class _AddLayerRowState extends State<_AddLayerRow> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool enabled = widget.onAdd != null;
    final Color background = _pressed ? theme.palette.ink : theme.palette.paper;
    final Color foreground = !enabled
        ? theme.palette.gray66
        : _pressed
        ? theme.palette.paper
        : theme.palette.ink;
    final String label = widget.atCap
        ? 'HEAVY ARTWORK  $layersPanelContentCap/$layersPanelContentCap'
        : '+ LAYER';
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: widget.onAdd,
      child: GestureDetector(
        key: const ValueKey<String>('layers-add'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTap: widget.onAdd,
        child: SizedBox(
          height: widget.scale.u(layersPanelRowDesignHeight),
          width: double.infinity,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: widget.scale.rule,
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: widget.scale.u(layersPanelRowDesignHeight),
                  child: CustomPaint(
                    painter: widget.atCap
                        ? InkGlyphPainter(
                            glyph: InkGlyph.markHeavy,
                            color: foreground,
                            strokeWidth: widget.scale.rule,
                          )
                        : _PlusPainter(
                            color: foreground,
                            strokeWidth: widget.scale.rule,
                          ),
                  ),
                ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    style: theme.type.label.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _LayerRow extends StatefulWidget {
  const _LayerRow({
    required this.item,
    required this.active,
    required this.isReference,
    required this.targetIndex,
    required this.scale,
    required this.onSelected,
    required this.onVisibilityChanged,
    required this.onLockChanged,
    required this.onOpacityChanged,
    required this.onReordered,
    required this.onLongPress,
  });

  final LayerPanelItem item;
  final bool active;
  final bool isReference;
  final int targetIndex;
  final _LayersPanelScale scale;
  final LayerIdCallback onSelected;
  final LayerVisibilityChanged? onVisibilityChanged;
  final LayerLockChanged? onLockChanged;
  final LayerOpacityChanged? onOpacityChanged;
  final LayerReorderCallback? onReordered;
  final VoidCallback? onLongPress;

  @override
  State<_LayerRow> createState() => _LayerRowState();
}

final class _LayerRowState extends State<_LayerRow> {
  bool _dragging = false;

  void _setDragging(bool value) {
    if (_dragging == value || !mounted) {
      return;
    }
    setState(() {
      _dragging = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Color background = widget.active
        ? theme.palette.ink
        : theme.palette.paper;
    final Color foreground = widget.active
        ? theme.palette.paper
        : theme.palette.ink;
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> details) =>
          widget.onReordered != null && details.data != widget.item.id,
      onAcceptWithDetails: (DragTargetDetails<String> details) =>
          widget.onReordered?.call(details.data, widget.targetIndex),
      builder:
          (
            BuildContext context,
            List<String?> candidateData,
            List<dynamic> rejectedData,
          ) {
            final bool isDropTarget = candidateData.isNotEmpty;
            return Semantics(
              container: true,
              selected: widget.active,
              label:
                  '${widget.isReference ? 'Reference' : 'Layer'} '
                  '${widget.item.name}, ${widget.item.opacityPercent} percent, '
                  '${widget.item.isVisible ? 'visible' : 'hidden'}, '
                  '${widget.item.isLocked ? 'locked' : 'unlocked'}',
              onLongPress: widget.onLongPress,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: widget.onLongPress,
                child: SizedBox(
                  width: double.infinity,
                  height: widget.scale.u(layersPanelRowDesignHeight),
                  child: CustomPaint(
                    foregroundPainter: _dragging || isDropTarget
                        ? _DashedRowPainter(
                            color: isDropTarget
                                ? theme.palette.accentBlue
                                : foreground,
                            scale: widget.scale.value,
                          )
                        : null,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: background,
                        border: Border(
                          bottom: BorderSide(
                            color: foreground,
                            width: widget.scale.rule,
                          ),
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          _ThumbnailCell(
                            item: widget.item,
                            isReference: widget.isReference,
                            foreground: foreground,
                            background: background,
                            scale: widget.scale,
                            onSelected: () => widget.onSelected(widget.item.id),
                          ),
                          Expanded(
                            child: SizedBox(
                              height: double.infinity,
                              child: _LayerInfo(
                                item: widget.item,
                                foreground: foreground,
                                background: background,
                                scale: widget.scale,
                                onOpacityChanged: widget.onOpacityChanged,
                              ),
                            ),
                          ),
                          _GlyphAction(
                            semanticsLabel: widget.item.isVisible
                                ? 'Hide ${widget.item.name}'
                                : 'Show ${widget.item.name}',
                            glyph: widget.item.isVisible
                                ? InkGlyph.markEyeOpen
                                : InkGlyph.markEyeClosed,
                            foreground: foreground,
                            background: background,
                            scale: widget.scale,
                            onPressed: widget.onVisibilityChanged == null
                                ? null
                                : () => widget.onVisibilityChanged?.call(
                                    widget.item.id,
                                    !widget.item.isVisible,
                                  ),
                          ),
                          _GlyphAction(
                            semanticsLabel: widget.item.isLocked
                                ? 'Unlock ${widget.item.name}'
                                : 'Lock ${widget.item.name}',
                            glyph: widget.item.isLocked
                                ? InkGlyph.markLock
                                : InkGlyph.markUnlock,
                            foreground: foreground,
                            background: background,
                            scale: widget.scale,
                            onPressed: widget.onLockChanged == null
                                ? null
                                : () => widget.onLockChanged?.call(
                                    widget.item.id,
                                    !widget.item.isLocked,
                                  ),
                          ),
                          _DragHandle(
                            item: widget.item,
                            foreground: foreground,
                            background: background,
                            scale: widget.scale,
                            enabled: widget.onReordered != null,
                            onDragStarted: () => _setDragging(true),
                            onDragEnded: () => _setDragging(false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
    );
  }
}

final class _ThumbnailCell extends StatelessWidget {
  const _ThumbnailCell({
    required this.item,
    required this.isReference,
    required this.foreground,
    required this.background,
    required this.scale,
    required this.onSelected,
  });

  final LayerPanelItem item;
  final bool isReference;
  final Color foreground;
  final Color background;
  final _LayersPanelScale scale;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Select ${item.name}',
      onTap: onSelected,
      child: GestureDetector(
        key: ValueKey<String>('layer-select-${item.id}'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onSelected,
        child: SizedBox.square(
          dimension: scale.u(_thumbnailCellDesignWidth),
          child: Padding(
            padding: EdgeInsets.all(scale.u(8)),
            child: CustomPaint(
              painter:
                  item.thumbnailPainter ??
                  _FallbackThumbnailPainter(
                    seed: item.thumbnailSeed,
                    isReference: isReference,
                    isVisible: item.isVisible,
                    ink: foreground,
                    paper: background,
                    rule: scale.rule,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _LayerInfo extends StatelessWidget {
  const _LayerInfo({
    required this.item,
    required this.foreground,
    required this.background,
    required this.scale,
    required this.onOpacityChanged,
  });

  final LayerPanelItem item;
  final Color foreground;
  final Color background;
  final _LayersPanelScale scale;
  final LayerOpacityChanged? onOpacityChanged;

  void _setOpacity(Offset localPosition) {
    final LayerOpacityChanged? callback = onOpacityChanged;
    if (callback == null) {
      return;
    }
    final double width = scale.u(_infoDesignWidth);
    final int notch = (localPosition.dx / width * layersPanelOpacityNotchCount)
        .floor()
        .clamp(0, layersPanelOpacityNotchCount - 1);
    callback(
      item.id,
      (notch * 100 / (layersPanelOpacityNotchCount - 1)).round(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool enabled = onOpacityChanged != null;
    return Semantics(
      slider: true,
      enabled: enabled,
      label: '${item.name} opacity',
      value: '${item.opacityPercent} percent',
      increasedValue:
          '${math.min(100, _nextOpacity(item.opacityPercent, 1))} percent',
      decreasedValue:
          '${math.max(0, _nextOpacity(item.opacityPercent, -1))} percent',
      onIncrease: enabled
          ? () => onOpacityChanged?.call(
              item.id,
              _nextOpacity(item.opacityPercent, 1),
            )
          : null,
      onDecrease: enabled
          ? () => onOpacityChanged?.call(
              item.id,
              _nextOpacity(item.opacityPercent, -1),
            )
          : null,
      child: GestureDetector(
        key: ValueKey<String>('layer-opacity-${item.id}'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled
            ? (TapDownDetails details) => _setOpacity(details.localPosition)
            : null,
        onHorizontalDragStart: enabled
            ? (DragStartDetails details) => _setOpacity(details.localPosition)
            : null,
        onHorizontalDragUpdate: enabled
            ? (DragUpdateDetails details) => _setOpacity(details.localPosition)
            : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: scale.u(5)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.label.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${item.opacityPercent}%',
                      maxLines: 1,
                      style: theme.type.mono.copyWith(
                        color: foreground,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: scale.u(30),
                child: CustomPaint(
                  painter: _OpacityRailPainter(
                    opacityPercent: item.opacityPercent,
                    foreground: enabled ? foreground : theme.palette.gray66,
                    background: background,
                    scale: scale.value,
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

final class _GlyphAction extends StatefulWidget {
  const _GlyphAction({
    required this.semanticsLabel,
    required this.glyph,
    required this.foreground,
    required this.background,
    required this.scale,
    required this.onPressed,
  });

  final String semanticsLabel;
  final InkGlyph glyph;
  final Color foreground;
  final Color background;
  final _LayersPanelScale scale;
  final VoidCallback? onPressed;

  @override
  State<_GlyphAction> createState() => _GlyphActionState();
}

final class _GlyphActionState extends State<_GlyphAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    final bool enabled = widget.onPressed != null;
    final Color background = _pressed ? widget.foreground : widget.background;
    final Color foreground = !enabled
        ? palette.gray66
        : _pressed
        ? widget.background
        : widget.foreground;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticsLabel,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.scale.u(_actionCellDesignWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                left: BorderSide(color: foreground, width: widget.scale.rule),
              ),
            ),
            child: CustomPaint(
              painter: InkGlyphPainter(
                glyph: widget.glyph,
                color: foreground,
                strokeWidth: widget.scale.rule,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.item,
    required this.foreground,
    required this.background,
    required this.scale,
    required this.enabled,
    required this.onDragStarted,
    required this.onDragEnded,
  });

  final LayerPanelItem item;
  final Color foreground;
  final Color background;
  final _LayersPanelScale scale;
  final bool enabled;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;

  @override
  Widget build(BuildContext context) {
    final Widget handle = SizedBox.square(
      dimension: scale.u(_actionCellDesignWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          border: Border(
            left: BorderSide(color: foreground, width: scale.rule),
          ),
        ),
        child: CustomPaint(
          painter: InkGlyphPainter(
            glyph: InkGlyph.benchGrip,
            color: enabled ? foreground : PaperTheme.of(context).palette.gray66,
            strokeWidth: scale.rule,
          ),
        ),
      ),
    );
    if (!enabled) {
      return Semantics(
        enabled: false,
        label: 'Reorder ${item.name}',
        child: handle,
      );
    }
    return Semantics(
      button: true,
      label: 'Drag to reorder ${item.name}',
      child: LongPressDraggable<String>(
        key: ValueKey<String>('layer-drag-${item.id}'),
        data: item.id,
        onDragStarted: onDragStarted,
        onDragEnd: (DraggableDetails details) => onDragEnded(),
        feedback: SizedBox(
          width: scale.u(layersPanelDesignWidth),
          height: scale.u(layersPanelRowDesignHeight),
          child: CustomPaint(
            painter: _DashedRowPainter(color: foreground, scale: scale.value),
          ),
        ),
        childWhenDragging: handle,
        child: handle,
      ),
    );
  }
}

final class _MenuVeil extends StatelessWidget {
  const _MenuVeil({
    required this.layer,
    required this.canMergeDown,
    required this.canDelete,
    required this.scale,
    required this.onDismiss,
    required this.onRename,
    required this.onDuplicate,
    required this.onMergeDown,
    required this.onClear,
    required this.onDelete,
  });

  final LayerPanelItem layer;
  final bool canMergeDown;
  final bool canDelete;
  final _LayersPanelScale scale;
  final VoidCallback onDismiss;
  final VoidCallback? onRename;
  final VoidCallback? onDuplicate;
  final VoidCallback? onMergeDown;
  final VoidCallback? onClear;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Semantics(
          button: true,
          label: 'Dismiss layer actions',
          onTap: onDismiss,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0xd9ffffff)),
          ),
        ),
        Center(
          child: SizedBox(
            width: scale.u(_menuDesignWidth),
            height: scale.u(layersPanelRowDesignHeight * 6),
            child: PaperSurface(
              plateShadow: true,
              radius: 0,
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  SizedBox(
                    width: double.infinity,
                    height: scale.u(layersPanelRowDesignHeight),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.palette.ink,
                        border: Border(
                          bottom: BorderSide(
                            color: theme.palette.paper,
                            width: scale.rule,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: scale.u(12)),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            layer.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.label.copyWith(
                              color: theme.palette.paper,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _MenuActionButton(
                    label: 'rename',
                    glyph: InkGlyph.markText,
                    scale: scale,
                    onPressed: onRename,
                  ),
                  _MenuActionButton(
                    label: 'duplicate',
                    glyph: InkGlyph.markDuplicate,
                    scale: scale,
                    onPressed: onDuplicate,
                  ),
                  _MenuActionButton(
                    label: canMergeDown ? 'merge down' : 'merge down · bottom',
                    glyph: InkGlyph.markMergeDown,
                    scale: scale,
                    onPressed: onMergeDown,
                  ),
                  _MenuActionButton(
                    label: 'clear',
                    glyph: InkGlyph.markErase,
                    scale: scale,
                    onPressed: onClear,
                  ),
                  _MenuActionButton(
                    label: canDelete ? 'delete' : 'delete · last layer',
                    glyph: InkGlyph.markTrash,
                    scale: scale,
                    onPressed: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _MenuActionButton extends StatefulWidget {
  const _MenuActionButton({
    required this.label,
    required this.glyph,
    required this.scale,
    required this.onPressed,
  });

  final String label;
  final InkGlyph glyph;
  final _LayersPanelScale scale;
  final VoidCallback? onPressed;

  @override
  State<_MenuActionButton> createState() => _MenuActionButtonState();
}

final class _MenuActionButtonState extends State<_MenuActionButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool enabled = widget.onPressed != null;
    final Color background = _pressed ? theme.palette.ink : theme.palette.paper;
    final Color foreground = !enabled
        ? theme.palette.gray66
        : _pressed
        ? theme.palette.paper
        : theme.palette.ink;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTap: widget.onPressed,
        child: SizedBox(
          width: double.infinity,
          height: widget.scale.u(layersPanelRowDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: widget.scale.rule,
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: widget.scale.u(layersPanelRowDesignHeight),
                  child: CustomPaint(
                    painter: InkGlyphPainter(
                      glyph: widget.glyph,
                      color: foreground,
                      strokeWidth: widget.scale.rule,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    style: theme.type.label.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _FallbackThumbnailPainter extends CustomPainter {
  const _FallbackThumbnailPainter({
    required this.seed,
    required this.isReference,
    required this.isVisible,
    required this.ink,
    required this.paper,
    required this.rule,
  });

  final int seed;
  final bool isReference;
  final bool isVisible;
  final Color ink;
  final Color paper;
  final double rule;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..color = paper
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds.deflate(rule / 2),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );
    final Paint mark = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(rule, size.shortestSide * 0.045)
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    if (isReference) {
      final Rect frame = bounds.deflate(size.shortestSide * 0.18);
      canvas.drawRect(frame, mark);
      canvas.drawLine(frame.bottomLeft, frame.center, mark);
      canvas.drawLine(frame.center, frame.topRight, mark);
    } else {
      final double phase = (seed.abs() % 7) / 7;
      final Path stroke = Path()..moveTo(size.width * 0.12, size.height * 0.7);
      for (int index = 1; index <= 8; index += 1) {
        final double t = index / 8;
        stroke.lineTo(
          size.width * (0.12 + 0.76 * t),
          size.height * (0.5 + math.sin((t + phase) * math.pi * 2) * 0.22),
        );
      }
      canvas.drawPath(stroke, mark);
    }
    if (!isVisible) {
      canvas.drawLine(bounds.topLeft, bounds.bottomRight, mark);
      canvas.drawLine(bounds.topRight, bounds.bottomLeft, mark);
    }
  }

  @override
  bool shouldRepaint(_FallbackThumbnailPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.isReference != isReference ||
      oldDelegate.isVisible != isVisible ||
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.rule != rule;
}

final class _OpacityRailPainter extends CustomPainter {
  const _OpacityRailPainter({
    required this.opacityPercent,
    required this.foreground,
    required this.background,
    required this.scale,
  });

  final int opacityPercent;
  final Color foreground;
  final Color background;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final int selected =
        (opacityPercent * (layersPanelOpacityNotchCount - 1) / 100).round();
    final double gap = math.max(0.5, scale);
    final double notchWidth = size.width / layersPanelOpacityNotchCount;
    final Paint fill = Paint()..isAntiAlias = false;
    for (int index = 0; index < layersPanelOpacityNotchCount; index += 1) {
      final double height = index == selected
          ? size.height
          : size.height * 0.55;
      final Rect notch = Rect.fromLTWH(
        index * notchWidth + gap / 2,
        size.height - height,
        math.max(0.5, notchWidth - gap),
        height,
      );
      fill.color = index <= selected ? foreground : background;
      fill.style = PaintingStyle.fill;
      canvas.drawRect(notch, fill);
      fill
        ..color = foreground
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.5, scale);
      canvas.drawRect(notch, fill);
    }
  }

  @override
  bool shouldRepaint(_OpacityRailPainter oldDelegate) =>
      oldDelegate.opacityPercent != opacityPercent ||
      oldDelegate.foreground != foreground ||
      oldDelegate.background != background ||
      oldDelegate.scale != scale;
}

final class _DashedRowPainter extends CustomPainter {
  const _DashedRowPainter({required this.color, required this.scale});

  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.5, scale)
      ..isAntiAlias = false;
    final Rect bounds = (Offset.zero & size).deflate(paint.strokeWidth / 2);
    final double dash = math.max(2, 8 * scale);
    final double gap = math.max(1, 6 * scale);
    _drawDashedLine(canvas, bounds.topLeft, bounds.topRight, dash, gap, paint);
    _drawDashedLine(
      canvas,
      bounds.bottomLeft,
      bounds.bottomRight,
      dash,
      gap,
      paint,
    );
    _drawDashedLine(
      canvas,
      bounds.topLeft,
      bounds.bottomLeft,
      dash,
      gap,
      paint,
    );
    _drawDashedLine(
      canvas,
      bounds.topRight,
      bounds.bottomRight,
      dash,
      gap,
      paint,
    );
  }

  @override
  bool shouldRepaint(_DashedRowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.scale != scale;
}

final class _PlusPainter extends CustomPainter {
  const _PlusPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    final Offset center = size.center(Offset.zero);
    canvas.drawLine(
      Offset(center.dx - size.width * 0.16, center.dy),
      Offset(center.dx + size.width * 0.16, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - size.height * 0.16),
      Offset(center.dx, center.dy + size.height * 0.16),
      paint,
    );
  }

  @override
  bool shouldRepaint(_PlusPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

final class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.scale, required this.onPressed});

  final _LayersPanelScale scale;
  final VoidCallback onPressed;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

final class _CloseButtonState extends State<_CloseButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    final Color background = _pressed ? palette.ink : palette.paper;
    final Color foreground = _pressed ? palette.paper : palette.ink;
    return Semantics(
      button: true,
      label: 'Close layers panel',
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.scale.u(_headerDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                left: BorderSide(color: palette.ink, width: widget.scale.rule),
              ),
            ),
            child: CustomPaint(
              painter: _CloseGlyphPainter(
                color: foreground,
                strokeWidth: widget.scale.rule,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CloseGlyphPainter extends CustomPainter {
  const _CloseGlyphPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect glyph = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.3,
      height: size.height * 0.3,
    );
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    canvas.drawLine(glyph.topLeft, glyph.bottomRight, paint);
    canvas.drawLine(glyph.topRight, glyph.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_CloseGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

final class _LayersPanelScale {
  const _LayersPanelScale(this.value);

  factory _LayersPanelScale.of(BuildContext context) {
    return _LayersPanelScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}

int _nextOpacity(int opacityPercent, int delta) {
  final int current =
      (opacityPercent * (layersPanelOpacityNotchCount - 1) / 100).round();
  final int next = (current + delta).clamp(0, layersPanelOpacityNotchCount - 1);
  return (next * 100 / (layersPanelOpacityNotchCount - 1)).round();
}

void _drawDashedLine(
  Canvas canvas,
  Offset start,
  Offset end,
  double dash,
  double gap,
  Paint paint,
) {
  final Offset delta = end - start;
  final double length = delta.distance;
  if (length == 0) {
    return;
  }
  final Offset direction = delta / length;
  for (double cursor = 0; cursor < length; cursor += dash + gap) {
    canvas.drawLine(
      start + direction * cursor,
      start + direction * math.min(length, cursor + dash),
      paint,
    );
  }
}

void _validateLayers({
  required List<LayerPanelItem> layers,
  required List<LayerPanelItem> references,
  required String activeLayerId,
}) {
  if (layers.isEmpty) {
    throw ArgumentError.value(layers, 'layers', 'must not be empty');
  }
  if (layers.length > layersPanelContentCap) {
    throw ArgumentError.value(
      layers.length,
      'layers.length',
      'must not exceed $layersPanelContentCap',
    );
  }
  if (references.length > layersPanelReferenceCap) {
    throw ArgumentError.value(
      references.length,
      'referenceLayers.length',
      'must not exceed $layersPanelReferenceCap',
    );
  }
  final Set<String> ids = <String>{};
  for (final LayerPanelItem item in <LayerPanelItem>[
    ...references,
    ...layers,
  ]) {
    if (item.id.isEmpty || !ids.add(item.id)) {
      throw ArgumentError.value(
        item.id,
        'layer id',
        'must be non-empty and unique across both stacks',
      );
    }
    if (item.name.isEmpty) {
      throw ArgumentError.value(item.name, 'layer name', 'must not be empty');
    }
  }
  if (!layers.any((LayerPanelItem item) => item.id == activeLayerId)) {
    throw ArgumentError.value(
      activeLayerId,
      'activeLayerId',
      'must identify a content layer',
    );
  }
}
