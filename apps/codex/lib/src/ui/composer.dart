import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../app_model.dart';
import '../models.dart';
import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/ruled_text.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';
import 'ink_canvas.dart';
import 'sketch_keyboard.dart';

/// The composer band: wavy divider, mode tabs, entry area (typed draft with
/// caret, or ink canvas with undo/clear), send flourish, and the sketch
/// keyboard in keyboard mode. Occupies the page from the separator down.
final class Composer extends StatefulWidget {
  const Composer({required this.model, super.key});

  final CodexAppModel model;

  static double sepYFor(AuthorMode mode, PageScale metrics) => metrics.bottomY(
    mode == AuthorMode.keyboard ? PageDesign.kbSepY : PageDesign.hwSepY,
  );

  /// The pen mark's box: bottom edge resting on the divider.
  static Rect nibRect(double sepY) => Rect.fromLTWH(40, sepY - 54, 50, 52);

  /// The keyboard mark's box, spaced clear of the pen.
  static Rect keysRect(double sepY) => Rect.fromLTWH(102, sepY - 52, 58, 50);

  /// The goal flag's box, third on the strip.
  static Rect flagRect(double sepY) => Rect.fromLTWH(178, sepY - 54, 64, 54);

  /// The running-turn control, kept at the quiet right edge of the divider.
  static Rect stopRect(double sepY, PageScale metrics) =>
      Rect.fromLTWH(metrics.rightX(754), sepY - 48, 146, 40);

  static Rect sendRectFor(AuthorMode mode, PageScale metrics) =>
      mode == AuthorMode.keyboard
      ? metrics.designSendMarkRectKb
      : metrics.designSendMarkRectHw;

  @override
  State<Composer> createState() => _ComposerState();
}

final class _ComposerState extends State<Composer> {
  void _tap(Offset local, PageScale metrics) {
    final model = widget.model;
    final mode = model.inputMode;
    final sepY = Composer.sepYFor(mode, metrics);
    final design = Offset(
      local.dx / metrics.scale,
      local.dy / metrics.scale + (sepY - _bandPadDesign),
    );
    final nib = Composer.nibRect(sepY);
    final keys = Composer.keysRect(sepY);
    const inflate = 12.0; // generous touch wells around the marks
    if (nib.inflate(inflate).contains(design)) {
      if (mode != AuthorMode.handwriting) {
        model.toggleMode();
        EinkRefreshRegion.request(
          context,
          refreshClass: RefreshClass.text,
          reason: 'composer.mode',
        );
      }
      return;
    }
    if (keys.inflate(inflate).contains(design)) {
      if (mode != AuthorMode.keyboard) {
        model.toggleMode();
        EinkRefreshRegion.request(
          context,
          refreshClass: RefreshClass.text,
          reason: 'composer.mode',
        );
      }
      return;
    }
    if ((model.goalEditing || !model.active.hasGoal) &&
        Composer.flagRect(sepY).inflate(inflate).contains(design)) {
      if (model.goalEditing) {
        model.cancelGoalEdit();
      } else {
        model.beginGoalEdit();
      }
      return;
    }
    if (model.phase == TurnPhase.busy &&
        Composer.stopRect(sepY, metrics).inflate(8).contains(design)) {
      model.stopTurn();
      return;
    }
    final send = Composer.sendRectFor(mode, metrics);
    if (send.inflate(18).contains(design)) {
      if (mode == AuthorMode.keyboard) {
        unawaited(model.sendKeyboard());
      } else {
        unawaited(model.sendHandwriting());
      }
      return;
    }
    if (mode == AuthorMode.handwriting) {
      final toolbarY = metrics.designHeight - 74;
      final undoRect = Rect.fromLTWH(PageDesign.contentX0, toolbarY, 50, 46);
      final clearRect = Rect.fromLTWH(
        PageDesign.contentX0 + 72,
        toolbarY,
        50,
        46,
      );
      if (undoRect.inflate(14).contains(design)) {
        model.undoStroke();
        return;
      }
      if (clearRect.inflate(14).contains(design)) {
        model.clearStrokes();
        return;
      }
    }
  }

  /// The band starts far enough above the separator that the strip marks
  /// (which perch ON the line) are fully inside it — for painting AND for
  /// taps; anything shallower leaves their top halves untappable.
  static const double _bandPadDesign = 68;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final model = widget.model;
    final mode = model.inputMode;
    final sepY = Composer.sepYFor(mode, metrics);
    final bandTop = sepY - _bandPadDesign;
    final heightDesign = metrics.designHeight - bandTop;

    final children = <Widget>[
      // Backing paper so transcript scrolling never shows through.
      Positioned.fill(child: ColoredBox(color: ink.paper)),
      Positioned.fill(
        child: CustomPaint(
          painter: _ComposerChromePainter(
            metrics: metrics,
            ink: ink,
            model: model,
            bandTop: bandTop,
          ),
        ),
      ),
    ];

    if (mode == AuthorMode.handwriting) {
      // Ink capture across the writing rules (below the tabs, above toolbar).
      final inkTop = metrics.u(metrics.designHwRulesY.first - 44 - bandTop);
      final inkBottom = metrics.u(metrics.designHeight - 84 - bandTop);
      children.add(
        Positioned(
          left: 0,
          right: 0,
          top: inkTop,
          height: math.max(0, inkBottom - inkTop),
          child: InkCanvas(
            strokes: model.handwritingDraft,
            origin: Offset(0, metrics.designHwRulesY.first - 44),
            onStroke: model.addStroke,
          ),
        ),
      );
    } else {
      children.add(
        Positioned(
          left: 0,
          right: 0,
          top: metrics.u(metrics.designKbTopY - bandTop),
          bottom: 0,
          child: SketchKeyboard(model: model),
        ),
      );
    }

    // Tap layer for marks (above ink canvas so glyph taps win).
    children.add(
      Positioned.fill(
        child: _MarkTapLayer(
          onTap: (local) => _tap(local, metrics),
          mode: mode,
          metrics: metrics,
          bandTop: bandTop,
          flagActive: model.goalEditing || !model.active.hasGoal,
          stopActive: model.phase == TurnPhase.busy,
        ),
      ),
    );

    return SizedBox(
      height: metrics.u(heightDesign),
      child: Stack(children: children),
    );
  }
}

/// Transparent tap routing that only claims taps landing on interactive
/// marks, letting everything else fall through to the ink canvas/keyboard.
final class _MarkTapLayer extends StatelessWidget {
  const _MarkTapLayer({
    required this.onTap,
    required this.mode,
    required this.metrics,
    required this.bandTop,
    required this.flagActive,
    required this.stopActive,
  });

  final ValueChanged<Offset> onTap;
  final AuthorMode mode;
  final PageScale metrics;
  final double bandTop;

  /// Whether the goal flag currently occupies its strip slot.
  final bool flagActive;
  final bool stopActive;

  bool _hits(Offset local) {
    final design = Offset(
      local.dx / metrics.scale,
      local.dy / metrics.scale + bandTop,
    );
    final sepY = Composer.sepYFor(mode, metrics);
    final marks = <Rect>[
      Composer.nibRect(sepY).inflate(12),
      Composer.keysRect(sepY).inflate(12),
      if (flagActive) Composer.flagRect(sepY).inflate(12),
      if (stopActive) Composer.stopRect(sepY, metrics).inflate(8),
      Composer.sendRectFor(mode, metrics).inflate(18),
      if (mode == AuthorMode.handwriting) ...[
        Rect.fromLTWH(
          PageDesign.contentX0,
          metrics.designHeight - 74,
          50,
          46,
        ).inflate(14),
        Rect.fromLTWH(
          PageDesign.contentX0 + 72,
          metrics.designHeight - 74,
          50,
          46,
        ).inflate(14),
      ],
    ];
    return marks.any((r) => r.contains(design));
  }

  @override
  Widget build(BuildContext context) {
    return _PassthroughTapRegion(hitTest: _hits, onTap: onTap);
  }
}

final class _PassthroughTapRegion extends StatelessWidget {
  const _PassthroughTapRegion({required this.hitTest, required this.onTap});

  final bool Function(Offset local) hitTest;
  final ValueChanged<Offset> onTap;

  @override
  Widget build(BuildContext context) {
    return _RegionHitTester(
      hitTest: hitTest,
      child: GestureDetector(
        // The region gate above decides *where* we participate; within a
        // claimed mark the tap must always win over layers underneath.
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => onTap(d.localPosition),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Only participates in hit testing where [hitTest] says so.
final class _RegionHitTester extends SingleChildRenderObjectWidget {
  const _RegionHitTester({required this.hitTest, required super.child});

  final bool Function(Offset local) hitTest;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RegionHitTesterRender(hitTest);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RegionHitTesterRender renderObject,
  ) {
    renderObject.hitTestFn = hitTest;
  }
}

final class _RegionHitTesterRender extends RenderProxyBox {
  _RegionHitTesterRender(this.hitTestFn);

  bool Function(Offset local) hitTestFn;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !hitTestFn(position)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

final class _ComposerChromePainter extends CustomPainter {
  _ComposerChromePainter({
    required this.metrics,
    required this.ink,
    required this.model,
    required this.bandTop,
  }) : super(repaint: model);

  final PageScale metrics;
  final PaperInk ink;
  final CodexAppModel model;
  final double bandTop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    canvas.translate(0, -bandTop);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final mode = model.inputMode;
    final sepY = Composer.sepYFor(mode, metrics);

    // The mode marks perch ON the divider like charms; the wavy rule
    // begins to their right so nothing is struck through.
    final nib = Composer.nibRect(sepY);
    final keys = Composer.keysRect(sepY);
    final flag = Composer.flagRect(sepY);
    Glyphs.wavyRule(
      sketch,
      flag.right + 14,
      sepY,
      metrics.designContentX1,
      model.goalEditing ? ink.rule : ink.softInk,
    );
    Glyphs.penGlyph(
      sketch,
      nib.left + 2,
      nib.top + 6,
      mode == AuthorMode.handwriting ? ink.ink : ink.softInk.withAlpha(205),
    );
    Glyphs.keyboardGlyph(
      sketch,
      keys.left + 2,
      keys.top + 4,
      mode == AuthorMode.keyboard ? ink.ink : ink.softInk.withAlpha(205),
    );
    // The goal flag appears here only as an invitation (no goal yet) or,
    // lit, while one is being written (tap = put the pen down). Once a goal
    // is pinned, the ribbon at the top of the page is its one true home.
    // Its pole's foot rests on the divider like its neighbours' feet.
    final showFlag = model.goalEditing || !model.active.hasGoal;
    if (showFlag) {
      final flagColor = model.goalEditing ? ink.ink : ink.softInk;
      Glyphs.flagMark(sketch, flag.left + 8, sepY - 9, flagColor);
      final goalLabel = TextPainter(
        text: TextSpan(
          text: 'goal',
          style: PaperType.note(ink, size: 22, color: flagColor).toTextStyle(),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      goalLabel.paint(
        canvas,
        Offset(
          flag.left + 48,
          sepY -
              8 -
              goalLabel.computeDistanceToActualBaseline(
                TextBaseline.alphabetic,
              ),
        ),
      );
    }
    if (model.phase == TurnPhase.busy) {
      _paintStopControl(canvas, sketch, sepY);
    }
    // A firm tick on the line under the active mark.
    final active = mode == AuthorMode.handwriting ? nib : keys;
    sketch.strokePath(
      [Offset(active.left + 8, sepY + 6), Offset(active.right - 8, sepY + 7)],
      2.2,
      ink.ink,
    );

    if (mode == AuthorMode.keyboard) {
      _paintKeyboardEntry(canvas, sketch);
    } else {
      _paintHandwritingEntry(sketch);
    }
    canvas.restore();
  }

  void _paintStopControl(Canvas canvas, Sketch sketch, double sepY) {
    final rect = Composer.stopRect(sepY, metrics);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = ink.paper,
    );
    sketch.strokePath(
      [
        Offset(rect.left + 3, rect.top + 5),
        Offset(rect.right - 5, rect.top + 3),
        Offset(rect.right - 3, rect.bottom - 4),
        Offset(rect.left + 5, rect.bottom - 2),
        Offset(rect.left + 3, rect.top + 5),
      ],
      1.6,
      ink.ink,
    );
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 15, rect.top + 12, 15, 15),
      Paint()..color = ink.ink,
    );
    final label = TextPainter(
      text: TextSpan(
        text: 'stop',
        style: PaperType.note(ink, size: 25, color: ink.ink).toTextStyle(),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(
        rect.left + 43,
        rect.bottom -
            7 -
            label.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  void _paintKeyboardEntry(Canvas canvas, Sketch sketch) {
    for (final y in metrics.designKbEntryRulesY) {
      sketch.line(
        PageDesign.contentX0,
        y,
        metrics.designContentX1,
        y,
        1,
        ink.faintRule,
      );
    }
    // While editing the goal, the words appear on the goal line at the top
    // of the page (where they belong); down here the entry band only points
    // the way, and the keyboard keeps typing.
    if (model.goalEditing) {
      final note = TextPainter(
        text: TextSpan(
          text:
              'writing this page\u2019s goal above \u2014 send pins it, '
              'empty clears it',
          style: PaperType.note(ink, color: ink.ink).toTextStyle(),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '\u2026',
      )..layout(maxWidth: metrics.designKbEntryW);
      note.paint(
        canvas,
        Offset(
          PageDesign.contentX0.toDouble(),
          metrics.designKbEntryRulesY.first -
              note.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
      );
      Glyphs.sendFlourish(
        sketch,
        metrics.designSendMarkRectKb,
        enabled: model.phase == TurnPhase.idle,
        ink: ink,
      );
      return;
    }
    final style = PaperType.hand(ink, size: PageDesign.handComposer);
    final layout = RuledTextLayout(
      text: model.keyboardDraft,
      style: style,
      maxWidth: metrics.designKbEntryW,
      firstBaseline: metrics.designKbEntryRulesY.first,
      x: PageDesign.contentX0,
    );
    // Keep the caret's line inside the two entry rules: shift up whole rules.
    final caret = layout.caretPosition(model.caret);
    final overflowRules = math.max(
      0,
      ((caret.baseline - metrics.designKbEntryRulesY.last) /
              PageDesign.ruleStep)
          .ceil(),
    );
    canvas.save();
    if (overflowRules > 0) {
      canvas.clipRect(
        Rect.fromLTWH(
          0,
          metrics.designKbEntryRulesY.first - PageDesign.ruleStep + 6,
          metrics.designWidth,
          PageDesign.ruleStep * 2.4,
        ),
      );
      canvas.translate(0, -overflowRules * PageDesign.ruleStep);
    }
    layout.paint(canvas);
    if (model.phase == TurnPhase.idle) {
      sketch.line(
        caret.x + 9,
        caret.baseline - 30,
        caret.x + 9,
        caret.baseline + 3,
        3,
        ink.ink,
      );
    }
    canvas.restore();
    Glyphs.sendFlourish(
      sketch,
      metrics.designSendMarkRectKb,
      enabled: model.keyboardSendEnabled,
      ink: ink,
    );
  }

  void _paintHandwritingEntry(Sketch sketch) {
    for (final y in metrics.designHwRulesY) {
      sketch.line(
        PageDesign.contentX0,
        y,
        metrics.designContentX1,
        y,
        1,
        ink.faintRule,
      );
    }
    final toolbarY = metrics.designHeight - 74;
    Glyphs.undoGlyph(sketch, PageDesign.contentX0, toolbarY, ink.softInk);
    Glyphs.clearGlyph(sketch, PageDesign.contentX0 + 72, toolbarY, ink.softInk);
    Glyphs.sendFlourish(
      sketch,
      metrics.designSendMarkRectHw.deflate(6),
      enabled: model.handwritingSendEnabled,
      ink: ink,
    );
  }

  @override
  bool shouldRepaint(_ComposerChromePainter old) =>
      old.ink != ink || old.metrics != metrics || old.bandTop != bandTop;
}
