import 'dart:async';
import 'dart:typed_data';

import 'endpointer.dart';
import 'seam.dart';
import 'stable_prefix.dart';
import 'transcript.dart';

/// The decode step a [VoicePipeline] drives.
///
/// [Transcriber] is the real implementation. The interface exists so the
/// pipeline's plumbing — ordering, delivery, flush — can be tested without a
/// model on disk, for the same reason [VadModel] exists for the endpointer.
abstract interface class UtteranceDecoder {
  Future<Transcript> transcribe(Float32List pcm);
}

/// A transcript for one endpointed utterance, with the timing that produced it.
class UtteranceResult {
  const UtteranceResult({
    required this.utterance,
    required this.transcript,
    this.isFinal = true,
    this.decode = Duration.zero,
    String? stableText,
    String? joinedText,
  }) : _agreed = stableText,
       _joined = joinedText;

  final Utterance utterance;
  final Transcript transcript;

  /// Wall time the decode took.
  ///
  /// Reported rather than inferred because it is the number that decides
  /// whether live text can keep up: once a decode costs more than the
  /// provisional interval, snapshots start being dropped and updates thin out.
  /// Compare it with [Utterance.duration] for a realtime factor.
  final Duration decode;

  /// Named for what it holds rather than for the getter, because Dart has no
  /// private named parameters: `this._agreed` as an initializing formal would
  /// force callers to write `_agreed:`, which does not compile.
  final String? _agreed;

  /// Words [SeamJoiner] removed from the head of this decode, or null when it
  /// left the decode alone. [transcript] keeps the raw text either way.
  final String? _joined;

  /// The full decode, including the part still liable to change.
  ///
  /// Not always `transcript.text`: after a truncated utterance the pre-roll
  /// overlap makes the first word or two a repeat of the previous result, and
  /// [SeamJoiner] drops them here so consumers can concatenate results without
  /// stuttering at the seam.
  String get text => _joined ?? transcript.text;

  /// The part of [text] that consecutive decodes have agreed on.
  ///
  /// This is what live UI should render. It only ever grows within an
  /// utterance, so text on screen extends rather than rewriting itself; [text]
  /// is a word or two ahead of it and flickers. For a final result the two are
  /// the same — nothing further is coming to disagree with it.
  ///
  /// See [StablePrefix] for why agreement is the right test.
  String get stableText => _agreed ?? transcript.text;

  /// False for a provisional decode of speech still in progress.
  ///
  /// Provisional results for one utterance supersede each other and are then
  /// superseded by the final one, so a UI must **replace** the previous
  /// provisional text rather than append to it. The tail of a provisional
  /// result is the least reliable part: the audio stops mid-utterance, so the
  /// model has no right context for the last word or two.
  final bool isFinal;

  /// Where this utterance sat in the stream. Adding [Segment.startMs] to
  /// [Utterance.start] gives absolute positions, since the engine timestamps
  /// relative to the clip it was handed.
  Duration get start => utterance.start;

  @override
  String toString() =>
      'UtteranceResult(${start.inMilliseconds} ms'
      '${isFinal ? '' : ', provisional'}: "${transcript.text}")';
}

/// Decodes submitted utterances, in order, and publishes the results.
///
/// Split out from [VoicePipeline] because endpointing and decoding do not
/// always live on the same isolate: a session runs the VAD on a reader
/// isolate close to the microphone and only ships finished utterances here.
class UtteranceTranscriber {
  UtteranceTranscriber(this._decoder, {int stableAgreement = 2})
    : _stable = StablePrefix(agreement: stableAgreement);

  final UtteranceDecoder _decoder;
  final StablePrefix _stable;
  final SeamJoiner _seam = SeamJoiner();
  final _results = StreamController<UtteranceResult>.broadcast();

  /// Which utterance [_stable] is currently accumulating, so a snapshot of a
  /// new one does not inherit agreement from the last one.
  Duration? _stableFor;

  /// Decodes, in utterance order. Ordering is inherited from the decoder, which
  /// serialises through a single worker isolate, so utterances that pile up
  /// while one is decoding queue rather than race.
  Future<void> _tail = Future<void>.value();

  /// Decodes queued but not yet finished. Provisional work is only admitted
  /// when this is zero, so a speculative decode can never sit in front of a
  /// real one.
  int _queued = 0;

  /// One [UtteranceResult] per submitted utterance.
  ///
  /// Broadcast, so several widgets can watch one pipeline — which also means
  /// results added while nobody is listening are dropped. Subscribe before the
  /// first submission.
  Stream<UtteranceResult> get results => _results.stream;

  /// Queues [utterance] for decoding. Returns immediately.
  void submit(Utterance utterance) => _enqueue(utterance, isFinal: true);

  /// Queues a snapshot of speech still in progress, for live text.
  ///
  /// Dropped rather than queued when anything is already decoding. That is the
  /// whole safety property: a provisional decode is worth doing only if it is
  /// current, and a queue of stale snapshots would both show old text and delay
  /// the final result behind work nobody needs. A fresher snapshot is always
  /// moments away.
  void submitProvisional(Utterance snapshot) {
    if (_queued > 0) return;
    _enqueue(snapshot, isFinal: false);
  }

  void _enqueue(Utterance utterance, {required bool isFinal}) {
    if (_results.isClosed) return;
    _queued++;
    _tail = _tail.then((_) async {
      try {
        final clock = Stopwatch()..start();
        final transcript = await _decoder.transcribe(utterance.audio);
        clock.stop();
        // Trim before commit: the trim must see the previous utterance's tail,
        // and the commit then makes this decode the left side of the next seam.
        final joined = _seam.trim(transcript.text);
        if (isFinal) {
          _seam.commit(joined, truncated: utterance.truncated);
        }
        if (!_results.isClosed) {
          _results.add(
            UtteranceResult(
              utterance: utterance,
              transcript: transcript,
              isFinal: isFinal,
              decode: clock.elapsed,
              stableText: _stabilise(utterance, joined, isFinal),
              joinedText: joined == transcript.text ? null : joined,
            ),
          );
        }
      } catch (e, st) {
        if (!_results.isClosed) _results.addError(e, st);
      } finally {
        _queued--;
      }
    });
  }

  /// Folds one decode into the agreement window.
  ///
  /// Done here rather than at the call site because it must happen in decode
  /// order, and this is the only place that order is guaranteed: [_tail]
  /// serialises the chain, while submissions arrive from a reader isolate.
  String _stabilise(Utterance utterance, String text, bool isFinal) {
    if (isFinal) {
      _stable.reset();
      _stableFor = null;
      return text;
    }
    if (_stableFor != utterance.start) {
      _stable.reset();
      _stableFor = utterance.start;
    }
    return _stable.update(text);
  }

  /// Waits until every submitted utterance has been decoded *and* delivered.
  ///
  /// The trailing yield is load-bearing, not defensive. A broadcast controller
  /// hands events to listeners in a microtask, so `add` returns before anyone
  /// has seen the value; awaiting only the decode chain would return with the
  /// final result still undelivered, and a caller that then cancels its
  /// subscription loses it. Yielding to the event loop drains the microtask
  /// queue first, which is exactly the guarantee this method advertises.
  ///
  /// Observed as a missing last utterance: the audio endpointed, the model
  /// decoded it, and it never arrived.
  Future<void> drain() async {
    await _tail;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    await drain();
    await _results.close();
  }
}

/// Endpointing plus decoding: audio in, transcripts out.
///
/// This is the shape the benchmarks argued for. Continuous streaming decode was
/// measured at a sustained 0.5× realtime on an A14 — it falls behind twice as
/// fast as speech arrives — because the streaming path re-attends over an audio
/// context that keeps growing. Decoding whole utterances instead is a single
/// forward pass over a bounded clip, and parakeet-tdt_ctc-110m turns a 5 s
/// utterance around in roughly 125 ms on the same phone.
///
/// The consequence, worth being deliberate about: text arrives per utterance,
/// not per word. Perceived latency is [EndpointerConfig.hangover] plus decode,
/// and the hangover dominates. If a product needs words appearing as they are
/// spoken, this is the wrong architecture and no amount of tuning fixes it.
class VoicePipeline {
  /// Positional rather than named because Dart cannot bind a named parameter
  /// straight to a private field, and neither of these should be public: an
  /// `add` that bypassed the pipeline would drop the events it produced.
  VoicePipeline(
    UtteranceDecoder decoder,
    this._endpointer, {
    int stableAgreement = 2,
  }) : _transcriber = UtteranceTranscriber(
         decoder,
         stableAgreement: stableAgreement,
       );

  final UtteranceTranscriber _transcriber;
  final Endpointer _endpointer;
  final _events = StreamController<EndpointerEvent>.broadcast();

  bool _closed = false;

  /// One [UtteranceResult] per completed utterance.
  Stream<UtteranceResult> get results => _transcriber.results;

  /// Raw endpointer events, including [SpeechStarted], which arrives well
  /// before the corresponding result. Drive "listening"/"speaking" UI from
  /// this rather than from [results].
  ///
  /// Also carries [SpeechDiscarded], which is the only signal that audio was
  /// heard and then filtered — it produces no [UtteranceResult] by design.
  Stream<EndpointerEvent> get events => _events.stream;

  /// True between a confirmed [SpeechStarted] and its [SpeechEnded].
  bool get isSpeaking => _endpointer.isSpeaking;

  /// Most recent speech probability, for a confidence indicator.
  double get lastProbability => _endpointer.lastProbability;

  /// Feeds captured audio: mono float32 at 16 kHz, any chunk size.
  ///
  /// Returns as soon as the VAD has consumed the samples — decoding happens in
  /// the background and surfaces on [results].
  void add(Float32List samples) {
    if (_closed) throw StateError('VoicePipeline has been closed');
    _dispatch(_endpointer.add(samples));
  }

  /// Ends the stream, emitting any utterance still in progress. Await the
  /// returned future to be sure every result has reached [results] listeners.
  Future<void> flush() async {
    if (_closed) return;
    _dispatch(_endpointer.flush());
    await _transcriber.drain();
  }

  void _dispatch(List<EndpointerEvent> events) {
    for (final event in events) {
      _events.add(event);
      if (event is SpeechEnded) _transcriber.submit(event.utterance);
    }
  }

  /// Closes the streams. Does not dispose the decoder — it is expensive to
  /// create and usually outlives any one pipeline.
  Future<void> close() async {
    if (_closed) return;
    await flush();
    _closed = true;
    await _events.close();
    await _transcriber.close();
  }
}
