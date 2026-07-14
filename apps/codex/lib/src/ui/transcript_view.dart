import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app_model.dart';
import '../ink_render.dart';
import '../models.dart';
import '../paper/answer_flow.dart';
import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/ruled_text.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';

/// The conversation on the page: user turns in blue Caveat (or their actual
/// ink), Codex turns in Garamond that write themselves in, hand marks in the
/// margins, errors as marginal notes with a retry mark on the tail.
///
/// The list is reversed so the newest writing is always pinned to the bottom
/// edge, like a notebook open at today's line; sending or receiving snaps
/// back to the tail even if you had leafed upward.
final class TranscriptView extends StatefulWidget {
  const TranscriptView({required this.model, super.key});

  final CodexAppModel model;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

final class _TranscriptViewState extends State<TranscriptView> {
  final ScrollController _scroll = ScrollController();
  int _seenScrollNonce = -1;

  @override
  void initState() {
    super.initState();
    _seenScrollNonce = widget.model.scrollNonce;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// With `reverse: true`, offset 0 is the bottom (the tail of the page).
  void _snapToTail() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  void _snapToRule(PageScale metrics) {
    if (!_scroll.hasClients) {
      return;
    }
    final step = metrics.ruleStep;
    final target = (_scroll.offset / step).roundToDouble() * step;
    final clamped = target.clamp(0, _scroll.position.maxScrollExtent);
    if ((clamped - _scroll.offset).abs() > 0.5) {
      _scroll.jumpTo(clamped.toDouble());
    }
  }

  /// While the quill writes, stay on the tail unless the reader has clearly
  /// leafed away (more than a few rules up).
  void _followQuill(PageScale metrics) {
    if (_scroll.hasClients && _scroll.offset < metrics.ruleStep * 4) {
      _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final model = widget.model;
    final session = model.active;

    if (model.scrollNonce != _seenScrollNonce) {
      _seenScrollNonce = model.scrollNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapToTail());
    }

    final children = <Widget>[];

    if (session.isEmpty && model.phase == TurnPhase.idle) {
      children.add(
        _Block(
          marginMark: null,
          child: _StaticRuledText(
            text:
                'Start a new Codex thought here. The page will stay quiet '
                'until you write.',
            style: PaperType.note(
              ink,
              size: 30,
              color: ink.softInk.withAlpha(215),
            ),
          ),
        ),
      );
    }

    for (var i = 0; i < session.messages.length; i++) {
      final message = session.messages[i];
      final isTail = i == session.messages.length - 1;
      children.add(_gap(metrics, rules: i == 0 ? 0 : 1));
      switch (message.role) {
        case TurnRole.user:
          children.add(_userBlock(message, ink, model));
        case TurnRole.codex:
          children.add(_codexBlock(message, ink, model, metrics, isTail));
      }
    }

    if (model.phase == TurnPhase.busy) {
      children.add(_gap(metrics, rules: 1));
      children.add(_ActivityFootprints(model: model));
    }

    // Breathing room so the tail clears the composer divider.
    children.add(_gap(metrics, rules: 1));

    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        _snapToRule(metrics);
        return false;
      },
      child: ListView(
        controller: _scroll,
        reverse: true,
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.zero,
        children: children.reversed.toList(),
      ),
    );
  }

  Widget _gap(PageScale metrics, {required int rules}) =>
      SizedBox(height: metrics.ruleStep * rules);

  Widget _userBlock(ChatMessage message, PaperInk ink, CodexAppModel model) {
    final Widget writing;
    if (message.isHandwritten) {
      writing = _InkReplay(strokes: message.strokes);
    } else {
      writing = _StaticRuledText(
        text: message.text,
        style: PaperType.hand(ink),
      );
    }
    return _Block(
      marginMark: (sketch, baseline, theme) => Glyphs.marginalUserMark(
        sketch,
        PageDesign.contentX0,
        baseline,
        theme,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          writing,
          if (message.state == MessageState.queued)
            _QueuedTurnNote(
              message: message,
              position: model.queuePosition(message),
              total: model.queuedCount,
              onSteer: () => unawaited(model.steerNow(message)),
            ),
        ],
      ),
    );
  }

  Widget _codexBlock(
    ChatMessage message,
    PaperInk ink,
    CodexAppModel model,
    PageScale metrics,
    bool isTail,
  ) {
    if (message.state == MessageState.pending) {
      // The breathing spiral sits in the margin; tap it to stop the turn.
      final phase = model.thinkingPhase;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: model.stopTurn,
        child: _Block(
          marginMark: (sketch, baseline, theme) => Glyphs.thinkingSpiral(
            sketch,
            PageDesign.contentX0 - 22,
            baseline - 4 + (phase == 0 ? 0 : 1),
            phase: phase,
            ink: theme.softInk,
          ),
          child: _PendingLine(phase: phase),
        ),
      );
    }
    if (message.state == MessageState.failed) {
      return _Block(
        marginMark: (sketch, baseline, theme) => Glyphs.marginalCodexMark(
          sketch,
          PageDesign.contentX0,
          baseline,
          theme,
        ),
        child: _ErrorNote(
          message: message,
          showRetry: isTail,
          onRetry: model.retryTail,
        ),
      );
    }
    final animate = model.revealMessageId == message.id;
    return _Block(
      marginMark: (sketch, baseline, theme) => Glyphs.marginalCodexMark(
        sketch,
        PageDesign.contentX0,
        baseline,
        theme,
      ),
      child: AnswerFlow(
        key: ValueKey('answer-${message.id}'),
        text: message.text,
        maxWidth: metrics.designContentW,
        animate: animate,
        onAdvance: (_) => _followQuill(metrics),
      ),
    );
  }
}

/// A transcript block: content in the content column plus an optional margin
/// mark aligned to the first baseline.
final class _Block extends StatelessWidget {
  const _Block({required this.child, required this.marginMark});

  final Widget child;
  final void Function(Sketch sketch, double baseline, PaperInk ink)? marginMark;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(left: metrics.contentX0),
          child: child,
        ),
        if (marginMark != null)
          Positioned(
            left: 0,
            top: 0,
            child: CustomPaint(
              size: Size(metrics.contentX0, metrics.ruleStep),
              painter: _MarginMarkPainter(
                metrics: metrics,
                ink: ink,
                draw: marginMark!,
              ),
            ),
          ),
      ],
    );
  }
}

final class _MarginMarkPainter extends CustomPainter {
  _MarginMarkPainter({
    required this.metrics,
    required this.ink,
    required this.draw,
  });

  final PageScale metrics;
  final PaperInk ink;
  final void Function(Sketch sketch, double baseline, PaperInk ink) draw;

  @override
  void paint(Canvas canvas, Size size) {
    draw(Sketch(canvas, metrics), PageDesign.ruleStep, ink);
  }

  @override
  bool shouldRepaint(_MarginMarkPainter old) =>
      old.ink != ink || old.metrics != metrics;
}

/// Static ruled text (history, prompts): the same layout engine as the
/// reveal, painted whole.
final class _StaticRuledText extends StatelessWidget {
  const _StaticRuledText({required this.text, required this.style});

  final String text;
  final RuledStyle style;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final layout = RuledTextLayout(
      text: text,
      style: style,
      maxWidth: metrics.designContentW,
      firstBaseline: PageDesign.ruleStep.toDouble(),
    );
    final height = math.max(
      PageDesign.ruleStep,
      layout.nextBaseline - PageDesign.ruleStep,
    );
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(metrics.contentW, metrics.u(height)),
        painter: _StaticTextPainter(layout: layout, metrics: metrics),
      ),
    );
  }
}

final class _StaticTextPainter extends CustomPainter {
  _StaticTextPainter({required this.layout, required this.metrics});

  final RuledTextLayout layout;
  final PageScale metrics;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    layout.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StaticTextPainter old) =>
      old.layout.text != layout.text ||
      old.layout.style != layout.style ||
      old.metrics != metrics;
}

/// Committed handwriting shown in the transcript — ink stays ink.
final class _InkReplay extends StatelessWidget {
  const _InkReplay({required this.strokes});

  final List<InkStroke> strokes;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final bounds = strokesBounds(strokes);
    final rules = math.max(
      1,
      ((bounds.bottom + 16) / PageDesign.ruleStep).ceil(),
    );
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(metrics.contentW, metrics.ruleStep * rules),
        painter: _InkReplayPainter(
          strokes: strokes,
          color: ink.userInk,
          scale: metrics.scale,
        ),
      ),
    );
  }
}

final class _InkReplayPainter extends CustomPainter {
  _InkReplayPainter({
    required this.strokes,
    required this.color,
    required this.scale,
  });

  final List<InkStroke> strokes;
  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    paintStrokes(canvas, strokes, color, scale: scale);
  }

  @override
  bool shouldRepaint(_InkReplayPainter old) =>
      old.strokes != strokes || old.color != color || old.scale != scale;
}

/// A failed turn as a marginal note + optional retry mark (ERR catalog).
final class _ErrorNote extends StatelessWidget {
  const _ErrorNote({
    required this.message,
    required this.showRetry,
    required this.onRetry,
  });

  final ChatMessage message;
  final bool showRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final kind = message.error ?? FailureKind.nonZero;
    final layout = RuledTextLayout(
      text: kind.note,
      style: PaperType.note(ink),
      maxWidth: metrics.designContentW - 120,
      firstBaseline: PageDesign.ruleStep.toDouble(),
    );
    final height = math.max(
      PageDesign.ruleStep * 1.4,
      layout.nextBaseline - PageDesign.ruleStep,
    );
    return SizedBox(
      width: metrics.contentW,
      height: metrics.u(height),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CustomPaint(
            size: Size(
              metrics.u(metrics.designContentW - 120),
              metrics.u(height),
            ),
            painter: _ErrorNotePainter(
              layout: layout,
              metrics: metrics,
              ink: ink,
              kind: kind,
            ),
          ),
          if (showRetry)
            Positioned(
              right: 0,
              top: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRetry,
                child: Padding(
                  // A finger-sized well around the 40px mark.
                  padding: EdgeInsets.all(metrics.u(18)),
                  child: CustomPaint(
                    size: Size(
                      metrics.u(PageDesign.retryMark),
                      metrics.u(PageDesign.retryMark),
                    ),
                    painter: _RetryMarkPainter(metrics: metrics, ink: ink),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _ErrorNotePainter extends CustomPainter {
  _ErrorNotePainter({
    required this.layout,
    required this.metrics,
    required this.ink,
    required this.kind,
  });

  final RuledTextLayout layout;
  final PageScale metrics;
  final PaperInk ink;
  final FailureKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    layout.paint(canvas);
    if (kind == FailureKind.binaryMissing) {
      Glyphs.brokenNibMark(
        Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1)),
        layout.words.isEmpty ? 0 : layout.words.last.right + 16,
        PageDesign.ruleStep - 28,
        ink.softInk,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ErrorNotePainter old) =>
      old.kind != kind || old.ink != ink || old.metrics != metrics;
}

final class _RetryMarkPainter extends CustomPainter {
  _RetryMarkPainter({required this.metrics, required this.ink});

  final PageScale metrics;
  final PaperInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    Glyphs.retryMark(
      Sketch(canvas, metrics),
      const Rect.fromLTWH(0, 0, PageDesign.retryMark, PageDesign.retryMark),
      ink.ink,
    );
  }

  @override
  bool shouldRepaint(_RetryMarkPainter old) =>
      old.ink != ink || old.metrics != metrics;
}

/// Marginal footprints while Codex works — each step gets a little
/// hand-drawn tool mark so you can see *how* it walks, not just where.
final class _ActivityFootprints extends StatelessWidget {
  const _ActivityFootprints({required this.model});

  final CodexAppModel model;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final rows = <({String kind, String label})>[
      for (final note in model.liveActivity)
        (kind: note.kind, label: note.label),
      if (model.stillThinking) (kind: 'still', label: 'still thinking…'),
    ];
    if (rows.isEmpty) {
      return SizedBox(height: metrics.ruleStep);
    }
    return Padding(
      padding: EdgeInsets.only(left: metrics.contentX0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            RepaintBoundary(
              child: CustomPaint(
                size: Size(metrics.contentW, metrics.ruleStep),
                painter: _FootprintPainter(
                  kind: row.kind,
                  label: row.label,
                  metrics: metrics,
                  ink: ink,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One footprint row: tool mark in a small margin well, label on the rule.
final class _FootprintPainter extends CustomPainter {
  _FootprintPainter({
    required this.kind,
    required this.label,
    required this.metrics,
    required this.ink,
  });

  final String kind;
  final String label;
  final PageScale metrics;
  final PaperInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final baseline = PageDesign.ruleStep.toDouble();
    final color = ink.softInk;
    switch (kind) {
      case 'command':
        Glyphs.terminalMark(sketch, 12, baseline - 6, color);
      case 'search':
        Glyphs.magnifierMark(sketch, 12, baseline - 6, color);
      case 'file':
        Glyphs.leafMark(sketch, 12, baseline - 6, color);
      case 'tool':
        Glyphs.wrenchMark(sketch, 12, baseline - 6, color);
      case 'thinking' || 'still':
        Glyphs.thinkingSpiral(sketch, 24, baseline - 16, phase: 0, ink: color);
      default:
        sketch.dot(20, baseline - 12, 2.4, color);
    }
    final machine =
        kind == 'command' ||
        kind == 'file' ||
        kind == 'search' ||
        kind == 'tool';
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: machine
            ? PaperType.mono(ink, color: ink.softInk)
            : PaperType.note(ink).toTextStyle(),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: metrics.designContentW - 64);
    painter.paint(
      canvas,
      Offset(
        48,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FootprintPainter old) =>
      old.kind != kind ||
      old.label != label ||
      old.ink != ink ||
      old.metrics != metrics;
}

/// The line a pending answer will land on: three slow ink dots so an empty
/// rule reads as "being written", not as a glitch.
final class _PendingLine extends StatelessWidget {
  const _PendingLine({required this.phase});

  final int phase;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(metrics.contentW, metrics.ruleStep),
        painter: _PendingLinePainter(metrics: metrics, ink: ink, phase: phase),
      ),
    );
  }
}

final class _PendingLinePainter extends CustomPainter {
  _PendingLinePainter({
    required this.metrics,
    required this.ink,
    required this.phase,
  });

  final PageScale metrics;
  final PaperInk ink;
  final int phase;

  @override
  void paint(Canvas canvas, Size size) {
    final sketch = Sketch(canvas, metrics);
    final baseline = PageDesign.ruleStep.toDouble();
    final dots = phase == 0 ? 3 : 2;
    for (var i = 0; i < dots; i++) {
      sketch.dot(10 + i * 16.0, baseline - 8, 2.6, ink.softInk);
    }
  }

  @override
  bool shouldRepaint(_PendingLinePainter old) =>
      old.phase != phase || old.ink != ink || old.metrics != metrics;
}

/// A persisted queue marker directly under the note it belongs to. The action
/// is deliberately textual: unlike an unexplained glyph, it is obvious that
/// this note can take over the running turn.
final class _QueuedTurnNote extends StatelessWidget {
  const _QueuedTurnNote({
    required this.message,
    required this.position,
    required this.total,
    required this.onSteer,
  });

  final ChatMessage message;
  final int position;
  final int total;
  final VoidCallback onSteer;

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    return SizedBox(
      width: metrics.contentW,
      height: metrics.ruleStep,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _QueuedTurnPainter(
                metrics: metrics,
                ink: ink,
                position: position,
                total: total,
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            width: metrics.u(230),
            height: metrics.ruleStep,
            child: Semantics(
              button: true,
              label: 'Steer now with queued message $position',
              child: GestureDetector(
                key: ValueKey('steer-${message.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onSteer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _QueuedTurnPainter extends CustomPainter {
  _QueuedTurnPainter({
    required this.metrics,
    required this.ink,
    required this.position,
    required this.total,
  });

  final PageScale metrics;
  final PaperInk ink;
  final int position;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(metrics.scale);
    final sketch = Sketch(canvas, const PageScale(size: Size(1, 1), scale: 1));
    final baseline = PageDesign.ruleStep - 8.0;
    final queueLabel = total > 1 ? 'queued $position of $total' : 'queued';
    _paintLabel(canvas, queueLabel, 8, baseline, ink.softInk);

    final contentW = metrics.designContentW;
    final actionLeft = contentW - 222;
    sketch.strokePath(
      [
        Offset(actionLeft, 9),
        Offset(contentW - 5, 7),
        Offset(contentW - 2, PageDesign.ruleStep - 5),
        Offset(actionLeft + 4, PageDesign.ruleStep - 3),
      ],
      1.3,
      ink.softInk,
    );
    _paintLabel(canvas, 'steer now', actionLeft + 18, baseline, ink.ink);
    sketch.strokePath(
      [
        Offset(contentW - 38, 27),
        Offset(contentW - 16, 27),
        Offset(contentW - 24, 18),
        Offset(contentW - 16, 27),
        Offset(contentW - 24, 36),
      ],
      1.8,
      ink.ink,
    );
    canvas.restore();
  }

  void _paintLabel(
    Canvas canvas,
    String text,
    double x,
    double baseline,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: PaperType.note(ink, size: 25, color: color).toTextStyle(),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        x,
        baseline -
            painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      ),
    );
  }

  @override
  bool shouldRepaint(_QueuedTurnPainter old) =>
      old.position != position ||
      old.total != total ||
      old.ink != ink ||
      old.metrics != metrics;
}
