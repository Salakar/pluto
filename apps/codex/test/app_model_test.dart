import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/app_model.dart';
import 'package:paper_codex/src/codex/codex_bridge.dart';
import 'package:paper_codex/src/codex/fake_bridge.dart';
import 'package:paper_codex/src/models.dart';
import 'package:paper_codex/src/services.dart';
import 'package:paper_codex/src/store.dart';

final class _RecordingSystem implements SystemBridge {
  int exits = 0;

  @override
  Future<void> exitToLauncher() async {
    exits += 1;
  }

  @override
  Future<double?> frontlightFraction() async => 0.4;

  @override
  Future<void> setFrontlightFraction(double fraction) async {}

  @override
  Future<WifiSummary> wifiSummary() async =>
      const WifiSummary(line: 'wi-fi: testnet', connected: true);
}

final class _SequenceBridge implements CodexBridge {
  _SequenceBridge(this.outcomes);

  final List<TurnOutcome> outcomes;
  final List<CodexTurnRequest> requests = [];

  @override
  CodexTurnHandle startTurn(CodexTurnRequest request) {
    requests.add(request);
    return _ImmediateTurn(outcomes.removeAt(0));
  }

  @override
  Future<CodexProbe> probe() async => const CodexProbe(
    binaryPath: '/fake/codex',
    version: 'codex-cli 0.144.1 (test)',
    loggedIn: true,
  );
}

final class _ImmediateTurn implements CodexTurnHandle {
  _ImmediateTurn(this.value);

  final TurnOutcome value;

  @override
  Future<TurnOutcome> get outcome async => value;

  @override
  Stream<TurnUpdate> get updates => const Stream.empty();

  @override
  void stop() {}
}

void main() {
  late Directory dir;
  var clock = 1000;
  final liveBinary = Platform.environment['PAPER_CODEX_LIVE_BINARY'];

  CodexServices services(CodexBridge bridge) {
    final paths = AppPaths(root: dir)..ensure();
    return CodexServices(
      bridge: bridge,
      store: TranscriptStore(stateDir: paths.state),
      paths: paths,
      panel: const PanelInfo(isColor: true),
      system: _RecordingSystem(),
    );
  }

  CodexAppModel model(CodexBridge bridge) =>
      CodexAppModel(services: services(bridge), nowMs: () => clock++);

  setUp(() {
    clock = 1000;
    dir = Directory.systemTemp.createTempSync('codex-model-test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test(
    'keyboard send: appends turns, titles the page, resolves the answer',
    () async {
      final bridge = FakeCodexBridge(answer: 'The page stays calm.');
      final m = model(bridge);
      await m.init();
      m
        ..keyTap('h')
        ..keyTap('i')
        ..keyTap(' ')
        ..keyTap('c')
        ..keyTap('o')
        ..keyTap('d')
        ..keyTap('e')
        ..keyTap('x');
      expect(m.keyboardDraft, 'hi codex');
      await m.sendKeyboard();
      expect(m.keyboardDraft, isEmpty);
      expect(m.phase, TurnPhase.idle);
      final session = m.active;
      expect(session.title, 'hi codex');
      expect(session.codexThreadId, 'fake-thread-0001');
      expect(session.messages, hasLength(2));
      expect(session.messages[0].role, TurnRole.user);
      expect(session.messages[1].text, 'The page stays calm.');
      expect(session.messages[1].state, MessageState.complete);
      expect(m.revealMessageId, session.messages[1].id);
      // Second turn resumes the same thread.
      m.keyTap('y');
      await m.sendKeyboard();
      expect(bridge.requests, hasLength(2));
      expect(bridge.requests[0].threadId, isNull);
      expect(bridge.requests[1].threadId, 'fake-thread-0001');
    },
  );

  test(
    'optional live model send leaves busy and persists the real answer',
    () async {
      final m = model(
        LiveCodexBridge(
          binaryCandidates: [liveBinary!],
          softTimeout: const Duration(seconds: 20),
          hardTimeout: const Duration(minutes: 3),
          networkProbe: () async => true,
        ),
      );
      await m.init();
      const prompt =
          'Reply with exactly PLUTO_MODEL_BRIDGE_OK and nothing else.';
      for (final rune in prompt.runes) {
        m.keyTap(String.fromCharCode(rune));
      }
      final send = m.sendKeyboard();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(m.phase, TurnPhase.busy);
      await send.timeout(const Duration(minutes: 4));
      expect(m.phase, TurnPhase.idle);
      expect(m.active.tail!.state, MessageState.complete);
      expect(m.active.tail!.text, 'PLUTO_MODEL_BRIDGE_OK');

      final restored = model(FakeCodexBridge());
      await restored.init();
      expect(restored.active.tail!.text, 'PLUTO_MODEL_BRIDGE_OK');
    },
    skip: liveBinary == null
        ? 'set PAPER_CODEX_LIVE_BINARY to an exec-compatible CLI'
        : false,
  );

  test('shift and layers shape typed text', () async {
    final m = model(FakeCodexBridge());
    await m.init();
    m
      ..shiftTap()
      ..keyTap('h')
      ..keyTap('i');
    expect(m.keyboardDraft, 'Hi');
    m
      ..shiftTap()
      ..shiftTap() // once -> lock
      ..keyTap('a')
      ..keyTap('b');
    expect(m.keyboardDraft, 'HiAB');
    m
      ..layerTap('123')
      ..keyTap('4');
    expect(m.layer, KeyboardLayer.symbols);
    expect(m.keyboardDraft, 'HiAB4');
    m.layerTap('abc');
    expect(m.layer, KeyboardLayer.letters);
    m
      ..cursorLeft()
      ..backspace();
    expect(m.keyboardDraft, 'HiA4');
  });

  test('failed turn resolves to a failed tail and retry re-runs it', () async {
    final failing = FakeCodexBridge(failure: FailureKind.network);
    final m = model(failing);
    await m.init();
    m.keyTap('x');
    await m.sendKeyboard();
    var tail = m.active.tail!;
    expect(tail.state, MessageState.failed);
    expect(tail.error, FailureKind.network);

    // Fix the network and retry the tail in place.
    final ok = FakeCodexBridge(answer: 'Back online.');
    final m2 = CodexAppModel(services: services(ok), nowMs: () => clock++);
    await m2.init();
    expect(m2.active.tail!.error, FailureKind.network);
    await m2.retryTail();
    tail = m2.active.tail!;
    expect(tail.state, MessageState.complete);
    expect(tail.text, 'Back online.');
    expect(m2.active.messages, hasLength(2));
  });

  test(
    'handwriting send renders a page image and stores transcription',
    () async {
      final bridge = FakeCodexBridge(answer: 'I read your ink.');
      final m = model(bridge);
      await m.init();
      m.toggleMode();
      expect(m.inputMode, AuthorMode.handwriting);
      m.addStroke(
        const InkStroke(
          points: [InkPoint(100, 1400, 0.5), InkPoint(300, 1420, 0.8)],
        ),
      );
      expect(m.handwritingSendEnabled, isTrue);
      await m.sendHandwriting();
      final session = m.active;
      final user = session.messages[0];
      expect(user.isHandwritten, isTrue);
      expect(user.transcription, '(read from the page)');
      expect(session.messages[1].text, 'I read your ink.');
      final request = bridge.requests.single;
      expect(request.imagePath, isNotNull);
      expect(File(request.imagePath!).existsSync(), isTrue);
      expect(request.prompt, contains('TRANSCRIPTION:'));
      // Title falls back to the transcription for handwriting-first pages.
      expect(session.title, '(read from the page)');
    },
  );

  test('busy turns persist new sends and drain them in FIFO order', () async {
    final slow = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 150),
    );
    final m = model(slow);
    await m.init();
    m.keyTap('a');
    final first = m.sendKeyboard();
    // While busy, a second send becomes a durable queue entry.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(m.phase, TurnPhase.busy);
    m.keyTap('b');
    await m.sendKeyboard();
    expect(m.keyboardDraft, isEmpty);
    expect(m.queuedCount, 1);
    expect(m.active.messages.last.state, MessageState.queued);
    expect(m.queuePosition(m.active.messages.last), 1);
    expect(
      m.active.messages.where((x) => x.role == TurnRole.user),
      hasLength(2),
    );
    await first;
    expect(m.phase, TurnPhase.idle);
    expect(m.queuedCount, 0);
    expect(slow.requests.map((request) => request.prompt), ['a', 'b']);
    expect(m.active.messages, hasLength(4));
  });

  test('stop pauses the queue until a queued note is steered', () async {
    final slow = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 100),
    );
    final m = model(slow);
    await m.init();
    m.keyTap('a');
    final first = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.keyTap('b');
    await m.sendKeyboard();
    final queued = m.active.messages.last;

    m.stopTurn();
    await first;
    expect(m.phase, TurnPhase.idle);
    expect(m.queuedCount, 1);
    expect(queued.state, MessageState.queued);
    expect(slow.requests, hasLength(1));

    await m.steerNow(queued);
    expect(m.phase, TurnPhase.idle);
    expect(m.queuedCount, 0);
    expect(slow.requests.map((request) => request.prompt), ['a', 'b']);
  });

  test('steer now promotes the selected note, then resumes FIFO', () async {
    final slow = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 80),
    );
    final m = model(slow);
    await m.init();
    m.keyTap('a');
    final first = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.keyTap('b');
    await m.sendKeyboard();
    m.keyTap('c');
    await m.sendKeyboard();
    final c = m.active.messages.last;
    expect(m.queuedCount, 2);

    await m.steerNow(c);
    await first;

    expect(m.phase, TurnPhase.idle);
    expect(m.queuedCount, 0);
    expect(slow.requests.map((request) => request.prompt), ['a', 'c', 'b']);
    expect(m.active.messages[1].error, FailureKind.stopped);
  });

  test('queued notes survive restart and can be steered from idle', () async {
    final slow = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 80),
    );
    final m = model(slow);
    await m.init();
    m.keyTap('a');
    final first = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.keyTap('b');
    await m.sendKeyboard();
    m.stopTurn();
    await first;

    final restoredBridge = FakeCodexBridge(answer: 'restored');
    final restored = model(restoredBridge);
    await restored.init();
    expect(restored.queuedCount, 1);
    final queued = restored.active.messages.singleWhere(
      (message) => message.state == MessageState.queued,
    );
    await restored.steerNow(queued);
    expect(restoredBridge.requests.single.prompt, 'b');
    expect(restored.active.tail!.text, 'restored');
  });

  test('the global queue keeps each note on its own page', () async {
    final slow = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 70),
    );
    final m = model(slow);
    await m.init();
    final firstPage = m.active;
    m.keyTap('a');
    final first = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    m.newPage();
    final secondPage = m.active;
    m.keyTap('b');
    await m.sendKeyboard();
    expect(secondPage.messages.single.state, MessageState.queued);
    expect(firstPage.messages, hasLength(2));

    await first;
    expect(slow.requests.map((request) => request.prompt), ['a', 'b']);
    expect(slow.requests[1].threadId, isNull);
    expect(firstPage.messages.last.text, 'done');
    expect(secondPage.messages.last.text, 'done');
  });

  test('a running turn keeps its thread id on the page that sent it', () async {
    final bridge = FakeCodexBridge(
      answer: 'done',
      stepDelay: const Duration(milliseconds: 80),
      activity: const [],
    );
    final m = model(bridge);
    await m.init();
    final sendingPage = m.active;
    m.keyTap('a');
    final send = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.newPage();
    final browsingPage = m.active;
    expect(browsingPage.id, isNot(sendingPage.id));
    await send;
    expect(sendingPage.codexThreadId, 'fake-thread-0001');
    expect(browsingPage.codexThreadId, isNull);
  });

  test('stop resolves the turn as stopped', () async {
    final slow = FakeCodexBridge(
      answer: 'never seen',
      stepDelay: const Duration(milliseconds: 200),
    );
    final m = model(slow);
    await m.init();
    m.keyTap('a');
    final send = m.sendKeyboard();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    m.stopTurn();
    await send;
    expect(m.active.tail!.error, FailureKind.stopped);
  });

  test(
    'new page reuses a blank page and shelf selection switches sessions',
    () async {
      final m = model(FakeCodexBridge(answer: 'ok'));
      await m.init();
      final blankId = m.active.id;
      m.newPage();
      expect(m.active.id, blankId, reason: 'blank page is reused');
      m.keyTap('a');
      await m.sendKeyboard();
      m.newPage();
      expect(m.active.id, isNot(blankId));
      expect(m.sessions, hasLength(2));
      m.selectSession(blankId);
      expect(m.active.id, blankId);
    },
  );

  test('persists across restarts', () async {
    final bridge = FakeCodexBridge(answer: 'persisted!');
    final m = model(bridge);
    await m.init();
    m.keyTap('q');
    await m.sendKeyboard();

    final m2 = model(FakeCodexBridge());
    await m2.init();
    expect(m2.active.messages, hasLength(2));
    expect(m2.active.messages[1].text, 'persisted!');
    expect(m2.active.codexThreadId, 'fake-thread-0001');
  });
  group('page goal', () {
    test('set, preamble, pause, done, edit, clear', () async {
      final bridge = FakeCodexBridge(answer: 'ok');
      final m = model(bridge);
      await m.init();

      // Set a goal through the composer's goal mode.
      m.beginGoalEdit();
      expect(m.goalEditing, isTrue);
      m.keyTap('s');
      m.keyTap('h');
      m.keyTap('i');
      m.keyTap('p');
      await m.sendKeyboard(); // commits the goal, not a turn
      expect(m.goalEditing, isFalse);
      expect(m.active.goalText, 'ship');
      expect(m.active.goalStatus, GoalStatus.active);
      expect(m.active.messages, isEmpty, reason: 'goal commit is not a turn');

      // Active goal rides into the prompt.
      m.keyTap('x');
      await m.sendKeyboard();
      expect(
        bridge.requests.single.prompt,
        'Standing goal for this page: ship\n\nx',
      );
      expect(bridge.requests.single.model, isNull);

      // Paused goal stays off the prompt.
      await m.toggleGoalPaused();
      expect(m.active.goalStatus, GoalStatus.paused);
      m.keyTap('y');
      await m.sendKeyboard();
      expect(bridge.requests[1].prompt, 'y');

      // Done + back to active.
      await m.toggleGoalDone();
      expect(m.active.goalStatus, GoalStatus.done);
      await m.toggleGoalDone();
      expect(m.active.goalStatus, GoalStatus.active);

      // Edit prefills; clearing the draft clears the goal.
      m.beginGoalEdit();
      expect(m.keyboardDraft, 'ship');
      for (var i = 0; i < 4; i++) {
        m.backspace();
      }
      await m.sendKeyboard();
      expect(m.active.hasGoal, isFalse);
    });

    test('goal persists across restarts', () async {
      final m = model(FakeCodexBridge());
      await m.init();
      m.beginGoalEdit();
      m.keyTap('g');
      await m.sendKeyboard();

      final m2 = model(FakeCodexBridge());
      await m2.init();
      expect(m2.active.goalText, 'g');
      expect(m2.active.goalStatus, GoalStatus.active);
    });
  });

  group('the mind', () {
    test('per-page override beats the house default and persists', () async {
      final bridge = FakeCodexBridge(answer: 'ok');
      final m = model(bridge);
      await m.init();
      await m.setMindModel('gpt-5.6-sol');
      await m.setMindEffort('high');
      await m.setPageMindModel('gpt-5.6-luna');
      expect(m.effectiveModel(m.active), 'gpt-5.6-luna');
      expect(m.effectiveEffort(m.active), 'high');
      m.keyTap('q');
      await m.sendKeyboard();
      expect(bridge.requests.single.model, 'gpt-5.6-luna');
      expect(bridge.requests.single.effort, 'high');

      final m2 = model(FakeCodexBridge());
      await m2.init();
      expect(m2.active.mindModel, 'gpt-5.6-luna');
      await m2.setPageMindModel(null);
      expect(m2.effectiveModel(m2.active), 'gpt-5.6-sol');
    });

    test('model/effort persist and ride into requests', () async {
      final bridge = FakeCodexBridge(answer: 'ok');
      final m = model(bridge);
      await m.init();
      await m.setMindModel('gpt-5.6-sol');
      await m.setMindEffort('ultra');
      m.keyTap('q');
      await m.sendKeyboard();
      expect(bridge.requests.single.model, 'gpt-5.6-sol');
      expect(bridge.requests.single.effort, 'ultra');

      final m2 = model(FakeCodexBridge());
      await m2.init();
      expect(m2.mind.model, 'gpt-5.6-sol');
      expect(m2.mind.effort, 'ultra');
      await m2.setMindModel(null);
      final m3 = model(FakeCodexBridge());
      await m3.init();
      expect(m3.mind.model, isNull);
      expect(m3.mind.effort, 'ultra');
    });

    test('normalizes obsolete and model-incompatible effort values', () async {
      final paths = AppPaths(root: dir)..ensure();
      File(
        '${paths.state.path}/mind.json',
      ).writeAsStringSync('{"model":"gpt-5.6-terra","effort":"minimal"}');
      final m = model(FakeCodexBridge());
      await m.init();
      expect(m.mind.effort, 'low');
      final repaired =
          jsonDecode(File('${paths.state.path}/mind.json').readAsStringSync())
              as Map<String, Object?>;
      expect(repaired['effort'], 'low');

      await m.setMindModel('gpt-5.6-luna');
      await m.setMindEffort('ultra');
      expect(m.mind.effort, 'max');
      expect(m.effectiveEffort(m.active), 'max');
      await m.setPageMindModel('gpt-5.6-luna');
      await m.setPageMindEffort('ultra');
      expect(m.active.mindEffort, 'max');
    });

    test(
      'lost-thread retry preserves mind settings without prompt duplication',
      () async {
        final seed = FakeCodexBridge(answer: 'first');
        final m = model(seed);
        await m.init();
        await m.setPageMindModel('gpt-5.6-sol');
        await m.setPageMindEffort('ultra');
        m.keyTap('a');
        await m.sendKeyboard();

        final bridge = _SequenceBridge([
          const TurnOutcome(
            failure: FailureKind.nonZero,
            detail: 'session not found',
          ),
          const TurnOutcome(answer: 'recovered', threadId: 'fresh-thread'),
        ]);
        final m2 = CodexAppModel(
          services: services(bridge),
          nowMs: () => clock++,
        );
        await m2.init();
        m2.keyTap('b');
        await m2.sendKeyboard();

        expect(bridge.requests, hasLength(2));
        expect(bridge.requests.first.threadId, 'fake-thread-0001');
        expect(bridge.requests.last.threadId, isNull);
        expect(bridge.requests.last.model, 'gpt-5.6-sol');
        expect(bridge.requests.last.effort, 'ultra');
        expect(
          RegExp(
            r'(?<![A-Za-z])b(?![A-Za-z])',
          ).allMatches(bridge.requests.last.prompt),
          hasLength(1),
        );
        expect(m2.active.tail!.text, 'recovered');
        expect(m2.active.codexThreadId, 'fresh-thread');
      },
    );
  });
}
