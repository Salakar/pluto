import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/models.dart';
import 'package:paper_codex/src/store.dart';

ChatSession _session() => ChatSession(
  id: 's1',
  title: 'Refactor the renderer',
  createdAtMs: 1000,
  updatedAtMs: 2000,
  codexThreadId: 'thread-1',
  messages: [
    ChatMessage(
      id: 'm1',
      role: TurnRole.user,
      mode: AuthorMode.keyboard,
      text: 'Refactor /src/render with tests',
      state: MessageState.complete,
      createdAtMs: 1000,
    ),
    ChatMessage(
      id: 'm2',
      role: TurnRole.codex,
      mode: AuthorMode.keyboard,
      text: 'Done. Three files changed.',
      state: MessageState.complete,
      createdAtMs: 1500,
      activity: const [ActivityNote(kind: 'command', label: 'cargo test')],
    ),
    ChatMessage(
      id: 'm3',
      role: TurnRole.user,
      mode: AuthorMode.handwriting,
      text: '',
      transcription: 'And the goldens?',
      strokes: const [
        InkStroke(points: [InkPoint(1, 2, 0.5), InkPoint(3, 4, 0.9)]),
      ],
      state: MessageState.complete,
      createdAtMs: 1800,
    ),
    ChatMessage(
      id: 'm4',
      role: TurnRole.codex,
      mode: AuthorMode.handwriting,
      text: '',
      state: MessageState.pending,
      createdAtMs: 1900,
    ),
  ],
);

void main() {
  group('models', () {
    test('json roundtrip preserves everything', () {
      final restored = ChatSession.fromJson(
        jsonDecode(jsonEncode(_session().toJson()))! as Map<String, Object?>,
      );
      expect(restored.id, 's1');
      expect(restored.codexThreadId, 'thread-1');
      expect(restored.messages, hasLength(4));
      expect(restored.messages[2].transcription, 'And the goldens?');
      expect(restored.messages[2].strokes.single.points, hasLength(2));
      expect(restored.messages[2].strokes.single.points[1].pressure, 0.9);
      expect(restored.messages[1].activity.single.label, 'cargo test');
      expect(restored.messages[3].state, MessageState.pending);
    });

    test('titleFromPrompt takes ~7 words capped at 48 chars', () {
      expect(titleFromPrompt('Fix the bug'), 'Fix the bug');
      expect(
        titleFromPrompt('one two three four five six seven eight nine'),
        'one two three four five six seven',
      );
      final long = titleFromPrompt(
        'extraordinarily gargantuan wordsmithing appears continuously here today',
      );
      expect(long.length, lessThanOrEqualTo(48));
      expect(long, endsWith('…'));
      expect(titleFromPrompt('   '), 'Untitled page');
    });

    test('failure notes match the ERR catalog', () {
      expect(FailureKind.binaryMissing.note, 'codex not found');
      expect(FailureKind.stopped.note, 'Stopped.');
      expect(FailureKind.network.note, contains('kept on this page'));
    });
  });

  group('TranscriptStore', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('codex-store-test');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('save/load roundtrip', () async {
      final store = TranscriptStore(stateDir: dir);
      await store.save([_session()]);
      final loaded = await store.load();
      expect(loaded.single.messages, hasLength(4));
      expect(loaded.single.title, 'Refactor the renderer');
    });

    test('corrupt file is set aside, not fatal', () async {
      final store = TranscriptStore(stateDir: dir);
      File('${dir.path}/chats.json').writeAsStringSync('{oh no');
      final loaded = await store.load();
      expect(loaded, isEmpty);
      expect(
        dir.listSync().whereType<File>().where(
          (f) => f.path.contains('.corrupt-'),
        ),
        hasLength(1),
      );
    });

    test(
      'boot recovery fails pending codex turns, completes user turns',
      () async {
        final sessions = [_session()];
        final queued = ChatMessage(
          id: 'm5',
          role: TurnRole.user,
          mode: AuthorMode.keyboard,
          text: 'Run this next',
          state: MessageState.queued,
          createdAtMs: 1950,
        );
        sessions.single.messages.add(queued);
        TranscriptStore.recoverInterrupted(sessions);
        final interrupted = sessions.single.messages[3];
        expect(interrupted.state, MessageState.failed);
        expect(interrupted.error, FailureKind.interrupted);
        expect(queued.state, MessageState.queued);
        expect(
          sessions.single.messages.where(
            (m) => m.state == MessageState.pending,
          ),
          isEmpty,
        );
      },
    );
  });
}
