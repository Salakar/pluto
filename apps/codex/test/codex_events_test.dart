import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/codex/codex_events.dart';

void main() {
  group('parseCodexEvent', () {
    test('parses the real exec --json event stream', () {
      // Captured verbatim from codex-cli 0.144.1 `codex exec --json`.
      const lines = [
        '{"type":"thread.started","thread_id":"019f4930-8a78-7b12-be80-d0fd4d35d0d5"}',
        '{"type":"turn.started"}',
        '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"The quill writes itself."}}',
        '{"type":"turn.completed","usage":{"input_tokens":13089,"cached_input_tokens":9984,"output_tokens":10,"reasoning_output_tokens":0}}',
      ];
      final events = [for (final l in lines) parseCodexEvent(l)];
      expect(events[0], isA<ThreadStarted>());
      expect(
        (events[0]! as ThreadStarted).threadId,
        '019f4930-8a78-7b12-be80-d0fd4d35d0d5',
      );
      expect(events[1], isA<TurnStarted>());
      final item = events[2]! as ItemEvent;
      expect(item.phase, ItemPhase.completed);
      expect((item.item as AgentMessageItem).text, 'The quill writes itself.');
      final done = events[3]! as TurnCompleted;
      expect(done.inputTokens, 13089);
      expect(done.outputTokens, 10);
    });

    test('parses command execution and reasoning items', () {
      final started =
          parseCodexEvent(
                '{"type":"item.started","item":{"id":"item_1","type":"command_execution",'
                '"command":"cargo test","status":"in_progress"}}',
              )!
              as ItemEvent;
      expect(started.phase, ItemPhase.started);
      final cmd = started.item as CommandExecutionItem;
      expect(cmd.command, 'cargo test');
      expect(cmd.status, 'in_progress');

      final reasoning =
          parseCodexEvent(
                '{"type":"item.completed","item":{"id":"item_2","type":"reasoning",'
                '"text":"Reading the page"}}',
              )!
              as ItemEvent;
      expect((reasoning.item as ReasoningItem).text, 'Reading the page');
    });

    test('parses todo lists and failures', () {
      final todo =
          parseCodexEvent(
                '{"type":"item.completed","item":{"id":"i","type":"todo_list",'
                '"items":[{"text":"probe DRM","completed":false},'
                '{"text":"ship it","completed":true}]}}',
              )!
              as ItemEvent;
      final list = todo.item as TodoListItem;
      expect(list.entries, hasLength(2));
      expect(list.entries[1].completed, isTrue);

      final failed =
          parseCodexEvent(
                '{"type":"turn.failed","error":{"message":"stream disconnected"}}',
              )!
              as TurnFailed;
      expect(failed.message, 'stream disconnected');
    });

    test('covers the remaining official exec item and error surface', () {
      final file =
          parseCodexEvent(
                '{"type":"item.completed","item":{"id":"f","type":"file_change",'
                '"changes":[{"path":"lib/main.dart","kind":"update"}],'
                '"status":"completed"}}',
              )!
              as ItemEvent;
      expect((file.item as FileChangeItem).paths, ['lib/main.dart']);

      final mcp =
          parseCodexEvent(
                '{"type":"item.started","item":{"id":"m","type":"mcp_tool_call",'
                '"server":"docs","tool":"search","status":"in_progress"}}',
              )!
              as ItemEvent;
      expect((mcp.item as McpToolCallItem).server, 'docs');
      expect((mcp.item as McpToolCallItem).tool, 'search');

      final collab =
          parseCodexEvent(
                '{"type":"item.started","item":{"id":"c","type":"collab_tool_call",'
                '"tool":"spawn_agent","sender_thread_id":"root",'
                '"receiver_thread_ids":["child-1"],"agents_states":{},'
                '"status":"in_progress"}}',
              )!
              as ItemEvent;
      final collabItem = collab.item as CollabToolCallItem;
      expect(collabItem.tool, 'spawn_agent');
      expect(collabItem.receiverThreadIds, ['child-1']);
      expect(collabItem.status, 'in_progress');

      final web =
          parseCodexEvent(
                '{"type":"item.started","item":{"id":"w","type":"web_search",'
                '"query":"e-ink waveform","action":{"type":"search"}}}',
              )!
              as ItemEvent;
      expect((web.item as WebSearchItem).query, 'e-ink waveform');

      final error =
          parseCodexEvent('{"type":"error","message":"transport closed"}')!
              as StreamError;
      expect(error.message, 'transport closed');
    });

    test('tolerates junk, blanks, and unknown types', () {
      expect(parseCodexEvent(''), isNull);
      expect(parseCodexEvent('Reading prompt from stdin...'), isNull);
      expect(parseCodexEvent('{not json'), isNull);
      expect(parseCodexEvent('[1,2,3]'), isNull);
      expect(
        parseCodexEvent('{"type":"session.wormhole","x":1}'),
        isA<UnknownEvent>(),
      );
      final weirdItem =
          parseCodexEvent(
                '{"type":"item.completed","item":{"id":"i","type":"hologram"}}',
              )!
              as ItemEvent;
      expect(weirdItem.item, isA<UnknownItem>());
    });
  });
}
