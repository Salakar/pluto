import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'tool.dart';

/// Selection geometry offered in the contextual dock.
enum SelectionMode {
  /// Axis-aligned rectangular selection.
  rectangle,

  /// Closed freehand polygon selection.
  lasso,

  /// Contiguous-color selection seeded by one point.
  wand,
}

/// How a newly produced region changes an existing selection.
enum SelectionCombineMode {
  /// Discards the old mask and owns the new region.
  replace,

  /// Unions the new region into the old mask.
  add,

  /// Removes the new region from the old mask.
  subtract,
}

/// Immutable document-space coverage mask owned by the selection tool.
///
/// Coverage is byte-valued so antialiased lasso boundaries can be retained,
/// while [containsDocumentPoint] offers the binary clipping decision needed by
/// draw, erase, and fill call sites.
final class SelectionMask {
  /// Creates a validated immutable mask.
  factory SelectionMask({
    required int left,
    required int top,
    required int width,
    required int height,
    required Iterable<int> coverage,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value((width, height), 'size', 'must be positive');
    }
    final Uint8List bytes = Uint8List.fromList(coverage.toList());
    if (bytes.length != width * height) {
      throw ArgumentError.value(
        bytes.length,
        'coverage',
        'must contain width * height bytes',
      );
    }
    return SelectionMask._(
      left: left,
      top: top,
      width: width,
      height: height,
      coverage: bytes,
    );
  }

  SelectionMask._({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this._coverage,
  });

  /// Creates a hard-edged mask from an integer document rectangle.
  factory SelectionMask.filledRect(Rect rect) {
    _requireFiniteRect(rect, 'rect');
    if (rect.isEmpty) {
      throw ArgumentError.value(rect, 'rect', 'must not be empty');
    }
    final int left = rect.left.floor();
    final int top = rect.top.floor();
    final int right = rect.right.ceil();
    final int bottom = rect.bottom.ceil();
    return SelectionMask(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
      coverage: List<int>.filled((right - left) * (bottom - top), 255),
    );
  }

  /// Left edge in integer document pixels.
  final int left;

  /// Top edge in integer document pixels.
  final int top;

  /// Mask width in document pixels.
  final int width;

  /// Mask height in document pixels.
  final int height;

  final Uint8List _coverage;

  /// Half-open document-space bounds.
  Rect get bounds => Rect.fromLTWH(
    left.toDouble(),
    top.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );

  /// Defensive copy of row-major coverage bytes.
  Uint8List get coverageBytes => Uint8List.fromList(_coverage);

  /// Whether every coverage byte is zero.
  bool get isEmpty => !_coverage.any((int value) => value != 0);

  /// Whether at least one pixel has non-zero selection coverage.
  bool get isNotEmpty => !isEmpty;

  /// Expands this offset mask into a canvas-aligned coverage buffer.
  ///
  /// Pixels outside the canvas are clipped. The result is row-major and has
  /// exactly `canvasWidth * canvasHeight` bytes, providing an explicit seam to
  /// the engine's canvas-aligned mask representation.
  Uint8List toCanvasCoverage(int canvasWidth, int canvasHeight) {
    if (canvasWidth <= 0 || canvasHeight <= 0) {
      throw ArgumentError.value(
        (canvasWidth, canvasHeight),
        'canvasSize',
        'must be positive',
      );
    }
    final Uint8List result = Uint8List(canvasWidth * canvasHeight);
    final int firstX = math.max(0, left);
    final int firstY = math.max(0, top);
    final int lastX = math.min(canvasWidth, left + width);
    final int lastY = math.min(canvasHeight, top + height);
    for (var y = firstY; y < lastY; y += 1) {
      for (var x = firstX; x < lastX; x += 1) {
        result[y * canvasWidth + x] = coverageAt(x, y);
      }
    }
    return result;
  }

  /// Coverage at an integer document pixel, or zero outside this mask.
  int coverageAt(int x, int y) {
    final int localX = x - left;
    final int localY = y - top;
    if (localX < 0 || localY < 0 || localX >= width || localY >= height) {
      return 0;
    }
    return _coverage[localY * width + localX];
  }

  /// Whether the pixel containing [point] has non-zero coverage.
  bool containsDocumentPoint(Offset point) {
    _requireFiniteOffset(point, 'point');
    return coverageAt(point.dx.floor(), point.dy.floor()) != 0;
  }

  /// Combines this mask with [other] in document coordinates.
  SelectionMask combine(SelectionMask other, SelectionCombineMode operation) {
    if (operation == SelectionCombineMode.replace) {
      return other;
    }
    final int resultLeft = math.min(left, other.left);
    final int resultTop = math.min(top, other.top);
    final int resultRight = math.max(left + width, other.left + other.width);
    final int resultBottom = math.max(top + height, other.top + other.height);
    final int resultWidth = resultRight - resultLeft;
    final int resultHeight = resultBottom - resultTop;
    final Uint8List result = Uint8List(resultWidth * resultHeight);
    for (var y = resultTop; y < resultBottom; y += 1) {
      for (var x = resultLeft; x < resultRight; x += 1) {
        final int oldCoverage = coverageAt(x, y);
        final int newCoverage = other.coverageAt(x, y);
        final int value = switch (operation) {
          SelectionCombineMode.add => math.max(oldCoverage, newCoverage),
          SelectionCombineMode.subtract =>
            (oldCoverage * (255 - newCoverage) / 255).round(),
          SelectionCombineMode.replace => newCoverage,
        };
        result[(y - resultTop) * resultWidth + x - resultLeft] = value;
      }
    }
    return SelectionMask._(
      left: resultLeft,
      top: resultTop,
      width: resultWidth,
      height: resultHeight,
      coverage: result,
    );
  }
}

/// Immutable options shared by selection gesture requests.
final class SelectionOptions {
  /// Creates validated selection options.
  factory SelectionOptions({
    SelectionMode mode = SelectionMode.rectangle,
    SelectionCombineMode combine = SelectionCombineMode.replace,
    int wandTolerance = 16,
    int wandGapClose = 0,
  }) {
    if (wandTolerance < 0 || wandTolerance > 64) {
      throw RangeError.range(wandTolerance, 0, 64, 'wandTolerance');
    }
    if (wandGapClose < 0 || wandGapClose > 4) {
      throw RangeError.range(wandGapClose, 0, 4, 'wandGapClose');
    }
    return SelectionOptions._(
      mode: mode,
      combine: combine,
      wandTolerance: wandTolerance,
      wandGapClose: wandGapClose,
    );
  }

  const SelectionOptions._({
    required this.mode,
    required this.combine,
    required this.wandTolerance,
    required this.wandGapClose,
  });

  /// Geometry produced by the next selection gesture.
  final SelectionMode mode;

  /// Operation applied to the existing static mask.
  final SelectionCombineMode combine;

  /// Wand color tolerance in the binding 0–64 range.
  final int wandTolerance;

  /// Wand boundary gap closing radius in the binding 0–4 range.
  final int wandGapClose;

  /// Returns a copy with selected fields replaced.
  SelectionOptions copyWith({
    SelectionMode? mode,
    SelectionCombineMode? combine,
    int? wandTolerance,
    int? wandGapClose,
  }) {
    final int nextTolerance = wandTolerance ?? this.wandTolerance;
    final int nextGapClose = wandGapClose ?? this.wandGapClose;
    if (nextTolerance < 0 || nextTolerance > 64) {
      throw RangeError.range(nextTolerance, 0, 64, 'wandTolerance');
    }
    if (nextGapClose < 0 || nextGapClose > 4) {
      throw RangeError.range(nextGapClose, 0, 4, 'wandGapClose');
    }
    return SelectionOptions(
      mode: mode ?? this.mode,
      combine: combine ?? this.combine,
      wandTolerance: nextTolerance,
      wandGapClose: nextGapClose,
    );
  }
}

/// Closed worker-request union for selection geometry.
sealed class SelectionRequest implements ToolCommand {
  const SelectionRequest({required this.combine});

  /// Operation to apply when the request's mask is returned.
  final SelectionCombineMode combine;
}

/// Rectangular selection request.
final class RectangleSelectionRequest extends SelectionRequest {
  /// Creates a finite, non-empty rectangle request.
  RectangleSelectionRequest({required this.rect, required super.combine}) {
    _requireFiniteRect(rect, 'rect');
    if (rect.isEmpty) {
      throw ArgumentError.value(rect, 'rect', 'must not be empty');
    }
  }

  /// Document-space rectangle.
  final Rect rect;
}

/// Closed freehand polygon selection request.
final class LassoSelectionRequest extends SelectionRequest {
  /// Creates a lasso containing at least three finite vertices.
  factory LassoSelectionRequest({
    required Iterable<Offset> points,
    required SelectionCombineMode combine,
  }) {
    final List<Offset> frozen = List<Offset>.unmodifiable(points);
    if (frozen.length < 3) {
      throw ArgumentError.value(points, 'points', 'must contain 3 or more');
    }
    for (final Offset point in frozen) {
      _requireFiniteOffset(point, 'point');
    }
    return LassoSelectionRequest._(points: frozen, combine: combine);
  }

  const LassoSelectionRequest._({required this.points, required super.combine});

  /// Document-space polygon vertices; closure is implicit.
  final List<Offset> points;
}

/// Contiguous-color wand selection request.
final class WandSelectionRequest extends SelectionRequest {
  /// Creates a validated wand worker request.
  WandSelectionRequest({
    required this.seed,
    required this.layerId,
    required this.tolerance,
    required this.gapClose,
    required super.combine,
  }) {
    _requireFiniteOffset(seed, 'seed');
    _requireId(layerId, 'layerId');
    if (tolerance < 0 || tolerance > 64) {
      throw RangeError.range(tolerance, 0, 64, 'tolerance');
    }
    if (gapClose < 0 || gapClose > 4) {
      throw RangeError.range(gapClose, 0, 4, 'gapClose');
    }
  }

  /// Document-space seed point.
  final Offset seed;

  /// Active content layer sampled by the wand.
  final String layerId;

  /// Color tolerance in the binding 0–64 range.
  final int tolerance;

  /// Bounded boundary-close radius in document pixels.
  final int gapClose;
}

/// Metadata retained with the session clipboard fragment.
final class FragmentSourceMetadata {
  /// Creates fragment source metadata.
  FragmentSourceMetadata({
    required this.documentId,
    required this.layerId,
    required this.sourceBounds,
  }) {
    _requireId(documentId, 'documentId');
    _requireId(layerId, 'layerId');
    _requireFiniteRect(sourceBounds, 'sourceBounds');
    if (sourceBounds.isEmpty) {
      throw ArgumentError.value(
        sourceBounds,
        'sourceBounds',
        'must not be empty',
      );
    }
  }

  /// Artwork from which the fragment was copied.
  final String documentId;

  /// Content layer from which the fragment was copied.
  final String layerId;

  /// Original document-space bounds.
  final Rect sourceBounds;
}

/// Immutable, tightly packed RGBA clipboard fragment.
final class RgbaFragment {
  /// Creates a validated RGBA fragment and defensively copies [rgba].
  factory RgbaFragment({
    required int width,
    required int height,
    required Iterable<int> rgba,
    required FragmentSourceMetadata source,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value((width, height), 'size', 'must be positive');
    }
    final Uint8List bytes = Uint8List.fromList(rgba.toList());
    if (bytes.length != width * height * 4) {
      throw ArgumentError.value(
        bytes.length,
        'rgba',
        'must contain width * height * 4 bytes',
      );
    }
    return RgbaFragment._(
      width: width,
      height: height,
      rgba: bytes,
      source: source,
    );
  }

  RgbaFragment._({
    required this.width,
    required this.height,
    required this._rgba,
    required this.source,
  });

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// Session clipboard source metadata.
  final FragmentSourceMetadata source;

  final Uint8List _rgba;

  /// Defensive copy of tightly packed row-major RGBA bytes.
  Uint8List get rgbaBytes => Uint8List.fromList(_rgba);

  /// Fragment size in document pixels at unit scale.
  Size get size => Size(width.toDouble(), height.toDouble());

  /// Returns an alpha-derived selection mask placed at integer [topLeft].
  SelectionMask alphaMaskAt(Offset topLeft) {
    _requireFiniteOffset(topLeft, 'topLeft');
    final Uint8List alpha = Uint8List(width * height);
    for (var index = 0; index < alpha.length; index += 1) {
      alpha[index] = _rgba[index * 4 + 3];
    }
    return SelectionMask(
      left: topLeft.dx.floor(),
      top: topLeft.dy.floor(),
      width: width,
      height: height,
      coverage: alpha,
    );
  }
}

/// One session-lifetime, in-memory clipboard slot.
final class SelectionClipboard {
  RgbaFragment? _fragment;

  /// Whether paste is currently available.
  bool get canPaste => _fragment != null;

  /// Current immutable fragment, if any.
  RgbaFragment? get fragment => _fragment;

  /// Replaces the one clipboard slot.
  void write(RgbaFragment fragment) {
    _fragment = fragment;
  }

  /// Clears the clipboard without affecting a canvas selection.
  void clear() {
    _fragment = null;
  }
}

/// Immutable placement of a floated RGBA fragment.
final class SelectionFloat {
  /// Creates a validated float placement.
  SelectionFloat({
    required this.fragment,
    required this.destinationLayerId,
    required this.topLeft,
    this.scaleX = 1,
    this.scaleY = 1,
    this.rotationRadians = 0,
  }) {
    _requireId(destinationLayerId, 'destinationLayerId');
    _requireFiniteOffset(topLeft, 'topLeft');
    if (!scaleX.isFinite || scaleX == 0) {
      throw ArgumentError.value(scaleX, 'scaleX', 'must be finite and nonzero');
    }
    if (!scaleY.isFinite || scaleY == 0) {
      throw ArgumentError.value(scaleY, 'scaleY', 'must be finite and nonzero');
    }
    if (!rotationRadians.isFinite) {
      throw ArgumentError.value(
        rotationRadians,
        'rotationRadians',
        'must be finite',
      );
    }
  }

  /// Floated pixels.
  final RgbaFragment fragment;

  /// Active layer receiving the eventual commit.
  final String destinationLayerId;

  /// Unrotated destination top-left in document space.
  final Offset topLeft;

  /// Horizontal scale, negative after a horizontal flip.
  final double scaleX;

  /// Vertical scale, negative after a vertical flip.
  final double scaleY;

  /// Clockwise document-space rotation.
  final double rotationRadians;

  /// Returns a placement with selected transform values replaced.
  SelectionFloat copyWith({
    Offset? topLeft,
    double? scaleX,
    double? scaleY,
    double? rotationRadians,
  }) => SelectionFloat(
    fragment: fragment,
    destinationLayerId: destinationLayerId,
    topLeft: topLeft ?? this.topLeft,
    scaleX: scaleX ?? this.scaleX,
    scaleY: scaleY ?? this.scaleY,
    rotationRadians: rotationRadians ?? this.rotationRadians,
  );
}

/// Float commit emitted by a canvas tap or explicit transform completion.
final class FloatCommitCommand implements JournaledToolCommand {
  /// Creates a float commit.
  const FloatCommitCommand(this.floatingSelection);

  /// Final fragment placement.
  final SelectionFloat floatingSelection;

  @override
  JournalKind get journalKind => JournalKind.floatCommit;
}

/// Selection-region clear emitted by cut or clear.
final class SelectionClearCommand implements JournaledToolCommand {
  /// Creates a layer-local masked clear.
  const SelectionClearCommand({required this.layerId, required this.mask});

  /// Content layer to clear.
  final String layerId;

  /// Static selection mask constraining the clear.
  final SelectionMask mask;

  @override
  JournalKind get journalKind => JournalKind.erase;
}

/// Non-journaled live float edit selected from the contextual dock.
enum SelectionFloatEdit {
  /// Creates a second floated copy of selected pixels.
  duplicate,

  /// Mirrors the float around its vertical center axis.
  flipHorizontal,

  /// Mirrors the float around its horizontal center axis.
  flipVertical,
}

/// Typed preview command for duplicate and mirror actions.
final class SelectionFloatEditCommand implements ToolCommand {
  /// Creates a live float edit command.
  const SelectionFloatEditCommand({
    required this.edit,
    required this.floatingSelection,
  });

  /// Dock action applied to the float.
  final SelectionFloatEdit edit;

  /// Resulting placement.
  final SelectionFloat floatingSelection;
}

/// Compound masked copy into a newly created content layer.
final class SelectionToNewLayerCommand implements JournaledToolCommand {
  /// Creates a validated new-layer command.
  SelectionToNewLayerCommand({
    required this.sourceLayerId,
    required this.newLayerId,
    required this.mask,
  }) {
    _requireId(sourceLayerId, 'sourceLayerId');
    _requireId(newLayerId, 'newLayerId');
    if (sourceLayerId == newLayerId) {
      throw ArgumentError.value(
        newLayerId,
        'newLayerId',
        'must differ from sourceLayerId',
      );
    }
  }

  /// Layer sampled through [mask].
  final String sourceLayerId;

  /// New content layer receiving the copied pixels.
  final String newLayerId;

  /// Static selection copied into the new layer.
  final SelectionMask mask;

  @override
  JournalKind get journalKind => JournalKind.layerAdd;
}

/// Owns selection lifecycle, the static clip mask, float history, and paste.
final class SelectionToolController extends ToolController<SelectionToolKind> {
  /// Creates a selection controller with a session clipboard.
  SelectionToolController({
    SelectionClipboard? clipboard,
    SelectionOptions? options,
  }) : clipboard = clipboard ?? SelectionClipboard(),
       // The public parameter intentionally omits the private field prefix.
       // ignore: prefer_initializing_formals
       _options = options ?? SelectionOptions(),
       super(const SelectionToolKind());

  /// One in-memory RGBA clipboard slot shared for the app session.
  final SelectionClipboard clipboard;

  SelectionOptions _options;
  SelectionMask? _mask;
  SelectionFloat? _floatingSelection;
  SelectionRequest? _pendingRequest;
  final List<SelectionFloat> _floatHistory = <SelectionFloat>[];

  /// Current mode and wand options.
  SelectionOptions get options => _options;

  /// Persistent clipping mask, retained across tool and layer switches.
  SelectionMask? get mask => _mask;

  /// Live floated pixels, if the selection is being moved or pasted.
  SelectionFloat? get floatingSelection => _floatingSelection;

  /// Request awaiting a worker-produced mask.
  SelectionRequest? get pendingRequest => _pendingRequest;

  /// Whether draw, erase, and fill should clip through [mask].
  bool get hasSelection => _mask != null;

  @override
  bool get hasLiveState =>
      _mask != null || _floatingSelection != null || _pendingRequest != null;

  /// Replaces the next-gesture options.
  void setOptions(SelectionOptions options) {
    _options = options;
  }

  /// Starts a rectangular selection request.
  RectangleSelectionRequest requestRectangle(Rect rect) {
    final RectangleSelectionRequest request = RectangleSelectionRequest(
      rect: rect,
      combine: _options.combine,
    );
    _pendingRequest = request;
    return request;
  }

  /// Starts a lasso selection request.
  LassoSelectionRequest requestLasso(Iterable<Offset> points) {
    final LassoSelectionRequest request = LassoSelectionRequest(
      points: points,
      combine: _options.combine,
    );
    _pendingRequest = request;
    return request;
  }

  /// Starts a contiguous-color wand selection request.
  WandSelectionRequest requestWand(Offset seed, {required String layerId}) {
    final WandSelectionRequest request = WandSelectionRequest(
      seed: seed,
      layerId: layerId,
      tolerance: _options.wandTolerance,
      gapClose: _options.wandGapClose,
      combine: _options.combine,
    );
    _pendingRequest = request;
    return request;
  }

  /// Publishes a request result as the new static selection mask.
  void completeRequest(SelectionRequest request, SelectionMask result) {
    if (!identical(request, _pendingRequest)) {
      throw StateError('Selection result does not match the pending request.');
    }
    _pendingRequest = null;
    applyMask(result, operation: request.combine);
  }

  /// Applies a mask directly, useful for synchronous rect/lasso rasterizers.
  void applyMask(
    SelectionMask result, {
    SelectionCombineMode operation = SelectionCombineMode.replace,
  }) {
    final SelectionMask? oldMask = _mask;
    final SelectionMask next =
        oldMask == null || operation == SelectionCombineMode.replace
        ? result
        : oldMask.combine(result, operation);
    _mask = next.isEmpty ? null : next;
  }

  /// Copies an already extracted selection fragment into the session slot.
  void copy(RgbaFragment fragment) {
    if (_mask == null) {
      throw StateError('Cannot copy without an active selection.');
    }
    clipboard.write(fragment);
  }

  /// Copies [fragment] then emits the masked clear half of a cut.
  SelectionClearCommand cut(RgbaFragment fragment, {required String layerId}) {
    copy(fragment);
    final SelectionMask? currentMask = _mask;
    if (currentMask == null) {
      throw StateError('Cannot cut without an active selection.');
    }
    return SelectionClearCommand(layerId: layerId, mask: currentMask);
  }

  /// Emits a masked clear while keeping the selection active.
  SelectionClearCommand clear({required String layerId}) {
    final SelectionMask? currentMask = _mask;
    if (currentMask == null) {
      throw StateError('Cannot clear without an active selection.');
    }
    return SelectionClearCommand(layerId: layerId, mask: currentMask);
  }

  /// Floats clipboard pixels centered at the current document viewport.
  SelectionFloat? pasteAtViewportCenter({
    required Offset viewportCenter,
    required String activeLayerId,
  }) {
    _requireFiniteOffset(viewportCenter, 'viewportCenter');
    final RgbaFragment? fragment = clipboard.fragment;
    if (fragment == null) {
      return null;
    }
    final Offset topLeft =
        viewportCenter - Offset(fragment.width / 2, fragment.height / 2);
    final SelectionFloat floated = SelectionFloat(
      fragment: fragment,
      destinationLayerId: activeLayerId,
      topLeft: topLeft,
    );
    _floatingSelection = floated;
    _floatHistory.clear();
    _mask = fragment.alphaMaskAt(topLeft);
    return floated;
  }

  /// Starts moving an extracted selection fragment.
  void beginFloat(SelectionFloat floatingSelection) {
    _floatingSelection = floatingSelection;
    _floatHistory.clear();
  }

  /// Duplicates extracted selected pixels into a live offset float.
  SelectionFloatEditCommand duplicate(
    RgbaFragment fragment, {
    required String activeLayerId,
    Offset offset = const Offset(16, 16),
  }) {
    _requireFiniteOffset(offset, 'offset');
    if (_mask == null) {
      throw StateError('Cannot duplicate without an active selection.');
    }
    final SelectionFloat floated = SelectionFloat(
      fragment: fragment,
      destinationLayerId: activeLayerId,
      topLeft: fragment.source.sourceBounds.topLeft + offset,
    );
    beginFloat(floated);
    return SelectionFloatEditCommand(
      edit: SelectionFloatEdit.duplicate,
      floatingSelection: floated,
    );
  }

  /// Mirrors the current float horizontally around its center.
  SelectionFloatEditCommand flipFloatHorizontal() {
    final SelectionFloat current = _requireFloat();
    final SelectionFloat next = current.copyWith(scaleX: -current.scaleX);
    updateFloat(next);
    return SelectionFloatEditCommand(
      edit: SelectionFloatEdit.flipHorizontal,
      floatingSelection: next,
    );
  }

  /// Mirrors the current float vertically around its center.
  SelectionFloatEditCommand flipFloatVertical() {
    final SelectionFloat current = _requireFloat();
    final SelectionFloat next = current.copyWith(scaleY: -current.scaleY);
    updateFloat(next);
    return SelectionFloatEditCommand(
      edit: SelectionFloatEdit.flipVertical,
      floatingSelection: next,
    );
  }

  /// Emits the compound selection-to-new-layer journal action.
  SelectionToNewLayerCommand toNewLayer({
    required String sourceLayerId,
    required String newLayerId,
  }) {
    final SelectionMask? currentMask = _mask;
    if (currentMask == null) {
      throw StateError('Cannot copy to a new layer without a selection.');
    }
    return SelectionToNewLayerCommand(
      sourceLayerId: sourceLayerId,
      newLayerId: newLayerId,
      mask: currentMask,
    );
  }

  /// Replaces the live placement and records a synchronous undo step.
  void updateFloat(SelectionFloat next) {
    final SelectionFloat? current = _floatingSelection;
    if (current == null) {
      throw StateError('No selection float is active.');
    }
    if (next.fragment != current.fragment ||
        next.destinationLayerId != current.destinationLayerId) {
      throw ArgumentError.value(
        next,
        'next',
        'must retain fragment and destination layer',
      );
    }
    _floatHistory.add(current);
    _floatingSelection = next;
  }

  /// Reverts one float move while retaining the live float.
  bool undoFloatMove() {
    if (_floatHistory.isEmpty || _floatingSelection == null) {
      return false;
    }
    _floatingSelection = _floatHistory.removeLast();
    return true;
  }

  SelectionFloat _requireFloat() {
    final SelectionFloat? current = _floatingSelection;
    if (current == null) {
      throw StateError('No selection float is active.');
    }
    return current;
  }

  /// Handles the lifecycle's single-finger canvas tap.
  ///
  /// A live float commits; without a float the tap intentionally does nothing.
  FloatCommitCommand? handleCanvasTap() {
    final SelectionFloat? floated = _floatingSelection;
    if (floated == null) {
      return null;
    }
    _floatingSelection = null;
    _floatHistory.clear();
    return FloatCommitCommand(floated);
  }

  /// Explicit lifecycle hook: switching tools preserves the mask and float.
  void handleToolSwitch() {}

  /// Explicit lifecycle hook: changing active content layer preserves mask.
  void handleLayerSwitch(String layerId) {
    _requireId(layerId, 'layerId');
  }

  /// Explicit lifecycle hook: opening a panel preserves selection state.
  void handlePanelOpen() {}

  /// Clears the static mask and any uncommitted float.
  void deselect() {
    _mask = null;
    _floatingSelection = null;
    _pendingRequest = null;
    _floatHistory.clear();
  }

  @override
  void cancel() {
    deselect();
  }
}

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

void _requireId(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}
