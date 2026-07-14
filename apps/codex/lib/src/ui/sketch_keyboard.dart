import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../app_model.dart';
import '../paper/glyphs.dart';
import '../paper/layout.dart';
import '../paper/sketch.dart';
import '../paper/theme.dart';

/// One key of the sketch keyboard (paper-codex `keyboard.rs::Key`).
@immutable
final class SketchKey {
  const SketchKey(
    this.label,
    this.col, {
    this.span = 0.86,
    this.kind = SketchKeyKind.text,
  });

  final String label;
  final double col;
  final double span;
  final SketchKeyKind kind;

  Rect rectFor(int row, PageScale metrics) => Rect.fromLTWH(
    PageDesign.kbX0 + col * metrics.designKeyboardPitch,
    metrics.designKbTopY + row * PageDesign.keyPitch,
    span * metrics.designKeyboardPitch,
    PageDesign.keyH,
  );
}

enum SketchKeyKind {
  text,
  shift,
  backspace,
  enter,
  space,
  toggle,
  cursorLeft,
  cursorRight,
}

/// The exact key rows from paper-codex, per layer.
List<List<SketchKey>> keyboardRows(KeyboardLayer layer) {
  const k = SketchKey.new;
  switch (layer) {
    case KeyboardLayer.letters:
      return [
        [
          k('q', 0),
          k('w', 1),
          k('e', 2),
          k('r', 3),
          k('t', 4),
          k('y', 5),
          k('u', 6),
          k('i', 7),
          k('o', 8),
          k('p', 9),
          k('back', 11, span: 1.45, kind: SketchKeyKind.backspace),
        ],
        [
          k('a', 0.5),
          k('s', 1.5),
          k('d', 2.5),
          k('f', 3.5),
          k('g', 4.5),
          k('h', 5.5),
          k('j', 6.5),
          k('k', 7.5),
          k('l', 8.5),
          k('return', 10.5, span: 1.45, kind: SketchKeyKind.enter),
        ],
        [
          k('shift', 0, span: 1.45, kind: SketchKeyKind.shift),
          k('z', 1.75),
          k('x', 2.75),
          k('c', 3.75),
          k('v', 4.75),
          k('b', 5.75),
          k('n', 6.75),
          k('m', 7.75),
          k(',', 8.75),
          k('.', 9.75),
          k('?', 10.75),
        ],
        [
          k('123', 0, span: 1.15, kind: SketchKeyKind.toggle),
          k('/', 1.35),
          k('space', 2.55, span: 5, kind: SketchKeyKind.space),
          k('-', 7.85),
          k('_', 8.85),
          k('left', 9.95, span: 1, kind: SketchKeyKind.cursorLeft),
          k('right', 11.2, span: 1, kind: SketchKeyKind.cursorRight),
        ],
      ];
    case KeyboardLayer.symbols:
      return [
        [
          k('1', 0),
          k('2', 1),
          k('3', 2),
          k('4', 3),
          k('5', 4),
          k('6', 5),
          k('7', 6),
          k('8', 7),
          k('9', 8),
          k('0', 9),
          k('back', 11, span: 1.45, kind: SketchKeyKind.backspace),
        ],
        [
          k('-', 0),
          k('/', 1),
          k(':', 2),
          k(';', 3),
          k('(', 4),
          k(')', 5),
          k(r'$', 6),
          k('&', 7),
          k('@', 8),
          k('"', 9),
          k('return', 10.5, span: 1.45, kind: SketchKeyKind.enter),
        ],
        [
          k('#+=', 0, span: 1.45, kind: SketchKeyKind.toggle),
          k('.', 1.75),
          k(',', 2.75),
          k('?', 3.75),
          k('!', 4.75),
          k("'", 5.75),
          k('<', 6.75),
          k('>', 7.75),
          k(r'\', 8.75),
          k('*', 9.75),
        ],
        [
          k('abc', 0, span: 1.15, kind: SketchKeyKind.toggle),
          k('space', 2, span: 5, kind: SketchKeyKind.space),
          k('return', 8, span: 1.45, kind: SketchKeyKind.enter),
        ],
      ];
    case KeyboardLayer.moreSymbols:
      return [
        [
          k('[', 0),
          k(']', 1),
          k('{', 2),
          k('}', 3),
          k('#', 4),
          k('%', 5),
          k('^', 6),
          k('*', 7),
          k('+', 8),
          k('=', 9),
          k('back', 11, span: 1.45, kind: SketchKeyKind.backspace),
        ],
        [
          k('_', 0),
          k(r'\', 1),
          k('|', 2),
          k('~', 3),
          k('<', 4),
          k('>', 5),
          k(r'$', 6),
          k('&', 7),
          k('@', 8),
          k('return', 10.5, span: 1.45, kind: SketchKeyKind.enter),
        ],
        [
          k('123', 0, span: 1.45, kind: SketchKeyKind.toggle),
          k('.', 1.75),
          k(',', 2.75),
          k('?', 3.75),
          k('!', 4.75),
          k("'", 5.75),
          k('`', 6.75),
          k('=', 7.75),
        ],
        [
          k('abc', 0, span: 1.15, kind: SketchKeyKind.toggle),
          k('space', 2, span: 5, kind: SketchKeyKind.space),
          k('return', 8, span: 1.45, kind: SketchKeyKind.enter),
        ],
      ];
  }
}

/// The hand-drawn on-screen keyboard. Paints all keys in one CustomPaint;
/// hit-testing maps taps to keys, with a brief pressed fill (fast-class).
final class SketchKeyboard extends StatefulWidget {
  const SketchKeyboard({required this.model, super.key});

  final CodexAppModel model;

  @override
  State<SketchKeyboard> createState() => _SketchKeyboardState();
}

final class _SketchKeyboardState extends State<SketchKeyboard> {
  SketchKey? _pressed;
  int _pressedRow = 0;

  void _onTapDown(TapDownDetails details, PageScale metrics) {
    final design = Offset(
      details.localPosition.dx / metrics.scale,
      details.localPosition.dy / metrics.scale + metrics.designKbTopY,
    );
    final rows = keyboardRows(widget.model.layer);
    for (var row = 0; row < rows.length; row++) {
      for (final key in rows[row]) {
        if (key.rectFor(row, metrics).inflate(4).contains(design)) {
          setState(() {
            _pressed = key;
            _pressedRow = row;
          });
          EinkRefreshRegion.request(
            context,
            refreshClass: RefreshClass.fast,
            reason: 'key.press',
          );
          return;
        }
      }
    }
  }

  void _onTapUp() {
    final key = _pressed;
    if (key == null) {
      return;
    }
    setState(() => _pressed = null);
    final model = widget.model;
    switch (key.kind) {
      case SketchKeyKind.text:
        model.keyTap(key.label);
      case SketchKeyKind.space:
        model.keyTap(' ');
      case SketchKeyKind.backspace:
        model.backspace();
      case SketchKeyKind.enter:
        model.returnKey();
      case SketchKeyKind.shift:
        model.shiftTap();
      case SketchKeyKind.toggle:
        model.layerTap(key.label);
      case SketchKeyKind.cursorLeft:
        model.cursorLeft();
      case SketchKeyKind.cursorRight:
        model.cursorRight();
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = PageScale.of(context);
    final ink = PaperCodexTheme.of(context);
    final heightDesign = metrics.designHeight - metrics.designKbTopY;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _onTapDown(d, metrics),
      onTapUp: (_) => _onTapUp(),
      onTapCancel: () => setState(() => _pressed = null),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(metrics.size.width, metrics.u(heightDesign)),
          painter: _KeyboardPainter(
            metrics: metrics,
            ink: ink,
            layer: widget.model.layer,
            shift: widget.model.shift,
            pressed: _pressed,
            pressedRow: _pressedRow,
          ),
        ),
      ),
    );
  }
}

final class _KeyboardPainter extends CustomPainter {
  _KeyboardPainter({
    required this.metrics,
    required this.ink,
    required this.layer,
    required this.shift,
    required this.pressed,
    required this.pressedRow,
  });

  final PageScale metrics;
  final PaperInk ink;
  final KeyboardLayer layer;
  final ShiftLatch shift;
  final SketchKey? pressed;
  final int pressedRow;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(0, -metrics.u(metrics.designKbTopY));
    final sketch = Sketch(canvas, metrics);
    final rows = keyboardRows(layer);
    for (var row = 0; row < rows.length; row++) {
      for (final key in rows[row]) {
        final rect = key.rectFor(row, metrics);
        final isPressed = identical(key, pressed) && row == pressedRow;
        if (isPressed) {
          canvas.drawRect(
            Rect.fromLTWH(
              metrics.u(rect.left),
              metrics.u(rect.top),
              metrics.u(rect.width),
              metrics.u(rect.height),
            ),
            Paint()..color = ink.softInk.withAlpha(110),
          );
        }
        Glyphs.keyOutline(
          sketch,
          rect,
          fnvSeed(row, key.col.toInt()),
          ink.softInk.withAlpha(215),
        );
        _label(canvas, sketch, rect, key);
      }
    }
  }

  void _label(Canvas canvas, Sketch sketch, Rect rect, SketchKey key) {
    final color =
        key.kind == SketchKeyKind.toggle || key.kind == SketchKeyKind.space
        ? ink.softInk
        : ink.ink;
    switch (key.kind) {
      case SketchKeyKind.shift:
        Glyphs.shiftMark(sketch, rect, shift.index, color);
      case SketchKeyKind.backspace:
        Glyphs.backspaceMark(sketch, rect, color);
      case SketchKeyKind.enter:
        Glyphs.returnMark(sketch, rect, color);
      case SketchKeyKind.space:
        sketch.strokePath(
          [
            Offset(rect.left + 18, rect.top + 33),
            Offset(rect.right - 18, rect.top + 33),
          ],
          1.2,
          color,
        );
      case SketchKeyKind.cursorLeft:
        Glyphs.cursorMark(sketch, rect, -1, color);
      case SketchKeyKind.cursorRight:
        Glyphs.cursorMark(sketch, rect, 1, color);
      case SketchKeyKind.text || SketchKeyKind.toggle:
        var label = key.label;
        if (key.kind == SketchKeyKind.text &&
            layer == KeyboardLayer.letters &&
            shift != ShiftLatch.off &&
            label.length == 1) {
          label = label.toUpperCase();
        }
        final style = PaperType.keyLabel(ink, color: color);
        final painter = TextPainter(
          text: TextSpan(text: label, style: style.toTextStyle()),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.scale(metrics.scale);
        painter.paint(
          canvas,
          Offset(
            rect.left + (rect.width - painter.width) / 2,
            rect.top +
                39 -
                painter.computeDistanceToActualBaseline(
                  TextBaseline.alphabetic,
                ),
          ),
        );
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_KeyboardPainter old) =>
      old.layer != layer ||
      old.shift != shift ||
      old.pressed != pressed ||
      old.pressedRow != pressedRow ||
      old.ink != ink ||
      old.metrics != metrics;
}
