import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/stable_prefix.dart';

void main() {
  group('StablePrefix', () {
    test('holds a word back until a second decode confirms it', () {
      final stable = StablePrefix();
      // First sighting of every word: nothing has been confirmed yet.
      expect(stable.update('ask not what'), '');
      // "ask not" survived; "what" became "watch", so it is still unsettled.
      expect(stable.update('ask not watch your'), 'ask not');
      expect(stable.update('ask not what your country'), 'ask not');
      expect(
        stable.update('ask not what your country can'),
        'ask not what your country',
      );
    });

    test('never retracts a word it has shown', () {
      final stable = StablePrefix();
      stable.update('the quick brown fox');
      expect(stable.update('the quick brown badger'), 'the quick brown');
      // A later decode disagrees about a committed word. Showing the revision
      // would mean text on screen changing under the reader, which is the
      // whole thing this class exists to prevent — it arrives with the final
      // result instead, which replaces the box wholesale.
      expect(stable.update('the slow brown fox'), 'the quick brown');
      expect(stable.update('a b c'), 'the quick brown');
    });

    test('a shorter decode does not shrink the text', () {
      final stable = StablePrefix();
      stable.update('one two three four');
      expect(stable.update('one two three four'), 'one two three four');
      expect(stable.update('one two'), 'one two three four');
    });

    test('punctuation and case do not block agreement', () {
      final stable = StablePrefix();
      stable.update('ask not what');
      // parakeet re-punctuates the whole clip as it grows, so the same words
      // come back capitalised and comma'd. Treating that as disagreement would
      // stall the prefix at the first comma in every sentence.
      expect(stable.update('Ask not, what you'), 'Ask not, what');
    });

    test('shows the newest spelling of a word it commits', () {
      final stable = StablePrefix();
      stable.update('ask not');
      // Committed on the second decode, so the second decode's spelling is
      // what reaches the screen — the fresher punctuation, not the older.
      expect(stable.update('Ask not,'), 'Ask not,');
    });

    test('agreement: 1 passes every decode straight through', () {
      final stable = StablePrefix(agreement: 1);
      expect(stable.update('ask not'), 'ask not');
      expect(stable.update('ask not what'), 'ask not what');
    });

    test('agreement: 3 needs three consecutive sightings', () {
      final stable = StablePrefix(agreement: 3);
      expect(stable.update('ask not'), '');
      expect(stable.update('ask not what'), '');
      expect(stable.update('ask not what your'), 'ask not');
      expect(stable.update('ask not what your country'), 'ask not what');
    });

    test('reset drops the agreement window', () {
      final stable = StablePrefix();
      stable.update('ask not');
      stable.update('ask not');
      expect(stable.text, 'ask not');
      // Decodes either side of an endpoint are of different audio; carrying
      // agreement across would prepend the last utterance to the next one.
      stable.reset();
      expect(stable.text, '');
      expect(stable.update('ask not'), '');
    });

    test('tolerates empty and whitespace-only decodes', () {
      final stable = StablePrefix();
      expect(stable.update(''), '');
      expect(stable.update('   '), '');
      expect(stable.update('hello'), '');
      expect(stable.update('  hello   world '), 'hello');
    });
  });
}
