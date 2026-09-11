import 'dart:ffi';
import 'dart:io';

import 'bindings.g.dart';

/// Symbol resolution for the two native images this package uses.
///
/// They are genuinely separate images and must be looked up separately:
///
///  * `transcribe_*` lives in `CTranscribe.framework`, a **dynamic** framework
///    that CocoaPods embeds in the app bundle. dyld loads it at launch, so
///    `DynamicLibrary.open` by framework-relative path resolves through the
///    app's rpath.
///  * `tcshim_*`, `silero_vad_*` and `audio_ring_*` are this package's own C
///    (see `src/`), compiled into the plugin target and statically linked into
///    the app's executable, so they are only visible through
///    `DynamicLibrary.process()`.
///
/// Doing this in one place means the rest of the package never has to care.
class _NativeImages {
  _NativeImages._();

  /// Resolved on first use, not at construction. The VAD lives in the shim
  /// image and has no dependency on the engine, so a missing or unloadable
  /// CTranscribe.framework must not take endpointing down with it.
  late final DynamicLibrary engine = _openEngine();
  late final DynamicLibrary shim = DynamicLibrary.process();

  static _NativeImages? _instance;

  static _NativeImages get instance => _instance ??= _NativeImages._();

  static DynamicLibrary _openEngine() {
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
      'transcribe_cpp has no native build for ${Platform.operatingSystem} yet. '
      'iOS is supported. Android is not blocked by the engine — it '
      'cross-compiles cleanly for arm64-v8a and x86_64 with the NDK, at about '
      '3.8 MB stripped per ABI — but this package has no Android build wiring '
      'and no capture implementation yet.',
    );
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
