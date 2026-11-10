#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build/module-cache"
xcrun swiftc -swift-version 6 -default-isolation MainActor -D TESTING -parse-as-library \
  -module-cache-path "$PROJECT_DIR/.build/module-cache" -framework AppKit -framework WebKit \
  "$PROJECT_DIR"/native/*.swift "$PROJECT_DIR/tests/native-tests.swift" -o "$PROJECT_DIR/.build/native-tests"
"$PROJECT_DIR/.build/native-tests"
