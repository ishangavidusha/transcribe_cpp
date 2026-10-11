import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcribe_cpp/src/vad.dart';
import 'package:transcribe_cpp/src/wav.dart';

Float32List _tone(int samples) => Float32List.fromList([
  for (var i = 0; i < samples; i++)
    0.4 * math.sin(2 * math.pi * 220 * i / vadSampleRate),
]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wav_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('Wav', () {
    test('round-trips samples exactly', () {
      // Exactness is the point of writing float. A recording exists to be
      // measured under several settings, and any loss in the file format would
      // sit underneath every comparison made with it.
      final path = '${dir.path}/tone.wav';
      final original = _tone(vadSampleRate);
      WavSink.open(path)
        ..add(original)
        ..close();

      final read = Wav.read(path);
      expect(read.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(read[i], original[i]);
      }
    });

    test('appends across many writes, as a live session does', () {
      final path = '${dir.path}/streamed.wav';
      final sink = WavSink.open(path);
      final chunks = [for (var i = 0; i < 40; i++) _tone(256)];
      for (final c in chunks) {
        sink.add(c);
      }
      expect(sink.duration.inMilliseconds, 640);
      sink.close();

      expect(Wav.read(path).length, 40 * 256);
    });

    test('reads 16-bit PCM too', () {
      // So a clip from anywhere else can be replayed, not only our own
      // recordings.
      final path = '${dir.path}/pcm16.wav';
      final samples = _tone(1024);
      final bytes = BytesBuilder();
      void u32(int v) => bytes.add(
        Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little),
      );
      void u16(int v) => bytes.add(
        Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little),
      );
      bytes.add('RIFF'.codeUnits);
      u32(36 + samples.length * 2);
      bytes.add('WAVE'.codeUnits);
      bytes.add('fmt '.codeUnits);
      u32(16);
      u16(1);
      u16(1);
      u32(vadSampleRate);
      u32(vadSampleRate * 2);
      u16(2);
      u16(16);
      bytes.add('data'.codeUnits);
      u32(samples.length * 2);
      final pcm = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        pcm.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
      }
      bytes.add(pcm.buffer.asUint8List());
      File(path).writeAsBytesSync(bytes.toBytes());

      final read = Wav.read(path);
      expect(read.length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        expect(read[i], closeTo(samples[i], 1 / 32767));
      }
    });

    test('refuses audio the models cannot use', () {
      // Rather than resampling or downmixing quietly. A clip at the wrong rate
      // would otherwise replay at the wrong speed and be scored as a model
      // failure.
      final path = '${dir.path}/wrong.wav';
      final bytes = BytesBuilder();
      void u32(int v) => bytes.add(
        Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little),
      );
      void u16(int v) => bytes.add(
        Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little),
      );
      bytes.add('RIFF'.codeUnits);
      u32(36);
      bytes.add('WAVE'.codeUnits);
      bytes.add('fmt '.codeUnits);
      u32(16);
      u16(1);
      u16(2); // stereo
      u32(44100);
      u32(44100 * 4);
      u16(4);
      u16(16);
      bytes.add('data'.codeUnits);
      u32(0);
      File(path).writeAsBytesSync(bytes.toBytes());

      expect(() => Wav.read(path), throwsA(isA<FormatException>()));
    });

    test('a file left unclosed still holds its audio', () {
      // The crash case. Sizes are patched on close, so an interrupted session
      // leaves a header claiming nothing — but the samples are on disk, and
      // saying so beats pretending the recording is gone.
      final path = '${dir.path}/truncated.wav';
      WavSink.open(path).add(_tone(4096));
      final size = File(path).lengthSync();
      expect(size, greaterThan(4096 * 4));
      expect(Wav.read(path), isEmpty);
    });
  });
}
