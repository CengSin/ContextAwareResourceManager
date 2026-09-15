#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ResourceSteward

APP="dist/ResourceSteward.app"
BIN=".build/release/ResourceSteward"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ResourceSteward"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Launch with: open $APP"
