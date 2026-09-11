# transcribe_cpp_example

The demo app for `transcribe_cpp` — and the measurement harness the package is
tuned against.

It runs live microphone transcription with hands-free endpointing, and prints a
per-utterance log with input level, applied gain, output level, peak, decode
time, real-time factor, and how much of the text was stable when it was shown:

```
[12 ] 41.8s +3.4s  in=-38.2dB  gain=6.1x  out=-22.0dB  peak=0.58  decode=171ms  rtf=19.9x  prov=9/11 live=8/8w
      "the majority of the change will come from"
```

It can also record a session to a WAV and replay it under a different
configuration. That is the only honest way to A/B a setting: two live runs cover
different audio, so comparing them means nothing.

## Setup

Model weights are gitignored — they are too large to commit and are not ours to
redistribute. Fetch both from
[huggingface.co/handy-computer](https://huggingface.co/handy-computer) into
`assets/`, keeping the filenames exactly as `pubspec.yaml` declares them:

```
assets/parakeet-tdt_ctc-110m-Q4_K_M.gguf
assets/moonshine-streaming-tiny-Q8_0.gguf
```

Then:

```bash
flutter run --release
```

Run it in **release**. A debug Dart VM makes the decode times and real-time
factors meaningless, and those numbers are the reason this app exists.

A physical device is required — the simulator has no usable microphone path and
no Metal GPU to accelerate the engine.
