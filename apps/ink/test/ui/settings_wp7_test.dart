import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_ink/src/model/settings_model.dart';
import 'package:paper_ink/src/ui/settings_page.dart';
import 'package:pluto_ui/pluto_ui.dart';

void main() {
  group('InkSettings', () {
    test('defaults match the first editor session contract', () {
      final InkSettings settings = InkSettings();

      expect(settings.fingerDrawing, isFalse);
      expect(settings.benchDock, BenchDockPreference.left);
      expect(settings.eraserDefault, EraserDefaultPreference.pixel);
      expect(settings.gridSpacing, 16);
      expect(settings.pressureCurve, PressureCurvePreference.normal);
    });

    test('JSON round trip retains forward-compatible fields', () {
      final InkSettings settings = InkSettings.fromJson(<String, Object?>{
        'schema': 1,
        'fingerDrawing': true,
        'benchDock': 'top',
        'eraserDefault': 'stroke',
        'gridEnabled': true,
        'gridStyle': 'dot',
        'gridSpacing': 32,
        'pressureCurve': 'soft',
        'futureFlag': 'kept',
      });

      expect(settings.benchDock, BenchDockPreference.top);
      expect(settings.toJson()['futureFlag'], 'kept');
      expect(settings.toJson()['pressureCurve'], 'soft');
    });

    test('rejects unknown enums and unsupported grid spacing', () {
      expect(
        () => InkSettings.fromJson(<String, Object?>{
          'schema': 1,
          'fingerDrawing': false,
          'benchDock': 'bottom',
          'eraserDefault': 'pixel',
          'gridEnabled': false,
          'gridStyle': 'line',
          'gridSpacing': 16,
          'pressureCurve': 'normal',
        }),
        throwsFormatException,
      );
      expect(() => InkSettings(gridSpacing: 12), throwsArgumentError);
    });
  });

  group('InkSettingsModel', () {
    test('loads an injected snapshot without file IO', () async {
      final _MemorySettingsStore store = _MemorySettingsStore(
        loaded: InkSettings(benchDock: BenchDockPreference.right),
      );
      final InkSettingsModel model = InkSettingsModel(store: store);

      await model.load();

      expect(model.phase, InkSettingsPhase.ready);
      expect(model.settings.benchDock, BenchDockPreference.right);
    });

    test('finger drawing mutation persists one complete snapshot', () async {
      final _MemorySettingsStore store = _MemorySettingsStore();
      final InkSettingsModel model = InkSettingsModel(
        store: store,
        initial: InkSettings(),
      );

      await model.setFingerDrawing(true);

      expect(model.settings.fingerDrawing, isTrue);
      expect(store.saved.single.fingerDrawing, isTrue);
    });

    test('dock, eraser, grid, and pressure actions remain typed', () async {
      final _MemorySettingsStore store = _MemorySettingsStore();
      final InkSettingsModel model = InkSettingsModel(
        store: store,
        initial: InkSettings(),
      );

      await model.setBenchDock(BenchDockPreference.top);
      await model.setEraserDefault(EraserDefaultPreference.lasso);
      await model.setGridEnabled(true);
      await model.setGridStyle(GridStylePreference.dot);
      await model.setGridSpacing(64);
      await model.setPressureCurve(PressureCurvePreference.firm);

      expect(model.settings.benchDock, BenchDockPreference.top);
      expect(model.settings.eraserDefault, EraserDefaultPreference.lasso);
      expect(model.settings.gridEnabled, isTrue);
      expect(model.settings.gridStyle, GridStylePreference.dot);
      expect(model.settings.gridSpacing, 64);
      expect(model.settings.pressureCurve, PressureCurvePreference.firm);
      expect(store.saved, hasLength(6));
    });

    test(
      'failed persistence keeps the local choice and surfaces retry copy',
      () async {
        final _MemorySettingsStore store = _MemorySettingsStore()
          ..failSave = true;
        final InkSettingsModel model = InkSettingsModel(
          store: store,
          initial: InkSettings(),
        );

        await model.setBenchDock(BenchDockPreference.right);

        expect(model.settings.benchDock, BenchDockPreference.right);
        expect(model.persistenceMessage, contains('will retry'));
        model.dismissPersistenceMessage();
        expect(model.persistenceMessage, isNull);
      },
    );

    test('failed load falls back to valid defaults', () async {
      final _MemorySettingsStore store = _MemorySettingsStore()
        ..failLoad = true;
      final InkSettingsModel model = InkSettingsModel(store: store);

      await model.load();

      expect(model.phase, InkSettingsPhase.ready);
      expect(model.settings.benchDock, BenchDockPreference.left);
      expect(model.persistenceMessage, 'settings reset to defaults');
    });
  });

  testWidgets('settings renders every required group and back action', (
    WidgetTester tester,
  ) async {
    var backed = false;
    await _pumpSettings(tester, onBack: () => backed = true);

    expect(find.text('input'), findsOneWidget);
    expect(find.text('bench'), findsOneWidget);
    expect(find.text('grid defaults'), findsOneWidget);
    expect(find.text('pressure curve'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('settings-back')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backed, isTrue);
  });

  testWidgets('finger drawing toggle persists through its model seam', (
    WidgetTester tester,
  ) async {
    final _MemorySettingsStore store = _MemorySettingsStore();
    final InkSettingsModel model = InkSettingsModel(
      store: store,
      initial: InkSettings(),
    );
    await _pumpSettings(tester, model: model);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('finger-draw-toggle')),
        matching: find.text('On'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(model.settings.fingerDrawing, isTrue);
    expect(store.saved.single.fingerDrawing, isTrue);
  });

  testWidgets('bench edge control selects the top dock globally', (
    WidgetTester tester,
  ) async {
    final InkSettingsModel model = InkSettingsModel(
      store: _MemorySettingsStore(),
      initial: InkSettings(),
    );
    await _pumpSettings(tester, model: model);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('bench-dock-control')),
        matching: find.text('top'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(model.settings.benchDock, BenchDockPreference.top);
  });

  testWidgets('eraser and grid controls persist typed defaults', (
    WidgetTester tester,
  ) async {
    final InkSettingsModel model = InkSettingsModel(
      store: _MemorySettingsStore(),
      initial: InkSettings(),
    );
    await _pumpSettings(tester, model: model);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('eraser-default-control')),
        matching: find.text('lasso'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('grid-enabled-toggle')),
        matching: find.text('On'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('grid-style-control')),
        matching: find.text('dot'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('grid-spacing-control')),
        matching: find.text('64'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(model.settings.eraserDefault, EraserDefaultPreference.lasso);
    expect(model.settings.gridEnabled, isTrue);
    expect(model.settings.gridStyle, GridStylePreference.dot);
    expect(model.settings.gridSpacing, 64);
  });

  testWidgets('pressure choice rebuilds the brush-engine preview semantics', (
    WidgetTester tester,
  ) async {
    final InkSettingsModel model = InkSettingsModel(
      store: _MemorySettingsStore(),
      initial: InkSettings(),
    );
    await _pumpSettings(tester, model: model);

    expect(
      find.bySemanticsLabel('normal pressure sample stroke'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('pressure-curve-control')),
        matching: find.text('firm'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(model.settings.pressureCurve, PressureCurvePreference.firm);
    expect(
      find.bySemanticsLabel('firm pressure sample stroke'),
      findsOneWidget,
    );
  });

  testWidgets('deep clean invokes the system callback and reports completion', (
    WidgetTester tester,
  ) async {
    var cleanCalls = 0;
    await _pumpSettings(
      tester,
      onDeepClean: () async {
        cleanCalls += 1;
      },
    );
    final Finder button = find.byKey(
      const ValueKey<String>('deep-clean-button'),
    );
    await tester.ensureVisible(button);
    await tester.pump();

    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 100));

    expect(cleanCalls, 1);
    expect(find.textContaining('display refreshed'), findsOneWidget);
  });

  testWidgets('about dialog exposes bundled font licenses', (
    WidgetTester tester,
  ) async {
    await _pumpSettings(tester);
    final Finder about = find.byKey(const ValueKey<String>('about-button'));
    await tester.ensureVisible(about);
    await tester.pump();

    await tester.tap(about);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('about Ink'), findsOneWidget);
    await tester.tap(find.widgetWithText(PaperButton, 'licenses'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('licenses'), findsOneWidget);
    expect(
      find.textContaining('Inter — SIL Open Font License'),
      findsOneWidget,
    );
    expect(
      find.textContaining('JetBrains Mono — SIL Open Font License'),
      findsOneWidget,
    );
  });
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  InkSettingsModel? model,
  VoidCallback? onBack,
  Future<void> Function()? onDeepClean,
}) async {
  tester.view.physicalSize = const Size(954, 1696);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final InkSettingsModel resolvedModel =
      model ??
      InkSettingsModel(store: _MemorySettingsStore(), initial: InkSettings());
  await tester.pumpWidget(
    PaperTheme(
      data: const PaperThemeData(isColorPanel: true),
      child: WidgetsApp(
        color: const Color(0xffffffff),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PaperPageRoute<T>(settings: settings, builder: builder),
        home: SettingsPage(
          model: resolvedModel,
          onBack: onBack ?? () {},
          onDeepClean: onDeepClean ?? () async {},
        ),
      ),
    ),
  );
  await tester.pump();
}

final class _MemorySettingsStore implements InkSettingsStore {
  _MemorySettingsStore({InkSettings? loaded})
    : loaded = loaded ?? InkSettings();

  InkSettings loaded;
  final List<InkSettings> saved = <InkSettings>[];
  bool failLoad = false;
  bool failSave = false;

  @override
  Future<InkSettings> load() async {
    if (failLoad) {
      throw StateError('load failed');
    }
    return loaded;
  }

  @override
  Future<void> save(InkSettings settings) async {
    if (failSave) {
      throw StateError('save failed');
    }
    saved.add(settings);
    loaded = settings;
  }
}
