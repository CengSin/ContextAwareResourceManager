#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---verify}"
case "$MODE" in
  --verify|--logs|--telemetry) ;;
  *) echo 'Usage: script/build_and_run.sh [--verify|--logs|--telemetry]' >&2; exit 2 ;;
esac
swift build --product ResourceSteward
BIN_DIR="$(swift build --show-bin-path)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ResourceSteward-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$(pwd)/dist/ResourceSteward.app"
if [[ -d "$APP" ]]; then
  ditto "$APP" "$STAGE/ResourceSteward.app"
else
  mkdir -p "$STAGE/ResourceSteward.app/Contents/MacOS" "$STAGE/ResourceSteward.app/Contents/Resources"
fi
cp "$BIN_DIR/ResourceSteward" "$STAGE/ResourceSteward.app/Contents/MacOS/ResourceSteward"
cp Resources/Info.plist "$STAGE/ResourceSteward.app/Contents/Info.plist"
REVISION="$(git rev-parse --short HEAD)"
if ! git diff --quiet; then REVISION="$REVISION-dirty"; fi
plutil -insert ResourceStewardBuildRevision -string "$REVISION" "$STAGE/ResourceSteward.app/Contents/Info.plist"
plutil -insert ResourceStewardBuildTime -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STAGE/ResourceSteward.app/Contents/Info.plist"
codesign --force --sign - "$STAGE/ResourceSteward.app"
swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "cc.resourcesteward.app") { if !app.terminate() { fputs("Could not request ResourceSteward termination\n", stderr); exit(1) } }'
for ((i=0; i<50; i++)); do
  if ! pgrep -x ResourceSteward >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x ResourceSteward >/dev/null; then echo 'ResourceSteward has not exited; bundle not replaced.' >&2; exit 1; fi
mkdir -p dist
# Keep bundle identity and resources while replacing the validated executable.
ditto "$STAGE/ResourceSteward.app" "$APP"
open -n "$APP"
for ((i=0; i<50; i++)); do
  if pgrep -x ResourceSteward >/dev/null; then break; fi
  sleep 0.1
done
pgrep -x ResourceSteward >/dev/null
echo "Running $APP ($REVISION)"
case "$MODE" in
  --logs) exec /usr/bin/log stream --style compact --level info --predicate 'process == "ResourceSteward"' ;;
  --telemetry) exec /usr/bin/log stream --style compact --level info --predicate 'subsystem BEGINSWITH "cc.resourcesteward"' ;;
esac
