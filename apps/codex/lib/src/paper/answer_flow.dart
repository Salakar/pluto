import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'answer_markup.dart';
import 'glyphs.dart';
import 'layout.dart';
import 'ruled_text.dart';
import 'sketch.dart';
import 'theme.dart';

/// Tuning for the quill reveal. E-ink discipline: reveals are quantized to
/// coarse ticks (a handful of coherent damage bursts per second, never
/// per-frame motion); when the text is down the widget goes quiet so the
/// renderer's idle settle sharpens the page — the ink dries.
@immutable
final class RevealSpec {
  const RevealSpec({
    this.tickMs = 130,
    this.minWordsPerTick = 1,
    this.maxWordsPerTick = 3,
    this.developing = true,
    this.nib = true,
  });

  final int tickMs;
  final int minWordsPerTick;
  final int maxWordsPerTick;

  /// Words land faint and darken a tick later — wet ink developing.
  final bool developing;

  /// Draw the leading nib dot (the invisible quill).
  final bool nib;
}

/// One reveal unit: a word of prose, a todo/bullet item, or a code block.
final class _Unit {
  _Unit({required this.paint, required this.origin});

  /// Paints this unit; [faint] renders the wet-ink phase.
  final void Function(Canvas canvas, bool faint) paint;

  /// Nib position (design px, block-local) when this unit is next.
  final Offset origin;
}

final class _FlowLayout {
  _FlowLayout({
    required this.units,
    required this.decorations,
    required this.height,
  });

  /// Sequential reveal units.
  final List<_Unit> units;

  /// Non-revealing furniture painted once any of its group is visible
  /// (todo bracket, code rule) keyed by the unit index that unlocks it.
  final Map<int, List<void Function(Canvas)>> decorations;

  /// Block height, design px (multiple of the rule step).
  final double height;
}

/// A Codex answer that writes itself onto the rulings: prose reveals word by
/// word, todo/bullet items land line by line, code blocks arrive whole.
final class AnswerFlow extends StatefulWidget {
  const AnswerFlow({
    required this.text,
    required this.maxWidth,
    this.animate = false,
    this.spec = const RevealSpec(),
    this.onAdvance,
    this.onSettled,
    super.key,
  });

  final String text;

  /// Wrap width, design px.
  final double maxWidth;

  /// Whether to play the quill reveal (fresh answers) or paint statically
  /// (history).
  final bool animate;
  final RevealSpec spec;

  /// Reports the nib baseline (design px, block-local) as the reveal grows,
  /// so the page can keep the quill in view.
  final ValueChanged<double>? onAdvance;
  final VoidCallback? onSettled;

  @override
  State<AnswerFlow> createState() => _AnswerFlowState();
}

final class _AnswerFlowState extends State<AnswerFlow>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  int _revealed = 0;
  int _developedUpTo = 0;
  int _lastTick = -1;
  bool _announcedSettle = false;

  // Rebuilt in build() when inputs change; cached by input signature.
  _FlowLayout? _layout;
  String? _layoutKey;
  PaperInk? _layoutInk;

  bool _complete(_FlowLayout layout) =>
      _revealed >= layout.units.length &&
      (!widget.spec.developing || _developedUpTo >= layout.units.length);

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ticker = createTicker(_onTick)..start();
    }
  }

  @override
  void didUpdateWidget(AnswerFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _revealed = 0;
      _developedUpTo = 0;
      _lastTick = -1;
      _announcedSettle = false;
      if (widget.animate) {
        _ticker ??= createTicker(_onTick);
        if (!_ticker!.isActive) {
          _ticker!.start();
        }
      }
    }
  }

  void _onTick(Duration elapsed) {
    final layout = _layout;
    if (layout == null) {
      return;
    }
    final tick = widget.spec.tickMs <= 0
        ? _lastTick + 1
        : elapsed.inMilliseconds ~/ widget.spec.tickMs;
    if (tick == _lastTick) {
      return;
    }
    _lastTick = tick;
    final span = widget.spec.maxWordsPerTick - widget.spec.minWordsPerTick + 1;
    final step =
        widget.spec.minWordsPerTick +
        (span <= 1 ? 0 : splitmix64(widget.text.hashCode ^ tick).abs() % span);
    setState(() {
      _developedUpTo = _revealed;
      _revealed = math.min(layout.units.length, _revealed + step);
      if (!widget.spec.developing) {
        _developedUpTo = _revealed;
      }
    });
    if (_revealed > 0 && _revealed <= layout.units.length) {
      final i = math.min(_revealed, layout.units.length - 1);
      widget.onAdvance?.call(layout.units[i].origin.dy);
    }
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'quill.reveal',
    );
    if (_complete(layout)) {
      _ticker?.stop();
      if (!_announcedSettle) {
        _announcedSettle = true;
        EinkRefreshRegion.request(
          context,
          refreshClass: RefreshClass.text,
          reason: 'quill.settle',
        );
        widget.onSettled?.call();
      }
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  _FlowLayout _buildLayout(PaperInk ink) {
    final key = '${widget.text}|${widget.maxWidth}';
    if (_layout != null && _layoutKey == key && _layoutInk == ink) {
      return _layout!;
    }
    _layoutKey = key;
    _layoutInk = ink;
    return _layout = _layoutSegments(
      parseAnswerMarkup(widget.text),
      widget.maxWidth,
      ink,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ink = PaperCodexTheme.of(context);
    final metrics = PageScale.of(context);
    final layout = _buildLayout(ink);
    final revealed = widget.animate ? _revealed : layout.units.length;
    final developed = widget.animate && widget.spec.developing
        ? _developedUpTo
        : revealed;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(metrics.u(widget.maxWidth), metrics.u(layout.height)),
        painter: _FlowPainter(
          layout: layout,
          metrics: metrics,
          ink: ink,
          revealed: revealed,
          developedUpTo: developed,
          nib:
              widget.animate &&
              widget.spec.nib &&
              revealed < layout.units.length,
        ),
      ),
    );
  }
}

final class _FlowPainter extends CustomPainter {
  _FlowPainter({
    required this.layout,
    required this.metrics,
    required this.ink,
    required this.revealed,
    required this.developedUpTo,
    required this.nib,
  });

  final _FlowLayout layout;
  final PageScale metrics;
  final PaperInk ink;
  final int revealed;
  final int developedUpTo;
  final bool nib;

  @override
  void paint(Canvas canvas, Size size) {
    // Everything below paints in design space; scale once here.
    canvas.save();
    canvas.scale(metrics.scale);
    final n = revealed.clamp(0, layout.units.length);
    for (final entry in layout.decorations.entries) {
      if (n > entry.key) {
        for (final decorate in entry.value) {
          decorate(canvas);
        }
      }
    }
    for (var i = 0; i < n; i++) {
      layout.units[i].paint(canvas, i >= developedUpTo);
    }
    if (nib && n < layout.units.length) {
      final tip = layout.units[n].origin;
      Sketch(
        canvas,
        const PageScale(size: Size(1, 1), scale: 1),
      ).dot(tip.dx - 4, tip.dy - 3, 2.2, ink.ink);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlowPainter old) =>
      old.layout != layout ||
      old.revealed != revealed ||
      old.developedUpTo != developedUpTo ||
      old.nib != nib ||
      old.ink != ink ||
      old.metrics != metrics;
}

_FlowLayout _layoutSegments(
  List<AnswerSegment> segments,
  double maxWidth,
  PaperInk ink,
) {
  final units = <_Unit>[];
  final decorations = <int, List<void Function(Canvas)>>{};
  var baseline = PageDesign.ruleStep.toDouble();

  void addTextUnits(RuledTextLayout layout) {
    for (final word in layout.words) {
      units.add(
        _Unit(
          origin: Offset(word.x, word.baseline),
          paint: (canvas, faint) {
            if (faint) {
              layout.paintWordAs(canvas, word, ink.softInk);
            } else {
              word.paintAt(canvas);
            }
          },
        ),
      );
    }
  }

  // The flow painter scales the canvas to design space before invoking
  // units/decorations, so sketches here use an identity metrics.
  const identity = PageScale(size: Size(1, 1), scale: 1);

  var isFirst = true;
  for (final segment in segments) {
    // A breathing rule between different kinds of blocks, like the original
    // review pages.
    if (!isFirst) {
      baseline += PageDesign.ruleStep;
    }
    isFirst = false;
    switch (segment) {
      case ProseSegment(:final text):
        final layout = RuledTextLayout(
          text: text,
          style: PaperType.serifBody(ink),
          maxWidth: maxWidth,
          firstBaseline: baseline,
        );
        addTextUnits(layout);
        baseline = layout.nextBaseline;
      case BulletSegment(:final items):
        for (final item in items) {
          final layout = RuledTextLayout(
            text: item,
            style: PaperType.serifBody(ink),
            maxWidth: maxWidth - 36,
            firstBaseline: baseline,
            x: 36,
          );
          final dashY = baseline;
          final unlockIndex = units.length;
          decorations.putIfAbsent(unlockIndex, () => []).add((canvas) {
            final s = Sketch(canvas, identity);
            s.strokePath(
              [Offset(8, dashY - 9), Offset(24, dashY - 11)],
              1.6,
              ink.softInk,
            );
          });
          addTextUnits(layout);
          baseline = layout.nextBaseline;
        }
      case TodoSegment(:final items):
        final firstY = baseline;
        double lastY = baseline;
        final bracketUnlock = units.length;
        for (final item in items) {
          final layout = RuledTextLayout(
            text: item.text,
            style: PaperType.todo(ink),
            maxWidth: maxWidth - 72,
            firstBaseline: baseline,
            x: 72,
          );
          final itemY = baseline;
          final unlockIndex = units.length;
          decorations.putIfAbsent(unlockIndex, () => []).add((canvas) {
            Glyphs.checkbox(
              Sketch(canvas, identity),
              30,
              itemY,
              ink,
              checked: item.checked,
            );
          });
          addTextUnits(layout);
          lastY = layout.nextBaseline - PageDesign.ruleStep;
          baseline = layout.nextBaseline;
        }
        decorations.putIfAbsent(bracketUnlock, () => []).add((canvas) {
          Glyphs.marginBracket(
            Sketch(canvas, identity),
            -32,
            firstY - 30,
            lastY + 5,
            ink,
          );
        });
      case CodeSegment(:final lines):
        const linePitch = 28.0;
        final blockTop = baseline - PageDesign.ruleStep + 8;
        final rawHeight = lines.length * linePitch + 16;
        final rules = (rawHeight / PageDesign.ruleStep).ceil();
        final origin = Offset(0, baseline);
        final capturedBaseline = baseline;
        units.add(
          _Unit(
            origin: origin,
            paint: (canvas, faint) {
              final color = faint ? ink.softInk : ink.ink;
              // Left rule.
              canvas.drawRect(
                Rect.fromLTWH(
                  4,
                  blockTop,
                  2.4,
                  rules * PageDesign.ruleStep - 12,
                ),
                Paint()..color = ink.softInk.withAlpha(180),
              );
              final style = PaperType.mono(ink, color: color);
              for (var i = 0; i < lines.length; i++) {
                final painter = TextPainter(
                  text: TextSpan(text: lines[i], style: style),
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  ellipsis: '…',
                )..layout(maxWidth: maxWidth - 28);
                painter.paint(
                  canvas,
                  Offset(
                    24,
                    capturedBaseline - PageDesign.ruleStep + 16 + i * linePitch,
                  ),
                );
              }
            },
          ),
        );
        baseline += rules * PageDesign.ruleStep;
    }
  }

  final height = math.max(PageDesign.ruleStep, baseline - PageDesign.ruleStep);
  return _FlowLayout(units: units, decorations: decorations, height: height);
}
