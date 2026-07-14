import 'package:flutter/widgets.dart';

import '../tools/reference_tool.dart';

/// Applies a reference layer's validated render opacity to its image subtree.
final class ReferenceLayerOpacity extends StatelessWidget {
  /// Creates the opacity boundary for [layer].
  const ReferenceLayerOpacity({
    required this.layer,
    required this.child,
    super.key,
  });

  /// Reference layer whose current opacity drives composition.
  final ReferenceLayer layer;

  /// Placed reference-image subtree.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(opacity: layer.opacity, child: child);
  }
}
