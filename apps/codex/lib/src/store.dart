import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Atomic JSON persistence for the notebook (paper-codex `model.rs`
/// semantics): tmp write + flush + rename; corrupt files are set aside, never
/// fatal; interrupted turns recover to failed at boot.
final class TranscriptStore {
  TranscriptStore({required this.stateDir});

  final Directory stateDir;

  File get _file => File('${stateDir.path}/chats.json');

  Future<List<ChatSession>> load() async {
    if (!_file.existsSync()) {
      return [];
    }
    try {
      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('not an object');
      }
      final sessions = decoded['sessions'];
      if (sessions is! List<Object?>) {
        throw const FormatException('no sessions');
      }
      return [
        for (final s in sessions)
          ChatSession.fromJson(s! as Map<String, Object?>),
      ];
    } on Object {
      // Set the corrupt file aside and start fresh — the page must open.
      try {
        final ts = DateTime.now().millisecondsSinceEpoch;
        await _file.rename('${_file.path}.corrupt-$ts');
      } on Object {
        // Even that failing must not block boot.
      }
      return [];
    }
  }

  Future<void> save(List<ChatSession> sessions) async {
    stateDir.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    final payload = jsonEncode({
      'sessions': [for (final s in sessions) s.toJson()],
    });
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(payload);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(_file.path);
  }

  /// Boot recovery: pending turns from a previous run become failed
  /// (interrupted); pending user turns settle to complete.
  static void recoverInterrupted(List<ChatSession> sessions) {
    for (final session in sessions) {
      for (final message in session.messages) {
        if (message.state != MessageState.pending) {
          continue;
        }
        if (message.role == TurnRole.codex) {
          message
            ..state = MessageState.failed
            ..error = FailureKind.interrupted;
        } else {
          message.state = MessageState.complete;
        }
      }
    }
  }
}
