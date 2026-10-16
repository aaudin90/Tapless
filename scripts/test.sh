#!/usr/bin/env bash
# Юнит-тесты (swift-testing). С Command Line Tools без Xcode SwiftPM не находит
# плагин макросов @Test/#expect — передаём путь к нему явно, если он есть.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
plugin_dir="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugin_dir" ]; then
  args+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
fi
swift test ${args[@]+"${args[@]}"} "$@"
