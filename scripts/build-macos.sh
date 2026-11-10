#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/随手记.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/.build/module-cache"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -default-isolation MainActor -parse-as-library \
  -module-cache-path "$PROJECT_DIR/.build/module-cache" \
  -framework AppKit -framework WebKit \
  "$PROJECT_DIR"/native/*.swift -o "$APP_DIR/Contents/MacOS/IslandNote"
cp "$PROJECT_DIR/index.html" "$PROJECT_DIR"/*.js "$PROJECT_DIR"/*.css "$APP_DIR/Contents/Resources/"
if [[ -f "$PROJECT_DIR/native/assets/miffy-reference.png" && -f "$PROJECT_DIR/native/assets/miffy-shape.json" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources/native/assets"
  cp "$PROJECT_DIR/native/assets/miffy-reference.png" "$PROJECT_DIR/native/assets/miffy-shape.json" "$APP_DIR/Contents/Resources/"
  cp "$PROJECT_DIR/native/assets/miffy-reference.png" "$APP_DIR/Contents/Resources/native/assets/"
else
  # Do not retain optional local artwork from a previous build.
  rm -f "$APP_DIR/Contents/Resources/miffy-reference.png" "$APP_DIR/Contents/Resources/miffy-shape.json" "$APP_DIR/Contents/Resources/native/assets/miffy-reference.png"
fi
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IslandNote</string>
<key>CFBundleIdentifier</key><string>com.heshufan.islandnote</string>
<key>CFBundleName</key><string>随手记</string>
<key>CFBundleDisplayName</key><string>随手记</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.5.0</string>
<key>CFBundleVersion</key><string>25</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
