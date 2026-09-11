import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'engine.dart';
import 'pipeline.dart';
import 'status.dart';
import 'streaming.dart';
import 'transcript.dart';

/// Commands sent to the worker isolate. Kept as small records rather than a
/// class hierarchy so they cross the port cheaply.
enum _Op {
  load,
  info,
  run,
  streamBegin,
  streamFeed,
  streamFinalize,
  streamText,
  close,
}

class _Request {
  _Request(this.id, this.op, [this.arg]);
  final int id;
  final _Op op;
  final Object? arg;
}

class _Response {
  _Response(this.id, this.value, this.error, this.stackTrace);
  final int id;
  final Object? value;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Runs a model on its own isolate and exposes an async API.
///
/// This is the type applications should use. The reason it exists rather than
/// letting callers hold a [Session] directly: `transcribe_run` and
/// `transcribe_stream_feed` are **blocking** native calls. Invoked on the UI
/// isolate they would freeze the frame pump for the duration of the decode.
/// The engine also requires that one session be touched by one thread at a
/// time, which a dedicated isolate gives us for free.
class Transcriber implements UtteranceDecoder {
  Transcriber._(this._isolate, this._commands, this._responses) {
    _responses.listen(_onResponse);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;

  final _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool _closed = false;

  /// Loads [modelPath] on a fresh worker isolate.
  ///
  /// [threads] is the CPU thread count for ops that run on CPU; 0 lets the
  /// engine choose. On phones, leaving this at 0 is usually right — pinning it
  /// high fights the scheduler and burns battery without helping, because the
  /// heavy tensor work goes to Metal anyway.
  static Future<Transcriber> open(String modelPath, {int threads = 0}) async {
    final responses = ReceivePort();
    final handshake = ReceivePort();

    final isolate = await Isolate.spawn(
      _workerMain,
      _Boot(handshake.sendPort, responses.sendPort),
      debugName: 'transcribe_cpp worker',
    );

    final commands = await handshake.first as SendPort;
    handshake.close();

    final transcriber = Transcriber._(isolate, commands, responses);
    await transcriber._send(_Op.load, (modelPath, threads));
    return transcriber;
  }

  /// Backend, architecture, and variant of the loaded model.
  ///
  /// Check [ModelInfo.isGpu] on a real device — a silent CPU fallback is the
  /// most common reason on-device numbers disappoint.
  Future<ModelInfo> info() async => await _send(_Op.info) as ModelInfo;

  /// Transcribes one clip of mono float32 16 kHz PCM.
  @override
  Future<Transcript> transcribe(Float32List pcm) async =>
      await _send(_Op.run, pcm) as Transcript;

  /// Opens a streaming session. Only one may be active at a time — an open
  /// stream holds the model's compute lease.
  Future<StreamingSession> startStream({
    CommitPolicy commitPolicy = CommitPolicy.auto,
    int stablePrefixAgreementN = 0,
  }) async {
    await _send(_Op.streamBegin, (commitPolicy.code, stablePrefixAgreementN));
    return StreamingSession._(this);
  }

  Future<Object?> _send(_Op op, [Object? arg]) {
    if (_closed) {
      throw StateError('Transcriber has been disposed');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send(_Request(id, op, arg));
    return completer.future;
  }

  void _onResponse(dynamic message) {
    final response = message as _Response;
    final completer = _pending.remove(response.id);
    if (completer == null) return;
    if (response.error != null) {
      completer.completeError(response.error!, response.stackTrace);
    } else {
      completer.complete(response.value);
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    try {
      await _send(_Op.close);
    } catch (_) {
      // The worker may already be gone; tearing down is best-effort.
    }
    _closed = true;
    _responses.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('Transcriber disposed mid-request'));
      }
    }
    _pending.clear();
  }
}

/// A live streaming transcription, driven from the app isolate.
class StreamingSession {
  StreamingSession._(this._owner);

  final Transcriber _owner;
  bool _done = false;

  /// Feeds one frame and returns the updated text view.
  ///
  /// Feeding is serialised through the worker's command queue, so calls made
  /// faster than the model can consume them queue rather than race — but they
  /// do build latency. Pace feeds to the family's natural cadence
  /// (~80 ms for moonshine_streaming) rather than firing per audio callback.
  Future<StreamText> feed(Float32List frame) async {
    _assertOpen();
    return await _owner._send(_Op.streamFeed, frame) as StreamText;
  }

  /// Current text without feeding anything.
  Future<StreamText> get text async =>
      await _owner._send(_Op.streamText) as StreamText;

  /// Drains and closes the stream, returning the final text.
  Future<StreamText> finalize() async {
    _assertOpen();
    _done = true;
    return await _owner._send(_Op.streamFinalize) as StreamText;
  }

  void _assertOpen() {
    if (_done) throw StateError('Streaming session already finalized');
  }
}

class _Boot {
  _Boot(this.handshake, this.responses);
  final SendPort handshake;
  final SendPort responses;
}

/// Worker entry point. Everything below runs off the UI isolate.
void _workerMain(_Boot boot) {
  final commands = ReceivePort();
  boot.handshake.send(commands.sendPort);

  Model? model;
  Session? session;
  TranscribeStream? stream;

  commands.listen((dynamic message) {
    final request = message as _Request;
    Object? value;
    Object? error;
    StackTrace? stackTrace;

    try {
      switch (request.op) {
        case _Op.load:
          final (path, threads) = request.arg! as (String, int);
          model = Model.load(path);
          session = model!.createSession(threads: threads);
          value = null;

        case _Op.info:
          value = ModelInfo(
            backend: model!.backend,
            architecture: model!.architecture,
            variant: model!.variant,
          );

        case _Op.run:
          value = session!.run(request.arg! as Float32List);

        case _Op.streamBegin:
          final (policy, agreementN) = request.arg! as (int, int);
          stream = TranscribeStream.begin(
            session!,
            commitPolicy: CommitPolicy.values.firstWhere(
              (p) => p.code == policy,
              orElse: () => CommitPolicy.auto,
            ),
            stablePrefixAgreementN: agreementN,
          );
          value = null;

        case _Op.streamFeed:
          stream!.feed(request.arg! as Float32List);
          value = stream!.text;

        case _Op.streamFinalize:
          stream!.finalize();
          value = stream!.text;
          stream = null;

        case _Op.streamText:
          value = stream!.text;

        case _Op.close:
          stream?.dispose();
          session?.dispose();
          model?.dispose();
          stream = null;
          session = null;
          model = null;
          value = null;
      }
    } on TranscribeException catch (e, st) {
      error = e;
      stackTrace = st;
    } catch (e, st) {
      error = e;
      stackTrace = st;
    }

    boot.responses.send(_Response(request.id, value, error, stackTrace));

    if (request.op == _Op.close) {
      commands.close();
    }
  });
}
