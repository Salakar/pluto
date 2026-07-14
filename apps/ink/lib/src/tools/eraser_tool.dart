import 'dart:math' as math;

import '../document/undo_journal.dart';
import '../engine/stroke_pipeline.dart';
import '../engine/symmetry.dart';
import 'tool.dart';

/// Duration for which whole-stroke kills are collected into one undo action.
const Duration strokeEraseBatchWindow = Duration(milliseconds: 120);

/// Fixed on-screen diameter of the whole-stroke eraser contact cursor.
const double strokeEraserCursorLogicalDiameter = 14;

/// The three eraser interaction modes exposed by the eraser option sheet.
enum EraserMode {
  /// Raster destination-out stamping through the existing `eraserpixel` brush.
  pixel,

  /// Contact removes complete, still-replayable strokes.
  stroke,

  /// A closed freehand region is cleared from the active layer.
  lasso,
}

/// Decodes the persisted WP7 eraser default, falling back to pixel erase.
EraserMode eraserModeFromPreset(Object? value) => switch (value) {
  'stroke' => EraserMode.stroke,
  'lasso' => EraserMode.lasso,
  _ => EraserMode.pixel,
};

/// Remembers eraser selection independently of the currently selected tool.
///
/// This is deliberately unaware of platform pen types. Input routing only has
/// to report whether the current contact is from the flipped pen end. That
/// keeps the last-mode rule usable with both `pluto_pen` metadata and
/// Flutter's inverted-stylus fallback.
final class EraserModeState {
  /// Creates state with the pixel eraser selected by default.
  EraserModeState({EraserMode initialMode = EraserMode.pixel})
    : _lastSelectedMode = initialMode;

  EraserMode _lastSelectedMode;

  /// The mode most recently chosen in the eraser option sheet.
  EraserMode get lastSelectedMode => _lastSelectedMode;

  /// Records a user-selected eraser mode.
  void selectMode(EraserMode mode) {
    _lastSelectedMode = mode;
  }

  /// Resolves the eraser mode for one input contact.
  ///
  /// A flipped pen always activates the last eraser mode, even while another
  /// bench tool is selected. A normal pen activates it only when the eraser
  /// bench tool is selected. `null` means the contact belongs to another tool.
  EraserMode? modeForInput({
    required bool eraserToolSelected,
    required bool penFlipped,
  }) {
    if (penFlipped || eraserToolSelected) {
      return _lastSelectedMode;
    }
    return null;
  }
}

/// One whole-stroke kill produced by the stroke-eraser hit tester.
final class StrokeKill {
  /// Creates a validated kill in document-journal sequence space.
  StrokeKill({
    required this.layerId,
    required this.strokeSequence,
    required this.timestamp,
  }) {
    _requireLayerId(layerId);
    if (strokeSequence <= 0) {
      throw ArgumentError.value(
        strokeSequence,
        'strokeSequence',
        'must be positive',
      );
    }
    _requireTimestamp(timestamp, 'timestamp');
  }

  /// Active layer containing the replayable stroke.
  final String layerId;

  /// Sequence of the target journal stroke.
  final int strokeSequence;

  /// Monotonic input time at which contact selected the stroke.
  final Duration timestamp;
}

/// Immutable worker command for one batched stroke-erase undo action.
///
/// The document journal currently replays individual recipe sequences. This
/// command intentionally carries a canonical sequence set instead of owning
/// replay state, so the worker can omit all targets in one reconstruction and
/// publish one undo entry.
final class StrokeEraseBatchRequest implements JournaledToolCommand {
  factory StrokeEraseBatchRequest({
    required String layerId,
    required Iterable<int> targetSequences,
    required Duration startedAt,
    required Duration endedAt,
  }) {
    _requireLayerId(layerId);
    _requireTimestamp(startedAt, 'startedAt');
    _requireTimestamp(endedAt, 'endedAt');
    if (endedAt < startedAt) {
      throw ArgumentError.value(
        endedAt,
        'endedAt',
        'must not precede startedAt',
      );
    }
    final List<int> targets = targetSequences.toSet().toList()..sort();
    if (targets.isEmpty) {
      throw ArgumentError.value(
        targetSequences,
        'targetSequences',
        'must contain at least one sequence',
      );
    }
    if (targets.any((int sequence) => sequence <= 0)) {
      throw ArgumentError.value(
        targetSequences,
        'targetSequences',
        'must contain only positive sequences',
      );
    }
    return StrokeEraseBatchRequest._(
      layerId: layerId,
      targetSequences: List<int>.unmodifiable(targets),
      startedAt: startedAt,
      endedAt: endedAt,
    );
  }

  const StrokeEraseBatchRequest._({
    required this.layerId,
    required this.targetSequences,
    required this.startedAt,
    required this.endedAt,
  });

  /// Layer whose live recipe tail should be reconstructed.
  final String layerId;

  /// Sorted, duplicate-free journal sequences to omit during reconstruction.
  final List<int> targetSequences;

  /// Time of the first kill in this undo group.
  final Duration startedAt;

  /// Time of the last observed kill in this undo group.
  final Duration endedAt;

  @override
  JournalKind get journalKind => JournalKind.erase;
}

/// Receives one canonical whole-stroke erase command.
typedef StrokeEraseBatchSink = void Function(StrokeEraseBatchRequest request);

/// Timer-free accumulator for deterministic 120 ms stroke-kill batching.
///
/// A batch occupies the half-open interval beginning at its first kill. A kill
/// exactly [batchWindow] after that first kill begins the next batch. The UI or
/// worker advances idle time explicitly through [flushThrough], so this class
/// needs neither a real timer nor fake async in tests.
final class StrokeKillBatcher {
  /// Creates a batcher that synchronously publishes completed commands.
  StrokeKillBatcher({
    required this.onBatch,
    this.batchWindow = strokeEraseBatchWindow,
  }) {
    if (batchWindow <= Duration.zero) {
      throw ArgumentError.value(batchWindow, 'batchWindow', 'must be positive');
    }
  }

  /// Callback invoked once for each completed undo group.
  final StrokeEraseBatchSink onBatch;

  /// Fixed duration measured from the first kill in a batch.
  final Duration batchWindow;

  String? _layerId;
  Duration? _startedAt;
  Duration? _endedAt;
  Duration? _lastObservedAt;
  final Set<int> _targetSequences = <int>{};

  /// Whether at least one kill is waiting to be published.
  bool get hasPendingBatch => _startedAt != null;

  /// Number of distinct target sequences in the pending command.
  int get pendingTargetCount => _targetSequences.length;

  /// Adds one hit-tested stroke kill.
  ///
  /// Switching layers closes the current command because journal recipe replay
  /// and undo grouping are layer-local.
  void addKill(StrokeKill kill) {
    _advanceTimeline(kill.timestamp, 'kill.timestamp');
    final Duration? startedAt = _startedAt;
    if (startedAt != null &&
        (_layerId != kill.layerId ||
            kill.timestamp - startedAt >= batchWindow)) {
      _emitPending();
    }
    _layerId ??= kill.layerId;
    _startedAt ??= kill.timestamp;
    _endedAt = kill.timestamp;
    _targetSequences.add(kill.strokeSequence);
  }

  /// Publishes a pending command once [timestamp] reaches its batch boundary.
  ///
  /// Calls before the boundary only advance the monotonic clock. At the exact
  /// boundary the pending command is published.
  void flushThrough(Duration timestamp) {
    _requireTimestamp(timestamp, 'timestamp');
    _advanceTimeline(timestamp, 'timestamp');
    final Duration? startedAt = _startedAt;
    if (startedAt != null && timestamp - startedAt >= batchWindow) {
      _emitPending();
    }
  }

  /// Immediately publishes the current command, for pointer-up or disposal.
  void flush() {
    _emitPending();
  }

  /// Discards the pending gesture without publishing an undo command.
  void discard() {
    _layerId = null;
    _startedAt = null;
    _endedAt = null;
    _targetSequences.clear();
  }

  void _advanceTimeline(Duration timestamp, String name) {
    final Duration? previous = _lastObservedAt;
    if (previous != null && timestamp < previous) {
      throw ArgumentError.value(
        timestamp,
        name,
        'must not precede the last observed timestamp',
      );
    }
    _lastObservedAt = timestamp;
  }

  void _emitPending() {
    final String? layerId = _layerId;
    final Duration? startedAt = _startedAt;
    final Duration? endedAt = _endedAt;
    if (layerId == null || startedAt == null || endedAt == null) {
      return;
    }
    final StrokeEraseBatchRequest request = StrokeEraseBatchRequest(
      layerId: layerId,
      targetSequences: _targetSequences,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    _layerId = null;
    _startedAt = null;
    _endedAt = null;
    _targetSequences.clear();
    onBatch(request);
  }
}

/// One finite document-space vertex in a lasso-clear polygon.
final class LassoPoint {
  /// Creates a finite point.
  LassoPoint({required this.x, required this.y}) {
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError.value((x, y), 'point', 'must be finite');
    }
  }

  /// Horizontal document coordinate.
  final double x;

  /// Vertical document coordinate.
  final double y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LassoPoint && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Axis-aligned bounds of a lasso clear request.
final class LassoBounds {
  const LassoBounds._({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Smallest x coordinate in the lasso.
  final double left;

  /// Smallest y coordinate in the lasso.
  final double top;

  /// Largest x coordinate in the lasso.
  final double right;

  /// Largest y coordinate in the lasso.
  final double bottom;

  /// Bounding width in document pixels.
  double get width => right - left;

  /// Bounding height in document pixels.
  double get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LassoBounds &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Immutable region-clear command for the lasso eraser.
///
/// The polygon is stored open (the first point is not repeated at the end),
/// while [closedVertices] is supplied for rasterizers that consume explicit
/// closing geometry. Self-intersection is allowed for an even-odd fill rule.
final class LassoClearRequest implements JournaledToolCommand {
  factory LassoClearRequest({
    required String layerId,
    required Iterable<LassoPoint> vertices,
    required Duration requestedAt,
  }) {
    _requireLayerId(layerId);
    _requireTimestamp(requestedAt, 'requestedAt');
    final List<LassoPoint> normalized = List<LassoPoint>.of(vertices);
    if (normalized.length > 1 && normalized.first == normalized.last) {
      normalized.removeLast();
    }
    if (normalized.toSet().length < 3) {
      throw ArgumentError.value(
        vertices,
        'vertices',
        'must contain at least three distinct points',
      );
    }
    if (!_hasTwoDimensionalArea(normalized)) {
      throw ArgumentError.value(
        vertices,
        'vertices',
        'must enclose a two-dimensional region',
      );
    }
    var left = normalized.first.x;
    var top = normalized.first.y;
    var right = left;
    var bottom = top;
    for (final LassoPoint point in normalized.skip(1)) {
      if (point.x < left) {
        left = point.x;
      }
      if (point.y < top) {
        top = point.y;
      }
      if (point.x > right) {
        right = point.x;
      }
      if (point.y > bottom) {
        bottom = point.y;
      }
    }
    final List<LassoPoint> frozen = List<LassoPoint>.unmodifiable(normalized);
    return LassoClearRequest._(
      layerId: layerId,
      vertices: frozen,
      closedVertices: List<LassoPoint>.unmodifiable(<LassoPoint>[
        ...frozen,
        frozen.first,
      ]),
      bounds: LassoBounds._(left: left, top: top, right: right, bottom: bottom),
      requestedAt: requestedAt,
    );
  }

  const LassoClearRequest._({
    required this.layerId,
    required this.vertices,
    required this.closedVertices,
    required this.bounds,
    required this.requestedAt,
  });

  /// Active layer to clear inside the polygon.
  final String layerId;

  /// Open, immutable polygon vertices in document space.
  final List<LassoPoint> vertices;

  /// Immutable polygon with its first vertex repeated at the end.
  final List<LassoPoint> closedVertices;

  /// Axis-aligned extent useful for tile selection and journaling.
  final LassoBounds bounds;

  /// Monotonic input time used for deterministic command ordering.
  final Duration requestedAt;

  @override
  JournalKind get journalKind => JournalKind.erase;
}

/// Finds the visually topmost replayable stroke touched by one contact.
///
/// [candidates] must be in journal order. The scan runs backwards so a later
/// committed stroke wins when several paths overlap. The contact and stroke
/// radii are added, matching the forgiving whole-stroke eraser interaction.
JournalEntry? hitTestTopmostReplayableStroke({
  required Iterable<JournalEntry> candidates,
  required LassoPoint contact,
  required double contactRadius,
  required double documentWidth,
  required double documentHeight,
}) {
  if (!contactRadius.isFinite || contactRadius < 0) {
    throw ArgumentError.value(
      contactRadius,
      'contactRadius',
      'must be finite and non-negative',
    );
  }
  if (!documentWidth.isFinite || documentWidth <= 0) {
    throw ArgumentError.value(
      documentWidth,
      'documentWidth',
      'must be finite and positive',
    );
  }
  if (!documentHeight.isFinite || documentHeight <= 0) {
    throw ArgumentError.value(
      documentHeight,
      'documentHeight',
      'must be finite and positive',
    );
  }
  final List<JournalEntry> ordered = candidates.toList(growable: false);
  for (final JournalEntry entry in ordered.reversed) {
    final StrokeRecipe? recipe = entry.recipe;
    if (entry.kind != JournalKind.stroke || recipe == null) {
      continue;
    }
    final List<StrokeSample> samples;
    try {
      samples = StrokeRecipeCodec.decode(recipe.samples);
    } on FormatException {
      continue;
    }
    if (samples.isEmpty) {
      continue;
    }
    final double hitRadius = contactRadius + recipe.size / 2;
    final double maximumDistanceSquared = hitRadius * hitRadius;
    final SymmetryConfiguration symmetry = SymmetryConfiguration(
      mode: _storedSymmetryMode(entry.unknownFields['strokeSymmetry']),
      axisX: documentWidth / 2,
      axisY: documentHeight / 2,
    );
    for (final SymmetryReflection reflection in symmetry.reflections) {
      // Reflections are their own inverse, so reflecting the contact is
      // equivalent to reflecting every recipe segment and is much cheaper.
      final SymmetryPoint sourceContact = reflection.applyToPoint(
        SymmetryPoint(contact.x, contact.y),
      );
      final LassoPoint pathContact = LassoPoint(
        x: sourceContact.x,
        y: sourceContact.y,
      );
      if (_distanceSquared(
            pathContact,
            samples.first.point.dx,
            samples.first.point.dy,
          ) <=
          maximumDistanceSquared) {
        return entry;
      }
      for (var index = 1; index < samples.length; index += 1) {
        final StrokeSample before = samples[index - 1];
        final StrokeSample after = samples[index];
        if (_segmentDistanceSquared(
              pathContact,
              before.point.dx,
              before.point.dy,
              after.point.dx,
              after.point.dy,
            ) <=
            maximumDistanceSquared) {
          return entry;
        }
      }
    }
  }
  return null;
}

SymmetryMode _storedSymmetryMode(Object? value) => switch (value) {
  'vertical' => SymmetryMode.vertical,
  'horizontal' => SymmetryMode.horizontal,
  'quad' => SymmetryMode.quad,
  _ => SymmetryMode.off,
};

/// Receives a lasso region-clear command.
typedef LassoClearSink = void Function(LassoClearRequest request);

/// Thin state and command-routing facade for WP4 eraser interactions.
final class EraserTool {
  /// Creates an eraser facade with injectable worker command seams.
  EraserTool({
    required StrokeEraseBatchSink onStrokeEraseBatch,
    required this.onLassoClear,
    EraserMode initialMode = EraserMode.pixel,
    EraserModeState? modeState,
    Duration strokeBatchWindow = strokeEraseBatchWindow,
  }) : modeState = modeState ?? EraserModeState(initialMode: initialMode),
       strokeKills = StrokeKillBatcher(
         onBatch: onStrokeEraseBatch,
         batchWindow: strokeBatchWindow,
       );

  /// Persistent-within-session last-mode state.
  final EraserModeState modeState;

  /// Deterministic whole-stroke kill accumulator.
  final StrokeKillBatcher strokeKills;

  /// Worker seam that receives validated lasso clear requests.
  final LassoClearSink onLassoClear;

  /// The last mode selected in the eraser option sheet.
  EraserMode get lastSelectedMode => modeState.lastSelectedMode;

  /// Selects an eraser mode for dock and flipped-pen use.
  void selectMode(EraserMode mode) {
    modeState.selectMode(mode);
  }

  /// Resolves normal or flipped-pen input using the stored last mode.
  EraserMode? modeForInput({
    required bool eraserToolSelected,
    required bool penFlipped,
  }) => modeState.modeForInput(
    eraserToolSelected: eraserToolSelected,
    penFlipped: penFlipped,
  );

  /// Sends validated lasso geometry to the worker seam.
  void clearLasso(LassoClearRequest request) {
    onLassoClear(request);
  }
}

void _requireLayerId(String value) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, 'layerId', 'must not be empty');
  }
}

void _requireTimestamp(Duration value, String name) {
  if (value.isNegative) {
    throw ArgumentError.value(value, name, 'must not be negative');
  }
}

bool _hasTwoDimensionalArea(List<LassoPoint> vertices) {
  final LassoPoint origin = vertices.first;
  for (var first = 1; first < vertices.length - 1; first += 1) {
    final double ax = vertices[first].x - origin.x;
    final double ay = vertices[first].y - origin.y;
    for (var second = first + 1; second < vertices.length; second += 1) {
      final double bx = vertices[second].x - origin.x;
      final double by = vertices[second].y - origin.y;
      if (ax * by - ay * bx != 0) {
        return true;
      }
    }
  }
  return false;
}

double _distanceSquared(LassoPoint point, double x, double y) {
  final double deltaX = point.x - x;
  final double deltaY = point.y - y;
  return deltaX * deltaX + deltaY * deltaY;
}

double _segmentDistanceSquared(
  LassoPoint point,
  double startX,
  double startY,
  double endX,
  double endY,
) {
  final double deltaX = endX - startX;
  final double deltaY = endY - startY;
  final double lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared == 0) {
    return _distanceSquared(point, startX, startY);
  }
  final double projection =
      ((point.x - startX) * deltaX + (point.y - startY) * deltaY) /
      lengthSquared;
  final double t = math.max(0, math.min(1, projection));
  return _distanceSquared(point, startX + deltaX * t, startY + deltaY * t);
}
