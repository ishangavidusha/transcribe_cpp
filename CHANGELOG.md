# Changelog

All notable changes to this package are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); while the version
is below `1.0.0`, a `0.x.0` bump may break the API and a `0.x.y` bump may not.

## 0.1.3 — 2026-10-21

### Fixed

- On iOS, changing the audio route mid-session (headphones or a Bluetooth
  headset connected or removed) could stop the microphone for good with
  "route changed: ... (OSStatus error 560557684)": iOS refused to
  re-activate an audio session that was still active. A route change now
  rebuilds only the engine for the new input, and capture continues.
- A sentence in progress when the audio route changed, or when an
  interruption ended, was thrown away: everything said before the switch was
  lost. It is now finished and delivered as a final result, and the new route
  starts a new sentence.

## 0.1.2 — 2026-10-15

### Fixed

- On iOS, starting the microphone during a phone call did nothing and
  reported nothing. Capture now reports `interrupted`, with the message "a
  call is using the microphone", and starts by itself when the call ends.
- On iOS, transcription stopped for good once the app went to the
  background: iOS refuses GPU work from a background app, and the Metal
  backend cannot recover from a refused command buffer. The session now
  moves decoding to the CPU when the app is hidden and back to the GPU when
  it returns, and a decode the GPU refuses is retried on the CPU, so an app
  with background audio keeps transcribing with the screen locked.

### Changed

- The example app is rebuilt around `ModelManager`: browse the catalogue,
  see each model's languages, size and licence, and download, switch or
  delete models. The transcript is live text in a box at the top with
  selectable, copyable paragraphs below, one per pause. The screen stays on
  while listening or downloading.

## 0.1.1 — 2026-10-12

### Fixed

- A download retried from the start, after the server refused to resume a
  partial file, is now awaited inside its error handling, so a failure in
  the retry surfaces as the download's own error. This also clears the
  static-analysis warning on pub.dev.

## 0.1.0 — 2026-10-12

First release: offline speech-to-text for Flutter on iOS and Android.

### Added

- `TranscribeSession`, the entry point for transcription: open it on an
  installed model, then `start()` and `stop()` the microphone any number of
  times. `state`, `text` (settled and interim), `level` and `capture` are
  `Live` values; `utterances`, `events` and `dropouts` are streams that last
  the whole session. `replay()` runs a recording through the same pipeline,
  so settings can be compared over identical audio.
- Transcription of the app's own audio, for apps with their own capture:
  `TranscribeSession.transcribeStream()` runs a stream of chunks through the
  same endpointing and live text as the microphone, and
  `TranscribeSession.transcribe()` decodes a single clip. `AudioFormat`
  describes the input — any rate from 8 to 384 kHz, any channel count,
  16-bit or float — and the session converts it to 16 kHz mono with a
  windowed-sinc resampler, flat to 0.01 dB through 4 kHz.
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
- Android (API 24+, arm64-v8a and x86_64), CPU only: the same engine release,
  prebuilt, with one CPU build per feature tier (dotprod, fp16, i8mm) and the
  fastest one the phone supports chosen at startup. Models are stored in the
  no-backup directory.
- Microphone capture on iOS over `AVAudioEngine`, surviving route changes,
  interruptions and media-services resets, and on Android over `AudioRecord`,
  reporting `interrupted` while the system silences the microphone and
  rebuilding after an audio-server restart. Before Android 10, which has no
  silencing callback, a second of exact digital silence is reported as an
  interruption, naming a call when one is active. Audio reaches Dart
  through a lock-free ring read over FFI, never across a method channel.
  Starting and stopping the microphone happen off the main thread, where
  Dart runs, so `stop()` never holds up the app's frames.
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
