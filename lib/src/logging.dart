import 'dart:ffi';

import 'bindings.g.dart';
import 'library.dart';

/// Controls what the engine and ggml print.
///
/// Left alone, every launch opens with a wall of backend-registration and
/// Metal-initialisation chatter that buries anything worth reading. The engine
/// offers one global sink for all of it, so the choice is all, nothing, or a
/// filter — and the filter has to be native code: the sink fires on ggml worker
/// threads and its message pointer is only valid for the duration of the call,
/// which rules out every asynchronous Dart callback.
///
/// The engine asks that this be installed once, at process startup, before any
/// model is loaded. Later calls are not a supported configuration.
class NativeLog {
  NativeLog._();

  static bool _installed = false;

  /// Silences everything below a warning.
  ///
  /// Nothing useful is lost. The one genuinely important launch-time fact —
  /// whether the model ended up on the GPU — is available as [ModelInfo] and
  /// should be read there rather than grepped out of the console, and failures
  /// arrive as exceptions carrying their own messages.
  ///
  /// [verbose] restores the informational messages, which is the setting to use
  /// when the engine itself is the suspect.
  ///
  /// Returns false if the engine image could not be reached, which is not worth
  /// treating as fatal — it only means the app starts noisy.
  static bool quiet({bool verbose = false}) {
    if (_installed) return true;
    const warn = 2, error = 3, info = 1, debug = 4;
    var mask = (1 << warn) | (1 << error);
    if (verbose) mask |= (1 << info) | (1 << debug);
    try {
      bindings.transcribe_log_set(
        lookupNative<NativeFunction<transcribe_log_callbackFunction>>(
          'tcshim_log_cb',
        ),
        Pointer<Void>.fromAddress(mask),
      );
      _installed = true;
      return true;
    } on Object {
      return false;
    }
  }

  /// Drops every message, warnings included.
  static bool silence() {
    try {
      bindings.transcribe_log_set(nullptr, nullptr);
      _installed = true;
      return true;
    } on Object {
      return false;
    }
  }
}
