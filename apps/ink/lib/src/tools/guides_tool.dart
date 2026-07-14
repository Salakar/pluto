import 'dart:ui';

import '../engine/symmetry.dart';
import 'tool.dart';

/// Binding snap distance for the straightedge in viewport logical pixels.
const double straightedgeSnapDistanceLp = 24;

/// Non-exporting square-grid presentation.
enum GridOverlayStyle {
  /// Grid is disabled.
  off,

  /// Intersections are rendered as dots.
  dots,

  /// Full horizontal and vertical rules are rendered.
  lines,
}

/// Immutable placeable straightedge segment.
final class StraightedgeGuide {
  /// Creates a non-degenerate document-space straightedge.
  StraightedgeGuide({required this.start, required this.end}) {
    _requireFiniteOffset(start, 'start');
    _requireFiniteOffset(end, 'end');
    if (start == end) {
      throw ArgumentError.value(end, 'end', 'must differ from start');
    }
  }

  /// First endpoint in document space.
  final Offset start;

  /// Second endpoint in document space.
  final Offset end;

  /// Projects [point] onto the infinite ruler line when within the snap band.
  Offset snap(Offset point, {required double documentToViewportScale}) {
    _requireFiniteOffset(point, 'point');
    if (!documentToViewportScale.isFinite || documentToViewportScale <= 0) {
      throw ArgumentError.value(
        documentToViewportScale,
        'documentToViewportScale',
        'must be finite and positive',
      );
    }
    final Offset direction = end - start;
    final double lengthSquared = direction.distanceSquared;
    final double projection =
        ((point.dx - start.dx) * direction.dx +
            (point.dy - start.dy) * direction.dy) /
        lengthSquared;
    final Offset onLine = start + direction * projection;
    final double viewportDistance =
        (point - onLine).distance * documentToViewportScale;
    return viewportDistance <= straightedgeSnapDistanceLp ? onLine : point;
  }
}

/// Immutable square-grid overlay settings.
final class GridOverlay {
  /// Creates a validated grid overlay.
  GridOverlay({this.style = GridOverlayStyle.off, this.spacingDpx = 16}) {
    if (spacingDpx != 8 &&
        spacingDpx != 16 &&
        spacingDpx != 32 &&
        spacingDpx != 64) {
      throw ArgumentError.value(
        spacingDpx,
        'spacingDpx',
        'must be 8, 16, 32, or 64',
      );
    }
  }

  /// Off, dot, or line presentation.
  final GridOverlayStyle style;

  /// Square-cell spacing in design/document pixels.
  final int spacingDpx;

  /// Whether the grid should be painted.
  bool get isEnabled => style != GridOverlayStyle.off;
}

/// Persistent non-exporting guide state shared across every active tool.
final class GuidesOverlayState {
  /// Creates guide state.
  const GuidesOverlayState({
    required this.straightedge,
    required this.grid,
    required this.symmetry,
  });

  /// Optional ruler; `null` is its explicit off state.
  final StraightedgeGuide? straightedge;

  /// Persistent square grid.
  final GridOverlay grid;

  /// Brush-engine-ready stroke mirror configuration.
  final SymmetryConfiguration symmetry;

  /// Guides never become artwork/export pixels.
  bool get excludedFromExport => true;

  /// V1 symmetry expands brush strokes only, never fills or shapes.
  bool get symmetryStrokesOnly => true;

  /// Whether any persistent overlay is visible.
  bool get hasVisibleOverlay =>
      straightedge != null ||
      grid.isEnabled ||
      symmetry.mode != SymmetryMode.off;
}

/// Configures persistent guides and exposes brush-engine symmetry directly.
final class GuidesToolController extends ToolController<GuidesToolKind> {
  /// Creates guide state with symmetry axes at the artwork center.
  GuidesToolController({required Size documentSize})
    : _state = GuidesOverlayState(
        straightedge: null,
        grid: GridOverlay(),
        symmetry: SymmetryConfiguration(
          mode: SymmetryMode.off,
          axisX: _requireSize(documentSize).width / 2,
          axisY: documentSize.height / 2,
        ),
      ),
      super(const GuidesToolKind());

  GuidesOverlayState _state;

  /// Persistent overlay state retained across [deactivate].
  GuidesOverlayState get state => _state;

  @override
  bool get hasLiveState => _state.hasVisibleOverlay;

  /// Enables or replaces the placeable straightedge.
  void setStraightedge(Offset start, Offset end) {
    _state = GuidesOverlayState(
      straightedge: StraightedgeGuide(start: start, end: end),
      grid: _state.grid,
      symmetry: _state.symmetry,
    );
  }

  /// Explicitly disables the straightedge.
  void disableStraightedge() {
    _state = GuidesOverlayState(
      straightedge: null,
      grid: _state.grid,
      symmetry: _state.symmetry,
    );
  }

  /// Configures or disables the square grid.
  void setGrid(GridOverlayStyle style, {required int spacingDpx}) {
    _state = GuidesOverlayState(
      straightedge: _state.straightedge,
      grid: GridOverlay(style: style, spacingDpx: spacingDpx),
      symmetry: _state.symmetry,
    );
  }

  /// Configures the stroke-only mirror mode while retaining its axes.
  void setSymmetryMode(SymmetryMode mode) {
    final SymmetryConfiguration current = _state.symmetry;
    _state = GuidesOverlayState(
      straightedge: _state.straightedge,
      grid: _state.grid,
      symmetry: SymmetryConfiguration(
        mode: mode,
        axisX: current.axisX,
        axisY: current.axisY,
      ),
    );
  }

  /// Places the vertical and horizontal symmetry axes in document space.
  void placeSymmetryAxes({required double axisX, required double axisY}) {
    final SymmetryConfiguration current = _state.symmetry;
    _state = GuidesOverlayState(
      straightedge: _state.straightedge,
      grid: _state.grid,
      symmetry: SymmetryConfiguration(
        mode: current.mode,
        axisX: axisX,
        axisY: axisY,
      ),
    );
  }

  /// Snaps through the active straightedge without changing guide state.
  Offset snapPoint(Offset point, {required double documentToViewportScale}) =>
      _state.straightedge?.snap(
        point,
        documentToViewportScale: documentToViewportScale,
      ) ??
      point;

  /// Escape only closes guide editing; persistent overlays require off toggles.
  @override
  void cancel() {}
}

Size _requireSize(Size value) {
  if (!value.width.isFinite ||
      !value.height.isFinite ||
      value.width <= 0 ||
      value.height <= 0) {
    throw ArgumentError.value(
      value,
      'documentSize',
      'must be finite and positive',
    );
  }
  return value;
}

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}
