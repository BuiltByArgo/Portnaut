#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: scripts/build.sh [debug|release]" >&2
  exit 1
fi
build_dir="${PORTNAUT_BUILD_DIR:-"$project/.build/app"}"
app="$project/build/Portnaut.app"
swift build --package-path "$project" --scratch-path "$build_dir" -c "$configuration"
bin="$(swift build --package-path "$project" --scratch-path "$build_dir" -c "$configuration" --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin/Portnaut" "$app/Contents/MacOS/Portnaut"
cp "$bin/portnaut-doctor" "$app/Contents/Helpers/portnaut-doctor"
# Wine and the game run as x86_64 under Rosetta; arm64 keeps native test runs working.
clang -dynamiclib -arch x86_64 -arch arm64 -mmacosx-version-min=14.0 -O2 -fno-objc-arc -Wall -Wextra -Wno-unused-parameter \
  -framework Foundation -framework Metal "$project/Shims/PortnautMetalShim.m" -o "$app/Contents/Helpers/libPortnautMetalShim.dylib"
cp "$project/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$project/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$project/Info.plist" "$app/Contents/Info.plist"
iconset="$build_dir/Portnaut.iconset"
mkdir -p "$iconset"
swift "$project/scripts/make-icon.swift" "$project/Icon/portnaut-icon.svg" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Portnaut.icns"
codesign --force --sign - "$app/Contents/Helpers/portnaut-doctor"
codesign --force --sign - "$app/Contents/Helpers/libPortnautMetalShim.dylib"
codesign --force --sign - "$app"
echo "Built $app"
