import 'package:flutter/widgets.dart';

import '../dock/contextual_dock.dart';

/// Maps a stable tool id to the complete contextual-dock state it owns.
///
/// Drawing, picking, and unknown future tools have no contextual bar.
/// The editor separately supplies [InkContextualDockHost.hasLiveState], keeping
/// lifecycle knowledge with its tool controllers.
ContextualDockMode? inkContextualDockModeForTool(String toolId) {
  return switch (toolId) {
    'erase' => ContextualDockMode.erase,
    'select' => ContextualDockMode.selection,
    'transform' => ContextualDockMode.transform,
    'fill' => ContextualDockMode.fill,
    'shape' => ContextualDockMode.shape,
    'text' => ContextualDockMode.text,
    'crop' => ContextualDockMode.crop,
    'guides' => ContextualDockMode.guides,
    _ => null,
  };
}

/// Callback-driven visibility boundary around the WP5 contextual dock.
///
/// It performs a whole-widget state swap with no animation. Tool controllers
/// remain the source of truth for whether a selection, transform, shape, text,
/// crop, fill preview, or persistent guide state is currently live.
final class InkContextualDockHost extends StatelessWidget {
  /// Creates a contextual slot for one active tool.
  const InkContextualDockHost({
    required this.activeToolId,
    required this.hasLiveState,
    required this.onAction,
    this.selectedActions = const <ContextualDockAction>{},
    this.disabledActions = const <ContextualDockAction>{},
    super.key,
  });

  /// Stable active tool id.
  final String activeToolId;

  /// Whether that tool controller currently owns live state.
  final bool hasLiveState;

  /// Receives the WP5 dock's stable action identifiers.
  final ValueChanged<ContextualDockAction> onAction;

  /// Toggle-like actions currently selected.
  final Set<ContextualDockAction> selectedActions;

  /// Visible actions that are currently unavailable.
  final Set<ContextualDockAction> disabledActions;

  @override
  Widget build(BuildContext context) {
    final ContextualDockMode? mode = inkContextualDockModeForTool(activeToolId);
    if (!hasLiveState || mode == null) {
      return const SizedBox.shrink(
        key: ValueKey<String>('ink-contextual-dock-hidden'),
      );
    }
    return ContextualDock(
      key: const ValueKey<String>('ink-contextual-dock-visible'),
      mode: mode,
      selectedActions: selectedActions,
      disabledActions: disabledActions,
      onAction: onAction,
    );
  }
}
