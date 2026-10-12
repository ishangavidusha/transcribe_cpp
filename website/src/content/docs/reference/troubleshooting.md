---
title: Troubleshooting
description: Common problems and what to do about them.
---

## `start()` throws "Microphone permission denied"

The user said no, and the system will not ask again (iOS asks once, Android
twice). Explain why you need the microphone and send them to your app's page
in Settings.

On iOS, also check that `NSMicrophoneUsageDescription` is in `Info.plist`;
without it, the app is closed the moment it asks. On Android, check that
`RECORD_AUDIO` is in your manifest.

## Downloads work in debug but not in release on Android

Your manifest is missing `android.permission.INTERNET`. Debug builds add it
automatically.

## Transcription stops when the app goes to the background

That is the default on both platforms. See
[Listening in the background](../../guides/background/).

## The capture state says `interrupted` and nothing is transcribed

Something else has the microphone: a phone or video call, Siri or the
Assistant, another recording app, or, on Android, your app is in the
background. The session resumes by itself when the microphone is free again.

## Transcription is slow

- Build in **release** or **profile**. Debug builds of Flutter apps are much
  slower, and decode times there say nothing about your app in production.
- On iOS, check `session.modelInfo.backend`. If it says CPU on a real device,
  the GPU was not available and decoding is several times slower. The iOS
  simulator always uses the CPU.
- Larger models are slower. Start with `parakeet-tdt_ctc-110m`.

## `ensure()` throws a `StateError` about a session

Downloads are refused while a session is transcribing, because the two would
compete for the phone. Stop the session first.

## Opening a session throws `UnsupportedError` on Android

The phone is 32-bit only (`armeabi-v7a`), which the engine does not support.

## Building from a git checkout fails with "the Android engine is missing"

The engine binaries are not in git. See [Building](../../contributing/building/).
