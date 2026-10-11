import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'activity.dart' as activity;
import 'capture.dart';
import 'endpointer.dart';
import 'live.dart';
import 'model_manager.dart';
import 'normalizer.dart';
import 'pipeline.dart';
import 'reader.dart';
import 'transcript.dart';
import 'vad.dart';
import 'worker.dart';

/// What a [TranscribeSession] is doing.
enum SessionState {
  /// Model loaded, microphone off.
  idle,

  /// Asking for permission and starting the microphone. The permission
  /// prompt can hold a session here for as long as the user takes.
  starting,

  /// The microphone is on and speech is being transcribed.
  listening,

  /// A recording is being fed through the pipeline by [TranscribeSession.replay].
  replaying,

  /// The microphone is off and the last utterances are still decoding.
  finishing,
}

/// The transcript so far: what is final, and what is still being spoken.
final class LiveText {
  const LiveText({this.settled = '', this.interim = ''});

  /// Every finished utterance since [TranscribeSession.start], joined. Only
  /// grows during a run.
  final String settled;

  /// The utterance in progress, as far as consecutive decodes agree on it.
  /// Replaced, not extended, as more audio arrives; empty between utterances.
  final String interim;

  /// [settled] and [interim] together, for a single text view.
  String get full => interim.isEmpty
      ? settled
      : settled.isEmpty
      ? interim
      : '$settled $interim';

  @override
  bool operator ==(Object other) =>
      other is LiveText && other.settled == settled && other.interim == interim;

  @override
  int get hashCode => Object.hash(settled, interim);

  @override
  String toString() => 'LiveText("$settled" + "$interim")';
}

/// A loaded model and the pipeline around it: microphone in, text out.
///
/// ```dart
/// final session = await TranscribeSession.open(model);
/// session.text.addListener(() => print(session.text.value.full));
/// await session.start();
/// // ... the user speaks ...
/// await session.stop();
/// await session.dispose();
/// ```
///
/// Opening loads the model, which is the expensive part; [start] and [stop]
/// can then run any number of times, and the streams and [Live] values last
/// for the whole session, so nothing needs re-subscribing between runs.
///
/// Three isolates sit behind it. The audio thread writes a lock-free ring; a
/// reader isolate drains it every 16 ms and runs the VAD and endpointer, off
/// the UI isolate so a janky frame cannot delay endpointing and off the
/// decode isolate so a long decode cannot overflow the ring; the decode
/// isolate makes the blocking engine call.
final class TranscribeSession {
  TranscribeSession._(
    this._decoder,
    this._weights,
    this._sources,
    this.modelInfo,
    this._release,
  );

  /// Loads [model] and the bundled VAD.
  ///
  /// [threads] is the engine's CPU thread count; 0 lets it choose. On iOS the
  /// heavy work runs on Metal and this rarely matters; on Android the engine
  /// runs on CPU.
  static Future<TranscribeSession> open(
    InstalledModel model, {
    int threads = 0,
  }) => openSessionAt(model.path, threads: threads);

  /// The rate every model, the VAD and [replay] expect: mono float32 at
  /// 16 kHz. The microphone path resamples to it natively; audio handed to
  /// [replay] must already be at it.
  static const sampleRate = vadSampleRate;

  final UtteranceDecoder _decoder;
  final Uint8List _weights;
  final SessionSources _sources;
  final Future<void> Function() _release;

  /// What the engine loaded, including the backend it is running on. A GPU
  /// model reporting a CPU backend has fallen back, and decodes several
  /// times slower.
  final ModelInfo modelInfo;

  final _state = LiveController(SessionState.idle);
  final _text = LiveController(const LiveText());
  final _level = LiveController(LiveLevel.silent);
  final _capture = LiveController(const CaptureStatus(CaptureState.idle));
  final _utterances = StreamController<UtteranceResult>.broadcast();
  final _events = StreamController<EndpointerEvent>.broadcast();
  final _dropouts = StreamController<Dropout>.broadcast();

  _Run? _run;
  Future<void>? _starting;
  bool _disposed = false;

  Live<SessionState> get state => _state.live;

  /// The transcript of the current or most recent run. Bind a text view to
  /// this rather than assembling [utterances] by hand.
  Live<LiveText> get text => _text.live;

  /// What the microphone hears now: speech probability, gain and input
  /// level, about every 60 ms. Follow this, not [events], for a meter: an
  /// utterance is only confirmed a quarter second after it begins.
  Live<LiveLevel> get level => _level.live;

  /// The capture layer's state, including interruptions and route changes
  /// nobody asked for. The session recovers from them itself; this is for
  /// showing the user why the microphone went quiet.
  Live<CaptureStatus> get capture => _capture.live;

  /// Every decode, in order: provisional ones while an utterance is spoken
  /// ([UtteranceResult.isFinal] false), then its final one. A provisional
  /// result is replaced by the next, never appended. Decode errors arrive
  /// here as stream errors.
  Stream<UtteranceResult> get utterances => _utterances.stream;

  /// Speech starting, ending, and bursts discarded as too short to be
  /// speech. [SpeechDiscarded] is the only account of audio that was heard
  /// and not transcribed.
  Stream<EndpointerEvent> get events => _events.stream;

  /// Audio the capture layer lost. A transcript spanning one has a hole in
  /// it; this is a fault worth showing.
  Stream<Dropout> get dropouts => _dropouts.stream;

  /// Starts the microphone and transcribes until [stop].
  ///
  /// Asks for microphone permission first. The system stops prompting after
  /// a denial (iOS after one, Android after two), so a denial throws
  /// [StateError] and the app should send the user to Settings rather than
  /// call this again. On Android the app must declare
  /// `android.permission.RECORD_AUDIO` in its manifest. [text] is cleared.
  ///
  /// [voiceProcessing] turns on the platform's echo cancellation and noise
  /// suppression. Off by default: the chain is tuned for calls, not
  /// transcription. Turn it on when the app plays audio while listening.
  ///
  /// [provisionalInterval] paces the re-decodes behind [LiveText.interim];
  /// [Duration.zero] turns live text off. [stableAgreement] is how many
  /// consecutive decodes must agree on a word before it shows.
  ///
  /// [recordTo] writes the raw microphone audio to a WAV as it arrives, for
  /// [replay] to run again later under other settings.
  Future<void> start({
    EndpointerConfig endpointer = const EndpointerConfig(),
    NormalizerConfig? normalizer = const NormalizerConfig(),
    bool voiceProcessing = false,
    Duration provisionalInterval = const Duration(milliseconds: 350),
    int stableAgreement = 2,
    String? recordTo,
  }) {
    _checkIdle();
    _state.value = SessionState.starting;
    _text.value = const LiveText();
    final settings = ReaderSettings(
      weights: _weights,
      endpointer: endpointer,
      normalizer: normalizer,
      provisionalInterval: provisionalInterval,
      voiceProcessing: voiceProcessing,
      recordTo: recordTo,
    );
    return _starting = () async {
      try {
        final source = await _sources.live(settings);
        _begin(source, stableAgreement);
        _state.value = SessionState.listening;
      } catch (_) {
        _state.value = SessionState.idle;
        rethrow;
      } finally {
        _starting = null;
      }
    }();
  }

  /// Stops the microphone and waits for every utterance already spoken to be
  /// decoded and delivered. The model stays loaded for the next [start].
  ///
  /// Also ends a [replay] early.
  Future<void> stop() async {
    await _starting?.catchError((_) {});
    final run = _run;
    if (run == null) return;
    _state.value = SessionState.finishing;
    run.source.stop();
    await _finish(run);
  }

  /// Feeds [audio] (mono float32 at [sampleRate]) through the same pipeline the
  /// microphone drives, and completes once every utterance is decoded and
  /// delivered.
  ///
  /// The same normalizer, VAD, endpointer and decoder, on the same reader
  /// isolate; only the source differs. A microphone never gives the same
  /// audio twice, so comparing two settings live compares two different
  /// recordings. Replaying one recording under each setting does not.
  ///
  /// Audio is fed as fast as the reader can take it, so live text, whose
  /// pacing depends on real time, is off. Segmentation and transcripts match
  /// what the same audio produces live.
  Future<void> replay(
    Float32List audio, {
    EndpointerConfig endpointer = const EndpointerConfig(),
    NormalizerConfig? normalizer = const NormalizerConfig(),
    int stableAgreement = 2,
  }) async {
    _checkIdle();
    _state.value = SessionState.replaying;
    _text.value = const LiveText();
    final settings = ReaderSettings(
      weights: _weights,
      endpointer: endpointer,
      normalizer: normalizer,
      provisionalInterval: Duration.zero,
      voiceProcessing: false,
    );
    final ReaderSource source;
    try {
      source = await _sources.replay(settings, audio);
    } catch (_) {
      _state.value = SessionState.idle;
      rethrow;
    }
    await _finish(_begin(source, stableAgreement));
  }

  /// Stops anything running and releases the model. The [Live] values keep
  /// their last state; the streams close.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _release();
    await _utterances.close();
    await _events.close();
    await _dropouts.close();
    await _state.close();
    await _text.close();
    await _level.close();
    await _capture.close();
  }

  void _checkIdle() {
    if (_disposed) throw StateError('TranscribeSession has been disposed');
    if (_state.value != SessionState.idle) {
      throw StateError('session is ${_state.value.name}; stop it first');
    }
  }

  _Run _begin(ReaderSource source, int stableAgreement) {
    activity.activeSessions++;
    final transcriber = UtteranceTranscriber(
      _decoder,
      stableAgreement: stableAgreement,
    );
    final run = _Run(source, transcriber);
    _run = run;
    run.subscriptions.addAll([
      transcriber.results.listen(_onResult, onError: _utterances.addError),
      source.captureStates.listen((s) => _capture.value = s),
      source.messages.listen((m) => _onMessage(run, m)),
    ]);
    return run;
  }

  Future<void> _finish(_Run run) async {
    await run.close();
    if (_run != run) return;
    _run = null;
    activity.activeSessions--;
    _level.value = LiveLevel.silent;
    _capture.value = const CaptureStatus(CaptureState.idle);
    _text.value = LiveText(settled: _text.value.settled);
    _state.value = SessionState.idle;
  }

  void _onMessage(_Run run, Object? message) {
    switch (message) {
      case Utterance():
        if (!_events.isClosed) _events.add(SpeechEnded(message.end, message));
        run.transcriber.submit(message);
      case Snapshot():
        run.transcriber.submitProvisional(
          Utterance(
            audio: message.audio,
            start: message.start,
            end:
                message.start +
                Duration(
                  microseconds: message.audio.length * 1000000 ~/ vadSampleRate,
                ),
            speechStart: message.start,
            speechEnd: message.start,
            truncated: false,
          ),
        );
      case LiveLevel():
        _level.value = message;
      case Dropout():
        if (!_dropouts.isClosed) _dropouts.add(message);
      // SpeechStarted and SpeechDiscarded: the reader sends ended speech as
      // the Utterance above, never as an event.
      case final EndpointerEvent event:
        if (!_events.isClosed) _events.add(event);
      case 'done':
        run.readerDone();
    }
  }

  void _onResult(UtteranceResult r) {
    if (!_utterances.isClosed) _utterances.add(r);
    final current = _text.value;
    if (r.isFinal) {
      final t = r.text.trim();
      _text.value = LiveText(
        settled: t.isEmpty
            ? current.settled
            : current.settled.isEmpty
            ? t
            : '${current.settled} $t',
      );
    } else {
      _text.value = LiveText(
        settled: current.settled,
        interim: r.stableText.trim(),
      );
    }
  }
}

/// One start-to-stop (or one replay): a reader and the decodes behind it.
final class _Run {
  _Run(this.source, this.transcriber);

  final ReaderSource source;
  final UtteranceTranscriber transcriber;
  final subscriptions = <StreamSubscription<Object?>>[];
  final _readerDone = Completer<void>();
  Future<void>? _closing;

  void readerDone() {
    if (!_readerDone.isCompleted) _readerDone.complete();
  }

  /// Waits for the reader to hand over its last utterance and for every
  /// decode to be delivered, then releases the reader.
  Future<void> close() => _closing ??= () async {
    await _readerDone.future;
    await transcriber.drain();
    for (final s in subscriptions) {
      await s.cancel();
    }
    await transcriber.close();
    await source.close();
  }();
}

/// The settings a reader is started with.
final class ReaderSettings {
  const ReaderSettings({
    required this.weights,
    required this.endpointer,
    required this.normalizer,
    required this.provisionalInterval,
    required this.voiceProcessing,
    this.recordTo,
  });

  final Uint8List weights;
  final EndpointerConfig endpointer;
  final NormalizerConfig? normalizer;
  final Duration provisionalInterval;
  final bool voiceProcessing;
  final String? recordTo;
}

/// Where a run's pipeline messages come from: the reader isolate behind the
/// microphone, the one behind a replay, or a script in a test.
///
/// [messages] carries what [Segmenter] emits, then `'done'` once the reader
/// has flushed its last utterance after [stop] or the end of a recording.
abstract interface class ReaderSource {
  Stream<Object?> get messages;
  Stream<CaptureStatus> get captureStates;

  /// Asks the reader to finish: flush what it holds, then send `'done'`.
  void stop();

  /// Releases everything, once `'done'` has arrived.
  Future<void> close();
}

/// How a session gets its readers. Swapped in tests, which have neither a
/// microphone nor the native VAD.
final class SessionSources {
  const SessionSources({required this.live, required this.replay});

  final Future<ReaderSource> Function(ReaderSettings settings) live;
  final Future<ReaderSource> Function(
    ReaderSettings settings,
    Float32List audio,
  )
  replay;

  static const platform = SessionSources(
    live: _startCapture,
    replay: _startReplay,
  );
}

/// Builds a session on the model at [path]. Not exported: apps open an
/// [InstalledModel], which has passed its hash check. Tests and the Mac
/// harness use this to supply a path, a decoder or sources of their own.
Future<TranscribeSession> openSessionAt(
  String path, {
  int threads = 0,
  UtteranceDecoder? decoder,
  ModelInfo? modelInfo,
  Uint8List? vadWeights,
  SessionSources sources = SessionSources.platform,
}) async {
  final weights = vadWeights ?? await SileroVad.loadBundledWeights();
  if (decoder != null) {
    return TranscribeSession._(
      decoder,
      weights,
      sources,
      modelInfo ?? const ModelInfo(backend: '', architecture: '', variant: ''),
      () async {},
    );
  }
  final transcriber = await Transcriber.open(path, threads: threads);
  return TranscribeSession._(
    transcriber,
    weights,
    sources,
    await transcriber.info(),
    transcriber.dispose,
  );
}

/// The reader isolate, over either the capture ring or a recording.
final class _IsolateSource implements ReaderSource {
  _IsolateSource(this._isolate, this._events, this._commands);

  final Isolate _isolate;
  final ReceivePort _events;
  final SendPort _commands;

  static Future<_IsolateSource> spawn(
    ReaderSettings s, {
    int ringAddress = 0,
    bool replay = false,
    String debugName = 'transcribe_cpp reader',
  }) async {
    final events = ReceivePort();
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      readerMain,
      ReaderBoot(
        handshake: handshake.sendPort,
        events: events.sendPort,
        ringAddress: ringAddress,
        weights: s.weights,
        config: s.endpointer,
        normalizer: s.normalizer,
        provisionalInterval: s.provisionalInterval,
        replay: replay,
        recordTo: s.recordTo,
      ),
      debugName: debugName,
    );
    // A reader that dies without saying 'done' would leave stop() waiting
    // forever; its exit says it instead.
    isolate.addOnExitListener(events.sendPort, response: 'done');
    final commands = await handshake.first as SendPort;
    handshake.close();
    return _IsolateSource(isolate, events, commands);
  }

  void send(Object message) => _commands.send(message);

  @override
  Stream<Object?> get messages => _events;

  @override
  Stream<CaptureStatus> get captureStates => const Stream.empty();

  @override
  void stop() => _commands.send('stop');

  @override
  Future<void> close() async {
    _events.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<ReaderSource> _startCapture(ReaderSettings s) async {
  if (!await MicrophoneCapture.requestPermission()) {
    throw StateError(
      'Microphone permission denied. The system stops asking after the user '
      'declines (once on iOS, twice on Android), so send the user to '
      'Settings rather than calling start again.',
    );
  }

  // Watched before the microphone starts, not after: the native side reports
  // "running" as it starts, and an event channel nobody is listening to drops
  // it, which left the session showing "idle" while it listened. A
  // single-subscription controller holds the events until the session does.
  final states = StreamController<CaptureStatus>();
  _IsolateSource? reader;
  var last = CaptureState.idle;
  final watch = MicrophoneCapture.states.listen((status) {
    // Audio either side of an interruption or a route change is not
    // contiguous. Feeding across that seam would let the VAD carry state
    // from before the gap and the endpointer glue two unrelated moments into
    // one utterance, so the reader is reset when capture comes back.
    final wasDisrupted =
        last == CaptureState.interrupted || last == CaptureState.recovering;
    if (wasDisrupted && status.state == CaptureState.running) {
      reader?.send('reset');
    }
    last = status.state;
    if (!states.isClosed) states.add(status);
  });

  try {
    final handle = await MicrophoneCapture.start(
      voiceProcessing: s.voiceProcessing,
    );
    if (handle.sampleRate != vadSampleRate) {
      await MicrophoneCapture.dispose();
      throw StateError(
        'Capture delivered ${handle.sampleRate} Hz; the models need '
        '$vadSampleRate Hz.',
      );
    }
    reader = await _IsolateSource.spawn(
      s,
      ringAddress: handle.ringAddress,
      debugName: 'transcribe_cpp capture reader',
    );
  } catch (_) {
    await watch.cancel();
    await states.close();
    rethrow;
  }
  return _CaptureSource(reader, states, watch);
}

/// The capture reader, stopping the microphone as it is told to finish so no
/// more audio arrives behind the final flush.
final class _CaptureSource implements ReaderSource {
  _CaptureSource(this._inner, this._states, this._watch);

  final _IsolateSource _inner;
  final StreamController<CaptureStatus> _states;
  final StreamSubscription<CaptureStatus> _watch;

  @override
  Stream<Object?> get messages => _inner.messages;

  @override
  Stream<CaptureStatus> get captureStates => _states.stream;

  @override
  void stop() {
    _inner.stop();
    unawaited(MicrophoneCapture.stop());
  }

  @override
  Future<void> close() async {
    await _watch.cancel();
    await MicrophoneCapture.dispose();
    await _inner.close();
    await _states.close();
  }
}

Future<ReaderSource> _startReplay(ReaderSettings s, Float32List audio) async {
  final source = await _IsolateSource.spawn(
    s,
    replay: true,
    debugName: 'transcribe_cpp replay',
  );
  // Sent straight away: the session subscribes to the port before it reads
  // anything, and a ReceivePort holds messages until it is listened to.
  source.send(audio);
  return source;
}
