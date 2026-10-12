import 'dart:math' as math;
import 'dart:typed_data';

import 'vad.dart';

/// How each sample of pushed audio is stored. Little-endian, as on every
/// platform the package runs on.
enum SampleFormat {
  /// Signed 16-bit PCM, full scale at ±32768. What most audio APIs deliver.
  int16(2),

  /// 32-bit float, full scale at ±1.0.
  float32(4);

  const SampleFormat(this.bytes);

  /// Bytes per sample.
  final int bytes;
}

/// The layout of audio handed to [TranscribeSession.transcribe] or
/// [TranscribeSession.transcribeStream]: its rate, channel count and sample
/// format.
///
/// Any rate and channel count is accepted. Channels are averaged to mono and
/// the result resampled to the 16 kHz the models take, so audio from an app's
/// own recorder, a call stack or a file can go in as it is.
final class AudioFormat {
  const AudioFormat({
    required this.sampleRate,
    this.channels = 1,
    this.sampleFormat = SampleFormat.int16,
  });

  /// What the models take: mono float32 at 16 kHz. Audio in this format is
  /// passed through untouched.
  static const engine = AudioFormat(
    sampleRate: vadSampleRate,
    sampleFormat: SampleFormat.float32,
  );

  /// Frames per second.
  final int sampleRate;

  /// Interleaved channels per frame.
  final int channels;

  final SampleFormat sampleFormat;

  /// Bytes per frame: one sample for every channel.
  int get frameBytes => channels * sampleFormat.bytes;

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat;

  @override
  int get hashCode => Object.hash(sampleRate, channels, sampleFormat);

  @override
  String toString() =>
      'AudioFormat($sampleRate Hz, $channels ch, ${sampleFormat.name})';
}

/// Turns audio in any [AudioFormat] into the engine's mono float32 at 16 kHz,
/// one chunk at a time.
///
/// Chunks may split a frame anywhere, even mid-sample; the remainder is held
/// for the next. Output does not depend on how the input was chunked.
final class AudioConverter {
  AudioConverter(this.format)
    : _resampler = check(format).sampleRate == vadSampleRate
          ? null
          : Resampler(format.sampleRate, vadSampleRate);

  /// Throws [ArgumentError] for a format this cannot convert, and returns it
  /// otherwise. 8 kHz is the lowest rate speech is carried at; below it the
  /// band the models need is not there to recover.
  static AudioFormat check(AudioFormat format) {
    if (format.sampleRate < 8000 || format.sampleRate > 384000) {
      throw ArgumentError.value(
        format.sampleRate,
        'sampleRate',
        'must be between 8000 and 384000 Hz',
      );
    }
    if (format.channels < 1 || format.channels > 32) {
      throw ArgumentError.value(
        format.channels,
        'channels',
        'must be between 1 and 32',
      );
    }
    return format;
  }

  /// Converts the whole of [audio] at once.
  static Float32List convertAll(TypedData audio, AudioFormat format) {
    final converter = AudioConverter(format);
    final body = converter.add(audio);
    final tail = converter.flush();
    if (tail.isEmpty) return body;
    return Float32List(body.length + tail.length)
      ..setAll(0, body)
      ..setAll(body.length, tail);
  }

  final AudioFormat format;
  final Resampler? _resampler;

  /// Bytes of a frame split across chunks, carried to the next.
  Uint8List _carry = Uint8List(0);

  /// Converts [audio], whose bytes are laid out as [format] describes. Its
  /// element type does not matter: an `Int16List`, a `Float32List` and the
  /// `Uint8List` holding the same bytes convert identically.
  Float32List add(TypedData audio) {
    var bytes = audio.buffer.asUint8List(
      audio.offsetInBytes,
      audio.lengthInBytes,
    );
    if (_carry.isNotEmpty) {
      bytes = Uint8List(_carry.length + bytes.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, bytes);
    }
    final frameBytes = format.frameBytes;
    final whole = bytes.length - bytes.length % frameBytes;
    _carry = Uint8List.fromList(bytes.sublist(whole));
    final mono = _decode(bytes, whole ~/ frameBytes);
    return _resampler?.add(mono) ?? mono;
  }

  /// Drains the resampler at end of stream. A partial frame still held is
  /// dropped: it is not audio.
  Float32List flush() {
    _carry = Uint8List(0);
    return _resampler?.flush() ?? Float32List(0);
  }

  Float32List _decode(Uint8List bytes, int frames) {
    final data = ByteData.sublistView(bytes);
    final channels = format.channels;
    final out = Float32List(frames);
    switch (format.sampleFormat) {
      case SampleFormat.int16:
        final scale = 1 / (32768 * channels);
        for (var f = 0, o = 0; f < frames; f++) {
          var sum = 0;
          for (var c = 0; c < channels; c++, o += 2) {
            sum += data.getInt16(o, Endian.little);
          }
          out[f] = sum * scale;
        }
      case SampleFormat.float32:
        for (var f = 0, o = 0; f < frames; f++) {
          var sum = 0.0;
          for (var c = 0; c < channels; c++, o += 4) {
            sum += data.getFloat32(o, Endian.little);
          }
          out[f] = channels == 1 ? sum : sum / channels;
        }
    }
    return out;
  }
}

/// Streaming sample-rate conversion by a Kaiser-windowed sinc, at any ratio.
///
/// Each output sample is the input's band-limited value at the output's
/// instant, so the result is the same whatever size the input arrives in.
///
/// Measured from 48 kHz to 16 kHz: flat to 0.01 dB through 4 kHz, where
/// speech recognition does its work; -3.3 dB at 7 kHz and -6 dB at the
/// cutoff, 7.2 kHz (90% of the lower Nyquist); and 97 dB or more of
/// rejection from 8.8 kHz up, so nothing above 8 kHz folds back into the
/// band the models hear. 44.1 kHz matches to 0.05 dB. Cost is about 6.5 ms
/// per second of 48 kHz audio (60 s in 389 ms under the JIT on an M-series
/// Mac). Latency is half the kernel: 16 zero crossings, a millisecond at
/// 48 kHz.
final class Resampler {
  Resampler(this.inRate, this.outRate)
    : _cutoff = _rolloff * 0.5 * math.min(inRate, outRate) / inRate {
    // Half-width in input samples: _zeroCrossings lobes of the sinc.
    _halfWidth = (_zeroCrossings / (2 * _cutoff)).ceil();
    _table = _buildTable(_cutoff, _halfWidth);
    _history = Float32List(2 * _halfWidth + 1024);
    // Virtual zeros before the first sample, so output starts at time zero
    // rather than half a kernel late.
    _base = -_halfWidth;
    _length = _halfWidth;
  }

  final int inRate;
  final int outRate;

  /// Fraction of the lower Nyquist kept. 0.9 is 7.2 kHz on the way to 16 kHz.
  static const _rolloff = 0.9;
  static const _zeroCrossings = 16;
  static const _beta = 8.6;

  /// Table entries per input sample. Linear interpolation between entries
  /// keeps the interpolation error below the window's own sidelobes.
  static const _density = 512;

  /// Cutoff as a fraction of the input rate (cycles per input sample).
  final double _cutoff;
  late final int _halfWidth;
  late final Float32List _table;

  /// Input not yet consumed. `_history[i]` is input sample `_base + i`.
  late Float32List _history;
  late int _base;
  late int _length;

  /// Output samples produced, and input samples received, since the start.
  int _produced = 0;
  int _received = 0;

  Float32List add(Float32List input) {
    _append(input);
    _received += input.length;
    return _drain(false);
  }

  /// Emits what is left, as if the input continued as silence, so the output
  /// is as long as the input's duration.
  Float32List flush() {
    _append(Float32List(_halfWidth));
    return _drain(true);
  }

  void _append(Float32List input) {
    if (_length + input.length > _history.length) {
      final grown = Float32List(
        math.max(_history.length * 2, _length + input.length),
      )..setRange(0, _length, _history);
      _history = grown;
    }
    _history.setRange(_length, _length + input.length, input);
    _length += input.length;
  }

  Float32List _drain(bool flushing) {
    // Output n sits at input time n * inRate / outRate; integer arithmetic
    // keeps the position exact however long the stream runs.
    final limit = flushing
        ? (_received * outRate + inRate - 1) ~/ inRate
        : null;
    // At most one output per input step, plus one for rounding.
    final out = Float32List(_length * outRate ~/ inRate + 2);
    var count = 0;
    while (true) {
      if (limit != null && _produced >= limit) break;
      final num = _produced * inRate;
      final whole = num ~/ outRate;
      final frac = (num % outRate) / outRate;
      // Needs input up to whole + _halfWidth.
      if (whole + _halfWidth >= _base + _length) break;
      out[count++] = _sample(whole - _base, frac);
      _produced++;
    }

    // Drop input no future output reaches back to.
    final nextWhole = (_produced * inRate) ~/ outRate;
    final keepFrom = nextWhole - _halfWidth + 1 - _base;
    if (keepFrom > 0) {
      final drop = math.min(keepFrom, _length);
      _history.setRange(0, _length - drop, _history, drop);
      _length -= drop;
      _base += drop;
    }
    return Float32List.sublistView(out, 0, count);
  }

  /// The band-limited input at `index + frac`, where `index` is into
  /// `_history`.
  double _sample(int index, double frac) {
    var sum = 0.0;
    // Taps left of the instant: distances frac, frac + 1, ...
    for (var k = 0; k < _halfWidth; k++) {
      sum += _history[index - k] * _kernel(frac + k);
    }
    // Taps right of it: distances 1 - frac, 2 - frac, ...
    for (var k = 1; k <= _halfWidth; k++) {
      sum += _history[index + k] * _kernel(k - frac);
    }
    return sum;
  }

  double _kernel(double distance) {
    final pos = distance * _density;
    final i = pos.floor();
    if (i + 1 >= _table.length) return 0;
    final t = pos - i;
    return _table[i] + (_table[i + 1] - _table[i]) * t;
  }

  static Float32List _buildTable(double cutoff, int halfWidth) {
    final n = halfWidth * _density + 2;
    final table = Float32List(n);
    final i0Beta = _besselI0(_beta);
    for (var i = 0; i < n; i++) {
      final x = i / _density;
      final r = x / halfWidth;
      if (r >= 1) break;
      final window = _besselI0(_beta * math.sqrt(1 - r * r)) / i0Beta;
      final u = 2 * cutoff * x;
      final sinc = u == 0 ? 1.0 : math.sin(math.pi * u) / (math.pi * u);
      table[i] = 2 * cutoff * sinc * window;
    }
    return table;
  }

  static double _besselI0(double x) {
    var sum = 1.0;
    var term = 1.0;
    final q = x * x / 4;
    for (var k = 1; k < 50; k++) {
      term *= q / (k * k);
      sum += term;
      if (term < 1e-12 * sum) break;
    }
    return sum;
  }
}
