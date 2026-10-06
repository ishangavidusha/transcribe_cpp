/// Value types for transcription results.
///
/// Everything here is owned Dart data. transcribe.cpp hands out `const char *`
/// pointers into session-owned storage that die on the next run or feed
/// (see "Result text-pointer lifetime" in `include/transcribe.h`), so the FFI
/// layer copies every string at the boundary and callers get plain immutable
/// objects that outlive the session.
library;

class Segment {
  const Segment({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speakerId = 0,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// 1-based; 0 means the model produced no speaker attribution.
  final int speakerId;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);

  @override
  String toString() => '[$startMs-$endMs] $text';
}

class Word {
  const Word({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.segmentIndex,
  });

  final int startMs;
  final int endMs;
  final String text;
  final int segmentIndex;

  @override
  String toString() => '[$startMs-$endMs] $text';
}

class Token {
  const Token({
    required this.id,
    required this.probability,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int id;

  /// Per-token confidence hint, or NaN when the architecture has none.
  /// The meaning varies by family — joint softmax for transducers, per-step
  /// softmax for autoregressive decoders, per-frame argmax for CTC — so treat
  /// it as a hint, not a calibrated probability.
  final double probability;

  final int startMs;
  final int endMs;

  /// The token's text. Byte-level tokenizers can split one character across
  /// tokens, so a token may begin or end with U+FFFD where it holds only part
  /// of a character. Joined text is in [Word.text] and [Transcript.text].
  final String text;
}

/// A complete result snapshot, fully copied out of the session.
class Transcript {
  const Transcript({
    required this.text,
    required this.segments,
    required this.words,
    required this.tokens,
    this.detectedLanguage,
    this.wasTruncated = false,
    this.wasAborted = false,
  });

  /// The cleaned transcript (`transcribe_full_text`).
  final String text;

  final List<Segment> segments;
  final List<Word> words;
  final List<Token> tokens;

  /// BCP-47-ish code the model reported, when the family detects language.
  final String? detectedLanguage;

  /// The decode hit the model's output budget; [text] is incomplete.
  final bool wasTruncated;

  /// The run was cancelled; [text] holds whatever completed first.
  final bool wasAborted;

  bool get isEmpty => text.isEmpty;

  @override
  String toString() => text;
}

/// The UI-facing view of an in-flight stream (`transcribe_stream_get_text`).
class StreamText {
  const StreamText({
    required this.full,
    required this.committed,
    required this.tentative,
  });

  /// The authoritative raw hypothesis. May rewrite anywhere while the stream
  /// is active.
  final String full;

  /// Append-only display prefix. Never rewritten once exposed.
  ///
  /// Note the tradeoff the engine documents: for models that re-attend over a
  /// growing audio context (moonshine_streaming is one), the raw hypothesis
  /// can revise a byte that was already committed. Because this is append-only
  /// it is not rolled back, so mid-stream `committed + tentative` may not
  /// reconstruct [full]. Render [full] if you need exact truth; render
  /// [display] if you want flicker-free text.
  final String committed;

  /// The volatile suffix after the committed boundary.
  final String tentative;

  String get display => committed + tentative;

  @override
  String toString() => display;
}

/// Per-call change metadata from feed/finalize (`transcribe_stream_update`).
class StreamUpdate {
  const StreamUpdate({
    required this.resultChanged,
    required this.isFinal,
    required this.revision,
    required this.inputReceivedMs,
    required this.audioCommittedMs,
    required this.bufferedMs,
    required this.committedChanged,
    required this.tentativeChanged,
  });

  final bool resultChanged;
  final bool isFinal;

  /// Monotonic snapshot counter. Diff it against the previous value rather
  /// than treating every bump as "text changed".
  final int revision;

  final int inputReceivedMs;
  final int audioCommittedMs;

  /// Audio still held inside the family's streaming state (frontend carry plus
  /// lookahead). Useful as a drain hint.
  final int bufferedMs;

  final bool committedChanged;
  final bool tentativeChanged;
}

/// Static facts about a loaded model.
///
/// [backend] is the one to check first on a real device: `MTL0` means the
/// Metal slice is live, `CPU0` means the build quietly fell back to CPU and
/// every performance number is off by an order of magnitude.
class ModelInfo {
  const ModelInfo({
    required this.backend,
    required this.architecture,
    required this.variant,
  });

  final String backend;
  final String architecture;
  final String variant;

  bool get isGpu => !backend.toUpperCase().startsWith('CPU');

  @override
  String toString() => '$variant ($architecture) on $backend';
}
