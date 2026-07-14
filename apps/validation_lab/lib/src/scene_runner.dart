import 'dart:async';

import 'package:flutter/widgets.dart';

import 'config.dart';
import 'lab_style.dart';
import 'scene.dart';

/// Plays a scripted sequence of [SceneSpec]s with a corner banner and a
/// toggleable stats HUD, so camera footage self-indexes.
///
/// Pacing is **wall-clock**: dwell and rest phases are driven by [Timer]s,
/// which fire on elapsed real time regardless of how many frames the
/// embedder produces, so scenes advance at their nominal durations even at
/// low device frame rates. Content *within* a scene stays deterministic
/// per its own timers and animation-controller values.
///
/// In [SceneRunnerMode.auto], every scene is followed by a **rest beacon**
/// of [restDuration]: the scene freezes in its final static state (via
/// [SceneRest]/[SceneRestFreeze]), the HUD clock stops, and the banner is
/// untouched — the app paints nothing, so the renderer's quiescence
/// settles fire and ghost debt clears before the next scene.
final class SceneRunner extends StatefulWidget {
  /// Creates a scene runner.
  const SceneRunner({
    required this.scenes,
    this.mode = SceneRunnerMode.auto,
    this.initialSceneId,
    this.showHud = true,
    this.restDuration = defaultRestDuration,
    super.key,
  }) : assert(scenes.length > 0, 'SceneRunner needs at least one scene.');

  /// Frozen quiet time between scenes in [SceneRunnerMode.auto].
  static const Duration defaultRestDuration = Duration(milliseconds: 2500);

  /// Scenes in loop order.
  final List<SceneSpec> scenes;

  /// Playback mode.
  final SceneRunnerMode mode;

  /// Scene id to start on, or null for the first scene.
  final String? initialSceneId;

  /// Whether the stats HUD starts visible.
  final bool showHud;

  /// Rest-beacon length between scenes; [Duration.zero] disables resting.
  final Duration restDuration;

  @override
  State<SceneRunner> createState() => _SceneRunnerState();
}

final class _SceneRunnerState extends State<SceneRunner> {
  late int _sceneIndex;

  /// Monotonic count of scene entries since launch; never resets.
  int _sceneCounter = 1;

  /// Full-loop count; increments on forward wrap-around.
  int _cycle = 1;

  /// Frames actually produced since launch.
  int _frameCount = 0;

  /// Whether the runner is holding the current scene's rest beacon.
  bool _isResting = false;

  Timer? _advanceTimer;

  SceneSpec get _scene => widget.scenes[_sceneIndex];

  @override
  void initState() {
    super.initState();
    final String? sceneId = widget.initialSceneId;
    if (sceneId == null) {
      _sceneIndex = 0;
    } else {
      final int index = widget.scenes.indexWhere(
        (SceneSpec scene) => scene.id == sceneId,
      );
      if (index < 0) {
        final String validIds = widget.scenes
            .map((SceneSpec scene) => scene.id)
            .join(', ');
        throw ArgumentError.value(
          sceneId,
          'initialSceneId',
          'Unknown scene. Valid ids: $validIds',
        );
      }
      _sceneIndex = index;
    }
    _scheduleAdvance();
    WidgetsBinding.instance.addPostFrameCallback(_countFrame);
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }

  void _countFrame(Duration timeStamp) {
    if (!mounted) {
      return;
    }
    _frameCount += 1;
    WidgetsBinding.instance.addPostFrameCallback(_countFrame);
  }

  /// Schedules the end of the current scene's dwell on the wall clock.
  ///
  /// Dart timers fire on elapsed real time, independent of frame
  /// production, so the dwell holds its nominal length even when the
  /// device renders at a fraction of the nominal frame rate.
  void _scheduleAdvance() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    if (widget.mode != SceneRunnerMode.auto) {
      return;
    }
    _advanceTimer = Timer(_scene.duration, _enterRest);
  }

  /// Starts the rest beacon: the scene subtree freezes via [SceneRest],
  /// the HUD clock stops, and nothing paints until the next scene.
  void _enterRest() {
    if (widget.restDuration <= Duration.zero) {
      _advance(1);
      return;
    }
    setState(() {
      _isResting = true;
    });
    _advanceTimer = Timer(widget.restDuration, () => _advance(1));
  }

  void _advance(int delta) {
    setState(() {
      _isResting = false;
      final int count = widget.scenes.length;
      final int rawNext = _sceneIndex + delta;
      if (rawNext >= count) {
        _cycle += 1;
      }
      _sceneIndex = ((rawNext % count) + count) % count;
      _sceneCounter += 1;
    });
    _scheduleAdvance();
  }

  void _handleNavTap(TapUpDetails details, Size size) {
    if (_isReservedCorner(details.localPosition, size)) {
      return;
    }
    _advance(details.localPosition.dx < size.width / 2 ? -1 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: ColoredBox(
                color: labPaper,
                child: SceneRest(
                  isResting: _isResting,
                  child: KeyedSubtree(
                    key: ValueKey<int>(_sceneCounter),
                    child: _scene.builder(context),
                  ),
                ),
              ),
            ),
            if (widget.mode == SceneRunnerMode.manual)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (TapUpDetails details) =>
                      _handleNavTap(details, size),
                ),
              ),
            Positioned(
              left: 12,
              bottom: 12,
              child: SceneBanner(
                index: _sceneIndex,
                total: widget.scenes.length,
                sceneId: _scene.id,
                counter: _sceneCounter,
                cycle: _cycle,
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: StatsHud(
                frameCountOf: () => _frameCount,
                sceneCounter: _sceneCounter,
                frozen: _isResting,
                initiallyVisible: widget.showHud,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Corner zones reserved for chrome (HUD, banner, scene action buttons);
/// manual-mode navigation taps inside them are ignored.
bool _isReservedCorner(Offset position, Size size) {
  const double cornerWidth = 280;
  const double cornerHeight = 96;
  final bool topRight =
      position.dx > size.width - cornerWidth && position.dy < cornerHeight;
  final bool bottomLeft =
      position.dx < cornerWidth && position.dy > size.height - cornerHeight;
  final bool bottomRight =
      position.dx > size.width - cornerWidth &&
      position.dy > size.height - cornerHeight;
  return topRight || bottomLeft || bottomRight;
}

/// Corner banner identifying the current scene for camera alignment.
///
/// Shows `S<index>/<total> <scene-id>`, the monotonic scene counter `N`,
/// the loop cycle `C`, and an 8-bit frame-code strip encoding `N % 256`
/// (MSB first) for machine indexing of footage.
final class SceneBanner extends StatelessWidget {
  /// Creates a scene banner.
  const SceneBanner({
    required this.index,
    required this.total,
    required this.sceneId,
    required this.counter,
    required this.cycle,
    super.key,
  });

  /// Zero-based index of the current scene.
  final int index;

  /// Number of scenes in the loop.
  final int total;

  /// Stable id of the current scene.
  final String sceneId;

  /// Monotonic scene-entry counter (never resets).
  final int counter;

  /// Loop cycle count.
  final int cycle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      color: labInk,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'S${_pad2(index + 1)}/${_pad2(total)} $sceneId',
            style: labBannerStyle,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CustomPaint(
                size: const Size(96, 12),
                painter: FrameCodePainter(value: counter),
              ),
              const SizedBox(width: 8),
              Text(
                'N=${_pad4(counter)} C=${_pad2(cycle)}',
                style: labBannerStyle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paints an 8-cell binary strip encoding `value % 256`, MSB first.
///
/// Set bits render as filled white cells on the ink banner; clear bits as
/// outlined cells, so footage can be indexed without OCR.
final class FrameCodePainter extends CustomPainter {
  /// Creates a frame-code painter for [value].
  const FrameCodePainter({required this.value});

  /// Encoded value; only the low 8 bits are painted.
  final int value;

  @override
  void paint(Canvas canvas, Size size) {
    final double cellWidth = size.width / 8;
    final Paint fill = Paint()..color = labPaper;
    final Paint outline = Paint()
      ..color = labPaper
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int bit = 0; bit < 8; bit += 1) {
      final bool isSet = (value >> (7 - bit)) & 1 == 1;
      final Rect cell = Rect.fromLTWH(
        bit * cellWidth,
        0,
        cellWidth,
        size.height,
      ).deflate(1);
      canvas.drawRect(cell, isSet ? fill : outline);
    }
  }

  @override
  bool shouldRepaint(FrameCodePainter oldDelegate) {
    return oldDelegate.value != value;
  }
}

/// Toggleable corner stats overlay: frame counter and scene time.
///
/// While visible it samples at 1 Hz, which also acts as a heartbeat frame
/// for footage correlation. During the rest beacon ([frozen]) the clock is
/// cancelled so the HUD stops ticking and paints nothing. Toggle it off
/// (HUD button) when a scene must be fully idle even while live.
final class StatsHud extends StatefulWidget {
  /// Creates the stats HUD.
  const StatsHud({
    required this.frameCountOf,
    required this.sceneCounter,
    this.frozen = false,
    this.initiallyVisible = true,
    super.key,
  });

  /// Reads the runner's produced-frame counter.
  final ValueGetter<int> frameCountOf;

  /// Monotonic scene counter; scene time resets when it changes.
  final int sceneCounter;

  /// Whether the runner is resting: the 1 Hz clock stops and the HUD
  /// holds its last readout without repainting.
  final bool frozen;

  /// Whether stats start visible.
  final bool initiallyVisible;

  @override
  State<StatsHud> createState() => _StatsHudState();
}

final class _StatsHudState extends State<StatsHud> {
  Timer? _clock;
  int _sceneSeconds = 0;
  late bool _isVisible = widget.initiallyVisible;

  @override
  void initState() {
    super.initState();
    if (_isVisible && !widget.frozen) {
      _startClock();
    }
  }

  @override
  void didUpdateWidget(StatsHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sceneCounter != widget.sceneCounter) {
      _sceneSeconds = 0;
    }
    if (oldWidget.frozen != widget.frozen) {
      _clock?.cancel();
      _clock = null;
      if (!widget.frozen && _isVisible) {
        _startClock();
      }
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clock = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      setState(() {
        _sceneSeconds += 1;
      });
    });
  }

  void _toggle() {
    setState(() {
      _isVisible = !_isVisible;
      _clock?.cancel();
      _clock = null;
      if (_isVisible && !widget.frozen) {
        _startClock();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_isVisible)
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            margin: const EdgeInsets.only(right: 8),
            color: labInk,
            child: Text(
              'F=${_pad6(widget.frameCountOf())} T=${_pad4(_sceneSeconds)}s',
              style: labBannerStyle,
            ),
          ),
        LabCornerButton(
          label: 'HUD',
          inverted: !_isVisible,
          onPressed: _toggle,
        ),
      ],
    );
  }
}

String _pad2(int value) => value.toString().padLeft(2, '0');

String _pad4(int value) => value.toString().padLeft(4, '0');

String _pad6(int value) => value.toString().padLeft(6, '0');
