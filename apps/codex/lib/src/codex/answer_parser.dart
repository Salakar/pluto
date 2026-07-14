/// The TRANSCRIPTION:/ANSWER: two-section contract used for handwriting
/// turns (paper-codex `codex/parse.rs`). Codex reads the attached page image
/// and replies with both sections; the transcription is context-only.
library;

const int answerCap = 65536;

final class ParsedAnswer {
  const ParsedAnswer({required this.answer, this.transcription});

  final String answer;
  final String? transcription;
}

ParsedAnswer parseAnswerSections(String raw) {
  var text = raw.trim();
  // Strip one outer code fence if the whole reply is fenced.
  if (text.startsWith('```')) {
    final firstNewline = text.indexOf('\n');
    if (firstNewline != -1 && text.endsWith('```')) {
      text = text.substring(firstNewline + 1, text.length - 3).trim();
    }
  }
  final upper = text.toUpperCase();
  final tIdx = upper.indexOf('TRANSCRIPTION:');
  final aIdx = upper.indexOf('ANSWER:');
  String? transcription;
  String answer;
  if (tIdx != -1 && aIdx != -1 && aIdx > tIdx) {
    transcription = text.substring(tIdx + 'TRANSCRIPTION:'.length, aIdx).trim();
    answer = text.substring(aIdx + 'ANSWER:'.length).trim();
  } else if (aIdx != -1) {
    answer = text.substring(aIdx + 'ANSWER:'.length).trim();
  } else {
    answer = text;
  }
  if (answer.length > answerCap) {
    answer = '${answer.substring(0, answerCap)}\n… [truncated]';
  }
  return ParsedAnswer(answer: answer, transcription: transcription);
}

/// The handwriting prompt preamble (paper-codex `invoke.rs::prepare_prompt`).
const String handwritingPrompt =
    'Read the attached handwritten prompt. Reply with exactly these two '
    'sections:\n\nTRANSCRIPTION:\n<the handwritten text, preserving line '
    'breaks>\n\nANSWER:\n<your answer>';
