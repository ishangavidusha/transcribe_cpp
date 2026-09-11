import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'library.dart';

/// Reads captured audio out of the native ring the microphone tap writes into.
///
/// Attaches to a ring the platform side already created, by address — the
/// integer that `start` returns. Nothing here owns the ring or frees it; the
/// native capture object outlives every reader.
///
/// Deliberately attachable from any isolate: the address is a plain integer, so
/// the reader can live on a worker isolate that never touches the UI. That is
/// the point of a ring rather than a platform channel — audio arrives without
/// the UI isolate's scheduling in the path.
class AudioRingReader {
  AudioRingReader.attach(int address, {int scratchFrames = 16000})
    : _ring = Pointer<audio_ring>.fromAddress(address),
      _capacity = scratchFrames {
    if (address == 0) {
      throw ArgumentError.value(address, 'address', 'not a valid ring');
    }
    _scratch = malloc<Float>(scratchFrames);
    _view = _scratch.asTypedList(scratchFrames);
  }

  final Pointer<audio_ring> _ring;
  final int _capacity;
  late final Pointer<Float> _scratch;
  late final Float32List _view;
  bool _freed = false;

  /// Frames waiting to be read. A lower bound — the tap may add more between
  /// this call and the next.
  int get available => bindings.audio_ring_available(_ring);

  /// Frames the capture layer has discarded because this reader fell a whole
  /// buffer behind.
  ///
  /// Poll it on every drain and compare with the previous value. A change means
  /// the audio has a hole in it, so anything carrying state across samples —
  /// the VAD's LSTM, the endpointer's utterance in progress — is now reasoning
  /// about audio that is not contiguous, and must be reset rather than fed
  /// across the seam.
  int get dropped => bindings.audio_ring_dropped(_ring);

  /// Reads whatever is available, up to the scratch capacity. Returns an empty
  /// list when the ring is empty; the returned list is a fresh copy the caller
  /// owns.
  Float32List read() {
    if (_freed) throw StateError('AudioRingReader has been disposed');
    final got = bindings.audio_ring_read(_ring, _scratch, _capacity);
    if (got == 0) return Float32List(0);
    return Float32List.fromList(Float32List.sublistView(_view, 0, got));
  }

  void dispose() {
    if (_freed) return;
    _freed = true;
    malloc.free(_scratch);
  }
}
