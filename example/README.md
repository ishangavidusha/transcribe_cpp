# transcribe_cpp example

A dictation app built on `transcribe_cpp`: pick a model, press Start, and talk.
The text appears as you speak, and each sentence settles when you pause.

```bash
flutter run --release
```

The first time you press Start it downloads the selected model
(parakeet-tdt_ctc-110m, 90 MB, or moonshine-streaming-tiny, 50 MB), so the
first run needs a network connection. After that it works offline.

Run it in **release** on a real phone. Debug builds are much slower, and the
simulator and emulator have no GPU for the engine.

## What it shows

- **Live transcription** from the microphone, with the sentence in progress in
  grey.
- **Presets** for when a sentence ends (`eager`, `balanced`, `patient`), and
  automatic gain on or off.
- **Background listening** on both platforms: a foreground service on Android
  (`android/.../ListeningService.kt`) and the audio background mode on iOS.
- **Compare settings**: every session is recorded, and can be replayed under
  each preset to compare them on identical audio.

It also prints a detailed log per sentence: input level, gain, decode time and
how much of the live text was stable when it was shown.

```
[12 ] 41.8s +3.4s  in=-38.2dB  gain=6.1x  out=-22.0dB  peak=0.58  decode=171ms  rtf=19.9x  prov=9/11 live=8/8w
      "the majority of the change will come from"
```

See the [documentation](https://ishangavidusha.github.io/transcribe_cpp/) for
how each part works.
