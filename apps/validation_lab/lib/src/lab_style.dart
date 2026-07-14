import 'package:flutter/widgets.dart';

/// Primary ink color for lab chrome and content.
const Color labInk = Color(0xFF000000);

/// Paper white background.
const Color labPaper = Color(0xFFFFFFFF);

/// Light structural gray for fills.
const Color labGrayLight = Color(0xFFEEEEEE);

/// Mid structural gray for inactive marks.
const Color labGrayMid = Color(0xFF999999);

/// Dark secondary-text gray.
const Color labGrayDark = Color(0xFF333333);

const List<String> _uiFontFallbacks = <String>[
  'Arial',
  'Helvetica',
  'sans-serif',
];

const List<String> _monoFontFallbacks = <String>[
  'Menlo',
  'Courier',
  'monospace',
];

/// Display-size type for scene headlines.
const TextStyle labDisplayStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 40,
  height: 1.2,
  fontWeight: FontWeight.w700,
  color: labInk,
);

/// Page-title type.
const TextStyle labTitleStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 28,
  height: 1.3,
  fontWeight: FontWeight.w700,
  color: labInk,
);

/// Section-heading type.
const TextStyle labHeadingStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 20,
  height: 1.4,
  fontWeight: FontWeight.w600,
  color: labInk,
);

/// Body type.
const TextStyle labBodyStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 16,
  height: 1.5,
  fontWeight: FontWeight.w500,
  color: labInk,
);

/// Button and metadata label type.
const TextStyle labLabelStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 14,
  height: 1.4,
  fontWeight: FontWeight.w600,
  color: labInk,
);

/// Caption type for annotations.
const TextStyle labCaptionStyle = TextStyle(
  fontFamily: 'Inter',
  fontFamilyFallback: _uiFontFallbacks,
  fontSize: 12,
  height: 1.3,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.2,
  color: labInk,
);

/// Monospace type for technical readouts.
const TextStyle labMonoStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: _monoFontFallbacks,
  fontSize: 14,
  height: 1.4,
  fontWeight: FontWeight.w500,
  color: labInk,
);

/// White-on-ink monospace type for the corner banner and HUD.
const TextStyle labBannerStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: _monoFontFallbacks,
  fontSize: 12,
  height: 1.2,
  fontWeight: FontWeight.w600,
  color: labPaper,
);

/// Chunky lab border.
const BoxBorder labBorder = Border.fromBorderSide(
  BorderSide(width: 3, color: labInk),
);

/// Standard two-pixel rule border.
const BoxBorder labRuleBorder = Border.fromBorderSide(
  BorderSide(width: 2, color: labInk),
);

/// Hairline rule border.
const BoxBorder labHairlineBorder = Border.fromBorderSide(
  BorderSide(width: 1, color: labInk),
);

/// Compact page header naming a scene and the behavior it exercises.
final class SceneHeader extends StatelessWidget {
  /// Creates a scene header.
  const SceneHeader({required this.title, required this.purpose, super.key});

  /// Scene name, rendered as the leading heading.
  final String title;

  /// Short note on the renderer behavior under test.
  final String purpose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: const BoxDecoration(
        color: labPaper,
        border: Border(bottom: BorderSide(width: 3, color: labInk)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(child: Text(title, style: labHeadingStyle)),
          Text(purpose, style: labCaptionStyle, textAlign: TextAlign.right),
        ],
      ),
    );
  }
}

/// Chunky corner button driven by raw pointer events.
///
/// Uses a [Listener] instead of a gesture recognizer so it keeps working
/// underneath the manual-mode navigation tap layer, which would otherwise
/// win the gesture arena.
final class LabCornerButton extends StatelessWidget {
  /// Creates a corner button.
  const LabCornerButton({
    required this.label,
    required this.onPressed,
    this.inverted = false,
    super.key,
  });

  /// Button caption.
  final String label;

  /// Called on pointer down.
  final VoidCallback onPressed;

  /// Whether to render ink-on-paper inverted (paper-on-ink).
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent event) => onPressed(),
      child: Container(
        alignment: Alignment.center,
        constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: inverted ? labInk : labPaper,
          border: labBorder,
        ),
        child: Text(
          label,
          style: inverted
              ? const TextStyle(
                  fontFamily: 'Inter',
                  fontFamilyFallback: _uiFontFallbacks,
                  fontSize: 14,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: labPaper,
                )
              : labLabelStyle,
        ),
      ),
    );
  }
}
