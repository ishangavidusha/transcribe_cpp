#
# transcribe_cpp — Flutter FFI bindings for transcribe.cpp.
#
# The native engine is consumed as a prebuilt dynamic `.xcframework`, the same
# artifact the official Swift binding uses. It is NOT built from source here:
# transcribe.cpp is a large CMake project with a Metal shader step, and
# building it inside a CocoaPods target would make every `pod install` a
# multi-minute affair. Regenerate it with `scripts/build_xcframework.sh` when
# you bump the engine.
#
# This podspec is the LEGACY path. Flutter 3.44 defaults to Swift Package
# Manager and CocoaPods' trunk goes read-only on 2026-12-02, so
# transcribe_cpp/Package.swift is the primary manifest; this exists only for
# apps that have not migrated. Both reference the same xcframework and the same
# sources.
#
# UNVERIFIED since the capture layer landed. SwiftPM splits the C and the Swift
# into two targets and the Swift says `import TranscribeCppC`; CocoaPods instead
# builds one mixed-language pod where the C arrives through the generated
# umbrella header. AudioCapture.swift guards the import for that case, but the
# example app is SPM-native, so nothing here exercises the CocoaPods build. The
# FFI-only surface (engine, VAD, ring) is the part most likely to still work;
# treat capture under CocoaPods as needing a real build before you trust it.
#
Pod::Spec.new do |s|
  s.name             = 'transcribe_cpp'
  s.version          = '0.0.1'
  s.summary          = 'Offline on-device speech-to-text for Flutter, powered by transcribe.cpp.'
  s.description      = <<-DESC
Dart FFI bindings for transcribe.cpp — GGUF/ggml speech-to-text inference
with Metal acceleration on iOS. Batch and streaming transcription, fully
offline.
                       DESC
  s.homepage         = 'https://github.com/handy-computer/transcribe.cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ishanga Vidusha' => 'ishangavidushalk@gmail.com' }

  s.source           = { :path => '.' }
  # Same files the SwiftPM target compiles, so the two integration paths can
  # never drift apart.
  s.source_files     = 'transcribe_cpp/Sources/**/*.{c,h,swift}'
  s.dependency 'Flutter'

  # The xcframework's iOS slices are built with a 16.0 deployment target
  # (IOS_MIN_OS_VERSION in transcribe.cpp's build_xcframework.sh). Anything
  # lower here and the app fails to link against it.
  s.platform = :ios, '16.0'

  # Dynamic framework: CocoaPods links it and adds it to the app's embed
  # phase, so dyld loads it at launch and `DynamicLibrary.open` finds it in
  # the app bundle's Frameworks/ directory.
  s.vendored_frameworks = 'transcribe_cpp/Frameworks/TranscribeCpp.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
