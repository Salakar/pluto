import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../../engine/brush_presets.dart';
import '../glyphs.dart';
import '../panels/brush_panel.dart';
import '../responsive_layout.dart';

/// Width of a side-docked drafting bench in authored design pixels.
const double inkBenchSideDesignWidth = 160;

/// Height of the complete side-docked drafting bench.
const double inkBenchSideDesignHeight = 1056;

/// Height of the horizontal top-docked drafting bench.
const double inkBenchTopDesignHeight = 120;

/// Width of the folded grip tab.
const double inkBenchCollapsedDesignWidth = 80;

/// Height of the folded grip tab.
const double inkBenchCollapsedDesignHeight = 96;

/// Authored side-bench grip height.
const double inkBenchGripDesignHeight = 80;

/// Authored tool-cell width and height.
const double inkBenchToolCellDesignSize = 80;

/// Authored side-bench brush-chip height.
const double inkBenchBrushChipDesignHeight = 96;

/// Number of stable notches on both bench parameter rails.
const int inkBenchSliderNotchCount = 16;

const double _sideRailDesignHeight = 80;
const double _topGripDesignWidth = 80;
const double _topBrushDesignWidth = 160;
const double _topRailDesignWidth = 160;

/// Edges to which the drafting bench may attach.
enum InkBenchDock {
  /// Default thumb-reachable left edge.
  left,

  /// Mirrored right edge.
  right,

  /// Horizontal strip immediately below the status band.
  top,
}

/// Layout properties used by the editor's positioning layer.
extension InkBenchDockLayout on InkBenchDock {
  /// Whether cells reflow into the horizontal 120-dpx strip.
  bool get isTop => this == InkBenchDock.top;

  /// Alignment at the composition boundary.
  Alignment get alignment => switch (this) {
    InkBenchDock.left => Alignment.topLeft,
    InkBenchDock.right => Alignment.topRight,
    InkBenchDock.top => Alignment.topCenter,
  };
}

/// The ten tools that live in the bench's 2-by-5 / 10-by-1 grid.
///
/// Reference import intentionally lives in the menu and is not represented
/// here. Stable ids match `ToolState` and the interaction router.
enum InkBenchTool {
  /// Freehand drawing.
  draw('draw', 'draw', InkGlyph.markDraw),

  /// Pixel, stroke, or lasso erase.
  erase('erase', 'erase', InkGlyph.markErase),

  /// Selection-mask creation.
  select('select', 'select', InkGlyph.markSelect),

  /// Selection or whole-layer transform.
  transform('transform', 'transform', InkGlyph.markTransform),

  /// Contiguous raster fill.
  fill('fill', 'fill', InkGlyph.markFill),

  /// Brush-stamped primitives.
  shape('shape', 'shape', InkGlyph.markShape),

  /// Raster text blocks.
  text('text', 'text', InkGlyph.markText),

  /// Radius-averaged eyedropper.
  picker('picker', 'picker', InkGlyph.markPicker),

  /// Persistent guides and symmetry.
  guides('guides', 'guides', InkGlyph.markGuides),

  /// Preserving artwork crop.
  crop('crop', 'crop', InkGlyph.markCrop);

  const InkBenchTool(this.id, this.label, this.glyph);

  /// Stable persisted and routed tool id.
  final String id;

  /// Compact semantics and painted label.
  final String label;

  /// Drawn mark; no icon font is used.
  final InkGlyph glyph;
}

/// Returns the closest logarithmic size notch for a brush range.
int inkBenchSizeNotch({
  required double value,
  required double minimum,
  required double maximum,
}) {
  _validateSizeRange(minimum, maximum);
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, 'value', 'must be finite and positive');
  }
  if (minimum == maximum) {
    return 0;
  }
  final double clamped = value.clamp(minimum, maximum).toDouble();
  final double fraction =
      math.log(clamped / minimum) / math.log(maximum / minimum);
  return (fraction * (inkBenchSliderNotchCount - 1)).round();
}

/// Resolves one of the sixteen logarithmic size notches for a brush range.
double inkBenchSizeForNotch({
  required int notch,
  required double minimum,
  required double maximum,
}) {
  _validateSizeRange(minimum, maximum);
  if (notch < 0 || notch >= inkBenchSliderNotchCount) {
    throw RangeError.range(notch, 0, inkBenchSliderNotchCount - 1, 'notch');
  }
  if (minimum == maximum) {
    return minimum;
  }
  final double fraction = notch / (inkBenchSliderNotchCount - 1);
  return minimum * math.pow(maximum / minimum, fraction).toDouble();
}

/// Returns the nearest one of sixteen linear flow positions.
int inkBenchFlowNotch(double flow) {
  if (!flow.isFinite || flow < 0 || flow > 1) {
    throw RangeError.range(flow, 0, 1, 'flow');
  }
  return (flow * (inkBenchSliderNotchCount - 1)).round();
}

/// Resolves a normalized flow value from a stable notch.
double inkBenchFlowForNotch(int notch) {
  if (notch < 0 || notch >= inkBenchSliderNotchCount) {
    throw RangeError.range(notch, 0, inkBenchSliderNotchCount - 1, 'notch');
  }
  return notch / (inkBenchSliderNotchCount - 1);
}

/// Compact mono size readout used by the rail.
String inkBenchSizeLabel(double value) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, 'value', 'must be finite and positive');
  }
  final bool whole = (value - value.roundToDouble()).abs() < 0.05;
  return whole ? '${value.round()}' : value.toStringAsFixed(1);
}

/// Chooses a new edge from one completed grip drag.
///
/// The decision uses drag intent instead of nearest-edge distance so a grip at
/// the top-left corner does not accidentally jump from the left dock to top.
InkBenchDock inkBenchDockForDrag({
  required InkBenchDock current,
  required Offset start,
  required Offset end,
  required Size viewport,
}) {
  if (viewport.isEmpty) {
    return current;
  }
  final Offset delta = end - start;
  final double scale = inkViewportFitScale(viewport);
  if (delta.distance < 24 * scale) {
    return current;
  }
  if (current == InkBenchDock.top) {
    if (delta.dy <= 0 && delta.dy.abs() >= delta.dx.abs()) {
      return current;
    }
    return end.dx < viewport.width / 2 ? InkBenchDock.left : InkBenchDock.right;
  }
  if (delta.dy < 0 && delta.dy.abs() > delta.dx.abs() * 0.7) {
    return InkBenchDock.top;
  }
  if (delta.dx.abs() >= delta.dy.abs() * 0.7) {
    return end.dx < viewport.width / 2 ? InkBenchDock.left : InkBenchDock.right;
  }
  return current;
}

/// Ink's complete callback-driven drafting bench.
///
/// This widget owns only transient pointer-down inversion. Tool, brush, color,
/// layer, undo, panel, and dock state remain with the editor host. Every mark
/// and proof is painted synchronously; no image decoding, isolate work,
/// animation, or file access occurs here.
final class InkBench extends StatelessWidget {
  /// Creates a complete or folded bench.
  const InkBench({
    required this.dock,
    required this.collapsed,
    required this.activeToolId,
    required this.activeBrush,
    required this.brushSize,
    required this.brushFlow,
    required this.currentColor,
    required this.activeLayerOrdinal,
    required this.canUndo,
    required this.canRedo,
    required this.onToggleCollapsed,
    required this.onToolSelected,
    required this.onBrushPressed,
    required this.onSizeChanged,
    required this.onFlowChanged,
    required this.onColorPressed,
    required this.onUndo,
    required this.onRedo,
    required this.onLayersPressed,
    required this.onMenuPressed,
    this.onDockChanged,
    super.key,
  }) : assert(activeToolId != ''),
       assert(brushSize > 0),
       assert(brushFlow >= 0 && brushFlow <= 1),
       assert(activeLayerOrdinal > 0);

  /// Current edge preference.
  final InkBenchDock dock;

  /// Whether only the 80-by-96 grip and active-tool mini remain.
  final bool collapsed;

  /// Stable active tool id from `ToolState.activeToolId`.
  final String activeToolId;

  /// Current brush, used for its name, range, and real mini proof.
  final BrushSpec activeBrush;

  /// Current brush diameter.
  final double brushSize;

  /// Host-owned normalized flow multiplier.
  final double brushFlow;

  /// Current opaque drawing color.
  final Color currentColor;

  /// One-based active content-layer ordinal.
  final int activeLayerOrdinal;

  /// Whether undo may be invoked.
  final bool canUndo;

  /// Whether redo may be invoked.
  final bool canRedo;

  /// Folds or restores this bench.
  final VoidCallback onToggleCollapsed;

  /// Selects one of the ten stable tool ids.
  final ValueChanged<String> onToolSelected;

  /// Opens the brush panel.
  final VoidCallback onBrushPressed;

  /// Replaces brush size with one of sixteen logarithmic values.
  final ValueChanged<double> onSizeChanged;

  /// Replaces the host-owned flow multiplier with one of sixteen values.
  final ValueChanged<double> onFlowChanged;

  /// Opens the color panel.
  final VoidCallback onColorPressed;

  /// Requests one undo journal action.
  final VoidCallback onUndo;

  /// Requests one redo journal action.
  final VoidCallback onRedo;

  /// Opens the layers panel.
  final VoidCallback onLayersPressed;

  /// Opens the less-frequent action menu.
  final VoidCallback onMenuPressed;

  /// Receives a dock edge chosen by a completed grip drag.
  final ValueChanged<InkBenchDock>? onDockChanged;

  @override
  Widget build(BuildContext context) {
    final _BenchScale scale = _BenchScale.of(context);
    if (collapsed) {
      return _CollapsedBench(
        key: const ValueKey<String>('ink-bench-collapsed'),
        dock: dock,
        activeToolId: activeToolId,
        scale: scale,
        onToggleCollapsed: onToggleCollapsed,
        onDockChanged: onDockChanged,
      );
    }
    if (dock.isTop) {
      return _TopBench(bench: this, scale: scale);
    }
    return _SideBench(bench: this, scale: scale);
  }
}

final class _SideBench extends StatelessWidget {
  const _SideBench({required this.bench, required this.scale});

  final InkBench bench;
  final _BenchScale scale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey<String>('ink-bench-${bench.dock.name}'),
      width: scale.u(inkBenchSideDesignWidth),
      height: scale.u(inkBenchSideDesignHeight),
      child: _BenchFrame(
        dock: bench.dock,
        child: Column(
          children: <Widget>[
            _BenchGrip(
              dock: bench.dock,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.touchTarget(inkBenchGripDesignHeight),
              collapsed: false,
              onToggleCollapsed: bench.onToggleCollapsed,
              onDockChanged: bench.onDockChanged,
            ),
            SizedBox(
              height: scale.u(inkBenchToolCellDesignSize * 5),
              child: Column(
                children: <Widget>[
                  for (var row = 0; row < 5; row += 1)
                    Row(
                      children: <Widget>[
                        for (var column = 0; column < 2; column += 1)
                          _ToolCell(
                            tool: InkBenchTool.values[row * 2 + column],
                            activeToolId: bench.activeToolId,
                            size: scale.touchTarget(inkBenchToolCellDesignSize),
                            onSelected: bench.onToolSelected,
                          ),
                      ],
                    ),
                ],
              ),
            ),
            _BrushChip(
              brush: bench.activeBrush,
              selectedSize: bench.brushSize,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(inkBenchBrushChipDesignHeight),
              onPressed: bench.onBrushPressed,
            ),
            _SizeRail(
              brush: bench.activeBrush,
              value: bench.brushSize,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(_sideRailDesignHeight),
              onChanged: bench.onSizeChanged,
            ),
            _FlowRail(
              value: bench.brushFlow,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(_sideRailDesignHeight),
              onChanged: bench.onFlowChanged,
            ),
            _ColorChip(
              color: bench.currentColor,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(inkBenchToolCellDesignSize),
              onPressed: bench.onColorPressed,
            ),
            SizedBox(
              height: scale.u(inkBenchToolCellDesignSize),
              child: Row(
                children: <Widget>[
                  _ActionCell(
                    actionKey: 'undo',
                    label: 'undo',
                    glyph: InkGlyph.markUndo,
                    width: scale.u(inkBenchToolCellDesignSize),
                    height: scale.u(inkBenchToolCellDesignSize),
                    enabled: bench.canUndo,
                    onPressed: bench.onUndo,
                  ),
                  _ActionCell(
                    actionKey: 'redo',
                    label: 'redo',
                    glyph: InkGlyph.markRedo,
                    width: scale.u(inkBenchToolCellDesignSize),
                    height: scale.u(inkBenchToolCellDesignSize),
                    enabled: bench.canRedo,
                    onPressed: bench.onRedo,
                  ),
                ],
              ),
            ),
            _LayerChip(
              ordinal: bench.activeLayerOrdinal,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(inkBenchToolCellDesignSize),
              onPressed: bench.onLayersPressed,
            ),
            _ActionCell(
              actionKey: 'menu',
              label: 'menu',
              glyph: InkGlyph.markMenu,
              width: scale.u(inkBenchSideDesignWidth),
              height: scale.u(inkBenchToolCellDesignSize),
              onPressed: bench.onMenuPressed,
            ),
          ],
        ),
      ),
    );
  }
}

final class _TopBench extends StatelessWidget {
  const _TopBench({required this.bench, required this.scale});

  final InkBench bench;
  final _BenchScale scale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('ink-bench-top'),
      width: double.infinity,
      height: scale.u(inkBenchTopDesignHeight),
      child: _BenchFrame(
        dock: InkBenchDock.top,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _BenchGrip(
                dock: bench.dock,
                width: scale.touchTarget(_topGripDesignWidth),
                height: scale.u(inkBenchTopDesignHeight),
                collapsed: false,
                onToggleCollapsed: bench.onToggleCollapsed,
                onDockChanged: bench.onDockChanged,
              ),
              for (final InkBenchTool tool in InkBenchTool.values)
                _ToolCell(
                  tool: tool,
                  activeToolId: bench.activeToolId,
                  size: scale.touchTarget(inkBenchToolCellDesignSize),
                  height: scale.u(inkBenchTopDesignHeight),
                  onSelected: bench.onToolSelected,
                ),
              _BrushChip(
                brush: bench.activeBrush,
                selectedSize: bench.brushSize,
                width: scale.u(_topBrushDesignWidth),
                height: scale.u(inkBenchTopDesignHeight),
                onPressed: bench.onBrushPressed,
              ),
              _SizeRail(
                brush: bench.activeBrush,
                value: bench.brushSize,
                width: scale.u(_topRailDesignWidth),
                height: scale.u(inkBenchTopDesignHeight),
                onChanged: bench.onSizeChanged,
              ),
              _FlowRail(
                value: bench.brushFlow,
                width: scale.u(_topRailDesignWidth),
                height: scale.u(inkBenchTopDesignHeight),
                onChanged: bench.onFlowChanged,
              ),
              _ColorChip(
                color: bench.currentColor,
                width: scale.u(inkBenchToolCellDesignSize),
                height: scale.u(inkBenchTopDesignHeight),
                onPressed: bench.onColorPressed,
                compact: true,
              ),
              _ActionCell(
                actionKey: 'undo',
                label: 'undo',
                glyph: InkGlyph.markUndo,
                width: scale.u(inkBenchToolCellDesignSize),
                height: scale.u(inkBenchTopDesignHeight),
                enabled: bench.canUndo,
                onPressed: bench.onUndo,
              ),
              _ActionCell(
                actionKey: 'redo',
                label: 'redo',
                glyph: InkGlyph.markRedo,
                width: scale.u(inkBenchToolCellDesignSize),
                height: scale.u(inkBenchTopDesignHeight),
                enabled: bench.canRedo,
                onPressed: bench.onRedo,
              ),
              _LayerChip(
                ordinal: bench.activeLayerOrdinal,
                width: scale.u(inkBenchToolCellDesignSize),
                height: scale.u(inkBenchTopDesignHeight),
                onPressed: bench.onLayersPressed,
                compact: true,
              ),
              _ActionCell(
                actionKey: 'menu',
                label: 'menu',
                glyph: InkGlyph.markMenu,
                width: scale.u(inkBenchToolCellDesignSize),
                height: scale.u(inkBenchTopDesignHeight),
                onPressed: bench.onMenuPressed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _CollapsedBench extends StatelessWidget {
  const _CollapsedBench({
    required this.dock,
    required this.activeToolId,
    required this.scale,
    required this.onToggleCollapsed,
    required this.onDockChanged,
    super.key,
  });

  final InkBenchDock dock;
  final String activeToolId;
  final _BenchScale scale;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<InkBenchDock>? onDockChanged;

  @override
  Widget build(BuildContext context) {
    final InkBenchTool active = InkBenchTool.values.firstWhere(
      (InkBenchTool tool) => tool.id == activeToolId,
      orElse: () => InkBenchTool.draw,
    );
    return SizedBox(
      width: scale.u(inkBenchCollapsedDesignWidth),
      height: scale.u(inkBenchCollapsedDesignHeight),
      child: _BenchFrame(
        dock: dock,
        child: _BenchGrip(
          dock: dock,
          width: scale.u(inkBenchCollapsedDesignWidth),
          height: scale.u(inkBenchCollapsedDesignHeight),
          collapsed: true,
          activeToolGlyph: active.glyph,
          activeToolLabel: active.label,
          onToggleCollapsed: onToggleCollapsed,
          onDockChanged: onDockChanged,
        ),
      ),
    );
  }
}

final class _BenchFrame extends StatelessWidget {
  const _BenchFrame({required this.dock, required this.child});

  final InkBenchDock dock;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    final _BenchScale scale = _BenchScale.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border(
          left: dock == InkBenchDock.right
              ? BorderSide(color: palette.ink, width: scale.rule)
              : BorderSide.none,
          right: dock == InkBenchDock.left
              ? BorderSide(color: palette.ink, width: scale.rule)
              : BorderSide.none,
          bottom: dock == InkBenchDock.top
              ? BorderSide(color: palette.ink, width: scale.rule)
              : BorderSide.none,
        ),
      ),
      child: child,
    );
  }
}

final class _BenchGrip extends StatefulWidget {
  const _BenchGrip({
    required this.dock,
    required this.width,
    required this.height,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onDockChanged,
    this.activeToolGlyph,
    this.activeToolLabel,
  });

  final InkBenchDock dock;
  final double width;
  final double height;
  final bool collapsed;
  final InkGlyph? activeToolGlyph;
  final String? activeToolLabel;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<InkBenchDock>? onDockChanged;

  @override
  State<_BenchGrip> createState() => _BenchGripState();
}

final class _BenchGripState extends State<_BenchGrip> {
  Offset? _dragStart;
  Offset? _dragEnd;

  void _finishDrag() {
    final Offset? start = _dragStart;
    final Offset? end = _dragEnd;
    _dragStart = null;
    _dragEnd = null;
    if (start == null || end == null || widget.onDockChanged == null) {
      return;
    }
    final InkBenchDock next = inkBenchDockForDrag(
      current: widget.dock,
      start: start,
      end: end,
      viewport: MediaQuery.sizeOf(context),
    );
    if (next != widget.dock) {
      widget.onDockChanged!(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final String semanticsLabel = widget.collapsed
        ? 'Restore bench, active tool ${widget.activeToolLabel}'
        : 'Bench grip, collapse bench';
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: semanticsLabel,
      onTap: widget.onToggleCollapsed,
      child: GestureDetector(
        key: const ValueKey<String>('bench-grip'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggleCollapsed,
        onPanStart: widget.onDockChanged == null
            ? null
            : (DragStartDetails details) {
                _dragStart = details.globalPosition;
                _dragEnd = details.globalPosition;
              },
        onPanUpdate: widget.onDockChanged == null
            ? null
            : (DragUpdateDetails details) {
                _dragEnd = details.globalPosition;
              },
        onPanEnd: widget.onDockChanged == null ? null : (_) => _finishDrag(),
        onPanCancel: widget.onDockChanged == null ? null : _finishDrag,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.palette.paper,
              border: Border(
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: _BenchScale.of(context).rule,
                ),
              ),
            ),
            child: widget.collapsed
                ? Column(
                    children: <Widget>[
                      Expanded(
                        child: CustomPaint(
                          painter: InkGlyphPainter(
                            glyph: InkGlyph.benchGrip,
                            color: theme.palette.ink,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: CustomPaint(
                          painter: InkGlyphPainter(
                            glyph: widget.activeToolGlyph!,
                            color: theme.palette.ink,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: <Widget>[
                      Expanded(
                        child: CustomPaint(
                          painter: InkGlyphPainter(
                            glyph: InkGlyph.benchGrip,
                            color: theme.palette.ink,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: CustomPaint(
                          painter: InkGlyphPainter(
                            glyph: InkGlyph.collapseChevrons,
                            color: theme.palette.ink,
                          ),
                          child: const SizedBox.expand(),
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

final class _ToolCell extends StatelessWidget {
  const _ToolCell({
    required this.tool,
    required this.activeToolId,
    required this.size,
    required this.onSelected,
    this.height,
  });

  final InkBenchTool tool;
  final String activeToolId;
  final double size;
  final double? height;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return _BenchPressCell(
      key: ValueKey<String>('bench-tool-${tool.id}'),
      semanticsLabel: '${tool.label} tool',
      width: size,
      height: height ?? size,
      selected: activeToolId == tool.id,
      onPressed: () => onSelected(tool.id),
      builder: (BuildContext context, Color foreground) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: math.min(size * 0.54, 44),
            height: math.min(size * 0.54, 44),
            child: CustomPaint(
              painter: InkGlyphPainter(glyph: tool.glyph, color: foreground),
            ),
          ),
          Text(
            tool.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: PaperTheme.of(context).type.caption.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

final class _BrushChip extends StatelessWidget {
  const _BrushChip({
    required this.brush,
    required this.selectedSize,
    required this.width,
    required this.height,
    required this.onPressed,
  });

  final BrushSpec brush;
  final double selectedSize;
  final double width;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _BenchPressCell(
      key: const ValueKey<String>('bench-brush'),
      semanticsLabel: 'Brush ${brush.name}',
      width: width,
      height: height,
      onPressed: onPressed,
      builder: (BuildContext context, Color foreground) {
        final TextStyle label = PaperTheme.of(
          context,
        ).type.caption.copyWith(color: foreground, fontWeight: FontWeight.w600);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                brush.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label,
              ),
              Expanded(
                child: CustomPaint(
                  painter: BrushMiniProofPainter(
                    plan: buildBrushMiniProofPlan(brush, size: selectedSize),
                    color: foreground,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _SizeRail extends StatelessWidget {
  const _SizeRail({
    required this.brush,
    required this.value,
    required this.width,
    required this.height,
    required this.onChanged,
  });

  final BrushSpec brush;
  final double value;
  final double width;
  final double height;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final int notch = inkBenchSizeNotch(
      value: value,
      minimum: brush.sizeMin,
      maximum: brush.sizeMax,
    );
    return _BenchSlider(
      key: const ValueKey<String>('bench-size'),
      label: 'size',
      valueLabel: inkBenchSizeLabel(value),
      semanticsLabel: 'Brush size ${inkBenchSizeLabel(value)}',
      notchIndex: notch,
      width: width,
      height: height,
      onNotchChanged: (int next) => onChanged(
        inkBenchSizeForNotch(
          notch: next,
          minimum: brush.sizeMin,
          maximum: brush.sizeMax,
        ),
      ),
    );
  }
}

final class _FlowRail extends StatelessWidget {
  const _FlowRail({
    required this.value,
    required this.width,
    required this.height,
    required this.onChanged,
  });

  final double value;
  final double width;
  final double height;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return _BenchSlider(
      key: const ValueKey<String>('bench-flow'),
      label: 'flow',
      valueLabel: '${(value * 100).round()}%',
      semanticsLabel: 'Brush flow ${(value * 100).round()} percent',
      notchIndex: inkBenchFlowNotch(value),
      width: width,
      height: height,
      onNotchChanged: (int notch) => onChanged(inkBenchFlowForNotch(notch)),
    );
  }
}

final class _BenchSlider extends StatefulWidget {
  const _BenchSlider({
    required this.label,
    required this.valueLabel,
    required this.semanticsLabel,
    required this.notchIndex,
    required this.width,
    required this.height,
    required this.onNotchChanged,
    super.key,
  });

  final String label;
  final String valueLabel;
  final String semanticsLabel;
  final int notchIndex;
  final double width;
  final double height;
  final ValueChanged<int> onNotchChanged;

  @override
  State<_BenchSlider> createState() => _BenchSliderState();
}

final class _BenchSliderState extends State<_BenchSlider> {
  bool _dragging = false;

  void _select(double x) {
    final double fraction = (x / widget.width).clamp(0, 1);
    final int notch = (fraction * (inkBenchSliderNotchCount - 1)).round();
    if (notch != widget.notchIndex) {
      widget.onNotchChanged(notch);
    }
  }

  void _setDragging(bool value) {
    if (_dragging == value) {
      return;
    }
    setState(() => _dragging = value);
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      container: true,
      slider: true,
      excludeSemantics: true,
      label: widget.semanticsLabel,
      value: widget.valueLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (TapDownDetails details) {
          _setDragging(true);
          _select(details.localPosition.dx);
        },
        onTapUp: (_) => _setDragging(false),
        onTapCancel: () => _setDragging(false),
        onHorizontalDragStart: (DragStartDetails details) {
          _setDragging(true);
          _select(details.localPosition.dx);
        },
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          _select(details.localPosition.dx);
        },
        onHorizontalDragEnd: (_) => _setDragging(false),
        onHorizontalDragCancel: () => _setDragging(false),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.palette.paper,
              border: Border(
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: _BenchScale.of(context).rule,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(widget.label, style: theme.type.caption),
                      ),
                      Text(
                        widget.valueLabel,
                        key: _dragging
                            ? const ValueKey<String>('bench-slider-drag-value')
                            : null,
                        style: theme.type.mono,
                      ),
                    ],
                  ),
                  Expanded(
                    child: CustomPaint(
                      painter: _BenchNotchPainter(
                        notchIndex: widget.notchIndex,
                        ink: theme.palette.ink,
                        ruleWidth: _BenchScale.of(context).rule,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.color,
    required this.width,
    required this.height,
    required this.onPressed,
    this.compact = false,
  });

  final Color color;
  final double width;
  final double height;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _BenchPressCell(
      key: const ValueKey<String>('bench-color'),
      semanticsLabel: 'Current color',
      width: width,
      height: height,
      onPressed: onPressed,
      builder: (BuildContext context, Color foreground) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: math.min(width * 0.5, 52),
            height: math.min(height * 0.5, 52),
            child: CustomPaint(
              painter: _ColorChipPainter(
                color: color,
                ink: foreground,
                latticeGray: _todayGray(color),
                ruleWidth: _BenchScale.of(context).rule,
              ),
            ),
          ),
          if (!compact) ...<Widget>[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'color',
                overflow: TextOverflow.ellipsis,
                style: PaperTheme.of(
                  context,
                ).type.caption.copyWith(color: foreground),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _LayerChip extends StatelessWidget {
  const _LayerChip({
    required this.ordinal,
    required this.width,
    required this.height,
    required this.onPressed,
    this.compact = false,
  });

  final int ordinal;
  final double width;
  final double height;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _BenchPressCell(
      key: const ValueKey<String>('bench-layers'),
      semanticsLabel: 'Layers, active layer $ordinal',
      width: width,
      height: height,
      onPressed: onPressed,
      builder: (BuildContext context, Color foreground) => Stack(
        children: <Widget>[
          Center(
            child: SizedBox(
              width: math.min(width * 0.4, 44),
              height: math.min(height * 0.4, 44),
              child: CustomPaint(
                painter: InkGlyphPainter(
                  glyph: InkGlyph.markLayers,
                  color: foreground,
                ),
              ),
            ),
          ),
          if (!compact)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '$ordinal',
                  style: PaperTheme.of(
                    context,
                  ).type.mono.copyWith(color: foreground),
                ),
              ),
            )
          else
            Positioned(
              right: 4,
              top: 4,
              child: Text(
                '$ordinal',
                style: PaperTheme.of(
                  context,
                ).type.caption.copyWith(color: foreground),
              ),
            ),
        ],
      ),
    );
  }
}

final class _ActionCell extends StatelessWidget {
  const _ActionCell({
    required this.actionKey,
    required this.label,
    required this.glyph,
    required this.width,
    required this.height,
    required this.onPressed,
    this.enabled = true,
  });

  final String actionKey;
  final String label;
  final InkGlyph glyph;
  final double width;
  final double height;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _BenchPressCell(
      key: ValueKey<String>('bench-$actionKey'),
      semanticsLabel: label,
      width: width,
      height: height,
      enabled: enabled,
      onPressed: onPressed,
      builder: (BuildContext context, Color foreground) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: math.min(width * 0.42, 40),
            height: math.min(height * 0.42, 40),
            child: CustomPaint(
              painter: InkGlyphPainter(glyph: glyph, color: foreground),
            ),
          ),
          if (width > 80)
            Text(
              label,
              style: PaperTheme.of(
                context,
              ).type.caption.copyWith(color: foreground),
            ),
        ],
      ),
    );
  }
}

typedef _BenchCellBuilder =
    Widget Function(BuildContext context, Color foreground);

final class _BenchPressCell extends StatefulWidget {
  const _BenchPressCell({
    required this.semanticsLabel,
    required this.width,
    required this.height,
    required this.onPressed,
    required this.builder,
    this.selected = false,
    this.enabled = true,
    super.key,
  });

  final String semanticsLabel;
  final double width;
  final double height;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;
  final _BenchCellBuilder builder;

  @override
  State<_BenchPressCell> createState() => _BenchPressCellState();
}

final class _BenchPressCellState extends State<_BenchPressCell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !widget.enabled) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(_BenchPressCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _pressed) {
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool inverted = widget.selected != _pressed;
    final Color background = inverted ? theme.palette.ink : theme.palette.paper;
    final Color foreground = !widget.enabled
        ? theme.palette.gray66
        : inverted
        ? theme.palette.paper
        : theme.palette.ink;
    return Semantics(
      container: true,
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      excludeSemantics: true,
      label: widget.semanticsLabel,
      onTap: widget.enabled ? widget.onPressed : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTap: widget.enabled ? widget.onPressed : null,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                right: BorderSide(
                  color: theme.palette.ink,
                  width: _BenchScale.of(context).rule,
                ),
                bottom: BorderSide(
                  color: theme.palette.ink,
                  width: _BenchScale.of(context).rule,
                ),
              ),
            ),
            child: widget.builder(context, foreground),
          ),
        ),
      ),
    );
  }
}

final class _BenchNotchPainter extends CustomPainter {
  const _BenchNotchPainter({
    required this.notchIndex,
    required this.ink,
    required this.ruleWidth,
  });

  final int notchIndex;
  final Color ink;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final Paint fill = Paint()
      ..color = ink
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    final Paint stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = ruleWidth
      ..isAntiAlias = false;
    final double start = 3;
    final double end = math.max(start, size.width - 3);
    final double centerY = size.height / 2;
    canvas.drawLine(Offset(start, centerY), Offset(end, centerY), stroke);
    for (var index = 0; index < inkBenchSliderNotchCount; index += 1) {
      final double x =
          start + (end - start) * index / (inkBenchSliderNotchCount - 1);
      final double height = index <= notchIndex
          ? math.min(22, size.height * 0.8)
          : math.min(12, size.height * 0.5);
      final Rect notch = Rect.fromCenter(
        center: Offset(x, centerY),
        width: math.max(2, ruleWidth),
        height: height,
      );
      canvas.drawRect(notch, index <= notchIndex ? fill : stroke);
    }
  }

  @override
  bool shouldRepaint(_BenchNotchPainter oldDelegate) =>
      oldDelegate.notchIndex != notchIndex ||
      oldDelegate.ink != ink ||
      oldDelegate.ruleWidth != ruleWidth;
}

final class _ColorChipPainter extends CustomPainter {
  const _ColorChipPainter({
    required this.color,
    required this.ink,
    required this.latticeGray,
    required this.ruleWidth,
  });

  final Color color;
  final Color ink;
  final Color latticeGray;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect frame = (Offset.zero & size).deflate(ruleWidth / 2);
    canvas.drawRect(frame, Paint()..color = color);
    canvas.drawRect(
      frame,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = ruleWidth
        ..isAntiAlias = false,
    );
    final double wedge = size.shortestSide * 0.32;
    final Path path = Path()
      ..moveTo(size.width - wedge, size.height)
      ..lineTo(size.width, size.height - wedge)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = latticeGray);
    canvas.drawLine(
      Offset(size.width - wedge, size.height),
      Offset(size.width, size.height - wedge),
      Paint()
        ..color = ink
        ..strokeWidth = ruleWidth
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_ColorChipPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.ink != ink ||
      oldDelegate.latticeGray != latticeGray ||
      oldDelegate.ruleWidth != ruleWidth;
}

Color _todayGray(Color color) {
  final double luma = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
  final int level = (luma * 15).round().clamp(0, 15);
  final int channel = (255 * level / 15).round();
  return Color.fromARGB(255, channel, channel, channel);
}

void _validateSizeRange(double minimum, double maximum) {
  if (!minimum.isFinite || minimum <= 0) {
    throw ArgumentError.value(
      minimum,
      'minimum',
      'must be finite and positive',
    );
  }
  if (!maximum.isFinite || maximum < minimum) {
    throw ArgumentError.value(
      maximum,
      'maximum',
      'must be finite and at least minimum',
    );
  }
}

final class _BenchScale {
  const _BenchScale(this.value);

  factory _BenchScale.of(BuildContext context) {
    return _BenchScale(
      math.max(
        PaperTheme.touchTargetMin / inkBenchToolCellDesignSize,
        inkViewportFitScaleOf(context),
      ),
    );
  }

  final double value;

  double u(double designPx) => designPx * value;

  /// Scales an authored hit target without dropping below the 48-lp law.
  double touchTarget(double designPx) =>
      math.max(PaperTheme.touchTargetMin, u(designPx));

  double get rule => math.max(1, u(2));
}
