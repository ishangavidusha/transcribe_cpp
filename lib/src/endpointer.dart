import 'dart:math' as math;
import 'dart:typed_data';

import 'vad.dart';

/// Tuning for [Endpointer].
///
/// The defaults are the ones to start from, not placeholders: they follow
/// Silero's own reference `VADIterator` where it has an opinion, and are
/// otherwise chosen for dictation on a phone. Every duration is rounded up to a
/// whole 32 ms window internally, so values below that granularity are
/// indistinguishable.
class EndpointerConfig {
  const EndpointerConfig({
    this.speechThreshold = 0.5,
    this.silenceThreshold = 0.35,
    this.minSpeechDuration = const Duration(milliseconds: 250),
    this.reattachWithin = const Duration(milliseconds: 400),
    this.hangover = const Duration(milliseconds: 400),
    this.preRoll = const Duration(milliseconds: 300),
    this.postRoll = const Duration(milliseconds: 250),
    this.maxUtterance = const Duration(seconds: 20),
  });

  /// Probability at or above which a window opens an utterance.
  final double speechThreshold;

  /// Probability below which a window counts toward the [hangover].
  ///
  /// Deliberately lower than [speechThreshold]: a single threshold makes the
  /// detector chatter on and off through the natural dips inside a word. This
  /// gap is the hysteresis, and 0.15 below onset is what Silero's own iterator
  /// uses.
  final double silenceThreshold;

  /// How long speech must persist before it is treated as real.
  ///
  /// Filters coughs, door clicks, and keyboard taps, which Silero scores
  /// confidently but briefly. Bursts shorter than this are never handed to the
  /// model; they are reported as [SpeechDiscarded] so the loss can be counted
  /// rather than guessed at.
  ///
  /// The floor cannot separate a click from a short word on its own, and for
  /// dictation the words said alone — "yes", "no", "stop", "undo" — are exactly
  /// the short ones. [reattachWithin] removes the common half of that problem;
  /// a genuinely isolated short word is still at risk, and lowering this is a
  /// measurement, not a guess. Count the [SpeechDiscarded] events on a real
  /// session first.
  final Duration minSpeechDuration;

  /// How soon after an utterance's audio ends a new burst counts as the same
  /// turn, and so skips [minSpeechDuration].
  ///
  /// [minSpeechDuration] is a prior about an idle room: the best explanation
  /// for a short confident burst out of nowhere is a cough or a key press.
  /// Directly after an utterance that prior is simply wrong. Someone
  /// demonstrably just spoke, and the likeliest explanation for a burst
  /// arriving on its heels is that the [hangover] cut their turn a word early.
  ///
  /// Which is what the shorter hangover made common. jfk.wav ends on 64 ms of
  /// speech that sits 320 ms after the previous *speech window* but only 64 ms
  /// after the previous utterance's *emitted audio*, because [postRoll] had
  /// already carried that utterance most of the way to it. Measured from the
  /// emission — where the audio actually stopped — the gap is tiny and the
  /// continuation is obvious. Measured from the last speech window it looks
  /// like a fresh event, which is why the floor threw it away.
  ///
  /// The trade is asymmetric on purpose. A cough within this long of your own
  /// speech now reaches the model, where it decodes to nothing or to a filler
  /// the transcript absorbs. A dropped "no" cannot be recovered by anything
  /// downstream, because nothing downstream ever sees it.
  ///
  /// Re-attachment chains: a burst kept this way becomes the emission the next
  /// one is measured against, so "yes. no. stop." all survive. The chain is
  /// bounded by the rule itself — one silence longer than this ends it.
  ///
  /// [Duration.zero] disables re-attachment and judges every burst alone.
  final Duration reattachWithin;

  /// Continuous silence required to declare the utterance finished.
  ///
  /// This is the dominant term in perceived latency — the user has stopped
  /// talking and is waiting out this timer before decode even begins. It is
  /// also what protects mid-sentence pauses from being cut in half.
  ///
  /// 400 ms. It was briefly 250 ms, on the strength of a podcast replay that
  /// scored 250 / 400 / 700 ms at 3.74 / 3.80 / 4.35% WER with parakeet — but
  /// on a paired test that recording cannot tell any of those apart (p >= 0.3),
  /// so it never supported the change it was used for.
  ///
  /// Real conversation can. A 31-minute two-person visit, replayed at
  /// 250 / 400 / 700 ms and scored against a full reference: 8.51 / 7.93 /
  /// 7.83% WER. 250 ms costs 28 errors against 400 ms, p = 0.005 on a paired
  /// block bootstrap; 400 and 700 ms are tied (p = 0.76).
  ///
  /// The mechanism is fragmentation. People pause mid-sentence in
  /// conversation, and 250 ms treats those pauses as endings: it made 181 cuts
  /// that 400 ms did not, 17 of its 28 extra errors sat within four words of
  /// them, and it produced 128 utterances under 1.5 s against 53. Each fragment
  /// is decoded without the words around it.
  ///
  /// The cost of going longer is [maxUtterance]. A longer hangover builds
  /// longer utterances, those hit the cap, and a truncated seam is the most
  /// error-prone place in a transcript: 0 / 3 / 24 truncations at 250 / 400 /
  /// 700 ms on the same conversation. 700 ms buys no accuracy for that and
  /// makes the user wait 300 ms longer on every turn. 400 ms is where the
  /// fragmentation stops paying and the truncations have not started.
  final Duration hangover;

  /// Audio retained from *before* the onset window.
  ///
  /// Silero fires a window or two into the first phoneme, so a cut at the exact
  /// onset reliably clips soft leading consonants — "sixty" arrives as "ixty".
  /// This is pure insurance; the audio is silence when it is not needed.
  final Duration preRoll;

  /// Audio retained *after* the last speech window, out of the [hangover].
  final Duration postRoll;

  /// Hard cap on one utterance.
  ///
  /// Someone reading a paragraph aloud may never pause long enough to endpoint.
  /// Without a cap, latency grows without bound and the eventual decode is a
  /// single unbroken wall of text. At the cap the audio is cut and emitted with
  /// [Utterance.truncated] set, and the next chunk continues from [preRoll]
  /// before the cut so a word straddling the boundary survives in one of them.
  final Duration maxUtterance;

  EndpointerConfig copyWith({
    double? speechThreshold,
    double? silenceThreshold,
    Duration? minSpeechDuration,
    Duration? reattachWithin,
    Duration? hangover,
    Duration? preRoll,
    Duration? postRoll,
    Duration? maxUtterance,
  }) {
    return EndpointerConfig(
      speechThreshold: speechThreshold ?? this.speechThreshold,
      silenceThreshold: silenceThreshold ?? this.silenceThreshold,
      minSpeechDuration: minSpeechDuration ?? this.minSpeechDuration,
      reattachWithin: reattachWithin ?? this.reattachWithin,
      hangover: hangover ?? this.hangover,
      preRoll: preRoll ?? this.preRoll,
      postRoll: postRoll ?? this.postRoll,
      maxUtterance: maxUtterance ?? this.maxUtterance,
    );
  }
}

/// One endpointed span of audio, ready to hand to `Transcriber.transcribe`.
class Utterance {
  const Utterance({
    required this.audio,
    required this.start,
    required this.end,
    required this.speechStart,
    required this.speechEnd,
    required this.truncated,
  });

  /// Mono float32 at [vadSampleRate], padding included.
  final Float32List audio;

  /// Stream-relative position of [audio]'s first sample (includes pre-roll).
  final Duration start;

  /// Stream-relative position just past [audio]'s last sample.
  final Duration end;

  /// Where speech actually began, i.e. [start] plus the pre-roll that was
  /// available. Use this for display timing; use [start] for audio maths.
  final Duration speechStart;

  /// End of the last window that scored as speech.
  final Duration speechEnd;

  /// True when [EndpointerConfig.maxUtterance] cut this short — the speaker had
  /// not finished, and the next utterance continues them.
  final bool truncated;

  Duration get duration => end - start;

  @override
  String toString() =>
      'Utterance(${start.inMilliseconds}–${end.inMilliseconds} ms, '
      '${audio.length} samples${truncated ? ', truncated' : ''})';
}

/// Something the [Endpointer] observed. Times are stream-relative.
sealed class EndpointerEvent {
  const EndpointerEvent(this.at);
  final Duration at;
}

/// Speech has been confirmed — it survived [EndpointerConfig.minSpeechDuration].
///
/// Arrives roughly [EndpointerConfig.minSpeechDuration] after the audio it
/// points at, because that is how long confirmation takes. Useful for ducking
/// other audio or driving a "speaking" indicator; the audio itself comes later.
class SpeechStarted extends EndpointerEvent {
  const SpeechStarted(super.at);

  @override
  String toString() => 'SpeechStarted(${at.inMilliseconds} ms)';
}

/// An utterance closed and its audio is ready.
class SpeechEnded extends EndpointerEvent {
  const SpeechEnded(super.at, this.utterance);
  final Utterance utterance;

  @override
  String toString() => 'SpeechEnded(${at.inMilliseconds} ms, $utterance)';
}

/// A burst of speech was thrown away for not clearing
/// [EndpointerConfig.minSpeechDuration].
///
/// The duration floor is a guess about what the audio was, and it is wrong some
/// of the time. This event exists so that being wrong is at least *visible*:
/// without it the audio simply never arrives, and nothing downstream can tell a
/// filtered cough from a lost "yes" — the two look identical, which is to say
/// they look like nothing at all.
///
/// It carries [peakProbability] because that is the first axis anyone tempted
/// to lower the floor will reach for. Silero scores transients confidently, so
/// a high peak is not by itself evidence of speech; logging these against a
/// real session is how you find out whether it separates them on *your* audio
/// instead of assuming it does.
///
/// The audio is deliberately not attached. This reports a loss; it is not a
/// second delivery path. A product that wants short bursts decoded should widen
/// the confirmation rule — [EndpointerConfig.reattachWithin], or a lower
/// [EndpointerConfig.minSpeechDuration] — so they arrive as ordinary
/// utterances, rather than growing a parallel pipeline out of an error report.
class SpeechDiscarded extends EndpointerEvent {
  const SpeechDiscarded(
    super.at, {
    required this.speechStart,
    required this.speechEnd,
    required this.peakProbability,
  });

  /// Where the burst's first speech window began.
  final Duration speechStart;

  /// Just past its last speech window.
  final Duration speechEnd;

  /// Highest probability any window in the burst scored.
  final double peakProbability;

  /// How long the burst ran — always under
  /// [EndpointerConfig.minSpeechDuration], or it would have been kept.
  Duration get duration => speechEnd - speechStart;

  @override
  String toString() =>
      'SpeechDiscarded(${at.inMilliseconds} ms, '
      '${duration.inMilliseconds} ms burst at '
      '${speechStart.inMilliseconds} ms, '
      'peak ${peakProbability.toStringAsFixed(2)})';
}

/// Turns a stream of audio into utterances by watching a [VadModel].
///
/// Feed it mono float32 at [vadSampleRate] in any chunk size — buffering to the
/// VAD's fixed 512-sample window is handled here — and it returns the events
/// that chunk produced. Synchronous and isolate-agnostic on purpose: the VAD
/// costs well under 1% of a core, so it belongs inline with capture rather than
/// behind another hop.
///
/// The state machine is: silence → (onset) → provisional speech → (survives
/// [EndpointerConfig.minSpeechDuration]) → confirmed speech → (silence lasts
/// [EndpointerConfig.hangover]) → emit → silence. Provisional speech that dies
/// early is discarded, so a cough never reaches the model, but it reports a
/// [SpeechDiscarded] on the way out so the loss is countable rather than
/// silent.
///
/// One shortcut through that machine: a burst opening within
/// [EndpointerConfig.reattachWithin] of the previous utterance's audio is
/// confirmed at onset and skips the provisional stage, because it is a
/// continuation of a turn already in progress rather than a fresh event to be
/// judged on its own.
class Endpointer {
  Endpointer(this._vad, {this.config = const EndpointerConfig()});

  final VadModel _vad;
  final EndpointerConfig config;

  late final int _minSpeechWindows = _windowsFor(config.minSpeechDuration);
  late final int _reattachWindows = _windowsFor(config.reattachWithin);
  late final int _hangoverWindows = math.max(1, _windowsFor(config.hangover));
  late final int _preRollWindows = _windowsFor(config.preRoll);
  late final int _postRollWindows = _windowsFor(config.postRoll);
  late final int _maxWindows = math.max(1, _windowsFor(config.maxUtterance));

  /// Retained audio, one entry per whole window. The front is trimmed to
  /// [_preRollWindows] while idle, and left to grow once speech opens.
  final List<Float32List> _retained = <Float32List>[];

  /// Global index of the window at the front of [_retained].
  int _retainedFrom = 0;

  /// Samples handed in that have not yet completed a window.
  final List<double> _partial = <double>[];

  /// Windows fed to the VAD so far — the stream clock.
  int _windowCount = 0;

  bool _speaking = false;
  bool _confirmed = false;
  int _speechStartWindow = 0;
  int _lastSpeechWindow = 0;
  int _silenceRun = 0;

  /// Window index just past the audio of the last naturally-closed utterance,
  /// or -1 when nothing has been emitted since the last [reset].
  ///
  /// The reference point for [EndpointerConfig.reattachWithin]. It is the end
  /// of the *emitted audio*, not of the last speech window, because that is the
  /// gap a listener would actually perceive — [EndpointerConfig.postRoll] has
  /// already been spent by the time it starts.
  int _lastEmissionEnd = -1;

  /// Highest probability seen in the burst currently open. Only ever read for a
  /// burst that gets discarded, where it is the one piece of evidence about
  /// what was thrown away.
  double _burstPeak = 0;

  double _lastProbability = 0;

  /// Probability of the most recent window. Handy for a level/confidence
  /// indicator; it carries no state, so reading it is free and optional.
  double get lastProbability => _lastProbability;

  /// True once speech has been confirmed and until the utterance closes.
  bool get isSpeaking => _speaking && _confirmed;

  /// Audio consumed since the last [reset], including any partial window.
  Duration get position =>
      _durationOfSamples(_windowCount * vadWindowSamples + _partial.length);

  /// A snapshot of the utterance in progress, or null when no confirmed speech
  /// is open.
  ///
  /// This is what makes live text possible without a streaming model. The
  /// endpointer already holds every sample since the onset, so a caller can
  /// decode that prefix repeatedly while the speaker keeps going and show the
  /// result as provisional, rather than waiting out the hangover to see
  /// anything at all.
  ///
  /// Returns a copy: the endpointer keeps accumulating into its own buffers,
  /// and the snapshot is about to cross an isolate boundary.
  ///
  /// Expect the last word or two to be unstable — the audio ends mid-utterance
  /// and often mid-word, so the model has no right context for the tail. Treat
  /// it as provisional and replace it, never append it.
  Float32List? pendingAudio() {
    if (!_speaking || !_confirmed) return null;
    final windows = _retained.length;
    final total = windows * vadWindowSamples + _partial.length;
    if (total == 0) return null;

    final audio = Float32List(total);
    for (var i = 0; i < windows; i++) {
      audio.setRange(
        i * vadWindowSamples,
        (i + 1) * vadWindowSamples,
        _retained[i],
      );
    }
    for (var i = 0; i < _partial.length; i++) {
      audio[windows * vadWindowSamples + i] = _partial[i];
    }
    return audio;
  }

  /// Stream position where [pendingAudio] begins, or null when nothing is open.
  Duration? get pendingStart =>
      _speaking && _confirmed ? _startOfWindow(_retainedFrom) : null;

  /// Feeds [samples] and returns the events they produced.
  ///
  /// Chunk size is free — a chunk smaller than one window produces no events
  /// and is carried forward, and a large chunk may produce several.
  List<EndpointerEvent> add(Float32List samples) {
    final events = <EndpointerEvent>[];
    var offset = 0;

    // Drain whatever is left over from the previous call first, topping it up
    // to a whole window from the head of this one.
    if (_partial.isNotEmpty) {
      final need = vadWindowSamples - _partial.length;
      final take = math.min(need, samples.length);
      for (var i = 0; i < take; i++) {
        _partial.add(samples[i]);
      }
      offset = take;
      if (_partial.length < vadWindowSamples) return events;
      _step(Float32List.fromList(_partial), events);
      _partial.clear();
    }

    while (offset + vadWindowSamples <= samples.length) {
      _step(
        Float32List.sublistView(samples, offset, offset + vadWindowSamples),
        events,
      );
      offset += vadWindowSamples;
    }

    for (var i = offset; i < samples.length; i++) {
      _partial.add(samples[i]);
    }
    return events;
  }

  /// Closes the stream: emits a confirmed utterance still in progress, then
  /// clears state.
  ///
  /// Call this when capture stops. Without it, the audio a user was still
  /// speaking when they released the button is silently dropped — the hangover
  /// that would have closed the utterance never arrives.
  List<EndpointerEvent> flush() {
    final events = <EndpointerEvent>[];
    if (_speaking) {
      // End of stream is not evidence about what the burst was: a cough on the
      // last window is still a cough. So the floor applies here exactly as it
      // does mid-stream, and an unconfirmed burst is reported rather than
      // vanishing into the reset below.
      events.add(
        _confirmed
            ? SpeechEnded(
                position,
                _cut(
                  through: _windowCount - 1,
                  truncated: false,
                  includePartial: true,
                ),
              )
            : _discardedBurst(position),
      );
    }
    reset();
    return events;
  }

  /// Drops all audio and state, including the VAD's, and restarts the clock.
  void reset() {
    _vad.reset();
    _retained.clear();
    _partial.clear();
    _retainedFrom = 0;
    _windowCount = 0;
    _speaking = false;
    _confirmed = false;
    _speechStartWindow = 0;
    _lastSpeechWindow = 0;
    _silenceRun = 0;
    _lastEmissionEnd = -1;
    _burstPeak = 0;
    _lastProbability = 0;
  }

  void _step(Float32List window, List<EndpointerEvent> events) {
    final index = _windowCount++;
    final p = _vad.process(window, offset: 0);
    _lastProbability = p;

    // Copy: the caller's buffer is theirs to reuse, and sublistView shares it.
    _retained.add(Float32List.fromList(window));

    if (!_speaking) {
      if (p >= config.speechThreshold) {
        _speaking = true;
        _speechStartWindow = index;
        _lastSpeechWindow = index;
        _silenceRun = 0;
        _burstPeak = p;
        // A burst landing on the heels of the last utterance is the rest of
        // that turn, not a new event needing proof. Confirm it now, so a word
        // the hangover cut off does not then fail the duration floor as well.
        _confirmed =
            config.reattachWithin > Duration.zero &&
            _lastEmissionEnd >= 0 &&
            index - _lastEmissionEnd <= _reattachWindows;
        if (_confirmed) events.add(SpeechStarted(_startOfWindow(index)));
        _trimFrontTo(index - _preRollWindows);
      } else {
        _trimFrontTo(index + 1 - _preRollWindows);
      }
      return;
    }

    if (p > _burstPeak) _burstPeak = p;

    if (p >= config.silenceThreshold) {
      _lastSpeechWindow = index;
      _silenceRun = 0;
    } else {
      _silenceRun++;
    }

    if (!_confirmed &&
        _lastSpeechWindow - _speechStartWindow + 1 >= _minSpeechWindows) {
      _confirmed = true;
      events.add(SpeechStarted(_startOfWindow(_speechStartWindow)));
    }

    if (_silenceRun >= _hangoverWindows) {
      // Keep the last pre-roll of windows for whatever speaks next, but never
      // reach back past what was just emitted: overlapping a natural endpoint
      // would feed the tail of this utterance into the head of the next one and
      // transcribe it twice.
      var keepFrom = index + 1 - _preRollWindows;
      if (_confirmed) {
        final through = math.min(_lastSpeechWindow + _postRollWindows, index);
        events.add(
          SpeechEnded(
            _startOfWindow(index + 1),
            _cut(through: through, truncated: false, includePartial: false),
          ),
        );
        keepFrom = math.max(keepFrom, through + 1);
        _lastEmissionEnd = through + 1;
      } else {
        // A blip that never became speech. It still does not reach the model —
        // but it is reported, because "the endpointer dropped 40 bursts this
        // session" and "the user said nothing" are very different facts and
        // used to look the same from outside.
        events.add(_discardedBurst(_startOfWindow(index + 1)));
      }
      _speaking = false;
      _confirmed = false;
      _silenceRun = 0;
      _trimFrontTo(keepFrom);
      return;
    }

    if (index - _speechStartWindow + 1 >= _maxWindows) {
      if (!_confirmed) {
        // Long enough to hit the cap but never long enough to confirm is
        // impossible unless minSpeechDuration exceeds maxUtterance. Confirm so
        // the audio is not thrown away.
        _confirmed = true;
        events.add(SpeechStarted(_startOfWindow(_speechStartWindow)));
      }
      events.add(
        SpeechEnded(
          _startOfWindow(index + 1),
          _cut(through: index, truncated: true, includePartial: false),
        ),
      );
      // Carry the pre-roll forward as overlap so a word sitting on the cut
      // survives intact in the next chunk.
      final resume = index + 1 - _preRollWindows;
      _trimFrontTo(resume);
      _speechStartWindow = math.max(resume, 0);
      _lastSpeechWindow = index;
    }
  }

  /// Reports the burst currently open as lost. Mirrors [_cut]'s timing fields
  /// so a discarded burst and a kept one can be compared directly in a log.
  SpeechDiscarded _discardedBurst(Duration at) => SpeechDiscarded(
    at,
    speechStart: _startOfWindow(_speechStartWindow),
    speechEnd: _startOfWindow(_lastSpeechWindow + 1),
    peakProbability: _burstPeak,
  );

  /// Builds an utterance from the retained windows up to and including
  /// [through]. Does not drop them — the caller decides how far back to keep,
  /// since a truncated cut deliberately overlaps and a natural one must not.
  Utterance _cut({
    required int through,
    required bool truncated,
    required bool includePartial,
  }) {
    final first = _retainedFrom;
    final count = math.max(0, through - first + 1);
    final tail = includePartial ? _partial.length : 0;

    final audio = Float32List(count * vadWindowSamples + tail);
    for (var i = 0; i < count; i++) {
      audio.setRange(
        i * vadWindowSamples,
        (i + 1) * vadWindowSamples,
        _retained[i],
      );
    }
    for (var i = 0; i < tail; i++) {
      audio[count * vadWindowSamples + i] = _partial[i];
    }

    return Utterance(
      audio: audio,
      start: _startOfWindow(first),
      end: _durationOfSamples(
        first * vadWindowSamples + count * vadWindowSamples + tail,
      ),
      speechStart: _startOfWindow(_speechStartWindow),
      speechEnd: _startOfWindow(_lastSpeechWindow + 1),
      truncated: truncated,
    );
  }

  /// Drops retained windows before [target], which may be negative or ahead of
  /// what is retained; both are clamped.
  void _trimFrontTo(int target) {
    final drop = math.min(
      math.max(0, target - _retainedFrom),
      _retained.length,
    );
    if (drop == 0) return;
    _retained.removeRange(0, drop);
    _retainedFrom += drop;
  }

  Duration _startOfWindow(int index) =>
      _durationOfSamples(index * vadWindowSamples);

  static Duration _durationOfSamples(int samples) =>
      Duration(microseconds: samples * 1000000 ~/ vadSampleRate);

  static int _windowsFor(Duration d) {
    final samples = d.inMicroseconds * vadSampleRate / 1000000;
    return (samples / vadWindowSamples).ceil();
  }
}
