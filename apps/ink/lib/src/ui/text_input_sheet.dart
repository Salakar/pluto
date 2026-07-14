import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'responsive_layout.dart';

const double _previewBandHeight = 80;
const double _propertyBandHeight = 52;

/// Font families supported by editable Ink text blocks.
enum InkTextFontFamily {
  /// Proportional Inter text.
  inter('Inter', 'Inter'),

  /// Monospaced JetBrains Mono text.
  jetBrainsMono('JetBrains Mono', 'Mono');

  const InkTextFontFamily(this.fontFamily, this.shortLabel);

  /// Flutter font-family name used to render the block and preview.
  final String fontFamily;

  /// Compact value shown in the sheet property band.
  final String shortLabel;
}

/// Bottom text-entry sheet backed by the four-layer [PaperKeyboard].
///
/// Text editing and layout are synchronous. The widget performs no image
/// decoding, file access, isolate work, animation, or delayed callbacks.
final class TextInputSheet extends StatefulWidget {
  /// Creates an editable text sheet.
  const TextInputSheet({
    required this.initialText,
    required this.font,
    required this.fontSizeDesignPx,
    required this.fontWeight,
    required this.currentColor,
    required this.onDone,
    this.onChanged,
    super.key,
  }) : assert(fontSizeDesignPx >= 16 && fontSizeDesignPx <= 96);

  /// Text shown when the sheet first opens.
  final String initialText;

  /// Chosen proportional or monospaced family.
  final InkTextFontFamily font;

  /// Authored text size in the specified 16-96 dpx range.
  final double fontSizeDesignPx;

  /// Chosen weight in the specified w500-w800 range.
  final FontWeight fontWeight;

  /// Current drawing color used for preview and rasterization.
  final Color currentColor;

  /// Receives each locally edited value, if the host wants live metadata.
  final ValueChanged<String>? onChanged;

  /// Commits the current text when the keyboard's Done key is pressed.
  final ValueChanged<String> onDone;

  @override
  State<TextInputSheet> createState() => _TextInputSheetState();
}

final class _TextInputSheetState extends State<TextInputSheet> {
  late String _text = widget.initialText;

  @override
  void didUpdateWidget(TextInputSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialText != widget.initialText &&
        widget.initialText != _text) {
      _text = widget.initialText;
    }
  }

  void _replaceText(String value) {
    if (value == _text) {
      return;
    }
    setState(() => _text = value);
    widget.onChanged?.call(value);
  }

  void _append(String value) => _replaceText('$_text$value');

  void _backspace() {
    if (_text.isEmpty) {
      return;
    }
    _replaceText(_text.substring(0, _text.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final _TextSheetScale scale = _TextSheetScale.of(context);
    final PaperThemeData theme = PaperTheme.of(context);
    final String preview = _text.isEmpty ? 'Tap keys to begin…' : _text;
    final Color previewColor = _text.isEmpty
        ? theme.palette.gray66
        : widget.currentColor;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Text input sheet',
      child: ColoredBox(
        color: theme.palette.paper,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: _previewBandHeight,
              width: double.infinity,
              child: CustomPaint(
                painter: _TextSheetChromePainter(
                  ink: theme.palette.ink,
                  paper: theme.palette.paper,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: previewColor,
                        fontFamily: widget.font.fontFamily,
                        fontFamilyFallback: const <String>[
                          'Arial',
                          'Menlo',
                          'sans-serif',
                        ],
                        fontSize: math.max(
                          12,
                          scale.u(widget.fontSizeDesignPx),
                        ),
                        fontWeight: widget.fontWeight,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: _propertyBandHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: _TextProperty(
                      label: 'FONT',
                      value: widget.font.shortLabel,
                    ),
                  ),
                  Expanded(
                    child: _TextProperty(
                      label: 'SIZE',
                      value: '${widget.fontSizeDesignPx.round()} dpx',
                    ),
                  ),
                  Expanded(
                    child: _TextProperty(
                      label: 'WEIGHT',
                      value: '${widget.fontWeight.value}',
                    ),
                  ),
                  Expanded(
                    child: _CurrentColorProperty(color: widget.currentColor),
                  ),
                ],
              ),
            ),
            PaperKeyboard(
              submitLabel: 'Done',
              onText: _append,
              onBackspace: _backspace,
              onSubmit: () => widget.onDone(_text),
            ),
          ],
        ),
      ),
    );
  }
}

final class _TextProperty extends StatelessWidget {
  const _TextProperty({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return CustomPaint(
      painter: _PropertyCellPainter(color: theme.palette.ink),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              style: theme.type.caption.copyWith(
                color: theme.palette.gray66,
                fontSize: 12,
                height: 1,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.mono.copyWith(
                color: theme.palette.ink,
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _CurrentColorProperty extends StatelessWidget {
  const _CurrentColorProperty({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return CustomPaint(
      painter: _PropertyCellPainter(color: theme.palette.ink),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'COLOR',
                    maxLines: 1,
                    style: theme.type.caption.copyWith(
                      color: theme.palette.gray66,
                      fontSize: 12,
                      height: 1,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'current',
                    maxLines: 1,
                    style: theme.type.mono.copyWith(
                      color: theme.palette.ink,
                      fontSize: 12,
                      height: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            CustomPaint(
              painter: _CurrentColorPainter(color: color),
              child: const SizedBox.square(dimension: 28),
            ),
          ],
        ),
      ),
    );
  }
}

final class _TextSheetChromePainter extends CustomPainter {
  const _TextSheetChromePainter({required this.ink, required this.paper});

  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    // Bound to the sheet's rect — `canvas.drawColor` fills the whole canvas.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = paper
        ..isAntiAlias = false,
    );
    final Paint rule = Paint()
      ..color = ink
      ..strokeWidth = 2
      ..isAntiAlias = false;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), rule);
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      rule,
    );
  }

  @override
  bool shouldRepaint(_TextSheetChromePainter oldDelegate) {
    return oldDelegate.ink != ink || oldDelegate.paper != paper;
  }
}

final class _PropertyCellPainter extends CustomPainter {
  const _PropertyCellPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint rule = Paint()
      ..color = color
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, size.height),
      rule,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      rule,
    );
  }

  @override
  bool shouldRepaint(_PropertyCellPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

final class _CurrentColorPainter extends CustomPainter {
  const _CurrentColorPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect swatch = Offset.zero & size;
    canvas.drawRect(
      swatch.deflate(2),
      Paint()
        ..color = color
        ..isAntiAlias = false,
    );
    canvas.drawRect(
      swatch.deflate(1),
      Paint()
        ..color = const Color(0xff000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_CurrentColorPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

final class _TextSheetScale {
  const _TextSheetScale(this.value);

  factory _TextSheetScale.of(BuildContext context) {
    return _TextSheetScale(inkViewportFitScaleOf(context));
  }

  final double value;

  double u(double designPx) => designPx * value;
}

/// Returns the minimal translation that places [content] inside [visible].
///
/// The calculation has no framework or time dependency and is suitable for
/// unit tests and pointer-time text placement. If the content is larger than
/// the visible bounds on an axis, its leading edge is aligned to that axis.
Offset panRectIntoVisibleBounds({
  required Rect content,
  required Rect visible,
}) {
  if (visible.isEmpty) {
    return Offset.zero;
  }

  var dx = 0.0;
  if (content.width > visible.width || content.left < visible.left) {
    dx = visible.left - content.left;
  } else if (content.right > visible.right) {
    dx = visible.right - content.right;
  }

  var dy = 0.0;
  if (content.height > visible.height || content.top < visible.top) {
    dy = visible.top - content.top;
  } else if (content.bottom > visible.bottom) {
    dy = visible.bottom - content.bottom;
  }
  return Offset(dx, dy);
}

/// Computes text-block auto-pan for a bottom keyboard occlusion.
///
/// [obscuredHeight] includes the keyboard and any sheet chrome above it.
/// [topInset] reserves the editor status band. The returned offset can be
/// added directly to the canvas view translation before presenting the sheet.
Offset keyboardOcclusionAutoPan({
  required Rect blockBounds,
  required Size viewportSize,
  required double obscuredHeight,
  double topInset = 0,
  double padding = 16,
}) {
  if (viewportSize.isEmpty ||
      !obscuredHeight.isFinite ||
      !topInset.isFinite ||
      !padding.isFinite) {
    return Offset.zero;
  }
  final double safePadding = math.max(0, padding);
  final double visibleTop = math.min(
    viewportSize.height,
    math.max(0, topInset) + safePadding,
  );
  final double visibleBottom = math.max(
    visibleTop,
    viewportSize.height - math.max(0, obscuredHeight) - safePadding,
  );
  final double visibleLeft = math.min(viewportSize.width, safePadding);
  final double visibleRight = math.max(
    visibleLeft,
    viewportSize.width - safePadding,
  );
  return panRectIntoVisibleBounds(
    content: blockBounds,
    visible: Rect.fromLTRB(
      visibleLeft,
      visibleTop,
      visibleRight,
      visibleBottom,
    ),
  );
}
