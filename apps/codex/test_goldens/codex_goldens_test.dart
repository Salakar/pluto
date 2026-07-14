import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/app.dart';
import 'package:paper_codex/src/app_model.dart';
import 'package:paper_codex/src/codex/fake_bridge.dart';
import 'package:paper_codex/src/models.dart';
import 'package:paper_codex/src/services.dart';
import 'package:paper_codex/src/store.dart';

final class _NullSystem implements SystemBridge {
  @override
  Future<void> exitToLauncher() async {}

  @override
  Future<double?> frontlightFraction() async => 0.6;

  @override
  Future<void> setFrontlightFraction(double fraction) async {}

  @override
  Future<WifiSummary> wifiSummary() async => const WifiSummary(
    line: 'wi-fi: chiappa-net (10.0.0.31)',
    connected: true,
  );
}

Future<void> _loadRealFonts() async {
  for (final (family, asset) in [
    ('EBGaramond', 'assets/fonts/EBGaramond-VariableFont_wght.ttf'),
    ('Caveat', 'assets/fonts/Caveat-VariableFont_wght.ttf'),
    ('JetBrainsMono', 'assets/fonts/JetBrainsMono-VariableFont_wght.ttf'),
  ]) {
    final loader = FontLoader(family)..addFont(rootBundle.load(asset));
    await loader.load();
  }
}

const String _reviewAnswer =
    'A Codex-first tablet should keep the page calm: conversation near the '
    'writing surface, a collapsed chat shelf, and one focused input mode at '
    'a time.\n'
    '\n'
    '- [ ] Probe DRM and pen events.\n'
    '- [ ] Build fullscreen ink canvas.\n'
    '- [ ] Install appliance boot with settings escape.';

ChatSession _reviewSession(int clock) => ChatSession(
  id: 'golden-1',
  title: 'review pass',
  createdAtMs: clock,
  updatedAtMs: clock + 10,
  codexThreadId: 'thread-golden',
  messages: [
    ChatMessage(
      id: 'g-u1',
      role: TurnRole.user,
      mode: AuthorMode.keyboard,
      text: 'Can we make this feel like paper, but alive?',
      state: MessageState.complete,
      createdAtMs: clock,
    ),
    ChatMessage(
      id: 'g-c1',
      role: TurnRole.codex,
      mode: AuthorMode.keyboard,
      text: _reviewAnswer,
      state: MessageState.complete,
      createdAtMs: clock + 5,
    ),
  ],
);

List<InkStroke> _scribbleStrokes() {
  // A deterministic pen scribble across the handwriting band.
  final strokes = <InkStroke>[];
  for (var s = 0; s < 3; s++) {
    final points = <InkPoint>[];
    for (var i = 0; i <= 60; i++) {
      final t = i / 60.0;
      points.add(
        InkPoint(
          90 + s * 250 + t * 200,
          1420 + s * 70 + math.sin(t * math.pi * 4 + s) * 22,
          0.4 + 0.5 * math.sin(t * math.pi),
        ),
      );
    }
    strokes.add(InkStroke(points: points));
  }
  return strokes;
}

void main() {
  late Directory dir;

  setUpAll(_loadRealFonts);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('codex-goldens');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  CodexServices services({bool isColor = true}) {
    // Fixed-name subdir so painted path tails ('…/appdata/workspace') stay
    // byte-identical across runs while the temp parent stays isolated.
    final paths = AppPaths(root: Directory('${dir.path}/appdata'))..ensure();
    return CodexServices(
      bridge: FakeCodexBridge(),
      store: TranscriptStore(stateDir: paths.state),
      paths: paths,
      panel: PanelInfo(isColor: isColor),
      system: _NullSystem(),
    );
  }

  Future<CodexAppModel> pumpScene(
    WidgetTester tester, {
    bool isColor = true,
    void Function(CodexAppModel model)? mutate,
  }) async {
    tester.view.physicalSize = const Size(954, 1696);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final model = CodexAppModel(services: services(isColor: isColor));
    await model.init();
    mutate?.call(model);
    await tester.pumpWidget(
      PaperCodexAppForModel(model: model, isColor: isColor),
    );
    // Let the boot ghost-sweep veil clear so scenes capture the settled page.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 30));
    return model;
  }

  Future<void> snap(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(WidgetsApp),
      matchesGoldenFile('goldens/$name.png'),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('G01 empty page, keyboard composer', (tester) async {
    await pumpScene(tester);
    await snap(tester, 'g01_empty_keyboard');
  });

  testWidgets('G02 review conversation (color)', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
        const draft = 'Ask Codex to refactor /src/render with tests...';
        m.keyboardDraft = draft;
        m.caret = draft.length;
      },
    );
    await snap(tester, 'g02_conversation_color');
  });

  testWidgets('G03 handwriting composer with draft ink', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        m.toggleMode();
        for (final stroke in _scribbleStrokes()) {
          m.addStroke(stroke);
        }
      },
    );
    await snap(tester, 'g03_handwriting_draft');
  });

  testWidgets('G04 busy: thinking spiral + footprints', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
        m.active.messages.add(
          ChatMessage(
            id: 'g-u2',
            role: TurnRole.user,
            mode: AuthorMode.keyboard,
            text: 'Now wire the shelf for real.',
            state: MessageState.complete,
            createdAtMs: 6000,
          ),
        );
        m.active.messages.add(
          ChatMessage(
            id: 'g-c2',
            role: TurnRole.codex,
            mode: AuthorMode.keyboard,
            text: '',
            state: MessageState.pending,
            createdAtMs: 6001,
          ),
        );
        m.phase = TurnPhase.busy;
        m.liveActivity.addAll(const [
          ActivityNote(kind: 'thinking', label: 'Planning the shelf overlay'),
          ActivityNote(kind: 'command', label: 'ls apps/codex/lib/src/ui'),
        ]);
      },
    );
    await snap(tester, 'g04_busy_footprints');
  });

  testWidgets('G05 offline failure: margin note + retry mark', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        final session = _reviewSession(5000);
        session.messages.last
          ..state = MessageState.failed
          ..error = FailureKind.network
          ..text = '';
        m.sessions.insert(0, session);
        m.selectSession('golden-1');
      },
    );
    await snap(tester, 'g05_offline_retry');
  });

  testWidgets('G06 chat shelf open', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.sessions.insert(
          1,
          ChatSession(
            id: 'golden-2',
            title: 'Fix dashed pen strokes',
            createdAtMs: 4000,
            updatedAtMs: 4100,
            messages: [
              ChatMessage(
                id: 'g2-u1',
                role: TurnRole.user,
                mode: AuthorMode.keyboard,
                text: 'Fix dashed pen strokes while drawing',
                state: MessageState.complete,
                createdAtMs: 4000,
              ),
            ],
          ),
        );
        m.selectSession('golden-1');
        m.openShelf();
      },
    );
    await snap(tester, 'g06_shelf_open');
  });

  testWidgets('G07 settings page', (tester) async {
    await pumpScene(tester);
    // Tap the settings sun (design 908,50 → logical at DPR2/954-wide).
    await tester.tapAt(const Offset(908 * 477 / 954, 50 * 477 / 954));
    // Let the async settings refresh (wifi/frontlight/probe) fully land so
    // the scene is deterministic.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await snap(tester, 'g07_settings');
  });

  testWidgets('G09 page goal ribbon (active)', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        final session = _reviewSession(5000)
          ..goalText = 'Ship the shelf with tests green'
          ..goalStatus = GoalStatus.active;
        m.sessions.insert(0, session);
        m.selectSession('golden-1');
      },
    );
    await snap(tester, 'g09_goal_active');
  });

  testWidgets('G10 page mind sheet', (tester) async {
    final model = await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
        m.active.mindModel = 'gpt-5.6-luna';
      },
    );
    model.openPageMind();
    await tester.pump(const Duration(milliseconds: 60));
    await snap(tester, 'g10_page_mind');
  });

  testWidgets('G11 goal being written on its own line', (tester) async {
    final model = await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
      },
    );
    model.beginGoalEdit();
    for (final ch in 'Ship the shelf'.split('')) {
      model.keyTap(ch);
    }
    await tester.pump(const Duration(milliseconds: 40));
    await snap(tester, 'g11_goal_editing');
  });

  testWidgets('G12 goal paused', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        final session = _reviewSession(5000)
          ..goalText = 'Ship the shelf with tests green'
          ..goalStatus = GoalStatus.paused;
        m.sessions.insert(0, session);
        m.selectSession('golden-1');
      },
    );
    await snap(tester, 'g12_goal_paused');
  });

  testWidgets('G13 goal done', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        final session = _reviewSession(5000)
          ..goalText = 'Ship the shelf with tests green'
          ..goalStatus = GoalStatus.done;
        m.sessions.insert(0, session);
        m.selectSession('golden-1');
      },
    );
    await snap(tester, 'g13_goal_done');
  });

  testWidgets('G14 queued note with steer-now control', (tester) async {
    await pumpScene(
      tester,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
        m.active.messages.addAll([
          ChatMessage(
            id: 'g-u2',
            role: TurnRole.user,
            mode: AuthorMode.keyboard,
            text: 'Keep the queue visible while you work.',
            state: MessageState.complete,
            createdAtMs: 6000,
          ),
          ChatMessage(
            id: 'g-c2',
            role: TurnRole.codex,
            mode: AuthorMode.keyboard,
            text: '',
            state: MessageState.pending,
            createdAtMs: 6001,
          ),
          ChatMessage(
            id: 'g-u3',
            role: TurnRole.user,
            mode: AuthorMode.keyboard,
            text: 'Actually, test the stop path first.',
            state: MessageState.queued,
            createdAtMs: 6002,
          ),
        ]);
        m.phase = TurnPhase.busy;
        m.liveActivity.add(
          const ActivityNote(kind: 'thinking', label: 'Checking queue state'),
        );
      },
    );
    await snap(tester, 'g14_queue_steer');
  });

  testWidgets('G08 review conversation (mono palette)', (tester) async {
    await pumpScene(
      tester,
      isColor: false,
      mutate: (m) {
        m.sessions.insert(0, _reviewSession(5000));
        m.selectSession('golden-1');
        const draft = 'Ask Codex to refactor /src/render with tests...';
        m.keyboardDraft = draft;
        m.caret = draft.length;
      },
    );
    await snap(tester, 'g08_conversation_mono');
  });
}
