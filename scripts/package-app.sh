#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [--version X.Y.Z] [--build N]

  --version, -v   CFBundleShortVersionString
                  (default: Resources/Info.plist, or a positional X.Y.Z)
  --build         CFBundleVersion
                  (default: $GITHUB_RUN_NUMBER in CI, otherwise --version)
  --help, -h      Show this help

Examples:
  scripts/package-app.sh
  scripts/package-app.sh 1.2.0
  scripts/package-app.sh --version 1.2.0 --build 18
EOF
}

VERSION=""
BUILD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      if [[ $# -lt 2 ]]; then
        echo "missing value for $1" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    --build)
      if [[ $# -lt 2 ]]; then
        echo "missing value for $1" >&2
        exit 1
      fi
      BUILD="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

read_plist_string() {
  plutil -extract "$1" raw -o - Resources/Info.plist | tr -d '\r\n'
}

if [[ -z "$VERSION" ]]; then
  VERSION="$(read_plist_string CFBundleShortVersionString)"
fi

if [[ -z "$VERSION" || "$VERSION" == *"/"* || "$VERSION" == *".."* ]] \
  || ! [[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*([.-][0-9A-Za-z]+)*$ ]]; then
  echo "invalid version: ${VERSION:-<empty>}" >&2
  exit 1
fi

if [[ -z "$BUILD" ]]; then
  if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    BUILD="$GITHUB_RUN_NUMBER"
  else
    BUILD="${VERSION%%-*}"
  fi
fi

if [[ -z "$BUILD" || "$BUILD" == *"/"* ]] \
  || ! [[ "$BUILD" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "invalid build: ${BUILD:-<empty>}" >&2
  exit 1
fi

swift build -c release --product ResourceSteward

APP="dist/ResourceSteward.app"
BIN=".build/release/ResourceSteward"
ICON_PNG="Resources/AppIcon.png"
ZIP="dist/ResourceSteward-${VERSION}.zip"

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
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
if [[ ! -f "$ICON_PNG" ]]; then
  echo "missing $ICON_PNG" >&2
  exit 1
fi
build_icns "$ICON_PNG" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [[ "${CI:-}" == "true" ]]; then
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zipped $ZIP"
fi

echo "Built $APP"
echo "Version $VERSION ($BUILD)"
echo "Launch with: open $APP"
