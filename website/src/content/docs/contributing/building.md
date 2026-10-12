---
title: Building from source
description: Work on the package itself — engine binaries, tests, CI and releases.
---

Apps that depend on the package from pub.dev need none of this. It is for
working on transcribe_cpp itself, or depending on it through git.

## Get the engine

The compiled engine is not in git. The package on pub.dev carries it; a clone
of the repository needs it put in place once:

```bash
tool/fetch_ios_engine.sh                 # upstream's xcframework, checksum-verified
tool/build_android.sh ../transcribe.cpp  # a transcribe.cpp checkout at the pinned tag
```

`fetch_ios_engine.sh` downloads transcribe.cpp's own iOS release and keeps its
two iOS slices. `build_android.sh` builds the Android libraries with the NDK
and CMake versions it names, from the Android SDK. Without them, an Android
build stops with a message saying so.

## Check your work

```bash
flutter analyze && flutter test
cd example && flutter build ios --release --no-codesign
tool/check_ios_symbols.sh example/build/ios/iphoneos/Runner.app/Runner
cd example && flutter build apk --release
```

The iOS release build matters. Dart finds the package's C functions at run
time, where the linker cannot see the use, so it removes them unless each is
marked `TC_EXPORT` (see `src/tc_export.h`). A debug build hides the problem;
`check_ios_symbols.sh` confirms every exported function survived.

## Repository layout

| Path | |
|---|---|
| `lib/` | The Dart API. `lib/src/` is private and changes freely. |
| `src/` | The package's C: FFI shim, voice detector, audio ring, Android backend loader. |
| `ios/transcribe_cpp/` | The Swift package: capture layer, C target, engine. |
| `android/` | The Gradle module: Kotlin plugin and engine libraries. |
| `assets/` | Voice detector weights. |
| `example/` | The example app, which also prints detailed timing logs. |
| `test/` | Dart tests, plus two standalone C tests. |
| `tool/` | Engine build and fetch, symbol check, weight extractor, catalogue generator. |
| `website/` | This documentation site (Starlight). |
| `.github/` | CI, the release workflow, and this site's deployment. |

## CI and releases

Every push runs the analysis, the Dart and C tests, and release builds of the
example on Android and iOS, building the engine from the pinned tag.

A `v<version>` tag runs the release: it builds both engines, verifies the
example on each platform, publishes to pub.dev, and attaches the engine
binaries to a GitHub release.

## This site

```bash
cd website
npm install
npm run dev
```

Pages are Markdown in `website/src/content/docs/`. Pushing to `main` publishes
the site.
