#!/bin/bash
# Tests metadata sizing with disposable SQLite fixtures; never opens a personal library.
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 PhotosSizeIndex.swift Tests/main.swift -o "$TEST_DIR/size-index-tests"
"$TEST_DIR/size-index-tests"
