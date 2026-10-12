---
title: Bringing your own audio
description: Use the speech engine with audio your app already records, without the package's microphone handling.
---

If your app already records audio, from its own capture code, a call, a file
or the network, you can use transcribe_cpp just for the transcription. Nothing
on this page touches the microphone, the audio session, permissions or
background handling. This is also the easy way to move an app over from a
cloud speech service.

## A stream of audio

`transcribeStream` takes audio as it arrives and transcribes it exactly like
the microphone path: it finds the sentences, shows live text, and delivers
results on the same `text`, `utterances` and `events`.

```dart
final session = await TranscribeSession.open(model);

await session.transcribeStream(
  audioChunks, // a Stream of Uint8List, Int16List or Float32List
  format: const AudioFormat(sampleRate: 48000, channels: 2),
);
```

It completes when the stream ends and the last sentence is delivered. Call
`session.stop()` to end it early; audio already pushed is still transcribed.

Push audio at its natural pace to get live text. Pushed faster, for example
from a file, it is transcribed as fast as the phone can, with fewer interim
updates. An error on your stream ends the run, and `transcribeStream` throws it
once what came before is delivered.

## A single clip

`transcribe` decodes one clip in one go, with no sentence splitting and no
live text:

```dart
final transcript = await session.transcribe(
  clip,
  format: const AudioFormat(sampleRate: 44100),
);
print(transcript.text);
```

Use it for a sentence or a short recording. A long clip runs into the model's
limits and can come back incomplete (`transcript.wasTruncated`); give long
audio to `transcribeStream`, which splits it at pauses.

## Audio formats

`AudioFormat` describes your audio, and the session converts it for you:

| | |
|---|---|
| `sampleRate` | Any rate from 8 kHz to 384 kHz. |
| `channels` | Any number; they are averaged to mono. Interleaved. |
| `sampleFormat` | `SampleFormat.int16` (the default) or `SampleFormat.float32`, little-endian. |

The models take 16 kHz mono. Conversion runs off the UI isolate with a
high-quality resampler, and chunks may split a sample anywhere.
`AudioFormat.engine` is the models' own format, which is passed through
untouched.
