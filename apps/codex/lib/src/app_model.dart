import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex/answer_parser.dart';
import 'codex/codex_bridge.dart';
import 'ink_render.dart';
import 'models.dart';
import 'services.dart';
import 'store.dart';

/// Keyboard layers (paper-codex `KeyboardLayer`).
enum KeyboardLayer { letters, symbols, moreSymbols }

/// Shift latch (paper-codex `ShiftState`).
enum ShiftLatch { off, once, lock }

/// Global turn phase — exactly one Codex turn may run at a time.
enum TurnPhase { idle, busy }

/// The notebook's single source of truth: an Elm-style model that mutates
/// only through action methods and notifies once per action.
final class CodexAppModel extends ChangeNotifier {
  CodexAppModel({required this.services, int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CodexServices services;
  final int Function() _nowMs;

  // --- notebook -----------------------------------------------------------

  final List<ChatSession> sessions = [];
  String? _activeId;
  bool _loaded = false;

  bool get loaded => _loaded;

  ChatSession get active {
    final id = _activeId;
    if (id != null) {
      for (final s in sessions) {
        if (s.id == id) {
          return s;
        }
      }
    }
    return _newSession();
  }

  // --- composer -----------------------------------------------------------

  AuthorMode inputMode = AuthorMode.keyboard;
  String keyboardDraft = '';
  int caret = 0;
  KeyboardLayer layer = KeyboardLayer.letters;
  ShiftLatch shift = ShiftLatch.off;
  List<InkStroke> _handwritingDraft = const [];
  List<InkStroke> get handwritingDraft => _handwritingDraft;

  bool get keyboardSendEnabled => keyboardDraft.trim().isNotEmpty;

  bool get handwritingSendEnabled => handwritingDraft.isNotEmpty;

  // --- turn ----------------------------------------------------------------

  TurnPhase phase = TurnPhase.idle;
  CodexTurnHandle? _handle;
  StreamSubscription<TurnUpdate>? _updatesSub;
  bool _stopBeforeStart = false;
  bool _stopPausesQueue = false;
  String? _steerMessageId;

  List<({ChatSession session, ChatMessage message})> get _queuedTurns {
    final turns = <({ChatSession session, ChatMessage message})>[
      for (final session in sessions)
        for (final message in session.messages)
          if (message.role == TurnRole.user &&
              message.state == MessageState.queued)
            (session: session, message: message),
    ];
    turns.sort((a, b) {
      final byTime = a.message.createdAtMs.compareTo(b.message.createdAtMs);
      return byTime != 0 ? byTime : a.message.id.compareTo(b.message.id);
    });
    return turns;
  }

  int get queuedCount => _queuedTurns.length;

  int queuePosition(ChatMessage message) {
    final index = _queuedTurns.indexWhere(
      (turn) => turn.message.id == message.id,
    );
    return index < 0 ? 0 : index + 1;
  }

  /// Marginal footprints for the in-flight turn (latest last).
  final List<ActivityNote> liveActivity = [];
  bool stillThinking = false;

  /// Breathing phase of the thinking spiral (toggled by the page each
  /// second while busy).
  int thinkingPhase = 0;

  void breathe() {
    if (phase == TurnPhase.busy) {
      thinkingPhase = 1 - thinkingPhase;
      notifyListeners();
    }
  }

  /// Set briefly when an action that cannot be queued is rejected while busy.
  bool busyNudge = false;

  /// Message id that should quill-reveal (the turn that just resolved).
  String? revealMessageId;

  /// Bumped whenever the page should snap back to its tail (sends, answers,
  /// page switches). The transcript listens and scrolls to the bottom.
  int scrollNonce = 0;

  /// The writer's instrument: model + effort overrides (null = house).
  MindSettings mind = const MindSettings();

  /// When true the composer edits the page's goal instead of sending a turn.
  bool goalEditing = false;

  /// Whether the per-page mind sheet is open.
  bool pageMindOpen = false;

  /// The model this page actually writes with (override, else house).
  String? effectiveModel(ChatSession session) =>
      session.mindModel ?? mind.model;

  String? effectiveEffort(ChatSession session) => MindSettings.normalizeEffort(
    session.mindEffort ?? mind.effort,
    model: effectiveModel(session),
  );

  // --- overlays -------------------------------------------------------------

  bool shelfOpen = false;

  // --- lifecycle -------------------------------------------------------------

  Future<void> init() async {
    mind = await services.mindStore.load();
    final loadedSessions = await services.store.load();
    final hadInterrupted = loadedSessions.any(
      (s) => s.messages.any((m) => m.state == MessageState.pending),
    );
    TranscriptStore.recoverInterrupted(loadedSessions);
    var repairedMind = false;
    for (final session in loadedSessions) {
      final normalized = MindSettings.normalizeEffort(
        session.mindEffort,
        model: session.mindModel ?? mind.model,
      );
      if (normalized != session.mindEffort) {
        session.mindEffort = normalized;
        repairedMind = true;
      }
    }
    sessions
      ..clear()
      ..addAll(loadedSessions);
    _sortSessions();
    if (sessions.isEmpty) {
      _newSession();
    } else {
      _activeId = sessions.first.id;
    }
    _loaded = true;
    notifyListeners();
    if (hadInterrupted || repairedMind) {
      await _persist();
    }
  }

  ChatSession _newSession() {
    final session = ChatSession(
      id: 'page-${_nowMs()}-${sessions.length}',
      title: 'New page',
      createdAtMs: _nowMs(),
      updatedAtMs: _nowMs(),
    );
    sessions.insert(0, session);
    _activeId = session.id;
    return session;
  }

  void _sortSessions() {
    sessions.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
  }

  Future<void> _persist() async {
    try {
      await services.store.save(sessions);
    } on Object {
      // ERR-005: saving must never take the page down.
    }
  }

  // --- composer actions ------------------------------------------------------

  void keyTap(String text) {
    var t = text;
    if (shift != ShiftLatch.off && layer == KeyboardLayer.letters) {
      t = t.toUpperCase();
      if (shift == ShiftLatch.once) {
        shift = ShiftLatch.off;
      }
    }
    keyboardDraft =
        keyboardDraft.substring(0, caret) + t + keyboardDraft.substring(caret);
    caret += t.length;
    notifyListeners();
  }

  void backspace() {
    if (caret == 0) {
      return;
    }
    keyboardDraft =
        keyboardDraft.substring(0, caret - 1) + keyboardDraft.substring(caret);
    caret -= 1;
    notifyListeners();
  }

  void returnKey() => keyTap('\n');

  void cursorLeft() {
    if (caret > 0) {
      caret -= 1;
      notifyListeners();
    }
  }

  void cursorRight() {
    if (caret < keyboardDraft.length) {
      caret += 1;
      notifyListeners();
    }
  }

  void shiftTap() {
    shift = switch (shift) {
      ShiftLatch.off => ShiftLatch.once,
      ShiftLatch.once => ShiftLatch.lock,
      ShiftLatch.lock => ShiftLatch.off,
    };
    notifyListeners();
  }

  void layerTap(String label) {
    layer = switch (label) {
      '123' => KeyboardLayer.symbols,
      '#+=' => KeyboardLayer.moreSymbols,
      _ => KeyboardLayer.letters,
    };
    notifyListeners();
  }

  Future<void> setMindModel(String? model) async {
    mind = mind.copyWith(
      model: () => model,
      effort: () => MindSettings.normalizeEffort(mind.effort, model: model),
    );
    notifyListeners();
    await services.mindStore.save(mind);
  }

  Future<void> setMindEffort(String? effort) async {
    mind = mind.copyWith(
      effort: () => MindSettings.normalizeEffort(effort, model: mind.model),
    );
    notifyListeners();
    await services.mindStore.save(mind);
  }

  void openPageMind() {
    pageMindOpen = true;
    notifyListeners();
  }

  void closePageMind() {
    pageMindOpen = false;
    notifyListeners();
  }

  Future<void> setPageMindModel(String? model) async {
    final session = active;
    session.mindModel = model;
    session.mindEffort = MindSettings.normalizeEffort(
      session.mindEffort,
      model: model ?? mind.model,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> setPageMindEffort(String? effort) async {
    final session = active;
    session.mindEffort = MindSettings.normalizeEffort(
      effort,
      model: session.mindModel ?? mind.model,
    );
    notifyListeners();
    await _persist();
  }

  // --- the page's goal -------------------------------------------------------

  /// Opens the composer in goal mode, prefilled with the current goal.
  void beginGoalEdit() {
    if (phase != TurnPhase.idle) {
      _rejectIfBusy();
      return;
    }
    goalEditing = true;
    inputMode = AuthorMode.keyboard;
    keyboardDraft = active.goalText ?? '';
    caret = keyboardDraft.length;
    notifyListeners();
  }

  void cancelGoalEdit() {
    if (!goalEditing) {
      return;
    }
    goalEditing = false;
    keyboardDraft = '';
    caret = 0;
    notifyListeners();
  }

  /// Commits the draft as the page's goal (empty draft clears the goal).
  Future<void> commitGoalEdit() async {
    final session = active;
    final text = keyboardDraft.trim();
    goalEditing = false;
    keyboardDraft = '';
    caret = 0;
    if (text.isEmpty) {
      session.goalText = null;
      session.goalStatus = null;
    } else {
      session.goalText = text;
      session.goalStatus = GoalStatus.active;
    }
    session.updatedAtMs = _nowMs();
    notifyListeners();
    await _persist();
  }

  Future<void> toggleGoalPaused() async {
    final session = active;
    if (!session.hasGoal || session.goalStatus == GoalStatus.done) {
      return;
    }
    session.goalStatus = session.goalStatus == GoalStatus.paused
        ? GoalStatus.active
        : GoalStatus.paused;
    notifyListeners();
    await _persist();
  }

  Future<void> toggleGoalDone() async {
    final session = active;
    if (!session.hasGoal) {
      return;
    }
    session.goalStatus = session.goalStatus == GoalStatus.done
        ? GoalStatus.active
        : GoalStatus.done;
    notifyListeners();
    await _persist();
  }

  void toggleMode() {
    goalEditing = false;
    inputMode = inputMode == AuthorMode.keyboard
        ? AuthorMode.handwriting
        : AuthorMode.keyboard;
    notifyListeners();
  }

  void addStroke(InkStroke stroke) {
    if (stroke.points.isEmpty) {
      return;
    }
    _handwritingDraft = List.unmodifiable([..._handwritingDraft, stroke]);
    notifyListeners();
  }

  void undoStroke() {
    if (_handwritingDraft.isNotEmpty) {
      _handwritingDraft = List.unmodifiable(
        _handwritingDraft.take(_handwritingDraft.length - 1),
      );
      notifyListeners();
    }
  }

  void clearStrokes() {
    if (_handwritingDraft.isNotEmpty) {
      _handwritingDraft = const [];
      notifyListeners();
    }
  }

  // --- shelf / navigation -----------------------------------------------------

  void openShelf() {
    shelfOpen = true;
    notifyListeners();
  }

  void closeShelf() {
    shelfOpen = false;
    notifyListeners();
  }

  void selectSession(String id) {
    if (sessions.any((s) => s.id == id)) {
      _activeId = id;
      shelfOpen = false;
      revealMessageId = null;
      goalEditing = false;
      pageMindOpen = false;
      scrollNonce += 1;
      notifyListeners();
    }
  }

  void newPage() {
    // Reuse the current page if it is already blank.
    if (active.isEmpty) {
      shelfOpen = false;
      notifyListeners();
      return;
    }
    _newSession();
    shelfOpen = false;
    revealMessageId = null;
    goalEditing = false;
    pageMindOpen = false;
    scrollNonce += 1;
    notifyListeners();
  }

  // --- turn actions -------------------------------------------------------------

  /// Rejects input while busy with a nudge note (BUSY-001).
  bool _rejectIfBusy() {
    if (phase == TurnPhase.idle) {
      return false;
    }
    busyNudge = true;
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      busyNudge = false;
      notifyListeners();
    });
    return true;
  }

  Future<void> sendKeyboard() async {
    if (goalEditing) {
      await commitGoalEdit();
      return;
    }
    final prompt = keyboardDraft.trim();
    if (prompt.isEmpty) {
      return;
    }
    keyboardDraft = '';
    caret = 0;
    final user = ChatMessage(
      id: 'm-${_nowMs()}-u',
      role: TurnRole.user,
      mode: AuthorMode.keyboard,
      text: prompt,
      state: MessageState.complete,
      createdAtMs: _nowMs(),
    );
    await _submitTurn(active, user);
  }

  Future<void> sendHandwriting() async {
    if (_handwritingDraft.isEmpty) {
      return;
    }
    final strokes = normalizeStrokes(_handwritingDraft);
    _handwritingDraft = const [];
    // Clear the physical composer immediately. Image encoding and the Codex
    // turn can both await IO; the consumed ink must not remain visible while
    // either is in flight.
    notifyListeners();
    final user = ChatMessage(
      id: 'm-${_nowMs()}-u',
      role: TurnRole.user,
      mode: AuthorMode.handwriting,
      text: '',
      strokes: strokes,
      state: MessageState.complete,
      createdAtMs: _nowMs(),
    );
    await _submitTurn(active, user);
  }

  Future<void> _submitTurn(ChatSession session, ChatMessage user) async {
    if (phase == TurnPhase.busy || queuedCount > 0) {
      user.state = MessageState.queued;
      session.messages.add(user);
      _titleFromUserIfFirst(session, user);
      session.updatedAtMs = _nowMs();
      _sortSessions();
      scrollNonce += 1;
      notifyListeners();
      await _persist();
      return;
    }
    await _startUserTurn(session, user, userAlreadyAdded: false);
  }

  Future<void> _startUserTurn(
    ChatSession session,
    ChatMessage user, {
    required bool userAlreadyAdded,
  }) async {
    String prompt;
    String? imagePath;
    if (user.mode == AuthorMode.handwriting) {
      prompt = handwritingPrompt;
      try {
        imagePath = await renderStrokesPng(user.strokes, services.paths.tmp);
      } on Object {
        imagePath = null;
      }
    } else {
      prompt = user.text;
    }
    await _beginTurn(
      user,
      session: session,
      prompt: prompt,
      imagePath: imagePath,
      userAlreadyAdded: userAlreadyAdded,
    );
  }

  Future<void> _beginTurn(
    ChatMessage user, {
    required ChatSession session,
    required String prompt,
    String? imagePath,
    ChatMessage? reusePending,
    bool userAlreadyAdded = false,
  }) async {
    if (reusePending == null && !userAlreadyAdded) {
      session.messages.add(user);
    }
    user.state = MessageState.complete;
    final pending =
        reusePending ??
        ChatMessage(
          id: 'm-${_nowMs()}-c',
          role: TurnRole.codex,
          mode: user.mode,
          text: '',
          state: MessageState.pending,
          createdAtMs: _nowMs(),
        );
    if (reusePending == null) {
      session.messages.add(pending);
    } else {
      pending
        ..state = MessageState.pending
        ..error = null;
    }
    _titleFromUserIfFirst(session, user);
    session.updatedAtMs = _nowMs();
    _sortSessions();
    phase = TurnPhase.busy;
    liveActivity.clear();
    stillThinking = false;
    revealMessageId = null;
    scrollNonce += 1;
    notifyListeners();
    await _persist();

    final request = CodexTurnRequest(
      prompt: _withGoal(session, prompt),
      workspace: services.paths.workspace.path,
      threadId: session.codexThreadId,
      imagePath: imagePath,
      model: effectiveModel(session),
      effort: effectiveEffort(session),
    );
    await _runTurn(session, user, pending, request);
  }

  void _titleFromUserIfFirst(ChatSession session, ChatMessage user) {
    if (session.messages.where((m) => m.role == TurnRole.user).length == 1 &&
        user.text.isNotEmpty) {
      session.title = titleFromPrompt(user.text);
    }
  }

  /// While the page's goal is active, every turn opens with it.
  String _withGoal(ChatSession session, String prompt) {
    if (session.hasGoal && session.goalStatus == GoalStatus.active) {
      final goal = session.goalText!.trim();
      return 'Standing goal for this page: $goal\n\n$prompt';
    }
    return prompt;
  }

  Future<void> _runTurn(
    ChatSession session,
    ChatMessage user,
    ChatMessage pending,
    CodexTurnRequest request,
  ) async {
    final handle = services.bridge.startTurn(request);
    _handle = handle;
    if (_stopBeforeStart) {
      _stopBeforeStart = false;
      handle.stop();
    }
    _updatesSub = handle.updates.listen((update) => _onUpdate(session, update));
    var outcome = await handle.outcome;

    // Resume fallback: a stale thread id must not strand the page — retry
    // once as a fresh conversation carrying recent history in the prompt.
    if (!outcome.ok && request.threadId != null) {
      final detail = outcome.detail.toLowerCase();
      final retryableFailure =
          outcome.failure == FailureKind.nonZero ||
          outcome.failure == FailureKind.emptyAnswer;
      final looksLikeLostThread =
          detail.contains('session not found') ||
          detail.contains('thread not found') ||
          detail.contains('no session found') ||
          detail.contains('failed to resume') ||
          detail.contains('unable to resume') ||
          detail.contains('could not resume');
      if (retryableFailure && looksLikeLostThread) {
        final fresh = CodexTurnRequest(
          prompt: _promptWithHistory(
            session,
            request.prompt,
            excludeMessageId: user.id,
          ),
          workspace: request.workspace,
          imagePath: request.imagePath,
          sandbox: request.sandbox,
          model: request.model,
          effort: request.effort,
        );
        final retryHandle = services.bridge.startTurn(fresh);
        _handle = retryHandle;
        await _updatesSub?.cancel();
        _updatesSub = retryHandle.updates.listen(
          (update) => _onUpdate(session, update),
        );
        outcome = await retryHandle.outcome;
      }
    }

    await _updatesSub?.cancel();
    _updatesSub = null;
    _handle = null;

    _applyOutcome(session, user, pending, outcome);
    scrollNonce += 1;
    phase = TurnPhase.idle;
    stillThinking = false;
    liveActivity.clear();
    notifyListeners();
    await _persist();

    final steerMessageId = _steerMessageId;
    _steerMessageId = null;
    final pauseQueue = _stopPausesQueue;
    _stopPausesQueue = false;
    if (steerMessageId != null) {
      final selected = _queuedTurns
          .where((turn) => turn.message.id == steerMessageId)
          .firstOrNull;
      if (selected != null) {
        await _startUserTurn(
          selected.session,
          selected.message,
          userAlreadyAdded: true,
        );
      }
      return;
    }
    if (outcome.ok && !pauseQueue) {
      final next = _queuedTurns.firstOrNull;
      if (next != null) {
        await _startUserTurn(
          next.session,
          next.message,
          userAlreadyAdded: true,
        );
      }
    }
  }

  void _onUpdate(ChatSession session, TurnUpdate update) {
    switch (update) {
      case TurnThread(:final threadId):
        session.codexThreadId = threadId;
      case TurnActivity(:final note):
        liveActivity.add(note);
        if (liveActivity.length > 3) {
          liveActivity.removeRange(0, liveActivity.length - 3);
        }
      case TurnStillThinking():
        stillThinking = true;
    }
    notifyListeners();
  }

  void _applyOutcome(
    ChatSession session,
    ChatMessage user,
    ChatMessage pending,
    TurnOutcome outcome,
  ) {
    if (outcome.threadId != null) {
      session.codexThreadId = outcome.threadId;
    }
    pending.activity = List.of(liveActivity);
    if (outcome.ok) {
      var answer = outcome.answer!;
      if (user.mode == AuthorMode.handwriting) {
        final parsed = parseAnswerSections(answer);
        answer = parsed.answer;
        if (parsed.transcription != null && parsed.transcription!.isNotEmpty) {
          user.transcription = parsed.transcription;
          if (session.messages.where((m) => m.role == TurnRole.user).length ==
              1) {
            session.title = titleFromPrompt(parsed.transcription!);
          }
        }
      }
      pending
        ..text = answer
        ..state = MessageState.complete
        ..error = null;
      revealMessageId = pending.id;
    } else {
      pending
        ..state = MessageState.failed
        ..error = outcome.failure ?? FailureKind.nonZero;
      if (outcome.answer != null && outcome.answer!.isNotEmpty) {
        pending.text = outcome.answer!;
      }
    }
    session.updatedAtMs = _nowMs();
    _sortSessions();
  }

  String _promptWithHistory(
    ChatSession session,
    String prompt, {
    String? excludeMessageId,
  }) {
    const window = 12;
    final lines = <String>[];
    final history = session.messages
        .where(
          (m) =>
              m.id != excludeMessageId &&
              m.state == MessageState.complete &&
              (m.text.isNotEmpty || m.transcription != null),
        )
        .toList();
    final start = history.length > window ? history.length - window : 0;
    for (final m in history.sublist(start)) {
      final who = m.role == TurnRole.user ? 'User' : 'Codex';
      final text = m.role == TurnRole.user && m.transcription != null
          ? m.transcription!
          : m.text;
      lines.add('$who: ${text.replaceAll('\n', ' ')}');
    }
    if (lines.isEmpty) {
      return prompt;
    }
    return 'Earlier on this page:\n${lines.join('\n')}\n\n$prompt';
  }

  void _requestStop() {
    final handle = _handle;
    if (handle == null) {
      _stopBeforeStart = true;
    } else {
      handle.stop();
    }
  }

  /// Stops the in-flight turn and leaves queued notes waiting on their pages.
  void stopTurn() {
    if (phase != TurnPhase.busy) {
      return;
    }
    _steerMessageId = null;
    _stopPausesQueue = true;
    _requestStop();
  }

  /// Interrupts the current turn, then promotes this queued note immediately.
  Future<void> steerNow(ChatMessage message) async {
    if (message.role != TurnRole.user || message.state != MessageState.queued) {
      return;
    }
    _stopPausesQueue = false;
    if (phase == TurnPhase.busy) {
      _steerMessageId = message.id;
      _requestStop();
      notifyListeners();
      return;
    }
    final selected = _queuedTurns
        .where((turn) => turn.message.id == message.id)
        .firstOrNull;
    if (selected != null) {
      await _startUserTurn(
        selected.session,
        selected.message,
        userAlreadyAdded: true,
      );
    }
  }

  /// Retries the failed tail turn in place (ERR-004).
  Future<void> retryTail() async {
    if (phase != TurnPhase.idle) {
      _rejectIfBusy();
      return;
    }
    final session = active;
    final tail = session.tail;
    if (tail == null ||
        tail.role != TurnRole.codex ||
        tail.state != MessageState.failed) {
      return;
    }
    final userIndex = session.messages.length - 2;
    if (userIndex < 0) {
      return;
    }
    final user = session.messages[userIndex];
    String prompt;
    String? imagePath;
    if (user.mode == AuthorMode.handwriting) {
      prompt = handwritingPrompt;
      try {
        imagePath = await renderStrokesPng(user.strokes, services.paths.tmp);
      } on Object {
        imagePath = null;
      }
    } else {
      prompt = user.text;
    }
    phase = TurnPhase.busy;
    liveActivity.clear();
    stillThinking = false;
    revealMessageId = null;
    tail
      ..state = MessageState.pending
      ..error = null;
    notifyListeners();
    await _persist();
    final request = CodexTurnRequest(
      prompt: _withGoal(session, prompt),
      workspace: services.paths.workspace.path,
      threadId: session.codexThreadId,
      imagePath: imagePath,
      model: effectiveModel(session),
      effort: effectiveEffort(session),
    );
    await _runTurn(session, user, tail, request);
  }

  @override
  void dispose() {
    unawaited(_updatesSub?.cancel());
    super.dispose();
  }
}
