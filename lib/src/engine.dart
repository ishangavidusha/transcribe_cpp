import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'library.dart';
import 'native_string.dart';
import 'status.dart';
import 'transcript.dart';

/// Reads a borrowed `const char *` into an owned Dart string.
///
/// Every text pointer transcribe.cpp returns is session-owned and dies on the
/// next run/feed, so this copy is not an optimisation to skip.
String _str(Pointer<Char> p) => decodeNativeText(p);

String? _strOrNull(Pointer<Char> p) =>
    p == nullptr ? null : decodeNativeText(p);

void _check(transcribe_status s, String context) {
  if (s == transcribe_status.TRANSCRIBE_OK) return;
  final status = TranscribeStatus.fromCode(s.value);
  final msg = _str(bindings.transcribe_status_string(s.value));
  throw TranscribeException(status, msg, context: context);
}

/// The engine's version string, e.g. `0.2.2`.
String get nativeVersion => _str(bindings.transcribe_version());

/// A loaded model. Cheap to keep around, expensive to create.
///
/// Concurrency, straight from the engine's contract: a model is shareable, but
/// in 0.x compute is *serialised per model*, so concurrent runs queue behind
/// one another. For real parallelism, load one [Model] per worker.
class Model {
  Model._(this._ptr);

  final Pointer<transcribe_model> _ptr;
  bool _freed = false;

  Pointer<transcribe_model> get pointer {
    if (_freed) throw StateError('Model has been freed');
    return _ptr;
  }

  /// Loads a GGUF from disk. Blocking — call this on a worker isolate.
  static Model load(String path) {
    return using((arena) {
      final params = arena<transcribe_model_load_params>();
      bindings.transcribe_model_load_params_init(params);

      final out = arena<Pointer<transcribe_model>>();
      _check(
        bindings.transcribe_model_load_file(
          path.toNativeUtf8(allocator: arena).cast<Char>(),
          params,
          out,
        ),
        'transcribe_model_load_file',
      );
      return Model._(out.value);
    });
  }

  /// Which ggml backend the model actually resolved to, e.g. `MTL0` for Metal
  /// or `CPU0`. Worth logging on device — it is the fastest way to catch a
  /// build that silently fell back to CPU.
  String get backend => _str(bindings.transcribe_model_backend(_ptr));

  String get architecture => _str(bindings.transcribe_model_arch_string(_ptr));

  String get variant => _str(bindings.transcribe_model_variant_string(_ptr));

  Session createSession({int threads = 0}) {
    return using((arena) {
      final params = arena<transcribe_session_params>();
      bindings.transcribe_session_params_init(params);
      params.ref.n_threads = threads;

      final out = arena<Pointer<transcribe_session>>();
      _check(
        bindings.transcribe_session_init(pointer, params, out),
        'transcribe_session_init',
      );
      return Session._(out.value);
    });
  }

  void dispose() {
    if (_freed) return;
    _freed = true;
    bindings.transcribe_model_free(_ptr);
  }
}

/// A single-threaded transcription context bound to a [Model].
///
/// Use one session from one thread at a time — this is the engine's rule, not
/// a Dart one.
class Session {
  Session._(this._ptr);

  final Pointer<transcribe_session> _ptr;
  bool _freed = false;

  Pointer<transcribe_session> get pointer {
    if (_freed) throw StateError('Session has been freed');
    return _ptr;
  }

  /// Transcribes one clip. Blocking.
  ///
  /// [pcm] must be mono float32 at 16 kHz in [-1, 1]. The engine links no
  /// resampler by design, so converting the microphone's native rate is the
  /// caller's job.
  ///
  /// A truncated or aborted run still returns a [Transcript]: those two
  /// statuses preserve partial output, and the corresponding flags are set on
  /// the result rather than thrown. Every other non-OK status throws.
  Transcript run(Float32List pcm) {
    if (pcm.isEmpty) {
      throw ArgumentError.value(pcm, 'pcm', 'must contain at least one sample');
    }

    final buffer = malloc<Float>(pcm.length);
    try {
      buffer.asTypedList(pcm.length).setAll(0, pcm);

      final status = using((arena) {
        final params = arena<transcribe_run_params>();
        bindings.transcribe_run_params_init(params);
        return bindings.transcribe_run(pointer, buffer, pcm.length, params);
      });

      final mapped = TranscribeStatus.fromCode(status.value);
      if (status != transcribe_status.TRANSCRIBE_OK &&
          !mapped.hasPartialResult) {
        _check(status, 'transcribe_run');
      }
      return readTranscript();
    } finally {
      malloc.free(buffer);
    }
  }

  /// Copies the session's current result into owned Dart objects.
  Transcript readTranscript() {
    final segments = <Segment>[];
    final words = <Word>[];
    final tokens = <Token>[];

    using((arena) {
      final seg = arena<transcribe_segment>();
      for (var i = 0; i < bindings.transcribe_n_segments(pointer); i++) {
        bindings.transcribe_segment_init(seg);
        _check(
          bindings.transcribe_get_segment(pointer, i, seg),
          'transcribe_get_segment',
        );
        if (seg.ref.text == nullptr) continue;
        segments.add(
          Segment(
            startMs: seg.ref.t0_ms,
            endMs: seg.ref.t1_ms,
            text: _str(seg.ref.text),
            speakerId: seg.ref.speaker_id,
          ),
        );
      }

      final word = arena<transcribe_word>();
      for (var i = 0; i < bindings.transcribe_n_words(pointer); i++) {
        bindings.transcribe_word_init(word);
        _check(
          bindings.transcribe_get_word(pointer, i, word),
          'transcribe_get_word',
        );
        if (word.ref.text == nullptr) continue;
        words.add(
          Word(
            startMs: word.ref.t0_ms,
            endMs: word.ref.t1_ms,
            text: _str(word.ref.text),
            segmentIndex: word.ref.seg_index,
          ),
        );
      }

      final tok = arena<transcribe_token>();
      for (var i = 0; i < bindings.transcribe_n_tokens(pointer); i++) {
        bindings.transcribe_token_init(tok);
        _check(
          bindings.transcribe_get_token(pointer, i, tok),
          'transcribe_get_token',
        );
        if (tok.ref.text == nullptr) continue;
        tokens.add(
          Token(
            id: tok.ref.id,
            probability: tok.ref.p,
            startMs: tok.ref.t0_ms,
            endMs: tok.ref.t1_ms,
            text: _str(tok.ref.text),
          ),
        );
      }
    });

    return Transcript(
      text: _str(bindings.transcribe_full_text(pointer)),
      segments: segments,
      words: words,
      tokens: tokens,
      detectedLanguage: _strOrNull(
        bindings.transcribe_detected_language(pointer),
      ),
      wasTruncated: bindings.transcribe_was_truncated(pointer),
      wasAborted: bindings.transcribe_was_aborted(pointer),
    );
  }

  void dispose() {
    if (_freed) return;
    _freed = true;
    bindings.transcribe_session_free(_ptr);
  }
}
