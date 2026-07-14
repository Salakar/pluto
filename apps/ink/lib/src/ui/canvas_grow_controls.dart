import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import '../engine/canvas_ops.dart';

/// Menu controls for choosing a nine-grid anchor and growing the canvas 125%.
final class InkCanvasGrowControls extends StatelessWidget {
  /// Creates the canvas-grow menu controls.
  const InkCanvasGrowControls({
    required this.selectedAnchor,
    required this.onAnchorSelected,
    required this.onGrow,
    super.key,
  });

  /// Anchor currently kept stationary by the resize operation.
  final CanvasResizeAnchor selectedAnchor;

  /// Receives a newly selected nine-grid anchor.
  final ValueChanged<CanvasResizeAnchor> onAnchorSelected;

  /// Invokes the fixed grow operation with [selectedAnchor].
  final ValueChanged<CanvasResizeAnchor> onGrow;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          label: 'canvas resize anchor',
          child: Column(
            children: <Widget>[
              for (final List<CanvasResizeAnchor> row in _anchorRows)
                Row(
                  children: <Widget>[
                    for (final CanvasResizeAnchor anchor in row)
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: PaperButton.ghost(
                            key: ValueKey<String>(
                              'canvas-anchor-${anchor.name}',
                            ),
                            label:
                                '${anchor == selectedAnchor ? '• ' : ''}'
                                '${_anchorLabel(anchor)}',
                            onPressed: () => onAnchorSelected(anchor),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        SizedBox(
          height: 48,
          child: PaperButton.ghost(
            key: const ValueKey<String>('canvas-grow-125'),
            label: 'grow canvas 125%',
            onPressed: () => onGrow(selectedAnchor),
          ),
        ),
      ],
    );
  }
}

const List<List<CanvasResizeAnchor>> _anchorRows = <List<CanvasResizeAnchor>>[
  <CanvasResizeAnchor>[
    CanvasResizeAnchor.topLeft,
    CanvasResizeAnchor.topCenter,
    CanvasResizeAnchor.topRight,
  ],
  <CanvasResizeAnchor>[
    CanvasResizeAnchor.centerLeft,
    CanvasResizeAnchor.center,
    CanvasResizeAnchor.centerRight,
  ],
  <CanvasResizeAnchor>[
    CanvasResizeAnchor.bottomLeft,
    CanvasResizeAnchor.bottomCenter,
    CanvasResizeAnchor.bottomRight,
  ],
];

String _anchorLabel(CanvasResizeAnchor anchor) => switch (anchor) {
  CanvasResizeAnchor.topLeft => 'top left',
  CanvasResizeAnchor.topCenter => 'top',
  CanvasResizeAnchor.topRight => 'top right',
  CanvasResizeAnchor.centerLeft => 'left',
  CanvasResizeAnchor.center => 'center',
  CanvasResizeAnchor.centerRight => 'right',
  CanvasResizeAnchor.bottomLeft => 'bottom left',
  CanvasResizeAnchor.bottomCenter => 'bottom',
  CanvasResizeAnchor.bottomRight => 'bottom right',
};
