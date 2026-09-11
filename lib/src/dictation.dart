import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'capture.dart';
import 'endpointer.dart';
import 'normalizer.dart';
import 'pipeline.dart';
import 'reader.dart';
import 'vad.dart';

/// Microphone in, transcripts out.
///
/// Three isolates, because each stage has a different reason not to share one:
///
///   * The **audio thread** (native) writes into a lock-free ring. It cannot
///     block, allocate, or call Dart.
///   * A **reader isolate** drains the ring every 16 ms and runs the VAD and
///     endpointer. It lives off the UI isolate so a janky frame cannot delay
///     endpointing, and off the decode isolate so a long decode cannot stall
///     the drain and overflow the ring.
///   * The **decode isolate**, inside [Transcriber], where the blocking native
///     call happens.
///
/// The reader is where the interesting failure lives. If it stalls for the ring
/// depth, audio is lost and the audio before and after the hole is not
/// contiguous — so the VAD's LSTM state and any utterance in progress are
/// reasoning about a stream that did not happen. The reader watches the drop
/// counter and resets rather than splicing, and reports the loss on [dropouts].
/// The same applies to interruptions and route changes, which is why this class
/// watches capture state and resets across those too.
class Dictation {
  Dictation._(this._transcriber, this._reader, this._commands, this._events);

  final UtteranceTranscriber _transcriber;
  final Isolate _reader;
  final SendPort _commands;
  final ReceivePort _events;

  final _dropouts = StreamController<Dropout>.broadcast();
  final _endpointerEvents = StreamController<EndpointerEvent>.broadcast();
  final _levels = StreamController<LiveLevel>.broadcast();
  StreamSubscription<CaptureStatus>? _stateWatch;
  CaptureState _lastState = CaptureState.idle;
  bool _speaking = false;
  bool _stopped = false;

  /// One result per endpointed utterance.
  Stream<UtteranceResult> get results => _transcriber.results;

  /// Endpointer events, including [SpeechStarted], which arrives before the
  /// text does. Drive "speaking" UI from this.
  ///
  /// [SpeechDiscarded] arrives here too, and is worth logging even if nothing
  /// in the UI reacts to it: it is the only account of audio the endpointer
  /// heard and chose not to decode.
  Stream<EndpointerEvent> get events => _endpointerEvents.stream;

  /// True between a confirmed speech start and the end of that utterance.
  ///
  /// Lags the microphone by [EndpointerConfig.minSpeechDuration] by
  /// construction — it reports *confirmed* speech, and confirmation takes that
  /// long, unless [EndpointerConfig.reattachWithin] confirmed it at onset. For a live meter use [levels], which updates every 32 ms; driving an
  /// indicator from this one makes it read "silence" through the first quarter
  /// second of every utterance.
  bool get isSpeaking => _speaking;

  /// Speech probability and applied gain, thinned to roughly 60 ms.
  ///
  /// Thinned because delivering one event per 32 ms window would cost more than
  /// running the VAD does. See [LiveLevel] for why this, and not [isSpeaking],
  /// is what an indicator should follow.
  Stream<LiveLevel> get levels => _levels.stream;

  /// Capture state, including interruptions and recoveries nobody asked for.
  Stream<CaptureStatus> get status => MicrophoneCapture.states;

  /// Audio that was captured and lost. Anything on this stream is a fault
  /// worth surfacing — it means a transcript has a hole in it.
  Stream<Dropout> get dropouts => _dropouts.stream;

  /// Requests permission, starts the microphone, and wires up the pipeline.
  ///
  /// [transcriber] is not owned by the session — it is expensive to build and
  /// usually outlives any one dictation — so [stop] does not dispose it.
  ///
  /// [recordTo] writes the captured audio to a WAV as the session runs, for
  /// [Replay] to feed back afterwards. That pairing is what makes tuning
  /// measurable: a microphone hands you different audio every time, so two
  /// settings compared across two live sessions are compared on two different
  /// recordings. Record once, then replay it under each setting.
  static Future<Dictation> start({
    required UtteranceDecoder transcriber,
    required Uint8List vadWeights,
    EndpointerConfig config = const EndpointerConfig(),
    NormalizerConfig? normalizer = const NormalizerConfig(),
    bool voiceProcessing = false,
    Duration provisionalInterval = const Duration(milliseconds: 350),
    int stableAgreement = 2,
    String? recordTo,
  }) async {
    if (!await MicrophoneCapture.requestPermission()) {
      throw StateError(
        'Microphone permission denied. iOS only prompts once, so send the '
        'user to Settings rather than calling start again.',
      );
    }

    final handle = await MicrophoneCapture.start(
      voiceProcessing: voiceProcessing,
    );
    if (handle.sampleRate != vadSampleRate) {
      await MicrophoneCapture.stop();
      throw StateError(
        'Capture delivered ${handle.sampleRate} Hz; the models need '
        '$vadSampleRate Hz.',
      );
    }

    final events = ReceivePort();
    final handshake = ReceivePort();
    final reader = await Isolate.spawn(
      readerMain,
      ReaderBoot(
        handshake: handshake.sendPort,
        events: events.sendPort,
        ringAddress: handle.ringAddress,
        weights: vadWeights,
        config: config,
        normalizer: normalizer,
        provisionalInterval: provisionalInterval,
        recordTo: recordTo,
      ),
      debugName: 'transcribe_cpp capture reader',
    );
    final commands = await handshake.first as SendPort;
    handshake.close();

    // Endpointing happens on the reader isolate, so this side only needs the
    // decode-and-deliver half of the pipeline.
    final dictation = Dictation._(
      UtteranceTranscriber(transcriber, stableAgreement: stableAgreement),
      reader,
      commands,
      events,
    );
    dictation._listen();
    return dictation;
  }

  void _listen() {
    _events.listen((dynamic message) {
      switch (message) {
        case Utterance():
          _speaking = false;
          if (!_endpointerEvents.isClosed) {
            _endpointerEvents.add(SpeechEnded(message.end, message));
          }
          _transcriber.submit(message);
        case Snapshot():
          _transcriber.submitProvisional(
            Utterance(
              audio: message.audio,
              start: message.start,
              end:
                  message.start +
                  Duration(
                    microseconds:
                        message.audio.length * 1000000 ~/ vadSampleRate,
                  ),
              speechStart: message.start,
              speechEnd: message.start,
              truncated: false,
            ),
          );
        case LiveLevel():
          if (!_levels.isClosed) _levels.add(message);
        case Dropout():
          _speaking = false;
          if (!_dropouts.isClosed) _dropouts.add(message);
        case SpeechStarted():
          _speaking = true;
          if (!_endpointerEvents.isClosed) _endpointerEvents.add(message);
        case SpeechDiscarded():
          if (!_endpointerEvents.isClosed) _endpointerEvents.add(message);
      }
    });

    // An interruption or a route change means the audio either side of it is
    // not contiguous. Feeding across that seam would let the VAD carry state
    // from before the gap and let the endpointer glue two unrelated moments
    // into one utterance.
    _stateWatch = MicrophoneCapture.states.listen((status) {
      final wasDisrupted =
          _lastState == CaptureState.interrupted ||
          _lastState == CaptureState.recovering;
      if (wasDisrupted && status.state == CaptureState.running) {
        _commands.send('reset');
      }
      _lastState = status.state;
    });
  }

  /// Stops the microphone and tears down the reader. Does not dispose the
  /// [Transcriber] it was given.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _stateWatch?.cancel();
    _commands.send('stop');
    await MicrophoneCapture.stop();
    await MicrophoneCapture.dispose();
    // Give the reader a moment to drain and flush before killing it, or the
    // last thing the user said dies with the isolate.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _events.close();
    _reader.kill(priority: Isolate.beforeNextEvent);
    await _transcriber.close();
    await _endpointerEvents.close();
    await _levels.close();
    await _dropouts.close();
  }
}
