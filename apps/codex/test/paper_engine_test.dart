import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/paper/layout.dart';
import 'package:paper_codex/src/paper/ruled_text.dart';
import 'package:paper_codex/src/paper/sketch.dart';
import 'package:paper_codex/src/paper/theme.dart';

void main() {
  group('sketch determinism', () {
    test('splitmix64 and fnvSeed are stable across runs', () {
      expect(splitmix64(42), splitmix64(42));
      expect(fnvSeed(2, 5), fnvSeed(2, 5));
      expect(fnvSeed(2, 5), isNot(fnvSeed(5, 2)));
    });

    test('seededWobble stays within amplitude and is stable', () {
      for (var idx = 0; idx < 64; idx++) {
        final v = seededWobble(fnvSeed(1, 3), idx, 2);
        expect(v, inInclusiveRange(-2, 2));
        expect(v, seededWobble(fnvSeed(1, 3), idx, 2));
      }
    });

    test('wobbleSegment displaces gently and is deterministic', () {
      final a = wobbleSegment(const Offset(0, 0), const Offset(40, 0));
      final b = wobbleSegment(const Offset(0, 0), const Offset(40, 0));
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i]);
        expect((a[i].dy).abs(), lessThan(1.0), reason: 'wobble stays subtle');
      }
    });
  });

  group('PageScale', () {
    test('maps design px to logical px at the live density', () {
      const scale = PageScale(size: Size(477, 848), scale: 0.5);
      expect(scale.u(56), 28);
      expect(scale.ruleStep, 28);
      expect(
        PageScale.forSize(const Size(954, 1696)).u(100),
        closeTo(100 * 160 / 264, 0.000001),
      );
    });

    test('reference viewport stays exact and wider panels gain real space', () {
      final reference = PageScale.forViewport(
        const Size(477, 848),
        devicePixelRatio: 2,
      );
      expect(reference.scale, 0.5);
      expect(reference.designSize, const Size(954, 1696));
      expect(reference.designContentW, PageDesign.contentW);

      const moveDpr = 264 / 160;
      final move = PageScale.forViewport(
        const Size(954 / moveDpr, 1696 / moveDpr),
        devicePixelRatio: moveDpr,
      );
      const dpr = 226 / 160;
      final rm = PageScale.forViewport(
        const Size(1404 / dpr, 1872 / dpr),
        devicePixelRatio: dpr,
      );
      const expectedWidth = 1404 * 264 / 226;
      const expectedHeight = 1872 * 264 / 226;
      expect(move.scale, closeTo(160 / 264, 0.000001));
      expect(rm.scale, closeTo(160 / 264, 0.000001));
      expect(rm.u(PageDesign.keyH), closeTo(move.u(PageDesign.keyH), 0.000001));
      expect(rm.physicalSize, const Size(1404, 1872));
      expect(rm.designWidth, closeTo(expectedWidth, 0.000001));
      expect(rm.designHeight, closeTo(expectedHeight, 0.000001));
      expect(
        rm.designContentW,
        closeTo(expectedWidth - PageDesign.margin * 2, 0.000001),
      );
      expect(
        rm.designSettingsMarkRect.right,
        closeTo(expectedWidth - 24, 0.000001),
      );
      expect(
        rm.designSendMarkRectHw.bottom,
        closeTo(expectedHeight - 28, 0.000001),
      );
    });

    testWidgets('viewport scope follows bounded layout constraints', (
      tester,
    ) async {
      PageScale? observed;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 1200),
            devicePixelRatio: 2,
          ),
          child: Align(
            child: SizedBox(
              width: 400,
              height: 500,
              child: PageScaleViewport(
                child: Builder(
                  builder: (context) {
                    observed = PageScale.of(context);
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(observed?.size, const Size(400, 500));
      expect(observed?.scale, closeTo(500 / PageDesign.pageH, 0.000001));
    });
  });

  group('RuledTextLayout', () {
    const style = RuledStyle(
      fontFamily: PaperFonts.serif,
      size: 28,
      color: Color(0xFF000000),
    );

    test('baselines land on the rule lattice and wrap advances one rule', () {
      final layout = RuledTextLayout(
        text:
            'alpha beta gamma delta epsilon zeta eta theta iota kappa '
            'lambda mu nu xi omicron pi rho sigma tau upsilon',
        style: style,
        maxWidth: 300,
        firstBaseline: 56,
      );
      expect(layout.words, isNotEmpty);
      expect(layout.lineCount, greaterThan(1));
      for (final word in layout.words) {
        expect(
          (word.baseline - 56) % PageDesign.ruleStep,
          0,
          reason: 'every baseline sits on a ruling',
        );
      }
      expect(layout.nextBaseline, 56 + layout.lineCount * PageDesign.ruleStep);
    });

    test('paragraph breaks leave a blank rule', () {
      final layout = RuledTextLayout(
        text: 'one\n\ntwo',
        style: style,
        maxWidth: 800,
        firstBaseline: 56,
      );
      final first = layout.words.first;
      final last = layout.words.last;
      // one at 56; blank rule; two at 56 + 3*56 (line + empty paragraph +
      // paragraph gap accounting per the original renderer).
      expect(first.baseline, 56);
      expect(
        last.baseline - first.baseline,
        greaterThanOrEqualTo(2 * PageDesign.ruleStep),
      );
    });

    test('caret positions track words and gaps', () {
      final layout = RuledTextLayout(
        text: 'hi codex',
        style: style,
        maxWidth: 800,
        firstBaseline: 56,
      );
      final start = layout.caretPosition(0);
      expect(start.x, 0);
      final mid = layout.caretPosition(1); // inside 'hi'
      expect(mid.x, greaterThan(0));
      final gap = layout.caretPosition(3); // just after the space
      expect(gap.x, greaterThanOrEqualTo(layout.words.first.right));
      final end = layout.caretPosition('hi codex'.length);
      expect(end.x, layout.words.last.right);
    });

    test('empty text is a zero-height layout', () {
      final layout = RuledTextLayout(
        text: '',
        style: style,
        maxWidth: 800,
        firstBaseline: 56,
      );
      expect(layout.words, isEmpty);
      expect(layout.nextBaseline, 56);
      expect(layout.caretPosition(0).x, 0);
    });
  });
}
