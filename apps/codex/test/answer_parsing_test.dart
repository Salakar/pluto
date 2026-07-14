import 'package:flutter_test/flutter_test.dart';
import 'package:paper_codex/src/codex/answer_parser.dart';
import 'package:paper_codex/src/paper/answer_markup.dart';

void main() {
  group('parseAnswerSections', () {
    test('splits the two-section handwriting contract', () {
      const raw =
          'TRANSCRIPTION:\nCan we make this feel like paper?\n\n'
          'ANSWER:\nYes - keep the page calm.';
      final parsed = parseAnswerSections(raw);
      expect(parsed.transcription, 'Can we make this feel like paper?');
      expect(parsed.answer, 'Yes - keep the page calm.');
    });

    test('handles answer-only and plain replies', () {
      expect(
        parseAnswerSections('ANSWER:\njust the answer').answer,
        'just the answer',
      );
      final plain = parseAnswerSections('no sections at all');
      expect(plain.answer, 'no sections at all');
      expect(plain.transcription, isNull);
    });

    test('strips a single outer code fence', () {
      const raw = '```\nTRANSCRIPTION:\nhi\n\nANSWER:\nhello\n```';
      final parsed = parseAnswerSections(raw);
      expect(parsed.transcription, 'hi');
      expect(parsed.answer, 'hello');
    });

    test('caps very long answers at a UTF-8-safe boundary', () {
      final big = 'ANSWER:\n${'a' * (answerCap + 500)}';
      final parsed = parseAnswerSections(big);
      expect(parsed.answer.length, lessThan(answerCap + 32));
      expect(parsed.answer, endsWith('[truncated]'));
    });
  });

  group('parseAnswerMarkup', () {
    test('splits prose, todos, code, and bullets', () {
      const answer =
          'A Codex-first tablet should keep the page calm.\n'
          '\n'
          '- [ ] Probe DRM and pen events.\n'
          '- [x] Build fullscreen ink canvas.\n'
          '\n'
          'Then run:\n'
          '```sh\n'
          'cargo test\n'
          '```\n'
          '- plain bullet\n';
      final segments = parseAnswerMarkup(answer);
      expect(segments, hasLength(5));
      expect(segments[0], isA<ProseSegment>());
      final todos = segments[1] as TodoSegment;
      expect(todos.items, hasLength(2));
      expect(todos.items[0].text, 'Probe DRM and pen events.');
      expect(todos.items[1].checked, isTrue);
      expect((segments[2] as ProseSegment).text, 'Then run:');
      final code = segments[3] as CodeSegment;
      expect(code.language, 'sh');
      expect(code.lines, ['cargo test']);
      final bullets = segments[4] as BulletSegment;
      expect(bullets.items, ['plain bullet']);
    });

    test('unclosed fences and empty input degrade gracefully', () {
      final open = parseAnswerMarkup('```\nline1\nline2');
      expect(open.single, isA<CodeSegment>());
      expect((open.single as CodeSegment).lines, ['line1', 'line2']);
      expect(parseAnswerMarkup(''), isEmpty);
      expect(parseAnswerMarkup('   \n \n'), isEmpty);
    });
  });
}
