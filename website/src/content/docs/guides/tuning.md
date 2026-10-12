---
title: Tuning
description: Adjust when sentences end, automatic gain, and compare settings on the same recording.
---

The defaults are tuned for dictation on a phone and are the right place to
start. Change them when your users speak differently, for example in short
commands or with long pauses mid-thought.

## When a sentence ends

`EndpointerConfig` controls how the session splits speech into sentences. It
is passed to `start()`, `transcribeStream()` or `replay()`.

```dart
await session.start(
  endpointer: const EndpointerConfig(
    hangover: Duration(milliseconds: 700), // wait longer before ending
  ),
);
```

| Setting | Default | What it does |
|---|---|---|
| `hangover` | 400 ms | How much silence ends a sentence. Longer lets people pause mid-thought; shorter returns text sooner. |
| `minSpeechDuration` | 250 ms | Sounds shorter than this, such as coughs and clicks, are ignored (and reported as `SpeechDiscarded`). |
| `reattachWithin` | 400 ms | A short sound right after speech is kept anyway, so a quick "yes" or "no" survives. |
| `maxUtterance` | 20 s | The longest sentence. Someone reading without pausing is split here, with a small overlap so no word is lost. |
| `speechThreshold` | 0.5 | How sure the voice detector must be that speech has started. |
| `silenceThreshold` | 0.35 | Below this, the detector counts silence. Lower than the start threshold, so a sentence is not cut off mid-word. |
| `preRoll` | 300 ms | Audio kept from before speech starts, so the first syllable is not clipped. |
| `postRoll` | 250 ms | Audio kept after speech ends. |

Durations are rounded up to the voice detector's 32 ms steps.

The example app offers three presets to try: `eager` (250 ms hangover),
`balanced` (400 ms, the default) and `patient` (700 ms).

## Automatic gain

Quiet speakers, or a phone held far away, can be too quiet for the voice
detector to notice. The session boosts quiet audio and calms loud audio before
anything listens to it. It is on by default; pass `normalizer: null` to turn it
off.

The gain never boosts a noisy room's background into "speech": the boost is
capped by how loud the room's own noise is. The defaults rarely need changing;
`NormalizerConfig` documents each setting.

## Compare settings on the same audio

Two live runs never hear the same audio, so comparing settings live tells you
little. Record once, then replay the recording under each setting:

```dart
await session.start(recordTo: '${dir.path}/take.wav');
// ...speak...
await session.stop();

final audio = Wav.read('${dir.path}/take.wav');
for (final config in [eager, balanced, patient]) {
  await session.replay(audio, endpointer: config);
  print(session.text.value.settled);
}
```

`replay` runs the recording through exactly what the microphone uses, as fast
as the phone can. Its audio must be 16 kHz mono float, which is what
`recordTo` writes.
