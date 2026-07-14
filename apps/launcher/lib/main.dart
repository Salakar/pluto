import 'package:flutter/widgets.dart';

import 'src/launcher_app.dart';
import 'src/real_services.dart';

export 'src/launcher_app.dart';
export 'src/models.dart';
export 'src/real_services.dart';
export 'src/services.dart';

/// Starts Pluto Home.
void main(List<String> arguments) {
  runApp(
    PlutoLauncherApp(
      services: createRealServices(),
      initialRoute: arguments.contains('--standby')
          ? '/standby'
          : arguments.contains('--power-menu')
          ? '/power'
          : arguments.contains('--status')
          ? '/status'
          : arguments.contains('--switcher')
          ? '/switcher'
          : '/',
    ),
  );
}
