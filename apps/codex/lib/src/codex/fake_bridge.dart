import 'dart:async';

import '../models.dart';
import 'codex_bridge.dart';

/// A scripted stand-in for the codex CLI: used by tests, host preview, and
/// on-device UI QA (`PAPER_CODEX_FAKE=1`). Emits a couple of activity
/// footprints, then answers.
final class FakeCodexBridge implements CodexBridge {
  FakeCodexBridge({
    this.answer = _defaultAnswer,
    this.failure,
    this.stepDelay = const Duration(milliseconds: 40),
    this.threadId = 'fake-thread-0001',
    this.activity = const [
      ActivityNote(kind: 'thinking', label: 'Reading the page'),
      ActivityNote(kind: 'command', label: 'ls workspace'),
    ],
  });

  static const String _defaultAnswer =
      'A Codex-first tablet should keep the page calm: conversation near the '
      'writing surface, a collapsed chat shelf, and one focused input mode '
      'at a time.\n\n'
      '- [ ] Probe DRM and pen events.\n'
      '- [ ] Build fullscreen ink canvas.\n'
      '- [ ] Install appliance boot with settings escape.';

  final String answer;
  final FailureKind? failure;
  final Duration stepDelay;
  final String threadId;
  final List<ActivityNote> activity;

  final List<CodexTurnRequest> requests = [];

  @override
  CodexTurnHandle startTurn(CodexTurnRequest request) {
    requests.add(request);
    return _FakeTurn(this, request);
  }

  @override
  Future<CodexProbe> probe() async => const CodexProbe(
    binaryPath: '/fake/codex',
    version: 'codex-cli 0.144.1 (fake)',
    loggedIn: true,
  );
}

final class _FakeTurn implements CodexTurnHandle {
  _FakeTurn(this._bridge, this._request) {
    unawaited(_run());
  }

  final FakeCodexBridge _bridge;
  final CodexTurnRequest _request;
  final _updates = StreamController<TurnUpdate>.broadcast();
  final _outcome = Completer<TurnOutcome>();
  bool _stopped = false;

  @override
  Stream<TurnUpdate> get updates => _updates.stream;

  @override
  Future<TurnOutcome> get outcome => _outcome.future;

  @override
  void stop() {
    _stopped = true;
  }

  Future<void> _run() async {
    await Future<void>.delayed(_bridge.stepDelay);
    if (!_stopped) {
      _updates.add(TurnThread(_bridge.threadId));
      for (final note in _bridge.activity) {
        await Future<void>.delayed(_bridge.stepDelay);
        if (_stopped) {
          break;
        }
        _updates.add(TurnActivity(note));
      }
    }
    await Future<void>.delayed(_bridge.stepDelay);
    final TurnOutcome outcome;
    if (_stopped) {
      outcome = TurnOutcome(
        threadId: _bridge.threadId,
        failure: FailureKind.stopped,
      );
    } else if (_bridge.failure != null) {
      outcome = TurnOutcome(
        threadId: _bridge.threadId,
        failure: _bridge.failure,
        detail: 'scripted failure',
      );
    } else {
      var text = _bridge.answer;
      if (_request.imagePath != null) {
        text = 'TRANSCRIPTION:\n(read from the page)\n\nANSWER:\n$text';
      }
      outcome = TurnOutcome(answer: text, threadId: _bridge.threadId);
    }
    if (!_outcome.isCompleted) {
      _outcome.complete(outcome);
    }
    await _updates.close();
  }
}
