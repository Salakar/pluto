import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await CodexServices.createReal();
  runApp(PaperCodexApp(services: services));
}
