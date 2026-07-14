import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:pluto_pen/pluto_pen.dart';

import 'pen_router.dart';

/// How long tool-driving touch remains suppressed after the pen leaves range.
const Duration penSuppressionLinger = Duration(milliseconds: 300);

/// Unconditional rejection radius around the stylus at touch birth, in lp.
const double stylusBirthDropRadius = 24;

/// Required stylus clearance for a new navigation gesture, in lp.
const double navigationStylusClearance = 48;

/// A touch use whose admission is decided by [PalmGuard].
enum PalmTouchIntent {
  /// Single-finger drawing or any other touch that drives a tool.
  toolTouch,

  /// A two-, three-, or four-finger command tap.
  multiFingerTap,

  /// The start of a two-finger pan, zoom, and rotate gesture.
  navigationStart,

  /// An already-admitted two-finger navigation gesture.
  navigationContinue,

  /// Non-tool single-finger behavior such as committing a live float.
  passiveSingleFinger,
}

/// Why a touch use was rejected.
enum PalmRejectionReason {
  /// At least one touch was born within 24 lp of the stylus.
  stylusBirthRadius,

  /// Finger drawing is disabled.
  fingerDrawDisabled,

  /// Pen proximity, contact, or the 300 ms leave linger gates tool touch.
  penSuppression,

  /// A new navigation gesture lacks 48 lp clearance from the stylus.
  navigationClearance,

  /// The intent did not receive enough touches.
  insufficientTouches,
}

/// Immutable result of classifying a touch at pointer birth.
final class PalmTouchBirth {
  const PalmTouchBirth({
    required this.pointer,
    required this.position,
    required this.stylusPosition,
    required this.stylusDistance,
  });

  /// Flutter pointer identifier.
  final int pointer;

  /// Birth position in viewport logical pixels.
  final Offset position;

  /// Latest stylus position when this touch was born, when known.
  final Offset? stylusPosition;

  /// Distance from [stylusPosition] at birth, or infinity when unknown.
  final double stylusDistance;

  /// Whether rule 2 unconditionally drops this pointer.
  bool get isDropped => stylusDistance <= stylusBirthDropRadius;
}

/// Admission result for one PalmGuard policy query.
final class PalmGuardDecision {
  const PalmGuardDecision._(this.rejectionReason);

  /// An allowed decision.
  static const PalmGuardDecision allowed = PalmGuardDecision._(null);

  /// Creates a rejected decision with a stable policy reason.
  const PalmGuardDecision.rejected(PalmRejectionReason reason) : this._(reason);

  /// The rejection reason, or null when this decision is allowed.
  final PalmRejectionReason? rejectionReason;

  /// Whether the requested touch use may proceed.
  bool get isAllowed => rejectionReason == null;
}

/// Table-driven pen and palm arbitration implementing UX rules 1 through 5.
///
/// Call [classifyTouchBirth] once for every raw touch down and retain the
/// returned token for the pointer lifetime. This preserves rule-2's
/// birth-time meaning even if the stylus subsequently moves.
final class PalmGuard {
  bool _isPenInProximity = false;
  bool _isPenInContact = false;
  Offset? _stylusPosition;
  Duration? _lastProximityLeave;

  /// Whether the latest pen state reports proximity or contact.
  bool get isPenInProximity => _isPenInProximity || _isPenInContact;

  /// Latest logical stylus position supplied by the pen channel.
  Offset? get stylusPosition => _stylusPosition;

  /// Applies normalized metadata from [PenRouter].
  void updatePenMetadata(PenMetadata metadata) {
    _updatePenState(
      proximity: metadata.isInProximity,
      contact: metadata.isInContact,
      timestamp: metadata.timestamp,
      explicitLeave: metadata.phase == PenMetadataPhase.leftProximity,
    );
    if (metadata.hasChannelSample) {
      _stylusPosition = metadata.logicalPosition;
    }
  }

  /// Reconciles channel state with a [PenState] poll at editor focus.
  ///
  /// [timestamp] must use the same monotonic basis as pointer and pen events.
  /// A state poll has no geometry, so the latest stylus position is retained.
  void synchronizePenState(PenState state, {required Duration timestamp}) {
    _updatePenState(
      proximity: state.isInProximity,
      contact: state.isInContact,
      timestamp: timestamp,
      explicitLeave: false,
    );
  }

  /// Records rule-2 facts for a new touch pointer.
  PalmTouchBirth classifyTouchBirth({
    required int pointer,
    required Offset position,
  }) {
    final Offset? stylus = _stylusPosition;
    return PalmTouchBirth(
      pointer: pointer,
      position: position,
      stylusPosition: stylus,
      stylusDistance: stylus == null
          ? double.infinity
          : (position - stylus).distance,
    );
  }

  /// Decides whether [intent] may use [touches] at [now].
  ///
  /// Rule 2 is universal. The remaining rule-specific gates come from the
  /// constant [_policies] table, keeping the proximity exemptions explicit.
  PalmGuardDecision decide({
    required PalmTouchIntent intent,
    required Iterable<PalmTouchBirth> touches,
    required Duration now,
    bool fingerDrawEnabled = false,
  }) {
    final List<PalmTouchBirth> touchList = touches.toList(growable: false);
    final _PalmPolicy policy = _policies[intent]!;
    if (touchList.any((PalmTouchBirth touch) => touch.isDropped)) {
      return const PalmGuardDecision.rejected(
        PalmRejectionReason.stylusBirthRadius,
      );
    }
    if (touchList.length < policy.minimumTouchCount) {
      return const PalmGuardDecision.rejected(
        PalmRejectionReason.insufficientTouches,
      );
    }
    if (policy.requiresFingerDraw && !fingerDrawEnabled) {
      return const PalmGuardDecision.rejected(
        PalmRejectionReason.fingerDrawDisabled,
      );
    }
    if (policy.gatesOnPenSuppression && isToolTouchSuppressedAt(now)) {
      return const PalmGuardDecision.rejected(
        PalmRejectionReason.penSuppression,
      );
    }
    if (policy.requiresNavigationClearance && isPenInProximity) {
      final bool isTooClose = touchList.any(
        (PalmTouchBirth touch) =>
            touch.stylusPosition == null ||
            touch.stylusDistance <= navigationStylusClearance,
      );
      if (isTooClose) {
        return const PalmGuardDecision.rejected(
          PalmRejectionReason.navigationClearance,
        );
      }
    }
    return PalmGuardDecision.allowed;
  }

  /// Whether rule 1 suppresses tool-driving touch at [now].
  bool isToolTouchSuppressedAt(Duration now) {
    if (isPenInProximity) {
      return true;
    }
    final Duration? leftAt = _lastProximityLeave;
    if (leftAt == null) {
      return false;
    }
    return now - leftAt <= penSuppressionLinger;
  }

  void _updatePenState({
    required bool proximity,
    required bool contact,
    required Duration timestamp,
    required bool explicitLeave,
  }) {
    final bool wasPresent = isPenInProximity;
    _isPenInProximity = proximity;
    _isPenInContact = contact;
    final bool isPresent = isPenInProximity;
    if (explicitLeave || (wasPresent && !isPresent)) {
      _lastProximityLeave = timestamp;
    }
  }
}

final class _PalmPolicy {
  const _PalmPolicy({
    required this.minimumTouchCount,
    this.requiresFingerDraw = false,
    this.gatesOnPenSuppression = false,
    this.requiresNavigationClearance = false,
  });

  final int minimumTouchCount;
  final bool requiresFingerDraw;
  final bool gatesOnPenSuppression;
  final bool requiresNavigationClearance;
}

const Map<PalmTouchIntent, _PalmPolicy> _policies =
    <PalmTouchIntent, _PalmPolicy>{
      PalmTouchIntent.toolTouch: _PalmPolicy(
        minimumTouchCount: 1,
        requiresFingerDraw: true,
        gatesOnPenSuppression: true,
      ),
      PalmTouchIntent.multiFingerTap: _PalmPolicy(minimumTouchCount: 2),
      PalmTouchIntent.navigationStart: _PalmPolicy(
        minimumTouchCount: 2,
        requiresNavigationClearance: true,
      ),
      PalmTouchIntent.navigationContinue: _PalmPolicy(minimumTouchCount: 2),
      PalmTouchIntent.passiveSingleFinger: _PalmPolicy(minimumTouchCount: 1),
    };

/// Maximum duration from the first down to the first release for command taps.
const Duration multiTouchTapMaximumDuration = Duration(milliseconds: 300);

/// Maximum travel of each command-tap pointer, in logical pixels.
const double multiTouchTapMaximumTravel = 32;

/// Count-disambiguation delay after the first release.
const Duration multiTouchTapSettleDuration = Duration(milliseconds: 40);

/// Multi-finger command selected from the pointer count at first release.
enum MultiTouchTapKind {
  /// Two-finger undo.
  undo,

  /// Three-finger redo.
  redo,

  /// Four-finger chrome collapse or restore.
  toggleChrome,
}

/// One classified multi-finger command tap.
final class MultiTouchTap {
  MultiTouchTap({required this.kind, required Iterable<int> pointers})
    : pointers = Set<int>.unmodifiable(pointers);

  /// Command selected by the first-release pointer count.
  final MultiTouchTapKind kind;

  /// Pointer identifiers present at the first release.
  final Set<int> pointers;
}

/// Receives a classified multi-finger command tap.
typedef MultiTouchTapCallback = void Function(MultiTouchTap tap);

/// Cancels a callback scheduled by [DelayedCallbackScheduler].
typedef CancelScheduledCallback = void Function();

/// Schedules a callback and returns a cancellation function.
typedef DelayedCallbackScheduler =
    CancelScheduledCallback Function(Duration delay, void Function() callback);

/// Raw-pointer command-tap classifier that never enters the gesture arena.
///
/// Feed every touch down, move, up, and cancel from a [Listener]. Because this
/// class is not a Flutter gesture recognizer, observing one pointer can never
/// claim that pointer. A command is emitted 40 ms after the first release;
/// its count is the count captured at that first release, so staggered 3-to-2
/// releases produce only redo and never a following undo.
final class MultiTouchTapClassifier {
  MultiTouchTapClassifier({
    required this.onTap,
    DelayedCallbackScheduler? scheduler,
  }) : _scheduler = scheduler ?? _scheduleWithTimer;

  /// Callback invoked for each accepted command tap.
  final MultiTouchTapCallback onTap;

  final DelayedCallbackScheduler _scheduler;
  final Map<int, _TapContact> _contacts = <int, _TapContact>{};

  Duration? _startedAt;
  Set<int>? _pendingPointers;
  MultiTouchTapKind? _pendingKind;
  CancelScheduledCallback? _cancelScheduled;
  bool _isEligible = true;
  bool _hasFirstRelease = false;
  bool _isDisposed = false;

  /// Number of pointers currently down in the observed chord.
  int get pointerCount => _contacts.length;

  /// Whether a first-release classification is waiting for its 40 ms settle.
  bool get isSettling => _cancelScheduled != null;

  /// Adds a raw touch pointer.
  ///
  /// Set [isBirthEligible] to false when PalmGuard rule 2 drops this birth;
  /// that invalidates the entire command chord without hiding its count.
  void pointerDown({
    required int pointer,
    required Offset position,
    required Duration timestamp,
    bool isBirthEligible = true,
  }) {
    _checkNotDisposed();
    if (_contacts.containsKey(pointer)) {
      return;
    }
    if (_contacts.isEmpty && !_hasFirstRelease) {
      _startedAt = timestamp;
      _isEligible = true;
    }
    if (_hasFirstRelease) {
      _isEligible = false;
      _cancelPending();
    }
    final Duration? startedAt = _startedAt;
    if (startedAt != null &&
        timestamp - startedAt > multiTouchTapMaximumDuration) {
      _isEligible = false;
    }
    _isEligible &= isBirthEligible;
    _contacts[pointer] = _TapContact(origin: position, position: position);
    if (_contacts.length > 4) {
      _isEligible = false;
    }
  }

  /// Updates raw touch travel and invalidates motion beyond 32 lp.
  void pointerMove({required int pointer, required Offset position}) {
    _checkNotDisposed();
    final _TapContact? contact = _contacts[pointer];
    if (contact == null) {
      return;
    }
    contact.position = position;
    if ((position - contact.origin).distance > multiTouchTapMaximumTravel) {
      _isEligible = false;
      _cancelPending();
    }
  }

  /// Records a raw touch release and starts settlement on the first release.
  void pointerUp({
    required int pointer,
    required Offset position,
    required Duration timestamp,
  }) {
    _checkNotDisposed();
    if (!_contacts.containsKey(pointer)) {
      return;
    }
    pointerMove(pointer: pointer, position: position);
    if (!_hasFirstRelease) {
      _hasFirstRelease = true;
      final Duration startedAt = _startedAt ?? timestamp;
      final int countAtFirstRelease = _contacts.length;
      if (timestamp - startedAt > multiTouchTapMaximumDuration) {
        _isEligible = false;
      }
      final MultiTouchTapKind? kind = _kindForCount(countAtFirstRelease);
      if (_isEligible && kind != null) {
        _pendingPointers = Set<int>.of(_contacts.keys);
        _pendingKind = kind;
        _cancelScheduled = _scheduler(
          multiTouchTapSettleDuration,
          _finishSettle,
        );
      }
    }
    _contacts.remove(pointer);
    _resetWhenFinished();
  }

  /// Cancels a raw touch pointer and therefore the whole command chord.
  void pointerCancel(int pointer) {
    _checkNotDisposed();
    if (!_contacts.containsKey(pointer)) {
      return;
    }
    _isEligible = false;
    _hasFirstRelease = true;
    _cancelPending();
    _contacts.remove(pointer);
    _resetWhenFinished();
  }

  /// Cancels timers and makes further input invalid.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _cancelPending();
    _contacts.clear();
  }

  void _finishSettle() {
    _cancelScheduled = null;
    final MultiTouchTapKind? kind = _pendingKind;
    final Set<int>? pointers = _pendingPointers;
    _pendingKind = null;
    _pendingPointers = null;
    if (!_isDisposed && _isEligible && kind != null && pointers != null) {
      onTap(MultiTouchTap(kind: kind, pointers: pointers));
    }
    _resetWhenFinished();
  }

  void _cancelPending() {
    _cancelScheduled?.call();
    _cancelScheduled = null;
    _pendingKind = null;
    _pendingPointers = null;
  }

  void _resetWhenFinished() {
    if (_contacts.isNotEmpty || _cancelScheduled != null) {
      return;
    }
    _startedAt = null;
    _pendingKind = null;
    _pendingPointers = null;
    _isEligible = true;
    _hasFirstRelease = false;
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('MultiTouchTapClassifier is disposed.');
    }
  }
}

final class _TapContact {
  _TapContact({required this.origin, required this.position});

  final Offset origin;
  Offset position;
}

MultiTouchTapKind? _kindForCount(int count) {
  return switch (count) {
    2 => MultiTouchTapKind.undo,
    3 => MultiTouchTapKind.redo,
    4 => MultiTouchTapKind.toggleChrome,
    _ => null,
  };
}

CancelScheduledCallback _scheduleWithTimer(
  Duration delay,
  void Function() callback,
) {
  final Timer timer = Timer(delay, callback);
  return timer.cancel;
}

/// Phase of a raw two-pointer navigation gesture.
enum TwoPointerNavigationPhase {
  /// Two eligible pointers established a gesture.
  start,

  /// One of the two pointers moved.
  update,

  /// The first pointer released; no inertia follows.
  end,

  /// The gesture was cancelled or transform-locked.
  cancel,
}

/// Recency window used to carry twist velocity through pointer-up.
const Duration twistVelocitySampleHorizon = Duration(milliseconds: 100);

/// One pan, zoom, and rotate snapshot from [TwoPointerNavigationTracker].
final class TwoPointerNavigationUpdate {
  TwoPointerNavigationUpdate({
    required this.phase,
    required Iterable<int> pointers,
    required this.focalPoint,
    required this.focalDelta,
    required this.scale,
    required this.rotation,
    required this.twistVelocity,
  }) : pointers = List<int>.unmodifiable(pointers);

  /// Gesture lifecycle phase.
  final TwoPointerNavigationPhase phase;

  /// The two pointer identifiers selected at start.
  final List<int> pointers;

  /// Current midpoint in viewport logical pixels.
  final Offset focalPoint;

  /// Midpoint movement since the previous update.
  final Offset focalDelta;

  /// Cumulative uniform scale relative to gesture start.
  final double scale;

  /// Cumulative twist in radians relative to gesture start.
  final double rotation;

  /// Most recent twist velocity in radians per second.
  final double twistVelocity;
}

/// Decides whether the two selected pointer identifiers may start navigation.
typedef NavigationStartPredicate = bool Function(List<int> pointers);

/// Receives navigation lifecycle snapshots.
typedef TwoPointerNavigationCallback =
    void Function(TwoPointerNavigationUpdate update);

/// Listener-driven two-pointer pan, zoom, and rotate tracker.
///
/// This class deliberately does not extend [GestureRecognizer]. It observes
/// raw `Listener` events and therefore never claims a single pointer. It emits
/// nothing until two birth-eligible pointers exist, stops at first release,
/// and reports twist velocity only for detent admission; it never continues
/// with inertia.
final class TwoPointerNavigationTracker {
  TwoPointerNavigationTracker({required this.onUpdate, this.canStart});

  /// Callback invoked for each navigation lifecycle snapshot.
  final TwoPointerNavigationCallback onUpdate;

  /// Optional admission callback evaluated when two pointers become eligible.
  final NavigationStartPredicate? canStart;
  final Map<int, _NavigationContact> _contacts = <int, _NavigationContact>{};

  List<int>? _activePointers;
  Offset _lastFocalPoint = Offset.zero;
  double _initialDistance = 0;
  double _lastAngle = 0;
  double _rotation = 0;
  double _lastTwistVelocity = 0;
  Duration _lastTimestamp = Duration.zero;
  bool _isLocked = false;
  bool _startRejected = false;
  bool _blockedUntilClear = false;
  bool _isDisposed = false;

  /// Whether a two-pointer navigation gesture is active.
  bool get isActive => _activePointers != null;

  /// Whether transform lock currently prevents new navigation.
  bool get isLocked => _isLocked;

  /// Adds one raw touch pointer without claiming it in a gesture arena.
  void pointerDown({
    required int pointer,
    required Offset position,
    Duration timestamp = Duration.zero,
    bool isBirthEligible = true,
  }) {
    _checkNotDisposed();
    if (_contacts.containsKey(pointer)) {
      return;
    }
    _contacts[pointer] = _NavigationContact(
      position: position,
      isBirthEligible: isBirthEligible,
    );
    if (_isLocked) {
      _blockedUntilClear = true;
      return;
    }
    _tryStart(timestamp);
  }

  /// Updates one raw touch position and emits a cumulative gesture snapshot.
  void pointerMove({
    required int pointer,
    required Offset position,
    Duration timestamp = Duration.zero,
  }) {
    _checkNotDisposed();
    final _NavigationContact? contact = _contacts[pointer];
    if (contact == null) {
      return;
    }
    contact.position = position;
    final List<int>? activePointers = _activePointers;
    if (activePointers == null || !activePointers.contains(pointer)) {
      return;
    }
    final _NavigationMetrics metrics = _metrics(activePointers);
    final double angleDelta = _normalizedAngle(metrics.angle - _lastAngle);
    _rotation += angleDelta;
    _lastTwistVelocity = _angularVelocity(
      angleDelta: angleDelta,
      from: _lastTimestamp,
      to: timestamp,
    );
    final Offset focalDelta = metrics.focalPoint - _lastFocalPoint;
    _lastAngle = metrics.angle;
    _lastFocalPoint = metrics.focalPoint;
    _lastTimestamp = timestamp;
    onUpdate(
      TwoPointerNavigationUpdate(
        phase: TwoPointerNavigationPhase.update,
        pointers: activePointers,
        focalPoint: metrics.focalPoint,
        focalDelta: focalDelta,
        scale: _initialDistance == 0 ? 1 : metrics.distance / _initialDistance,
        rotation: _rotation,
        twistVelocity: _lastTwistVelocity,
      ),
    );
  }

  /// Ends navigation at the first selected-pointer release, with no inertia.
  void pointerUp({
    required int pointer,
    required Offset position,
    Duration timestamp = Duration.zero,
  }) {
    _checkNotDisposed();
    final _NavigationContact? contact = _contacts[pointer];
    if (contact == null) {
      return;
    }
    contact.position = position;
    final List<int>? activePointers = _activePointers;
    if (activePointers != null && activePointers.contains(pointer)) {
      _finishActive(TwoPointerNavigationPhase.end, timestamp: timestamp);
      _blockedUntilClear = true;
    }
    _contacts.remove(pointer);
    _clearBlockWhenEmpty();
  }

  /// Cancels navigation when a selected raw pointer is cancelled.
  void pointerCancel(int pointer) {
    _checkNotDisposed();
    if (!_contacts.containsKey(pointer)) {
      return;
    }
    final List<int>? activePointers = _activePointers;
    if (activePointers != null && activePointers.contains(pointer)) {
      _finishActive(TwoPointerNavigationPhase.cancel);
      _blockedUntilClear = true;
    }
    _contacts.remove(pointer);
    _clearBlockWhenEmpty();
  }

  /// Sets transform lock; locking cancels an active navigation immediately.
  ///
  /// Touches already down when the lock is released cannot start a gesture;
  /// all must lift before a fresh two-pointer gesture is admitted.
  void setLocked(bool value) {
    _checkNotDisposed();
    if (_isLocked == value) {
      return;
    }
    _isLocked = value;
    if (value) {
      if (_activePointers != null) {
        _finishActive(TwoPointerNavigationPhase.cancel);
      }
      if (_contacts.isNotEmpty) {
        _blockedUntilClear = true;
      }
      return;
    }
    _clearBlockWhenEmpty();
  }

  /// Cancels an active gesture while retaining raw pointer lifetimes.
  void cancel() {
    _checkNotDisposed();
    if (_activePointers != null) {
      _finishActive(TwoPointerNavigationPhase.cancel);
      _blockedUntilClear = _contacts.isNotEmpty;
    }
  }

  /// Clears all tracked state and makes further input invalid.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    if (_activePointers != null) {
      _finishActive(TwoPointerNavigationPhase.cancel);
    }
    _contacts.clear();
    _isDisposed = true;
  }

  void _tryStart(Duration timestamp) {
    if (_activePointers != null ||
        _blockedUntilClear ||
        _startRejected ||
        _isLocked) {
      return;
    }
    final List<int> eligiblePointers = _contacts.entries
        .where(
          (MapEntry<int, _NavigationContact> entry) =>
              entry.value.isBirthEligible,
        )
        .map((MapEntry<int, _NavigationContact> entry) => entry.key)
        .toList(growable: false);
    if (eligiblePointers.length != 2) {
      return;
    }
    if (!(canStart?.call(eligiblePointers) ?? true)) {
      _startRejected = true;
      return;
    }
    _activePointers = List<int>.unmodifiable(eligiblePointers);
    final _NavigationMetrics metrics = _metrics(eligiblePointers);
    _lastFocalPoint = metrics.focalPoint;
    _initialDistance = metrics.distance;
    _lastAngle = metrics.angle;
    _rotation = 0;
    _lastTwistVelocity = 0;
    _lastTimestamp = timestamp;
    onUpdate(
      TwoPointerNavigationUpdate(
        phase: TwoPointerNavigationPhase.start,
        pointers: eligiblePointers,
        focalPoint: metrics.focalPoint,
        focalDelta: Offset.zero,
        scale: 1,
        rotation: 0,
        twistVelocity: 0,
      ),
    );
  }

  void _finishActive(TwoPointerNavigationPhase phase, {Duration? timestamp}) {
    final List<int>? activePointers = _activePointers;
    if (activePointers == null) {
      return;
    }
    final _NavigationMetrics metrics = _metrics(activePointers);
    final double angleDelta = _normalizedAngle(metrics.angle - _lastAngle);
    _rotation += angleDelta;
    final Duration eventTimestamp = timestamp ?? _lastTimestamp;
    if (angleDelta != 0) {
      _lastTwistVelocity = _angularVelocity(
        angleDelta: angleDelta,
        from: _lastTimestamp,
        to: eventTimestamp,
      );
    } else if (eventTimestamp - _lastTimestamp > twistVelocitySampleHorizon) {
      _lastTwistVelocity = 0;
    }
    onUpdate(
      TwoPointerNavigationUpdate(
        phase: phase,
        pointers: activePointers,
        focalPoint: metrics.focalPoint,
        focalDelta: metrics.focalPoint - _lastFocalPoint,
        scale: _initialDistance == 0 ? 1 : metrics.distance / _initialDistance,
        rotation: _rotation,
        twistVelocity: _lastTwistVelocity,
      ),
    );
    _activePointers = null;
  }

  _NavigationMetrics _metrics(List<int> pointers) {
    final Offset first = _contacts[pointers[0]]!.position;
    final Offset second = _contacts[pointers[1]]!.position;
    final Offset delta = second - first;
    return _NavigationMetrics(
      focalPoint: Offset(
        (first.dx + second.dx) / 2,
        (first.dy + second.dy) / 2,
      ),
      distance: delta.distance,
      angle: math.atan2(delta.dy, delta.dx),
    );
  }

  void _clearBlockWhenEmpty() {
    if (_contacts.isNotEmpty) {
      return;
    }
    _blockedUntilClear = false;
    _startRejected = false;
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('TwoPointerNavigationTracker is disposed.');
    }
  }
}

final class _NavigationContact {
  _NavigationContact({required this.position, required this.isBirthEligible});

  Offset position;
  final bool isBirthEligible;
}

final class _NavigationMetrics {
  const _NavigationMetrics({
    required this.focalPoint,
    required this.distance,
    required this.angle,
  });

  final Offset focalPoint;
  final double distance;
  final double angle;
}

double _normalizedAngle(double value) {
  return math.atan2(math.sin(value), math.cos(value));
}

double _angularVelocity({
  required double angleDelta,
  required Duration from,
  required Duration to,
}) {
  if (angleDelta == 0) {
    return 0;
  }
  final int elapsedMicroseconds = (to - from).inMicroseconds;
  if (elapsedMicroseconds <= 0) {
    // Preserve the "fast, do not snap" meaning without leaking infinity to
    // CanvasController's finite-value contract.
    return angleDelta * Duration.microsecondsPerSecond;
  }
  return angleDelta * Duration.microsecondsPerSecond / elapsedMicroseconds;
}
