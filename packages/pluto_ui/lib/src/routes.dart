import 'package:flutter/widgets.dart';

import 'components.dart';
import 'paper_theme.dart';
import 'refresh.dart';
import 'package:pluto_core/pluto_core.dart';

/// Zero-duration page route for discrete e-ink page flips.
final class PaperPageRoute<T> extends PageRoute<T> {
  /// Creates a paper page route.
  PaperPageRoute({required this.builder, super.settings});

  /// Builds the route page.
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// Helpers for paper dialogs and sheets.
abstract final class PaperDialogs {
  /// Shows a centered paper dialog.
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.ui,
      reason: 'dialog.open',
    );
    return Navigator.of(context).push<T>(
      _PaperDialogRoute<T>(
        builder: builder,
        barrierDismissible: barrierDismissible,
      ),
    );
  }

  /// Shows a bottom paper sheet.
  static Future<T?> showSheet<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    EinkRefreshRegion.request(
      context,
      refreshClass: RefreshClass.ui,
      reason: 'sheet.open',
    );
    return Navigator.of(context).push<T>(
      _PaperSheetRoute<T>(
        builder: builder,
        barrierDismissible: barrierDismissible,
      ),
    );
  }

  /// Shows a two-action confirmation dialog.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    PaperButtonVariant confirmVariant = PaperButtonVariant.primary,
    Duration armingDelay = const Duration(milliseconds: 600),
  }) async {
    final bool? result = await show<bool>(
      context,
      builder: (BuildContext context) {
        return PaperDialog(
          title: title,
          actions: <Widget>[
            PaperButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
            ),
            PaperButton(
              label: confirmLabel,
              onPressed: () => Navigator.of(context).pop(true),
              variant: confirmVariant,
              armingDelay: armingDelay,
            ),
          ],
          child: Text(message, style: PaperTheme.of(context).type.body),
        );
      },
    );
    return result ?? false;
  }
}

final class _PaperDialogRoute<T> extends PageRoute<T> {
  _PaperDialogRoute({required this.builder, required this.barrierDismissible});

  final WidgetBuilder builder;

  @override
  final bool barrierDismissible;

  @override
  Color get barrierColor => const Color(0x00000000);

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  /// Paper veil that washes the page out behind overlays. On e-ink this
  /// dithers to pale gray without the ghosting risk of a dark scrim.
  static const Color veil = Color(0xD9FFFFFF);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: barrierDismissible ? () => Navigator.of(context).pop() : null,
      child: ColoredBox(
        color: veil,
        child: GestureDetector(onTap: () {}, child: builder(context)),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

final class _PaperSheetRoute<T> extends _PaperDialogRoute<T> {
  _PaperSheetRoute({required super.builder, required super.barrierDismissible});

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final PaperThemeData theme = PaperTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: barrierDismissible ? () => Navigator.of(context).pop() : null,
      child: ColoredBox(
        color: _PaperDialogRoute.veil,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.palette.paper,
                border: Border(
                  top: BorderSide(
                    color: theme.palette.ink,
                    width: PaperSpacing.heavyRule,
                  ),
                ),
              ),
              child: SizedBox(width: double.infinity, child: builder(context)),
            ),
          ),
        ),
      ),
    );
  }
}
