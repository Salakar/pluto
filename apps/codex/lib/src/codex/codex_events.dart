import 'dart:convert';

/// The `codex exec --json` JSONL event vocabulary (verified against
/// codex-cli 0.144.x): `thread.started`, `turn.started`, `item.started`,
/// `item.updated`, `item.completed`, `turn.completed`, `turn.failed`,
/// `error`. Unknown types map to [UnknownEvent] so protocol drift degrades
/// gracefully instead of crashing a turn.
sealed class CodexEvent {
  const CodexEvent();
}

final class ThreadStarted extends CodexEvent {
  const ThreadStarted(this.threadId);

  final String threadId;
}

final class TurnStarted extends CodexEvent {
  const TurnStarted();
}

enum ItemPhase { started, updated, completed }

final class ItemEvent extends CodexEvent {
  const ItemEvent(this.phase, this.item);

  final ItemPhase phase;
  final CodexItem item;
}

final class TurnCompleted extends CodexEvent {
  const TurnCompleted({this.inputTokens = 0, this.outputTokens = 0});

  final int inputTokens;
  final int outputTokens;
}

final class TurnFailed extends CodexEvent {
  const TurnFailed(this.message);

  final String message;
}

final class StreamError extends CodexEvent {
  const StreamError(this.message);

  final String message;
}

final class UnknownEvent extends CodexEvent {
  const UnknownEvent(this.type);

  final String type;
}

/// Items within a turn.
sealed class CodexItem {
  const CodexItem(this.id);

  final String id;
}

final class AgentMessageItem extends CodexItem {
  const AgentMessageItem(super.id, this.text);

  final String text;
}

final class ReasoningItem extends CodexItem {
  const ReasoningItem(super.id, this.text);

  final String text;
}

final class CommandExecutionItem extends CodexItem {
  const CommandExecutionItem(
    super.id, {
    required this.command,
    this.exitCode,
    this.status,
  });

  final String command;
  final int? exitCode;
  final String? status;
}

final class FileChangeItem extends CodexItem {
  const FileChangeItem(super.id, this.paths);

  final List<String> paths;
}

final class McpToolCallItem extends CodexItem {
  const McpToolCallItem(super.id, {required this.server, required this.tool});

  final String server;
  final String tool;
}

final class CollabToolCallItem extends CodexItem {
  const CollabToolCallItem(
    super.id, {
    required this.tool,
    required this.receiverThreadIds,
    this.status,
  });

  final String tool;
  final List<String> receiverThreadIds;
  final String? status;
}

final class WebSearchItem extends CodexItem {
  const WebSearchItem(super.id, this.query);

  final String query;
}

final class TodoListItem extends CodexItem {
  const TodoListItem(super.id, this.entries);

  final List<({String text, bool completed})> entries;
}

final class ErrorItem extends CodexItem {
  const ErrorItem(super.id, this.message);

  final String message;
}

final class UnknownItem extends CodexItem {
  const UnknownItem(super.id, this.type);

  final String type;
}

/// Parses one stdout line. Returns null for blank/non-JSON lines (codex may
/// interleave plain-text notices).
CodexEvent? parseCodexEvent(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final type = decoded['type'];
  if (type is! String) {
    return null;
  }
  switch (type) {
    case 'thread.started':
      final id = decoded['thread_id'];
      return id is String
          ? ThreadStarted(id)
          : const UnknownEvent('thread.started');
    case 'turn.started':
      return const TurnStarted();
    case 'item.started':
    case 'item.updated':
    case 'item.completed':
      final phase = switch (type) {
        'item.started' => ItemPhase.started,
        'item.updated' => ItemPhase.updated,
        _ => ItemPhase.completed,
      };
      final raw = decoded['item'];
      if (raw is! Map<String, Object?>) {
        return UnknownEvent(type);
      }
      return ItemEvent(phase, _parseItem(raw));
    case 'turn.completed':
      final usage = decoded['usage'];
      if (usage is Map<String, Object?>) {
        return TurnCompleted(
          inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
          outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
        );
      }
      return const TurnCompleted();
    case 'turn.failed':
      return TurnFailed(_errorMessage(decoded['error']) ?? 'turn failed');
    case 'error':
      return StreamError(
        (decoded['message'] as String?) ??
            _errorMessage(decoded['error']) ??
            'stream error',
      );
    default:
      return UnknownEvent(type);
  }
}

String? _errorMessage(Object? error) {
  if (error is Map<String, Object?>) {
    final m = error['message'];
    if (m is String) {
      return m;
    }
  }
  if (error is String) {
    return error;
  }
  return null;
}

CodexItem _parseItem(Map<String, Object?> raw) {
  final id = (raw['id'] as String?) ?? '';
  final type = raw['type'];
  switch (type) {
    case 'agent_message':
      return AgentMessageItem(id, (raw['text'] as String?) ?? '');
    case 'reasoning':
      return ReasoningItem(id, (raw['text'] as String?) ?? '');
    case 'command_execution':
      return CommandExecutionItem(
        id,
        command: (raw['command'] as String?) ?? '',
        exitCode: (raw['exit_code'] as num?)?.toInt(),
        status: raw['status'] as String?,
      );
    case 'file_change':
      final changes = raw['changes'];
      return FileChangeItem(id, [
        if (changes is List<Object?>)
          for (final c in changes)
            if (c is Map<String, Object?> && c['path'] is String)
              c['path']! as String,
      ]);
    case 'mcp_tool_call':
      return McpToolCallItem(
        id,
        server: (raw['server'] as String?) ?? '',
        tool: (raw['tool'] as String?) ?? '',
      );
    case 'collab_tool_call':
      final receivers = raw['receiver_thread_ids'];
      return CollabToolCallItem(
        id,
        tool: (raw['tool'] as String?) ?? '',
        receiverThreadIds: [
          if (receivers is List<Object?>)
            for (final receiver in receivers)
              if (receiver is String) receiver,
        ],
        status: raw['status'] as String?,
      );
    case 'web_search':
      return WebSearchItem(id, (raw['query'] as String?) ?? '');
    case 'todo_list':
      final items = raw['items'];
      return TodoListItem(id, [
        if (items is List<Object?>)
          for (final it in items)
            if (it is Map<String, Object?>)
              (
                text: (it['text'] as String?) ?? '',
                completed: (it['completed'] as bool?) ?? false,
              ),
      ]);
    case 'error':
      return ErrorItem(id, (raw['message'] as String?) ?? 'error');
    default:
      return UnknownItem(id, type is String ? type : 'unknown');
  }
}
