import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'endpointer.dart';
import 'normalizer.dart';
import 'pipeline.dart';
import 'reader.dart';

/// Runs recorded audio through the same pipeline the microphone drives.
///
/// This exists because a live session cannot be repeated. Comparing two
/// endpointer settings means running the same audio twice, and a microphone
/// gives you different audio every time — the two most recent tuning sessions
/// both played straight through a recording, so each setting was measured on a
/// different passage and none of the comparisons meant anything. Replaying
/// fixed samples removes the only variable that was not supposed to be there.
///
/// It is the *same* code, not a reimplementation: normalizer, VAD, endpointer
/// and decoder are the ones [Dictation] uses, on the same reader isolate, with
/// only the audio source swapped. Two copies would eventually disagree and the
/// offline numbers would quietly stop describing the live pipeline.
///
/// What it does **not** reproduce is live-text behaviour. Audio is fed as fast
/// as the isolate manages rather than in real time, so which provisional
/// snapshots would have been dropped is meaningless — and so provisional
/// decoding is switched off here entirely rather than reported misleadingly.
/// Segmentation, gain and transcripts are exact; latency belongs to a device.
class Replay {
  Replay._(this._transcriber, this._isolate, this._events);

  final UtteranceTranscriber _transcriber;
  final Isolate _isolate;
  final ReceivePort _events;

  final _endpointerEvents = StreamController<EndpointerEvent>.broadcast();
  final _levels = StreamController<LiveLevel>.broadcast();
  final _finished = Completer<void>();

  SendPort? _commands;
  Float32List? _audio;
  bool _started = false;
  bool _disposed = false;

  /// One result per endpointed utterance, in order.
  Stream<UtteranceResult> get results => _transcriber.results;

  /// Endpointer events, including [SpeechStarted].
  Stream<EndpointerEvent> get events => _endpointerEvents.stream;

  /// Speech probability and gain, one per ~60 ms of audio.
  Stream<LiveLevel> get levels => _levels.stream;

  /// Prepares a run. Feeding does not begin until [run] is called.
  ///
  /// Two phases on purpose. The result streams are broadcast, which drops
  /// anything emitted before a listener attaches, and this isolate would
  /// otherwise be producing utterances while the caller was still wiring
  /// subscriptions up. Subscribe between [start] and [run].
  static Future<Replay> start({
    required UtteranceDecoder transcriber,
    required Float32List audio,
    required Uint8List vadWeights,
    EndpointerConfig config = const EndpointerConfig(),
    NormalizerConfig? normalizer = const NormalizerConfig(),
    int stableAgreement = 2,
  }) async {
    final events = ReceivePort();
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      readerMain,
      ReaderBoot(
        handshake: handshake.sendPort,
        events: events.sendPort,
        weights: vadWeights,
        config: config,
        normalizer: normalizer,
        // Off, not merely unreported. Audio is fed as fast as the isolate
        // manages, so which snapshots would have survived the drop rule is a
        // property of this machine's scheduler rather than of the pipeline —
        // and running them would cost decode time to produce a number that
        // means nothing.
        provisionalInterval: Duration.zero,
        replay: true,
      ),
      debugName: 'transcribe_cpp replay',
    );

    final replay = Replay._(
      UtteranceTranscriber(transcriber, stableAgreement: stableAgreement),
      isolate,
      events,
    );
    replay._commands = await handshake.first as SendPort;
    handshake.close();
    replay._audio = audio;
    replay._listen();
    return replay;
  }

  /// Feeds the audio and completes once every utterance has been decoded *and*
  /// delivered to listeners.
  Future<void> run() {
    if (_started) throw StateError('Replay has already been run');
    _started = true;
    _commands!.send(_audio);
    _audio = null;
    return _finished.future;
  }

  void _listen() {
    _events.listen((dynamic message) async {
      switch (message) {
        case Utterance():
          if (!_endpointerEvents.isClosed) {
            _endpointerEvents.add(SpeechEnded(message.end, message));
          }
          _transcriber.submit(message);
        case SpeechStarted():
        case SpeechDiscarded():
          if (!_endpointerEvents.isClosed) _endpointerEvents.add(message);
        case LiveLevel():
          if (!_levels.isClosed) _levels.add(message);
        case 'done':
          // Every utterance has been submitted; wait for the decodes behind
          // them, and for delivery, before saying the run is over.
          await _transcriber.drain();
          if (!_finished.isCompleted) _finished.complete();
      }
    });
  }

  /// Tears down the isolate and closes the streams. Does not dispose the
  /// decoder, which usually outlives any one run.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commands?.send('stop');
    _events.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _transcriber.close();
    await _endpointerEvents.close();
    await _levels.close();
    if (!_finished.isCompleted) _finished.complete();
  }
}
