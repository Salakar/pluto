import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../document/document.dart';
import '../document/tile_store.dart';
import 'geometry.dart';

/// Largest twist velocity that may capture a rotation detent, in radians/s.
const double rotationSnapVelocity = 0.35;

/// Minimum fraction of the smaller canvas/viewport area retained on-screen.
const double minimumVisibleCanvasFraction = 0.15;

/// Owns Ink's document-to-viewport similarity transform.
///
/// The controller stores canonical translation, scale, and rotation values and
/// only ever assembles matrices from them. It never decomposes a matrix. It is
/// deliberately not a [Listenable]; [onChanged] lets the engine's independent
/// repaint signal react without routing stroke frames through app models.
final class CanvasController {
  /// Creates a controller for one fixed-size document and current viewport.
  CanvasController({
    required Size documentSize,
    required Size viewportSize,
    InkViewState? initialView,
    this.onChanged,
  }) : _documentSize = _checkedSize(documentSize, 'documentSize'),
       _viewportSize = _checkedSize(viewportSize, 'viewportSize'),
       _translation = Offset(initialView?.tx ?? 0, initialView?.ty ?? 0),
       _scale = constrainCanvasScale(initialView?.scale ?? 1),
       _rotation = normalizeRadians(
         (initialView?.rotationDeg ?? 0) * math.pi / 180,
       ) {
    _constrainTranslation();
    _rebuildMatrices();
  }

  Size _documentSize;
  Size _viewportSize;
  Offset _translation;
  double _scale;
  double _rotation;

  /// Optional hook used to request an engine repaint after each action.
  final VoidCallback? onChanged;

  late Matrix4 _viewMatrix;
  late Matrix4 _inverseViewMatrix;

  bool _gestureActive = false;
  bool _strokeLocked = false;
  Offset? _gestureAnchorDocument;
  double _gestureStartScale = 1;
  double _gestureStartRotation = 0;

  /// Artwork dimensions in document pixels.
  Size get documentSize => _documentSize;

  /// Current canvas viewport in logical pixels.
  Size get viewportSize => _viewportSize;

  /// Viewport-space translation applied after scale and rotation.
  Offset get translation => _translation;

  /// Uniform document-to-viewport scale.
  double get scale => _scale;

  /// Clockwise document rotation in radians.
  double get rotation => _rotation;

  /// Clockwise document rotation in degrees.
  double get rotationDegrees => _rotation * 180 / math.pi;

  /// Whether a two-pointer navigation gesture currently owns the transform.
  bool get gestureActive => _gestureActive;

  /// Whether stylus-down through commit-published has frozen navigation.
  bool get strokeLocked => _strokeLocked;

  /// Fresh document-to-viewport matrix assembled as translate/rotate/scale.
  Matrix4 get viewMatrix => Matrix4.copy(_viewMatrix);

  /// Maps a viewport logical-pixel point into document pixels.
  Offset docFromViewport(Offset point) =>
      transformPoint(_inverseViewMatrix, point);

  /// Maps a document-pixel point into viewport logical pixels.
  Offset viewportFromDoc(Offset point) => transformPoint(_viewMatrix, point);

  /// Tile positions whose document rectangles intersect the current viewport.
  List<TileKey> get visibleTiles => visibleTileKeys(
    viewMatrix: _viewMatrix,
    viewportSize: _viewportSize,
    documentSize: _documentSize,
  );

  /// Persistable snapshot of the current view transform.
  InkViewState toViewState() => InkViewState(
    tx: _translation.dx,
    ty: _translation.dy,
    scale: _scale,
    rotationDeg: rotationDegrees,
  );

  /// Updates viewport dimensions and re-applies the visibility clamp.
  void setViewportSize(Size size) {
    if (_strokeLocked) {
      return;
    }
    final next = _checkedSize(size, 'size');
    if (next == _viewportSize) {
      return;
    }
    _viewportSize = next;
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Updates document bounds, for a later journaled canvas-resize operation.
  void setDocumentSize(Size size) {
    if (_strokeLocked) {
      return;
    }
    final next = _checkedSize(size, 'size');
    if (next == _documentSize) {
      return;
    }
    _documentSize = next;
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Replaces canonical transform values without accepting an arbitrary matrix.
  void setView({
    required Offset translation,
    required double scale,
    required double rotation,
    bool snapScale = true,
  }) {
    if (_strokeLocked) {
      return;
    }
    _checkOffset(translation, 'translation');
    _translation = translation;
    _scale = constrainCanvasScale(scale, snapToUnit: snapScale);
    _rotation = normalizeRadians(rotation);
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Begins a navigation gesture and captures its focal document point.
  ///
  /// Returns false while a stroke lock is held or another gesture is active.
  bool beginNavigation(Offset focalPoint) {
    _checkOffset(focalPoint, 'focalPoint');
    if (_strokeLocked || _gestureActive) {
      return false;
    }
    _gestureActive = true;
    _gestureAnchorDocument = docFromViewport(focalPoint);
    _gestureStartScale = _scale;
    _gestureStartRotation = _rotation;
    onChanged?.call();
    return true;
  }

  /// Applies scale and rotation relative to [beginNavigation].
  ///
  /// [scale] is a positive gesture scale factor and [rotation] is a gesture
  /// rotation delta in radians. The captured document point follows
  /// [focalPoint], producing simultaneous 1:1 focal pan, zoom, and twist.
  void updateNavigation({
    required Offset focalPoint,
    required double scale,
    required double rotation,
  }) {
    if (!_gestureActive || _strokeLocked) {
      return;
    }
    _checkOffset(focalPoint, 'focalPoint');
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and positive');
    }
    if (!rotation.isFinite) {
      throw ArgumentError.value(rotation, 'rotation', 'must be finite');
    }
    _scale = constrainCanvasScale(_gestureStartScale * scale);
    _rotation = normalizeRadians(_gestureStartRotation + rotation);
    final anchor = _gestureAnchorDocument!;
    final transformedAnchor = _linearTransform(anchor);
    _translation = focalPoint - transformedAnchor;
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Ends navigation without inertia and optionally captures a rotation detent.
  void endNavigation({double twistVelocity = 0}) {
    if (!_gestureActive) {
      return;
    }
    if (!twistVelocity.isFinite) {
      throw ArgumentError.value(
        twistVelocity,
        'twistVelocity',
        'must be finite',
      );
    }
    final anchor = _gestureAnchorDocument;
    final focalPoint = anchor == null ? null : viewportFromDoc(anchor);
    _gestureActive = false;
    _scale = constrainCanvasScale(_scale);
    if (twistVelocity.abs() <= rotationSnapVelocity) {
      _rotation = snapRotationToQuarterTurn(_rotation);
    }
    if (anchor != null && focalPoint != null) {
      _translation = focalPoint - _linearTransform(anchor);
    }
    _gestureAnchorDocument = null;
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Ends a cancelled navigation gesture at its latest transform, unsnapped.
  void cancelNavigation() {
    if (!_gestureActive) {
      return;
    }
    _gestureActive = false;
    _gestureAnchorDocument = null;
    onChanged?.call();
  }

  /// Fits the unrotated document into the viewport and centers it.
  void fitToViewport({double padding = 0}) {
    if (_strokeLocked) {
      return;
    }
    if (!padding.isFinite || padding < 0) {
      throw ArgumentError.value(padding, 'padding', 'must be finite and >= 0');
    }
    final usableWidth = math.max(1, _viewportSize.width - padding * 2);
    final usableHeight = math.max(1, _viewportSize.height - padding * 2);
    _rotation = 0;
    _scale = constrainCanvasScale(
      math.min(
        usableWidth / _documentSize.width,
        usableHeight / _documentSize.height,
      ),
      snapToUnit: false,
    );
    _translation = Offset(
      (_viewportSize.width - _documentSize.width * _scale) / 2,
      (_viewportSize.height - _documentSize.height * _scale) / 2,
    );
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Shows exact 100 percent zoom around the viewport center.
  void resetScale() {
    if (_strokeLocked) {
      return;
    }
    final focal = _viewportSize.center(Offset.zero);
    final anchor = docFromViewport(focal);
    _scale = 1;
    _translation = focal - _linearTransform(anchor);
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Resets rotation alone around the viewport center.
  void resetRotation() {
    if (_strokeLocked || _rotation == 0) {
      return;
    }
    final focal = _viewportSize.center(Offset.zero);
    final anchor = docFromViewport(focal);
    _rotation = 0;
    _translation = focal - _linearTransform(anchor);
    _constrainTranslation();
    _rebuildMatrices();
    onChanged?.call();
  }

  /// Freezes the transform from stylus-down through commit publication.
  void lockForStroke() {
    if (_strokeLocked) {
      return;
    }
    _strokeLocked = true;
    if (_gestureActive) {
      _gestureActive = false;
      _gestureAnchorDocument = null;
    }
    onChanged?.call();
  }

  /// Releases the transform only after the committed tiles are published.
  void unlockAfterStrokeCommit() {
    if (!_strokeLocked) {
      return;
    }
    _strokeLocked = false;
    onChanged?.call();
  }

  Offset _linearTransform(Offset point) {
    final scaledX = point.dx * _scale;
    final scaledY = point.dy * _scale;
    final cosine = math.cos(_rotation);
    final sine = math.sin(_rotation);
    return Offset(
      scaledX * cosine - scaledY * sine,
      scaledX * sine + scaledY * cosine,
    );
  }

  void _constrainTranslation() {
    final linear = Matrix4.identity()
      ..rotateZ(_rotation)
      ..scaleByDouble(_scale, _scale, 1, 1);
    final bounds = transformedBounds(linear, Offset.zero & _documentSize);
    final centered = _viewportSize.center(Offset.zero) - bounds.center;
    final viewportRect = Offset.zero & _viewportSize;
    final canvasRect = Offset.zero & _documentSize;
    final requested = _translation;
    double overlapAt(Offset translation) => transformedRectIntersectionArea(
      Matrix4.identity()
        ..translateByDouble(translation.dx, translation.dy, 0, 1)
        ..multiply(linear),
      canvasRect,
      viewportRect,
    );
    final requestedOverlap = overlapAt(requested);
    final centeredOverlap = overlapAt(centered);
    final transformedCanvasArea =
        _documentSize.width * _documentSize.height * _scale * _scale;
    final desiredOverlap =
        math.min(
          transformedCanvasArea,
          viewportRect.width * viewportRect.height,
        ) *
        minimumVisibleCanvasFraction;
    final requiredOverlap = math.min(desiredOverlap, centeredOverlap);
    if (requestedOverlap + 1e-7 >= requiredOverlap) {
      return;
    }

    // Centering is the maximum-overlap position for these centrally symmetric
    // rectangles. Walk toward the requested pan until the 15% area boundary.
    var validFraction = 0.0;
    var invalidFraction = 1.0;
    for (var iteration = 0; iteration < 40; iteration += 1) {
      final fraction = (validFraction + invalidFraction) / 2;
      final candidate = Offset.lerp(centered, requested, fraction)!;
      if (overlapAt(candidate) + 1e-7 >= requiredOverlap) {
        validFraction = fraction;
      } else {
        invalidFraction = fraction;
      }
    }
    _translation = Offset.lerp(centered, requested, validFraction)!;
  }

  void _rebuildMatrices() {
    _viewMatrix = Matrix4.identity()
      ..translateByDouble(_translation.dx, _translation.dy, 0, 1)
      ..rotateZ(_rotation)
      ..scaleByDouble(_scale, _scale, 1, 1);
    _inverseViewMatrix = invertedMatrix(_viewMatrix);
  }

  static Size _checkedSize(Size size, String name) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(size, name, 'must be finite and non-empty');
    }
    return size;
  }

  static void _checkOffset(Offset offset, String name) {
    if (!offset.dx.isFinite || !offset.dy.isFinite) {
      throw ArgumentError.value(offset, name, 'must be finite');
    }
  }
}
