import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:test_core/src/direct_run.dart';

import 'palm_guard_test.dart' as palm_guard_test;
import 'pen_router_test.dart' as pen_router_test;
import 'touch_gesture_test.dart' as touch_gesture_test;

Future<void> main() async {
  var success = await directRunTests(palm_guard_test.main);
  success = await directRunTests(touch_gesture_test.main) && success;
  success = await directRunTests(pen_router_test.main) && success;
  stdout.writeln('DIRECT_INPUT_TEST_RESULT=${success ? 'PASS' : 'FAIL'}');
  exit(success ? 0 : 1);
}
