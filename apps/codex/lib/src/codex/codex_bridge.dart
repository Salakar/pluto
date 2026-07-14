import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'codex_events.dart';

/// A request for one Codex turn.
final class CodexTurnRequest {
  const CodexTurnRequest({
    required this.prompt,
    required this.workspace,
    this.threadId,
    this.imagePath,
    this.sandbox = 'workspace-write',
    this.model,
    this.effort,
  });

  final String prompt;

  /// Codex working root (`-C`).
  final String workspace;

  /// Resume this thread when set; fresh turn otherwise.
  final String? threadId;

  /// Attach an image (handwriting page render).
  final String? imagePath;

  final String sandbox;

  /// Model override (`-m`); null = as the house config set it.
  final String? model;

  /// Reasoning effort override (`-c model_reasoning_effort=…`); null = house.
  final String? effort;
}

/// Live progress of a turn, surfaced as paper-native footprints.
sealed class TurnUpdate {
  const TurnUpdate();
}

final class TurnThread extends TurnUpdate {
  const TurnThread(this.threadId);

  final String threadId;
}

final class TurnActivity extends TurnUpdate {
  const TurnActivity(this.note);

  final ActivityNote note;
}

final class TurnStillThinking extends TurnUpdate {
  const TurnStillThinking();
}

/// Terminal result of a turn.
final class TurnOutcome {
  const TurnOutcome({
    this.answer,
    this.threadId,
    this.failure,
    this.detail = '',
  });

  final String? answer;
  final String? threadId;
  final FailureKind? failure;
  final String detail;

  bool get ok => failure == null && answer != null;
}

/// A running turn: progress stream + terminal outcome + cancellation.
abstract interface class CodexTurnHandle {
  Stream<TurnUpdate> get updates;

  Future<TurnOutcome> get outcome;

  /// User-initiated stop (SEND-007): terminate, classify as stopped.
  void stop();
}

/// Health snapshot for the settings page.
final class CodexProbe {
  const CodexProbe({
    required this.binaryPath,
    required this.version,
    required this.loggedIn,
  });

  final String? binaryPath;
  final String? version;
  final bool loggedIn;
}

/// The gateway to the codex CLI.
abstract interface class CodexBridge {
  CodexTurnHandle startTurn(CodexTurnRequest request);

  Future<CodexProbe> probe();
}

/// Spawns `codex exec --json` / `codex exec resume <id> --json` and folds the
/// JSONL event stream into [TurnUpdate]s + a classified [TurnOutcome].
final class LiveCodexBridge implements CodexBridge {
  LiveCodexBridge({
    List<String>? binaryCandidates,
    this.softTimeout = const Duration(seconds: 120),
    this.hardTimeout = const Duration(minutes: 10),
    this.killGrace = const Duration(seconds: 5),
    Future<bool> Function()? networkProbe,
  }) : binaryCandidates = binaryCandidates ?? defaultBinaryCandidates(),
       networkProbe = networkProbe ?? hasNetwork;

  final List<String> binaryCandidates;
  final Duration softTimeout;
  final Duration hardTimeout;
  final Duration killGrace;

  /// Answers whether the API is plausibly reachable (injectable for tests).
  final Future<bool> Function() networkProbe;

  /// True when some DNS answers — codex has a chance of reaching the API.
  /// Without this, an offline device sits silent for codex's own network
  /// timeouts; the page must answer within a breath (ERR-009).
  static Future<bool> hasNetwork() async {
    for (final host in ['api.openai.com', 'chatgpt.com']) {
      try {
        final addresses = await InternetAddress.lookup(
          host,
        ).timeout(const Duration(milliseconds: 1500));
        if (addresses.isNotEmpty) {
          return true;
        }
      } on Object {
        // Try the next host.
      }
    }
    return false;
  }

  static List<String> defaultBinaryCandidates() => [
    if (Platform.environment['PAPER_CODEX_BIN'] case final String p
        when p.isNotEmpty)
      p,
    '/home/root/bin/codex',
    '/home/root/.local/bin/codex',
    'codex',
  ];

  String? _resolvedBinary;

  String? resolveBinary() {
    if (_resolvedBinary != null) {
      return _resolvedBinary;
    }
    for (final candidate in binaryCandidates) {
      if (candidate.contains('/')) {
        if (File(candidate).existsSync()) {
          return _resolvedBinary = candidate;
        }
      } else {
        return _resolvedBinary = candidate; // rely on PATH lookup
      }
    }
    return null;
  }

  static List<String> argsFor(CodexTurnRequest request) {
    final threadId = request.threadId;
    return [
      'exec',
      if (threadId != null) ...['resume', threadId],
      '--json',
      '--skip-git-repo-check',
      // `exec resume` inherits sandbox/cwd from the original session.
      if (threadId == null) ...['--sandbox', request.sandbox],
      if (threadId == null) ...['-C', request.workspace],
      if (request.model != null) ...['-m', request.model!],
      if (request.effort != null) ...[
        '-c',
        'model_reasoning_effort="${request.effort!}"',
      ],
      if (request.imagePath != null) ...['-i', request.imagePath!],
      // Keep arbitrary/user-authored text out of argv and force Codex to read
      // the prompt from the pipe that _LiveTurn closes after writing it.
      '-',
    ];
  }

  @override
  CodexTurnHandle startTurn(CodexTurnRequest request) =>
      _LiveTurn(this, request);

  @override
  Future<CodexProbe> probe() async {
    final binary = resolveBinary();
    if (binary == null) {
      return const CodexProbe(binaryPath: null, version: null, loggedIn: false);
    }
    String? version;
    var loggedIn = false;
    try {
      final v = await Process.run(binary, [
        '--version',
      ]).timeout(const Duration(seconds: 10));
      if (v.exitCode == 0) {
        version = (v.stdout as String).trim();
      }
      final s = await Process.run(binary, [
        'login',
        'status',
      ]).timeout(const Duration(seconds: 10));
      final out = '${s.stdout}\n${s.stderr}'.toLowerCase();
      loggedIn = s.exitCode == 0 && !out.contains('not logged in');
    } on Object {
      // Unreachable binary counts as missing.
      return const CodexProbe(binaryPath: null, version: null, loggedIn: false);
    }
    return CodexProbe(binaryPath: binary, version: version, loggedIn: loggedIn);
  }
}

final class _LiveTurn implements CodexTurnHandle {
  _LiveTurn(this._bridge, this._request) {
    unawaited(_runSafely());
  }

  final LiveCodexBridge _bridge;
  final CodexTurnRequest _request;

  final _updates = StreamController<TurnUpdate>.broadcast();
  final _outcome = Completer<TurnOutcome>();

  Process? _process;
  Timer? _softTimer;
  Timer? _hardTimer;
  Timer? _killTimer;
  bool _stopped = false;
  bool _hardTimedOut = false;

  final _answers = <String>[];
  String? _threadId;
  String? _failedMessage;
  final _stderrTail = StringBuffer();

  @override
  Stream<TurnUpdate> get updates => _updates.stream;

  @override
  Future<TurnOutcome> get outcome => _outcome.future;

  @override
  void stop() {
    if (_outcome.isCompleted) {
      return;
    }
    _stopped = true;
    if (_process == null) {
      _finish(
        TurnOutcome(
          threadId: _threadId,
          failure: FailureKind.stopped,
          detail: 'stopped by user',
        ),
      );
    } else {
      // Keep the turn active until the child has actually exited. Otherwise a
      // second turn could start during the INT-to-KILL grace period.
      // Codex handles SIGINT as a graceful turn interrupt before shutdown.
      _terminate(ProcessSignal.sigint);
    }
  }

  void _terminate([ProcessSignal signal = ProcessSignal.sigterm]) {
    final p = _process;
    if (p == null) {
      return;
    }
    p.kill(signal);
    _killTimer ??= Timer(_bridge.killGrace, () {
      _process?.kill(ProcessSignal.sigkill);
    });
  }

  Future<void> _runSafely() async {
    try {
      await _run();
    } on Object catch (error) {
      await _terminateAndReap();
      _finish(
        TurnOutcome(
          threadId: _threadId,
          failure: FailureKind.nonZero,
          detail: 'codex bridge failed: $error',
        ),
      );
    }
  }

  Future<void> _terminateAndReap() async {
    final process = _process;
    _terminate();
    if (process == null) {
      return;
    }
    try {
      await process.exitCode.timeout(
        _bridge.killGrace + const Duration(seconds: 1),
      );
      _killTimer?.cancel();
      _killTimer = null;
    } on Object {
      // The SIGKILL escalation has fired; do not strand the caller if the OS
      // still cannot report process exit.
    }
  }

  Future<void> _run() async {
    if (_outcome.isCompleted) {
      return;
    }
    final binary = _bridge.resolveBinary();
    if (binary == null) {
      _finish(
        const TurnOutcome(
          failure: FailureKind.binaryMissing,
          detail: 'no codex binary found',
        ),
      );
      return;
    }
    if (!await _bridge.networkProbe()) {
      _finish(
        const TurnOutcome(
          failure: FailureKind.network,
          detail: 'offline (dns preflight failed)',
        ),
      );
      return;
    }
    if (_outcome.isCompleted) {
      return;
    }
    try {
      _process = await Process.start(
        binary,
        LiveCodexBridge.argsFor(_request),
        workingDirectory: _request.workspace,
        environment: {'NO_COLOR': '1', 'TERM': 'xterm-256color'},
      );
    } on ProcessException catch (e) {
      _finish(
        TurnOutcome(failure: FailureKind.binaryMissing, detail: e.message),
      );
      return;
    }

    final process = _process!;
    final cancelledBeforePrompt = _outcome.isCompleted || _stopped;
    if (!cancelledBeforePrompt) {
      _softTimer = Timer(_bridge.softTimeout, () {
        if (!_outcome.isCompleted) {
          _emit(const TurnStillThinking());
        }
      });
      _hardTimer = Timer(_bridge.hardTimeout, () {
        if (_outcome.isCompleted) {
          return;
        }
        _hardTimedOut = true;
        _terminate();
      });
    }

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(_onLine)
        .catchError((Object _) {});
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(_onStderr)
        .catchError((Object _) {});

    // The final `-` argument explicitly asks Codex to read this turn from
    // stdin. Supplying prompts this way supports arbitrary text without option
    // ambiguity or argv-size/privacy problems. EOF is part of the protocol:
    // Codex waits for it before starting the turn. The output listeners and
    // timers above must already be live so config/auth diagnostics cannot fill
    // a pipe while a large prompt is still being written.
    //
    // Ignore a broken pipe so an early CLI argument/configuration failure can
    // still be classified from its exit code and stderr.
    if (cancelledBeforePrompt) {
      // stop() may win while Process.start is awaiting the OS. Now that the
      // PID exists, close and reap it without ever sending the queued prompt.
      try {
        await process.stdin.close();
      } on Object {
        // The child exited before consuming stdin.
      }
      _terminate(ProcessSignal.sigint);
    } else {
      try {
        process.stdin.write(_request.prompt);
        await process.stdin.close();
      } on Object {
        // The child exited before consuming stdin.
      }
    }

    final exitCode = await process.exitCode;
    _killTimer?.cancel();
    _killTimer = null;
    // Don't block on pipe closure: a surviving grandchild (codex's own
    // spawned command) can hold the fds open long after codex itself dies.
    await Future.wait([
      stdoutDone,
      stderrDone,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    _finish(_classify(exitCode));
  }

  void _onLine(String line) {
    final event = parseCodexEvent(line);
    switch (event) {
      case ThreadStarted(:final threadId):
        _threadId = threadId;
        _emit(TurnThread(threadId));
      case ItemEvent(:final phase, :final item):
        _onItem(phase, item);
      case TurnFailed(:final message):
        _failedMessage = message;
      case StreamError(:final message):
        _failedMessage ??= message;
      case TurnStarted() || TurnCompleted() || UnknownEvent() || null:
        break;
    }
  }

  void _onItem(ItemPhase phase, CodexItem item) {
    switch (item) {
      case AgentMessageItem(:final text):
        if (phase == ItemPhase.completed && text.isNotEmpty) {
          _answers.add(text);
        }
      case ReasoningItem(:final text):
        if (text.isNotEmpty) {
          _activity('thinking', _firstLine(text));
        }
      case CommandExecutionItem(:final command, :final status):
        if (phase == ItemPhase.started ||
            (phase == ItemPhase.completed && status != 'completed')) {
          _activity('command', _firstLine(command));
        }
      case FileChangeItem(:final paths):
        if (phase == ItemPhase.completed && paths.isNotEmpty) {
          _activity('file', paths.join(', '));
        }
      case McpToolCallItem(:final server, :final tool):
        if (phase == ItemPhase.started) {
          _activity('tool', '$server.$tool');
        }
      case CollabToolCallItem(:final tool, :final status):
        if (phase == ItemPhase.started ||
            (phase == ItemPhase.completed && status != 'completed')) {
          _activity('tool', 'collab.$tool');
        }
      case WebSearchItem(:final query):
        if (phase == ItemPhase.started && query.isNotEmpty) {
          _activity('search', query);
        }
      case ErrorItem(:final message):
        _failedMessage ??= message;
      case TodoListItem() || UnknownItem():
        break;
    }
  }

  void _activity(String kind, String label) {
    if (label.isEmpty) {
      return;
    }
    _emit(TurnActivity(ActivityNote(kind: kind, label: label)));
  }

  void _emit(TurnUpdate update) {
    if (!_updates.isClosed) {
      _updates.add(update);
    }
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.length > 96 ? '${line.substring(0, 95)}…' : line;
  }

  void _onStderr(String chunk) {
    _stderrTail.write(chunk);
    final s = _stderrTail.toString();
    if (s.length > 4096) {
      _stderrTail
        ..clear()
        ..write(s.substring(s.length - 4096));
    }
  }

  TurnOutcome _classify(int exitCode) {
    final answer = _answers.isEmpty ? null : _answers.join('\n\n');
    final haystack = '${_failedMessage ?? ''}\n${_stderrTail.toString()}'
        .toLowerCase();
    if (_stopped) {
      return TurnOutcome(
        threadId: _threadId,
        failure: FailureKind.stopped,
        detail: 'stopped by user',
      );
    }
    if (_hardTimedOut) {
      return TurnOutcome(
        threadId: _threadId,
        failure: FailureKind.timeout,
        detail: 'hard timeout',
      );
    }
    if (exitCode == 0 && answer != null) {
      // Codex emits advisory `error` items (e.g. "session was recorded with
      // model X") on successful turns; a delivered answer wins.
      return TurnOutcome(answer: answer, threadId: _threadId);
    }
    const authNeedles = [
      'not logged in',
      'unauthorized',
      '401',
      'please run codex login',
      'no credentials',
      'token expired',
      'login required',
    ];
    const networkNeedles = [
      'dns',
      'connection refused',
      'connection reset',
      'tls handshake',
      'offline',
      'network is unreachable',
      'failed to connect',
      'temporary failure in name resolution',
      'error sending request',
    ];
    const sandboxNeedles = ['landlock', 'seccomp', 'sandbox unavailable'];
    FailureKind kind;
    if (authNeedles.any(haystack.contains)) {
      kind = FailureKind.auth;
    } else if (sandboxNeedles.any(haystack.contains)) {
      kind = FailureKind.sandbox;
    } else if (networkNeedles.any(haystack.contains)) {
      kind = FailureKind.network;
    } else if (exitCode != 0) {
      kind = FailureKind.nonZero;
    } else {
      kind = FailureKind.emptyAnswer;
    }
    return TurnOutcome(
      answer: answer,
      threadId: _threadId,
      failure: kind,
      detail: _failedMessage ?? _stderrTail.toString(),
    );
  }

  void _finish(TurnOutcome outcome) {
    _softTimer?.cancel();
    _hardTimer?.cancel();
    if (!_outcome.isCompleted) {
      _outcome.complete(outcome);
    }
    unawaited(_updates.close());
  }
}
