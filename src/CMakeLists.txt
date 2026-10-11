# This package's own C, as one shared library for Android. iOS compiles the
# same files through Swift Package Manager (ios/transcribe_cpp/Package.swift).
#
# The engine is not built here: tool/build_android.sh builds it once, and its
# libraries ship prebuilt in android/src/main/jniLibs. Nothing here links
# against it either — the VAD and the ring have no engine dependency, and the
# backend loader reaches libggml.so through dlopen.

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. Do not raise this: it fails the build for anyone with less.
cmake_minimum_required(VERSION 3.10)

project(transcribe_cpp_library LANGUAGES C)

add_library(transcribe_cpp SHARED
  "audio_ring.c"
  "backend_loader.c"
  "silero_vad.c"
  "transcribe_shim.c"
)

# Debug builds too: the VAD runs every 32 ms on the reader isolate, and AGP
# builds the debug variant at -O0.
target_compile_options(transcribe_cpp PRIVATE -O3)
target_link_libraries(transcribe_cpp PRIVATE m dl)

if (ANDROID)
  # The microphone's AudioRecord writes into the ring through JNI.
  target_sources(transcribe_cpp PRIVATE "capture_jni.c")
  # Engine log messages go to logcat (see tcshim_log_cb).
  target_link_libraries(transcribe_cpp PRIVATE log)
  # Android 15 devices with 16 KB pages refuse libraries aligned for 4 KB.
  target_link_options(transcribe_cpp PRIVATE "-Wl,-z,max-page-size=16384")
endif()
