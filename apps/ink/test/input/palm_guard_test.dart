import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/input/palm_guard.dart';
import 'package:paper_ink/src/input/pen_router.dart';
import 'package:pluto_pen/pluto_pen.dart';

void main() {
  group('PalmGuard rules 1-5 matrix', () {
    test('table-driven policy matrix encodes rules 1 through 5', () {
      final List<
        ({
          String name,
          PalmTouchIntent intent,
          bool proximity,
          bool fingerDraw,
          List<Offset> positions,
          PalmRejectionReason? rejection,
        })
      >
      cases =
          <
            ({
              String name,
              PalmTouchIntent intent,
              bool proximity,
              bool fingerDraw,
              List<Offset> positions,
              PalmRejectionReason? rejection,
            })
          >[
            (
              name: 'rule 1 proximity gates tool touch',
              intent: PalmTouchIntent.toolTouch,
              proximity: true,
              fingerDraw: true,
              positions: <Offset>[Offset(200, 100)],
              rejection: PalmRejectionReason.penSuppression,
            ),
            (
              name: 'rule 1 clear pen allows enabled tool touch',
              intent: PalmTouchIntent.toolTouch,
              proximity: false,
              fingerDraw: true,
              positions: <Offset>[Offset(200, 100)],
              rejection: null,
            ),
            (
              name: 'rule 2 birth radius overrides tap exemption',
              intent: PalmTouchIntent.multiFingerTap,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(124, 100), Offset(200, 100)],
              rejection: PalmRejectionReason.stylusBirthRadius,
            ),
            (
              name: 'rule 3 tap is allowed during proximity',
              intent: PalmTouchIntent.multiFingerTap,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(160, 100), Offset(200, 100)],
              rejection: null,
            ),
            (
              name: 'rule 4 navigation needs both births past 48 lp',
              intent: PalmTouchIntent.navigationStart,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(148, 100), Offset(200, 100)],
              rejection: PalmRejectionReason.navigationClearance,
            ),
            (
              name: 'rule 4 clear navigation births are admitted',
              intent: PalmTouchIntent.navigationStart,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(149, 100), Offset(200, 100)],
              rejection: null,
            ),
            (
              name: 'rule 4 in-flight navigation survives proximity',
              intent: PalmTouchIntent.navigationContinue,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(130, 100), Offset(140, 100)],
              rejection: null,
            ),
            (
              name: 'rule 5 disabled finger draw gates tool touch',
              intent: PalmTouchIntent.toolTouch,
              proximity: false,
              fingerDraw: false,
              positions: <Offset>[Offset(200, 100)],
              rejection: PalmRejectionReason.fingerDrawDisabled,
            ),
            (
              name: 'rule 5 does not gate passive single-finger input',
              intent: PalmTouchIntent.passiveSingleFinger,
              proximity: true,
              fingerDraw: false,
              positions: <Offset>[Offset(200, 100)],
              rejection: null,
            ),
          ];

      for (final ({
            String name,
            PalmTouchIntent intent,
            bool proximity,
            bool fingerDraw,
            List<Offset> positions,
            PalmRejectionReason? rejection,
          })
          policyCase
          in cases) {
        final PalmGuard guard = PalmGuard()
          ..updatePenMetadata(_metadata(inProximity: policyCase.proximity));
        final List<PalmTouchBirth> touches = <PalmTouchBirth>[
          for (var index = 0; index < policyCase.positions.length; index++)
            guard.classifyTouchBirth(
              pointer: index + 1,
              position: policyCase.positions[index],
            ),
        ];

        final PalmGuardDecision decision = guard.decide(
          intent: policyCase.intent,
          touches: touches,
          now: const Duration(seconds: 1),
          fingerDrawEnabled: policyCase.fingerDraw,
        );

        expect(
          decision.rejectionReason,
          policyCase.rejection,
          reason: policyCase.name,
        );
      }
    });

    test('rule 1 gates enabled tool touch during proximity and contact', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final PalmTouchBirth touch = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(200, 200),
      );

      final PalmGuardDecision proximity = guard.decide(
        intent: PalmTouchIntent.toolTouch,
        touches: <PalmTouchBirth>[touch],
        now: const Duration(seconds: 1),
        fingerDrawEnabled: true,
      );
      guard.updatePenMetadata(_metadata(inProximity: true, inContact: true));
      final PalmGuardDecision contact = guard.decide(
        intent: PalmTouchIntent.toolTouch,
        touches: <PalmTouchBirth>[touch],
        now: const Duration(seconds: 1),
        fingerDrawEnabled: true,
      );

      expect(proximity.rejectionReason, PalmRejectionReason.penSuppression);
      expect(contact.rejectionReason, PalmRejectionReason.penSuppression);
    });

    test('rule 1 lingers through 300 ms and expires immediately after', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true))
        ..updatePenMetadata(
          _metadata(
            phase: PenMetadataPhase.leftProximity,
            timestamp: const Duration(seconds: 2),
          ),
        );
      final PalmTouchBirth touch = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(200, 200),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.toolTouch,
              touches: <PalmTouchBirth>[touch],
              now: const Duration(milliseconds: 2300),
              fingerDrawEnabled: true,
            )
            .rejectionReason,
        PalmRejectionReason.penSuppression,
      );
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.toolTouch,
              touches: <PalmTouchBirth>[touch],
              now: const Duration(milliseconds: 2301),
              fingerDrawEnabled: true,
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 2 drops every intent at the inclusive 24 lp boundary', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final PalmTouchBirth near = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(124, 100),
      );
      final PalmTouchBirth far = guard.classifyTouchBirth(
        pointer: 2,
        position: const Offset(200, 100),
      );

      for (final PalmTouchIntent intent in PalmTouchIntent.values) {
        final Iterable<PalmTouchBirth> touches = switch (intent) {
          PalmTouchIntent.multiFingerTap ||
          PalmTouchIntent.navigationStart ||
          PalmTouchIntent.navigationContinue => <PalmTouchBirth>[near, far],
          _ => <PalmTouchBirth>[near],
        };
        expect(
          guard
              .decide(
                intent: intent,
                touches: touches,
                now: const Duration(seconds: 1),
                fingerDrawEnabled: true,
              )
              .rejectionReason,
          PalmRejectionReason.stylusBirthRadius,
          reason: intent.name,
        );
      }
    });

    test('rule 2 is fixed at birth rather than following stylus movement', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final PalmTouchBirth initiallyFar = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(200, 100),
      );
      guard.updatePenMetadata(
        _metadata(inProximity: true, position: const Offset(200, 100)),
      );

      expect(initiallyFar.isDropped, isFalse);
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.multiFingerTap,
              touches: <PalmTouchBirth>[
                initiallyFar,
                guard.classifyTouchBirth(
                  pointer: 2,
                  position: const Offset(300, 100),
                ),
              ],
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 3 exempts multi-finger taps from proximity and linger', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final List<PalmTouchBirth> touches = <PalmTouchBirth>[
        guard.classifyTouchBirth(pointer: 1, position: const Offset(160, 100)),
        guard.classifyTouchBirth(pointer: 2, position: const Offset(200, 100)),
      ];

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.multiFingerTap,
              touches: touches,
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );
      guard.updatePenMetadata(
        _metadata(
          phase: PenMetadataPhase.leftProximity,
          timestamp: const Duration(seconds: 1),
        ),
      );
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.multiFingerTap,
              touches: touches,
              now: const Duration(milliseconds: 1100),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 4 requires both new navigation pointers beyond 48 lp', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final PalmTouchBirth atBoundary = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(148, 100),
      );
      final PalmTouchBirth beyond = guard.classifyTouchBirth(
        pointer: 2,
        position: const Offset(149, 100),
      );
      final PalmTouchBirth far = guard.classifyTouchBirth(
        pointer: 3,
        position: const Offset(200, 100),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: <PalmTouchBirth>[atBoundary, far],
              now: const Duration(seconds: 1),
            )
            .rejectionReason,
        PalmRejectionReason.navigationClearance,
      );
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: <PalmTouchBirth>[beyond, far],
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 4 clearance stays tied to the stylus position at birth', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(_metadata(inProximity: true));
      final List<PalmTouchBirth> bornClear = <PalmTouchBirth>[
        guard.classifyTouchBirth(pointer: 1, position: const Offset(149, 100)),
        guard.classifyTouchBirth(pointer: 2, position: const Offset(200, 100)),
      ];
      guard.updatePenMetadata(
        _metadata(inProximity: true, position: const Offset(149, 100)),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: bornClear,
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );

      guard.updatePenMetadata(
        _metadata(inProximity: true, position: const Offset(100, 100)),
      );
      final List<PalmTouchBirth> bornBlocked = <PalmTouchBirth>[
        guard.classifyTouchBirth(pointer: 3, position: const Offset(148, 100)),
        guard.classifyTouchBirth(pointer: 4, position: const Offset(200, 100)),
      ];
      guard.updatePenMetadata(
        _metadata(inProximity: true, position: const Offset(500, 500)),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: bornBlocked,
              now: const Duration(seconds: 1),
            )
            .rejectionReason,
        PalmRejectionReason.navigationClearance,
      );
    });

    test('rule 4 rejects poll-only proximity with unknown pen geometry', () {
      final PalmGuard guard = PalmGuard();
      guard.synchronizePenState(
        const PenState(
          isInProximity: true,
          isInContact: false,
          tool: PenTool.pen,
          buttons: PenButtons.none,
        ),
        timestamp: const Duration(seconds: 1),
      );
      final List<PalmTouchBirth> touches = <PalmTouchBirth>[
        guard.classifyTouchBirth(pointer: 1, position: const Offset(100, 100)),
        guard.classifyTouchBirth(pointer: 2, position: const Offset(200, 100)),
      ];

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationStart,
              touches: touches,
              now: const Duration(seconds: 1),
            )
            .rejectionReason,
        PalmRejectionReason.navigationClearance,
      );
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.multiFingerTap,
              touches: touches,
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 4 always allows already admitted navigation to continue', () {
      final PalmGuard guard = PalmGuard()
        ..updatePenMetadata(
          _metadata(inProximity: false, position: const Offset(500, 500)),
        );
      final List<PalmTouchBirth> touches = <PalmTouchBirth>[
        guard.classifyTouchBirth(pointer: 1, position: const Offset(100, 100)),
        guard.classifyTouchBirth(pointer: 2, position: const Offset(150, 100)),
      ];
      guard.updatePenMetadata(
        _metadata(inProximity: true, position: const Offset(125, 100)),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.navigationContinue,
              touches: touches,
              now: const Duration(seconds: 1),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('rule 5 requires the finger-draw setting only for tool touch', () {
      final PalmGuard guard = PalmGuard();
      final PalmTouchBirth touch = guard.classifyTouchBirth(
        pointer: 1,
        position: const Offset(20, 20),
      );

      expect(
        guard
            .decide(
              intent: PalmTouchIntent.toolTouch,
              touches: <PalmTouchBirth>[touch],
              now: Duration.zero,
            )
            .rejectionReason,
        PalmRejectionReason.fingerDrawDisabled,
      );
      expect(
        guard
            .decide(
              intent: PalmTouchIntent.passiveSingleFinger,
              touches: <PalmTouchBirth>[touch],
              now: Duration.zero,
            )
            .isAllowed,
        isTrue,
      );
    });

    test('PenState poll is authoritative and starts linger on transition', () {
      final PalmGuard guard = PalmGuard();
      guard.synchronizePenState(
        const PenState(
          isInProximity: true,
          isInContact: false,
          tool: PenTool.pen,
          buttons: PenButtons.none,
        ),
        timestamp: const Duration(seconds: 1),
      );
      guard.synchronizePenState(
        const PenState(
          isInProximity: false,
          isInContact: false,
          tool: PenTool.pen,
          buttons: PenButtons.none,
        ),
        timestamp: const Duration(seconds: 2),
      );

      expect(
        guard.isToolTouchSuppressedAt(const Duration(milliseconds: 2299)),
        isTrue,
      );
      expect(
        guard.isToolTouchSuppressedAt(const Duration(milliseconds: 2301)),
        isFalse,
      );
    });

    test('unknown stylus geometry never triggers the birth-radius rule', () {
      final PalmGuard guard = PalmGuard();
      final PalmTouchBirth touch = guard.classifyTouchBirth(
        pointer: 1,
        position: Offset.zero,
      );

      expect(touch.stylusDistance, double.infinity);
      expect(touch.isDropped, isFalse);
    });
  });
}

PenMetadata _metadata({
  PenMetadataPhase phase = PenMetadataPhase.hover,
  Duration timestamp = const Duration(seconds: 1),
  Offset position = const Offset(100, 100),
  bool inProximity = false,
  bool inContact = false,
}) {
  return PenMetadata(
    phase: phase,
    timestamp: timestamp,
    logicalPosition: position,
    rawPosition: position,
    tool: PenTool.pen,
    tilt: Offset.zero,
    rawTilt: Offset.zero,
    buttons: PenButtons.none,
    hoverDistance: 0,
    rawDistance: 0,
    isInProximity: inProximity,
    isInContact: inContact,
    hasChannelSample: true,
  );
}
