import 'package:flutter/widgets.dart';

import 'layout.dart';
import 'ruled_text.dart';

/// The paper-codex palette, tuned for e-ink: mid-grays dither into sparse
/// noise on the panel, so everything meant to be read is solid ink or a
/// deep soft-ink; only the page furniture (rules) stays genuinely faint.
/// Blue is user ink and nothing else.
@immutable
final class PaperInk {
  const PaperInk({
    required this.paper,
    required this.ink,
    required this.softInk,
    required this.rule,
    required this.faintRule,
    required this.userInk,
  });

  const PaperInk.color()
    : this(
        paper: const Color(0xFFFCFBF7),
        ink: const Color(0xFF141715),
        softInk: const Color(0xFF343835),
        rule: const Color(0xFF8E8971),
        faintRule: const Color(0xC8C9C4B0),
        userInk: const Color(0xFF1D3E74),
      );

  const PaperInk.mono()
    : this(
        paper: const Color(0xFFFDFDFD),
        ink: const Color(0xFF0F0F0F),
        softInk: const Color(0xFF303030),
        rule: const Color(0xFF7A7A7A),
        faintRule: const Color(0xC8BDBDBD),
        userInk: const Color(0xFF161616),
      );

  final Color paper;
  final Color ink;
  final Color softInk;
  final Color rule;
  final Color faintRule;
  final Color userInk;

  /// A veil for overlays: paper at high alpha (dark scrims ghost on e-ink).
  Color get veil => paper.withAlpha(0xD9);
}

abstract final class PaperFonts {
  static const String serif = 'EBGaramond';
  static const String hand = 'Caveat';
  static const String mono = 'JetBrainsMono';
}

/// Type roles. Weights run heavy on purpose: 400-weight glyphs thin out to
/// broken gray on the panel; 600-weight Caveat / 500-weight Garamond render
/// as solid ink strokes.
abstract final class PaperType {
  /// Codex body text.
  static RuledStyle serifBody(PaperInk ink) => RuledStyle(
    fontFamily: PaperFonts.serif,
    size: PageDesign.serifBody,
    color: ink.ink,
    fontWeight: FontWeight.w500,
  );

  /// User ink (typed) and page titles.
  static RuledStyle hand(PaperInk ink, {Color? color, double? size}) =>
      RuledStyle(
        fontFamily: PaperFonts.hand,
        size: size ?? PageDesign.handBody,
        color: color ?? ink.userInk,
        fontWeight: FontWeight.w600,
      );

  /// Marginal notes (errors, footprints, hints).
  static RuledStyle note(PaperInk ink, {Color? color, double? size}) =>
      RuledStyle(
        fontFamily: PaperFonts.hand,
        size: size ?? PageDesign.noteLabel,
        color: color ?? ink.softInk,
        fontWeight: FontWeight.w600,
      );

  /// The "paper codex" wordmark and serif labels.
  static RuledStyle wordmark(PaperInk ink) => RuledStyle(
    fontFamily: PaperFonts.serif,
    size: PageDesign.wordmark,
    color: ink.softInk,
    fontWeight: FontWeight.w600,
  );

  /// Keyboard key labels.
  static RuledStyle keyLabel(PaperInk ink, {Color? color}) => RuledStyle(
    fontFamily: PaperFonts.serif,
    size: PageDesign.keyLabel,
    color: color ?? ink.ink,
    fontWeight: FontWeight.w600,
  );

  /// Todo items (hand lettering on the ruling).
  static RuledStyle todo(PaperInk ink) => RuledStyle(
    fontFamily: PaperFonts.hand,
    size: PageDesign.todoLabel,
    color: ink.ink,
    fontWeight: FontWeight.w600,
  );

  /// Code lines.
  static TextStyle mono(PaperInk ink, {Color? color}) => TextStyle(
    fontFamily: PaperFonts.mono,
    fontSize: PageDesign.monoBody,
    color: color ?? ink.ink,
    fontWeight: FontWeight.w500,
    height: 1,
  );
}

/// Inherited theme carrying the ink palette.
final class PaperCodexTheme extends InheritedWidget {
  const PaperCodexTheme({required this.ink, required super.child, super.key});

  final PaperInk ink;

  static PaperInk of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<PaperCodexTheme>();
    return theme?.ink ?? const PaperInk.color();
  }

  @override
  bool updateShouldNotify(PaperCodexTheme oldWidget) => ink != oldWidget.ink;
}
