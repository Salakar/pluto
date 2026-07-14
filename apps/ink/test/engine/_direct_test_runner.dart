import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:test_core/src/direct_run.dart';

import 'canvas_controller_test.dart' as canvas_controller_test;
import 'brush_engine_test.dart' as brush_engine_test;
import 'brush_panel_test.dart' as brush_panel_test;
import 'brush_presets_test.dart' as brush_presets_test;
import 'compositor_test.dart' as compositor_test;
import 'eraser_tool_test.dart' as eraser_tool_test;
import 'geometry_test.dart' as geometry_test;
import 'proof_sheet_test.dart' as proof_sheet_test;
import 'raster_worker_test.dart' as raster_worker_test;
import 'shade_snapshot_test.dart' as shade_snapshot_test;
import 'stroke_commit_test.dart' as stroke_commit_test;
import 'stroke_pipeline_test.dart' as stroke_pipeline_test;
import 'stroke_preview_test.dart' as stroke_preview_test;
import 'wp4_brush_catalog_test.dart' as wp4_brush_catalog_test;
import 'wp4_brush_mechanics_test.dart' as wp4_brush_mechanics_test;
import 'wp4_brush_overlap_test.dart' as wp4_brush_overlap_test;

Future<void> main() async {
  var success = await directRunTests(geometry_test.main);
  success = await directRunTests(canvas_controller_test.main) && success;
  success = await directRunTests(brush_presets_test.main) && success;
  success = await directRunTests(wp4_brush_catalog_test.main) && success;
  success = await directRunTests(stroke_pipeline_test.main) && success;
  success = await directRunTests(brush_engine_test.main) && success;
  success = await directRunTests(wp4_brush_mechanics_test.main) && success;
  success = await directRunTests(wp4_brush_overlap_test.main) && success;
  success = await directRunTests(shade_snapshot_test.main) && success;
  success = await directRunTests(stroke_preview_test.main) && success;
  success = await directRunTests(stroke_commit_test.main) && success;
  success = await directRunTests(proof_sheet_test.main) && success;
  success = await directRunTests(brush_panel_test.main) && success;
  success = await directRunTests(eraser_tool_test.main) && success;
  success = await directRunTests(compositor_test.main) && success;
  success = await directRunTests(raster_worker_test.main) && success;
  stdout.writeln('DIRECT_ENGINE_TEST_RESULT=${success ? 'PASS' : 'FAIL'}');
  exit(success ? 0 : 1);
}
