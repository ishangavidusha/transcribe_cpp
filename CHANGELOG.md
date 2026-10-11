# Changelog

All notable changes to this package are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); while the version
is below `1.0.0`, a `0.x.0` bump may break the API and a `0.x.y` bump may not.

## 0.0.1 — unreleased

Not yet published to pub.dev. The public API is still being shaped and every
export should be treated as unstable.

### Added

- `TranscribeSession`, the entry point for transcription: open it on an
  installed model, then `start()` and `stop()` the microphone any number of
  times. `state`, `text` (settled and interim), `level` and `capture` are
  `Live` values; `utterances`, `events` and `dropouts` are streams that last
  the whole session. `replay()` runs a recording through the same pipeline,
  so settings can be compared over identical audio.
- `ModelManager`, which downloads catalogue models on request, resuming an
  interrupted download, sharing one transfer between callers and installing a
  file only once its size and SHA-256 match. `installed` is a `Live` map of
  each model's status and `progressOf` a `Live` download progress. On iOS
  models are stored in Application Support, excluded from iCloud backup.
- `ModelCatalog`, the transcription models transcribe.cpp publishes at 1 GB or
  less (58 models, 223 files), generated from the catalogue of the engine
  release the package links. Each `ModelDescriptor` carries the file's size,
  SHA-256 and a commit-pinned download URL. Apps can add their own entries;
  `available` hides any whose family the linked engine cannot load.
- The transcribe.cpp 0.3.1 engine (ggml/GGUF), shipped as a prebuilt dynamic
  xcframework with Metal acceleration on iOS. Decoding runs on a helper
  isolate, so it never blocks the UI isolate.
- Microphone capture on iOS over `AVAudioEngine`, surviving route changes,
  interruptions and media-services resets. Audio reaches Dart through a
  lock-free ring read over FFI, never across a method channel.
- Hands-free endpointing (`EndpointerConfig`) with hysteresis, minimum speech
  duration, hangover and pre/post-roll, driven by a from-scratch C port of
  Silero VAD whose 16 kHz weights ship as an asset (~1.2 MB), so endpointing
  needs no second inference runtime.
- Live text that extends rather than rewrites itself: a word is shown only
  once consecutive decodes agree on it, and words repeated across an
  utterance split at the length cap are removed.
- An optional gain stage (`NormalizerConfig`) targeting a fixed RMS, with
  peak and noise ceilings.
- `Live<T>`, a state type that is both a `ValueListenable` and a `Stream`
  replaying its current value to each new subscriber.
