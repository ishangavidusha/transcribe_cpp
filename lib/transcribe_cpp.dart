/// Offline, on-device speech-to-text for Flutter, over
/// [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), a
/// ggml/GGUF speech engine, with Metal acceleration on iOS.
///
/// Two entry points. [ModelManager] downloads and verifies a model when the
/// app asks for one; [TranscribeSession] loads it and turns the microphone
/// into text, endpointing speech hands-free.
///
/// An app with its own audio stack can skip the microphone:
/// [TranscribeSession.transcribeStream] runs the same endpointing and live
/// text over audio the app pushes, and [TranscribeSession.transcribe] decodes
/// a single clip. Both take any rate and channel count ([AudioFormat]).
/// Audio handed to [TranscribeSession.replay] must already be mono float32
/// at [TranscribeSession.sampleRate] (16 kHz), with samples in `[-1, 1]`.
library;

export 'src/audio_format.dart' show AudioFormat, SampleFormat;
export 'src/capture.dart' show CaptureState, CaptureStatus;
export 'src/catalog.dart' show ModelCatalog, ModelDescriptor, ModelId;
export 'src/endpointer.dart'
    show
        EndpointerConfig,
        EndpointerEvent,
        SpeechDiscarded,
        SpeechEnded,
        SpeechStarted,
        Utterance;
export 'src/live.dart' show Live;
export 'src/logging.dart' show NativeLog;
export 'src/model_download.dart'
    show
        CancelToken,
        DownloadCancelledException,
        DownloadProgress,
        ModelDownloadException;
export 'src/model_manager.dart' show InstalledModel, ModelManager, ModelStatus;
export 'src/model_store.dart'
    show InsufficientStorageException, ModelIntegrityException;
export 'src/normalizer.dart' show NormalizerConfig;
export 'src/pipeline.dart' show UtteranceResult;
export 'src/reader.dart' show Dropout, LiveLevel;
export 'src/session.dart' show LiveText, SessionState, TranscribeSession;
export 'src/status.dart' show TranscribeStatus, TranscribeException;
export 'src/transcript.dart' show ModelInfo, Segment, Token, Transcript, Word;
export 'src/wav.dart' show Wav;
