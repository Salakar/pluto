import 'dart:async';

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

/// Auto-scrolling text list: constant-velocity motion, then a full stop so
/// the renderer can settle after MOVE-heavy updates.
final class ScrollListScene extends StatefulWidget {
  /// Creates the scroll-list scene.
  const ScrollListScene({super.key});

  @override
  State<ScrollListScene> createState() => _ScrollListSceneState();
}

final class _ScrollListSceneState extends State<ScrollListScene>
    with SceneRestFreeze {
  static const int _rowCount = 400;
  static const double _rowHeight = 48;
  static const Duration _legDuration = Duration(seconds: 6);
  static const Duration _pauseDuration = Duration(seconds: 4);

  /// 240 px/s * 6 s.
  static const double _legDistance = 1440;

  final ScrollController _controller = ScrollController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted) {
        _startLeg();
      }
    });
  }

  @override
  void freezeForRest() {
    _timer?.cancel();
    _timer = null;
    if (_controller.hasClients) {
      // Jumping to the current offset cancels an in-flight animateTo
      // without moving the viewport.
      _controller.position.jumpTo(_controller.position.pixels);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startLeg() {
    if (!_controller.hasClients) {
      return;
    }
    final double maxExtent = _controller.position.maxScrollExtent;
    double from = _controller.offset;
    if (from + _legDistance > maxExtent) {
      _controller.jumpTo(0);
      from = 0;
    }
    unawaited(
      _controller.animateTo(
        from + _legDistance,
        duration: _legDuration,
        curve: Curves.linear,
      ),
    );
    _timer = Timer(_legDuration + _pauseDuration, _startLeg);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'SCROLL LIST', purpose: 'MOVE + SETTLE'),
        Expanded(
          child: ListView.builder(
            controller: _controller,
            physics: const ClampingScrollPhysics(),
            itemExtent: _rowHeight,
            itemCount: _rowCount,
            itemBuilder: (BuildContext context, int index) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: index.isEven ? labPaper : labGrayLight,
                  border: const Border(
                    bottom: BorderSide(width: 1, color: labInk),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      'ROW ${index.toString().padLeft(4, '0')}',
                      style: labMonoStyle,
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        'the quick brown fox jumps over the lazy dog',
                        style: labBodyStyle,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
