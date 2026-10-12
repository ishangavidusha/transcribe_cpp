# Contributing to transcribe_cpp

Thanks for helping. Bug reports, questions, ideas and pull requests are all
welcome.

## Reporting a bug

[Open an issue](https://github.com/ishangavidusha/transcribe_cpp/issues) with:

- the device, and its iOS or Android version
- the model you were using
- what you expected, and what happened instead
- whether it happens in a **release** build (debug builds are much slower,
  and timing problems there are usually not real)

For anything that looks like the engine misbehaving, turn on its log before
opening a session and include the output:

```dart
NativeLog.quiet(verbose: true);
```

If the transcription itself is wrong for a model, rather than the package
handling it badly, the problem may belong to
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), which runs
the models. Please read and follow
[its contributing guidelines](https://github.com/handy-computer/transcribe.cpp/blob/main/CONTRIBUTING.md)
before reporting there.

## Suggesting a change

For anything larger than a fix, open an issue first so we can agree on the
approach before you spend time on it. That matters most for the public API:
every exported type and method is a promise to the apps that use the package.

## Setting up

You need Flutter (stable), Xcode for iOS, and the Android SDK for Android.

```bash
git clone https://github.com/ishangavidusha/transcribe_cpp
cd transcribe_cpp
```

The compiled speech engine is not in git, so put it in place once:

```bash
# iOS: transcribe.cpp's own release, checked against its SHA-256.
tool/fetch_ios_engine.sh

# Android: built from a transcribe.cpp checkout at the pinned tag, with the
# NDK and CMake versions named at the top of the script.
git clone --branch v0.3.1 --depth 1 https://github.com/handy-computer/transcribe.cpp ../transcribe.cpp
tool/build_android.sh ../transcribe.cpp
```

Then run the example on a real phone:

```bash
cd example && flutter run --release
```

## Before opening a pull request

```bash
dart format lib test example/lib
flutter analyze && flutter test
cd example && flutter analyze && flutter test
cd example && flutter build ios --release --no-codesign
tool/check_ios_symbols.sh example/build/ios/iphoneos/Runner.app/Runner
cd example && flutter build apk --release
```

CI runs all of these, plus the C tests, on every push and pull request.

The iOS **release** build matters. Dart calls the package's C functions in a
way the linker cannot see, so it removes any that are not marked `TC_EXPORT`
(see `src/tc_export.h`). A debug build hides this; `check_ios_symbols.sh`
catches it.

## How we work

- **One change per pull request.** Small, focused changes are easier to
  review, and when something regresses it is clear which change did it.
- **Test what is true.** A test should check how the code actually behaves,
  not restate what you expected it to do. Do not weaken a test to make it
  pass; if a change makes some case worse, add a test that says so.
- **Numbers come from measurements.** Every threshold and default in the
  package was measured. If you change one, say in the comment beside it what
  you measured and what else you tried. If you cannot measure it, make it
  measurable first.
- **Comments explain why**: the constraint, the measurement or the failure
  behind the code, not what the code does.
- **Changelog.** If a change is visible to apps using the package, add a line
  to `CHANGELOG.md` in the same pull request, saying what changed for them.
- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`), with an
  imperative subject under 72 characters and a body explaining why.

## Documentation

The documentation site lives in `website/` and is built with
[Starlight](https://starlight.astro.build/):

```bash
cd website
npm install
npm run dev
```

Pages are Markdown in `website/src/content/docs/`. Merging to `main`
publishes the site.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE), like the rest of the package.
