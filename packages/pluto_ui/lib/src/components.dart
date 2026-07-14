import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';

import 'paper_theme.dart';
import 'refresh.dart';

/// One discrete visual state in a [StateScript].
final class StateStep {
  /// Creates a script step.
  const StateStep({
    required this.apply,
    this.minDwell = const Duration(milliseconds: 80),
  });

  /// Applies the visual state.
  final VoidCallback apply;

  /// Minimum wall-clock dwell before the next state.
  final Duration minDwell;
}

/// Runs a sequence of complete visual states without tweening.
final class StateScript {
  /// Creates a script from [steps].
  StateScript(this.steps);

  /// Script steps.
  final List<StateStep> steps;

  bool _cancelled = false;

  /// Runs all steps unless [cancel] is called.
  Future<void> run() async {
    _cancelled = false;
    for (final StateStep step in steps) {
      if (_cancelled) {
        return;
      }
      step.apply();
      await Future<void>.delayed(step.minDwell);
    }
  }

  /// Cancels the currently running script.
  void cancel() {
    _cancelled = true;
  }
}

/// Visual style for a [PaperButton].
enum PaperButtonVariant {
  /// Filled ink button for the primary page action.
  primary,

  /// Outlined button for neutral actions.
  secondary,

  /// Destructive action button.
  destructive,

  /// Borderless low-emphasis button.
  ghost,
}

/// A square-corner e-ink button with fast-class pressed inversion.
final class PaperButton extends StatefulWidget {
  /// Creates a button.
  const PaperButton({
    required this.label,
    required this.onPressed,
    this.variant = PaperButtonVariant.secondary,
    this.icon,
    this.armingDelay,
    this.minWidth,
    super.key,
  });

  /// Creates a primary filled button.
  factory PaperButton.primary({
    required String label,
    required VoidCallback? onPressed,
    Key? key,
  }) {
    return PaperButton(
      key: key,
      label: label,
      onPressed: onPressed,
      variant: PaperButtonVariant.primary,
    );
  }

  /// Creates a destructive action button.
  factory PaperButton.destructive({
    required String label,
    required VoidCallback? onPressed,
    Duration? armingDelay,
    Key? key,
  }) {
    return PaperButton(
      key: key,
      label: label,
      onPressed: onPressed,
      variant: PaperButtonVariant.destructive,
      armingDelay: armingDelay,
    );
  }

  /// Creates a borderless low-emphasis button.
  factory PaperButton.ghost({
    required String label,
    required VoidCallback? onPressed,
    Key? key,
  }) {
    return PaperButton(
      key: key,
      label: label,
      onPressed: onPressed,
      variant: PaperButtonVariant.ghost,
    );
  }

  /// Text label.
  final String label;

  /// Called after the minimum pressed dwell when enabled.
  final VoidCallback? onPressed;

  /// Button visual variant.
  final PaperButtonVariant variant;

  /// Optional leading glyph.
  final Widget? icon;

  /// Delay before the button becomes enabled.
  final Duration? armingDelay;

  /// Optional minimum button width.
  final double? minWidth;

  @override
  State<PaperButton> createState() => _PaperButtonState();
}

final class _PaperButtonState extends State<PaperButton> {
  static const Duration _pressDwell = Duration(milliseconds: 80);

  Timer? _armingTimer;
  Timer? _releaseTimer;
  bool _armed = true;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && _armed;

  @override
  void initState() {
    super.initState();
    _startArmingTimer();
  }

  @override
  void didUpdateWidget(PaperButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.armingDelay != widget.armingDelay ||
        oldWidget.onPressed != widget.onPressed) {
      _startArmingTimer();
    }
  }

  @override
  void dispose() {
    _armingTimer?.cancel();
    _releaseTimer?.cancel();
    super.dispose();
  }

  void _startArmingTimer() {
    _armingTimer?.cancel();
    final Duration? delay = widget.armingDelay;
    if (delay == null || widget.onPressed == null) {
      _armed = true;
      return;
    }
    _armed = false;
    _armingTimer = Timer(delay, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _armed = true;
      });
      EinkRefreshRegion.request(
        context,
        refreshClass: RefreshClass.ui,
        reason: 'button.armed',
      );
    });
  }

  void _handleTapDown(TapDownDetails details) {
    if (!_enabled) {
      return;
    }
    setState(() {
      _pressed = true;
    });
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'button.press',
    );
  }

  void _handleTapCancel() {
    if (!_pressed) {
      return;
    }
    setState(() {
      _pressed = false;
    });
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'button.cancel',
    );
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_enabled || !_pressed) {
      return;
    }
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_pressDwell, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _pressed = false;
      });
      widget.onPressed?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final PaperPalette palette = theme.palette;
    final TextStyle labelStyle = theme.type.label;
    final _ButtonColors colors = _buttonColors(
      palette: palette,
      enabled: _enabled,
      arming: widget.onPressed != null && !_armed,
      pressed: _pressed,
      variant: widget.variant,
    );
    final Widget label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: labelStyle.copyWith(color: colors.foreground),
    );
    final Widget child = widget.icon == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconTheme(
                data: IconThemeData(color: colors.foreground, size: 18),
                child: widget.icon!,
              ),
              const SizedBox(width: PaperSpacing.space8),
              Flexible(child: label),
            ],
          );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: PaperSpacing.touchTargetMin,
            minWidth: widget.minWidth ?? PaperSpacing.touchTargetMin,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.background,
              border: Border.all(
                color: colors.border,
                width: PaperSpacing.rule,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PaperSpacing.space16,
                vertical: PaperSpacing.space12,
              ),
              // Shrink-wraps under loose constraints so Align/Row parents can
              // size the button to its label; fills tight constraints as before.
              child: Align(widthFactor: 1, heightFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ButtonColors {
  const _ButtonColors({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color border;
}

_ButtonColors _buttonColors({
  required PaperPalette palette,
  required bool enabled,
  required bool arming,
  required bool pressed,
  required PaperButtonVariant variant,
}) {
  if (arming) {
    // Not yet tappable, but the intent (ink or destructive red) stays visible
    // so the button reads as "becoming ready" rather than disabled.
    return _ButtonColors(
      background: palette.paper,
      foreground: variant == PaperButtonVariant.destructive
          ? palette.accentRed
          : palette.ink,
      border: palette.gray99,
    );
  }
  if (!enabled) {
    return _ButtonColors(
      background: palette.paper,
      foreground: palette.gray66,
      border: variant == PaperButtonVariant.ghost
          ? const Color(0x00000000)
          : palette.gray99,
    );
  }
  if (pressed) {
    return _ButtonColors(
      background: palette.ink,
      foreground: palette.paper,
      border: palette.ink,
    );
  }
  switch (variant) {
    case PaperButtonVariant.primary:
      return _ButtonColors(
        background: palette.ink,
        foreground: palette.paper,
        border: palette.ink,
      );
    case PaperButtonVariant.secondary:
      return _ButtonColors(
        background: palette.paper,
        foreground: palette.ink,
        border: palette.ink,
      );
    case PaperButtonVariant.destructive:
      return _ButtonColors(
        background: palette.paper,
        foreground: palette.accentRed,
        border: palette.ink,
      );
    case PaperButtonVariant.ghost:
      return _ButtonColors(
        background: palette.paper,
        foreground: palette.ink,
        border: const Color(0x00000000),
      );
  }
}

/// A discrete hold-to-confirm control with segmented fast-class feedback.
final class HoldToConfirmButton extends StatefulWidget {
  /// Creates a hold-to-confirm button.
  const HoldToConfirmButton({
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(seconds: 3),
    this.segmentCount = 6,
    super.key,
  });

  /// Text drawn over the segmented progress bar.
  final String label;

  /// Called when all hold segments have filled.
  final VoidCallback onConfirmed;

  /// Total hold duration.
  final Duration holdDuration;

  /// Number of discrete progress segments.
  final int segmentCount;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

final class _HoldToConfirmButtonState extends State<HoldToConfirmButton> {
  Timer? _timer;
  int _filledSegments = 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    setState(() {
      _filledSegments = 0;
    });
    final int segmentCount = math.max(1, widget.segmentCount);
    final int stepMs = math.max(
      1,
      widget.holdDuration.inMilliseconds ~/ segmentCount,
    );
    _timer = Timer.periodic(Duration(milliseconds: stepMs), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _filledSegments = math.min(segmentCount, _filledSegments + 1);
      });
      EinkRefreshRegion.request(
        context,
        refreshClass: RefreshClass.fast,
        reason: 'hold.segment',
      );
      if (_filledSegments >= segmentCount) {
        timer.cancel();
        widget.onConfirmed();
      }
    });
  }

  void _reset() {
    _timer?.cancel();
    if (_filledSegments == 0) {
      return;
    }
    setState(() {
      _filledSegments = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final int segmentCount = math.max(1, widget.segmentCount);
    final double fillFraction =
        _filledSegments.clamp(0, segmentCount) / segmentCount;
    final Text inkLabel = Text(
      widget.label,
      style: theme.type.label.copyWith(color: theme.palette.accentRed),
    );
    final Text paperLabel = Text(
      widget.label,
      style: theme.type.label.copyWith(color: theme.palette.paper),
    );
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _reset(),
        onTapCancel: _reset,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: 64,
            minWidth: PaperSpacing.touchTargetMin,
          ),
          child: CustomPaint(
            painter: _SegmentFillPainter(
              filledSegments: _filledSegments,
              segmentCount: widget.segmentCount,
              palette: theme.palette,
            ),
            child: SizedBox(
              height: 64,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Center(child: inkLabel),
                  // Paper copy of the label revealed over the filled portion so
                  // the text stays legible as ink segments fill behind it.
                  ClipRect(
                    clipper: _LeadingFractionClipper(fillFraction),
                    child: Center(child: paperLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _LeadingFractionClipper extends CustomClipper<Rect> {
  const _LeadingFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeadingFractionClipper oldClipper) =>
      fraction != oldClipper.fraction;
}

/// A single segment option in [SegmentedControl].
final class PaperSegment<T> {
  /// Creates a segment.
  const PaperSegment({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  /// Value emitted when this segment is selected.
  final T value;

  /// Visible label.
  final String label;

  /// Whether this segment can be selected.
  final bool enabled;
}

/// A hard-edged segmented control for mode choices.
final class SegmentedControl<T> extends StatelessWidget {
  /// Creates a segmented control.
  const SegmentedControl({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Available segments.
  final List<PaperSegment<T>> segments;

  /// Currently selected value.
  final T selected;

  /// Called when the selected value changes.
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final PaperPalette palette = theme.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int index = 0; index < segments.length; index++)
          _SegmentButton<T>(
            segment: segments[index],
            selected: segments[index].value == selected,
            onChanged: onChanged,
            showLeftBorder: index == 0,
            palette: palette,
            labelStyle: theme.type.caption,
          ),
      ],
    );
  }
}

final class _SegmentButton<T> extends StatelessWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.onChanged,
    required this.showLeftBorder,
    required this.palette,
    required this.labelStyle,
  });

  final PaperSegment<T> segment;
  final bool selected;
  final ValueChanged<T> onChanged;
  final bool showLeftBorder;
  final PaperPalette palette;
  final TextStyle labelStyle;

  @override
  Widget build(BuildContext context) {
    final Color background = selected ? palette.ink : palette.paper;
    final Color foreground = !segment.enabled
        ? palette.gray66
        : selected
        ? palette.paper
        : palette.ink;
    return Semantics(
      button: true,
      selected: selected,
      enabled: segment.enabled,
      label: segment.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: segment.enabled
            ? () {
                EinkRefreshRegion.request(
                  context,
                  refreshClass: RefreshClass.fast,
                  reason: 'segment.select',
                );
                onChanged(segment.value);
              }
            : null,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: PaperSpacing.touchTargetMin,
            minWidth: PaperSpacing.touchTargetMin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: PaperSpacing.space8),
          decoration: BoxDecoration(
            color: background,
            border: Border(
              left: showLeftBorder
                  ? BorderSide(color: palette.ink, width: PaperSpacing.rule)
                  : BorderSide.none,
              top: BorderSide(color: palette.ink, width: PaperSpacing.rule),
              right: BorderSide(color: palette.ink, width: PaperSpacing.rule),
              bottom: BorderSide(color: palette.ink, width: PaperSpacing.rule),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            segment.label,
            overflow: TextOverflow.ellipsis,
            style: labelStyle.copyWith(color: foreground),
          ),
        ),
      ),
    );
  }
}

/// A notched e-ink slider for discrete values such as frontlight brightness.
final class DiscreteSlider extends StatelessWidget {
  /// Creates a discrete slider.
  const DiscreteSlider({
    required this.notchCount,
    required this.notchIndex,
    required this.onNotchChanged,
    this.leadingLabel,
    this.trailingLabel,
    super.key,
  });

  /// Number of notches.
  final int notchCount;

  /// Current notch index.
  final int notchIndex;

  /// Called when the user selects a new notch.
  final ValueChanged<int> onNotchChanged;

  /// Optional text before the track.
  final String? leadingLabel;

  /// Optional text after the track.
  final String? trailingLabel;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final int safeCount = math.max(2, notchCount);
    final int safeIndex = notchIndex.clamp(0, safeCount - 1);
    return Row(
      children: <Widget>[
        if (leadingLabel != null)
          Padding(
            padding: const EdgeInsets.only(right: PaperSpacing.space8),
            child: Text(leadingLabel!, style: theme.type.caption),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails details) {
                  _selectNotch(
                    context,
                    details.localPosition.dx,
                    constraints.maxWidth,
                  );
                },
                onPanUpdate: (DragUpdateDetails details) {
                  _selectNotch(
                    context,
                    details.localPosition.dx,
                    constraints.maxWidth,
                  );
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PaperSpacing.touchTargetMin,
                  ),
                  child: CustomPaint(
                    painter: _DiscreteSliderPainter(
                      notchCount: safeCount,
                      notchIndex: safeIndex,
                      palette: theme.palette,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (trailingLabel != null)
          Padding(
            padding: const EdgeInsets.only(left: PaperSpacing.space8),
            child: Text(
              trailingLabel!,
              maxLines: 1,
              softWrap: false,
              style: theme.type.mono,
            ),
          ),
      ],
    );
  }

  void _selectNotch(BuildContext context, double x, double width) {
    if (width <= 0) {
      return;
    }
    final int safeCount = math.max(2, notchCount);
    final double fraction = (x / width).clamp(0, 1);
    final int next = (fraction * (safeCount - 1)).round();
    if (next == notchIndex) {
      return;
    }
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.fast,
      reason: 'slider.notch',
    );
    onNotchChanged(next);
  }
}

/// A square e-ink checkbox.
final class PaperCheckbox extends StatelessWidget {
  /// Creates a checkbox.
  const PaperCheckbox({
    required this.value,
    required this.onChanged,
    required this.label,
    super.key,
  });

  /// Whether the box is checked.
  final bool value;

  /// Called when the box is toggled.
  final ValueChanged<bool> onChanged;

  /// Visible label.
  final String label;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Semantics(
      checked: value,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          EinkRefreshRegion.request(
            context,
            refreshClass: RefreshClass.fast,
            reason: 'checkbox.toggle',
          );
          onChanged(!value);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: PaperSpacing.touchTargetMin,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _CheckBoxMark(value: value),
              const SizedBox(width: PaperSpacing.space12),
              Flexible(child: Text(label, style: theme.type.body)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact on/off toggle.
final class PaperToggle extends StatelessWidget {
  /// Creates a toggle control.
  const PaperToggle({
    required this.value,
    required this.onChanged,
    this.onLabel = 'On',
    this.offLabel = 'Off',
    super.key,
  });

  /// Current toggle value.
  final bool value;

  /// Called when the value flips.
  final ValueChanged<bool> onChanged;

  /// Label for the on state.
  final String onLabel;

  /// Label for the off state.
  final String offLabel;

  @override
  Widget build(BuildContext context) {
    return SegmentedControl<bool>(
      selected: value,
      onChanged: onChanged,
      segments: <PaperSegment<bool>>[
        PaperSegment<bool>(value: true, label: onLabel),
        PaperSegment<bool>(value: false, label: offLabel),
      ],
    );
  }
}

/// Standard page header with optional leading and trailing controls.
final class PageHeader extends StatelessWidget {
  /// Creates a page header.
  const PageHeader({
    required this.title,
    this.leading,
    this.trailing,
    this.subtitle,
    super.key,
  });

  /// Main page title.
  final String title;

  /// Optional leading widget.
  final Widget? leading;

  /// Optional trailing widget.
  final Widget? trailing;

  /// Optional smaller subtitle.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PaperSpacing.pageMargin,
        ),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              Center(
                child: SizedBox(
                  height: PaperSpacing.touchTargetMin,
                  child: leading,
                ),
              ),
              const SizedBox(width: PaperSpacing.space12),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.title,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.copyWith(
                        color: theme.palette.gray33,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null)
              Center(
                child: SizedBox(
                  height: PaperSpacing.touchTargetMin,
                  child: trailing,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Page-dot row using filled and hollow square dots.
final class PageDots extends StatelessWidget {
  /// Creates page indicator dots.
  const PageDots({
    required this.count,
    required this.index,
    this.onPrevious,
    this.onNext,
    super.key,
  });

  /// Number of pages.
  final int count;

  /// Selected page index.
  final int index;

  /// Called when the left third is tapped.
  final VoidCallback? onPrevious;

  /// Called when the right third is tapped.
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final int safeCount = math.max(1, count);
    if (safeCount < 2) {
      return const SizedBox.shrink();
    }
    final int safeIndex = index.clamp(0, safeCount - 1);
    final TextStyle chevronStyle = theme.type.label.copyWith(
      color: theme.palette.gray33,
    );
    return SizedBox(
      height: PaperSpacing.touchTargetMin,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPrevious,
              child: onPrevious == null
                  ? const SizedBox.expand()
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          right: PaperSpacing.space20,
                        ),
                        child: Text('‹', style: chevronStyle),
                      ),
                    ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < safeCount; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: _PageDot(
                    filled: i == safeIndex,
                    palette: theme.palette,
                  ),
                ),
            ],
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onNext,
              child: onNext == null
                  ? const SizedBox.expand()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: PaperSpacing.space20,
                        ),
                        child: Text('›', style: chevronStyle),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _PageDot extends StatelessWidget {
  const _PageDot({required this.filled, required this.palette});

  final bool filled;
  final PaperPalette palette;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: filled ? palette.ink : palette.paper,
          border: Border.all(color: palette.ink, width: PaperSpacing.rule),
        ),
      ),
    );
  }
}

/// Full paper page scaffold with status, header, content, and page dots.
final class PaperScaffold extends StatelessWidget {
  /// Creates a paper scaffold.
  const PaperScaffold({
    required this.body,
    this.header,
    this.statusBar,
    this.pageIndicator,
    this.showStatusBar = true,
    super.key,
  });

  /// Main content body.
  final Widget body;

  /// Optional page header.
  final Widget? header;

  /// Optional status bar widget.
  final Widget? statusBar;

  /// Optional bottom page indicator.
  final Widget? pageIndicator;

  /// Whether the status band should be reserved.
  final bool showStatusBar;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return ColoredBox(
      color: theme.palette.paper,
      child: Column(
        children: <Widget>[
          if (showStatusBar) ...<Widget>[
            SizedBox(height: 40, child: statusBar ?? const SizedBox.shrink()),
            _Rule(color: theme.palette.ink, height: PaperSpacing.rule),
          ],
          if (header != null) ...<Widget>[
            header!,
            _Rule(color: theme.palette.ink, height: PaperSpacing.rule),
          ],
          Expanded(child: body),
          ?pageIndicator,
          const SizedBox(height: PaperSpacing.space16),
        ],
      ),
    );
  }
}

/// A fixed-height list row with fast-class pressed inversion.
final class PaperListItem extends StatefulWidget {
  /// Creates a paper list item.
  const PaperListItem({
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.height = 56,
    this.destructive = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: PaperSpacing.pageMargin,
    ),
    super.key,
  });

  /// Primary row title.
  final String title;

  /// Secondary row text.
  final String? subtitle;

  /// Secondary row widget, used instead of [subtitle] when provided.
  final Widget? subtitleWidget;

  /// Optional leading widget.
  final Widget? leading;

  /// Optional trailing widget.
  final Widget? trailing;

  /// Tap callback.
  final VoidCallback? onTap;

  /// Long-press callback.
  final VoidCallback? onLongPress;

  /// Row height.
  final double height;

  /// Whether the title uses the destructive accent.
  final bool destructive;

  /// Horizontal row padding.
  final EdgeInsetsGeometry padding;

  @override
  State<PaperListItem> createState() => _PaperListItemState();
}

final class _PaperListItemState extends State<PaperListItem> {
  bool _pressed = false;

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
      reason: 'list.press',
    );
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final PaperPalette palette = theme.palette;
    final Color background = _pressed ? palette.ink : palette.paper;
    final Color foreground = _pressed
        ? palette.paper
        : widget.destructive
        ? palette.accentRed
        : palette.ink;
    final Color secondary = _pressed ? palette.paper : palette.gray33;
    return Semantics(
      button: widget.onTap != null,
      label: widget.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
        onTapUp: widget.onTap == null
            ? null
            : (_) {
                _setPressed(false);
                widget.onTap?.call();
              },
        onLongPress: widget.onLongPress,
        child: Container(
          height: math.max(PaperSpacing.touchTargetMin, widget.height),
          color: background,
          padding: widget.padding,
          child: Row(
            children: <Widget>[
              if (widget.leading != null) ...<Widget>[
                widget.leading!,
                const SizedBox(width: PaperSpacing.space12),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.body.copyWith(color: foreground),
                    ),
                    if (widget.subtitleWidget != null)
                      widget.subtitleWidget!
                    else if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.copyWith(color: secondary),
                      ),
                  ],
                ),
              ),
              if (widget.trailing != null) ...<Widget>[
                const SizedBox(width: PaperSpacing.space12),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A bordered paper surface with optional plate shadow.
final class PaperSurface extends StatelessWidget {
  /// Creates a paper surface.
  const PaperSurface({
    required this.child,
    this.padding = const EdgeInsets.all(PaperSpacing.space16),
    this.plateShadow = false,
    this.hairline = false,
    this.radius = PaperSpacing.radius,
    super.key,
  });

  /// Surface contents.
  final Widget child;

  /// Inner padding.
  final EdgeInsetsGeometry padding;

  /// Whether to draw the 4 lp offset ink plate behind the surface.
  final bool plateShadow;

  /// Whether to use a quiet 1 lp gray border for non-interactive panels.
  final bool hairline;

  /// Corner radius.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.palette.paper,
        borderRadius: BorderRadius.circular(radius),
        // Quiet borders stay ink so they survive 1-bit dithering.
        border: hairline
            ? Border.all(color: theme.palette.ink, width: PaperSpacing.hairline)
            : Border.all(color: theme.palette.ink, width: PaperSpacing.rule),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (!plateShadow) {
      return surface;
    }
    return Padding(
      padding: const EdgeInsets.only(
        right: PaperSpacing.space4,
        bottom: PaperSpacing.space4,
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            left: PaperSpacing.space4,
            top: PaperSpacing.space4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.palette.ink,
                borderRadius: BorderRadius.circular(radius),
              ),
            ),
          ),
          surface,
        ],
      ),
    );
  }
}

/// Centered dialog plate.
final class PaperDialog extends StatelessWidget {
  /// Creates a paper dialog.
  const PaperDialog({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    super.key,
  });

  /// Dialog title.
  final String title;

  /// Dialog body.
  final Widget child;

  /// Dialog actions.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 437, minWidth: 320),
        child: PaperSurface(
          plateShadow: true,
          radius: PaperSpacing.radiusDialog,
          padding: const EdgeInsets.all(PaperSpacing.space20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: theme.type.heading),
              const SizedBox(height: PaperSpacing.space16),
              child,
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: PaperSpacing.space20),
                Row(
                  children: <Widget>[
                    for (int i = 0; i < actions.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: PaperSpacing.space12),
                      Expanded(child: actions[i]),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Standard empty-state block.
final class PaperEmptyState extends StatelessWidget {
  /// Creates an empty state.
  const PaperEmptyState({
    required this.title,
    required this.message,
    this.icon,
    this.extra,
    super.key,
  });

  /// Empty-state title.
  final String title;

  /// Explanatory message.
  final String message;

  /// Optional icon or art.
  final Widget? icon;

  /// Optional extra content.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PaperSpacing.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            icon ?? const _ShelfMark(),
            const SizedBox(height: PaperSpacing.space24),
            Text(title, textAlign: TextAlign.center, style: theme.type.heading),
            const SizedBox(height: PaperSpacing.space12),
            Text(message, textAlign: TextAlign.center, style: theme.type.body),
            if (extra != null) ...<Widget>[
              const SizedBox(height: PaperSpacing.space20),
              extra!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Standard loading-state block.
final class PaperLoadingState extends StatelessWidget {
  /// Creates a loading state.
  const PaperLoadingState({required this.label, this.segment = 0, super.key});

  /// Loading label.
  final String label;

  /// Active ring segment.
  final int segment;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SegmentRing(segment: segment),
          const SizedBox(height: PaperSpacing.space16),
          Text(label, style: theme.type.body),
        ],
      ),
    );
  }
}

/// Standard error-state block.
final class PaperErrorState extends StatelessWidget {
  /// Creates an error state.
  const PaperErrorState({
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  /// Error title.
  final String title;

  /// Error message.
  final String message;

  /// Optional recovery action.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PaperSpacing.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const WarningMark(size: 56),
            const SizedBox(height: PaperSpacing.space20),
            Text(title, textAlign: TextAlign.center, style: theme.type.heading),
            const SizedBox(height: PaperSpacing.space12),
            Text(message, textAlign: TextAlign.center, style: theme.type.body),
            if (action != null) ...<Widget>[
              const SizedBox(height: PaperSpacing.space20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A drawn warning triangle with an exclamation mark.
final class WarningMark extends StatelessWidget {
  /// Creates a warning mark.
  const WarningMark({this.size = 24, this.color, super.key});

  /// Mark square size.
  final double size;

  /// Optional ink override.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _WarningMarkPainter(color: color ?? theme.palette.ink),
      ),
    );
  }
}

final class _WarningMarkPainter extends CustomPainter {
  const _WarningMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = math.max(2, size.width / 12);
    final Paint outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.miter;
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final double inset = stroke;
    final Path triangle = Path()
      ..moveTo(size.width / 2, inset)
      ..lineTo(size.width - inset, size.height - inset)
      ..lineTo(inset, size.height - inset)
      ..close();
    canvas.drawPath(triangle, outline);
    final double barWidth = math.max(2, size.width / 11);
    final double barTop = size.height * 0.38;
    final double barBottom = size.height * 0.62;
    canvas.drawRect(
      Rect.fromLTRB(
        size.width / 2 - barWidth / 2,
        barTop,
        size.width / 2 + barWidth / 2,
        barBottom,
      ),
      fill,
    );
    final double dotTop = size.height * 0.70;
    canvas.drawRect(
      Rect.fromLTRB(
        size.width / 2 - barWidth / 2,
        dotTop,
        size.width / 2 + barWidth / 2,
        dotTop + barWidth,
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(_WarningMarkPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// A terminal-excerpt block: mono lines behind a 2 lp ink left rule.
final class PaperCodeBlock extends StatelessWidget {
  /// Creates a code block.
  const PaperCodeBlock({required this.lines, super.key});

  /// Mono lines to render.
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.palette.ink, width: PaperSpacing.rule),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PaperSpacing.space16,
          PaperSpacing.space8,
          0,
          PaperSpacing.space8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String line in lines) Text(line, style: theme.type.mono),
          ],
        ),
      ),
    );
  }
}

/// Eight-segment progress ring.
final class SegmentRing extends StatelessWidget {
  /// Creates a segment ring.
  const SegmentRing({required this.segment, this.size = 64, super.key});

  /// Active segment index.
  final int segment;

  /// Ring square size.
  final double size;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SegmentRingPainter(segment: segment, palette: theme.palette),
      ),
    );
  }
}

final class _Rule extends StatelessWidget {
  const _Rule({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color,
    child: SizedBox(height: height, width: double.infinity),
  );
}

final class _CheckBoxMark extends StatelessWidget {
  const _CheckBoxMark({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return SizedBox.square(
      dimension: 26,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.palette.ink,
            width: PaperSpacing.rule,
          ),
        ),
        child: value
            ? Padding(
                padding: const EdgeInsets.all(6),
                child: ColoredBox(color: theme.palette.ink),
              )
            : null,
      ),
    );
  }
}

final class _ShelfMark extends StatelessWidget {
  const _ShelfMark();

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    return CustomPaint(
      size: const Size(128, 72),
      painter: _ShelfPainter(theme.palette),
    );
  }
}

final class _SegmentFillPainter extends CustomPainter {
  const _SegmentFillPainter({
    required this.filledSegments,
    required this.segmentCount,
    required this.palette,
  });

  final int filledSegments;
  final int segmentCount;
  final PaperPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint border = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    final Paint tick = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.hairline;
    final Paint fill = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.fill;
    final Rect rect = Offset.zero & size;
    final int safeCount = math.max(1, segmentCount);
    final double segmentWidth = size.width / safeCount;
    // Short edge ticks preview the hold mechanics before any segment fills
    // while leaving the center band clear for the label.
    for (int i = 1; i < safeCount; i++) {
      final double x = i * segmentWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, 10), tick);
      canvas.drawLine(
        Offset(x, size.height - 10),
        Offset(x, size.height),
        tick,
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(
        0,
        0,
        segmentWidth * filledSegments.clamp(0, safeCount),
        size.height,
      ),
      fill,
    );
    canvas.drawRect(rect.deflate(PaperSpacing.rule / 2), border);
  }

  @override
  bool shouldRepaint(_SegmentFillPainter oldDelegate) {
    return filledSegments != oldDelegate.filledSegments ||
        segmentCount != oldDelegate.segmentCount ||
        palette != oldDelegate.palette;
  }
}

final class _DiscreteSliderPainter extends CustomPainter {
  const _DiscreteSliderPainter({
    required this.notchCount,
    required this.notchIndex,
    required this.palette,
  });

  final int notchCount;
  final int notchIndex;
  final PaperPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint inkFill = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.fill;
    final Paint inkStroke = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule;
    final double centerY = size.height / 2;
    final double startX = 6;
    final double endX = size.width - 6;
    canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), inkStroke);
    final int safeCount = math.max(2, notchCount);
    for (int i = 0; i < safeCount; i++) {
      final double x = startX + (endX - startX) * i / (safeCount - 1);
      final Rect notch = Rect.fromCenter(
        center: Offset(x, centerY),
        width: 10,
        height: i <= notchIndex ? 28 : 16,
      );
      if (i <= notchIndex) {
        canvas.drawRect(notch, inkFill);
      } else {
        canvas.drawRect(notch, inkStroke);
      }
    }
  }

  @override
  bool shouldRepaint(_DiscreteSliderPainter oldDelegate) {
    return notchCount != oldDelegate.notchCount ||
        notchIndex != oldDelegate.notchIndex ||
        palette != oldDelegate.palette;
  }
}

final class _SegmentRingPainter extends CustomPainter {
  const _SegmentRingPainter({required this.segment, required this.palette});

  final int segment;
  final PaperPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    // All spokes are ink so the dial stays crisp on a dithering panel; the
    // active segment reads by stroke weight, not by gray value.
    final Paint active = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.butt;
    final Paint inactive = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt;
    final Offset center = size.center(Offset.zero);
    final double radius = math.min(size.width, size.height) / 2 - 2;
    const int count = 8;
    for (int i = 0; i < count; i++) {
      final double angle = -math.pi / 2 + i * math.pi * 2 / count;
      final Offset start =
          center + Offset(math.cos(angle), math.sin(angle)) * (radius - 16);
      final Offset end =
          center + Offset(math.cos(angle), math.sin(angle)) * radius;
      canvas.drawLine(start, end, i == segment % count ? active : inactive);
    }
  }

  @override
  bool shouldRepaint(_SegmentRingPainter oldDelegate) {
    return segment != oldDelegate.segment || palette != oldDelegate.palette;
  }
}

final class _ShelfPainter extends CustomPainter {
  const _ShelfPainter(this.palette);

  final PaperPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    // An open tray seen from the front: side walls, a base, and one interior
    // shelf line — deliberately simple geometry that reads as "empty shelf".
    final Paint stroke = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = PaperSpacing.rule
      ..strokeJoin = StrokeJoin.miter;
    final double inset = PaperSpacing.rule / 2;
    final Path tray = Path()
      ..moveTo(inset, inset)
      ..lineTo(inset, size.height - inset)
      ..lineTo(size.width - inset, size.height - inset)
      ..lineTo(size.width - inset, inset);
    canvas.drawPath(tray, stroke);
    canvas.drawLine(
      Offset(inset, size.height * 0.55),
      Offset(size.width - inset, size.height * 0.55),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_ShelfPainter oldDelegate) =>
      palette != oldDelegate.palette;
}
