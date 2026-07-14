import 'package:flutter/widgets.dart';

/// Inherited design tokens for the Pluto paper UI.
final class PaperTheme extends InheritedWidget {
  /// Creates a paper theme with [data].
  const PaperTheme({required this.data, required super.child, super.key});

  /// Design tokens available to descendants.
  final PaperThemeData data;

  /// Returns the nearest [PaperThemeData], or the default color-panel theme.
  static PaperThemeData of(BuildContext context) {
    final PaperTheme? theme = context
        .dependOnInheritedWidgetOfExactType<PaperTheme>();
    return theme?.data ?? const PaperThemeData(isColorPanel: true);
  }

  /// Four logical-pixel spacing token.
  static const double space4 = PaperSpacing.space4;

  /// Eight logical-pixel spacing token.
  static const double space8 = PaperSpacing.space8;

  /// Twelve logical-pixel spacing token.
  static const double space12 = PaperSpacing.space12;

  /// Sixteen logical-pixel spacing token.
  static const double space16 = PaperSpacing.space16;

  /// Twenty logical-pixel spacing token.
  static const double space20 = PaperSpacing.space20;

  /// Twenty-four logical-pixel spacing token.
  static const double space24 = PaperSpacing.space24;

  /// Thirty-two logical-pixel spacing token.
  static const double space32 = PaperSpacing.space32;

  /// Forty-eight logical-pixel spacing token.
  static const double space48 = PaperSpacing.space48;

  /// Page margin in logical pixels.
  static const double pageMargin = PaperSpacing.pageMargin;

  /// Grid gutter in logical pixels.
  static const double gutter = PaperSpacing.gutter;

  /// Minimum touch target in logical pixels.
  static const double touchTargetMin = PaperSpacing.touchTargetMin;

  /// Thinnest visible rule in logical pixels.
  static const double hairline = PaperSpacing.hairline;

  /// Standard rule thickness in logical pixels.
  static const double rule = PaperSpacing.rule;

  /// Heavy rule thickness in logical pixels.
  static const double heavyRule = PaperSpacing.heavyRule;

  /// Default radius for paper surfaces.
  static const double radius = PaperSpacing.radius;

  /// Dialog radius in logical pixels.
  static const double radiusDialog = PaperSpacing.radiusDialog;

  /// Display text style token from the default theme.
  static TextStyle get display =>
      const PaperThemeData(isColorPanel: true).type.display;

  /// Page title text style token from the default theme.
  static TextStyle get title =>
      const PaperThemeData(isColorPanel: true).type.title;

  /// Section heading text style token from the default theme.
  static TextStyle get heading =>
      const PaperThemeData(isColorPanel: true).type.heading;

  /// Body text style token from the default theme.
  static TextStyle get body =>
      const PaperThemeData(isColorPanel: true).type.body;

  /// Label text style token from the default theme.
  static TextStyle get label =>
      const PaperThemeData(isColorPanel: true).type.label;

  /// Caption text style token from the default theme.
  static TextStyle get caption =>
      const PaperThemeData(isColorPanel: true).type.caption;

  /// Monospace metadata text style token from the default theme.
  static TextStyle get mono =>
      const PaperThemeData(isColorPanel: true).type.mono;

  @override
  bool updateShouldNotify(PaperTheme oldWidget) => data != oldWidget.data;
}

/// Immutable paper design tokens.
@immutable
final class PaperThemeData {
  /// Creates paper tokens for a color or monochrome panel.
  const PaperThemeData({required this.isColorPanel, this.textScale = 1.0});

  /// Whether accent colors may render as color in settled states.
  final bool isColorPanel;

  /// Accessibility text scale multiplier supported by the launcher.
  final double textScale;

  /// Fixed spacing and rule tokens.
  PaperSpacing get spacing => const PaperSpacing();

  /// Palette tokens with accents resolved for the panel class.
  PaperPalette get palette => PaperPalette(isColorPanel: isColorPanel);

  /// Typography tokens scaled by [textScale].
  PaperTypography get type => PaperTypography(textScale: textScale);

  /// Returns a copy with selected fields replaced.
  PaperThemeData copyWith({bool? isColorPanel, double? textScale}) {
    return PaperThemeData(
      isColorPanel: isColorPanel ?? this.isColorPanel,
      textScale: textScale ?? this.textScale,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PaperThemeData &&
            other.isColorPanel == isColorPanel &&
            other.textScale == textScale;
  }

  @override
  int get hashCode => Object.hash(isColorPanel, textScale);
}

/// Fixed layout, spacing, and rule tokens from doc 06 section 4.2.
@immutable
final class PaperSpacing {
  /// Creates spacing tokens.
  const PaperSpacing();

  /// Four logical-pixel spacing token.
  static const double space4 = 4;

  /// Eight logical-pixel spacing token.
  static const double space8 = 8;

  /// Twelve logical-pixel spacing token.
  static const double space12 = 12;

  /// Sixteen logical-pixel spacing token.
  static const double space16 = 16;

  /// Twenty logical-pixel spacing token.
  static const double space20 = 20;

  /// Twenty-four logical-pixel spacing token.
  static const double space24 = 24;

  /// Thirty-two logical-pixel spacing token.
  static const double space32 = 32;

  /// Forty-eight logical-pixel spacing token.
  static const double space48 = 48;

  /// Page margin in logical pixels.
  static const double pageMargin = 20;

  /// Grid gutter in logical pixels.
  static const double gutter = 16;

  /// Minimum touch target in logical pixels.
  static const double touchTargetMin = 48;

  /// Hairline rule thickness.
  static const double hairline = 1;

  /// Standard rule thickness.
  static const double rule = 2;

  /// Heavy rule thickness.
  static const double heavyRule = 4;

  /// Default paper radius. Paper surfaces are square.
  static const double radius = 0;

  /// Sole rounded-surface exception for dialogs and sheets.
  static const double radiusDialog = 8;
}

/// Quantized monochrome palette plus Gallery 3 accent tokens.
@immutable
final class PaperPalette {
  /// Creates a palette for a color or monochrome panel.
  const PaperPalette({required this.isColorPanel});

  /// Whether accent colors should resolve to color instead of ink.
  final bool isColorPanel;

  /// Primary ink.
  Color get ink => const Color(0xFF000000);

  /// Secondary text gray.
  Color get gray33 => const Color(0xFF333333);

  /// Disabled text and icons.
  Color get gray66 => const Color(0xFF666666);

  /// Decorative rule gray.
  Color get gray99 => const Color(0xFF999999);

  /// Field fill gray.
  Color get grayDD => const Color(0xFFDDDDDD);

  /// Paper background.
  Color get paper => const Color(0xFFFFFFFF);

  /// Settled-state blue accent, or ink on monochrome panels.
  Color get accentBlue =>
      isColorPanel ? const Color(0xFF1A4FA0) : const Color(0xFF000000);

  /// Settled-state destructive accent, or ink on monochrome panels.
  Color get accentRed =>
      isColorPanel ? const Color(0xFFB3261E) : const Color(0xFF000000);

  /// Settled-state yellow accent, or ink on monochrome panels.
  Color get accentYellow =>
      isColorPanel ? const Color(0xFFE8A800) : const Color(0xFF000000);
}

/// Typography scale from doc 06 section 4.3.
@immutable
final class PaperTypography {
  /// Creates type tokens, optionally scaled for accessibility.
  const PaperTypography({this.textScale = 1.0});

  /// Accessibility scale applied to font sizes.
  final double textScale;

  static const List<String> _uiFallbacks = <String>[
    'Arial',
    'Helvetica',
    'sans-serif',
  ];
  static const List<String> _monoFallbacks = <String>[
    'Menlo',
    'Courier',
    'monospace',
  ];

  TextStyle _style({
    required double size,
    required double lineHeight,
    required FontWeight weight,
    required String family,
    required List<String> fallbacks,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontFamily: family,
      fontFamilyFallback: fallbacks,
      fontSize: size * textScale,
      height: lineHeight / size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      color: const Color(0xFF000000),
    );
  }

  /// First-run and sleep-screen display style.
  TextStyle get display => _style(
    size: 40,
    lineHeight: 48,
    weight: FontWeight.w700,
    family: 'Inter',
    fallbacks: _uiFallbacks,
  );

  /// Page title style.
  TextStyle get title => _style(
    size: 28,
    lineHeight: 36,
    weight: FontWeight.w700,
    family: 'Inter',
    fallbacks: _uiFallbacks,
  );

  /// Section heading and dialog title style.
  TextStyle get heading => _style(
    size: 20,
    lineHeight: 28,
    weight: FontWeight.w600,
    family: 'Inter',
    fallbacks: _uiFallbacks,
  );

  /// Default body style.
  TextStyle get body => _style(
    size: 16,
    lineHeight: 24,
    weight: FontWeight.w500,
    family: 'Inter',
    fallbacks: _uiFallbacks,
  );

  /// Tile, button, and metadata label style.
  TextStyle get label => _style(
    size: 14,
    lineHeight: 20,
    weight: FontWeight.w600,
    family: 'Inter',
    fallbacks: _uiFallbacks,
  );

  /// Status bar and badge caption style.
  TextStyle get caption => _style(
    size: 12,
    lineHeight: 16,
    weight: FontWeight.w600,
    family: 'Inter',
    fallbacks: _uiFallbacks,
    letterSpacing: 0.2,
  );

  /// Technical metadata style.
  TextStyle get mono => _style(
    size: 14,
    lineHeight: 20,
    weight: FontWeight.w500,
    family: 'JetBrains Mono',
    fallbacks: _monoFallbacks,
  );

  /// App-tile monogram style with a single shared scale.
  TextStyle get monogram => _style(
    size: 34,
    lineHeight: 40,
    weight: FontWeight.w600,
    family: 'Inter',
    fallbacks: _uiFallbacks,
    letterSpacing: 1,
  );
}
