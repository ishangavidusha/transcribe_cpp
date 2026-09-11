import 'words.dart';

/// Turns a sequence of provisional decodes into text that only ever grows.
///
/// Live text here is repeated re-decoding of a growing clip, not token-by-token
/// streaming, so every pass is free to disagree with the last one — and it
/// does, most often about the final word or two, where the audio stops
/// mid-utterance and the model has no right context. Rendered directly that
/// reads as flicker: words appear, change, and change back several times a
/// second.
///
/// The fix is the standard one from streaming ASR, usually called
/// LocalAgreement-n: hold a word back until [agreement] consecutive decodes
/// have produced it in the same position, and show only the prefix that has
/// cleared that bar. Agreement is cheap evidence that a word is settled — the
/// unstable tail is precisely the part successive decodes disagree about — so
/// the displayed text stops rewriting itself and simply extends.
///
/// The cost is one interval of latency: a word is shown on the second decode
/// that contains it, not the first. That is the trade being made, and it is the
/// right way round — a word that appears 350 ms later is barely noticeable,
/// while a word that appears and then changes is the thing that reads as
/// broken.
class StablePrefix {
  StablePrefix({this.agreement = 2})
    : assert(agreement >= 1, 'agreement must be at least 1');

  /// Consecutive decodes that must contain a word before it is shown.
  ///
  /// 1 disables the rule and shows every decode raw. 2 is the useful setting.
  /// 3 is noticeably steadier on a model that thrashes, at another interval of
  /// latency.
  final int agreement;

  /// Word lists from the previous [agreement] - 1 decodes, oldest first.
  final List<List<String>> _history = <List<String>>[];

  /// What has been committed, and will never be retracted.
  List<String> _committed = const <String>[];

  /// The stable text as of the last [update].
  String get text => _committed.join(' ');

  /// Folds one provisional decode in and returns the text safe to display.
  ///
  /// Monotone by construction: the result of this call always starts with the
  /// result of the previous one. If a later decode revises a word that was
  /// already committed, the revision is ignored here and arrives with the final
  /// result, which replaces this text wholesale.
  String update(String decode) {
    final words = splitWords(decode);

    // Nothing is agreed until there are enough decodes to agree. The guard
    // matters on the first snapshot of every utterance, where an empty history
    // would otherwise make the whole decode look unanimous.
    if (_history.length >= agreement - 1) {
      var stable = words.length;
      for (final previous in _history) {
        stable = _commonPrefix(words, previous, stable);
      }
      if (stable > _committed.length) {
        _committed = List<String>.unmodifiable(words.sublist(0, stable));
      }
    }

    _history.add(words);
    if (_history.length >= agreement) _history.removeAt(0);
    return text;
  }

  /// Forgets everything. Call between utterances — the decodes either side of
  /// an endpoint are of different audio and have no reason to agree.
  void reset() {
    _history.clear();
    _committed = const <String>[];
  }

  /// Length of the common prefix of [a] and [b], never exceeding [limit].
  static int _commonPrefix(List<String> a, List<String> b, int limit) {
    final end = limit < b.length ? limit : b.length;
    var i = 0;
    while (i < end && wordKey(a[i]) == wordKey(b[i])) {
      i++;
    }
    return i;
  }
}
