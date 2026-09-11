import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

void main() {
  group('SeamJoiner', () {
    test('leaves text alone before any commit', () {
      expect(SeamJoiner().trim('we have some news'), 'we have some news');
    });

    test('leaves text alone after a natural endpoint', () {
      final s = SeamJoiner()..commit('hey we have', truncated: false);
      // A repeat here is the speaker repeating themselves, not the pre-roll.
      expect(s.trim('we have some news'), 'we have some news');
    });

    test('drops the pre-roll repeat after a truncated cut', () {
      final s = SeamJoiner()
        ..commit('call and they say hey we have', truncated: true);
      expect(
        s.trim('we have some news Hillary Clinton'),
        'some news Hillary Clinton',
      );
    });

    test('prefers the longest repeat', () {
      final s = SeamJoiner()..commit('you can have a life', truncated: true);
      // "a" alone also matches; stripping only that would leave "have a life".
      expect(s.trim('have a life a social life'), 'a social life');
    });

    test('ignores case and edge punctuation', () {
      final s = SeamJoiner()..commit('to any problem.', truncated: true);
      expect(s.trim('Problem, having snake oil'), 'having snake oil');
    });

    test('keeps text that only happens to start with a similar word', () {
      final s = SeamJoiner()
        ..commit('miracle solutions to any problem', truncated: true);
      expect(
        s.trim('they would be having snake oil'),
        'they would be having snake oil',
      );
    });

    test('arms for exactly one utterance', () {
      final s = SeamJoiner()..commit('hey we have', truncated: true);
      expect(s.trim('we have some news'), 'some news');
      s.commit('some news', truncated: false);
      expect(s.trim('some news again'), 'some news again');
    });

    test('never strips more than maxWords', () {
      final s = SeamJoiner(maxWords: 2)..commit('a b c d', truncated: true);
      expect(s.trim('c d e'), 'e');
      final t = SeamJoiner(maxWords: 2)..commit('a b c d', truncated: true);
      expect(t.trim('b c d e'), 'b c d e');
    });

    test('maxWords 0 disables trimming', () {
      final s = SeamJoiner(maxWords: 0)..commit('we have', truncated: true);
      expect(s.trim('we have some news'), 'we have some news');
    });

    test('handles a decode that is entirely a repeat', () {
      final s = SeamJoiner()..commit('we have', truncated: true);
      expect(s.trim('we have'), '');
    });

    test('reset forgets the pending seam', () {
      final s = SeamJoiner()..commit('we have', truncated: true);
      s.reset();
      expect(s.trim('we have some news'), 'we have some news');
    });
  });
}
