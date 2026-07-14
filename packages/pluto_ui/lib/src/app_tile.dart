import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';

import 'components.dart';
import 'paper_theme.dart';
import 'refresh.dart';

/// Visual state for an app tile.
enum AppTileState {
  /// Normal idle tile.
  idle,

  /// Pen hover outline.
  hover,

  /// Fast-class pressed inversion.
  pressed,

  /// App launch in progress.
  launching,

  /// App install in progress.
  installing,

  /// Manifest or runtime is invalid.
  broken,

  /// App update in progress.
  updating,
}

/// Tile data consumed by [AppTile].
@immutable
final class PaperAppTileData {
  /// Creates app tile data.
  const PaperAppTileData({
    required this.id,
    required this.name,
    this.version,
    this.subtitle,
    this.iconBytes,
    this.isSystem = false,
    this.isPinned = false,
    this.isBroken = false,
  });

  /// Stable app id.
  final String id;

  /// Display name.
  final String name;

  /// Optional version.
  final String? version;

  /// Optional subtitle or state caption.
  final String? subtitle;

  /// Manifest-declared icon artwork, already loaded from the installed app.
  /// The image is treated as an alpha mask and recolored for tile state.
  final Uint8List? iconBytes;

  /// Whether this is the pinned stock reMarkable system tile.
  final bool isSystem;

  /// Whether this app is pinned to the front.
  final bool isPinned;

  /// Whether this app is broken.
  final bool isBroken;
}

/// Launcher app tile with icon, label, state, and e-ink feedback.
final class AppTile extends StatefulWidget {
  /// Creates an app tile.
  const AppTile({
    required this.app,
    required this.onLaunch,
    required this.onManage,
    this.state = AppTileState.idle,
    this.progress,
    super.key,
  });

  /// App tile data.
  final PaperAppTileData app;

  /// Tap callback.
  final VoidCallback onLaunch;

  /// Long-press management callback.
  final VoidCallback onManage;

  /// Visual state.
  final AppTileState state;

  /// Install/update progress from 0 to 1.
  final double? progress;

  @override
  State<AppTile> createState() => _AppTileState();
}

final class _AppTileState extends State<AppTile> {
  bool _pressed = false;

  bool get _isPressed => _pressed || widget.state == AppTileState.pressed;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'tile.press',
    );
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final PaperPalette palette = theme.palette;
    final bool stateInverted = _isPressed;
    final Color background = stateInverted ? palette.ink : palette.paper;
    final Color foreground = stateInverted ? palette.paper : palette.ink;
    final String label = switch (widget.state) {
      AppTileState.launching => 'Opening...',
      AppTileState.installing => 'Installing...',
      AppTileState.updating => 'Updating...',
      AppTileState.broken => widget.app.name,
      _ => widget.app.name,
    };

    final Widget tileBody = SizedBox(
      width: 135,
      height: 160,
      child: ColoredBox(
        color: background,
        child: Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: PaperSpacing.space4),
              child: Column(
                children: <Widget>[
                  Center(
                    child: _AppIconFrame(
                      app: widget.app,
                      state: widget.state,
                      foreground: foreground,
                      background: background,
                      progress: widget.progress,
                    ),
                  ),
                  const SizedBox(height: PaperSpacing.space8),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PaperSpacing.space4,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.type.label.copyWith(color: foreground),
                    ),
                  ),
                  // Fixed caption slot keeps label baselines aligned across
                  // every tile in a row, broken or not.
                  SizedBox(
                    height: 18,
                    child: widget.state == AppTileState.broken
                        ? Text(
                            'Tap for info',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.copyWith(
                              color: foreground,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            if (widget.state == AppTileState.hover)
              Positioned.fill(
                child: CustomPaint(painter: _DashedOutlinePainter(palette.ink)),
              ),
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      label: widget.app.isSystem
          ? 'Switch to reMarkable'
          : '${widget.app.name} app',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) {
          _setPressed(false);
          widget.onLaunch();
        },
        onLongPress: widget.onManage,
        child: tileBody,
      ),
    );
  }
}

final class _AppIconFrame extends StatelessWidget {
  const _AppIconFrame({
    required this.app,
    required this.state,
    required this.foreground,
    required this.background,
    this.progress,
  });

  final PaperAppTileData app;
  final AppTileState state;
  final Color foreground;
  final Color background;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final bool dashed =
        app.isSystem ||
        state == AppTileState.installing ||
        state == AppTileState.updating;
    return SizedBox.square(
      dimension: 96,
      child: CustomPaint(
        painter: dashed
            ? _DashedFramePainter(color: foreground)
            : _SolidFramePainter(color: foreground),
        child: Stack(
          children: <Widget>[
            Center(
              child: _IconContent(
                app: app,
                state: state,
                foreground: foreground,
                progress: progress,
              ),
            ),
            if (state == AppTileState.broken)
              Positioned(
                right: 7,
                top: 7,
                child: WarningMark(size: 20, color: foreground),
              )
            else if (app.isPinned && !app.isSystem)
              // Dog-ear pin tab anchored to the frame corner.
              Positioned(
                right: 0,
                top: 0,
                child: SizedBox.square(
                  dimension: 14,
                  child: ColoredBox(color: foreground),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _IconContent extends StatelessWidget {
  const _IconContent({
    required this.app,
    required this.state,
    required this.foreground,
    this.progress,
  });

  final PaperAppTileData app;
  final AppTileState state;
  final Color foreground;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    if (state == AppTileState.launching) {
      return SegmentRing(segment: 7, size: 54);
    }
    if (state == AppTileState.installing || state == AppTileState.updating) {
      return _ProgressMonogram(
        label: '${((progress ?? 0) * 100).round()}%',
        foreground: foreground,
      );
    }
    final Uint8List? iconBytes = app.iconBytes;
    if (!app.isSystem && iconBytes != null && iconBytes.isNotEmpty) {
      return SizedBox.square(
        dimension: 88,
        child: Image.memory(
          iconBytes,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          color: foreground,
          colorBlendMode: BlendMode.srcATop,
          gaplessPlayback: true,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => _Monogram(app: app, color: foreground),
        ),
      );
    }
    return _Monogram(app: app, color: foreground);
  }
}

final class _Monogram extends StatelessWidget {
  const _Monogram({required this.app, required this.color});

  final PaperAppTileData app;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final String text = app.isSystem ? 'rM' : _initials(app.name);
    return Text(
      text,
      textAlign: TextAlign.center,
      style: theme.type.monogram.copyWith(color: color),
    );
  }
}

final class _ProgressMonogram extends StatelessWidget {
  const _ProgressMonogram({required this.label, required this.foreground});

  final String label;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('.....', style: theme.type.caption.copyWith(color: foreground)),
        Text(label, style: theme.type.heading.copyWith(color: foreground)),
        Text('.....', style: theme.type.caption.copyWith(color: foreground)),
      ],
    );
  }
}

String _initials(String name) {
  final List<String> words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return '?';
  }
  if (words.length == 1) {
    return words.first.characters.take(2).toString().toUpperCase();
  }
  return '${words[0].characters.first}${words[1].characters.first}'
      .toUpperCase();
}

final class _SolidFramePainter extends CustomPainter {
  const _SolidFramePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    canvas.drawRect(Offset.zero & size, stroke);
  }

  @override
  bool shouldRepaint(_SolidFramePainter oldDelegate) =>
      color != oldDelegate.color;
}

final class _DashedFramePainter extends CustomPainter {
  const _DashedFramePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    _drawDashedRect(canvas, Offset.zero & size, stroke, 10, 6);
  }

  @override
  bool shouldRepaint(_DashedFramePainter oldDelegate) =>
      color != oldDelegate.color;
}

final class _DashedOutlinePainter extends CustomPainter {
  const _DashedOutlinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    _drawDashedRect(canvas, (Offset.zero & size).deflate(4), stroke, 10, 6);
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter oldDelegate) =>
      color != oldDelegate.color;
}

void _drawDashedRect(
  Canvas canvas,
  Rect rect,
  Paint paint,
  double dash,
  double gap,
) {
  void drawLine(Offset start, Offset end) {
    final double length = (end - start).distance;
    final Offset direction = (end - start) / length;
    double travelled = 0;
    while (travelled < length) {
      final double segmentEnd = math.min(travelled + dash, length);
      canvas.drawLine(
        start + direction * travelled,
        start + direction * segmentEnd,
        paint,
      );
      travelled += dash + gap;
    }
  }

  drawLine(rect.topLeft, rect.topRight);
  drawLine(rect.topRight, rect.bottomRight);
  drawLine(rect.bottomRight, rect.bottomLeft);
  drawLine(rect.bottomLeft, rect.topLeft);
}
