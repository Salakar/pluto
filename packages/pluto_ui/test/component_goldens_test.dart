import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pluto_core/pluto_core.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  setUpAll(_loadGoldenFonts);

  testWidgets('paper component sheet golden', (WidgetTester tester) async {
    _setMoveViewport(tester);
    await tester.pumpWidget(
      PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: WidgetsApp(
            color: const Color(0xFFFFFFFF),
            pageRouteBuilder:
                <T>(RouteSettings settings, WidgetBuilder builder) {
                  return PaperPageRoute<T>(
                    settings: settings,
                    builder: builder,
                  );
                },
            home: const _ComponentSheet(),
            debugShowCheckedModeBanner: false,
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/paper_components.png'),
    );
  });

  testWidgets('refresh hint scope records fast button feedback', (
    WidgetTester tester,
  ) async {
    final List<EinkRefreshHint> hints = <EinkRefreshHint>[];
    await tester.pumpWidget(
      PaperTheme(
        data: const PaperThemeData(isColorPanel: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: EinkRefreshScope(
            onHint: hints.add,
            child: PaperButton(label: 'Press', onPressed: () {}),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Press'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      hints.map((EinkRefreshHint hint) => hint.refreshClass),
      contains(RefreshClass.fast),
    );
  });
}

final class _ComponentSheet extends StatelessWidget {
  const _ComponentSheet();

  @override
  Widget build(BuildContext context) {
    final StatusSnapshot snapshot = StatusSnapshot.fixed;
    return PaperScaffold(
      statusBar: StatusBar(snapshot: snapshot),
      header: PageHeader(
        title: 'Components',
        trailing: SegmentedControl<String>(
          selected: 'grid',
          onChanged: (_) {},
          segments: const <PaperSegment<String>>[
            PaperSegment<String>(value: 'grid', label: 'grid'),
            PaperSegment<String>(value: 'list', label: 'list'),
          ],
        ),
      ),
      pageIndicator: const PageDots(count: 3, index: 1),
      body: Padding(
        padding: const EdgeInsets.all(PaperSpacing.pageMargin),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: PaperButton.primary(
                    label: 'Primary',
                    onPressed: () {},
                  ),
                ),
                const SizedBox(width: PaperSpacing.space12),
                Expanded(
                  child: PaperButton(label: 'Secondary', onPressed: () {}),
                ),
              ],
            ),
            const SizedBox(height: PaperSpacing.space12),
            Row(
              children: <Widget>[
                Expanded(
                  child: PaperButton.destructive(
                    label: 'Destructive',
                    onPressed: () {},
                  ),
                ),
                const SizedBox(width: PaperSpacing.space12),
                const Expanded(
                  child: HoldToConfirmButton(label: 'HOLD', onConfirmed: _noop),
                ),
              ],
            ),
            const SizedBox(height: PaperSpacing.space20),
            DiscreteSlider(
              notchCount: 8,
              notchIndex: 5,
              leadingLabel: 'off',
              trailingLabel: '1250 / 2047',
              onNotchChanged: (_) {},
            ),
            const SizedBox(height: PaperSpacing.space20),
            Row(
              children: <Widget>[
                AppTile(
                  app: const PaperAppTileData(
                    id: 'dev.example.counter',
                    name: 'Counter',
                    isPinned: true,
                  ),
                  onLaunch: () {},
                  onManage: () {},
                ),
                const SizedBox(width: PaperSpacing.space16),
                AppTile(
                  app: const PaperAppTileData(
                    id: 'dev.example.installing',
                    name: 'Installing...',
                  ),
                  state: AppTileState.installing,
                  progress: 0.25,
                  onLaunch: () {},
                  onManage: () {},
                ),
                const SizedBox(width: PaperSpacing.space16),
                AppTile(
                  app: const PaperAppTileData(
                    id: 'dev.example.broken',
                    name: 'Broken Demo',
                  ),
                  state: AppTileState.broken,
                  onLaunch: () {},
                  onManage: () {},
                ),
              ],
            ),
            const SizedBox(height: PaperSpacing.space20),
            PaperDialog(
              title: 'Paper dialog',
              actions: <Widget>[
                PaperButton(label: 'Cancel', onPressed: () {}),
                PaperButton.primary(label: 'OK', onPressed: () {}),
              ],
              child: const Text('Offset plate, hard rules, no shadows.'),
            ),
          ],
        ),
      ),
    );
  }
}

void _setMoveViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _noop() {}

Future<void> _loadGoldenFonts() async {
  final Directory flutterRoot = _findFlutterRoot();
  final File testFont = _findRepositoryFile(
    'assets/test_fonts/JetBrainsMono-VariableFont_wght.ttf',
  );
  final FontLoader uiLoader = FontLoader('Inter')
    ..addFont(
      _fontData(
        '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
        'Roboto-Regular.ttf',
      ),
    );
  final FontLoader symbolLoader = FontLoader('Arial')
    ..addFont(_fontData(testFont.path));
  final FontLoader monoLoader = FontLoader('JetBrains Mono')
    ..addFont(_fontData(testFont.path));
  await uiLoader.load();
  await symbolLoader.load();
  await monoLoader.load();
}

Directory _findFlutterRoot() {
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
  throw StateError(
    'Cannot locate the Flutter SDK from ${Platform.resolvedExecutable}.',
  );
}

File _findRepositoryFile(String relativePath) {
  Directory current = Directory.current.absolute;
  while (true) {
    final File marker = File.fromUri(
      current.uri.resolve('tools/pluto/pins/engine.version'),
    );
    if (marker.existsSync()) {
      final File file = File.fromUri(current.uri.resolve(relativePath));
      if (!file.existsSync()) {
        throw StateError('Repository fixture does not exist: ${file.path}.');
      }
      return file;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
  throw StateError('Cannot locate the repository from ${Directory.current}.');
}

Future<ByteData> _fontData(String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
}
