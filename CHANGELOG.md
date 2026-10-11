# Changelog

All notable changes to this package are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); while the version
is below `1.0.0`, a `0.x.0` bump may break the API and a `0.x.y` bump may not.

## 0.0.1 — unreleased

Not yet published to pub.dev. The public API is still being shaped and every
export should be treated as unstable.

### Added

- Dart FFI bindings to transcribe.cpp 0.3.1 (ggml/GGUF), with the engine
  shipped as a prebuilt dynamic xcframework and Metal acceleration on iOS.
- Batch and streaming transcription on a helper isolate, so decoding never
  blocks the UI isolate.
- Microphone capture on iOS over `AVAudioEngine`, surviving route changes,
  interruptions and media-services resets. Audio reaches Dart through a
  lock-free ring read over FFI, never across a method channel.
- Voice activity detection: a from-scratch port of Silero VAD in C, with the
  16 kHz weights bundled as an asset (~1.2 MB), so endpointing needs no second
  inference runtime.
- Hands-free endpointing with hysteresis, minimum speech duration, hangover,
  and pre/post-roll.
- `StablePrefix`, a LocalAgreement-2 stable-prefix policy, so live text can be
  shown before an utterance closes without it flickering as it is revised.
- `SeamJoiner`, which removes the duplicated words an overlap-carrying
  truncation boundary would otherwise emit.
- `AudioNormalizer`, a gain stage targeting a fixed RMS with peak and noise
  ceilings.
- `Live<T>`, a state primitive that is both a `ValueListenable` and a `Stream`
  replaying its current value to each new subscriber.
- `ModelCatalog`, the transcription models transcribe.cpp publishes at 1 GB or
  less (58 models, 223 files), generated from the catalogue of the engine
  release the package links. Each `ModelDescriptor` carries the file's size,
  SHA-256 and a commit-pinned download URL. Apps can add their own entries;
  `available` hides any whose family the linked engine cannot load.
- `Replay`, which drives the pipeline from a recorded WAV so two configurations
  can be compared over identical audio.
