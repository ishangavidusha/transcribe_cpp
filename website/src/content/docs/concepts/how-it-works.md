---
title: How it works
description: The pipeline from microphone to text, and what each part is built to survive.
---

You do not need this page to use the package. It is for when you want to know
why something behaves the way it does.

## The pipeline

```
microphone ─▶ capture layer ─▶ ring buffer ─▶ reader isolate ─────────▶ decode isolate ─▶ your app
              (Swift/Kotlin)    (C, 8 s)       gain                       transcribe.cpp     text,
                                               voice detection            (ggml)             utterances,
                                               sentence splitting                            events
                                               live-text snapshots
```

Three threads of work keep each other from getting in the way:

- **The audio thread** belongs to the platform. It converts the microphone to
  16 kHz mono and writes it into a lock-free ring buffer in C. Audio never
  crosses a Flutter method channel: about 60 messages a second through the
  platform thread would tie capture to how busy your UI is.
- **The reader isolate** drains the ring every 16 ms, applies gain, runs voice
  detection, and decides where sentences begin and end. It is off the UI
  isolate, so a janky frame cannot delay a sentence, and off the decode
  isolate, so a long decode cannot let the ring overflow. The ring holds 8
  seconds, far more than a pause in the reader ever needs; if it does
  overflow, the gap is reported as a `Dropout` rather than stitched over.
- **The decode isolate** owns the model and makes the blocking engine call.

Starting and stopping the microphone also happen off the main thread. Since
Flutter 3.29, Dart runs on the platform's main thread, so stopping there would
freeze your animations while the audio system shuts down.

## Voice detection

[Silero VAD](https://github.com/snakers4/silero-vad), ported to plain C and
checked against the original's output to within float rounding. Its weights,
about 1.2 MB, ship with the package, so voice detection needs no second
machine-learning runtime. It scores each 32 ms window of audio with the
probability that someone is speaking.

## Splitting speech into sentences

The endpointer turns those probabilities into sentences:

- **Two thresholds**, a higher one to start speech and a lower one to keep it
  going, so natural dips inside a word do not end the sentence.
- **A minimum length**, so a cough or a click does not become a sentence, plus
  re-attachment, so a short word right after speech is kept.
- **A hangover** of silence before the sentence is declared over, with a little
  audio kept on either side so the first and last sounds are not clipped.
- **A maximum length**. Someone reading aloud may never pause; at 20 seconds the
  sentence is cut, and the next one starts slightly before the cut. The words
  both pieces share are removed again when the text is joined.

Each finished sentence is decoded once, in one pass. That is fast because the
recommended models decode a whole sentence in a single parallel step.

## Live text

While a sentence is being spoken, its audio so far is decoded again every
350 ms. The last word or two of each decode is unreliable, because the model
has not heard what comes next. So a word only appears once two consecutive
decodes agree on it. The interim text then only grows, and the user does not
see it rewrite itself. If decoding falls behind, updates are skipped rather
than queued.

## Capture on iOS

`AVAudioEngine`, in measurement mode, so the models get the cleanest signal.
The hard part is staying alive for a long session:

- **Interruptions** (a call, Siri, another app): capture stops and restarts
  when iOS says it may.
- **Route changes** (headphones in or out, Bluetooth on or off): the input
  format can change underneath, say from 48 kHz to 16 kHz, so the converter is
  rebuilt for it. Bluetooth headset microphones work.
- **Media services reset**: everything is rebuilt from scratch.

## Capture on Android

`AudioRecord`, from the voice-recognition source, which asks the device for no
noise suppression or gain control. Android handles route changes itself.

- **Silencing.** Android does not stop a recording when something more
  important needs the microphone. It quietly feeds it silence. From Android 10
  the system says so, and the session reports `interrupted`. Before that, a
  second of exact digital silence, which a real microphone never produces, is
  taken as the same signal, and the phone's call state tells a call apart.
- **Audio server restarts**: the recording is rebuilt once.
- Bluetooth headset microphones are not used yet; the built-in or a wired
  microphone is.

## The engine

[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) runs the
models, on [ggml](https://github.com/ggml-org/ggml). On iOS it uses the GPU
through Metal. On Android it runs on the CPU, in one of four builds for
different generations of ARM processors; the fastest one the phone supports is
picked when the app starts.
