import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../responsive_layout.dart';

/// Authored height of the bottom contextual dock in design pixels.
const double contextualDockDesignHeight = 96;

/// Minimum authored width of a contextual-dock action in design pixels.
const double contextualDockMinimumCellDesignWidth = 80;

/// Complete visual states supported by the contextual dock.
///
/// This enum deliberately does not depend on the editor's tool model. The
/// editor maps its active state to one of these values at the composition
/// boundary, while golden scenes can render the dock synchronously.
enum ContextualDockMode {
  /// Pixel, whole-stroke, and lasso eraser modes.
  erase,

  /// Selection mode, mask operations, and clipboard actions.
  selection,

  /// Floating-selection or whole-layer transform actions.
  transform,

  /// Flood-fill sampling, region, and pattern options.
  fill,

  /// Live shape selection and geometry modifiers.
  shape,

  /// Editable text-block actions.
  text,

  /// Active crop rectangle actions.
  crop,

  /// Persistent guide, grid, and symmetry controls.
  guides,
}

/// A stable action identifier emitted by [ContextualDock].
enum ContextualDockAction {
  /// Erase raster pixels through the clear-blend brush.
  eraserPixel('pixel'),

  /// Remove a contacted replayable stroke as a whole action.
  eraserStroke('stroke'),

  /// Clear pixels inside a closed freehand region.
  eraserLasso('lasso'),

  /// Use a rectangular selection gesture.
  selectRect('rect'),

  /// Use a freehand lasso selection gesture.
  selectLasso('lasso'),

  /// Use the contiguous-color wand.
  selectWand('wand'),

  /// Add the next region to the active mask.
  selectAdd('add'),

  /// Subtract the next region from the active mask.
  selectSubtract('subtract'),

  /// Cycle the wand tolerance through its supported values.
  selectionTolerance('tol 0–64'),

  /// Cycle the wand gap-closing radius through its supported values.
  selectionGapClose('gap 0–4'),

  /// Move the active selection or block.
  move('move'),

  /// Enter transform mode.
  transform('transform'),

  /// Duplicate selected pixels.
  duplicate('duplicate'),

  /// Flip the target horizontally.
  flipHorizontal('flip H'),

  /// Flip the target vertically.
  flipVertical('flip V'),

  /// Cut selected pixels to the session clipboard.
  cut('cut'),

  /// Copy selected pixels to the session clipboard.
  copy('copy'),

  /// Paste the session clipboard at the viewport center.
  paste('paste'),

  /// Clear selected pixels.
  clear('clear'),

  /// Fill the active selection.
  fill('fill'),

  /// Move selected pixels to a new layer.
  toNewLayer('new layer'),

  /// Preserve the current aspect ratio.
  aspect('aspect'),

  /// Rotate through a fifteen-degree detent.
  rotateDetent('rotate 15°'),

  /// Restore the target to its initial live state.
  reset('reset'),

  /// Commit the current operation.
  apply('apply'),

  /// Set the flood-fill color tolerance in the zero-to-sixty-four range.
  fillTolerance('tol 0–64'),

  /// Set bounded gap closing in the zero-to-four-pixel range.
  fillGapClose('gap 0–4'),

  /// Grow the filled region by up to four pixels.
  fillGrow('grow +0–4'),

  /// Contract the filled region by up to four pixels.
  fillContract('contract −0–4'),

  /// Sample the active content layer only.
  fillSampleActive('sample active'),

  /// Sample the visible composite while writing to the active layer.
  fillSampleComposite('sample all'),

  /// Fill with the current solid color.
  fillSolid('solid'),

  /// Fill with a hatch pattern.
  fillHatch('hatch'),

  /// Fill with a dot-screen pattern.
  fillDotScreen('dot screen'),

  /// Use the four-by-four Bayer dot-screen density.
  fillBayer4('bayer4'),

  /// Use the eight-by-eight Bayer dot-screen density.
  fillBayer8('bayer8'),

  /// Draw a line.
  shapeLine('line'),

  /// Draw an arrow.
  shapeArrow('arrow'),

  /// Draw a rectangle.
  shapeRect('rect'),

  /// Draw an ellipse.
  shapeEllipse('ellipse'),

  /// Draw an N-sided polygon.
  shapePolygon('polygon N'),

  /// Cycle the polygon side count through its supported values.
  polygonSides('sides 3–8'),

  /// Construct shape geometry from its center.
  fromCenter('from center'),

  /// Engage hold-to-perfect geometry.
  perfect('perfect'),

  /// Select Inter for the text block.
  textInter('Inter'),

  /// Select JetBrains Mono for the text block.
  textMono('Mono'),

  /// Change the text size.
  textSize('size'),

  /// Change the text weight.
  textWeight('weight'),

  /// Resize the editable text block.
  textResize('resize'),

  /// Commit the editable text block.
  done('Done'),

  /// Toggle the persistent straightedge.
  straightedge('straightedge'),

  /// Turn off the persistent straightedge without changing other guides.
  straightedgeOff('ruler off'),

  /// Use a dot grid.
  gridDots('grid dots'),

  /// Use a line grid.
  gridLines('grid lines'),

  /// Set grid spacing to eight design pixels.
  grid8('8'),

  /// Set grid spacing to sixteen design pixels.
  grid16('16'),

  /// Set grid spacing to thirty-two design pixels.
  grid32('32'),

  /// Set grid spacing to sixty-four design pixels.
  grid64('64'),

  /// Turn off the grid without changing the straightedge or symmetry.
  gridOff('grid off'),

  /// Mirror strokes about the vertical axis.
  symmetryVertical('vertical'),

  /// Mirror strokes about the horizontal axis.
  symmetryHorizontal('horizontal'),

  /// Mirror strokes about both axes.
  symmetryQuad('quad'),

  /// Turn off stroke symmetry without changing other guide families.
  symmetryOff('mirror off'),

  /// Cancel live state or clear the selection mask.
  dismiss('×');

  const ContextualDockAction(this.label);

  /// Short label painted in the action cell.
  final String label;

  /// Authored cell width, always at least the 80-dpx touch-target minimum.
  double get designWidth => designWidthForLabel(label);

  /// Authored cell width for a current-value [resolvedLabel].
  double designWidthForLabel(String resolvedLabel) {
    final double labelWidth = 48 + resolvedLabel.characters.length * 14;
    return math.max(contextualDockMinimumCellDesignWidth, labelWidth);
  }
}

/// Wand-tolerance values exposed by the selection dock.
const List<int> selectionToleranceDockValues = <int>[0, 8, 16, 32, 48, 64];

/// Wand gap-closing values exposed by the selection dock.
const List<int> selectionGapCloseDockValues = <int>[0, 1, 2, 4];

/// Polygon side counts exposed by the shape dock.
const List<int> polygonSidesDockValues = <int>[3, 4, 5, 6, 8];

/// Returns the next selection tolerance shown by the dock.
int nextSelectionTolerance(int current) {
  return _nextSupportedValue(current, selectionToleranceDockValues);
}

/// Returns the next selection gap-closing radius shown by the dock.
int nextSelectionGapClose(int current) {
  return _nextSupportedValue(current, selectionGapCloseDockValues);
}

/// Returns the next polygon side count shown by the dock.
int nextPolygonSides(int current) {
  return _nextSupportedValue(current, polygonSidesDockValues);
}

/// Builds the current-value labels used by the selection dock.
Map<ContextualDockAction, String> selectionDockValueLabels({
  required int tolerance,
  required int gapClose,
}) {
  RangeError.checkValueInInterval(tolerance, 0, 64, 'tolerance');
  RangeError.checkValueInInterval(gapClose, 0, 4, 'gapClose');
  return <ContextualDockAction, String>{
    ContextualDockAction.selectionTolerance: 'tol $tolerance',
    ContextualDockAction.selectionGapClose: 'gap $gapClose',
  };
}

/// Builds the current-value labels used by the fill dock.
Map<ContextualDockAction, String> fillDockValueLabels({
  required int tolerance,
  required int gapClose,
  required int grow,
}) {
  RangeError.checkValueInInterval(tolerance, 0, 64, 'tolerance');
  RangeError.checkValueInInterval(gapClose, 0, 4, 'gapClose');
  RangeError.checkValueInInterval(grow, -4, 4, 'grow');
  final int growMagnitude = math.max(grow, 0);
  final int contractMagnitude = math.max(-grow, 0);
  return <ContextualDockAction, String>{
    ContextualDockAction.fillTolerance: 'tol $tolerance',
    ContextualDockAction.fillGapClose: 'gap $gapClose',
    ContextualDockAction.fillGrow: 'grow +$growMagnitude',
    ContextualDockAction.fillContract: 'contract −$contractMagnitude',
  };
}

/// Builds the current polygon-side label used by the shape dock.
Map<ContextualDockAction, String> shapeDockValueLabels({
  required int polygonSides,
}) {
  RangeError.checkValueInInterval(polygonSides, 3, 32, 'polygonSides');
  return <ContextualDockAction, String>{
    ContextualDockAction.shapePolygon: 'polygon $polygonSides',
    ContextualDockAction.polygonSides: 'sides $polygonSides',
  };
}

int _nextSupportedValue(int current, List<int> supportedValues) {
  for (final int value in supportedValues) {
    if (value > current) {
      return value;
    }
  }
  return supportedValues.first;
}

const List<ContextualDockAction> _eraserActions = <ContextualDockAction>[
  ContextualDockAction.eraserPixel,
  ContextualDockAction.eraserStroke,
  ContextualDockAction.eraserLasso,
];

const List<ContextualDockAction> _selectionActions = <ContextualDockAction>[
  ContextualDockAction.selectRect,
  ContextualDockAction.selectLasso,
  ContextualDockAction.selectWand,
  ContextualDockAction.selectionTolerance,
  ContextualDockAction.selectionGapClose,
  ContextualDockAction.selectAdd,
  ContextualDockAction.selectSubtract,
  ContextualDockAction.move,
  ContextualDockAction.transform,
  ContextualDockAction.duplicate,
  ContextualDockAction.flipHorizontal,
  ContextualDockAction.flipVertical,
  ContextualDockAction.cut,
  ContextualDockAction.copy,
  ContextualDockAction.paste,
  ContextualDockAction.clear,
  ContextualDockAction.fill,
  ContextualDockAction.toNewLayer,
  ContextualDockAction.dismiss,
];

const List<ContextualDockAction> _transformActions = <ContextualDockAction>[
  ContextualDockAction.aspect,
  ContextualDockAction.rotateDetent,
  ContextualDockAction.flipHorizontal,
  ContextualDockAction.flipVertical,
  ContextualDockAction.reset,
  ContextualDockAction.apply,
  ContextualDockAction.dismiss,
];

const List<ContextualDockAction> _fillActions = <ContextualDockAction>[
  ContextualDockAction.fillTolerance,
  ContextualDockAction.fillGapClose,
  ContextualDockAction.fillGrow,
  ContextualDockAction.fillContract,
  ContextualDockAction.fillSampleActive,
  ContextualDockAction.fillSampleComposite,
  ContextualDockAction.fillSolid,
  ContextualDockAction.fillHatch,
  ContextualDockAction.fillDotScreen,
  ContextualDockAction.fillBayer4,
  ContextualDockAction.fillBayer8,
];

const List<ContextualDockAction> _shapeActions = <ContextualDockAction>[
  ContextualDockAction.shapeLine,
  ContextualDockAction.shapeArrow,
  ContextualDockAction.shapeRect,
  ContextualDockAction.shapeEllipse,
  ContextualDockAction.shapePolygon,
  ContextualDockAction.polygonSides,
  ContextualDockAction.fromCenter,
  ContextualDockAction.aspect,
  ContextualDockAction.perfect,
  ContextualDockAction.dismiss,
];

const List<ContextualDockAction> _textActions = <ContextualDockAction>[
  ContextualDockAction.textInter,
  ContextualDockAction.textMono,
  ContextualDockAction.textSize,
  ContextualDockAction.textWeight,
  ContextualDockAction.move,
  ContextualDockAction.textResize,
  ContextualDockAction.done,
  ContextualDockAction.dismiss,
];

const List<ContextualDockAction> _cropActions = <ContextualDockAction>[
  ContextualDockAction.aspect,
  ContextualDockAction.reset,
  ContextualDockAction.apply,
  ContextualDockAction.dismiss,
];

const List<ContextualDockAction> _guideActions = <ContextualDockAction>[
  ContextualDockAction.straightedge,
  ContextualDockAction.straightedgeOff,
  ContextualDockAction.gridDots,
  ContextualDockAction.gridLines,
  ContextualDockAction.grid8,
  ContextualDockAction.grid16,
  ContextualDockAction.grid32,
  ContextualDockAction.grid64,
  ContextualDockAction.gridOff,
  ContextualDockAction.symmetryVertical,
  ContextualDockAction.symmetryHorizontal,
  ContextualDockAction.symmetryQuad,
  ContextualDockAction.symmetryOff,
  ContextualDockAction.dismiss,
];

/// Returns the canonical, immutable action order for [mode].
List<ContextualDockAction> contextualDockActionsFor(ContextualDockMode mode) {
  return switch (mode) {
    ContextualDockMode.erase => _eraserActions,
    ContextualDockMode.selection => _selectionActions,
    ContextualDockMode.transform => _transformActions,
    ContextualDockMode.fill => _fillActions,
    ContextualDockMode.shape => _shapeActions,
    ContextualDockMode.text => _textActions,
    ContextualDockMode.crop => _cropActions,
    ContextualDockMode.guides => _guideActions,
  };
}

/// Bottom-edge, whole-state contextual action bar.
///
/// The bar is entirely synchronous: its paper plate and cells are painted
/// directly, and press feedback swaps colors immediately without timers or
/// animation. Long action sets remain reachable through a horizontal drag.
final class ContextualDock extends StatelessWidget {
  /// Creates a dock for one complete contextual state.
  const ContextualDock({
    required this.mode,
    required this.onAction,
    this.selectedActions = const <ContextualDockAction>{},
    this.disabledActions = const <ContextualDockAction>{},
    this.actionLabels = const <ContextualDockAction, String>{},
    super.key,
  });

  /// Complete action set to display.
  final ContextualDockMode mode;

  /// Receives a stable action identifier when a cell is tapped.
  final ValueChanged<ContextualDockAction> onAction;

  /// Toggle-like actions currently engaged.
  final Set<ContextualDockAction> selectedActions;

  /// Actions visible but currently unavailable, such as paste with no clip.
  final Set<ContextualDockAction> disabledActions;

  /// Current-value labels that replace an action's static fallback label.
  final Map<ContextualDockAction, String> actionLabels;

  @override
  Widget build(BuildContext context) {
    final _DockScale scale = _DockScale.of(context);
    final PaperPalette palette = PaperTheme.of(context).palette;
    final List<ContextualDockAction> actions = contextualDockActionsFor(mode);
    return SizedBox(
      height: scale.u(contextualDockDesignHeight),
      width: double.infinity,
      child: CustomPaint(
        painter: _DockChromePainter(
          paper: palette.paper,
          ink: palette.ink,
          ruleWidth: scale.rule,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _DockModeCell(mode: mode, scale: scale),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final ContextualDockAction action in actions)
                      _DockActionCell(
                        label: actionLabels[action] ?? action.label,
                        width: scale.u(
                          action.designWidthForLabel(
                            actionLabels[action] ?? action.label,
                          ),
                        ),
                        selected: selectedActions.contains(action),
                        enabled: !disabledActions.contains(action),
                        ruleWidth: scale.rule,
                        onPressed: () => onAction(action),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _DockModeCell extends StatelessWidget {
  const _DockModeCell({required this.mode, required this.scale});

  final ContextualDockMode mode;
  final _DockScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: scale.u(128),
      child: ColoredBox(
        color: theme.palette.ink,
        child: Center(
          child: Text(
            _modeLabel(mode),
            maxLines: 2,
            textAlign: TextAlign.center,
            style: theme.type.caption.copyWith(
              color: theme.palette.paper,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

String _modeLabel(ContextualDockMode mode) => switch (mode) {
  ContextualDockMode.erase => 'ERASER',
  ContextualDockMode.selection => 'SELECT\nMASK',
  ContextualDockMode.transform => 'TRANSFORM',
  ContextualDockMode.fill => 'FILL',
  ContextualDockMode.shape => 'SHAPE',
  ContextualDockMode.text => 'TEXT',
  ContextualDockMode.crop => 'CROP',
  ContextualDockMode.guides => 'GUIDES',
};

final class _DockActionCell extends StatefulWidget {
  const _DockActionCell({
    required this.label,
    required this.width,
    required this.selected,
    required this.enabled,
    required this.ruleWidth,
    required this.onPressed,
  });

  final String label;
  final double width;
  final bool selected;
  final bool enabled;
  final double ruleWidth;
  final VoidCallback onPressed;

  @override
  State<_DockActionCell> createState() => _DockActionCellState();
}

final class _DockActionCellState extends State<_DockActionCell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !widget.enabled) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool inverted = widget.selected != _pressed;
    final Color foreground = !widget.enabled
        ? theme.palette.gray66
        : inverted
        ? theme.palette.paper
        : theme.palette.ink;
    final Color background = inverted ? theme.palette.ink : theme.palette.paper;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTap: widget.enabled ? widget.onPressed : null,
        child: SizedBox(
          width: widget.width,
          child: CustomPaint(
            painter: _DockCellPainter(
              background: background,
              rule: theme.palette.ink,
              ruleWidth: widget.ruleWidth,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.type.caption.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DockChromePainter extends CustomPainter {
  const _DockChromePainter({
    required this.paper,
    required this.ink,
    required this.ruleWidth,
  });

  final Color paper;
  final Color ink;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // Fill only the dock's own rect — `canvas.drawColor` fills the entire
    // canvas (CustomPaint does not clip to `size`), which would white out every
    // sibling painted before this dock (status band, bench, canvas).
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = paper
        ..isAntiAlias = false,
    );
    final Paint rule = Paint()
      ..color = ink
      ..strokeWidth = ruleWidth
      ..isAntiAlias = false;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), rule);
  }

  @override
  bool shouldRepaint(_DockChromePainter oldDelegate) {
    return oldDelegate.paper != paper ||
        oldDelegate.ink != ink ||
        oldDelegate.ruleWidth != ruleWidth;
  }
}

final class _DockCellPainter extends CustomPainter {
  const _DockCellPainter({
    required this.background,
    required this.rule,
    required this.ruleWidth,
  });

  final Color background;
  final Color rule;
  final double ruleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // Bound the fill to this cell — `canvas.drawColor` fills the whole canvas.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = background
        ..isAntiAlias = false,
    );
    final Paint paint = Paint()
      ..color = rule
      ..strokeWidth = ruleWidth
      ..isAntiAlias = false;
    canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(_DockCellPainter oldDelegate) {
    return oldDelegate.background != background ||
        oldDelegate.rule != rule ||
        oldDelegate.ruleWidth != ruleWidth;
  }
}

final class _DockScale {
  const _DockScale(this.value);

  factory _DockScale.of(BuildContext context) {
    return _DockScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}
