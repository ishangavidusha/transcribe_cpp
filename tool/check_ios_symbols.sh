#!/usr/bin/env bash
#
# Checks that every C function the package exports for Dart survived the
# linker in an iOS release build.
#
# Dart finds these through DynamicLibrary.process(), which the linker cannot
# see, so without TC_EXPORT (src/tc_export.h) it strips them as unused. A
# debug build hides the loss, because Xcode leaves the code in an unstripped
# Runner.debug.dylib; only a release build shows it, and only at the first
# FFI lookup on a device. The list is read from the headers, so a newly
# exported function is checked without anyone remembering to add it.
#
# Usage:
#   tool/check_ios_symbols.sh example/build/ios/iphoneos/Runner.app/Runner

set -euo pipefail

binary="$1"
here="$(cd "$(dirname "$0")/.." && pwd)"

# backend_loader.h is Android only.
headers=("$here/src/audio_ring.h" "$here/src/silero_vad.h" "$here/src/transcribe_shim.h")
names="$(grep -h '^TC_EXPORT' "${headers[@]}" | sed -E 's/^.*[ *]([A-Za-z_0-9]+)[[:space:]]*\(.*$/\1/')"
present="$(nm -gU "$binary")"

missing=0
count=0
for name in $names; do
  count=$((count + 1))
  if ! grep -q "[[:space:]]_${name}\$" <<<"$present"; then
    echo "missing: $name" >&2
    missing=$((missing + 1))
  fi
done

if ((missing > 0)); then
  echo "$missing of $count exported functions were stripped from $binary" >&2
  exit 1
fi
echo "all $count exported functions present"
