#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${PORTNAUT_TEST_BUILD_DIR:-"$project/.build/tests"}"
developer_dir="$(xcode-select -p)"
plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=()
# Command Line Tools' Swift Build integration needs the macro plugin explicitly.
if [[ -f "$plugin" ]]; then
  args=(-Xswiftc -load-plugin-library -Xswiftc "$plugin")
fi
swift test --package-path "$project" --scratch-path "$build_dir" --disable-xctest "${args[@]}"
