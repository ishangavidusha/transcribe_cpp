#!/usr/bin/env bash
#
# Build the transcribe.cpp engine for Android and place the stripped shared
# libraries in android/src/main/jniLibs/, where the Android Gradle Plugin
# packages them into every app that depends on this plugin.
#
# Upstream publishes no Android binaries, so these are ours. They are built
# from the same engine tag as the iOS xcframework and the bundled catalogue,
# and committed, so an app build never compiles the engine: that would cost
# minutes per ABI on every clean build, put ~250 MB of engine source in the
# package, and require the NDK of every developer who uses it.
#
# CPU code ships as several variants, and the plugin picks one at startup (see
# src/backend_loader.c). Android's arm64 baseline is armv8.0, where ggml's
# dotprod, fp16 and i8mm paths are all compiled out — a single baseline build
# runs on every phone and is slow on all of them, while a single build with
# i8mm (Armv8.6) dies with SIGILL on older ones. ggml builds each tier as its
# own module with a score function that rejects a CPU missing the features,
# so the loader tries them best-first. Of ggml's seven Android tiers, four
# ship: the SVE2/SME builds add ~2.3 MB for flagships whose 128-bit SVE is the
# same width as NEON, an unmeasured gain. x86_64 exists for emulators on
# Intel hosts and ships a baseline plus an AVX2 tier.
#
# Usage:
#   tool/build_android.sh [path/to/transcribe.cpp]    (default ../transcribe.cpp)
#
# The checkout must be at the engine tag the catalogue names. NDK and CMake
# come from the Android SDK (ANDROID_HOME, default ~/Library/Android/sdk);
# the NDK is pinned so the output does not drift with whatever is installed.

set -euo pipefail

ENGINE_REF=v0.3.1
NDK_VERSION=28.2.13676358
CMAKE_VERSION=4.1.2
ANDROID_PLATFORM=android-24 # matches minSdk in android/build.gradle.kts

ARM64_VARIANTS=(android_armv8.0_1 android_armv8.2_1 android_armv8.2_2 android_armv8.6_1)
X86_64_VARIANTS=(x64 haswell)

here="$(cd "$(dirname "$0")/.." && pwd)"
engine="$(cd "${1:-$here/../transcribe.cpp}" && pwd)"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ndk="$sdk/ndk/$NDK_VERSION"
cmake="$sdk/cmake/$CMAKE_VERSION/bin/cmake"
ninja="$sdk/cmake/$CMAKE_VERSION/bin/ninja"
strip="$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-strip)"

catalog_ref="$(sed -n "s/^const _engineRef = '\(.*\)';/\1/p" "$here/lib/src/catalog.g.dart")"
if [[ "$catalog_ref" != "$ENGINE_REF" ]]; then
  echo "catalog.g.dart is generated from $catalog_ref, this script builds $ENGINE_REF" >&2
  exit 1
fi
actual_ref="$(git -C "$engine" describe --tags --exact-match 2>/dev/null || true)"
if [[ "$actual_ref" != "$ENGINE_REF" ]]; then
  echo "$engine is at '${actual_ref:-an untagged commit}', expected $ENGINE_REF" >&2
  exit 1
fi
if [[ -n "$(git -C "$engine" status --porcelain --untracked-files=no)" ]]; then
  echo "$engine has local changes; build from a clean checkout" >&2
  exit 1
fi
for tool in "$ndk" "$cmake" "$ninja" "$strip"; do
  [[ -e "$tool" ]] || { echo "missing: $tool" >&2; exit 1; }
done

build() {
  local abi="$1"; shift
  local variants=("$@")
  local out="$here/build/android-engine/$abi"
  local dest="$here/android/src/main/jniLibs/$abi"

  "$cmake" -S "$engine" -B "$out" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$ninja" \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DTRANSCRIBE_BUILD_SHARED=ON \
    -DTRANSCRIBE_GGML_BACKEND_DL=ON \
    -DGGML_CPU_ALL_VARIANTS=ON \
    -DGGML_OPENMP=OFF \
    -DTRANSCRIBE_METAL=OFF \
    -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF \
    -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
    -DTRANSCRIBE_INSTALL=OFF >/dev/null
  "$cmake" --build "$out" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

  rm -rf "$dest"
  mkdir -p "$dest"
  local libs=(libtranscribe.so libggml.so libggml-base.so)
  for v in "${variants[@]}"; do libs+=("libggml-cpu-$v.so"); done
  for lib in "${libs[@]}"; do
    local src
    src="$(find "$out" -name "$lib" -type f | head -1)"
    [[ -n "$src" ]] || { echo "$abi: $lib was not built" >&2; exit 1; }
    "$strip" --strip-unneeded -o "$dest/$lib" "$src"
  done
}

build arm64-v8a "${ARM64_VARIANTS[@]}"
build x86_64 "${X86_64_VARIANTS[@]}"

echo
echo "transcribe.cpp $ENGINE_REF, NDK $NDK_VERSION:"
( cd "$here/android/src/main/jniLibs" && find . -name '*.so' -exec ls -l {} + | awk '{print $5, $9}' )
