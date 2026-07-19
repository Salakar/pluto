import 'package:flutter/widgets.dart';
import 'package:pluto_core/pluto_core.dart';

/// Structured refresh hint emitted by paper widgets.
@immutable
final class EinkRefreshHint {
  /// Creates a refresh hint.
  const EinkRefreshHint({
    required this.refreshClass,
    required this.reason,
    this.globalRect,
  });

  /// Requested refresh quality class.
  final RefreshClass refreshClass;

  /// Human-readable reason useful in tests and diagnostics.
  final String reason;

  /// Global logical bounds for the damaged widget when known.
  final Rect? globalRect;
}

/// Receives refresh hints from [EinkRefreshRegion] and paper controls.
typedef EinkRefreshHintSink = void Function(EinkRefreshHint hint);

/// Inherited sink used by tests and the embedder channel adapter.
final class EinkRefreshScope extends InheritedWidget {
  /// Creates a refresh hint scope.
  const EinkRefreshScope({
    required this.onHint,
    required super.child,
    super.key,
  });

  /// Callback invoked when a child requests an e-ink refresh class.
  final EinkRefreshHintSink onHint;

  /// Returns the nearest hint sink, if one is installed.
  static EinkRefreshHintSink? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<EinkRefreshScope>()
        ?.onHint;
  }

  /// Sends a refresh hint using the nearest [EinkRefreshScope].
  static void request(
    BuildContext context, {
    required RefreshClass refreshClass,
    required String reason,
  }) {
    final EinkRefreshHintSink? sink = maybeOf(context);
    if (sink == null) {
      return;
    }
    final RenderObject? renderObject = context.findRenderObject();
    Rect? rect;
    if (renderObject is RenderBox && renderObject.hasSize) {
      rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    sink(
      EinkRefreshHint(
        refreshClass: refreshClass,
        reason: reason,
        globalRect: rect,
      ),
    );
  }

  @override
  bool updateShouldNotify(EinkRefreshScope oldWidget) {
    return onHint != oldWidget.onHint;
  }
}

/// Declares the refresh class for damage produced by [child].
final class EinkRefreshRegion extends StatelessWidget {
  /// Creates a refresh class region.
  const EinkRefreshRegion({
    required this.refreshClass,
    required this.child,
    this.reason = 'region',
    super.key,
  });

  /// Refresh class to use for visual changes inside [child].
  final RefreshClass refreshClass;

  /// Diagnostic reason emitted when [request] is called.
  final String reason;

  /// Region contents.
  final Widget child;

  /// Requests a refresh for the nearest widget context.
  static void request(
    BuildContext context, {
    required RefreshClass refreshClass,
    required String reason,
  }) {
    EinkRefreshScope.request(
      context,
      refreshClass: refreshClass,
      reason: reason,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _EinkRefreshMarker(
      refreshClass: refreshClass,
      reason: reason,
      child: child,
    );
  }
}

final class _EinkRefreshMarker extends InheritedWidget {
  const _EinkRefreshMarker({
    required this.refreshClass,
    required this.reason,
    required super.child,
  });

  final RefreshClass refreshClass;
  final String reason;

  static _EinkRefreshMarker? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_EinkRefreshMarker>();
  }

  @override
  bool updateShouldNotify(_EinkRefreshMarker oldWidget) {
    return refreshClass != oldWidget.refreshClass || reason != oldWidget.reason;
  }
}

/// Requests the refresh class from the nearest [EinkRefreshRegion].
void requestNearestEinkRefresh(BuildContext context, {String? reason}) {
  final _EinkRefreshMarker? marker = _EinkRefreshMarker.maybeOf(context);
  if (marker == null) {
    return;
  }
  EinkRefreshRegion.request(
    context,
    refreshClass: marker.refreshClass,
    reason: reason ?? marker.reason,
  );
}
