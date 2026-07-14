import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../glyphs.dart';
import '../palette.dart';
import '../responsive_layout.dart';

/// Width of the color sheet in the 954 x 1696 authored coordinate space.
const double colorPanelDesignWidth = 400;

/// Full color-sheet height below the authored 88-dpx status band.
const double colorPanelDesignHeight = 1608;

/// Height and width of every palette choice.
const double colorPanelSwatchDesignSize = 80;

/// Width and height of the direct HSV field.
const double colorPanelHsvDesignSize = 200;

/// Number of columns in every color-panel swatch grid.
const int colorPanelColumnCount = 4;

/// Number of recent colors retained by the panel host.
const int colorPanelRecentCount = 8;

const double _headerDesignHeight = 80;
const double _sectionLabelDesignHeight = 32;
const double _gridDesignWidth =
    colorPanelSwatchDesignSize * colorPanelColumnCount;
const double _grayRailDesignHeight = 80;
const double _captionDesignHeight = 120;

/// A synchronous, fixed-geometry sheet for Ink's complete color system.
///
/// The production palette groups use their canonical data identities directly.
/// [recents] remains document-owned because recent colors need not be members of
/// the default palette. No image decode, file access, isolate work, futures, or
/// animation is performed by this widget or its painters.
final class ColorPanel extends StatelessWidget {
  /// Creates the color sheet.
  const ColorPanel({
    required this.selectedColor,
    required this.recents,
    required this.onClose,
    required this.onColorSelected,
    this.presenterDrivesColor = true,
    this.nativeSwatches = inkNativeSwatches,
    this.developsWellSwatches = inkDevelopsWellSwatches,
    this.highlighterSwatches = inkHighlighterSwatches,
    this.hsvHue,
    this.hsvSaturation,
    this.hsvValue,
    this.selectedGrayLevel,
    super.key,
  }) : assert(nativeSwatches.length == 8),
       assert(developsWellSwatches.length == 24),
       assert(highlighterSwatches.length == 4),
       assert(recents.length <= colorPanelRecentCount),
       assert(hsvHue == null || (hsvHue >= 0 && hsvHue <= 360)),
       assert(
         hsvSaturation == null || (hsvSaturation >= 0 && hsvSaturation <= 1),
       ),
       assert(hsvValue == null || (hsvValue >= 0 && hsvValue <= 1)),
       assert(
         selectedGrayLevel == null ||
             (selectedGrayLevel >= 0 &&
                 selectedGrayLevel <= inkGrayLatticeMaxLevel &&
                 selectedGrayLevel % 2 == 0),
       );

  /// Color currently used by the active drawing tool.
  final Color selectedColor;

  /// Up to eight most recently selected document colors, newest first.
  final List<Color> recents;

  /// Closes this sheet without changing the selected color.
  final VoidCallback onClose;

  /// Receives palette, gray-rail, and direct-HSV selections.
  final ValueChanged<Color> onColorSelected;

  /// Whether the active presenter renders chroma rather than developed gray.
  final bool presenterDrivesColor;

  /// Eight native K/W/C/M/Y/R/G/B pigment states.
  final List<InkPaletteSwatch> nativeSwatches;

  /// Twenty-four collision-safe default colors in 6-by-4 display order.
  final List<InkPaletteSwatch> developsWellSwatches;

  /// Four highlighter-only pale colors.
  final List<InkPaletteSwatch> highlighterSwatches;

  /// Optional custom-field hue override in degrees.
  final double? hsvHue;

  /// Optional custom-field saturation override from zero to one.
  final double? hsvSaturation;

  /// Optional custom-field value override from zero to one.
  final double? hsvValue;

  /// Optional selected gray rail level in the inclusive /30 range.
  final int? selectedGrayLevel;

  @override
  Widget build(BuildContext context) {
    final _ColorPanelScale scale = _ColorPanelScale.of(context);
    final HSVColor selectedHsv = HSVColor.fromColor(selectedColor);
    final double resolvedHue = hsvHue ?? selectedHsv.hue;
    final double resolvedSaturation = hsvSaturation ?? selectedHsv.saturation;
    final double resolvedValue = hsvValue ?? selectedHsv.value;

    return SizedBox(
      width: scale.u(colorPanelDesignWidth),
      height: scale.u(colorPanelDesignHeight),
      child: PaperSurface(
        plateShadow: true,
        radius: 0,
        padding: EdgeInsets.zero,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Color panel',
          child: Column(
            children: <Widget>[
              _ColorPanelHeader(
                selectedColor: selectedColor,
                scale: scale,
                onClose: onClose,
              ),
              _SectionLabel(label: 'NATIVE  K W C M Y R G B', scale: scale),
              _PaletteGrid(
                swatches: nativeSwatches,
                selectedColor: selectedColor,
                presenterDrivesColor: presenterDrivesColor,
                scale: scale,
                keyPrefix: 'native',
                showShortLabels: true,
                onSelected: onColorSelected,
              ),
              _SectionLabel(label: 'DEVELOPS WELL', scale: scale),
              _PaletteGrid(
                swatches: developsWellSwatches,
                selectedColor: selectedColor,
                presenterDrivesColor: presenterDrivesColor,
                scale: scale,
                keyPrefix: 'develops',
                onSelected: onColorSelected,
              ),
              _SectionLabel(label: 'HIGHLIGHT', scale: scale),
              _PaletteGrid(
                swatches: highlighterSwatches,
                selectedColor: selectedColor,
                presenterDrivesColor: presenterDrivesColor,
                scale: scale,
                keyPrefix: 'highlight',
                onSelected: onColorSelected,
              ),
              _SectionLabel(label: 'CUSTOM  HSV', scale: scale),
              _HsvSection(
                selectedColor: selectedColor,
                hue: resolvedHue,
                saturation: resolvedSaturation,
                value: resolvedValue,
                presenterDrivesColor: presenterDrivesColor,
                scale: scale,
                onSelected: onColorSelected,
              ),
              _GrayLatticeRail(
                selectedLevel: selectedGrayLevel,
                scale: scale,
                onSelected: onColorSelected,
              ),
              _SectionLabel(label: 'RECENTS', scale: scale),
              _RecentGrid(
                colors: recents,
                selectedColor: selectedColor,
                presenterDrivesColor: presenterDrivesColor,
                scale: scale,
                onSelected: onColorSelected,
              ),
              if (!presenterDrivesColor) _DevelopCaption(scale: scale),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ColorPanelHeader extends StatelessWidget {
  const _ColorPanelHeader({
    required this.selectedColor,
    required this.scale,
    required this.onClose,
  });

  final Color selectedColor;
  final _ColorPanelScale scale;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: double.infinity,
      height: scale.u(_headerDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            bottom: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: scale.u(_headerDesignHeight),
              child: CustomPaint(
                painter: InkGlyphPainter(
                  glyph: InkGlyph.markColor,
                  color: theme.palette.ink,
                  currentColor: selectedColor,
                  strokeWidth: scale.rule,
                ),
              ),
            ),
            Expanded(
              child: Text(
                'COLOR',
                maxLines: 1,
                style: theme.type.heading.copyWith(
                  color: theme.palette.ink,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            _CloseButton(scale: scale, onPressed: onClose),
          ],
        ),
      ),
    );
  }
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.scale});

  final String label;
  final _ColorPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: scale.u(_gridDesignWidth),
      height: scale.u(_sectionLabelDesignHeight),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          style: theme.type.caption.copyWith(
            color: theme.palette.ink,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.35,
          ),
        ),
      ),
    );
  }
}

final class _PaletteGrid extends StatelessWidget {
  const _PaletteGrid({
    required this.swatches,
    required this.selectedColor,
    required this.presenterDrivesColor,
    required this.scale,
    required this.keyPrefix,
    required this.onSelected,
    this.showShortLabels = false,
  });

  final List<InkPaletteSwatch> swatches;
  final Color selectedColor;
  final bool presenterDrivesColor;
  final _ColorPanelScale scale;
  final String keyPrefix;
  final ValueChanged<Color> onSelected;
  final bool showShortLabels;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: scale.u(_gridDesignWidth),
      height: scale.u(
        colorPanelSwatchDesignSize * (swatches.length ~/ colorPanelColumnCount),
      ),
      child: Column(
        children: <Widget>[
          for (
            int row = 0;
            row < swatches.length ~/ colorPanelColumnCount;
            row += 1
          )
            Row(
              children: <Widget>[
                for (
                  int column = 0;
                  column < colorPanelColumnCount;
                  column += 1
                )
                  _PaletteSwatchCell(
                    key: ValueKey<String>(
                      'color-$keyPrefix-${row * colorPanelColumnCount + column}',
                    ),
                    swatch: swatches[row * colorPanelColumnCount + column],
                    selected:
                        swatches[row * colorPanelColumnCount + column].argb ==
                        selectedColor.toARGB32(),
                    presenterDrivesColor: presenterDrivesColor,
                    scale: scale,
                    showShortLabel: showShortLabels,
                    onSelected: onSelected,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

final class _PaletteSwatchCell extends StatefulWidget {
  const _PaletteSwatchCell({
    required this.swatch,
    required this.selected,
    required this.presenterDrivesColor,
    required this.scale,
    required this.showShortLabel,
    required this.onSelected,
    super.key,
  });

  final InkPaletteSwatch swatch;
  final bool selected;
  final bool presenterDrivesColor;
  final _ColorPanelScale scale;
  final bool showShortLabel;
  final ValueChanged<Color> onSelected;

  @override
  State<_PaletteSwatchCell> createState() => _PaletteSwatchCellState();
}

final class _PaletteSwatchCellState extends State<_PaletteSwatchCell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (value == _pressed) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Color color = Color(widget.swatch.argb);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.swatch.label}, ${widget.swatch.hex}',
      onTap: () => widget.onSelected(color),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: () => widget.onSelected(color),
        child: SizedBox.square(
          dimension: widget.scale.u(colorPanelSwatchDesignSize),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CustomPaint(
                painter: ColorPanelSwatchPainter(
                  color: color,
                  ink: theme.palette.ink,
                  paper: theme.palette.paper,
                  todayGray: widget.presenterDrivesColor
                      ? null
                      : Color(widget.swatch.developedGrayArgb),
                  selected: widget.selected || _pressed,
                  scale: widget.scale.value,
                ),
              ),
              if (widget.showShortLabel)
                Center(
                  child: Text(
                    widget.swatch.label,
                    style: theme.type.heading.copyWith(
                      color: _readableColor(color),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _RecentGrid extends StatelessWidget {
  const _RecentGrid({
    required this.colors,
    required this.selectedColor,
    required this.presenterDrivesColor,
    required this.scale,
    required this.onSelected,
  });

  final List<Color> colors;
  final Color selectedColor;
  final bool presenterDrivesColor;
  final _ColorPanelScale scale;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: scale.u(_gridDesignWidth),
      height: scale.u(colorPanelSwatchDesignSize * 2),
      child: Column(
        children: <Widget>[
          for (int row = 0; row < 2; row += 1)
            Row(
              children: <Widget>[
                for (
                  int column = 0;
                  column < colorPanelColumnCount;
                  column += 1
                )
                  if (row * colorPanelColumnCount + column < colors.length)
                    _RawColorCell(
                      key: ValueKey<String>(
                        'color-recent-${row * colorPanelColumnCount + column}',
                      ),
                      color: colors[row * colorPanelColumnCount + column],
                      label:
                          'Recent color ${row * colorPanelColumnCount + column + 1}',
                      selected:
                          colors[row * colorPanelColumnCount + column]
                              .toARGB32() ==
                          selectedColor.toARGB32(),
                      todayGray: presenterDrivesColor
                          ? null
                          : Color(
                              inkDevelopedGrayArgb(
                                colors[row * colorPanelColumnCount + column]
                                    .toARGB32(),
                              ),
                            ),
                      ink: theme.palette.ink,
                      paper: theme.palette.paper,
                      scale: scale,
                      onSelected: onSelected,
                    )
                  else
                    _EmptyRecentCell(
                      key: ValueKey<String>(
                        'color-recent-empty-${row * colorPanelColumnCount + column}',
                      ),
                      scale: scale,
                    ),
              ],
            ),
        ],
      ),
    );
  }
}

final class _EmptyRecentCell extends StatelessWidget {
  const _EmptyRecentCell({required this.scale, super.key});

  final _ColorPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    return Semantics(
      label: 'Empty recent color slot',
      child: SizedBox.square(
        dimension: scale.u(colorPanelSwatchDesignSize),
        child: CustomPaint(
          painter: _EmptyRecentPainter(
            ink: palette.gray99,
            paper: palette.paper,
            rule: scale.rule,
          ),
        ),
      ),
    );
  }
}

final class _EmptyRecentPainter extends CustomPainter {
  const _EmptyRecentPainter({
    required this.ink,
    required this.paper,
    required this.rule,
  });

  final Color ink;
  final Color paper;
  final double rule;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..color = paper
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds.deflate(rule / 2),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );
    canvas.drawLine(
      Offset(size.width * 0.25, size.height * 0.5),
      Offset(size.width * 0.75, size.height * 0.5),
      Paint()
        ..color = ink
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_EmptyRecentPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.rule != rule;
}

final class _RawColorCell extends StatefulWidget {
  const _RawColorCell({
    required this.color,
    required this.label,
    required this.selected,
    required this.todayGray,
    required this.ink,
    required this.paper,
    required this.scale,
    required this.onSelected,
    super.key,
  });

  final Color color;
  final String label;
  final bool selected;
  final Color? todayGray;
  final Color ink;
  final Color paper;
  final _ColorPanelScale scale;
  final ValueChanged<Color> onSelected;

  @override
  State<_RawColorCell> createState() => _RawColorCellState();
}

final class _RawColorCellState extends State<_RawColorCell> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.label}, ${_hexColor(widget.color)}',
      onTap: () => widget.onSelected(widget.color),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: () => widget.onSelected(widget.color),
        child: SizedBox.square(
          dimension: widget.scale.u(colorPanelSwatchDesignSize),
          child: CustomPaint(
            painter: ColorPanelSwatchPainter(
              color: widget.color,
              ink: widget.ink,
              paper: widget.paper,
              todayGray: widget.todayGray,
              selected: widget.selected || _pressed,
              scale: widget.scale.value,
            ),
          ),
        ),
      ),
    );
  }
}

final class _HsvSection extends StatelessWidget {
  const _HsvSection({
    required this.selectedColor,
    required this.hue,
    required this.saturation,
    required this.value,
    required this.presenterDrivesColor,
    required this.scale,
    required this.onSelected,
  });

  final Color selectedColor;
  final double hue;
  final double saturation;
  final double value;
  final bool presenterDrivesColor;
  final _ColorPanelScale scale;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: scale.u(_gridDesignWidth),
      height: scale.u(colorPanelHsvDesignSize),
      child: Row(
        children: <Widget>[
          _HsvField(
            hue: hue,
            saturation: saturation,
            value: value,
            scale: scale,
            onSelected: onSelected,
          ),
          SizedBox(
            width: scale.u(_gridDesignWidth - colorPanelHsvDesignSize),
            height: scale.u(colorPanelHsvDesignSize),
            child: Padding(
              padding: EdgeInsets.only(left: scale.u(16)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox.square(
                    dimension: scale.u(colorPanelSwatchDesignSize),
                    child: CustomPaint(
                      painter: ColorPanelSwatchPainter(
                        color: selectedColor,
                        ink: theme.palette.ink,
                        paper: theme.palette.paper,
                        todayGray: presenterDrivesColor
                            ? null
                            : Color(
                                inkDevelopedGrayArgb(selectedColor.toARGB32()),
                              ),
                        selected: true,
                        scale: scale.value,
                      ),
                    ),
                  ),
                  SizedBox(height: scale.u(8)),
                  Text(
                    _hexColor(selectedColor),
                    maxLines: 1,
                    style: theme.type.mono.copyWith(
                      color: theme.palette.ink,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    'H ${hue.round()}  S ${(saturation * 100).round()}',
                    maxLines: 1,
                    style: theme.type.mono.copyWith(
                      color: theme.palette.gray33,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    'V ${(value * 100).round()}',
                    maxLines: 1,
                    style: theme.type.mono.copyWith(
                      color: theme.palette.gray33,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _HsvField extends StatelessWidget {
  const _HsvField({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.scale,
    required this.onSelected,
  });

  final double hue;
  final double saturation;
  final double value;
  final _ColorPanelScale scale;
  final ValueChanged<Color> onSelected;

  void _selectAt(Offset localPosition) {
    final double size = scale.u(colorPanelHsvDesignSize);
    final double nextSaturation = (localPosition.dx / size).clamp(0.0, 1.0);
    final double nextValue = 1 - (localPosition.dy / size).clamp(0.0, 1.0);
    onSelected(HSVColor.fromAHSV(1, hue, nextSaturation, nextValue).toColor());
  }

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    return Semantics(
      label:
          'HSV field, hue ${hue.round()}, saturation '
          '${(saturation * 100).round()}, value ${(value * 100).round()}',
      slider: true,
      child: GestureDetector(
        key: const ValueKey<String>('color-hsv-field'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapUp: (TapUpDetails details) => _selectAt(details.localPosition),
        onPanStart: (DragStartDetails details) =>
            _selectAt(details.localPosition),
        onPanUpdate: (DragUpdateDetails details) =>
            _selectAt(details.localPosition),
        child: SizedBox.square(
          dimension: scale.u(colorPanelHsvDesignSize),
          child: CustomPaint(
            painter: _HsvFieldPainter(
              hue: hue,
              saturation: saturation,
              value: value,
              ink: palette.ink,
              paper: palette.paper,
              rule: scale.rule,
            ),
          ),
        ),
      ),
    );
  }
}

final class _GrayLatticeRail extends StatelessWidget {
  const _GrayLatticeRail({
    required this.selectedLevel,
    required this.scale,
    required this.onSelected,
  });

  final int? selectedLevel;
  final _ColorPanelScale scale;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Sixteen notch gray lattice',
      child: SizedBox(
        width: scale.u(_gridDesignWidth),
        height: scale.u(_grayRailDesignHeight),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final int level in inkGrayLatticeLevels)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: selectedLevel == level,
                  label: 'Gray level $level of 30',
                  onTap: () => onSelected(Color(inkGrayArgbForLevel(level))),
                  child: GestureDetector(
                    key: ValueKey<String>('color-gray-$level'),
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: () => onSelected(Color(inkGrayArgbForLevel(level))),
                    child: CustomPaint(
                      painter: _GrayNotchPainter(
                        color: Color(inkGrayArgbForLevel(level)),
                        selected: selectedLevel == level,
                        ink: palette.ink,
                        paper: palette.paper,
                        rule: scale.rule,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _DevelopCaption extends StatelessWidget {
  const _DevelopCaption({required this.scale});

  final _ColorPanelScale scale;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      width: scale.u(_gridDesignWidth),
      height: scale.u(_captionDesignHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.palette.paper,
          border: Border(
            top: BorderSide(color: theme.palette.ink, width: scale.rule),
          ),
        ),
        child: Center(
          child: Text(
            'colors develop after color glass lands — today they present '
            'as these grays',
            maxLines: 3,
            textAlign: TextAlign.center,
            style: theme.type.caption.copyWith(
              color: theme.palette.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Synchronous painter for one palette or recent-color cell.
final class ColorPanelSwatchPainter extends CustomPainter {
  /// Creates a hard-edged color cell with optional gray and selection marks.
  const ColorPanelSwatchPainter({
    required this.color,
    required this.ink,
    required this.paper,
    required this.selected,
    required this.scale,
    this.todayGray,
  });

  /// Authored document color.
  final Color color;

  /// Rule and selection-ring color.
  final Color ink;

  /// Gap and selected-tick backing color.
  final Color paper;

  /// Developed monochrome preview, or null when chroma is driven directly.
  final Color? todayGray;

  /// Whether to draw the three-dpx ink ring and corner tick.
  final bool selected;

  /// Current logical-pixel scale per authored design pixel.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double rule = math.max(1, 2 * scale);
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..color = color
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds.deflate(rule / 2),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );

    final Color? gray = todayGray;
    if (gray != null) {
      final double wedge = 24 * scale;
      final Path grayCorner = Path()
        ..moveTo(size.width - wedge, size.height)
        ..lineTo(size.width, size.height - wedge)
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        grayCorner,
        Paint()
          ..color = gray
          ..isAntiAlias = false,
      );
      canvas.drawLine(
        Offset(size.width - wedge, size.height),
        Offset(size.width, size.height - wedge),
        Paint()
          ..color = ink
          ..strokeWidth = rule
          ..isAntiAlias = false,
      );
    }

    if (!selected) {
      return;
    }
    final double gap = math.max(rule, 3 * scale);
    final double ringWidth = math.max(1, 3 * scale);
    canvas.drawRect(
      bounds.deflate(gap),
      Paint()
        ..color = paper
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, 2 * ringWidth)
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds.deflate(gap),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..isAntiAlias = false,
    );

    final double tickCorner = 24 * scale;
    final Path backing = Path()
      ..moveTo(size.width - tickCorner, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, tickCorner)
      ..close();
    canvas.drawPath(
      backing,
      Paint()
        ..color = paper
        ..isAntiAlias = false,
    );
    final Paint tick = Paint()
      ..color = ink
      ..strokeWidth = ringWidth
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false;
    final Path check = Path()
      ..moveTo(size.width - 17 * scale, 8 * scale)
      ..lineTo(size.width - 12 * scale, 13 * scale)
      ..lineTo(size.width - 5 * scale, 5 * scale);
    canvas.drawPath(check, tick);
  }

  @override
  bool shouldRepaint(ColorPanelSwatchPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.todayGray != todayGray ||
      oldDelegate.selected != selected ||
      oldDelegate.scale != scale;
}

final class _HsvFieldPainter extends CustomPainter {
  const _HsvFieldPainter({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.ink,
    required this.paper,
    required this.rule,
  });

  final double hue;
  final double saturation;
  final double value;
  final Color ink;
  final Color paper;
  final double rule;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    final Color hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[paper, hueColor],
        ).createShader(bounds)
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Color(0xff000000)],
        ).createShader(bounds)
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      bounds.deflate(rule / 2),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );

    final Offset center = Offset(
      saturation * size.width,
      (1 - value) * size.height,
    );
    final double radius = math.max(4, 8 * rule / 2);
    canvas.drawCircle(
      center,
      radius + rule,
      Paint()
        ..color = paper
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule * 2
        ..isAntiAlias = false,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_HsvFieldPainter oldDelegate) =>
      oldDelegate.hue != hue ||
      oldDelegate.saturation != saturation ||
      oldDelegate.value != value ||
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.rule != rule;
}

final class _GrayNotchPainter extends CustomPainter {
  const _GrayNotchPainter({
    required this.color,
    required this.selected,
    required this.ink,
    required this.paper,
    required this.rule,
  });

  final Color color;
  final bool selected;
  final Color ink;
  final Color paper;
  final double rule;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect notch = Rect.fromLTWH(
      0,
      size.height * 0.25,
      size.width,
      size.height * 0.5,
    );
    canvas.drawRect(
      notch,
      Paint()
        ..color = color
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      notch.deflate(rule / 2),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = rule
        ..isAntiAlias = false,
    );
    if (selected) {
      canvas.drawRect(
        notch.deflate(rule * 1.5),
        Paint()
          ..color = paper
          ..style = PaintingStyle.stroke
          ..strokeWidth = rule * 2
          ..isAntiAlias = false,
      );
      canvas.drawRect(
        notch.deflate(rule * 1.5),
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = rule
          ..isAntiAlias = false,
      );
    }
  }

  @override
  bool shouldRepaint(_GrayNotchPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.rule != rule;
}

final class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.scale, required this.onPressed});

  final _ColorPanelScale scale;
  final VoidCallback onPressed;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

final class _CloseButtonState extends State<_CloseButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperPalette palette = PaperTheme.of(context).palette;
    final Color background = _pressed ? palette.ink : palette.paper;
    final Color foreground = _pressed ? palette.paper : palette.ink;
    return Semantics(
      button: true,
      label: 'Close color panel',
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: widget.scale.u(_headerDesignHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border(
                left: BorderSide(color: palette.ink, width: widget.scale.rule),
              ),
            ),
            child: CustomPaint(
              painter: _CloseGlyphPainter(
                color: foreground,
                strokeWidth: widget.scale.rule,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CloseGlyphPainter extends CustomPainter {
  const _CloseGlyphPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect glyph = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width * 0.3,
      height: size.height * 0.3,
    );
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = false;
    canvas.drawLine(glyph.topLeft, glyph.bottomRight, paint);
    canvas.drawLine(glyph.topRight, glyph.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_CloseGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}

final class _ColorPanelScale {
  const _ColorPanelScale(this.value);

  factory _ColorPanelScale.of(BuildContext context) {
    return _ColorPanelScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;

  double get rule => math.max(1, u(2));
}

Color _readableColor(Color background) => background.computeLuminance() > 0.42
    ? const Color(0xff000000)
    : const Color(0xffffffff);

String _hexColor(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
