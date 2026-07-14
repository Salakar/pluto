import 'package:flutter/foundation.dart';

/// Who wrote a transcript turn.
enum TurnRole { user, codex }

/// How a user turn was authored.
enum AuthorMode { keyboard, handwriting }

/// Message lifecycle. Queued user turns survive restarts; pending Codex turns
/// recover to failed on boot because their child process no longer exists.
enum MessageState { queued, pending, complete, failed }

/// A page's standing goal lifecycle.
enum GoalStatus { active, paused, done }

/// Paper-native failure taxonomy (from paper-codex `CodexError` + harness
/// spec classification).
enum FailureKind {
  binaryMissing,
  auth,
  network,
  timeout,
  nonZero,
  emptyAnswer,
  stopped,
  interrupted,
  sandbox,
}

/// The margin note wording for each failure (ERR catalog).
extension FailureNote on FailureKind {
  String get note => switch (this) {
    FailureKind.binaryMissing => 'codex not found',
    FailureKind.auth => 'codex sign-in expired',
    FailureKind.network =>
      'No connection. Your note is kept on this page - tap the mark to try again.',
    FailureKind.timeout => 'timed out',
    FailureKind.nonZero => 'Codex could not answer this turn.',
    FailureKind.emptyAnswer => 'Codex could not answer this turn.',
    FailureKind.stopped => 'Stopped.',
    FailureKind.interrupted => 'Interrupted - this page was closed.',
    FailureKind.sandbox => 'sandbox unavailable - ran unfenced',
  };
}

/// A point of a handwriting stroke, in design-pixel page coordinates.
@immutable
final class InkPoint {
  const InkPoint(this.x, this.y, this.pressure);

  final double x;
  final double y;
  final double pressure;

  List<double> toJson() => [x, y, pressure];

  static InkPoint fromJson(List<Object?> json) => InkPoint(
    (json[0]! as num).toDouble(),
    (json[1]! as num).toDouble(),
    (json[2]! as num).toDouble(),
  );
}

/// One committed pen stroke.
@immutable
final class InkStroke {
  const InkStroke({required this.points, this.width = 2.2});

  final List<InkPoint> points;

  /// Base nib width, design px.
  final double width;

  Map<String, Object?> toJson() => {
    'width': width,
    'points': [for (final p in points) p.toJson()],
  };

  static InkStroke fromJson(Map<String, Object?> json) => InkStroke(
    width: (json['width']! as num).toDouble(),
    points: [
      for (final p in json['points']! as List<Object?>)
        InkPoint.fromJson(p! as List<Object?>),
    ],
  );
}

/// A step of agent activity shown as marginal footprints while it works.
@immutable
final class ActivityNote {
  const ActivityNote({required this.kind, required this.label});

  /// e.g. `command`, `thinking`, `file`, `search`, `still`.
  final String kind;
  final String label;

  Map<String, Object?> toJson() => {'kind': kind, 'label': label};

  static ActivityNote fromJson(Map<String, Object?> json) => ActivityNote(
    kind: json['kind']! as String,
    label: json['label']! as String,
  );
}

/// One transcript turn.
final class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.mode,
    required this.text,
    required this.state,
    required this.createdAtMs,
    this.transcription,
    this.strokes = const [],
    this.error,
    this.activity = const [],
  });

  final String id;
  final TurnRole role;
  final AuthorMode mode;

  /// Body text: the prompt (keyboard turns) or the answer. For handwriting
  /// user turns this holds the Codex transcription once known (context only —
  /// the page keeps showing the ink).
  String text;
  String? transcription;

  /// Handwriting user turns keep their strokes; ink stays ink.
  List<InkStroke> strokes;

  MessageState state;
  FailureKind? error;

  /// Agent footprints observed during this turn (codex turns).
  List<ActivityNote> activity;

  final int createdAtMs;

  bool get isHandwritten => strokes.isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'mode': mode.name,
    'text': text,
    if (transcription != null) 'transcription': transcription,
    if (strokes.isNotEmpty) 'strokes': [for (final s in strokes) s.toJson()],
    'state': state.name,
    if (error != null) 'error': error!.name,
    if (activity.isNotEmpty) 'activity': [for (final a in activity) a.toJson()],
    'createdAtMs': createdAtMs,
  };

  static ChatMessage fromJson(Map<String, Object?> json) => ChatMessage(
    id: json['id']! as String,
    role: TurnRole.values.byName(json['role']! as String),
    mode: AuthorMode.values.byName(json['mode']! as String),
    text: json['text']! as String,
    transcription: json['transcription'] as String?,
    strokes: [
      for (final s in (json['strokes'] as List<Object?>?) ?? <Object?>[])
        InkStroke.fromJson(s! as Map<String, Object?>),
    ],
    state: MessageState.values.byName(json['state']! as String),
    error: json['error'] == null
        ? null
        : FailureKind.values.byName(json['error']! as String),
    activity: [
      for (final a in (json['activity'] as List<Object?>?) ?? <Object?>[])
        ActivityNote.fromJson(a! as Map<String, Object?>),
    ],
    createdAtMs: json['createdAtMs']! as int,
  );
}

/// A page in the notebook: one Codex conversation.
final class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.codexThreadId,
    this.goalText,
    this.goalStatus,
    this.mindModel,
    this.mindEffort,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];

  final String id;
  String title;
  String? codexThreadId;

  /// The page's standing goal, shown as a pinned ribbon and (while active)
  /// carried into every turn.
  String? goalText;
  GoalStatus? goalStatus;

  /// Per-page mind overrides; null falls back to the house defaults.
  String? mindModel;
  String? mindEffort;
  final int createdAtMs;
  int updatedAtMs;
  final List<ChatMessage> messages;

  bool get hasGoal => goalText != null && goalText!.trim().isNotEmpty;

  bool get isEmpty => messages.isEmpty;

  ChatMessage? get tail => messages.isEmpty ? null : messages.last;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (codexThreadId != null) 'codexThreadId': codexThreadId,
    if (goalText != null) 'goalText': goalText,
    if (goalStatus != null) 'goalStatus': goalStatus!.name,
    if (mindModel != null) 'mindModel': mindModel,
    if (mindEffort != null) 'mindEffort': mindEffort,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'messages': [for (final m in messages) m.toJson()],
  };

  static ChatSession fromJson(Map<String, Object?> json) => ChatSession(
    id: json['id']! as String,
    title: json['title']! as String,
    codexThreadId: json['codexThreadId'] as String?,
    goalText: json['goalText'] as String?,
    goalStatus: json['goalStatus'] == null
        ? null
        : GoalStatus.values.byName(json['goalStatus']! as String),
    mindModel: json['mindModel'] as String?,
    mindEffort: json['mindEffort'] as String?,
    createdAtMs: json['createdAtMs']! as int,
    updatedAtMs: json['updatedAtMs']! as int,
    messages: [
      for (final m in json['messages']! as List<Object?>)
        ChatMessage.fromJson(m! as Map<String, Object?>),
    ],
  );
}

/// Session title from the first prompt: ~7 words, ≤48 chars (TITLE spec).
String titleFromPrompt(String prompt) {
  final words = prompt
      .replaceAll('\n', ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(7)
      .toList();
  if (words.isEmpty) {
    return 'Untitled page';
  }
  var title = words.join(' ');
  if (title.length > 48) {
    title = '${title.substring(0, 47).trimRight()}…';
  }
  return title;
}
