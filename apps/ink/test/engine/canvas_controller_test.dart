import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/document/document.dart';
import 'package:paper_ink/src/engine/canvas_controller.dart';
import 'package:paper_ink/src/engine/geometry.dart';

void main() {
  CanvasController controller({
    Size document = const Size(100, 100),
    Size viewport = const Size(100, 100),
    InkViewState? initial,
    VoidCallback? onChanged,
  }) => CanvasController(
    documentSize: document,
    viewportSize: viewport,
    initialView: initial,
    onChanged: onChanged,
  );

  group('CanvasController transform', () {
    test('document and viewport points round-trip at full precision', () {
      final subject = controller(
        document: const Size(400, 500),
        viewport: const Size(300, 300),
        initial: InkViewState(tx: 37, ty: -21, scale: 1.7, rotationDeg: 23),
      );
      const point = Offset(123.456, 98.765);

      final viewportPoint = subject.viewportFromDoc(point);
      final roundTrip = subject.docFromViewport(viewportPoint);

      expect(roundTrip.dx, closeTo(point.dx, 1e-8));
      expect(roundTrip.dy, closeTo(point.dy, 1e-8));
    });

    test('assembled matrix applies scale then rotation then translation', () {
      final subject = controller(
        document: const Size(1000, 1000),
        viewport: const Size(1000, 1000),
      );
      subject.setView(
        translation: const Offset(1000, 0),
        scale: 1,
        rotation: math.pi / 2,
      );

      final result = subject.viewportFromDoc(const Offset(5, 10));

      expect(result.dx, closeTo(990, 1e-9));
      expect(result.dy, closeTo(5, 1e-9));
    });

    test('persisted view snapshot preserves canonical scalar values', () {
      final subject = controller();
      subject.setView(
        translation: const Offset(12, -7),
        scale: 2.5,
        rotation: math.pi / 3,
      );

      final view = subject.toViewState();

      expect(view.tx, 12);
      expect(view.ty, -7);
      expect(view.scale, 2.5);
      expect(view.rotationDeg, closeTo(60, 1e-9));
    });

    test('translation clamp retains fifteen percent on every edge', () {
      final subject = controller();

      subject.setView(
        translation: const Offset(10000, 0),
        scale: 1,
        rotation: 0,
      );
      expect(subject.translation.dx, closeTo(85, 1e-6));
      expect(subject.translation.dy, 0);

      subject.setView(
        translation: const Offset(0, -10000),
        scale: 1,
        rotation: 0,
      );
      expect(subject.translation.dx, 0);
      expect(subject.translation.dy, closeTo(-85, 1e-6));
    });

    test(
      'rotated extreme pan retains actual polygon area, not only its AABB',
      () {
        final subject = controller();

        subject.setView(
          translation: const Offset(10000, 10000),
          scale: 1,
          rotation: math.pi / 4,
        );

        final overlap = transformedRectIntersectionArea(
          subject.viewMatrix,
          const Rect.fromLTWH(0, 0, 100, 100),
          const Rect.fromLTWH(0, 0, 100, 100),
        );
        expect(overlap, greaterThanOrEqualTo(1500 - 1e-4));
      },
    );
  });

  group('CanvasController navigation', () {
    test('focal pan is one-to-one', () {
      final subject = controller();

      expect(subject.beginNavigation(const Offset(50, 50)), isTrue);
      subject.updateNavigation(
        focalPoint: const Offset(70, 65),
        scale: 1,
        rotation: 0,
      );

      expect(subject.translation, const Offset(20, 15));
      subject.endNavigation();
      expect(subject.gestureActive, isFalse);
    });

    test('zoom and twist preserve the captured document focal point', () {
      final subject = controller(
        document: const Size(1000, 1000),
        viewport: const Size(500, 500),
      );
      const firstFocal = Offset(200, 180);
      const nextFocal = Offset(230, 210);
      final anchor = subject.docFromViewport(firstFocal);

      subject.beginNavigation(firstFocal);
      subject.updateNavigation(
        focalPoint: nextFocal,
        scale: 1.8,
        rotation: 0.31,
      );

      final mapped = subject.viewportFromDoc(anchor);
      expect(mapped.dx, closeTo(nextFocal.dx, 1e-8));
      expect(mapped.dy, closeTo(nextFocal.dy, 1e-8));
    });

    test('gesture scale clamps at both binding limits', () {
      final subject = controller();

      subject.beginNavigation(const Offset(50, 50));
      subject.updateNavigation(
        focalPoint: const Offset(50, 50),
        scale: 1000,
        rotation: 0,
      );
      expect(subject.scale, 16);
      subject.endNavigation();

      subject.beginNavigation(const Offset(50, 50));
      subject.updateNavigation(
        focalPoint: const Offset(50, 50),
        scale: 0.0001,
        rotation: 0,
      );
      expect(subject.scale, 0.1);
    });

    test('gesture captures the exact 100 percent zoom detent', () {
      final subject = controller();
      subject.setView(translation: Offset.zero, scale: 0.5, rotation: 0);

      subject.beginNavigation(const Offset(50, 50));
      subject.updateNavigation(
        focalPoint: const Offset(50, 50),
        scale: 1.96,
        rotation: 0,
      );

      expect(subject.scale, 1);
    });

    test('low-velocity end captures a nearby quarter turn', () {
      final subject = controller();
      const focal = Offset(30, 70);
      final anchor = subject.docFromViewport(focal);

      subject.beginNavigation(focal);
      subject.updateNavigation(
        focalPoint: focal,
        scale: 1,
        rotation: 87 * math.pi / 180,
      );
      subject.endNavigation(twistVelocity: 0.1);

      expect(subject.rotation, closeTo(math.pi / 2, 1e-12));
      final mapped = subject.viewportFromDoc(anchor);
      expect(mapped.dx, closeTo(focal.dx, 1e-8));
      expect(mapped.dy, closeTo(focal.dy, 1e-8));
    });

    test('high-velocity end leaves nearby rotation free', () {
      final subject = controller();
      final rotation = 87 * math.pi / 180;

      subject.beginNavigation(const Offset(50, 50));
      subject.updateNavigation(
        focalPoint: const Offset(50, 50),
        scale: 1,
        rotation: rotation,
      );
      subject.endNavigation(twistVelocity: rotationSnapVelocity + 0.01);

      expect(subject.rotation, closeTo(rotation, 1e-12));
    });

    test('a second begin never steals an active gesture', () {
      final subject = controller();

      expect(subject.beginNavigation(const Offset(10, 10)), isTrue);
      expect(subject.beginNavigation(const Offset(80, 80)), isFalse);
    });
  });

  group('CanvasController actions and lock', () {
    test('fit centers the canvas and always resets rotation', () {
      final subject = controller(
        document: const Size(200, 400),
        viewport: const Size(300, 300),
      );
      subject.setView(translation: Offset.zero, scale: 2, rotation: 0.4);

      subject.fitToViewport();

      expect(subject.rotation, 0);
      expect(subject.scale, 0.75);
      expect(subject.translation, const Offset(75, 0));
    });

    test('rotation reset preserves the viewport-center document point', () {
      final subject = controller(
        document: const Size(500, 500),
        viewport: const Size(300, 300),
      );
      subject.setView(
        translation: const Offset(20, -30),
        scale: 1.3,
        rotation: 0.7,
      );
      const center = Offset(150, 150);
      final anchor = subject.docFromViewport(center);

      subject.resetRotation();

      expect(subject.rotation, 0);
      final mapped = subject.viewportFromDoc(anchor);
      expect(mapped.dx, closeTo(center.dx, 1e-8));
      expect(mapped.dy, closeTo(center.dy, 1e-8));
    });

    test(
      'stroke lock freezes every transform mutation through publication',
      () {
        var changes = 0;
        final subject = controller(onChanged: () => changes += 1);
        subject.setView(
          translation: const Offset(10, 11),
          scale: 1.5,
          rotation: 0.2,
        );
        subject.lockForStroke();
        final frozen = subject.viewMatrix.storage.toList();
        final frozenDocument = subject.documentSize;
        final frozenViewport = subject.viewportSize;
        final changesAfterLock = changes;

        expect(subject.beginNavigation(const Offset(50, 50)), isFalse);
        subject.setView(
          translation: const Offset(80, 80),
          scale: 3,
          rotation: 1,
        );
        subject.fitToViewport();
        subject.resetScale();
        subject.resetRotation();
        subject.setDocumentSize(const Size(200, 200));
        subject.setViewportSize(const Size(300, 300));

        expect(subject.viewMatrix.storage, orderedEquals(frozen));
        expect(subject.documentSize, frozenDocument);
        expect(subject.viewportSize, frozenViewport);
        expect(changes, changesAfterLock);

        subject.unlockAfterStrokeCommit();
        expect(subject.beginNavigation(const Offset(50, 50)), isTrue);
      },
    );

    test('actions notify once and no-op resets stay quiet', () {
      var changes = 0;
      final subject = controller(onChanged: () => changes += 1);

      subject.resetRotation();
      expect(changes, 0);
      subject.fitToViewport();
      expect(changes, 1);
      subject.lockForStroke();
      expect(changes, 2);
      subject.lockForStroke();
      expect(changes, 2);
      subject.unlockAfterStrokeCommit();
      expect(changes, 3);
    });
  });
}
