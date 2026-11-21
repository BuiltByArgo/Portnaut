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
# Highball's compatibility database with its licences; scripts/update-compatibility.sh refreshes it.
rm -rf "$app/Contents/Resources/Compatibility"
cp -R "$project/Compatibility" "$app/Contents/Resources/Compatibility"
cp "$project/Info.plist" "$app/Contents/Info.plist"
# Sparkle, for Portnaut's own updates. Keep its symlinks (ditto); a non-sandboxed app needs none of
# its XPC services, so remove them and the symlink that points at them.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle"
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
cp "$build_dir/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
# Test builds only (scripts/package-release.sh refuses them): another update key, feed, identity or version.
plist="$app/Contents/Info.plist"
setplist() { /usr/libexec/PlistBuddy -c "Delete :$1" "$plist" >/dev/null 2>&1 || true; /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$plist"; }
[[ -n "${PORTNAUT_SPARKLE_PUBLIC_KEY:-}" ]] && setplist SUPublicEDKey string "$PORTNAUT_SPARKLE_PUBLIC_KEY"
[[ -n "${PORTNAUT_BUNDLE_ID:-}" ]] && setplist CFBundleIdentifier string "$PORTNAUT_BUNDLE_ID"
[[ -n "${PORTNAUT_VERSION:-}" ]] && setplist CFBundleShortVersionString string "$PORTNAUT_VERSION"
[[ -n "${PORTNAUT_BUILD_NUMBER:-}" ]] && setplist CFBundleVersion string "$PORTNAUT_BUILD_NUMBER"
if [[ -n "${PORTNAUT_SPARKLE_FEED:-}" ]]; then
  setplist SUFeedURL string "$PORTNAUT_SPARKLE_FEED"
  # A feed served from this Mac for testing is plain http.
  if [[ "$PORTNAUT_SPARKLE_FEED" == http://127.0.0.1:* ]]; then
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
  fi
fi
iconset="$build_dir/Portnaut.iconset"
mkdir -p "$iconset"
swift "$project/scripts/make-icon.swift" "$project/Icon/portnaut-icon.svg" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Portnaut.icns"
# Inside out and never --deep: Sparkle's helpers keep Sparkle's own signatures; the framework is
# resealed because its XPC services were removed.
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$sparkle"
codesign --force --sign - "$app/Contents/Helpers/portnaut-doctor"
codesign --force --sign - "$app/Contents/Helpers/libPortnautMetalShim.dylib"
codesign --force --sign - "$app"
echo "Built $app"
