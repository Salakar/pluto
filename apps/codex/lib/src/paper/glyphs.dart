import 'dart:math' as math;
import 'dart:ui';

import 'layout.dart';
import 'sketch.dart';
import 'theme.dart';

/// Every hand-drawn mark on the page, ported point-for-point from
/// paper-codex `crates/paper-render/src/components/`. Coordinates are design
/// pixels; callers paint through a [Sketch].
///
/// New marks that paper-codex specified but never drew (retry, broken nib,
/// thinking phases) follow the same stroke grammar.
abstract final class Glyphs {
  // --- transcript margin marks -------------------------------------------

  /// The `>` chevron beside a user turn.
  static void marginalUserMark(Sketch s, double x, double y, PaperInk ink) {
    s.strokePath(
      [Offset(x - 28, y - 14), Offset(x - 18, y), Offset(x - 26, y + 16)],
      1.4,
      ink.softInk,
    );
  }

  /// The Archimedean spiral beside a Codex turn.
  static void marginalCodexMark(Sketch s, double x, double y, PaperInk ink) {
    thinkingSpiral(s, x - 22, y - 4, phase: 0, ink: ink.softInk);
  }

  /// The spiral, parameterised so the busy state can breathe: phase 0 is the
  /// resting mark, phase 1 winds slightly tighter and further round.
  static void thinkingSpiral(
    Sketch s,
    double cx,
    double cy, {
    required int phase,
    required Color ink,
  }) {
    final turns = phase == 0 ? 1.6 : 1.85;
    final r0 = phase == 0 ? 3.0 : 2.2;
    final points = <Offset>[];
    for (var idx = 0; idx < 22; idx++) {
      final t = idx / 21.0;
      final a = t * math.pi * 2 * turns;
      final r = r0 + t * 10.0;
      points.add(Offset(cx + math.cos(a) * r, cy + math.sin(a) * r));
    }
    s.strokePath(points, 1.2, ink);
  }

  // --- composer / toolbar marks ------------------------------------------

  static void undoGlyph(Sketch s, double x, double y, Color color) {
    // A curved arrow sweeping back to the left.
    final points = <Offset>[];
    for (var i = 0; i <= 18; i++) {
      final t = i / 18.0;
      final a = -math.pi * 0.15 - t * math.pi * 0.7;
      points.add(Offset(x + 24 + math.cos(a) * 17, y + 24 + math.sin(a) * 15));
    }
    s.strokePath(points, 1.6, color);
    final tip = points.last;
    s.strokePath(
      [Offset(tip.dx + 12, tip.dy - 4), tip, Offset(tip.dx + 6, tip.dy + 11)],
      1.6,
      color,
    );
  }

  static void clearGlyph(Sketch s, double x, double y, Color color) {
    // An eraser block mid-sweep, crumbs behind it.
    s.strokePath(
      [
        Offset(x + 10, y + 26),
        Offset(x + 22, y + 12),
        Offset(x + 42, y + 16),
        Offset(x + 32, y + 32),
        Offset(x + 10, y + 26),
      ],
      1.5,
      color,
    );
    s.strokePath([Offset(x + 22, y + 12), Offset(x + 14, y + 22)], 1.1, color);
    for (var i = 0; i < 3; i++) {
      s.strokePath(
        [
          Offset(x + 2 + i * 4.0, y + 34 + i * 3.0),
          Offset(x + 8 + i * 4.0, y + 35 + i * 3.0),
        ],
        1.2,
        color,
      );
    }
  }

  /// Send: a hand-sketched paper dart. The page itself takes flight.
  static void sendFlourish(
    Sketch s,
    Rect rect, {
    required bool enabled,
    required PaperInk ink,
  }) {
    final color = enabled ? ink.ink : ink.softInk.withAlpha(185);
    final w = rect.width;
    final h = rect.height;
    Offset p(double nx, double ny) =>
        Offset(rect.left + nx * w, rect.top + ny * h);
    final nose = p(0.94, 0.30);
    final tailTop = p(0.08, 0.40);
    final notch = p(0.40, 0.58);
    final tailBot = p(0.24, 0.90);
    s.strokePath([nose, tailTop, notch, nose], enabled ? 1.7 : 1.2, color);
    s.strokePath([nose, notch, tailBot, nose], enabled ? 1.7 : 1.2, color);
    if (enabled) {
      // Ink the lower wing so the dart carries weight on the page.
      s.strokePath(
        [Offset.lerp(notch, nose, 0.25)!, Offset.lerp(tailBot, nose, 0.30)!],
        1.4,
        color,
      );
      s.strokePath(
        [Offset.lerp(notch, nose, 0.55)!, Offset.lerp(tailBot, nose, 0.60)!],
        1.4,
        color,
      );
    }
  }

  // --- keyboard special-key marks ----------------------------------------

  static void backspaceMark(Sketch s, Rect rect, Color color) {
    final x = rect.left + rect.width / 2 - 17;
    final y = rect.top + rect.height / 2;
    s.strokePath(
      [
        Offset(x + 34, y - 10),
        Offset(x + 9, y - 9),
        Offset(x, y),
        Offset(x + 9, y + 10),
        Offset(x + 35, y + 9),
      ],
      1.4,
      color,
    );
    s.strokePath([Offset(x + 18, y - 5), Offset(x + 27, y + 5)], 1.2, color);
  }

  static void returnMark(Sketch s, Rect rect, Color color) {
    final x = rect.left + rect.width / 2 - 16;
    final y = rect.top + rect.height / 2 - 9;
    s.strokePath(
      [Offset(x + 31, y), Offset(x + 31, y + 17), Offset(x + 8, y + 17)],
      1.5,
      color,
    );
    s.strokePath(
      [
        Offset(x + 8, y + 17),
        Offset(x + 16, y + 9),
        Offset(x + 1, y + 17),
        Offset(x + 16, y + 25),
      ],
      1.3,
      color,
    );
  }

  /// Shift chevron; weight deepens with latch state (off/once/lock).
  static void shiftMark(Sketch s, Rect rect, int latch, Color color) {
    final weight = switch (latch) {
      0 => 1.1,
      1 => 1.8,
      _ => 2.5,
    };
    final cx = rect.left + rect.width / 2;
    final y = rect.top + rect.height / 2 - 15;
    s.strokePath(
      [Offset(cx - 13, y + 17), Offset(cx, y), Offset(cx + 13, y + 17)],
      weight,
      color,
    );
    s.strokePath([Offset(cx, y), Offset(cx, y + 31)], weight, color);
  }

  /// Cursor keys: a plain straight arrow — at icon size the sketch wobble
  /// reads as a bent hook, so these three strokes stay ruler-straight.
  static void cursorMark(Sketch s, Rect rect, int dir, Color color) {
    final cx = rect.left + rect.width / 2;
    final cy = rect.top + rect.height / 2;
    final tip = cx + dir * 13.0;
    final tail = cx - dir * 13.0;
    s.line(tail, cy, tip, cy, 3.4, color);
    s.line(tip, cy, tip - dir * 9, cy - 8, 3.4, color);
    s.line(tip, cy, tip - dir * 9, cy + 8, 3.4, color);
  }

  /// Wobbly octagonal key outline with stable per-key jitter
  /// (`keyboard.rs::draw_key_outline`).
  static void keyOutline(Sketch s, Rect rect, int seed, Color color) {
    int w(int idx, int amp) => seededWobble(seed, idx, amp);
    final x = rect.left;
    final y = rect.top;
    final kw = rect.width;
    final kh = rect.height;
    s.strokePath(
      [
        Offset(x + 4 + w(1, 2), y + w(2, 1).toDouble()),
        Offset(x + kw - 5 + w(3, 2), y + 1 + w(4, 1)),
        Offset(x + kw + w(5, 1), y + 8 + w(6, 2)),
        Offset(x + kw - 1 + w(7, 1), y + kh - 6 + w(8, 2)),
        Offset(x + kw - 7 + w(9, 2), y + kh + w(10, 1)),
        Offset(x + 5 + w(11, 2), y + kh - 1 + w(12, 1)),
        Offset(x + w(13, 1).toDouble(), y + kh - 8 + w(14, 2)),
        Offset(x + 1 + w(15, 1), y + 7 + w(16, 2)),
        Offset(x + 4 + w(1, 2), y + w(2, 1).toDouble()),
      ],
      1.15,
      color,
    );
  }

  // --- page furniture ------------------------------------------------------

  static void wavyRule(Sketch s, double x0, double y, double x1, Color color) {
    final points = <Offset>[];
    for (var idx = 0; idx < 48; idx++) {
      final t = idx / 47.0;
      final x = x0 + (x1 - x0) * t;
      final wobble = math.sin(t * math.pi * 2 * 3.0) * 1.6;
      points.add(Offset(x, y + wobble));
    }
    s.strokePath(points, 1.3, color);
  }

  /// The sun-of-rays settings mark (scribbled disc + 7 rays).
  static void settingsMark(Sketch s, PaperInk ink, {Rect? at}) {
    final rect = at ?? PageDesign.settingsMarkRect;
    final color = ink.softInk;
    final cx = rect.left + 22.0;
    final cy = rect.top + 22.0;
    s.scribbleEllipse(cx, cy, 13, 13, color);
    for (var idx = 0; idx < 7; idx++) {
      final a = idx / 7.0 * math.pi * 2;
      s.strokePath(
        [
          Offset(cx + math.cos(a) * 16, cy + math.sin(a) * 16),
          Offset(cx + math.cos(a) * 20, cy + math.sin(a) * 20),
        ],
        1.0,
        color,
      );
    }
  }

  static void shelfTab(Sketch s, PaperInk ink, {Rect? at}) {
    final rect = at ?? PageDesign.shelfTabRect;
    // A stack of page edges peeking in from the right — unmistakably "more
    // pages live here".
    s.line(rect.left, rect.top, rect.left, rect.bottom, 3, ink.softInk);
    s.strokePath(
      [
        Offset(rect.right, rect.top),
        Offset(rect.left + 4, rect.top + 18),
        Offset(rect.left + 4, rect.bottom - 18),
        Offset(rect.right, rect.bottom),
      ],
      1.4,
      ink.softInk,
    );
    for (var i = 0; i < 3; i++) {
      final y = rect.top + 74.0 + i * 40.0;
      s.strokePath(
        [Offset(rect.left + 4, y), Offset(rect.left + 12, y + 1)],
        1.5,
        ink.ink,
      );
    }
    s.strokePath(
      [
        Offset(rect.left + 3, rect.top + 20),
        Offset(rect.left + 13, rect.top + 31),
        Offset(rect.left + 4, rect.top + 31),
        Offset(rect.left + 3, rect.top + 20),
      ],
      1.3,
      ink.softInk,
    );
  }

  // --- mode tabs -----------------------------------------------------------

  static void penGlyph(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x + 14, y + 4),
        Offset(x + 34, y + 27),
        Offset(x + 27, y + 36),
        Offset(x + 7, y + 13),
        Offset(x + 14, y + 4),
      ],
      1.5,
      color,
    );
    s.strokePath(
      [
        Offset(x + 8, y + 42),
        Offset(x + 18, y + 37),
        Offset(x + 28, y + 43),
        Offset(x + 38, y + 38),
      ],
      1.4,
      color,
    );
  }

  static void keyboardGlyph(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x, y + 9),
        Offset(x + 48, y + 8),
        Offset(x + 49, y + 42),
        Offset(x + 1, y + 43),
        Offset(x, y + 9),
      ],
      1.2,
      color,
    );
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 4; col++) {
        final xx = x + 8 + col * 9.0;
        final yy = y + 16 + row * 8.0;
        s.strokePath([Offset(xx, yy), Offset(xx + 4, yy + 1)], 1.0, color);
      }
    }
  }

  // --- todo list -----------------------------------------------------------

  static void checkbox(
    Sketch s,
    double x,
    double y,
    PaperInk ink, {
    bool checked = false,
  }) {
    final color = ink.softInk;
    s.strokePath(
      [
        Offset(x + 1, y - 20),
        Offset(x + 24, y - 19),
        Offset(x + 22, y + 5),
        Offset(x - 1, y + 3),
        Offset(x + 1, y - 20),
      ],
      1.2,
      color,
    );
    s.strokePath(
      [
        Offset(x + 3, y - 18),
        Offset(x + 22, y - 20),
        Offset(x + 24, y + 3),
        Offset(x, y + 5),
      ],
      0.75,
      color.withAlpha(165),
    );
    if (checked) {
      s.strokePath(
        [Offset(x + 4, y - 8), Offset(x + 10, y + 1), Offset(x + 26, y - 24)],
        1.7,
        ink.ink,
      );
    }
  }

  static void marginBracket(
    Sketch s,
    double x,
    double y0,
    double y1,
    PaperInk ink,
  ) {
    final color = ink.softInk;
    s.strokePath(
      [
        Offset(x + 18, y0 + 1),
        Offset(x + 1, y0),
        Offset(x - 1, (y0 + y1) / 2),
        Offset(x, y1),
        Offset(x + 18, y1 - 1),
      ],
      1.2,
      color,
    );
    s.strokePath(
      [
        Offset(x + 16, y0 + 3),
        Offset(x + 3, y0 + 1),
        Offset(x + 2, y1),
        Offset(x + 15, y1 - 2),
      ],
      0.7,
      ink.softInk.withAlpha(170),
    );
  }

  // --- error / recovery marks ---------------------------------------------

  /// Retry: a circular arrow, drawn as one confident loop with a firm
  /// head - reads as "again" at a glance (ERR-004).
  static void retryMark(Sketch s, Rect rect, Color color) {
    final cx = rect.left + rect.width / 2;
    final cy = rect.top + rect.height / 2;
    const r = 14.0;
    final points = <Offset>[];
    for (var i = 0; i <= 30; i++) {
      final t = i / 30.0;
      final a = -math.pi / 3 + t * math.pi * 5 / 3;
      points.add(Offset(cx + math.cos(a) * r, cy + math.sin(a) * r));
    }
    s.strokePath(points, 1.7, color);
    final tip = points.first;
    final prev = points[2];
    final dx = tip.dx - prev.dx;
    final dy = tip.dy - prev.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    final ux = dx / len;
    final uy = dy / len;
    Offset head(double angle) {
      final ca = math.cos(angle);
      final sa = math.sin(angle);
      return Offset(
        tip.dx + (ux * ca - uy * sa) * 11,
        tip.dy + (ux * sa + uy * ca) * 11,
      );
    }

    s.strokePath([head(2.6), tip, head(-2.6)], 1.7, color);
  }

  /// A cracked nib for "codex not found" (ERR-001).
  static void brokenNibMark(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x + 10, y),
        Offset(x + 22, y + 2),
        Offset(x + 18, y + 20),
        Offset(x + 14, y + 20),
        Offset(x + 10, y),
      ],
      1.3,
      color,
    );
    s.strokePath([Offset(x + 16, y + 20), Offset(x + 16, y + 28)], 1.2, color);
    s.strokePath(
      [Offset(x + 15, y + 6), Offset(x + 18, y + 10), Offset(x + 14, y + 14)],
      0.9,
      color,
    );
  }

  // --- goal ribbon marks -----------------------------------------------------

  /// A small hand-drawn triangular pennant on a pole — the page's goal.
  static void flagMark(Sketch s, double x, double y, Color color) {
    s.strokePath([Offset(x + 6, y - 32), Offset(x + 5, y + 4)], 1.6, color);
    s.strokePath(
      [Offset(x + 7, y - 31), Offset(x + 32, y - 22), Offset(x + 7, y - 12)],
      1.5,
      color,
    );
  }

  /// Two firm nib strokes — pause.
  static void pauseMark(Sketch s, Rect rect, Color color) {
    final cx = rect.left + rect.width / 2;
    final cy = rect.top + rect.height / 2;
    s.strokePath(
      [Offset(cx - 6, cy - 11), Offset(cx - 7, cy + 11)],
      1.9,
      color,
    );
    s.strokePath(
      [Offset(cx + 6, cy - 11), Offset(cx + 5, cy + 11)],
      1.9,
      color,
    );
  }

  /// A small open triangle — resume.
  static void playMark(Sketch s, Rect rect, Color color) {
    final cx = rect.left + rect.width / 2;
    final cy = rect.top + rect.height / 2;
    s.strokePath(
      [
        Offset(cx - 7, cy - 11),
        Offset(cx + 9, cy),
        Offset(cx - 8, cy + 11),
        Offset(cx - 7, cy - 11),
      ],
      1.6,
      color,
    );
  }

  /// A little pencil at an angle — edit.
  static void pencilMark(Sketch s, Rect rect, Color color) {
    final x = rect.left + rect.width / 2 - 12;
    final y = rect.top + rect.height / 2 + 10;
    s.strokePath(
      [
        Offset(x, y),
        Offset(x + 5, y + 1),
        Offset(x + 21, y - 15),
        Offset(x + 16, y - 20),
        Offset(x, y),
      ],
      1.3,
      color,
    );
    s.strokePath([Offset(x + 3, y - 4), Offset(x + 6, y - 1)], 1.1, color);
  }

  /// A confident tick — done.
  static void checkMark(Sketch s, Rect rect, Color color) {
    final cx = rect.left + rect.width / 2;
    final cy = rect.top + rect.height / 2;
    s.strokePath(
      [
        Offset(cx - 10, cy + 1),
        Offset(cx - 3, cy + 9),
        Offset(cx + 11, cy - 10),
      ],
      1.9,
      color,
    );
  }

  // --- the mind (model) marks -----------------------------------------------

  /// sol — a small sun: disc + rays.
  static void solMark(Sketch s, double cx, double cy, Color color) {
    s.scribbleEllipse(cx, cy, 9, 9, color);
    for (var i = 0; i < 7; i++) {
      final a = i / 7.0 * math.pi * 2 - math.pi / 2;
      s.strokePath(
        [
          Offset(cx + math.cos(a) * 12, cy + math.sin(a) * 12),
          Offset(cx + math.cos(a) * 17, cy + math.sin(a) * 17),
        ],
        1.2,
        color,
      );
    }
  }

  /// luna — a waxing crescent, drawn full and closed.
  static void lunaMark(Sketch s, double cx, double cy, Color color) {
    final outer = <Offset>[];
    for (var i = 0; i <= 26; i++) {
      final t = i / 26.0;
      final a = -math.pi / 2 + t * math.pi;
      outer.add(Offset(cx - 3 + math.cos(a) * 15, cy + math.sin(a) * 15));
    }
    for (var i = 26; i >= 0; i--) {
      final t = i / 26.0;
      final a = -math.pi / 2 + t * math.pi;
      outer.add(Offset(cx + 3 + math.cos(a) * 11, cy + math.sin(a) * 11));
    }
    outer.add(outer.first);
    s.strokePath(outer, 1.5, color);
  }

  /// terra — a globe: circle, equator, one meridian.
  static void terraMark(Sketch s, double cx, double cy, Color color) {
    s.scribbleEllipse(cx, cy, 12, 12, color);
    s.strokePath(
      [Offset(cx - 11, cy + 1), Offset(cx + 11, cy - 1)],
      1.1,
      color,
    );
    final meridian = <Offset>[];
    for (var i = 0; i <= 16; i++) {
      final t = i / 16.0;
      final a = -math.pi / 2 + t * math.pi;
      meridian.add(Offset(cx + math.sin(a) * 5, cy - math.cos(a) * 12));
    }
    s.strokePath(meridian, 1.1, color);
  }

  /// "as the house set it" — a small home-shaped mark.
  static void houseMark(Sketch s, double cx, double cy, Color color) {
    s.strokePath(
      [
        Offset(cx - 10, cy + 10),
        Offset(cx - 10, cy - 2),
        Offset(cx, cy - 12),
        Offset(cx + 10, cy - 2),
        Offset(cx + 10, cy + 10),
        Offset(cx - 10, cy + 10),
      ],
      1.4,
      color,
    );
  }

  // --- tool footprint marks ---------------------------------------------------

  /// Terminal prompt — a chevron and a short baseline.
  static void terminalMark(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [Offset(x, y - 14), Offset(x + 8, y - 8), Offset(x + 1, y - 2)],
      1.4,
      color,
    );
    s.strokePath([Offset(x + 12, y - 1), Offset(x + 22, y - 1)], 1.3, color);
  }

  /// Magnifier — searched.
  static void magnifierMark(Sketch s, double x, double y, Color color) {
    s.scribbleEllipse(x + 8, y - 12, 7, 7, color);
    s.strokePath([Offset(x + 13, y - 6), Offset(x + 21, y + 2)], 1.6, color);
  }

  /// A page with a folded corner — touched files.
  static void leafMark(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x + 2, y - 20),
        Offset(x + 14, y - 21),
        Offset(x + 19, y - 16),
        Offset(x + 20, y + 2),
        Offset(x + 3, y + 3),
        Offset(x + 2, y - 20),
      ],
      1.2,
      color,
    );
    s.strokePath(
      [Offset(x + 13, y - 21), Offset(x + 14, y - 15), Offset(x + 19, y - 15)],
      1.0,
      color,
    );
  }

  /// A little spanner — tools.
  static void wrenchMark(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x + 3, y - 18),
        Offset(x + 9, y - 12),
        Offset(x + 18, y - 3),
        Offset(x + 15, y + 1),
        Offset(x + 6, y - 8),
        Offset(x, y - 14),
      ],
      1.4,
      color,
    );
    s.scribbleEllipse(x + 3, y - 15, 4, 4, color);
  }

  /// The dog-eared corner drawn on the active shelf card.
  static void dogEar(Sketch s, double x, double y, Color color) {
    s.strokePath(
      [
        Offset(x, y),
        Offset(x + 22, y + 2),
        Offset(x + 2, y + 22),
        Offset(x, y),
      ],
      1.1,
      color,
    );
  }
}
