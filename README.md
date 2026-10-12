# transcribe_cpp

[![pub package](https://img.shields.io/pub/v/transcribe_cpp.svg)](https://pub.dev/packages/transcribe_cpp)
[![CI](https://github.com/ishangavidusha/transcribe_cpp/actions/workflows/ci.yml/badge.svg)](https://github.com/ishangavidusha/transcribe_cpp/actions/workflows/ci.yml)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-4f46e5.svg)](https://ishangavidusha.github.io/transcribe_cpp/reference/platforms/)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Offline speech-to-text for Flutter.** The user talks, your app gets text,
and the audio never leaves the phone.

<p align="center">
  <img src="https://raw.githubusercontent.com/ishangavidusha/transcribe_cpp/main/screenshots/demo.gif" width="400" alt="Words appearing on screen as a speech is transcribed live on the phone">
</p>

- **Private.** Everything runs on the device: no server, no account, no API
  key.
- **Hands-free.** Voice detection decides when each sentence ends. No button
  to hold.
- **Live text.** Words appear while the user is still speaking, and settle in
  place without flickering.
- **Fast.** About 40 times faster than real time on a mid-range phone.
- **Resilient.** Keeps going through calls, Siri, headphones being plugged in,
  and the app going to the background.
- **Your audio, too.** Already record audio yourself? Feed it in at any sample
  rate.

## Install

```bash
flutter pub add transcribe_cpp
```

Then let your app use the microphone. On **iOS**, add a reason to
`ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Your speech is transcribed on this device.</string>
```

On **Android**, add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

## Use it

```dart
import 'package:transcribe_cpp/transcribe_cpp.dart';

// Download a model once (90 MB). Later calls return it straight away.
final models = await ModelManager.open();
final model = await models.ensure(const ModelId('parakeet-tdt_ctc-110m-Q4_K_M'));

// Load it, and listen.
final session = await TranscribeSession.open(model);
await session.start();

// Show the text as the user speaks.
ValueListenableBuilder(
  valueListenable: session.text,
  builder: (context, text, _) => Text(text.full),
);

await session.stop();
```

Already capture audio yourself? Hand it over instead of using the microphone:

```dart
await session.transcribeStream(
  myAudio,
  format: const AudioFormat(sampleRate: 48000),
);
```

## Models

Models are downloaded at runtime, not bundled with your app. Two good places to
start:

| Model | Download | Word error rate* |
|---|---|---|
| `parakeet-tdt_ctc-110m-Q4_K_M` | 90 MB | 2.5% |
| `moonshine-streaming-tiny-Q8_0` | 50 MB | 4.5% |

\* LibriSpeech test-clean, from the models' published benchmarks.

Many more are available, including other languages: every model
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) publishes up
to 1 GB.

## Platforms

| | |
|---|---|
| iOS | 16.0 or later. Runs on the GPU. |
| Android | 7.0 (API 24) or later, 64-bit. Runs on the CPU. |

## Documentation

The full guide is at
**[ishangavidusha.github.io/transcribe_cpp](https://ishangavidusha.github.io/transcribe_cpp/)**:
choosing and downloading models, live text and sentences, interruptions,
listening in the background, tuning, and how it all works.

The [example app](example/) is a complete app with a model picker.

## License

MIT. The package includes builds of
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) and
[ggml](https://github.com/ggml-org/ggml), and weights derived from
[Silero VAD](https://github.com/snakers4/silero-vad), all MIT; see
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). Speech models carry their
own licences, and some are non-commercial.
