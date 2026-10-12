import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/audio_format.dart';

Float32List _sine(int rate, double hz, double seconds, {double amp = 0.5}) {
  final n = (rate * seconds).round();
  return Float32List.fromList([
    for (var i = 0; i < n; i++) amp * math.sin(2 * math.pi * hz * i / rate),
  ]);
}

/// RMS of the middle of [x], away from the edges where the kernel runs into
/// the zeros before the start and after the end.
double _rms(Float32List x) {
  final from = x.length ~/ 4;
  final to = x.length * 3 ~/ 4;
  var sum = 0.0;
  for (var i = from; i < to; i++) {
    sum += x[i] * x[i];
  }
  return math.sqrt(sum / (to - from));
}

/// Frequency from the count of rising zero crossings in the middle half.
double _frequency(Float32List x, int rate) {
  final from = x.length ~/ 4;
  final to = x.length * 3 ~/ 4;
  var first = -1;
  var last = -1;
  var crossings = 0;
  for (var i = from + 1; i < to; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) {
      if (first < 0) first = i;
      last = i;
      crossings++;
    }
  }
  return (crossings - 1) * rate / (last - first);
}

Float32List _convertAll(
  AudioFormat format,
  TypedData audio, {
  List<int>? chunkBytes,
}) {
  final converter = AudioConverter(format);
  final bytes = audio.buffer.asUint8List(
    audio.offsetInBytes,
    audio.lengthInBytes,
  );
  final out = <double>[];
  if (chunkBytes == null) {
    out.addAll(converter.add(bytes));
  } else {
    var at = 0;
    var i = 0;
    while (at < bytes.length) {
      final size = math.min(chunkBytes[i++ % chunkBytes.length], bytes.length - at);
      out.addAll(converter.add(Uint8List.sublistView(bytes, at, at + size)));
      at += size;
    }
  }
  out.addAll(converter.flush());
  return Float32List.fromList(out);
}

Int16List _toInt16(Float32List x) =>
    Int16List.fromList([for (final v in x) (v * 32767).round()]);

void main() {
  group('AudioConverter', () {
    test('passes the engine format through untouched', () {
      final input = _sine(16000, 440, 0.5);
      final out = _convertAll(AudioFormat.engine, input);
      expect(out, input);
    });

    test('reads int16 as full scale at 32768', () {
      final out = _convertAll(
        const AudioFormat(sampleRate: 16000),
        Int16List.fromList([0, 16384, -32768, 32767]),
      );
      expect(out, [0, 0.5, -1, closeTo(1, 1e-4)]);
    });

    test('averages channels to mono', () {
      final out = _convertAll(
        const AudioFormat(sampleRate: 16000, channels: 2),
        Int16List.fromList([16384, 0, -16384, -16384]),
      );
      expect(out, [0.25, -0.5]);
    });

    test('a sample split across chunks converts as if it were whole', () {
      final input = _toInt16(_sine(48000, 1000, 0.3));
      const format = AudioFormat(sampleRate: 48000, channels: 2);
      final whole = _convertAll(format, input);
      // Odd sizes split samples, frames and the stereo pair.
      final chunked = _convertAll(format, input, chunkBytes: [1, 3, 7, 1000]);
      expect(chunked, whole);
    });

    test('rejects rates it cannot convert', () {
      expect(
        () => AudioConverter(const AudioFormat(sampleRate: 4000)),
        throwsArgumentError,
      );
      expect(
        () => AudioConverter(const AudioFormat(sampleRate: 16000, channels: 0)),
        throwsArgumentError,
      );
    });
  });

  group('Resampler', () {
    for (final rate in [8000, 11025, 22050, 24000, 44100, 48000, 96000]) {
      test('$rate Hz to 16 kHz keeps a 1 kHz tone', () {
        final input = _sine(rate, 1000, 1);
        final out = _convertAll(
          AudioFormat(sampleRate: rate, sampleFormat: SampleFormat.float32),
          input,
        );
        // As long as the input, to the sample.
        expect(out.length, (input.length * 16000 / rate).ceil());
        expect(_frequency(out, 16000), closeTo(1000, 1));
        // Within 0.02 dB: the pass band is flat.
        expect(_rms(out) / _rms(input), closeTo(1, 0.0025));
      });
    }

    test('does not fold tones above 8 kHz into the band', () {
      // 12 kHz at 48 kHz would alias to 4 kHz, the middle of speech.
      final input = _sine(48000, 12000, 1);
      final out = _convertAll(
        const AudioFormat(sampleRate: 48000, sampleFormat: SampleFormat.float32),
        input,
      );
      final rejection = 20 * math.log(_rms(out) / _rms(input)) / math.ln10;
      // Measured at -100 dB.
      expect(rejection, lessThan(-90));
    });

    test('output does not depend on chunk size', () {
      final input = _sine(44100, 523, 0.7);
      const format = AudioFormat(
        sampleRate: 44100,
        sampleFormat: SampleFormat.float32,
      );
      final whole = _convertAll(format, input);
      final chunked = _convertAll(format, input, chunkBytes: [4, 1764, 12, 400]);
      expect(chunked, whole);
    });

    test('starts on time', () {
      // An impulse at input time t must peak at output time t, not half a
      // kernel later.
      final input = Float32List(48000)..[24000] = 1;
      final out = _convertAll(
        const AudioFormat(sampleRate: 48000, sampleFormat: SampleFormat.float32),
        input,
      );
      var peak = 0;
      for (var i = 1; i < out.length; i++) {
        if (out[i] > out[peak]) peak = i;
      }
      expect(peak, 8000);
    });
  });
}
