/// Light markdown-ish parsing of Codex answers into paper-native segments:
/// prose, todo lists (`- [ ]` / `- [x]`), bullets, and fenced code blocks.
/// Anything unrecognised stays prose — the page never fails to render.
library;

sealed class AnswerSegment {
  const AnswerSegment();
}

final class ProseSegment extends AnswerSegment {
  const ProseSegment(this.text);

  final String text;
}

final class TodoSegment extends AnswerSegment {
  const TodoSegment(this.items);

  final List<({String text, bool checked})> items;
}

final class BulletSegment extends AnswerSegment {
  const BulletSegment(this.items);

  final List<String> items;
}

final class CodeSegment extends AnswerSegment {
  const CodeSegment(this.lines, {this.language = ''});

  final List<String> lines;
  final String language;
}

final _todoRe = RegExp(r'^\s*[-*]\s*\[( |x|X)\]\s+(.*)$');
final _bulletRe = RegExp(r'^\s*[-*]\s+(.*)$');
final _fenceRe = RegExp(r'^\s*```(.*)$');

List<AnswerSegment> parseAnswerMarkup(String answer) {
  final segments = <AnswerSegment>[];
  final prose = StringBuffer();
  var todos = <({String text, bool checked})>[];
  var bullets = <String>[];

  void flushProse() {
    final text = prose.toString().trim();
    if (text.isNotEmpty) {
      segments.add(ProseSegment(text));
    }
    prose.clear();
  }

  void flushTodos() {
    if (todos.isNotEmpty) {
      segments.add(TodoSegment(todos));
      todos = [];
    }
  }

  void flushBullets() {
    if (bullets.isNotEmpty) {
      segments.add(BulletSegment(bullets));
      bullets = [];
    }
  }

  void flushAll() {
    flushProse();
    flushTodos();
    flushBullets();
  }

  final lines = answer.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fenceRe.firstMatch(line);
    if (fence != null) {
      flushAll();
      final language = fence.group(1)!.trim();
      final code = <String>[];
      i += 1;
      while (i < lines.length && _fenceRe.firstMatch(lines[i]) == null) {
        code.add(lines[i]);
        i += 1;
      }
      i += 1; // skip closing fence (or run off the end)
      segments.add(CodeSegment(code, language: language));
      continue;
    }
    final todo = _todoRe.firstMatch(line);
    if (todo != null) {
      flushProse();
      flushBullets();
      todos.add((
        text: todo.group(2)!.trim(),
        checked: todo.group(1)!.toLowerCase() == 'x',
      ));
      i += 1;
      continue;
    }
    final bullet = _bulletRe.firstMatch(line);
    if (bullet != null) {
      flushProse();
      flushTodos();
      bullets.add(bullet.group(1)!.trim());
      i += 1;
      continue;
    }
    if (line.trim().isEmpty) {
      flushAll();
    } else {
      flushTodos();
      flushBullets();
      if (prose.isNotEmpty) {
        prose.write('\n');
      }
      prose.write(line.trim());
    }
    i += 1;
  }
  flushAll();
  return segments;
}
