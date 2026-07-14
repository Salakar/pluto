import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pluto_pen/pluto_pen.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'image_upload_probe.dart';
import 'isolate_probe.dart';
import 'probe_math.dart';
import 'probe_painter.dart';

const int _frameCount = 120;
const int _maximumLogLines = 120;

/// Bare app shell for the opt-in WP0 on-device probes.
final class InkProbeApp extends StatelessWidget {
  const InkProbeApp({
    this.isolateRunner = const IsolateBlendProbeRunner(),
    this.penEvents,
    super.key,
  });

  /// Injectable isolate runner used by widget tests.
  final IsolateProbeRunner isolateRunner;

  /// Injectable pen stream; the real Pluto stream is used when omitted.
  final PenEvents? penEvents;

  @override
  Widget build(BuildContext context) {
    return PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xFFFFFFFF),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(builder: builder, settings: settings),
        home: ProbePage(
          isolateRunner: isolateRunner,
          penEvents: penEvents ?? PlutoPen.instance,
        ),
      ),
    );
  }
}

/// Full-screen controls, pointer capture, and release-safe probe log.
final class ProbePage extends StatefulWidget {
  const ProbePage({
    required this.isolateRunner,
    required this.penEvents,
    super.key,
  });

  /// Runner for the four-tile isolate benchmark.
  final IsolateProbeRunner isolateRunner;

  /// Source used to detect barrel-button events.
  final PenEvents penEvents;

  @override
  State<ProbePage> createState() => _ProbePageState();
}

final class _ProbePageState extends State<ProbePage>
    with SingleTickerProviderStateMixin {
  final List<String> _logLines = <String>[
    'INK_PROBE: ready — run one probe at a time',
  ];
  final RollingWindowCounter _rollingRate = RollingWindowCounter();
  final RollingWindowCounter _wholeStrokeRate = RollingWindowCounter(
    window: const Duration(days: 1),
  );
  final ConcurrentPointerCounter _touchCounter = ConcurrentPointerCounter();
  final Set<int> _targetFrameNumbers = <int>{};
  final Map<int, ui.FrameTiming> _frameTimings = <int, ui.FrameTiming>{};
  final List<ui.FrameTiming> _unattributedFrameTimings = <ui.FrameTiming>[];

  late final ValueNotifier<int> _frameSignal;
  late final ProbeLoadPainter _loadPainter;
  late final Ticker _frameTicker;
  late final ui.TimingsCallback _installedTimingsCallback;
  late StreamSubscription<PenEvent> _penSubscription;

  String? _busyProbe;
  bool _rateArmed = false;
  int? _ratePointer;
  PointerDeviceKind? _rateKind;
  Stopwatch? _rateStopwatch;
  Timer? _rateWindowTimer;

  bool _capsActive = false;
  bool _sawButtonsChangedEvent = false;
  bool _sawNonZeroButtons = false;

  bool _collectingFrames = false;
  ui.TimingsCallback? _previousTimingsCallback;
  Timer? _frameTimeout;
  var _frameTickCount = 0;

  @override
  void initState() {
    super.initState();
    _frameSignal = ValueNotifier<int>(0);
    _loadPainter = ProbeLoadPainter(frame: _frameSignal);
    _frameTicker = createTicker(_handleFrameTick);
    _installedTimingsCallback = _handleFrameTimings;
    _subscribeToPenEvents();
    debugPrint(_logLines.first);
  }

  @override
  void didUpdateWidget(ProbePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.penEvents != widget.penEvents) {
      unawaited(_penSubscription.cancel());
      _subscribeToPenEvents();
    }
  }

  @override
  void dispose() {
    _collectingFrames = false;
    _rateWindowTimer?.cancel();
    _frameTimeout?.cancel();
    _frameTicker.dispose();
    _restoreTimingsCallback();
    unawaited(_penSubscription.cancel());
    _frameSignal.dispose();
    super.dispose();
  }

  void _subscribeToPenEvents() {
    _penSubscription = widget.penEvents.events.listen(
      _handlePenEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (_capsActive) {
          _emit('P-caps pen stream error: $error');
        }
      },
    );
  }

  void _handlePenEvent(PenEvent event) {
    if (!_capsActive) {
      return;
    }
    final bool wasPresent = _sawButtonsChangedEvent || _sawNonZeroButtons;
    _sawButtonsChangedEvent |= event is PenButtonsChangedEvent;
    _sawNonZeroButtons |= event.sample.buttons.bits != 0;
    final bool isPresent = _sawButtonsChangedEvent || _sawNonZeroButtons;
    if (!wasPresent && isPresent) {
      _emit(
        'P-caps barrel signal received '
        '(changed=$_sawButtonsChangedEvent, nonZero=$_sawNonZeroButtons)',
      );
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_capsActive && event.kind == PointerDeviceKind.touch) {
      final int previousMaximum = _touchCounter.maximum;
      _touchCounter.pointerDown(event.pointer);
      if (_touchCounter.maximum > previousMaximum) {
        _emit('P-caps simultaneous touches=${_touchCounter.maximum}');
      }
    }

    if (!_rateArmed || _ratePointer != null || !_isStylus(event.kind)) {
      return;
    }
    _rollingRate.reset();
    _wholeStrokeRate.reset();
    _ratePointer = event.pointer;
    _rateKind = event.kind;
    _rateStopwatch = Stopwatch()..start();
    _rateWindowTimer?.cancel();
    _rateWindowTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _reportRollingRate(),
    );
    _emit('P-rate stroke started kind=${event.kind.name}');
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _ratePointer) {
      return;
    }
    final Stopwatch? stopwatch = _rateStopwatch;
    if (stopwatch == null) {
      return;
    }
    final int timestampMicroseconds = stopwatch.elapsedMicroseconds;
    _rollingRate.add(
      timestampMicroseconds: timestampMicroseconds,
      x: event.position.dx,
      y: event.position.dy,
      pressure: event.pressure,
    );
    _wholeStrokeRate.add(
      timestampMicroseconds: timestampMicroseconds,
      x: event.position.dx,
      y: event.position.dy,
      pressure: event.pressure,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_capsActive && event.kind == PointerDeviceKind.touch) {
      _touchCounter.pointerUp(event.pointer);
    }
    if (event.pointer == _ratePointer) {
      _finishRateStroke(wasCancelled: false);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_capsActive && event.kind == PointerDeviceKind.touch) {
      _touchCounter.pointerUp(event.pointer);
    }
    if (event.pointer == _ratePointer) {
      _finishRateStroke(wasCancelled: true);
    }
  }

  bool _isStylus(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  void _toggleRateProbe() {
    if (_rateArmed) {
      _rateWindowTimer?.cancel();
      _ratePointer = null;
      _rateStopwatch?.stop();
      _rateStopwatch = null;
      _rateArmed = false;
      _emit('P-rate cancelled');
      return;
    }
    _rollingRate.reset();
    _wholeStrokeRate.reset();
    _rateArmed = true;
    _emit('P-rate armed — draw one continuous stylus stroke');
  }

  void _reportRollingRate() {
    final Stopwatch? stopwatch = _rateStopwatch;
    if (stopwatch == null) {
      return;
    }
    final RollingWindowStats stats = _rollingRate.snapshot(
      nowMicroseconds: stopwatch.elapsedMicroseconds,
    );
    _emit('P-rate 1s ${_formatPointerStats(stats)} kind=${_rateKind?.name}');
  }

  void _finishRateStroke({required bool wasCancelled}) {
    final Stopwatch? stopwatch = _rateStopwatch;
    if (stopwatch == null) {
      return;
    }
    stopwatch.stop();
    _rateWindowTimer?.cancel();
    _rateWindowTimer = null;
    final RollingWindowStats stats = _wholeStrokeRate.snapshot(
      nowMicroseconds: stopwatch.elapsedMicroseconds,
    );
    final double durationSeconds = stopwatch.elapsedMicroseconds / 1000000;
    final double rate = durationSeconds == 0
        ? 0
        : stats.count / durationSeconds;
    final String kind = _rateKind?.name ?? 'unknown';
    _ratePointer = null;
    _rateKind = null;
    _rateStopwatch = null;
    _rateArmed = false;
    _emit(
      'P-rate summary end=${wasCancelled ? 'cancel' : 'up'} '
      'durationMs=${(durationSeconds * 1000).toStringAsFixed(1)} '
      'rateHz=${rate.toStringAsFixed(1)} ${_formatPointerStats(stats)} '
      'kind=$kind',
    );
  }

  String _formatPointerStats(RollingWindowStats stats) {
    final String minimumGap = stats.minimumGapMicroseconds?.toString() ?? 'n/a';
    final String medianGap =
        stats.medianGapMicroseconds?.toStringAsFixed(0) ?? 'n/a';
    final String pressure = stats.minimumPressure == null
        ? 'n/a'
        : '${stats.minimumPressure!.toStringAsFixed(3)}..'
              '${stats.maximumPressure!.toStringAsFixed(3)}';
    return 'moves=${stats.count} minGapUs=$minimumGap medianGapUs=$medianGap '
        'distinct=${stats.distinctPositions} pressure=$pressure';
  }

  void _toggleCapabilitiesProbe() {
    if (_capsActive) {
      final bool barrelPresent = _sawButtonsChangedEvent || _sawNonZeroButtons;
      _capsActive = false;
      _emit(
        'P-caps summary maxTouches=${_touchCounter.maximum} '
        'barrelPresent=$barrelPresent '
        'buttonsChanged=$_sawButtonsChangedEvent '
        'nonZeroButtons=$_sawNonZeroButtons',
      );
      return;
    }
    _touchCounter.reset();
    _sawButtonsChangedEvent = false;
    _sawNonZeroButtons = false;
    _capsActive = true;
    _emit(
      'P-caps started — hold multiple fingers together, then press the '
      'barrel button; tap P-caps again to finish',
    );
  }

  void _startFrameProbe() {
    if (!_beginPerformanceProbe('P-frame')) {
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _busyProbe == 'P-frame') {
        _armFrameProbe();
      }
    });
  }

  void _armFrameProbe() {
    _targetFrameNumbers.clear();
    _frameTimings.clear();
    _unattributedFrameTimings.clear();
    _frameTickCount = 0;
    _collectingFrames = true;
    final ui.PlatformDispatcher dispatcher = ui.PlatformDispatcher.instance;
    _previousTimingsCallback = dispatcher.onReportTimings;
    dispatcher.onReportTimings = _installedTimingsCallback;
    _frameTimeout?.cancel();
    _frameTimeout = Timer(
      const Duration(seconds: 20),
      () => _finishFrameProbe(timedOut: true),
    );
    _frameTicker.start();
  }

  void _handleFrameTick(Duration elapsed) {
    if (!_collectingFrames) {
      return;
    }
    _frameTickCount++;
    _frameSignal.value = _frameTickCount;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_collectingFrames) {
        return;
      }
      _targetFrameNumbers.add(
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      );
      _maybeFinishFrameProbe();
    });
    if (_frameTickCount >= _frameCount) {
      _frameTicker.stop();
    }
  }

  void _handleFrameTimings(List<ui.FrameTiming> timings) {
    if (_collectingFrames) {
      for (final ui.FrameTiming timing in timings) {
        if (_targetFrameNumbers.contains(timing.frameNumber)) {
          _frameTimings[timing.frameNumber] = timing;
        } else if (timing.frameNumber == -1 &&
            _unattributedFrameTimings.length < _frameCount) {
          _unattributedFrameTimings.add(timing);
        }
      }
      _maybeFinishFrameProbe();
    }
    _previousTimingsCallback?.call(timings);
  }

  void _maybeFinishFrameProbe() {
    if (!_collectingFrames || _targetFrameNumbers.length < _frameCount) {
      return;
    }
    final int received =
        _frameTimings.length + _unattributedFrameTimings.length;
    if (received >= _frameCount) {
      scheduleMicrotask(_finishFrameProbe);
    }
  }

  void _finishFrameProbe({bool timedOut = false}) {
    if (!_collectingFrames) {
      return;
    }
    _collectingFrames = false;
    _frameTicker.stop();
    _frameTimeout?.cancel();
    _frameTimeout = null;
    _restoreTimingsCallback();
    if (!mounted) {
      return;
    }
    final List<ui.FrameTiming> timings = <ui.FrameTiming>[
      ..._targetFrameNumbers
          .map((int frame) => _frameTimings[frame])
          .whereType<ui.FrameTiming>(),
      ..._unattributedFrameTimings,
    ].take(_frameCount).toList(growable: false);
    if (timings.isEmpty) {
      _emit(
        'P-frame failed: no FrameTiming records${timedOut ? ' before timeout' : ''}',
        clearBusy: true,
      );
      return;
    }
    final List<double> buildMilliseconds = timings
        .map(
          (ui.FrameTiming timing) => timing.buildDuration.inMicroseconds / 1000,
        )
        .toList(growable: false);
    final List<double> rasterMilliseconds = timings
        .map(
          (ui.FrameTiming timing) =>
              timing.rasterDuration.inMicroseconds / 1000,
        )
        .toList(growable: false);
    _emit(
      'P-frame result frames=${timings.length}/$_frameCount '
      'buildMs p50=${percentile(buildMilliseconds, 0.50).toStringAsFixed(2)} '
      'p95=${percentile(buildMilliseconds, 0.95).toStringAsFixed(2)} '
      'rasterMs p50=${percentile(rasterMilliseconds, 0.50).toStringAsFixed(2)} '
      'p95=${percentile(rasterMilliseconds, 0.95).toStringAsFixed(2)}'
      '${timedOut ? ' timedOut=true' : ''}',
      clearBusy: true,
    );
  }

  void _restoreTimingsCallback() {
    final ui.PlatformDispatcher dispatcher = ui.PlatformDispatcher.instance;
    if (identical(dispatcher.onReportTimings, _installedTimingsCallback)) {
      dispatcher.onReportTimings = _previousTimingsCallback;
    }
    _previousTimingsCallback = null;
  }

  Future<void> _runUploadProbe() async {
    if (!_beginPerformanceProbe('P-upload')) {
      return;
    }
    try {
      final List<double> milliseconds = await runImageUploadProbe();
      if (!mounted) {
        return;
      }
      _emit(
        'P-upload result iterations=${milliseconds.length} '
        'ms p50=${percentile(milliseconds, 0.50).toStringAsFixed(2)} '
        'p95=${percentile(milliseconds, 0.95).toStringAsFixed(2)}',
        clearBusy: true,
      );
    } on Object catch (error) {
      if (mounted) {
        _emit('P-upload failed: $error', clearBusy: true);
      }
    }
  }

  Future<void> _runIsolateProbe() async {
    if (!_beginPerformanceProbe('P-isolate')) {
      return;
    }
    try {
      final IsolateProbeResult result = await widget.isolateRunner.run();
      if (!mounted) {
        return;
      }
      _emit(
        'P-isolate result iterations=${result.roundTripMilliseconds.length} '
        'roundTripMs p50='
        '${percentile(result.roundTripMilliseconds, 0.50).toStringAsFixed(2)} '
        'p95=${percentile(result.roundTripMilliseconds, 0.95).toStringAsFixed(2)} '
        'blendMs p50='
        '${percentile(result.blendMilliseconds, 0.50).toStringAsFixed(2)} '
        'p95=${percentile(result.blendMilliseconds, 0.95).toStringAsFixed(2)}',
        clearBusy: true,
      );
    } on Object catch (error) {
      if (mounted) {
        _emit('P-isolate failed: $error', clearBusy: true);
      }
    }
  }

  bool _beginPerformanceProbe(String name) {
    if (_busyProbe != null || _rateArmed || _capsActive) {
      return false;
    }
    _emit('$name started', busyProbe: name);
    return true;
  }

  void _emit(String message, {String? busyProbe, bool clearBusy = false}) {
    final String line = 'INK_PROBE: $message';
    debugPrint(line);
    if (!mounted) {
      return;
    }
    setState(() {
      if (clearBusy) {
        _busyProbe = null;
      } else if (busyProbe != null) {
        _busyProbe = busyProbe;
      }
      _logLines.insert(0, line);
      if (_logLines.length > _maximumLogLines) {
        _logLines.removeRange(_maximumLogLines, _logLines.length);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final PaperThemeData theme = PaperTheme.of(context);
    final bool performanceAvailable =
        _busyProbe == null && !_rateArmed && !_capsActive;
    return ColoredBox(
      color: theme.palette.paper,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RepaintBoundary(
              child: CustomPaint(
                painter: _loadPainter,
                isComplex: true,
                willChange: true,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(PaperSpacing.space16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Ink · WP0 probes',
                      style: theme.type.title.copyWith(
                        color: theme.palette.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: PaperSpacing.space8),
                    Text(
                      'Release AOT only. Run one probe at a time.',
                      style: theme.type.body.copyWith(
                        color: theme.palette.gray33,
                      ),
                    ),
                    const SizedBox(height: PaperSpacing.space12),
                    Wrap(
                      spacing: PaperSpacing.space8,
                      runSpacing: PaperSpacing.space8,
                      children: <Widget>[
                        PaperButton(
                          label: _rateArmed ? 'P-rate: cancel' : 'P-rate',
                          onPressed: _busyProbe == null && !_capsActive
                              ? _toggleRateProbe
                              : null,
                        ),
                        PaperButton(
                          label: 'P-frame',
                          onPressed: performanceAvailable
                              ? _startFrameProbe
                              : null,
                        ),
                        PaperButton(
                          label: 'P-upload',
                          onPressed: performanceAvailable
                              ? () => unawaited(_runUploadProbe())
                              : null,
                        ),
                        PaperButton(
                          label: 'P-isolate',
                          onPressed: performanceAvailable
                              ? () => unawaited(_runIsolateProbe())
                              : null,
                        ),
                        PaperButton(
                          label: _capsActive ? 'P-caps: finish' : 'P-caps',
                          onPressed: _busyProbe == null && !_rateArmed
                              ? _toggleCapabilitiesProbe
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: PaperSpacing.space12),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.palette.paper,
                          border: Border.all(
                            color: theme.palette.gray99,
                            width: PaperSpacing.hairline,
                          ),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(PaperSpacing.space12),
                          child: Text(
                            _logLines.join('\n'),
                            key: const ValueKey<String>('probe-log'),
                            style: theme.type.mono.copyWith(
                              color: theme.palette.ink,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
