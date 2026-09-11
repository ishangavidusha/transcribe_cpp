import 'dart:io';
import 'dart:typed_data';

import 'vad.dart';

/// Minimal WAV support, for capturing a session and replaying it.
///
/// Deliberately narrow: mono, at [vadSampleRate], reading 16-bit PCM or 32-bit
/// float and writing only float. That is the whole of what this package needs,
/// and a general audio codec is not something a transcription plugin should
/// grow on the side.
///
/// Float rather than 16-bit PCM on the write side because these recordings
/// exist to be measured, not listened to. The gain stage in front of the models
/// works on audio around -38 dBFS and boosts it as much as twentyfold; going
/// through 16-bit would leave the question of whether a difference between two
/// runs came from the setting under test or from the file format, and that is
/// exactly the doubt a controlled comparison is supposed to remove.
class Wav {
  Wav._();

  static const _headerBytes = 58;

  /// Reads a mono WAV into float32 samples in [-1, 1].
  ///
  /// Throws if the file is not mono, not [vadSampleRate], or not one of the two
  /// supported sample formats — silently resampling or downmixing here would
  /// hide exactly the mistakes worth catching.
  static Float32List read(String path) {
    final bytes = File(path).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') {
      throw FormatException('$path is not a RIFF file');
    }

    var format = 0;
    var channels = 0;
    var rate = 0;
    var bits = 0;
    var offset = 12;

    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;

      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (channels != 1) {
          throw FormatException('$path has $channels channels; mono required');
        }
        if (rate != vadSampleRate) {
          throw FormatException(
            '$path is $rate Hz; the models need $vadSampleRate Hz and this '
            'package links no resampler',
          );
        }
        return _decode(data, body, size, format, bits, path);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw FormatException('$path has no data chunk');
  }

  static Float32List _decode(
    ByteData data,
    int start,
    int size,
    int format,
    int bits,
    String path,
  ) {
    if (format == 3 && bits == 32) {
      final count = size ~/ 4;
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = data.getFloat32(start + i * 4, Endian.little);
      }
      return out;
    }
    if (format == 1 && bits == 16) {
      final count = size ~/ 2;
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = data.getInt16(start + i * 2, Endian.little) / 32768.0;
      }
      return out;
    }
    throw FormatException(
      '$path is format $format/$bits-bit; only 32-bit float and 16-bit PCM '
      'are supported',
    );
  }

  static Uint8List _header(int sampleRate, int dataBytes) {
    final header = ByteData(_headerBytes);
    var at = 0;
    void tag(String s) {
      for (final c in s.codeUnits) {
        header.setUint8(at++, c);
      }
    }

    void u32(int v) {
      header.setUint32(at, v, Endian.little);
      at += 4;
    }

    void u16(int v) {
      header.setUint16(at, v, Endian.little);
      at += 2;
    }

    tag('RIFF');
    u32(_headerBytes - 8 + dataBytes);
    tag('WAVE');
    // An 18-byte fmt chunk with the trailing cbSize, plus a fact chunk. Both
    // are required by the spec for non-PCM formats, and readers that enforce it
    // reject the bare 16-byte header some tools emit.
    tag('fmt ');
    u32(18);
    u16(3); // IEEE float
    u16(1); // mono
    u32(sampleRate);
    u32(sampleRate * 4); // byte rate
    u16(4); // block align
    u16(32); // bits per sample
    u16(0); // cbSize
    tag('fact');
    u32(4);
    u32(dataBytes ~/ 4); // sample frames
    tag('data');
    u32(dataBytes);
    return header.buffer.asUint8List();
  }
}

/// Appends float32 audio to a WAV file as a session runs.
///
/// Sizes are patched on [close], so a recording interrupted by a crash leaves a
/// file whose header claims zero samples. The audio is all there; only the
/// lengths are wrong.
class WavSink {
  WavSink.open(String path, {this.sampleRate = vadSampleRate})
    : _file = File(path).openSync(mode: FileMode.write) {
    _file.writeFromSync(Wav._header(sampleRate, 0));
  }

  final RandomAccessFile _file;
  final int sampleRate;
  int _bytes = 0;
  bool _closed = false;

  Duration get duration =>
      Duration(microseconds: (_bytes ~/ 4) * 1000000 ~/ sampleRate);

  void add(Float32List samples) {
    if (_closed) return;
    final bytes = ByteData(samples.length * 4);
    for (var i = 0; i < samples.length; i++) {
      bytes.setFloat32(i * 4, samples[i], Endian.little);
    }
    _file.writeFromSync(bytes.buffer.asUint8List());
    _bytes += bytes.lengthInBytes;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _file.setPositionSync(0);
    _file.writeFromSync(Wav._header(sampleRate, _bytes));
    _file.closeSync();
  }
}
