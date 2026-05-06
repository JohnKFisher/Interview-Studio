#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="YearlyInterviewStudioApp"
BUNDLE_NAME="Yearly Interview Studio"
BUNDLE_ID="com.jkfisher.yearlyinterviewstudio"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SCRATCH_PATH="$ROOT_DIR/.build-codex"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

SYSTEM_FFMPEG="$(command -v ffmpeg || true)"
SYSTEM_FFPROBE="$(command -v ffprobe || true)"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$BUNDLE_NAME" >/dev/null 2>&1 || true

swift build --scratch-path "$SCRATCH_PATH" --product "$APP_NAME"
BUILD_BINARY="$(swift build --scratch-path "$SCRATCH_PATH" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/BundledTools"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -n "$SYSTEM_FFMPEG" ]]; then
  cp "$SYSTEM_FFMPEG" "$APP_RESOURCES/BundledTools/ffmpeg"
  chmod +x "$APP_RESOURCES/BundledTools/ffmpeg"
fi

if [[ -n "$SYSTEM_FFPROBE" ]]; then
  cp "$SYSTEM_FFPROBE" "$APP_RESOURCES/BundledTools/ffprobe"
  chmod +x "$APP_RESOURCES/BundledTools/ffprobe"
fi

/usr/bin/env python3 - <<'PY' "$INFO_PLIST" "$APP_NAME" "$BUNDLE_ID" "$BUNDLE_NAME" "$MIN_SYSTEM_VERSION"
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("wb") as handle:
    plistlib.dump(
        {
            "CFBundleDisplayName": sys.argv[4],
            "CFBundleExecutable": sys.argv[2],
            "CFBundleIdentifier": sys.argv[3],
            "CFBundleName": sys.argv[4],
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "2",
            "LSMinimumSystemVersion": sys.argv[5],
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
        },
        handle,
    )
PY

/usr/bin/codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build|--build)
    echo "Built $APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
