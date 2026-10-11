/// Offline, on-device speech-to-text for Flutter.
///
/// Dart FFI bindings to [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp),
/// a ggml/GGUF speech-to-text engine, with Metal acceleration on iOS.
///
/// Audio in must be **mono float32 at 16 kHz** in [-1, 1]. The engine links no
/// resampler by design, so capture and rate conversion belong to the caller.
library;

export 'src/capture.dart'
    show CaptureHandle, CaptureState, CaptureStatus, MicrophoneCapture;
export 'src/catalog.dart' show ModelCatalog, ModelDescriptor, ModelId;
export 'src/dictation.dart' show Dictation;
export 'src/endpointer.dart'
    show
        Endpointer,
        EndpointerConfig,
        EndpointerEvent,
        SpeechDiscarded,
        SpeechEnded,
        SpeechStarted,
        Utterance;
export 'src/engine.dart' show nativeVersion;
export 'src/live.dart' show Live, LiveController;
export 'src/logging.dart' show NativeLog;
export 'src/normalizer.dart' show AudioNormalizer, NormalizerConfig;
export 'src/pipeline.dart'
    show UtteranceDecoder, UtteranceResult, UtteranceTranscriber, VoicePipeline;
export 'src/reader.dart' show Dropout, LiveLevel;
export 'src/replay.dart' show Replay;
export 'src/ring.dart' show AudioRingReader;
export 'src/seam.dart' show SeamJoiner;
export 'src/stable_prefix.dart' show StablePrefix;
export 'src/status.dart' show TranscribeStatus, TranscribeException;
export 'src/streaming.dart' show CommitPolicy;
export 'src/transcript.dart'
    show ModelInfo, Segment, StreamText, StreamUpdate, Token, Transcript, Word;
export 'src/wav.dart' show Wav, WavSink;
export 'src/vad.dart' show SileroVad, VadModel, vadSampleRate, vadWindowSamples;
export 'src/worker.dart' show StreamingSession, Transcriber;
