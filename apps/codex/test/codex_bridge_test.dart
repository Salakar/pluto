@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/codex/codex_bridge.dart';
import 'package:paper_codex/src/models.dart';

/// Writes an executable fake `codex` whose behaviour is driven by its first
/// argument file; exercises the real Process plumbing end to end.
String _writeFakeCodex(Directory dir, String script) {
  final file = File('${dir.path}/codex-fake');
  file.writeAsStringSync('#!/bin/sh\n$script\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('codex-bridge-test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  group('argsFor', () {
    const workspace = '/tmp/ws';

    test('fresh turn args', () {
      final args = LiveCodexBridge.argsFor(
        const CodexTurnRequest(prompt: '--help', workspace: workspace),
      );
      expect(args, [
        'exec',
        '--json',
        '--skip-git-repo-check',
        '--sandbox',
        'workspace-write',
        '-C',
        workspace,
        '-',
      ]);
    });

    test('resume turn inherits session settings and adds thread id', () {
      final args = LiveCodexBridge.argsFor(
        const CodexTurnRequest(
          prompt: 'and now?',
          workspace: workspace,
          threadId: 'thread-9',
        ),
      );
      expect(args, [
        'exec',
        'resume',
        'thread-9',
        '--json',
        '--skip-git-repo-check',
        '-',
      ]);
    });

    test('model and effort overrides ride along on fresh and resume', () {
      final fresh = LiveCodexBridge.argsFor(
        const CodexTurnRequest(
          prompt: 'p',
          workspace: workspace,
          model: 'gpt-5.6-sol',
          effort: 'ultra',
        ),
      );
      expect(fresh, containsAllInOrder(['-m', 'gpt-5.6-sol']));
      expect(
        fresh,
        containsAllInOrder(['-c', 'model_reasoning_effort="ultra"']),
      );
      final resume = LiveCodexBridge.argsFor(
        const CodexTurnRequest(
          prompt: 'p',
          workspace: workspace,
          threadId: 't1',
          model: 'gpt-5.6-luna',
          effort: 'low',
        ),
      );
      expect(resume, containsAllInOrder(['resume', 't1', '-m']));
      expect(
        resume,
        containsAllInOrder(['-c', 'model_reasoning_effort="low"']),
      );
    });

    test('handwriting turn attaches the page image', () {
      final args = LiveCodexBridge.argsFor(
        const CodexTurnRequest(
          prompt: 'read the page',
          workspace: workspace,
          imagePath: '/tmp/page.png',
        ),
      );
      expect(args, containsAllInOrder(['-i', '/tmp/page.png']));
    });
  });

  group('LiveCodexBridge subprocess handling', () {
    final liveBinary = Platform.environment['PAPER_CODEX_LIVE_BINARY'];

    test(
      'optional live CLI smoke completes a real JSONL turn',
      () async {
        final bridge = LiveCodexBridge(
          binaryCandidates: [liveBinary!],
          softTimeout: const Duration(seconds: 20),
          hardTimeout: const Duration(minutes: 3),
          networkProbe: () async => true,
        );
        final outcome = await bridge
            .startTurn(
              CodexTurnRequest(
                prompt: 'Reply with exactly PLUTO_BRIDGE_OK and nothing else.',
                workspace: dir.path,
              ),
            )
            .outcome
            .timeout(const Duration(minutes: 4));
        expect(outcome.ok, isTrue, reason: outcome.detail);
        expect(outcome.answer, 'PLUTO_BRIDGE_OK');
        expect(outcome.threadId, isNotEmpty);
      },
      skip: liveBinary == null
          ? 'set PAPER_CODEX_LIVE_BINARY to an exec-compatible CLI'
          : false,
    );

    test('collects thread id, activity, and the final answer', () async {
      final binary = _writeFakeCodex(dir, r'''
echo '{"type":"thread.started","thread_id":"t-123"}'
echo '{"type":"turn.started"}'
echo '{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls -la","status":"in_progress"}}'
echo '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"All done."}}'
echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
''');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final handle = bridge.startTurn(
        CodexTurnRequest(prompt: 'p', workspace: dir.path),
      );
      final updates = <TurnUpdate>[];
      final sub = handle.updates.listen(updates.add);
      final outcome = await handle.outcome;
      await sub.cancel();
      expect(outcome.ok, isTrue);
      expect(outcome.answer, 'All done.');
      expect(outcome.threadId, 't-123');
      expect(updates.whereType<TurnThread>().single.threadId, 't-123');
      expect(updates.whereType<TurnActivity>().single.note.label, 'ls -la');
    });

    test(
      'writes the prompt to stdin and closes it before codex begins',
      () async {
        final binary = _writeFakeCodex(dir, r'''
input=$(cat)
if [ "$input" != "--prompt text stays out of argv" ]; then
  echo "unexpected stdin: $input" >&2
  exit 42
fi
last=''
for arg in "$@"; do
  last=$arg
done
if [ "$#" -eq 0 ] || [ "$last" != "-" ]; then
  echo "missing stdin sentinel" >&2
  exit 43
fi
echo '{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"stdin reached EOF"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
''');
        final bridge = LiveCodexBridge(
          binaryCandidates: [binary],
          hardTimeout: const Duration(seconds: 2),
          networkProbe: () async => true,
        );
        final outcome = await bridge
            .startTurn(
              CodexTurnRequest(
                prompt: '--prompt text stays out of argv',
                workspace: dir.path,
              ),
            )
            .outcome
            .timeout(const Duration(seconds: 2));
        expect(outcome.ok, isTrue);
        expect(outcome.answer, 'stdin reached EOF');
      },
    );

    test('classifies auth failures from stderr needles', () async {
      final binary = _writeFakeCodex(dir, r'''
echo 'Error: not logged in - please run codex login' 1>&2
exit 1
''');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.failure, FailureKind.auth);
    });

    test('classifies network failures', () async {
      final binary = _writeFakeCodex(dir, r'''
echo '{"type":"turn.failed","error":{"message":"error sending request: dns error"}}'
exit 1
''');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.failure, FailureKind.network);
    });

    test('empty answer with zero exit classifies emptyAnswer', () async {
      final binary = _writeFakeCodex(dir, 'true');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.failure, FailureKind.emptyAnswer);
    });

    test('missing binary classifies binaryMissing without spawning', () async {
      final bridge = LiveCodexBridge(
        binaryCandidates: ['${dir.path}/definitely-not-here'],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.failure, FailureKind.binaryMissing);
    });

    test('stop() kills a hung child and classifies stopped', () async {
      final binary = _writeFakeCodex(dir, r'''
echo '{"type":"thread.started","thread_id":"t-9"}'
sleep 60
''');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        killGrace: const Duration(milliseconds: 100),
        networkProbe: () async => true,
      );
      final handle = bridge.startTurn(
        CodexTurnRequest(prompt: 'p', workspace: dir.path),
      );
      await handle.updates.firstWhere((u) => u is TurnThread);
      handle.stop();
      final outcome = await handle.outcome.timeout(const Duration(seconds: 4));
      expect(outcome.failure, FailureKind.stopped);
    });

    test('hard timeout kills the child and classifies timeout', () async {
      final binary = _writeFakeCodex(dir, 'sleep 60');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        softTimeout: const Duration(milliseconds: 50),
        hardTimeout: const Duration(milliseconds: 400),
        killGrace: const Duration(milliseconds: 200),
        networkProbe: () async => true,
      );
      final handle = bridge.startTurn(
        CodexTurnRequest(prompt: 'p', workspace: dir.path),
      );
      final updates = <TurnUpdate>[];
      final sub = handle.updates.listen(updates.add);
      final outcome = await handle.outcome.timeout(const Duration(seconds: 20));
      await sub.cancel();
      expect(outcome.failure, FailureKind.timeout);
      expect(updates.whereType<TurnStillThinking>(), isNotEmpty);
    });

    test('offline preflight fails fast without spawning', () async {
      final binary = _writeFakeCodex(dir, 'echo should-not-run; sleep 30');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => false,
      );
      final stopwatch = Stopwatch()..start();
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      stopwatch.stop();
      expect(outcome.failure, FailureKind.network);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('unexpected bridge exceptions still complete the outcome', () async {
      final binary = _writeFakeCodex(dir, 'echo should-not-run');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => throw StateError('probe exploded'),
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome
          .timeout(const Duration(seconds: 2));
      expect(outcome.failure, FailureKind.nonZero);
      expect(outcome.detail, contains('probe exploded'));
    });

    test('advisory error items do not fail a delivered answer', () async {
      final binary = _writeFakeCodex(dir, r'''
echo '{"type":"item.completed","item":{"id":"w","type":"error","message":"session was recorded with model X"}}'
echo '{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Still fine."}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
''');
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.ok, isTrue);
      expect(outcome.answer, 'Still fine.');
    });

    test('utf8 answers survive the pipe', () async {
      final message = jsonEncode({
        'type': 'item.completed',
        'item': {
          'id': 'm1',
          'type': 'agent_message',
          'text': 'ink → page ✎ done',
        },
      });
      final binary = _writeFakeCodex(dir, "echo '$message'");
      final bridge = LiveCodexBridge(
        binaryCandidates: [binary],
        networkProbe: () async => true,
      );
      final outcome = await bridge
          .startTurn(CodexTurnRequest(prompt: 'p', workspace: dir.path))
          .outcome;
      expect(outcome.answer, 'ink → page ✎ done');
    });
  });
}
