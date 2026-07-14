import 'package:flutter/widgets.dart';
import 'package:pluto_ui/pluto_ui.dart';

import 'app_model.dart';
import 'paper/layout.dart';
import 'paper/theme.dart';
import 'services.dart';
import 'ui/chat_page.dart';

/// Paper Codex app root: bare WidgetsApp (no Material), zero-duration paper
/// routes, palette chosen by the panel.
final class PaperCodexApp extends StatefulWidget {
  const PaperCodexApp({required this.services, super.key});

  final CodexServices services;

  @override
  State<PaperCodexApp> createState() => _PaperCodexAppState();
}

final class _PaperCodexAppState extends State<PaperCodexApp> {
  late final CodexAppModel _model;

  @override
  void initState() {
    super.initState();
    _model = CodexAppModel(services: widget.services);
    // Fire and forget: the page renders its empty state until loaded.
    // ignore: discarded_futures
    _model.init();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PaperCodexAppForModel(
      model: _model,
      isColor: widget.services.panel.isColor,
    );
  }
}

/// App shell around an externally-owned model (tests and goldens inject
/// prepared state; the runtime wraps it via [PaperCodexApp]).
final class PaperCodexAppForModel extends StatelessWidget {
  const PaperCodexAppForModel({
    required this.model,
    required this.isColor,
    super.key,
  });

  final CodexAppModel model;
  final bool isColor;

  @override
  Widget build(BuildContext context) {
    final ink = isColor ? const PaperInk.color() : const PaperInk.mono();
    return PaperCodexTheme(
      ink: ink,
      child: WidgetsApp(
        color: const Color(0xFFFFFFFF),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(builder: builder, settings: settings),
        home: PageScaleViewport(
          child: ListenableBuilder(
            listenable: model,
            builder: (context, _) => ChatPage(model: model),
          ),
        ),
      ),
    );
  }
}
