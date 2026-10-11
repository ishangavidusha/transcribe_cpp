import 'dart:ffi';
import 'dart:io';

import 'bindings.g.dart';

/// Symbol resolution for the two native images this package uses.
///
/// They are genuinely separate images and must be looked up separately:
///
///  * `transcribe_*` lives in the engine: `CTranscribe.framework` on iOS, a
///    **dynamic** framework that is embedded in the app bundle, so
///    `DynamicLibrary.open` by framework-relative path resolves through the
///    app's rpath; `libtranscribe.so` on Android, prebuilt by
///    `tool/build_android.sh`.
///  * `tcshim_*`, `silero_vad_*` and `audio_ring_*` are this package's own C
///    (see `src/`). On iOS it is compiled into the plugin target and
///    statically linked into the app's executable, so it is only visible
///    through `DynamicLibrary.process()`; on Android it is
///    `libtranscribe_cpp.so`.
///
/// Doing this in one place means the rest of the package never has to care.
class _NativeImages {
  _NativeImages._();

  /// Resolved on first use, not at construction. The VAD lives in the shim
  /// image and has no dependency on the engine, so a missing or unloadable
  /// CTranscribe.framework must not take endpointing down with it.
  late final DynamicLibrary engine = _openEngine();
  late final DynamicLibrary shim = Platform.isAndroid
      ? DynamicLibrary.open('libtranscribe_cpp.so')
      : DynamicLibrary.process();

  static _NativeImages? _instance;

  static _NativeImages get instance => _instance ??= _NativeImages._();

  DynamicLibrary _openEngine() {
    if (Platform.isAndroid) return _openAndroidEngine();
    if (Platform.isIOS) {
      return DynamicLibrary.open('CTranscribe.framework/CTranscribe');
    }
    if (Platform.isMacOS) {
      // Unit tests and desktop runs resolve against a locally built dylib.
      // TRANSCRIBE_CPP_LIBRARY lets `dart test` point at build-host output
      // without an app bundle in the picture.
      final override = Platform.environment['TRANSCRIBE_CPP_LIBRARY'];
      return DynamicLibrary.open(
        override ?? 'CTranscribe.framework/CTranscribe',
      );
    }
    throw UnsupportedError(
      'transcribe_cpp has no native build for ${Platform.operatingSystem}. '
      'iOS and Android are supported.',
    );
  }

  /// The Android engine's ggml backends are separate modules, and one has to
  /// be registered before the engine can place a model anywhere. The shim
  /// picks the best CPU tier this phone runs (see `src/backend_loader.h`).
  DynamicLibrary _openAndroidEngine() {
    final load = shim
        .lookupFunction<Pointer<Char> Function(), Pointer<Char> Function()>(
          'tcshim_load_cpu_backend',
        );
    if (load() == nullptr) {
      throw UnsupportedError(
        'transcribe_cpp could not load an engine backend on ${Abi.current()}. '
        'The engine ships for arm64-v8a and x86_64 only: 32-bit ARM is not '
        "built, because the ggml it vendors does not compile for it.",
      );
    }
    return DynamicLibrary.open('libtranscribe.so');
  }

  Pointer<T> lookup<T extends NativeType>(String symbol) {
    if (symbol.startsWith('tcshim_') ||
        symbol.startsWith('silero_vad_') ||
        symbol.startsWith('audio_ring_')) {
      return shim.lookup<T>(symbol);
    }
    return engine.lookup<T>(symbol);
  }
}

/// Resolves a raw symbol pointer from whichever image owns it.
///
/// The generated bindings expose callable wrappers; this is for the cases that
/// need the address itself — passing one of the shim's C functions to the
/// engine as a callback, where a Dart closure could not be used.
Pointer<T> lookupNative<T extends NativeType>(String symbol) =>
    _NativeImages.instance.lookup<T>(symbol);

TranscribeBindings? _bindings;

/// The raw generated bindings, bound to the resolved native images.
TranscribeBindings get bindings =>
    _bindings ??= TranscribeBindings.fromLookup(_NativeImages.instance.lookup);
