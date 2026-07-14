import 'package:flutter/widgets.dart';

import 'src/probe/probe_page.dart';
import 'src/ui/app.dart';
import 'src/ui/proof_sheet.dart';

export 'src/ui/app.dart' show InkApp, InkAppForModel;

const bool _inkProbeEnabled =
    bool.fromEnvironment('INK_PROBE') ||
    String.fromEnvironment('INK_PROBE') == '1';

const bool _inkTuneEnabled =
    bool.fromEnvironment('INK_TUNE') ||
    String.fromEnvironment('INK_TUNE') == '1';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    _inkProbeEnabled
        ? const InkProbeApp()
        : _inkTuneEnabled
        ? const InkProofSheetApp()
        : const InkApp(),
  );
}
