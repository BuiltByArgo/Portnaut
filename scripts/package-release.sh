#!/bin/bash
# Builds Portnaut and packs it for a GitHub release: Portnaut-<version>.zip and its SHA-256, in
# release-assets/ (or $PORTNAUT_RELEASE_DIR). ditto zips the app the way Finder's
# Compress does, keeping its signature, symlinks and extended attributes intact.
# Then scripts/make-appcast.sh makes appcast.xml; upload both to the GitHub release.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
# A release is never a test build: refuse build.sh's test overrides.
for name in PORTNAUT_SPARKLE_PUBLIC_KEY PORTNAUT_SPARKLE_FEED PORTNAUT_BUNDLE_ID PORTNAUT_VERSION PORTNAUT_BUILD_NUMBER; do
  if [[ -n "${!name:-}" ]]; then echo "Refusing to package a release: $name is set (test builds only)." >&2; exit 1; fi
done
bash "$project/scripts/build.sh" release
app="$project/build/Portnaut.app"
codesign --verify --deep --strict "$app"
plist="$app/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
problems=()
[[ "$(read_plist CFBundleIdentifier)" == "com.builtbyargo.portnaut" ]] || problems+=("the bundle identifier is not com.builtbyargo.portnaut")
[[ "$(read_plist SUFeedURL)" == "https://github.com/BuiltByArgo/Portnaut/releases/latest/download/appcast.xml" ]] || problems+=("the update feed is not https://github.com/BuiltByArgo/Portnaut/releases/latest/download/appcast.xml")
[[ -n "$(read_plist SUPublicEDKey)" ]] || problems+=("Info.plist has no SUPublicEDKey: without it, this release could never update itself")
[[ -z "$(read_plist NSAppTransportSecurity)" ]] || problems+=("NSAppTransportSecurity is set (only test builds allow a local feed)")
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || problems+=("Sparkle.framework is missing")
[[ ! -e "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ]] || problems+=("Sparkle's XPC services are still in the app")
if (( ${#problems[@]} )); then
  printf 'Refusing to package a release: %s.\n' "${problems[@]}" >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
out="${PORTNAUT_RELEASE_DIR:-$project/release-assets}"
mkdir -p "$out"
zip="Portnaut-$version.zip"
rm -f "$out/$zip" "$out/$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip"
(cd "$out" && shasum -a 256 "$zip" | tee "$zip.sha256")
ls -l "$out/$zip"
