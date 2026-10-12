#!/usr/bin/env bash
#
# Fetch the transcribe.cpp engine for iOS into
# ios/transcribe_cpp/Frameworks/TranscribeCpp.xcframework, where SwiftPM and
# the podspec pick it up.
#
# This is upstream's own release artifact, not a build of ours: the same
# dynamic xcframework transcribe.cpp's Swift binding ships, with Metal on the
# device slice. The download is checked against the SHA-256 pinned below, so
# a release asset replaced after the fact is refused rather than shipped. It
# is then trimmed to the two slices an iOS app links; upstream's macOS slice
# would only add size to every app that depends on this plugin.
#
# The binaries are not committed. CI runs this before building and before
# publishing, so the pub.dev package carries them; run it yourself after
# cloning, or when ENGINE_REF changes.
#
# Usage:
#   tool/fetch_ios_engine.sh

set -euo pipefail

ENGINE_REF=v0.3.1
ZIP_SHA256=9fbd7fa74bf2cf903ee291d3fa98a02c5bd1cf07dda6adbc4f64c3a68be287ca
URL="https://github.com/handy-computer/transcribe.cpp/releases/download/$ENGINE_REF/TranscribeCpp.xcframework.zip"
KEEP=(ios-arm64 ios-arm64_x86_64-simulator)

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/ios/transcribe_cpp/Frameworks/TranscribeCpp.xcframework"

catalog_ref="$(sed -n "s/^const _engineRef = '\(.*\)';/\1/p" "$here/lib/src/catalog.g.dart")"
if [[ "$catalog_ref" != "$ENGINE_REF" ]]; then
  echo "catalog.g.dart is generated from $catalog_ref, this script fetches $ENGINE_REF" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/engine.zip" "$URL"
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$work/engine.zip" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$work/engine.zip" | cut -d' ' -f1)"
fi
if [[ "$actual" != "$ZIP_SHA256" ]]; then
  echo "TranscribeCpp.xcframework.zip has SHA-256 $actual, expected $ZIP_SHA256" >&2
  exit 1
fi

unzip -q "$work/engine.zip" -d "$work/out"
fw="$work/out/TranscribeCpp.xcframework"

# Drop every slice but the iOS ones, from the directory and from the
# xcframework's index of slices alike, so neither names something missing.
for slice in "$fw"/*/; do
  slice="$(basename "$slice")"
  keep=false
  for k in "${KEEP[@]}"; do [[ "$slice" == "$k" ]] && keep=true; done
  $keep || rm -rf "${fw:?}/$slice"
done
# The licence texts upstream bundles are in THIRD-PARTY-LICENSES.md.
rm -f "$fw"/LICENSE*
python3 - "$fw/Info.plist" "${KEEP[@]}" <<'EOF'
import plistlib, sys
path, keep = sys.argv[1], set(sys.argv[2:])
with open(path, 'rb') as f:
    plist = plistlib.load(f)
libs = plist['AvailableLibraries']
plist['AvailableLibraries'] = [l for l in libs if l['LibraryIdentifier'] in keep]
missing = keep - {l['LibraryIdentifier'] for l in plist['AvailableLibraries']}
if missing:
    sys.exit(f'upstream xcframework has no slice {sorted(missing)}')
with open(path, 'wb') as f:
    plistlib.dump(plist, f)
EOF

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$fw" "$dest"

echo "transcribe.cpp $ENGINE_REF xcframework:"
( cd "$dest" && find . -name CTranscribe -type f -exec ls -l {} + | awk '{print $5, $9}' )
