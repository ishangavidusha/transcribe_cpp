---
title: Performance
description: How fast and how accurate the recommended models are.
---

The best measure is your own app with your own users: install the example and
talk to it. As a guide:

## Speed

On a mid-range phone, `parakeet-tdt_ctc-110m` transcribes 11 seconds of speech
in about a quarter of a second: roughly **40 times faster than real time**. A
typical spoken sentence comes back as text a few hundred milliseconds after the
speaker pauses, most of which is the pause itself.

`moonshine-streaming-tiny` is about half as fast. Its decoder works one word at
a time, while parakeet's produces the whole sentence in one step.

## Accuracy

Word error rate on LibriSpeech test-clean, as published in
[transcribe.cpp's model catalogue](https://github.com/handy-computer/transcribe.cpp/tree/main/catalog):

| Model | Download | Word error rate |
|---|---|---|
| `parakeet-tdt_ctc-110m-Q4_K_M` | 90 MB | 2.53% |
| `moonshine-streaming-tiny-Q8_0` | 50 MB | 4.52% |

LibriSpeech is clean, read speech. Expect more errors from casual
conversation, noisy rooms, accents and specialist vocabulary.

## Size

The package adds about 6 MB of engine to an Android app per processor
architecture, and about 6 MB on iOS. Models are downloaded at runtime and are
not part of your app.
