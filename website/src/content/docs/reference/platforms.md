---
title: Platforms
description: Supported versions, devices and known limitations.
---

| | |
|---|---|
| Flutter | 3.3.0 or later |
| Dart | 3.12.2 or later |
| iOS | 16.0 or later |
| Android | 7.0 (API 24) or later, 64-bit (arm64-v8a, and x86_64 for emulators) |

## iOS

- Swift Package Manager is the supported integration, and Flutter's default.
  A CocoaPods podspec exists but has not been verified.
- The model runs on the GPU through Metal. The simulator runs it on the CPU.
- Bluetooth headset microphones are used when connected. They carry
  narrow-band audio, so accuracy is a little lower than with the built-in
  microphone.

## Android

- The model runs on the CPU. Four builds for different ARM generations ship,
  and the fastest one the phone supports is chosen at startup.
- 32-bit-only phones (`armeabi-v7a`) are not supported: the engine does not
  build for them. Opening a session there throws an `UnsupportedError`.
- Bluetooth headset microphones are not used yet.
- Before Android 10, the system does not report when it silences an app's
  microphone, so the session detects it from the audio, about a second late.

## Not supported

macOS, Windows, Linux and the web are not targets today.
