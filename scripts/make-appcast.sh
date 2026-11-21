#!/bin/bash
# Makes appcast.xml, the file Portnaut's updater reads, for a release zip from package-release.sh.
#   scripts/make-appcast.sh release-assets/Portnaut-0.13.0.zip [RELEASE-NOTES-0.13.0.md]
# Upload both files to the GitHub release (tag = the version, e.g. 0.13.0). Portnaut checks
# https://github.com/BuiltByArgo/Portnaut/releases/latest/download/appcast.xml, so the newest
# published release (not a pre-release or draft) is what everyone is offered.
# The zip is signed with the update key in the login Keychain, account "portnaut" (made on 20 November
# 2026 with Sparkle's generate_keys; restore a backup with generate_keys --account portnaut -f <file>).
# Test runs only: PORTNAUT_SPARKLE_KEY_FILE (a test key), PORTNAUT_UPDATE_DOWNLOAD_URL, PORTNAUT_APPCAST_OUT.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
zip="${1:?usage: scripts/make-appcast.sh <Portnaut-version.zip> [release-notes.md]}"
notes="${2:-}"
repository="https://github.com/BuiltByArgo/Portnaut"
tools="${PORTNAUT_BUILD_DIR:-"$project/.build/app"}/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/sign_update" ]] || { echo "Sparkle's tools are missing; run scripts/build.sh first." >&2; exit 1; }
[[ -z "$notes" || -f "$notes" ]] || { echo "No release notes at $notes" >&2; exit 1; }
# Read the version from the app inside the zip, so the feed can't disagree with it.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto -x -k "$zip" "$stage"
plist="$stage/Portnaut.app/Contents/Info.plist"
[[ -f "$plist" ]] || { echo "$zip does not contain Portnaut.app" >&2; exit 1; }
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
short=$(read_plist CFBundleShortVersionString)
build=$(read_plist CFBundleVersion)
minimum=$(read_plist LSMinimumSystemVersion)
[[ "$minimum" =~ ^[0-9]+\.[0-9]+$ ]] && minimum="$minimum.0"
key_args=(--account portnaut)
[[ -n "${PORTNAUT_SPARKLE_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$PORTNAUT_SPARKLE_KEY_FILE")
signature=$("$tools/sign_update" ${key_args[@]+"${key_args[@]}"} "$zip")
url="${PORTNAUT_UPDATE_DOWNLOAD_URL:-$repository/releases/download/$short/$(basename "$zip")}"
out="${PORTNAUT_APPCAST_OUT:-$(dirname "$zip")/appcast.xml}"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  echo '  <channel>'
  echo '    <title>Portnaut</title>'
  echo "    <link>$repository/releases</link>"
  echo '    <item>'
  echo "      <title>Portnaut $short</title>"
  echo "      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>"
  echo "      <sparkle:version>$build</sparkle:version>"
  echo "      <sparkle:shortVersionString>$short</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>"
  echo "      <sparkle:fullReleaseNotesLink>$repository/releases</sparkle:fullReleaseNotesLink>"
  if [[ -n "$notes" ]]; then
    # Shown in Sparkle's update window. CDATA ends at "]]>", so split any in the notes.
    echo -n '      <description sparkle:format="markdown"><![CDATA['
    sed 's/]]>/]]]]><![CDATA[>/g' "$notes"
    echo ']]></description>'
  fi
  echo "      <enclosure url=\"$url\" type=\"application/octet-stream\" $signature/>"
  echo '    </item>'
  echo '  </channel>'
  echo '</rss>'
} > "$out"
xmllint --noout "$out"
echo "Wrote $out for Portnaut $short (build $build). Upload it with $(basename "$zip") to the GitHub release $short."
