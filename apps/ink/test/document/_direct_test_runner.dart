import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:test_core/src/direct_run.dart';

import 'document_io_test.dart' as document_io_test;
import 'document_test.dart' as document_test;
import 'gallery_store_test.dart' as gallery_store_test;
import 'tile_codec_test.dart' as tile_codec_test;
import 'tile_store_test.dart' as tile_store_test;
import 'undo_journal_wp1_test.dart' as undo_journal_test;
import '../app_smoke_test.dart' as app_smoke_test;
import '../probe_math_test.dart' as probe_math_test;
import '../services_test.dart' as services_test;

Future<void> main() async {
  var success = await directRunTests(document_test.main);
  success = await directRunTests(tile_store_test.main) && success;
  success = await directRunTests(tile_codec_test.main) && success;
  success = await directRunTests(document_io_test.main) && success;
  success = await directRunTests(gallery_store_test.main) && success;
  success = await directRunTests(undo_journal_test.main) && success;
  success = await directRunTests(services_test.main) && success;
  success = await directRunTests(probe_math_test.main) && success;
  success = await directRunTests(app_smoke_test.main) && success;
  stdout.writeln('DIRECT_TEST_RESULT=${success ? 'PASS' : 'FAIL'}');
  exit(success ? 0 : 1);
}
