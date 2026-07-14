import 'dart:async';

import 'package:flutter/widgets.dart';

import '../lab_style.dart';
import '../scene.dart';

const String _articleBody =
    'Full-content page turns are where the flash policy earns its keep: '
    'the whole viewport changes at once, so the scheduler must decide '
    'between a clean flashing refresh and a faster, ghost-prone update. '
    'Alternating layouts guarantee near-total damage every two seconds.';

const String _articleBodyTwo =
    'The A layout is a text article; the B layout is a tiled grid with an '
    'inverted header. Their structure shares no pixels, which makes any '
    'partial-update shortcut visible on camera as residue from the '
    'previous page.';

/// Full-content page transitions every two seconds: flash policy.
final class PageTurnScene extends StatefulWidget {
  /// Creates the page-turn scene.
  const PageTurnScene({super.key});

  @override
  State<PageTurnScene> createState() => _PageTurnSceneState();
}

final class _PageTurnSceneState extends State<PageTurnScene>
    with SceneRestFreeze {
  static const Duration _turnPeriod = Duration(seconds: 2);

  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_turnPeriod, (Timer timer) {
      setState(() {
        _page += 1;
      });
    });
  }

  @override
  void freezeForRest() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SceneHeader(title: 'PAGE TURN', purpose: 'FLASH POLICY'),
        Expanded(
          child: _page.isEven
              ? _ArticlePage(page: _page)
              : _GridPage(page: _page),
        ),
      ],
    );
  }
}

final class _ArticlePage extends StatelessWidget {
  const _ArticlePage({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'PAGE A-${page.toString().padLeft(3, '0')}',
            style: labMonoStyle,
          ),
          const SizedBox(height: 12),
          const Text(
            'The ledger pays for every impulse.',
            style: labTitleStyle,
          ),
          const SizedBox(height: 12),
          const Text(_articleBody, style: labBodyStyle),
          const SizedBox(height: 12),
          const Text(_articleBodyTwo, style: labBodyStyle),
          const Spacer(),
          Container(height: 3, color: labInk),
          const SizedBox(height: 8),
          const Text('ARTICLE LAYOUT — TEXT-DOMINANT', style: labCaptionStyle),
        ],
      ),
    );
  }
}

final class _GridPage extends StatelessWidget {
  const _GridPage({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            color: labInk,
            child: Text(
              'PAGE B-${page.toString().padLeft(3, '0')}',
              style: labBannerStyle.copyWith(fontSize: 20),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Column(
              children: <Widget>[
                for (int row = 0; row < 3; row += 1)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: <Widget>[
                          for (int column = 0; column < 2; column += 1)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  right: column == 0 ? 12 : 0,
                                ),
                                child: _GridTile(row: row, column: column),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Text('GRID LAYOUT — TILE-DOMINANT', style: labCaptionStyle),
        ],
      ),
    );
  }
}

final class _GridTile extends StatelessWidget {
  const _GridTile({required this.row, required this.column});

  final int row;

  final int column;

  @override
  Widget build(BuildContext context) {
    final bool isFilled = (row + column).isEven;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isFilled ? labInk : labPaper,
        border: labRuleBorder,
      ),
      child: Text(
        'B$row$column',
        style: labTitleStyle.copyWith(color: isFilled ? labPaper : labInk),
      ),
    );
  }
}
