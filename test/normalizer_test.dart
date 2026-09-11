import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

/// Speech-like audio: bursts of tone separated by pauses that are only room
/// noise, in whole 512-sample blocks.
///
/// The pauses are the important part and not decoration. The noise floor is
/// estimated as a running minimum, so a signal that is never quiet gives it
/// nothing to measure — and a normalizer that boosted such a signal would be
/// boosting on no evidence about the room at all.
Float32List _speech(
  double seconds, {
  double amplitude = 0.0,
  double noise = 0.0,
  double burst = 0.8,
  double pause = 0.6,
  int seed = 7,
}) {
  final n = (seconds * vadSampleRate).round();
  final period = ((burst + pause) * vadSampleRate).round();
  final voiced = (burst * vadSampleRate).round();
  final random = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final speaking = amplitude > 0 && i % period < voiced;
    final tone = speaking
        ? amplitude * math.sin(2 * math.pi * 220 * i / vadSampleRate)
        : 0.0;
    out[i] = tone + (random.nextDouble() * 2 - 1) * noise;
  }
  return out;
}

/// Unbroken tone, for the cases where continuous audio is the point.
Float32List _signal(
  double seconds, {
  double amplitude = 0.0,
  double noise = 0.0,
  int seed = 7,
}) => _speech(
  seconds,
  amplitude: amplitude,
  noise: noise,
  burst: 1,
  pause: 0,
  seed: seed,
);

double _peak(Float32List x, {int from = 0}) {
  var peak = 0.0;
  for (var i = from; i < x.length; i++) {
    final a = x[i].abs();
    if (a > peak) peak = a;
  }
  return peak;
}

/// Feeds in 512-sample chunks, the way the reader isolate does, and returns the
/// concatenated output. Chunking matters: the noise floor only updates on block
/// boundaries, and gain glides across calls.
Float32List _run(AudioNormalizer n, Float32List input) {
  final out = Float32List(input.length);
  for (var i = 0; i < input.length; i += 512) {
    final end = math.min(i + 512, input.length);
    final chunk = Float32List.fromList(Float32List.sublistView(input, i, end));
    n.process(chunk);
    out.setRange(i, end, chunk);
  }
  return out;
}

void main() {
  group('AudioNormalizer', () {
    test('lifts quiet speech in a quiet room', () {
      // The reported failure: someone talking softly, whose audio the VAD never
      // scores as speech. 0.02 peak is about -34 dBFS.
      final quiet = _speech(6, amplitude: 0.02, noise: 0.0002);
      final out = _run(AudioNormalizer(), quiet);

      // Judge the second half: the first second is the noise tracker filling
      // and the gain gliding, and it deliberately starts at unity.
      final lifted = _peak(out, from: 3 * vadSampleRate);
      expect(
        lifted,
        greaterThan(0.15),
        reason:
            'quiet speech was not boosted into the range the VAD and '
            'the decoder were trained on',
      );
      expect(lifted, lessThanOrEqualTo(0.98));
    });

    test('brings loud speech down to the same level as quiet speech', () {
      // Bidirectional, so the level the microphone happened to deliver stops
      // reaching the model at all. A boost-only stage would leave this one
      // untouched and lift the quiet one, which still leaves the two different.
      final loud = _speech(6, amplitude: 0.45, noise: 0.0002);
      final n = AudioNormalizer();
      final out = _run(n, loud);

      const config = NormalizerConfig();
      expect(
        _peak(out, from: 3 * vadSampleRate),
        lessThanOrEqualTo(config.peakCeiling + 0.05),
      );
      expect(n.gain, lessThan(1.0));
    });

    test('refuses to amplify a noisy room', () {
      // Same quiet voice, but the room is loud. Gain cannot improve SNR, so
      // boosting here would only lift the room into the VAD's speech range and
      // trade missed speech for hallucinated speech.
      final noisy = _speech(6, amplitude: 0.02, noise: 0.05);
      final n = AudioNormalizer();
      _run(n, noisy);

      expect(n.noiseFloor, greaterThan(0.01));
      expect(
        n.gain,
        lessThan(1.5),
        reason:
            'the noise cap did not bind; amplified room noise will show '
            'up as phantom utterances',
      );
    });

    test('does not run away on silence', () {
      final n = AudioNormalizer();
      final out = _run(n, _signal(5, amplitude: 0.0, noise: 0.00002));

      expect(
        _peak(out),
        lessThan(0.05),
        reason:
            'near-silence was amplified into something the VAD will '
            'score',
      );
      expect(n.gain.isFinite, isTrue);
    });

    test(
      'never exceeds the limit, even on a step from silence to full scale',
      () {
        final input = Float32List(vadSampleRate * 2);
        for (var i = vadSampleRate; i < input.length; i++) {
          input[i] = math.sin(2 * math.pi * 220 * i / vadSampleRate);
        }
        final out = _run(AudioNormalizer(), input);
        expect(_peak(out), lessThanOrEqualTo(0.97 + 1e-6));
      },
    );

    test('gain is capped by maxGain', () {
      final n = AudioNormalizer(
        config: const NormalizerConfig(maxGain: 2.0, noiseCeiling: 1.0),
      );
      _run(n, _speech(6, amplitude: 0.001, noise: 0.00001));
      expect(n.gain, lessThanOrEqualTo(2.0 + 1e-6));
    });

    test('reset clears the envelope and the gain', () {
      final n = AudioNormalizer();
      _run(n, _speech(6, amplitude: 0.02, noise: 0.0002));
      expect(n.gain, greaterThan(1.5));

      // A dropout or a route change means the audio either side is not
      // contiguous — and after a device change, not even the same microphone
      // sensitivity. Carrying the gain across would apply the old room's.
      n.reset();
      expect(n.gain, 1.0);
      expect(n.noiseFloor, 0.0);
    });

    test('processes in place', () {
      final buffer = _speech(0.5, amplitude: 0.02);
      final returned = AudioNormalizer().process(buffer);
      expect(identical(returned, buffer), isTrue);
    });

    // The reported failure, on real speech: a quiet talker whose audio the VAD
    // scores below threshold and never opens an utterance for. If the
    // normalizer puts an attenuated clip back at roughly its original level,
    // then the VAD is looking at essentially the audio it already handles, and
    // whatever it detected before it detects again.
    test('a 10x quieter microphone produces the same levels', () {
      expect(
        _levelRatio(0.10),
        closeTo(1.0, 0.25),
        reason:
            'input level still reaches the model, so the VAD thresholds '
            'and the decoder both remain level-dependent',
      );
    });

    test('a 33x quieter microphone is lifted as far as the cap allows', () {
      // Past what maxGain can undo. Pinned anyway, because "improves as far as
      // it is permitted to" is a weaker claim than "makes level irrelevant",
      // and the point at which one becomes the other is worth knowing.
      final ratio = _levelRatio(0.03);
      expect(ratio, greaterThan(0.3));
      expect(ratio, lessThan(0.85));
    });

    // The bug this caught in a real session: targetLevel was set from sine
    // tests, where peak sits 1.4x above the envelope. Speech came back at 6.5x,
    // so every single utterance was driven into the limiter and decoded with
    // clipping distortion on every loud syllable.
    test('real speech never reaches the limiter', () {
      final speech = _readWav('../transcribe_cpp/example/assets/jfk.wav');
      final out = _run(AudioNormalizer(), Float32List.fromList(speech));
      const config = NormalizerConfig();

      final peak = _peak(out, from: vadSampleRate);
      expect(
        peak,
        lessThanOrEqualTo(config.limit - 0.02),
        reason:
            'the gain cap did not hold the peak below the backstop, so '
            'loud syllables are being clipped',
      );
      // And the cap is doing it by reducing gain, not by clamping samples:
      // a signal parked exactly at the limit is the signature of clipping.
      final atLimit = out.where((v) => v.abs() >= config.limit - 1e-6).length;
      expect(atLimit, 0);
    });

    test('chunk size does not change the result', () {
      final input = _speech(4, amplitude: 0.03, noise: 0.0005);
      final whole = Float32List.fromList(input);
      AudioNormalizer().process(whole);

      final chunked = _run(AudioNormalizer(), Float32List.fromList(input));
      for (var i = 0; i < whole.length; i++) {
        expect(chunked[i], closeTo(whole[i], 1e-6));
      }
    });
  });
}

/// Reads a 16-bit mono PCM WAV into float32.
Float32List _readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      final count = size ~/ 2;
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = data.getInt16(offset + 8 + i * 2, Endian.little) / 32768.0;
      }
      return out;
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}

/// RMS of each 32 ms block, the granularity the VAD works at.
List<double> _blockRms(Float32List x) {
  final out = <double>[];
  for (var i = 0; i + 512 <= x.length; i += 512) {
    var sum = 0.0;
    for (var j = i; j < i + 512; j++) {
      sum += x[j] * x[j];
    }
    out.add(math.sqrt(sum / 512));
  }
  return out;
}

/// Runs the clip at full level and attenuated, and returns the ratio of the
/// two normalized outputs over the blocks that carry speech.
///
/// Phrased as a comparison against the normalizer's own output rather than
/// against the original audio, because "restores the original level" stopped
/// being the claim: the normalizer targets a level of its own choosing. What it
/// promises is that how loud the microphone happened to be stops mattering, and
/// that is exactly a ratio of 1 between these two runs.
double _levelRatio(double attenuation) {
  final original = _readWav('../transcribe_cpp/example/assets/jfk.wav');
  final quiet = Float32List.fromList(original);
  for (var i = 0; i < quiet.length; i++) {
    quiet[i] *= attenuation;
  }

  final loudOut = _blockRms(
    _run(AudioNormalizer(), Float32List.fromList(original)),
  );
  final quietOut = _blockRms(_run(AudioNormalizer(), quiet));
  final reference = _blockRms(original);
  final loudest = reference.reduce(math.max);

  final ratios = <double>[];
  // Speech blocks only, and past the first second, where the noise floor
  // estimate is still filling and the gain is deliberately gliding up.
  for (var i = 31; i < reference.length; i++) {
    if (reference[i] > loudest * 0.15 && loudOut[i] > 1e-6) {
      ratios.add(quietOut[i] / loudOut[i]);
    }
  }
  ratios.sort();
  expect(ratios, isNotEmpty);
  return ratios[ratios.length ~/ 2];
}
