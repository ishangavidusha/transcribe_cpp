/// Mirrors `transcribe_status` in `include/transcribe.h`.
///
/// Kept as a hand-written enum rather than reusing the generated integer
/// constants so callers can `switch` exhaustively and so the doc comments
/// travel with the values.
enum TranscribeStatus {
  ok(0),
  invalidArg(1),
  notImplemented(2),
  fileNotFound(3),
  gguf(4),
  unsupportedArch(5),
  unsupportedVariant(6),
  outOfMemory(7),
  backend(8),
  sampleRate(9),
  unsupportedLanguage(10),
  unsupportedTask(11),
  unsupportedTimestamps(12),

  /// The abort callback returned true. Partial results are still readable.
  aborted(13),
  badStructSize(14),
  unsupportedPnc(15),
  unsupportedItn(16),

  /// Audio is longer than the model can decode in one pass. Rejected up front.
  inputTooLong(17),

  /// Decode hit the context budget before end-of-stream. The partial
  /// transcript is preserved and readable.
  outputTruncated(18);

  const TranscribeStatus(this.code);

  final int code;

  static TranscribeStatus fromCode(int code) {
    for (final s in TranscribeStatus.values) {
      if (s.code == code) return s;
    }
    return TranscribeStatus.invalidArg;
  }

  /// True for the two statuses that are errors but still leave a usable
  /// partial transcript on the session.
  bool get hasPartialResult =>
      this == TranscribeStatus.aborted ||
      this == TranscribeStatus.outputTruncated;
}

/// Thrown for any non-OK status from the native library.
class TranscribeException implements Exception {
  TranscribeException(this.status, this.message, {this.context});

  final TranscribeStatus status;

  /// `transcribe_status_string()` for the code — the library's own wording.
  final String message;

  /// Which call failed, for example `transcribe_model_load_file`.
  final String? context;

  @override
  String toString() {
    final where = context == null ? '' : ' in $context';
    return 'TranscribeException($status)$where: $message';
  }
}
