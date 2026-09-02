#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="YearlyInterviewStudioApp"
BUNDLE_NAME="Yearly Interview Studio"
BUNDLE_ID="com.jkfisher.yearlyinterviewstudio"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
MARKETING_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
CURRENT_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
if [[ -z "$MARKETING_VERSION" || ! "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "VERSION and BUILD_NUMBER must contain a version and a numeric build." >&2
  exit 1
fi
BUILD_NUMBER="$((CURRENT_BUILD_NUMBER + 1))"
PACKAGE_DIR="${TMPDIR:-/tmp}/YearlyInterviewStudio-package-$BUILD_NUMBER"
SCRATCH_PATH="${TMPDIR:-/tmp}/interview-studio-build-$RANDOM"
APP_BUNDLE="$PACKAGE_DIR/$BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/App/Resources/AppIcon.icns"

SYSTEM_FFMPEG="$(command -v ffmpeg || true)"
SYSTEM_FFPROBE="$(command -v ffprobe || true)"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Yearly Interview Studio requires Apple Silicon (arm64)." >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$BUNDLE_NAME" >/dev/null 2>&1 || true

swift build --scratch-path "$SCRATCH_PATH" --product "$APP_NAME"
BUILD_BINARY="$(swift build --scratch-path "$SCRATCH_PATH" --show-bin-path)/$APP_NAME"

printf '%s\n' "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/BundledTools"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -n "$SYSTEM_FFMPEG" && -n "$SYSTEM_FFPROBE" ]]; then
  cp "$SYSTEM_FFMPEG" "$APP_RESOURCES/BundledTools/ffmpeg"
  cp "$SYSTEM_FFPROBE" "$APP_RESOURCES/BundledTools/ffprobe"
  chmod +x "$APP_RESOURCES/BundledTools/ffmpeg" "$APP_RESOURCES/BundledTools/ffprobe"
  {
    echo "bundle_status=host_tools_copied_for_local_build"
    echo "ffmpeg_version=$("$SYSTEM_FFMPEG" -version | sed -n '1p')"
    echo "ffprobe_version=$("$SYSTEM_FFPROBE" -version | sed -n '1p')"
    echo "ffmpeg_sha256=$(shasum -a 256 "$SYSTEM_FFMPEG" | awk '{print $1}')"
    echo "ffprobe_sha256=$(shasum -a 256 "$SYSTEM_FFPROBE" | awk '{print $1}')"
  } > "$APP_RESOURCES/BundledTools/PROVENANCE.txt"
else
  echo "FFmpeg and FFprobe were not bundled because a complete pair was not found; runtime discovery will use other candidates." >&2
  echo "bundle_status=not_bundled_incomplete_host_pair" > "$APP_RESOURCES/BundledTools/PROVENANCE.txt"
fi

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi
cp "$ROOT_DIR/ATTRIBUTIONS.md" "$APP_RESOURCES/ATTRIBUTIONS.md"

/usr/bin/env python3 - <<'PY' "$INFO_PLIST" "$APP_NAME" "$BUNDLE_ID" "$BUNDLE_NAME" "$MIN_SYSTEM_VERSION" "$MARKETING_VERSION" "$BUILD_NUMBER"
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
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": sys.argv[3],
            "CFBundleName": sys.argv[4],
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": sys.argv[6],
            "CFBundleVersion": sys.argv[7],
            "LSMinimumSystemVersion": sys.argv[5],
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
            "NSPhotoLibraryUsageDescription": "Yearly Interview Studio needs access to the Photos videos you explicitly choose to import.",
            "NSSpeechRecognitionUsageDescription": "Yearly Interview Studio can transcribe an interview on this Mac when you explicitly start analysis.",
            "CFBundleDocumentTypes": [
                {
                    "CFBundleTypeName": "Yearly Interview Studio Project",
                    "CFBundleTypeRole": "Editor",
                    "LSItemContentTypes": ["com.jkfisher.yearly-interview-studio.project"],
                }
            ],
            "UTExportedTypeDeclarations": [
                {
                    "UTTypeIdentifier": "com.jkfisher.yearly-interview-studio.project",
                    "UTTypeDescription": "Yearly Interview Studio project",
                    "UTTypeConformsTo": ["com.apple.package"],
                    "UTTypeTagSpecification": {"public.filename-extension": ["interviewstudio"]},
                }
            ],
        },
        handle,
    )
PY

# Finder/FileProvider metadata must not be sealed into the app bundle.
/usr/bin/xattr -rc "$APP_BUNDLE" 2>/dev/null || true

if /usr/bin/codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "Applied ad hoc signing to $APP_BUNDLE"
else
  # FileProvider can reattach FinderInfo while the bundle is being assembled.
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
  if /usr/bin/codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "Applied ad hoc signing to $APP_BUNDLE after removing Finder metadata"
  else
    echo "Warning: ad hoc signing failed; the app bundle is unsigned and is not distribution-ready." >&2
  fi
fi

# Verify after signing; an ad hoc signature is not useful if the bundle seal is invalid.
if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
  if /usr/bin/codesign --force --sign - --deep "$APP_BUNDLE" >/dev/null 2>&1 && /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "Verified strict app signature after removing Finder metadata"
  else
    echo "Warning: strict app signature verification failed; the app is not distribution-ready." >&2
  fi
fi

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
