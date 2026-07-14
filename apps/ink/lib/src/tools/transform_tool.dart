import 'dart:math' as math;
import 'dart:ui';

import 'selection_tool.dart';
import 'tool.dart';

/// Raster sampling used by a transform presentation.
enum TransformResampling {
  /// Fast, stable pixel presentation while the pointer is moving.
  nearest,

  /// Quality presentation after the pointer comes to rest.
  bilinear,
}

/// Eight resize handles plus the separate rotation lug.
enum TransformHandle {
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

  /// Rotation lug outside the bounds.
  rotateLug,
}

/// Closed union of transformable content targets.
sealed class TransformTarget {
  const TransformTarget(this.layerId, this.sourceBounds);

  /// Content layer being transformed.
  final String layerId;

  /// Original document-space pixel bounds.
  final Rect sourceBounds;
}

/// Active-selection transform target.
final class SelectionTransformTarget extends TransformTarget {
  /// Creates a selection target.
  SelectionTransformTarget({required String layerId, required this.mask})
    : super(layerId, mask.bounds) {
    _requireId(layerId, 'layerId');
  }

  /// Static selection mask used to extract and clip the float.
  final SelectionMask mask;
}

/// Whole-active-layer fallback used when no selection exists.
final class WholeLayerTransformTarget extends TransformTarget {
  /// Creates a whole-layer target.
  WholeLayerTransformTarget({required String layerId, required Rect bounds})
    : super(layerId, bounds) {
    _requireId(layerId, 'layerId');
    _requireUsableRect(bounds, 'bounds');
  }
}

/// Immutable transform state presented by the handles overlay.
final class TransformSnapshot {
  /// Creates a validated transform snapshot.
  TransformSnapshot({
    required this.target,
    required this.bounds,
    required this.rotationRadians,
    required this.resampling,
    this.isFlippedHorizontally = false,
    this.isFlippedVertically = false,
  }) {
    _requireUsableRect(bounds, 'bounds');
    if (!rotationRadians.isFinite) {
      throw ArgumentError.value(
        rotationRadians,
        'rotationRadians',
        'must be finite',
      );
    }
  }

  /// Selection or whole-layer source.
  final TransformTarget target;

  /// Unrotated destination bounds.
  final Rect bounds;

  /// Rotation about [bounds]' center.
  final double rotationRadians;

  /// Sampling quality required for this presentation.
  final TransformResampling resampling;

  /// Whether the destination is mirrored around its vertical center axis.
  final bool isFlippedHorizontally;

  /// Whether the destination is mirrored around its horizontal center axis.
  final bool isFlippedVertically;
}

/// Non-journaled transform preview command.
final class TransformPreviewCommand implements ToolCommand {
  /// Creates a worker preview request.
  const TransformPreviewCommand(this.snapshot);

  /// Current destination transform and requested sampling.
  final TransformSnapshot snapshot;
}

/// Final quality transform commit.
final class TransformCommitCommand implements JournaledToolCommand {
  /// Creates a final transform command.
  const TransformCommitCommand(this.snapshot);

  /// Final destination transform, always bilinear.
  final TransformSnapshot snapshot;

  @override
  JournalKind get journalKind => JournalKind.floatCommit;
}

/// Snaps [radians] to the nearest binding 15-degree rotation detent.
double snapTransformRotation(double radians) {
  if (!radians.isFinite) {
    throw ArgumentError.value(radians, 'radians', 'must be finite');
  }
  const double step = math.pi / 12;
  return (radians / step).round() * step;
}

/// Synchronous eight-handle transform controller.
final class TransformToolController extends ToolController<TransformToolKind> {
  /// Creates a controller with aspect locking enabled by default.
  TransformToolController({bool lockAspect = true})
    : // The public parameter intentionally omits the private field prefix.
      // ignore: prefer_initializing_formals
      _lockAspect = lockAspect,
      super(const TransformToolKind());

  bool _lockAspect;
  TransformSnapshot? _snapshot;
  TransformHandle? _activeHandle;
  Offset? _dragOrigin;
  Rect? _dragBounds;
  double? _dragRotation;

  /// Whether resize gestures preserve the source aspect ratio.
  bool get lockAspect => _lockAspect;

  /// Current transform state, if the tool has a target.
  TransformSnapshot? get snapshot => _snapshot;

  /// Handle currently driven by the pointer.
  TransformHandle? get activeHandle => _activeHandle;

  @override
  bool get hasLiveState => _snapshot != null;

  /// Changes the contextual-dock aspect toggle.
  void setLockAspect(bool value) {
    _lockAspect = value;
  }

  /// Activates the selected region, or the whole active layer as fallback.
  TransformSnapshot begin({
    required String activeLayerId,
    required Rect activeLayerBounds,
    SelectionMask? selection,
  }) {
    _requireId(activeLayerId, 'activeLayerId');
    _requireUsableRect(activeLayerBounds, 'activeLayerBounds');
    final TransformTarget target = selection == null
        ? WholeLayerTransformTarget(
            layerId: activeLayerId,
            bounds: activeLayerBounds,
          )
        : SelectionTransformTarget(layerId: activeLayerId, mask: selection);
    final TransformSnapshot result = TransformSnapshot(
      target: target,
      bounds: target.sourceBounds,
      rotationRadians: 0,
      resampling: TransformResampling.bilinear,
    );
    _snapshot = result;
    _clearDrag();
    return result;
  }

  /// Captures one handle and its stable drag origin.
  void beginHandleDrag(TransformHandle handle, Offset pointer) {
    _requireFiniteOffset(pointer, 'pointer');
    final TransformSnapshot? current = _snapshot;
    if (current == null) {
      throw StateError('Transform has no active target.');
    }
    _activeHandle = handle;
    _dragOrigin = pointer;
    _dragBounds = current.bounds;
    _dragRotation = current.rotationRadians;
  }

  /// Updates the captured handle using nearest-neighbor presentation.
  TransformPreviewCommand updateHandleDrag(Offset pointer) {
    _requireFiniteOffset(pointer, 'pointer');
    final TransformSnapshot? current = _snapshot;
    final TransformHandle? handle = _activeHandle;
    final Offset? dragOrigin = _dragOrigin;
    final Rect? dragBounds = _dragBounds;
    final double? dragRotation = _dragRotation;
    if (current == null ||
        handle == null ||
        dragOrigin == null ||
        dragBounds == null ||
        dragRotation == null) {
      throw StateError('No transform handle drag is active.');
    }

    final TransformSnapshot next;
    if (handle == TransformHandle.rotateLug) {
      final Offset center = dragBounds.center;
      final Offset from = dragOrigin - center;
      final Offset to = pointer - center;
      if (from.distanceSquared == 0 || to.distanceSquared == 0) {
        throw ArgumentError.value(
          pointer,
          'pointer',
          'rotation pointer must not coincide with the center',
        );
      }
      final double delta =
          math.atan2(to.dy, to.dx) - math.atan2(from.dy, from.dx);
      next = TransformSnapshot(
        target: current.target,
        bounds: dragBounds,
        rotationRadians: snapTransformRotation(dragRotation + delta),
        resampling: TransformResampling.nearest,
        isFlippedHorizontally: current.isFlippedHorizontally,
        isFlippedVertically: current.isFlippedVertically,
      );
    } else {
      next = TransformSnapshot(
        target: current.target,
        bounds: _resizeBounds(dragBounds, handle, pointer, _lockAspect),
        rotationRadians: dragRotation,
        resampling: TransformResampling.nearest,
        isFlippedHorizontally: current.isFlippedHorizontally,
        isFlippedVertically: current.isFlippedVertically,
      );
    }
    _snapshot = next;
    return TransformPreviewCommand(next);
  }

  /// Translates the target during a move gesture using nearest sampling.
  TransformPreviewCommand translateBy(Offset delta) {
    _requireFiniteOffset(delta, 'delta');
    final TransformSnapshot? current = _snapshot;
    if (current == null) {
      throw StateError('Transform has no active target.');
    }
    final TransformSnapshot next = TransformSnapshot(
      target: current.target,
      bounds: current.bounds.shift(delta),
      rotationRadians: current.rotationRadians,
      resampling: TransformResampling.nearest,
      isFlippedHorizontally: current.isFlippedHorizontally,
      isFlippedVertically: current.isFlippedVertically,
    );
    _snapshot = next;
    return TransformPreviewCommand(next);
  }

  /// Ends a pointer drag and requests a bilinear rest presentation.
  TransformPreviewCommand endDrag() {
    final TransformSnapshot? current = _snapshot;
    if (current == null) {
      throw StateError('Transform has no active target.');
    }
    final TransformSnapshot settled = TransformSnapshot(
      target: current.target,
      bounds: current.bounds,
      rotationRadians: current.rotationRadians,
      resampling: TransformResampling.bilinear,
      isFlippedHorizontally: current.isFlippedHorizontally,
      isFlippedVertically: current.isFlippedVertically,
    );
    _snapshot = settled;
    _clearDrag();
    return TransformPreviewCommand(settled);
  }

  /// Mirrors the live destination horizontally and settles bilinearly.
  TransformPreviewCommand flipHorizontal() => _setOneShotTransform(
    flipHorizontal: !_requireSnapshot().isFlippedHorizontally,
  );

  /// Mirrors the live destination vertically and settles bilinearly.
  TransformPreviewCommand flipVertical() => _setOneShotTransform(
    flipVertical: !_requireSnapshot().isFlippedVertically,
  );

  /// Rotates the live destination by [radians] and settles bilinearly.
  TransformPreviewCommand rotateBy(double radians) {
    if (!radians.isFinite) {
      throw ArgumentError.value(radians, 'radians', 'must be finite');
    }
    return _setOneShotTransform(
      rotationRadians: _requireSnapshot().rotationRadians + radians,
    );
  }

  /// Restores source bounds, zero rotation, and no mirror flags.
  TransformPreviewCommand reset() {
    final TransformSnapshot current = _requireSnapshot();
    final TransformSnapshot reset = TransformSnapshot(
      target: current.target,
      bounds: current.target.sourceBounds,
      rotationRadians: 0,
      resampling: TransformResampling.bilinear,
    );
    _snapshot = reset;
    _clearDrag();
    return TransformPreviewCommand(reset);
  }

  /// Emits the final bilinear commit and clears the live target.
  TransformCommitCommand commit() {
    final TransformSnapshot? current = _snapshot;
    if (current == null) {
      throw StateError('Transform has no active target.');
    }
    final TransformSnapshot settled = TransformSnapshot(
      target: current.target,
      bounds: current.bounds,
      rotationRadians: current.rotationRadians,
      resampling: TransformResampling.bilinear,
      isFlippedHorizontally: current.isFlippedHorizontally,
      isFlippedVertically: current.isFlippedVertically,
    );
    _snapshot = null;
    _clearDrag();
    return TransformCommitCommand(settled);
  }

  /// Restores a live snapshot after a host-side commit failure.
  void restore(TransformSnapshot snapshot) {
    _snapshot = snapshot;
    _clearDrag();
  }

  TransformPreviewCommand _setOneShotTransform({
    bool? flipHorizontal,
    bool? flipVertical,
    double? rotationRadians,
  }) {
    final TransformSnapshot current = _requireSnapshot();
    final TransformSnapshot next = TransformSnapshot(
      target: current.target,
      bounds: current.bounds,
      rotationRadians: rotationRadians ?? current.rotationRadians,
      resampling: TransformResampling.bilinear,
      isFlippedHorizontally: flipHorizontal ?? current.isFlippedHorizontally,
      isFlippedVertically: flipVertical ?? current.isFlippedVertically,
    );
    _snapshot = next;
    _clearDrag();
    return TransformPreviewCommand(next);
  }

  TransformSnapshot _requireSnapshot() {
    final TransformSnapshot? current = _snapshot;
    if (current == null) {
      throw StateError('Transform has no active target.');
    }
    return current;
  }

  @override
  void cancel() {
    _snapshot = null;
    _clearDrag();
  }

  void _clearDrag() {
    _activeHandle = null;
    _dragOrigin = null;
    _dragBounds = null;
    _dragRotation = null;
  }
}

Rect _resizeBounds(
  Rect source,
  TransformHandle handle,
  Offset pointer,
  bool lockAspect,
) {
  const double minimumExtent = 1;
  var left = source.left;
  var top = source.top;
  var right = source.right;
  var bottom = source.bottom;

  final bool changesLeft = switch (handle) {
    TransformHandle.topLeft ||
    TransformHandle.middleLeft ||
    TransformHandle.bottomLeft => true,
    _ => false,
  };
  final bool changesRight = switch (handle) {
    TransformHandle.topRight ||
    TransformHandle.middleRight ||
    TransformHandle.bottomRight => true,
    _ => false,
  };
  final bool changesTop = switch (handle) {
    TransformHandle.topLeft ||
    TransformHandle.topCenter ||
    TransformHandle.topRight => true,
    _ => false,
  };
  final bool changesBottom = switch (handle) {
    TransformHandle.bottomLeft ||
    TransformHandle.bottomCenter ||
    TransformHandle.bottomRight => true,
    _ => false,
  };

  if (changesLeft) {
    left = math.min(pointer.dx, right - minimumExtent);
  }
  if (changesRight) {
    right = math.max(pointer.dx, left + minimumExtent);
  }
  if (changesTop) {
    top = math.min(pointer.dy, bottom - minimumExtent);
  }
  if (changesBottom) {
    bottom = math.max(pointer.dy, top + minimumExtent);
  }
  if (!lockAspect) {
    return Rect.fromLTRB(left, top, right, bottom);
  }

  final double aspect = source.width / source.height;
  final bool changesX = changesLeft || changesRight;
  final bool changesY = changesTop || changesBottom;
  if (changesX && changesY) {
    var width = right - left;
    var height = bottom - top;
    final double widthChange = (width / source.width - 1).abs();
    final double heightChange = (height / source.height - 1).abs();
    if (widthChange >= heightChange) {
      height = width / aspect;
    } else {
      width = height * aspect;
    }
    if (changesLeft) {
      left = source.right - width;
      right = source.right;
    } else {
      left = source.left;
      right = source.left + width;
    }
    if (changesTop) {
      top = source.bottom - height;
      bottom = source.bottom;
    } else {
      top = source.top;
      bottom = source.top + height;
    }
  } else if (changesX) {
    final double height = (right - left) / aspect;
    top = source.center.dy - height / 2;
    bottom = source.center.dy + height / 2;
  } else if (changesY) {
    final double width = (bottom - top) * aspect;
    left = source.center.dx - width / 2;
    right = source.center.dx + width / 2;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void _requireFiniteOffset(Offset value, String name) {
  if (!value.dx.isFinite || !value.dy.isFinite) {
    throw ArgumentError.value(value, name, 'must be finite');
  }
}

void _requireUsableRect(Rect value, String name) {
  if (!value.left.isFinite ||
      !value.top.isFinite ||
      !value.right.isFinite ||
      !value.bottom.isFinite ||
      value.isEmpty) {
    throw ArgumentError.value(value, name, 'must be finite and non-empty');
  }
}

void _requireId(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}
