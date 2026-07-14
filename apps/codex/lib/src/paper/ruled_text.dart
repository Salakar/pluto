import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'layout.dart';

/// Text style in design-pixel units.
@immutable
final class RuledStyle {
  const RuledStyle({
    required this.fontFamily,
    required this.size,
    required this.color,
    this.fontWeight = FontWeight.w400,
  });

  final String fontFamily;

  /// Font size in design px.
  final double size;
  final Color color;
  final FontWeight fontWeight;

  /// Space advance: paper-codex uses `0.34 em` rather than the font's space.
  double get spaceWidth => size * 0.34;

  RuledStyle withColor(Color c) => RuledStyle(
    fontFamily: fontFamily,
    size: size,
    color: c,
    fontWeight: fontWeight,
  );

  TextStyle toTextStyle() => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    color: color,
    fontWeight: fontWeight,
    height: 1,
  );

  @override
  bool operator ==(Object other) =>
      other is RuledStyle &&
      other.fontFamily == fontFamily &&
      other.size == size &&
      other.color == color &&
      other.fontWeight == fontWeight;

  @override
  int get hashCode => Object.hash(fontFamily, size, color, fontWeight);
}

/// One word placed on a ruling.
final class PlacedWord {
  PlacedWord({
    required this.text,
    required this.x,
    required this.baseline,
    required this.width,
    required this.line,
    required this.charStart,
    required this.charEnd,
    required this.painter,
  });

  final String text;

  /// Left edge, design px.
  final double x;

  /// Baseline y, design px (always on a ruling).
  final double baseline;
  final double width;
  final int line;

  /// Range in the source text (for caret mapping).
  final int charStart;
  final int charEnd;

  final TextPainter painter;

  double get right => x + width;

  /// Bounding rect (approximate ascent box), design px.
  Rect rectFor(RuledStyle style) =>
      Rect.fromLTWH(x, baseline - style.size, width, style.size * 1.3);

  void paintAt(Canvas canvas, {TextPainter? override}) {
    final p = override ?? painter;
    final dy = p.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    p.paint(canvas, Offset(x, baseline - dy));
  }
}

TextPainter _painterFor(String word, RuledStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: word, style: style.toTextStyle()),
    textDirection: TextDirection.ltr,
  )..layout();
  return painter;
}

/// Word-wrapped text snapped to the page ruling — the Flutter port of
/// `wrapped_text_on_rules`, kept as an inspectable layout so the quill
/// reveal can uncover it word by word.
final class RuledTextLayout {
  RuledTextLayout({
    required this.text,
    required this.style,
    required this.maxWidth,
    required this.firstBaseline,
    this.x = 0,
  }) {
    _layout();
  }

  final String text;
  final RuledStyle style;

  /// Wrap width, design px.
  final double maxWidth;

  /// Baseline of the first line, design px.
  final double firstBaseline;

  /// Left edge, design px.
  final double x;

  final List<PlacedWord> words = [];

  /// Baseline the *next* block would start on, design px.
  late final double nextBaseline;

  int get lineCount => words.isEmpty ? 0 : words.last.line + 1;

  void _layout() {
    var baseline = firstBaseline;
    var line = 0;
    final paragraphs = text.split('\n');
    var charOffset = 0;
    var anyWordOnLine = false;

    for (var p = 0; p < paragraphs.length; p++) {
      final paragraph = paragraphs[p];
      var cx = x;
      anyWordOnLine = false;
      for (final match in RegExp(r'\S+').allMatches(paragraph)) {
        final word = match.group(0)!;
        final painter = _painterFor(word, style);
        final width = painter.width;
        final startX = anyWordOnLine ? cx + style.spaceWidth : cx;
        double placedX;
        if (anyWordOnLine && startX + width > x + maxWidth) {
          baseline += PageDesign.ruleStep;
          line += 1;
          placedX = x;
        } else {
          placedX = startX;
        }
        words.add(
          PlacedWord(
            text: word,
            x: placedX,
            baseline: baseline,
            width: width,
            line: line,
            charStart: charOffset + match.start,
            charEnd: charOffset + match.end,
            painter: painter,
          ),
        );
        cx = placedX + width;
        anyWordOnLine = true;
      }
      // Advance past this paragraph's last line; blank line between
      // paragraphs, matching `wrapped_text_on_rules`.
      if (anyWordOnLine || paragraph.isEmpty) {
        baseline += PageDesign.ruleStep;
        line += 1;
      }
      if (p + 1 < paragraphs.length) {
        baseline += PageDesign.ruleStep;
        line += 1;
      }
      charOffset += paragraph.length + 1;
    }
    if (words.isEmpty) {
      nextBaseline = firstBaseline;
    } else {
      nextBaseline = baseline;
    }
  }

  /// Paints words `[0, upTo)`; null paints everything.
  void paint(Canvas canvas, {int? upTo}) {
    final n = upTo == null ? words.length : upTo.clamp(0, words.length);
    for (var i = 0; i < n; i++) {
      words[i].paintAt(canvas);
    }
  }

  /// Paints one placed word with a substitute color (ink developing).
  void paintWordAs(Canvas canvas, PlacedWord word, Color color) {
    word.paintAt(
      canvas,
      override: _painterFor(word.text, style.withColor(color)),
    );
  }

  /// Caret position for character [caretIndex] into [text]: returns
  /// (x, baseline) in design px.
  ({double x, double baseline}) caretPosition(int caretIndex) {
    if (words.isEmpty) {
      return (x: x, baseline: firstBaseline);
    }
    final i = caretIndex.clamp(0, text.length);
    PlacedWord? before;
    for (final w in words) {
      if (i >= w.charEnd) {
        before = w;
        continue;
      }
      if (i > w.charStart) {
        final prefix = w.text.substring(0, i - w.charStart);
        final width = _painterFor(prefix, style).width;
        return (x: w.x + width, baseline: w.baseline);
      }
      // Caret sits in whitespace before this word.
      break;
    }
    if (before == null) {
      return (x: x, baseline: firstBaseline);
    }
    if (i > before.charEnd) {
      return (x: before.right + style.spaceWidth, baseline: before.baseline);
    }
    return (x: before.right, baseline: before.baseline);
  }
}
