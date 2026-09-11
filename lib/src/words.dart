/// Word splitting and comparison shared by the text-stitching stages.
///
/// Both [StablePrefix] and [SeamJoiner] have to decide whether two decodes
/// produced "the same word", and both need the answer to ignore the things
/// these models rewrite freely between passes.
library;

/// Splits a decode into words on whitespace, dropping empties.
List<String> splitWords(String text) =>
    text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Compares words ignoring case and edge punctuation.
///
/// Without this, agreement would break on every comma. Punctuation and
/// capitalisation are the least stable thing these models emit — parakeet
/// re-punctuates the whole clip on each pass as the sentence grows — and a
/// word whose only change is a trailing comma is not an unsettled word. Callers
/// always render the original spelling, so the freshest punctuation is what
/// reaches the screen either way.
String wordKey(String word) {
  final lower = word.toLowerCase();
  var start = 0;
  var end = lower.length;
  while (start < end && !_isWordChar(lower.codeUnitAt(start))) {
    start++;
  }
  while (end > start && !_isWordChar(lower.codeUnitAt(end - 1))) {
    end--;
  }
  // All punctuation: compare it literally rather than collapsing every such
  // token to the empty string, which would make them all equal.
  if (start == end) return lower;
  return lower.substring(start, end);
}

bool _isWordChar(int c) =>
    (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c > 0x7f;
