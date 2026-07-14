import '../document/undo_journal.dart' show JournalKind;

export '../document/undo_journal.dart' show JournalKind;

/// Marker interface for immutable commands emitted by an interaction tool.
abstract interface class ToolCommand {}

/// A command that becomes one document undo-journal entry when committed.
abstract interface class JournaledToolCommand implements ToolCommand {
  /// Stable journal kind from the Ink document format.
  JournalKind get journalKind;
}

/// Closed union of tools understood by Ink's input router and chrome.
sealed class Tool {
  const Tool(this.id, this.label);

  /// Stable persisted identifier.
  final String id;

  /// Short user-facing label.
  final String label;
}

/// Freehand drawing through the current brush.
final class DrawToolKind extends Tool {
  /// Creates the canonical draw tool value.
  const DrawToolKind() : super('draw', 'draw');
}

/// Pixel, stroke, or lasso erasing.
final class EraserToolKind extends Tool {
  /// Creates the canonical eraser tool value.
  const EraserToolKind() : super('erase', 'erase');
}

/// Rectangular, lasso, and contiguous-color selection.
final class SelectionToolKind extends Tool {
  /// Creates the canonical selection tool value.
  const SelectionToolKind() : super('select', 'select');
}

/// Float or whole-layer affine transformation.
final class TransformToolKind extends Tool {
  /// Creates the canonical transform tool value.
  const TransformToolKind() : super('transform', 'transform');
}

/// Contiguous raster filling.
final class FillToolKind extends Tool {
  /// Creates the canonical fill tool value.
  const FillToolKind() : super('fill', 'fill');
}

/// Brush-stamped geometric shapes.
final class ShapeToolKind extends Tool {
  /// Creates the canonical shape tool value.
  const ShapeToolKind() : super('shape', 'shape');
}

/// Editable text-block placement.
final class TextToolKind extends Tool {
  /// Creates the canonical text tool value.
  const TextToolKind() : super('text', 'text');
}

/// Radius-averaged canvas color sampling.
final class EyedropperToolKind extends Tool {
  /// Creates the canonical eyedropper tool value.
  const EyedropperToolKind() : super('picker', 'picker');
}

/// Persistent guide and symmetry configuration.
final class GuidesToolKind extends Tool {
  /// Creates the canonical guides tool value.
  const GuidesToolKind() : super('guides', 'guides');
}

/// Locked, non-exporting reference placement.
final class ReferenceToolKind extends Tool {
  /// Creates the canonical reference tool value.
  const ReferenceToolKind() : super('reference', 'reference');
}

/// Artwork-bounds cropping that preserves off-bounds pixels.
final class CropToolKind extends Tool {
  /// Creates the canonical crop tool value.
  const CropToolKind() : super('crop', 'crop');
}

/// Canonical tool values in persisted/router order.
const List<Tool> inkTools = <Tool>[
  DrawToolKind(),
  EraserToolKind(),
  SelectionToolKind(),
  TransformToolKind(),
  FillToolKind(),
  ShapeToolKind(),
  TextToolKind(),
  EyedropperToolKind(),
  GuidesToolKind(),
  ReferenceToolKind(),
  CropToolKind(),
];

/// Why an otherwise valid layer-local tool action was refused.
enum ToolActionBlockReason {
  /// Content layers cannot be modified while locked.
  layerLocked,

  /// Hidden layers cannot be modified by interaction tools.
  layerHidden,
}

/// Closed generic result of applying the common layer action gate.
sealed class ToolActionResult<C extends ToolCommand> {
  const ToolActionResult();

  /// Whether the action produced an executable command.
  bool get isAllowed;
}

/// Allowed layer-local tool action.
final class AllowedToolAction<C extends ToolCommand>
    extends ToolActionResult<C> {
  /// Creates an allowed result containing [command].
  const AllowedToolAction(this.command);

  /// Immutable command that may be dispatched to the worker or journal.
  final C command;

  @override
  bool get isAllowed => true;
}

/// Refused layer-local tool action with user-facing chip text.
final class BlockedToolAction<C extends ToolCommand>
    extends ToolActionResult<C> {
  /// Creates a blocked result.
  const BlockedToolAction(this.reason);

  /// Locked or hidden reason.
  final ToolActionBlockReason reason;

  /// Canonical non-silent status-chip message.
  String get message => switch (reason) {
    ToolActionBlockReason.layerLocked => 'layer locked',
    ToolActionBlockReason.layerHidden => 'layer hidden',
  };

  @override
  bool get isAllowed => false;
}

/// Synchronous base lifecycle shared by interaction-tool controllers.
///
/// Deactivation only changes routing. Tool-specific durable state, such as a
/// selection mask or guide overlay, is deliberately retained unless [cancel]
/// explicitly clears it.
abstract interface class ToolControllerLifecycle {
  /// Tool represented by this controller.
  Tool get tool;

  /// Whether input is currently routed to this controller.
  bool get isActive;

  /// Whether this controller owns a live interaction or persistent overlay.
  bool get hasLiveState;

  /// Starts routing input to this controller.
  void activate();

  /// Stops routing input without discarding persistent state.
  void deactivate();

  /// Cancels this controller's current live interaction.
  void cancel();
}

/// Synchronous base lifecycle shared by interaction-tool controllers.
abstract base class ToolController<T extends Tool>
    implements ToolControllerLifecycle {
  /// Creates a controller for [tool].
  ToolController(this.tool);

  /// Tool represented by this controller.
  @override
  final T tool;

  bool _isActive = false;

  /// Whether input is currently routed to this controller.
  @override
  bool get isActive => _isActive;

  /// Whether the controller owns a draft, float, loupe, or other live state.
  @override
  bool get hasLiveState;

  /// Starts routing input to the controller.
  @override
  void activate() {
    _isActive = true;
  }

  /// Stops routing input without discarding persistent state.
  @override
  void deactivate() {
    _isActive = false;
  }

  /// Applies the binding locked/hidden-layer gate to a command factory.
  ///
  /// [bypassLock] is reserved for reference placement transforms. Hidden
  /// layers remain blocked so every invisible edit has explicit feedback.
  ToolActionResult<C> gateLayerAction<C extends ToolCommand>({
    required bool isLayerVisible,
    required bool isLayerLocked,
    required C Function() createCommand,
    bool bypassLock = false,
  }) {
    if (!isLayerVisible) {
      return BlockedToolAction<C>(ToolActionBlockReason.layerHidden);
    }
    if (isLayerLocked && !bypassLock) {
      return BlockedToolAction<C>(ToolActionBlockReason.layerLocked);
    }
    return AllowedToolAction<C>(createCommand());
  }

  /// Cancels the controller's current live interaction.
  @override
  void cancel();
}

/// Non-generic router facade for a concrete set of tool controllers.
///
/// The facade avoids importing individual controller libraries into this base
/// library, so tool modules stay acyclic while the editor still gets one
/// strongly validated activation path.
final class ToolControllerRouter {
  /// Creates a router, activates [initialToolId], and rejects duplicate ids.
  factory ToolControllerRouter({
    required Iterable<ToolControllerLifecycle> controllers,
    required String initialToolId,
  }) {
    final Map<String, ToolControllerLifecycle> byId =
        <String, ToolControllerLifecycle>{};
    for (final ToolControllerLifecycle controller in controllers) {
      final ToolControllerLifecycle? previous = byId[controller.tool.id];
      if (previous != null) {
        throw ArgumentError.value(
          controller.tool.id,
          'controllers',
          'contains a duplicate tool id',
        );
      }
      byId[controller.tool.id] = controller;
      controller.deactivate();
    }
    final ToolControllerLifecycle? initial = byId[initialToolId];
    if (initial == null) {
      throw ArgumentError.value(
        initialToolId,
        'initialToolId',
        'has no registered controller',
      );
    }
    initial.activate();
    return ToolControllerRouter._(
      Map<String, ToolControllerLifecycle>.unmodifiable(byId),
      initial,
    );
  }

  ToolControllerRouter._(this._controllers, this._activeController);

  final Map<String, ToolControllerLifecycle> _controllers;
  ToolControllerLifecycle _activeController;

  /// Currently active controller.
  ToolControllerLifecycle get activeController => _activeController;

  /// Currently active sealed-union tool value.
  Tool get activeTool => _activeController.tool;

  /// Registered controller ids.
  Set<String> get registeredToolIds =>
      Set<String>.unmodifiable(_controllers.keys);

  /// Looks up a controller without changing routing.
  ToolControllerLifecycle controllerFor(String toolId) {
    final ToolControllerLifecycle? controller = _controllers[toolId];
    if (controller == null) {
      throw ArgumentError.value(toolId, 'toolId', 'is not registered');
    }
    return controller;
  }

  /// Deactivates the old controller and activates [toolId].
  void select(String toolId) {
    final ToolControllerLifecycle next = controllerFor(toolId);
    if (identical(next, _activeController)) {
      return;
    }
    _activeController.deactivate();
    _activeController = next;
    _activeController.activate();
  }

  /// Cancels only the active controller's live interaction.
  void cancelActive() {
    _activeController.cancel();
  }
}
