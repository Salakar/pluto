// Doc-image capture of the launcher home showing a single pinned app (Codex),
// written to docs/img/apps/. It is not a golden comparison — a one-shot
// capture, skipped unless CAPTURE_SHOWCASE=1, so it never runs in ordinary CI.
//
//   CAPTURE_SHOWCASE=1 flutter test test_goldens/showcase_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_launcher/main.dart';

import '../test/support/fake_services.dart';

const Size _panel = Size(954, 1696);
const Key _sceneKey = ValueKey<String>('launcher-showcase-scene');

void main() {
  final bool capture = Platform.environment['CAPTURE_SHOWCASE'] == '1';

  testWidgets('launcher home (codex only) showcase', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    tester.view.physicalSize = _panel;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // sampleFeaturedLauncherApps lists Codex first (pinned); take just it.
    final Uint8List codexIcon = _repoFile(
      'apps/codex/assets/pluto/icon.png',
    ).readAsBytesSync();
    final List<LauncherApp> apps = sampleFeaturedLauncherApps(
      icons: <String, Uint8List>{'dev.pluto.codex': codexIcon},
    ).take(1).toList();

    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: _sceneKey,
          child: SizedBox(
            width: _panel.width,
            height: _panel.height,
            child: PlutoLauncherApp(
              services: createHostPreviewServices(apps: apps),
              initialRoute: '/',
            ),
          ),
        ),
      ),
    );
    // Let the home route build first, then decode the app icon, then settle.
    await tester.pumpAndSettle();
    for (final Element element in find.byType(Image).evaluate()) {
      final Image image = element.widget as Image;
      await tester.runAsync(() => precacheImage(image.image, element));
    }
    await tester.pumpAndSettle();

    if (!capture) {
      return;
    }
    final RenderRepaintBoundary boundary =
        tester.renderObject(find.byKey(_sceneKey)) as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final File out = _repoFile('docs/img/apps/launcher-home.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote ${out.path}');
  }, skip: !capture);
}

Future<void> _loadFonts() async {
  final Directory flutterRoot = _flutterRoot();
  final File testFont = _repoFile(
    'assets/test_fonts/JetBrainsMono-VariableFont_wght.ttf',
  );
  await (FontLoader('Inter')..addFont(
        _bytes(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
          'Roboto-Regular.ttf',
        ),
      ))
      .load();
  await (FontLoader('Arial')..addFont(_bytes(testFont.path))).load();
  await (FontLoader('JetBrains Mono')..addFont(_bytes(testFont.path))).load();
}

Future<ByteData> _bytes(String path) async {
  final Uint8List data = File(path).readAsBytesSync();
  return ByteData.view(data.buffer);
}

Directory _flutterRoot() {
  Directory current = File(Platform.resolvedExecutable).parent;
  while (current.parent.path != current.path) {
    final File uiFont = File.fromUri(
      current.uri.resolve(
        'bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    );
    if (uiFont.existsSync()) {
      return current;
    }
    current = current.parent;
  }
  throw StateError('Cannot locate the Flutter SDK.');
}

File _repoFile(String relativePath) {
  Directory current = Directory.current.absolute;
  while (true) {
    final File marker = File.fromUri(
      current.uri.resolve('tools/pluto/pins/engine.version'),
    );
    if (marker.existsSync()) {
      return File.fromUri(current.uri.resolve(relativePath));
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Cannot locate the repository root.');
    }
    current = parent;
  }
}
