#!/bin/bash
# Builds Portnaut and packs it for a GitHub release: Portnaut-<version>.zip and its SHA-256, in
# release-assets/ (or $PORTNAUT_RELEASE_DIR). ditto zips the app the way Finder's
# Compress does, keeping its signature, symlinks and extended attributes intact.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
bash "$project/scripts/build.sh" release
app="$project/build/Portnaut.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
out="${PORTNAUT_RELEASE_DIR:-$project/release-assets}"
mkdir -p "$out"
zip="Portnaut-$version.zip"
rm -f "$out/$zip" "$out/$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip"
(cd "$out" && shasum -a 256 "$zip" | tee "$zip.sha256")
ls -l "$out/$zip"
