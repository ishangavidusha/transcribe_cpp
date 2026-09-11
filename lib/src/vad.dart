import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'bindings.g.dart';
import 'library.dart';

/// The only sample rate the VAD is trained for.
const int vadSampleRate = 16000;

/// New samples consumed per [VadModel.process] call — 32 ms at 16 kHz.
///
/// This is fixed by the network, not a tuning knob. Silero v5+ also feeds the
/// previous window's last 64 samples back in as context, but that carry is
/// internal: callers hand over exactly [vadWindowSamples] new samples each time.
const int vadWindowSamples = 512;

/// The speech-probability source an [Endpointer] runs on.
///
/// Exists so the endpointing state machine can be tested against a scripted
/// probability sequence without loading native code — the state machine and the
/// network are independently wrong in different ways, and separating them keeps
/// a failure in one from being debugged as the other.
abstract interface class VadModel {
  /// Speech probability in [0, 1] for the [vadWindowSamples] samples starting
  /// at [offset]. Advances internal state, so windows must arrive in order.
  double process(Float32List samples, {int offset});

  /// Clears carried state. Call between unrelated streams.
  void reset();
}

/// Silero VAD v5/v6, running through this package's C implementation.
///
/// Cheap enough to ignore: about 0.26 ms per 32 ms window on an A14, or 0.8% of
/// one core. There is no reason to run this anywhere but inline with capture.
///
/// Not thread-safe and not isolate-shareable — one instance is one stream of
/// audio with carried state. Construct one per stream, on the isolate that will
/// feed it.
class SileroVad implements VadModel {
  SileroVad._(this._ptr) {
    _window = malloc<Float>(vadWindowSamples);
    _windowView = _window.asTypedList(vadWindowSamples);
  }

  final Pointer<silero_vad> _ptr;

  /// Reused across calls. At ~31 windows/second a fresh allocation per window
  /// would be pure churn.
  late final Pointer<Float> _window;
  late final Float32List _windowView;

  bool _freed = false;

  /// Loads the weight blob produced by `tool/extract_silero_weights.py`.
  ///
  /// [weights] is copied into native memory by the C side, so the caller may
  /// drop it immediately. Pass the bytes rather than a path when the weights
  /// ship as an app asset — see [loadBundledWeights].
  factory SileroVad.fromBytes(Uint8List weights) {
    final buffer = malloc<Uint8>(weights.length);
    try {
      buffer.asTypedList(weights.length).setAll(0, weights);
      final ptr = bindings.silero_vad_create_from_memory(
        buffer.cast<Void>(),
        weights.length,
      );
      if (ptr == nullptr) throw StateError('silero_vad: ${_lastError()}');
      return SileroVad._(ptr);
    } finally {
      malloc.free(buffer);
    }
  }

  /// Loads the weight blob from disk.
  factory SileroVad.fromFile(String path) {
    return using((arena) {
      final ptr = bindings.silero_vad_create(
        path.toNativeUtf8(allocator: arena).cast<Char>(),
      );
      if (ptr == nullptr) throw StateError('silero_vad: ${_lastError()}');
      return SileroVad._(ptr);
    });
  }

  /// Reads the weights this package ships as a Flutter asset.
  ///
  /// The `packages/` prefix is how Flutter addresses an asset that lives in a
  /// dependency rather than the app — it is not optional.
  static Future<Uint8List> loadBundledWeights() async {
    final data = await rootBundle.load(
      'packages/transcribe_cpp/assets/silero_vad.bin',
    );
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static String _lastError() {
    final p = bindings.silero_vad_last_error();
    return p == nullptr ? 'unknown error' : p.cast<Utf8>().toDartString();
  }

  @override
  double process(Float32List samples, {int offset = 0}) {
    if (_freed) throw StateError('SileroVad has been disposed');
    if (offset < 0 || offset + vadWindowSamples > samples.length) {
      throw RangeError(
        'process needs $vadWindowSamples samples at offset $offset, '
        'but the buffer holds ${samples.length}',
      );
    }
    _windowView.setRange(0, vadWindowSamples, samples, offset);
    return bindings.silero_vad_process(_ptr, _window);
  }

  @override
  void reset() {
    if (_freed) throw StateError('SileroVad has been disposed');
    bindings.silero_vad_reset(_ptr);
  }

  void dispose() {
    if (_freed) return;
    _freed = true;
    bindings.silero_vad_free(_ptr);
    malloc.free(_window);
  }
}
