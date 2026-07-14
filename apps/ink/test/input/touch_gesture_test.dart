import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/input/palm_guard.dart';

void main() {
  group('MultiTouchTapClassifier', () {
    test('two fingers emit undo only after the 40 ms settle', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _down(classifier, 2);

      _up(classifier, 1, milliseconds: 100);

      expect(taps, isEmpty);
      expect(classifier.isSettling, isTrue);
      expect(scheduler.lastDelay, multiTouchTapSettleDuration);
      scheduler.fireAll();
      expect(taps.single.kind, MultiTouchTapKind.undo);
      expect(taps.single.pointers, <int>{1, 2});
      classifier.dispose();
    });

    test('three staggered releases emit redo and never a later undo', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTapKind> kinds = <MultiTouchTapKind>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: (MultiTouchTap tap) => kinds.add(tap.kind),
        scheduler: scheduler.schedule,
      );
      for (var pointer = 1; pointer <= 3; pointer++) {
        _down(classifier, pointer);
      }

      _up(classifier, 1, milliseconds: 100);
      _up(classifier, 2, milliseconds: 110);
      _up(classifier, 3, milliseconds: 120);
      scheduler.fireAll();

      expect(kinds, <MultiTouchTapKind>[MultiTouchTapKind.redo]);
      classifier.dispose();
    });

    test('four fingers emit chrome collapse toggle', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTapKind> kinds = <MultiTouchTapKind>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: (MultiTouchTap tap) => kinds.add(tap.kind),
        scheduler: scheduler.schedule,
      );
      for (var pointer = 1; pointer <= 4; pointer++) {
        _down(classifier, pointer);
      }

      _up(classifier, 1, milliseconds: 90);
      scheduler.fireAll();

      expect(kinds, <MultiTouchTapKind>[MultiTouchTapKind.toggleChrome]);
      classifier.dispose();
    });

    test('one-finger and five-finger chords never classify', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _up(classifier, 1, milliseconds: 20);
      for (var pointer = 1; pointer <= 5; pointer++) {
        _down(classifier, pointer, milliseconds: 40);
      }
      _up(classifier, 1, milliseconds: 80);
      scheduler.fireAll();

      expect(taps, isEmpty);
      classifier.dispose();
    });

    test('300 ms and 32 lp boundaries are inclusive', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _down(classifier, 2);
      classifier.pointerMove(pointer: 1, position: const Offset(42, 10));

      classifier.pointerUp(
        pointer: 1,
        position: const Offset(42, 10),
        timestamp: const Duration(milliseconds: 300),
      );
      scheduler.fireAll();

      expect(taps.single.kind, MultiTouchTapKind.undo);
      classifier.dispose();
    });

    test('duration over 300 ms rejects the chord', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _down(classifier, 2);

      _up(classifier, 1, milliseconds: 301);
      scheduler.fireAll();

      expect(taps, isEmpty);
      classifier.dispose();
    });

    test('travel over 32 lp rejects the chord', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _down(classifier, 2);

      classifier.pointerMove(pointer: 2, position: const Offset(43, 20));
      _up(classifier, 1, milliseconds: 100);
      scheduler.fireAll();

      expect(taps, isEmpty);
      classifier.dispose();
    });

    test('a rule-2-ineligible birth rejects the whole command chord', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1, isBirthEligible: false);
      _down(classifier, 2);

      _up(classifier, 1, milliseconds: 100);
      scheduler.fireAll();

      expect(taps, isEmpty);
      classifier.dispose();
    });

    test('a cancel during settlement suppresses the pending action', () {
      final _FakeScheduler scheduler = _FakeScheduler();
      final List<MultiTouchTap> taps = <MultiTouchTap>[];
      final MultiTouchTapClassifier classifier = MultiTouchTapClassifier(
        onTap: taps.add,
        scheduler: scheduler.schedule,
      );
      _down(classifier, 1);
      _down(classifier, 2);
      _up(classifier, 1, milliseconds: 100);

      classifier.pointerCancel(2);
      scheduler.fireAll();

      expect(taps, isEmpty);
      classifier.dispose();
    });
  });

  group('TwoPointerNavigationTracker', () {
    test('a single pointer never emits or becomes active', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );

      tracker.pointerDown(pointer: 1, position: const Offset(10, 10));
      tracker.pointerMove(pointer: 1, position: const Offset(20, 20));

      expect(updates, isEmpty);
      expect(tracker.isActive, isFalse);
      tracker.dispose();
    });

    test('second eligible pointer starts at scale one around midpoint', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );
      tracker.pointerDown(pointer: 4, position: const Offset(0, 0));

      tracker.pointerDown(pointer: 9, position: const Offset(10, 0));

      expect(updates.single.phase, TwoPointerNavigationPhase.start);
      expect(updates.single.pointers, <int>[4, 9]);
      expect(updates.single.focalPoint, const Offset(5, 0));
      expect(updates.single.focalDelta, Offset.zero);
      expect(updates.single.scale, 1);
      expect(updates.single.rotation, 0);
      tracker.dispose();
    });

    test('updates report cumulative pan scale and rotation', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );
      tracker.pointerDown(pointer: 1, position: const Offset(-1, 0));
      tracker.pointerDown(pointer: 2, position: const Offset(1, 0));

      tracker.pointerMove(pointer: 2, position: const Offset(-1, 4));

      final TwoPointerNavigationUpdate update = updates.last;
      expect(update.phase, TwoPointerNavigationPhase.update);
      expect(update.focalPoint, const Offset(-1, 2));
      expect(update.focalDelta, const Offset(-1, 2));
      expect(update.scale, 2);
      expect(update.rotation, closeTo(math.pi / 2, 1e-9));
      tracker.dispose();
    });

    test('fast twist velocity survives an immediate stationary release', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );
      tracker.pointerDown(
        pointer: 1,
        position: const Offset(-1, 0),
        timestamp: Duration.zero,
      );
      tracker.pointerDown(
        pointer: 2,
        position: const Offset(1, 0),
        timestamp: Duration.zero,
      );
      tracker.pointerMove(
        pointer: 2,
        position: const Offset(-1, 2),
        timestamp: const Duration(milliseconds: 100),
      );
      final double movingVelocity = updates.last.twistVelocity;

      tracker.pointerUp(
        pointer: 1,
        position: const Offset(-1, 0),
        timestamp: const Duration(milliseconds: 110),
      );

      expect(movingVelocity, closeTo(5 * math.pi, 1e-9));
      expect(updates.last.phase, TwoPointerNavigationPhase.end);
      expect(updates.last.twistVelocity, movingVelocity);
      tracker.dispose();
    });

    test('first release ends dead and remaining moves emit nothing', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );
      tracker.pointerDown(pointer: 1, position: const Offset(0, 0));
      tracker.pointerDown(pointer: 2, position: const Offset(10, 0));

      tracker.pointerUp(pointer: 1, position: const Offset(0, 0));
      final int eventCountAtEnd = updates.length;
      tracker.pointerMove(pointer: 2, position: const Offset(20, 0));

      expect(updates.last.phase, TwoPointerNavigationPhase.end);
      expect(tracker.isActive, isFalse);
      expect(updates, hasLength(eventCountAtEnd));
      tracker.dispose();
    });

    test('start predicate can reject a proximity-blocked pair', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final List<List<int>> attempts = <List<int>>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
        canStart: (List<int> pointers) {
          attempts.add(pointers);
          return false;
        },
      );

      tracker.pointerDown(pointer: 1, position: Offset.zero);
      tracker.pointerDown(pointer: 2, position: const Offset(10, 0));

      expect(attempts, <List<int>>[
        <int>[1, 2],
      ]);
      expect(updates, isEmpty);
      expect(tracker.isActive, isFalse);
      tracker.dispose();
    });

    test('transform lock cancels active and requires all fingers to lift', () {
      final List<TwoPointerNavigationPhase> phases =
          <TwoPointerNavigationPhase>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: (TwoPointerNavigationUpdate update) {
          phases.add(update.phase);
        },
      );
      tracker.pointerDown(pointer: 1, position: Offset.zero);
      tracker.pointerDown(pointer: 2, position: const Offset(10, 0));

      tracker.setLocked(true);
      tracker.setLocked(false);
      tracker.pointerMove(pointer: 1, position: const Offset(1, 0));
      expect(phases, <TwoPointerNavigationPhase>[
        TwoPointerNavigationPhase.start,
        TwoPointerNavigationPhase.cancel,
      ]);
      tracker.pointerUp(pointer: 1, position: const Offset(1, 0));
      tracker.pointerUp(pointer: 2, position: const Offset(10, 0));
      tracker.pointerDown(pointer: 3, position: Offset.zero);
      tracker.pointerDown(pointer: 4, position: const Offset(10, 0));

      expect(phases.last, TwoPointerNavigationPhase.start);
      tracker.dispose();
    });

    test('birth-ineligible contacts are ignored as navigation pointers', () {
      final List<TwoPointerNavigationUpdate> updates =
          <TwoPointerNavigationUpdate>[];
      final TwoPointerNavigationTracker tracker = TwoPointerNavigationTracker(
        onUpdate: updates.add,
      );
      tracker.pointerDown(
        pointer: 1,
        position: Offset.zero,
        isBirthEligible: false,
      );
      tracker.pointerDown(pointer: 2, position: const Offset(10, 0));
      expect(updates, isEmpty);

      tracker.pointerDown(pointer: 3, position: const Offset(20, 0));

      expect(updates.single.pointers, <int>[2, 3]);
      tracker.dispose();
    });
  });
}

void _down(
  MultiTouchTapClassifier classifier,
  int pointer, {
  int milliseconds = 0,
  bool isBirthEligible = true,
}) {
  classifier.pointerDown(
    pointer: pointer,
    position: Offset(10, pointer * 10.0),
    timestamp: Duration(milliseconds: milliseconds),
    isBirthEligible: isBirthEligible,
  );
}

void _up(
  MultiTouchTapClassifier classifier,
  int pointer, {
  required int milliseconds,
}) {
  classifier.pointerUp(
    pointer: pointer,
    position: Offset(10, pointer * 10.0),
    timestamp: Duration(milliseconds: milliseconds),
  );
}

final class _FakeScheduler {
  final List<_FakeScheduledCallback> _callbacks = <_FakeScheduledCallback>[];
  Duration? lastDelay;

  CancelScheduledCallback schedule(Duration delay, void Function() callback) {
    lastDelay = delay;
    final _FakeScheduledCallback scheduled = _FakeScheduledCallback(callback);
    _callbacks.add(scheduled);
    return scheduled.cancel;
  }

  void fireAll() {
    final List<_FakeScheduledCallback> callbacks = List.of(_callbacks);
    _callbacks.clear();
    for (final _FakeScheduledCallback callback in callbacks) {
      callback.fire();
    }
  }
}

final class _FakeScheduledCallback {
  _FakeScheduledCallback(this._callback);

  final void Function() _callback;
  bool _isCancelled = false;

  void cancel() {
    _isCancelled = true;
  }

  void fire() {
    if (!_isCancelled) {
      _callback();
    }
  }
}
