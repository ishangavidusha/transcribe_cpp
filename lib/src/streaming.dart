import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'engine.dart';
import 'library.dart';
import 'native_string.dart';
import 'status.dart';
import 'transcript.dart';

/// When the UI-facing committed text is allowed to grow.
enum CommitPolicy {
  /// Whatever stable-prefix implementation the model family selects.
  auto(0),

  /// Nothing commits until `finalize`; everything is tentative until then.
  onFinalize(1),

  /// Commit only a prefix that repeated hypotheses agree on.
  stablePrefix(2);

  const CommitPolicy(this.code);
  final int code;
}

/// An active streaming transcription.
///
/// The stream holds the model's compute lease until [finalize], [reset], or
/// [dispose]; other runs or streams on the same model fail while it is open.
class TranscribeStream {
  TranscribeStream._(this._session);

  final Session _session;
  bool _closed = false;

  Pointer<transcribe_session> get _ptr => _session.pointer;

  /// Begins a stream on [session].
  static TranscribeStream begin(
    Session session, {
    CommitPolicy commitPolicy = CommitPolicy.auto,

    /// How many consecutive hypotheses must agree on a prefix before it is
    /// committed. 0 uses the engine default (3). Higher means later but safer
    /// commits.
    int stablePrefixAgreementN = 0,
  }) {
    using((arena) {
      // stream_begin takes BOTH the ordinary run params (timestamps, pnc,
      // itn, language — same knobs as a one-shot run) and the streaming-only
      // params. Defaults for the former; the caller tunes the latter.
      final runParams = arena<transcribe_run_params>();
      bindings.transcribe_run_params_init(runParams);

      final params = arena<transcribe_stream_params>();
      bindings.transcribe_stream_params_init(params);
      params.ref.commit_policyAsInt = commitPolicy.code;
      params.ref.stable_prefix_agreement_n = stablePrefixAgreementN;

      _checkStream(
        bindings.transcribe_stream_begin(session.pointer, runParams, params),
        'transcribe_stream_begin',
      );
    });
    return TranscribeStream._(session);
  }

  /// Feeds one frame of mono float32 16 kHz audio.
  ///
  /// Frame size is a latency/throughput knob, not a correctness one — the
  /// engine buffers internally. Families publish a natural cadence
  /// (moonshine_streaming wants roughly 80 ms).
  StreamUpdate feed(Float32List frame) {
    _assertOpen();
    if (frame.isEmpty) {
      throw ArgumentError.value(frame, 'frame', 'must contain samples');
    }

    final buffer = malloc<Float>(frame.length);
    try {
      buffer.asTypedList(frame.length).setAll(0, frame);
      return using((arena) {
        final update = arena<transcribe_stream_update>();
        bindings.transcribe_stream_update_init(update);
        _checkStream(
          bindings.transcribe_stream_feed(_ptr, buffer, frame.length, update),
          'transcribe_stream_feed',
        );
        return _mapUpdate(update.ref);
      });
    } finally {
      malloc.free(buffer);
    }
  }

  /// Drains the stream and produces the final result.
  StreamUpdate finalize() {
    _assertOpen();
    _closed = true;
    return using((arena) {
      final update = arena<transcribe_stream_update>();
      bindings.transcribe_stream_update_init(update);
      _checkStream(
        bindings.transcribe_stream_finalize(_ptr, update),
        'transcribe_stream_finalize',
      );
      return _mapUpdate(update.ref);
    });
  }

  /// The current committed / tentative / raw text view.
  StreamText get text {
    return using((arena) {
      final out = arena<transcribe_stream_text>();
      bindings.transcribe_stream_text_init(out);
      _checkStream(
        bindings.transcribe_stream_get_text(_ptr, out),
        'transcribe_stream_get_text',
      );
      return StreamText(
        full: _utf8(out.ref.full_text, out.ref.full_text_bytes),
        committed: _utf8(out.ref.committed_text, out.ref.committed_text_bytes),
        tentative: _utf8(out.ref.tentative_text, out.ref.tentative_text_bytes),
      );
    });
  }

  /// The full structured snapshot (segments, words, tokens, language).
  Transcript get snapshot => _session.readTranscript();

  int get revision => bindings.transcribe_stream_revision(_ptr);

  /// Abandons the stream and releases the model's compute lease.
  void dispose() {
    if (_closed) return;
    _closed = true;
    bindings.transcribe_stream_reset(_ptr);
  }

  void _assertOpen() {
    if (_closed) throw StateError('Stream is already finalized or disposed');
  }

  static String _utf8(Pointer<Char> p, int bytes) {
    if (bytes == 0) return '';
    return decodeNativeText(p, length: bytes);
  }

  static StreamUpdate _mapUpdate(transcribe_stream_update u) => StreamUpdate(
    resultChanged: u.result_changed,
    isFinal: u.is_final,
    revision: u.revision,
    inputReceivedMs: u.input_received_ms,
    audioCommittedMs: u.audio_committed_ms,
    bufferedMs: u.buffered_ms,
    committedChanged: u.committed_changed,
    tentativeChanged: u.tentative_changed,
  );
}

void _checkStream(transcribe_status s, String context) {
  if (s == transcribe_status.TRANSCRIBE_OK) return;
  final status = TranscribeStatus.fromCode(s.value);
  final msg = bindings.transcribe_status_string(s.value);
  throw TranscribeException(
    status,
    msg == nullptr ? 'unknown' : msg.cast<Utf8>().toDartString(),
    context: context,
  );
}
