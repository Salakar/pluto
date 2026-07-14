import 'dart:math' as math;
import 'dart:ui';

import 'tool.dart';

/// Eight pen-adjustable crop handles.
enum CropHandle {
  /// Upper-left corner.
  topLeft,

  /// Upper edge midpoint.
  topCenter,

  /// Upper-right corner.
  topRight,

  /// Left edge midpoint.
  middleLeft,

  /// Right edge midpoint.
  middleRight,

  /// Lower-left corner.
  bottomLeft,

  /// Lower edge midpoint.
  bottomCenter,

  /// Lower-right corner.
  bottomRight,
}

/// Immutable crop overlay state.
final class CropDraft {
  /// Creates a crop draft inside [artworkBounds].
  CropDraft({required this.artworkBounds, required this.cropRect}) {
    _requireUsableRect(artworkBounds, 'artworkBounds');
    _requireFiniteRect(cropRect, 'cropRect');
    if (!_containsRect(artworkBounds, cropRect)) {
      throw ArgumentError.value(
        cropRect,
        'cropRect',
        'must stay inside artworkBounds',
      );
    }
  }

  /// Current artwork bounds before commit.
  final Rect artworkBounds;

  /// Proposed crop rectangle; it may be empty during initial pointer-down.
  final Rect cropRect;
}

/// Journaled artwork-bounds change that preserves pixels outside the crop.
final class CropCommand implements JournaledToolCommand {
  /// Creates a validated canvas-resize crop command.
  CropCommand({required this.previousBounds, required this.newBounds}) {
    _requireUsableRect(previousBounds, 'previousBounds');
    _requireUsableRect(newBounds, 'newBounds');
    if (!_hasIntegerEdges(previousBounds) || !_hasIntegerEdges(newBounds)) {
      throw ArgumentError.value(
        (previousBounds, newBounds),
        'bounds',
        'canvasResize bounds must use integer pixel edges',
      );
    }
    if (!_containsRect(previousBounds, newBounds)) {
      throw ArgumentError.value(
        newBounds,
        'newBounds',
        'must stay inside previousBounds',
      );
    }
  }

  /// Bounds before the crop.
  final Rect previousBounds;

  /// New artwork/export bounds.
  final Rect newBounds;

  /// Crop changes the export clip, not backing tile ownership.
  bool get preservesOutsideContent => true;

  /// Export must clip to the committed bounds.
  Rect get exportClip => newBounds;

  @override
  JournalKind get journalKind => JournalKind.canvasResize;
}

/// Synchronous crop drag, handle adjustment, and commit controller.
final class CropToolController extends ToolController<CropToolKind> {
  /// Creates a crop controller.
  CropToolController() : super(const CropToolKind());

  CropDraft? _draft;
  Offset? _dragStart;
  CropHandle? _activeHandle;
  Rect? _handleDragStartRect;

  /// Current artwork and proposed crop bounds.
  CropDraft? get draft => _draft;

  /// Handle currently being adjusted.
  CropHandle? get activeHandle => _activeHandle;

  @override
  bool get hasLiveState => _draft != null;

  /// Begins a fresh crop rectangle clamped to [artworkBounds].
  CropDraft beginDrag({required Offset point, required Rect artworkBounds}) {
    _requireFiniteOffset(point, 'point');
    _requireUsableRect(artworkBounds, 'artworkBounds');
    final Offset clamped = _clampPoint(point, artworkBounds);
    final CropDraft result = CropDraft(
      artworkBounds: artworkBounds,
      cropRect: Rect.fromPoints(clamped, clamped),
    );
    _draft = result;
    _dragStart = clamped;
    _activeHandle = null;
    _handleDragStartRect = null;
    return result;
  }

  /// Updates the fresh crop drag.
  CropDraft updateDrag(Offset point) {
    _requireFiniteOffset(point, 'point');
    final CropDraft current = _requireDraft();
    final Offset? start = _dragStart;
    if (start == null) {
      throw StateError('No fresh crop drag is active.');
    }
    final Rect rect = Rect.fromPoints(
      start,
      _clampPoint(point, current.artworkBounds),
    );
    final CropDraft next = CropDraft(
      artworkBounds: current.artworkBounds,
      cropRect: rect,
    );
    _draft = next;
    return next;
  }

  /// Ends the initial drag while keeping its handles live.
  void endDrag() {
    _dragStart = null;
  }

  /// Captures one of the eight adjustment handles.
  void beginHandleDrag(CropHandle handle) {
    final CropDraft current = _requireDraft();
    _dragStart = null;
    _activeHandle = handle;
    _handleDragStartRect = current.cropRect;
  }

  /// Adjusts the captured handle, clamped to the existing artwork.
  ///
  /// When [preserveAspect] is true, the crop keeps the aspect ratio captured
  /// by [beginHandleDrag]. Corner handles retain their opposite corner; edge
  /// handles retain their opposite edge and center the perpendicular span.
  CropDraft updateHandleDrag(Offset point, {bool preserveAspect = false}) {
    _requireFiniteOffset(point, 'point');
    final CropDraft current = _requireDraft();
    final CropHandle? handle = _activeHandle;
    if (handle == null) {
      throw StateError('No crop handle drag is active.');
    }
    final Offset clamped = _clampPoint(point, current.artworkBounds);
    final Rect handleStart = _handleDragStartRect ?? current.cropRect;
    if (preserveAspect && !handleStart.isEmpty) {
      final CropDraft next = CropDraft(
        artworkBounds: current.artworkBounds,
        cropRect: _resizeWithPreservedAspect(
          cropRect: handleStart,
          artworkBounds: current.artworkBounds,
          handle: handle,
          point: clamped,
        ),
      );
      _draft = next;
      return next;
    }
    const double minimumExtent = 1;
    var left = current.cropRect.left;
    var top = current.cropRect.top;
    var right = current.cropRect.right;
    var bottom = current.cropRect.bottom;
    switch (handle) {
      case CropHandle.topLeft:
        left = math.min(clamped.dx, right - minimumExtent);
        top = math.min(clamped.dy, bottom - minimumExtent);
      case CropHandle.topCenter:
        top = math.min(clamped.dy, bottom - minimumExtent);
      case CropHandle.topRight:
        right = math.max(clamped.dx, left + minimumExtent);
        top = math.min(clamped.dy, bottom - minimumExtent);
      case CropHandle.middleLeft:
        left = math.min(clamped.dx, right - minimumExtent);
      case CropHandle.middleRight:
        right = math.max(clamped.dx, left + minimumExtent);
      case CropHandle.bottomLeft:
        left = math.min(clamped.dx, right - minimumExtent);
        bottom = math.max(clamped.dy, top + minimumExtent);
      case CropHandle.bottomCenter:
        bottom = math.max(clamped.dy, top + minimumExtent);
      case CropHandle.bottomRight:
        right = math.max(clamped.dx, left + minimumExtent);
        bottom = math.max(clamped.dy, top + minimumExtent);
    }
    final CropDraft next = CropDraft(
      artworkBounds: current.artworkBounds,
      cropRect: Rect.fromLTRB(left, top, right, bottom),
    );
    _draft = next;
    return next;
  }

  /// Ends a handle adjustment while retaining the proposed crop.
  void endHandleDrag() {
    _activeHandle = null;
    _handleDragStartRect = null;
  }

  /// Commits the proposed crop as a `canvasResize` journal action.
  CropCommand commit() {
    final CropDraft current = _requireDraft();
    if (current.cropRect.isEmpty ||
        current.cropRect.width < 1 ||
        current.cropRect.height < 1) {
      throw StateError('Cannot commit an empty crop.');
    }
    final Rect pixelBounds = Rect.fromLTRB(
      current.cropRect.left.roundToDouble(),
      current.cropRect.top.roundToDouble(),
      current.cropRect.right.roundToDouble(),
      current.cropRect.bottom.roundToDouble(),
    );
    if (pixelBounds.isEmpty) {
      throw StateError('Cannot commit a crop smaller than one document pixel.');
    }
    final CropCommand command = CropCommand(
      previousBounds: current.artworkBounds,
      newBounds: pixelBounds,
    );
    cancel();
    return command;
  }

  /// Restores an editable draft after a host-side commit failure.
  void restoreDraft(CropDraft draft) {
    _draft = draft;
    _dragStart = null;
    _activeHandle = null;
    _handleDragStartRect = null;
  }

  CropDraft _requireDraft() {
    final CropDraft? current = _draft;
    if (current == null) {
      throw StateError('No crop is active.');
    }
    return current;
  }

  @override
  void cancel() {
    _draft = null;
    _dragStart = null;
    _activeHandle = null;
    _handleDragStartRect = null;
  }
}

Rect _resizeWithPreservedAspect({
  required Rect cropRect,
  required Rect artworkBounds,
  required CropHandle handle,
  required Offset point,
}) {
  final double aspectRatio = cropRect.width / cropRect.height;
  return switch (handle) {
    CropHandle.topLeft => _resizeCornerWithPreservedAspect(
      anchor: cropRect.bottomRight,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: true,
      growsUp: true,
    ),
    CropHandle.topCenter => _resizeVerticalEdgeWithPreservedAspect(
      anchorY: cropRect.bottom,
      centerX: cropRect.center.dx,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsUp: true,
    ),
    CropHandle.topRight => _resizeCornerWithPreservedAspect(
      anchor: cropRect.bottomLeft,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: false,
      growsUp: true,
    ),
    CropHandle.middleLeft => _resizeHorizontalEdgeWithPreservedAspect(
      anchorX: cropRect.right,
      centerY: cropRect.center.dy,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: true,
    ),
    CropHandle.middleRight => _resizeHorizontalEdgeWithPreservedAspect(
      anchorX: cropRect.left,
      centerY: cropRect.center.dy,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: false,
    ),
    CropHandle.bottomLeft => _resizeCornerWithPreservedAspect(
      anchor: cropRect.topRight,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: true,
      growsUp: false,
    ),
    CropHandle.bottomCenter => _resizeVerticalEdgeWithPreservedAspect(
      anchorY: cropRect.top,
      centerX: cropRect.center.dx,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsUp: false,
    ),
    CropHandle.bottomRight => _resizeCornerWithPreservedAspect(
      anchor: cropRect.topLeft,
      point: point,
      artworkBounds: artworkBounds,
      aspectRatio: aspectRatio,
      growsLeft: false,
      growsUp: false,
    ),
  };
}

Rect _resizeCornerWithPreservedAspect({
  required Offset anchor,
  required Offset point,
  required Rect artworkBounds,
  required double aspectRatio,
  required bool growsLeft,
  required bool growsUp,
}) {
  final double desiredWidth = math.max(
    0,
    growsLeft ? anchor.dx - point.dx : point.dx - anchor.dx,
  );
  final double desiredHeight = math.max(
    0,
    growsUp ? anchor.dy - point.dy : point.dy - anchor.dy,
  );
  final double horizontalCapacity = growsLeft
      ? anchor.dx - artworkBounds.left
      : artworkBounds.right - anchor.dx;
  final double verticalCapacity = growsUp
      ? anchor.dy - artworkBounds.top
      : artworkBounds.bottom - anchor.dy;
  final double maximumHeight = math.min(
    verticalCapacity,
    horizontalCapacity / aspectRatio,
  );
  final double height = _clampResizeExtent(
    desired: math.max(desiredHeight, desiredWidth / aspectRatio),
    minimum: math.max(1, 1 / aspectRatio),
    maximum: maximumHeight,
  );
  final double width = height * aspectRatio;
  return _clampResizeRect(
    Rect.fromLTRB(
      growsLeft ? anchor.dx - width : anchor.dx,
      growsUp ? anchor.dy - height : anchor.dy,
      growsLeft ? anchor.dx : anchor.dx + width,
      growsUp ? anchor.dy : anchor.dy + height,
    ),
    artworkBounds,
  );
}

Rect _resizeVerticalEdgeWithPreservedAspect({
  required double anchorY,
  required double centerX,
  required Offset point,
  required Rect artworkBounds,
  required double aspectRatio,
  required bool growsUp,
}) {
  final double desiredHeight = math.max(
    0,
    growsUp ? anchorY - point.dy : point.dy - anchorY,
  );
  final double verticalCapacity = growsUp
      ? anchorY - artworkBounds.top
      : artworkBounds.bottom - anchorY;
  final double horizontalCapacity =
      2 * math.min(centerX - artworkBounds.left, artworkBounds.right - centerX);
  final double height = _clampResizeExtent(
    desired: desiredHeight,
    minimum: math.max(1, 1 / aspectRatio),
    maximum: math.min(verticalCapacity, horizontalCapacity / aspectRatio),
  );
  final double width = height * aspectRatio;
  return _clampResizeRect(
    Rect.fromLTRB(
      centerX - width / 2,
      growsUp ? anchorY - height : anchorY,
      centerX + width / 2,
      growsUp ? anchorY : anchorY + height,
    ),
    artworkBounds,
  );
}

Rect _resizeHorizontalEdgeWithPreservedAspect({
  required double anchorX,
  required double centerY,
  required Offset point,
  required Rect artworkBounds,
  required double aspectRatio,
  required bool growsLeft,
}) {
  final double desiredWidth = math.max(
    0,
    growsLeft ? anchorX - point.dx : point.dx - anchorX,
  );
  final double horizontalCapacity = growsLeft
      ? anchorX - artworkBounds.left
      : artworkBounds.right - anchorX;
  final double verticalCapacity =
      2 * math.min(centerY - artworkBounds.top, artworkBounds.bottom - centerY);
  final double width = _clampResizeExtent(
    desired: desiredWidth,
    minimum: math.max(1, aspectRatio),
    maximum: math.min(horizontalCapacity, verticalCapacity * aspectRatio),
  );
  final double height = width / aspectRatio;
  return _clampResizeRect(
    Rect.fromLTRB(
      growsLeft ? anchorX - width : anchorX,
      centerY - height / 2,
      growsLeft ? anchorX : anchorX + width,
      centerY + height / 2,
    ),
    artworkBounds,
  );
}

Rect _clampResizeRect(Rect rect, Rect bounds) => Rect.fromLTRB(
  rect.left.clamp(bounds.left, bounds.right),
  rect.top.clamp(bounds.top, bounds.bottom),
  rect.right.clamp(bounds.left, bounds.right),
  rect.bottom.clamp(bounds.top, bounds.bottom),
);

double _clampResizeExtent({
  required double desired,
  required double minimum,
  required double maximum,
}) => desired.clamp(math.min(minimum, maximum), maximum);

Offset _clampPoint(Offset point, Rect bounds) => Offset(
  point.dx.clamp(bounds.left, bounds.right),
  point.dy.clamp(bounds.top, bounds.bottom),
);

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

bool _hasIntegerEdges(Rect rect) =>
    rect.left == rect.left.roundToDouble() &&
    rect.top == rect.top.roundToDouble() &&
    rect.right == rect.right.roundToDouble() &&
    rect.bottom == rect.bottom.roundToDouble();

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireFiniteRect(Rect value, String name) {
  if (!value.left.isFinite ||
      !value.top.isFinite ||
      !value.right.isFinite ||
      !value.bottom.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireUsableRect(Rect value, String name) {
  _requireFiniteRect(value, name);
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}
