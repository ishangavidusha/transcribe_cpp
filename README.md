# transcribe_cpp

Offline, on-device speech-to-text for Flutter. Dart FFI bindings to
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) — a
ggml/GGUF speech engine — with Metal acceleration on iOS.

No network calls, no API keys, no audio leaving the device.

> **Pre-release.** Not published to pub.dev. iOS only so far, and the public API
> is still being shaped — treat every export as unstable.

## What is in the box

- **Transcription** — batch and streaming, run on a helper isolate so decoding
  never blocks the UI.
- **Microphone capture** (iOS) over `AVAudioEngine`, surviving route changes,
  interruptions and media-services resets. Audio reaches Dart through a
  lock-free ring read over FFI; it never crosses a method channel.
- **Voice activity detection** — Silero VAD, ported to C and bundled as a
  ~1.2 MB weights asset, so endpointing costs no second inference runtime.
- **Hands-free endpointing** — hysteresis, minimum speech duration, hangover,
  pre/post-roll. The endpointer decides when an utterance ends; there is no
  push-to-talk button to hold.
- **Stable live text** — a LocalAgreement-2 stable prefix, so partial results
  can be shown as they arrive without the tail flickering as it is revised.

## Requirements

| | |
|---|---|
| Flutter | 3.3.0+ |
| Dart SDK | 3.12.2+ |
| iOS | 16.0+ (the xcframework slices refuse to link below this) |
| Android | not yet — the engine cross-compiles, the capture layer is not written |

Swift Package Manager is the supported iOS integration path. A CocoaPods
podspec exists for apps that have not migrated, but it is **unverified** since
the capture layer landed.

## Audio format

Audio in must be **mono float32 at 16 kHz**, samples in `[-1, 1]`. The engine
links no resampler by design, so rate conversion belongs to the caller.
`MicrophoneCapture` already delivers audio in this format.

## Models

Model weights are **not** bundled and never will be — a useful GGUF runs from
tens to hundreds of megabytes, which is not something an app should carry in
its binary. Your app downloads the model it wants at first launch and points
the package at the file.

Models live at
[huggingface.co/handy-computer](https://huggingface.co/handy-computer). Which
one to use is your decision: `parakeet-tdt_ctc-110m` measured faster and more
accurate than `moonshine-streaming-tiny` on an iPhone 12 Pro, but the tradeoff
between size, latency and accuracy depends on what you are building.

`ModelManager` downloads, verifies and stores them. It never picks a model or
starts a download on its own; your app decides which models to offer and when
to fetch one:

```dart
final models = await ModelManager.open();

// Every model the linked engine can load, with size, languages and licence.
final choices = models.available;

// Download if needed, then return the verified file. Resumes a download that
// was interrupted; callers asking for the same model share one transfer.
final model = await models.ensure(
  const ModelId('parakeet-tdt_ctc-110m-Q4_K_M'),
);
print(model.path);
```

`models.installed` is a `Live` map of each model's status for a picker, and
`models.progressOf(id)` a `Live` progress value while one downloads. On iOS
models are stored in Application Support, excluded from iCloud backup, and a
file is only installed once its size and SHA-256 match the catalogue. Model
licences differ, and some are non-commercial: check
`ModelDescriptor.license` before shipping one.

## Transcribing

```dart
final session = await TranscribeSession.open(model);

// Settled text plus the utterance still being spoken, ready for a text view.
session.text.addListener(() => print(session.text.value.full));

await session.start();   // asks for microphone permission the first time
// ... the user speaks; the endpointer decides when each utterance ends ...
await session.stop();    // waits for the last utterance to be decoded

await session.dispose(); // releases the model
```

`start()` and `stop()` can repeat on one session without reloading the model.
`state`, `text`, `level` and `capture` are `Live` values (a `ValueListenable`
with a `stream` that replays the current value); `utterances`, `events` and
`dropouts` are streams. `replay(samples)` feeds a recording through the same
pipeline as the microphone, to compare settings on identical audio.

## Running the example

The example app is a measurement harness as much as a demo: it prints a
per-utterance log with levels, gain, decode time and real-time factor, and can
replay a recorded WAV under different settings to compare them over identical
audio.

It downloads the selected model (parakeet-tdt_ctc-110m, 90 MB, or
moonshine-streaming-tiny, 50 MB) through `ModelManager` the first time you
press Start, so the first run needs a network connection.

```bash
cd example && flutter run --release
```

Run it in **release**. Debug builds of the Dart VM make decode times
meaningless, and the numbers the log prints are the point.

## Repository layout

| Path | |
|---|---|
| `lib/` | the Dart API; `lib/src/` is private and changes freely |
| `src/` | this package's C — the FFI shim, the Silero port, the audio ring |
| `ios/transcribe_cpp/` | the SwiftPM package: capture layer, C target, engine xcframework |
| `assets/` | bundled Silero VAD weights |
| `example/` | the demo and measurement harness |
| `test/` | Dart tests, plus two standalone C tests |
| `tool/` | the Silero weight extractor |

## Building

```bash
flutter analyze && flutter test
cd example && flutter build ios --release --no-codesign
```

The release build matters. Dart resolves FFI symbols through
`DynamicLibrary.process()`, which the linker cannot see, so it dead-strips them
unless each exported C function is annotated — see `src/tc_export.h`. A debug
build hides the problem.

## License

MIT — see [LICENSE](LICENSE).

This package redistributes a compiled build of transcribe.cpp (which links ggml
and miniz) and weights derived from Silero VAD, all MIT-licensed. See
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). Model weights are not
redistributed and carry their own licenses from their own publishers.
