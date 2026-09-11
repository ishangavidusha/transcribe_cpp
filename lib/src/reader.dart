import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'endpointer.dart';
import 'normalizer.dart';
import 'ring.dart';
import 'vad.dart';
import 'wav.dart';

/// Audio the capture layer lost, and had to be skipped over.
class Dropout {
  const Dropout(this.frames);

  /// Frames the microphone produced that never reached the reader.
  final int frames;

  Duration get duration =>
      Duration(microseconds: frames * 1000000 ~/ vadSampleRate);

  @override
  String toString() => 'Dropout(${duration.inMilliseconds} ms)';
}

/// A snapshot of speech still in progress, on its way to a provisional decode.
class Snapshot {
  Snapshot(this.audio, this.start);
  final Float32List audio;
  final Duration start;
}

/// What the front of the pipeline is hearing, right now.
class LiveLevel {
  const LiveLevel({
    required this.probability,
    required this.gain,
    required this.noise,
    required this.inputRms,
  });

  /// The VAD's speech probability for the most recent 32 ms window, in [0, 1].
  ///
  /// The immediate signal: no confirmation delay, no hangover. This is what a
  /// level or "hearing you" indicator should follow.
  final double probability;

  /// Gain [AudioNormalizer] is currently applying, or 1.0 when normalization
  /// is off.
  ///
  /// Worth surfacing while tuning. A gain pinned at 1.0 through quiet speech
  /// means the noise cap is binding — the room is too loud for boosting to be
  /// safe — which is a different problem from the microphone being quiet, and
  /// the two are indistinguishable from the transcript alone.
  final double gain;

  /// The normalizer's estimate of the room's noise floor, as RMS, or 0 when
  /// normalization is off.
  ///
  /// The other half of the gain reading. Gain stuck at 1.0 means one of two
  /// very different things — a quiet room the normalizer has not needed to act
  /// on, or a loud one where boosting is capped because it could not help — and
  /// this is what tells them apart.
  final double noise;

  /// RMS of the most recent 32 ms of audio **as the microphone delivered it**,
  /// before gain. Zero when normalization is off.
  ///
  /// The honest answer to "how loud was I speaking". Room loudness in dB SPL
  /// needs an instrument and still tells you less, because what reaches the
  /// models depends just as much on distance, the phone's own input gain, and
  /// which microphone the route selected. This is the number those all collapse
  /// into. Convert with `20 * log10(inputRms)` for dBFS: about -20 is loud,
  /// -30 is normal, below -45 is where detection starts to suffer.
  final double inputRms;

  @override
  String toString() =>
      'LiveLevel(p=${probability.toStringAsFixed(2)}, '
      'gain=${gain.toStringAsFixed(1)}x, '
      'noise=${noise.toStringAsFixed(4)})';
}

/// Everything the reader isolate needs to start.
class ReaderBoot {
  ReaderBoot({
    required this.handshake,
    required this.events,
    required this.weights,
    required this.config,
    required this.normalizer,
    required this.provisionalInterval,
    this.ringAddress = 0,
    this.replay = false,
    this.recordTo,
  });

  final SendPort handshake;
  final SendPort events;
  final Uint8List weights;
  final EndpointerConfig config;
  final NormalizerConfig? normalizer;
  final Duration provisionalInterval;

  /// Live capture: the native ring to drain. Zero when replaying.
  final int ringAddress;

  /// Replay mode: audio arrives over the command port instead of a ring.
  final bool replay;

  /// Live capture: where to write the raw audio, or null not to.
  final String? recordTo;
}

/// Audio in, utterances and snapshots out.
///
/// Extracted so the microphone and the replay path cannot drift apart. An
/// offline comparison is only worth running if it exercises the code the
/// microphone exercises; two copies of this logic would eventually disagree,
/// and the offline numbers would quietly stop describing the live pipeline.
class Segmenter {
  Segmenter({
    required this.endpointer,
    required this.normalizer,
    required this.provisionalInterval,
    required this.emit,
  });

  final Endpointer endpointer;
  final AudioNormalizer? normalizer;
  final Duration provisionalInterval;
  final void Function(Object message) emit;

  /// Samples fed since the session opened, across resets.
  ///
  /// Pacing runs off this rather than a wall clock. For the microphone the two
  /// are the same thing — audio arrives in real time — but keeping the clock in
  /// audio makes a replay produce identical output every run, which is the
  /// whole point of having one.
  int _fed = 0;
  Duration _lastSnapshot = Duration.zero;
  Duration _lastLevel = Duration.zero;

  Duration get position =>
      Duration(microseconds: _fed * 1000000 ~/ vadSampleRate);

  void add(Float32List samples) {
    // Gain is applied here, before anything looks at the audio, so the VAD and
    // the decoder both see the same normalized stream. Doing it after the VAD
    // would leave the miss it is meant to fix in place: quiet speech that never
    // opens an utterance is never handed to the decoder at all.
    normalizer?.process(samples);
    _fed += samples.length;

    for (final event in endpointer.add(samples)) {
      switch (event) {
        case SpeechEnded(:final utterance):
          emit(utterance);
          // A finished utterance supersedes every provisional decode of it, so
          // do not immediately snapshot whatever comes next.
          _lastSnapshot = position;
        case SpeechStarted():
        case SpeechDiscarded():
          emit(event);
      }
    }

    final now = position;
    if (now - _lastLevel >= const Duration(milliseconds: 60)) {
      _lastLevel = now;
      emit(
        LiveLevel(
          probability: endpointer.lastProbability,
          gain: normalizer?.gain ?? 1.0,
          noise: normalizer?.noiseFloor ?? 0.0,
          inputRms: normalizer?.inputRms ?? 0.0,
        ),
      );
    }

    // Live text: re-decode the utterance so far while the speaker keeps going.
    // Checked once per call, so the pacing is only as fine as the caller's
    // chunks — with the ring's ~16 ms that is far below the interval, and a
    // replay turns provisional decoding off. Utterance boundaries do not share
    // this granularity; those are exact at any chunk size.
    // Affordable only because parakeet decodes a whole utterance in tens of
    // milliseconds; the transcriber drops these when it is already busy, so a
    // slow decode degrades to fewer updates rather than a growing backlog.
    if (provisionalInterval > Duration.zero &&
        now - _lastSnapshot >= provisionalInterval) {
      final audio = endpointer.pendingAudio();
      final start = endpointer.pendingStart;
      if (audio != null && start != null) {
        _lastSnapshot = now;
        emit(Snapshot(audio, start));
      }
    }
  }

  void reset() {
    endpointer.reset();
    normalizer?.reset();
  }

  void flush() {
    for (final event in endpointer.flush()) {
      // A burst still open at end of stream may be discarded rather than
      // emitted, and that is the one loss the caller has no other way to see —
      // there is no next utterance to notice a hole in.
      if (event is SpeechEnded) {
        emit(event.utterance);
      } else if (event is SpeechDiscarded) {
        emit(event);
      }
    }
  }
}

/// Reader isolate entry point, for both live capture and replay.
void readerMain(ReaderBoot boot) {
  final vad = SileroVad.fromBytes(boot.weights);
  final segmenter = Segmenter(
    endpointer: Endpointer(vad, config: boot.config),
    normalizer: boot.normalizer == null
        ? null
        : AudioNormalizer(config: boot.normalizer!),
    provisionalInterval: boot.provisionalInterval,
    emit: boot.events.send,
  );

  if (boot.replay) {
    replayLoop(boot, vad, segmenter);
  } else {
    captureLoop(boot, vad, segmenter);
  }
}

/// Feeds recorded audio as fast as the isolate can, yielding often enough to
/// stay responsive to a stop.
Future<void> replayLoop(
  ReaderBoot boot,
  SileroVad vad,
  Segmenter segmenter,
) async {
  final commands = ReceivePort();
  boot.handshake.send(commands.sendPort);

  // Waits for the caller to hand over the audio rather than taking it at spawn.
  // The results are broadcast streams, which drop whatever is emitted before a
  // listener attaches, so the caller needs a window in which the isolate exists
  // but is not yet producing.
  // The stop flag has to be set by the port listener itself, not read out of a
  // queue the feed loop is too busy to drain: once the loop is running it never
  // returns to a `await for`, so a stop routed through the same stream would
  // only be seen after the whole clip had already been fed.
  final begin = Completer<Float32List?>();
  var stopped = false;
  commands.listen((dynamic message) {
    if (message == 'stop') {
      stopped = true;
      if (!begin.isCompleted) begin.complete(null);
    } else if (message is Float32List && !begin.isCompleted) {
      begin.complete(message);
    }
  });

  final audio = await begin.future;
  if (audio != null) {
    // One VAD window per step. Chunk size does not change what the endpointer
    // sees — it buffers to windows itself — but it does set how often the level
    // and snapshot checks run, and a window is the natural granularity.
    const chunk = vadWindowSamples;
    for (var i = 0; i < audio.length; i += chunk) {
      final end = math.min(i + chunk, audio.length);
      segmenter.add(Float32List.sublistView(audio, i, end));
      // Yield periodically so the stop can land and the outbound queue can
      // drain. Without this the loop holds the isolate for the whole clip and
      // nothing can interrupt it.
      if ((i ~/ chunk) % 32 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (stopped) break;
      }
    }
    if (!stopped) segmenter.flush();
  }

  vad.dispose();
  commands.close();
  boot.events.send('done');
}

/// Drains the ring, runs the VAD, and ships finished utterances back.
void captureLoop(ReaderBoot boot, SileroVad vad, Segmenter segmenter) {
  final reader = AudioRingReader.attach(boot.ringAddress);
  // Written before the normalizer touches the samples, so a recording captures
  // what the microphone delivered rather than what one particular gain setting
  // made of it. Replaying it can then compare normalizer settings too, which it
  // could not if the gain were baked in.
  final recorder = boot.recordTo == null ? null : WavSink.open(boot.recordTo!);
  var lastDropped = reader.dropped;
  Timer? timer;

  void drain() {
    // Check for loss before reading, so a hole is handled before the samples
    // on the far side of it are fed to a VAD that still carries state from the
    // near side.
    final dropped = reader.dropped;
    if (dropped != lastDropped) {
      final lost = dropped - lastDropped;
      lastDropped = dropped;
      segmenter.reset();
      boot.events.send(Dropout(lost));
    }

    final samples = reader.read();
    if (samples.isEmpty) return;
    // A synchronous write of a kilobyte or two per tick. It happens on the
    // reader isolate, which must not stall or the ring overflows behind it —
    // measured well under the 16 ms budget, and the ring holds a second.
    recorder?.add(samples);
    segmenter.add(samples);
  }

  final commands = ReceivePort();
  boot.handshake.send(commands.sendPort);

  commands.listen((dynamic message) {
    switch (message) {
      case 'reset':
        // Drain what is buffered first: it is audio from before the
        // disruption and belongs to whatever the user was saying then.
        drain();
        segmenter.reset();
        lastDropped = reader.dropped;
      case 'stop':
        timer?.cancel();
        // One last drain so the tail of what the user said is not lost to the
        // stop, then close out any utterance still open.
        drain();
        segmenter.flush();
        recorder?.close();
        reader.dispose();
        vad.dispose();
        commands.close();
    }
  });

  // 16 ms is half the VAD's window, so a window is never more than one tick
  // late. The drain itself is a memcpy plus about 0.6 ms of VAD per window.
  timer = Timer.periodic(const Duration(milliseconds: 16), (_) => drain());
}
