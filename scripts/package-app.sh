#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ResourceSteward

APP="dist/ResourceSteward.app"
BIN=".build/release/ResourceSteward"
ICON_PNG="Resources/AppIcon.png"

build_icns() {
  local src="$1"
  local dest="$2"
  local workdir iconset
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/AppIcon.XXXXXX")"
  iconset="$workdir/AppIcon.iconset"
  mkdir -p "$iconset"
  sips -s format png -z 16 16 "$src" --out "$iconset/icon_16x16.png" >/dev/null
  sips -s format png -z 32 32 "$src" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -s format png -z 32 32 "$src" --out "$iconset/icon_32x32.png" >/dev/null
  sips -s format png -z 64 64 "$src" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -s format png -z 128 128 "$src" --out "$iconset/icon_128x128.png" >/dev/null
  sips -s format png -z 256 256 "$src" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -s format png -z 256 256 "$src" --out "$iconset/icon_256x256.png" >/dev/null
  sips -s format png -z 512 512 "$src" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -s format png -z 512 512 "$src" --out "$iconset/icon_512x512.png" >/dev/null
  sips -s format png -z 1024 1024 "$src" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$dest"
  rm -rf "$workdir"
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ResourceSteward"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f "$ICON_PNG" ]]; then
  echo "missing $ICON_PNG" >&2
  exit 1
fi
build_icns "$ICON_PNG" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [[ "${CI:-}" == "true" ]]; then
  ditto -c -k --keepParent "$APP" "dist/ResourceSteward.app.zip"
  echo "Zipped dist/ResourceSteward.app.zip"
fi

echo "Built $APP"
echo "Launch with: open $APP"
