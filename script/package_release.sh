#!/usr/bin/env bash
set -euo pipefail

# Build and package a Developer ID-signed macOS prerelease. This intentionally
# does not redistribute the host's FFmpeg binaries; that dependency still has
# an open licensing and self-contained-packaging decision in this project.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Yearly Interview Studio"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-1}"

if [[ -z "$VERSION" || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "VERSION and BUILD_NUMBER must contain a version and a numeric build." >&2
  exit 1
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "SIGNING_IDENTITY must name a Developer ID Application certificate." >&2
  exit 1
fi

if [[ -n "${RELEASE_ROOT:-}" ]]; then
  RELEASE_ROOT="$RELEASE_ROOT"
  mkdir -p "$RELEASE_ROOT"
else
  RELEASE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/interview-studio-release.XXXXXX")"
fi

BUILD_OUTPUT_DIR="$RELEASE_ROOT/app-output"
ASSET_DIR="$RELEASE_ROOT/assets"
mkdir -p "$ASSET_DIR"

BUILD_CONFIGURATION=release \
PRESERVE_BUILD_NUMBER=1 \
BUNDLE_HOST_TOOLS=0 \
OUTPUT_DIR="$BUILD_OUTPUT_DIR" \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  "$ROOT_DIR/script/build_and_run.sh" build

APP_PATH="$BUILD_OUTPUT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced at $APP_PATH." >&2
  exit 1
fi

if [[ "$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")" != "$BUILD_NUMBER" ]]; then
  echo "Release packaging changed BUILD_NUMBER; release builds must use the checked-in value." >&2
  exit 1
fi
if [[ -e "$APP_PATH/Contents/Resources/BundledTools/ffmpeg" || -e "$APP_PATH/Contents/Resources/BundledTools/ffprobe" ]]; then
  echo "Release packaging unexpectedly included host FFmpeg tools." >&2
  exit 1
fi

SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNATURE_DETAILS"
grep -q 'Authority=Developer ID Application:' <<< "$SIGNATURE_DETAILS"
grep -q 'runtime' <<< "$SIGNATURE_DETAILS"
grep -q 'Timestamp=' <<< "$SIGNATURE_DETAILS"
ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true)"
if grep -q 'com.apple.security.get-task-allow' <<< "$ENTITLEMENTS"; then
  echo "Release app contains the development-only get-task-allow entitlement." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

NOTARIZATION_ZIP="$ASSET_DIR/${APP_NAME// /-}-$VERSION-$BUILD_NUMBER-notarization.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZATION_ZIP"

if [[ "$NOTARIZE" == "1" ]]; then
  NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
  NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
  NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
  if [[ ! -f "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
    echo "NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID are required when NOTARIZE=1." >&2
    exit 1
  fi

  NOTARY_RESPONSE="$RELEASE_ROOT/notary-response.json"
  if ! /usr/bin/xcrun notarytool submit "$NOTARIZATION_ZIP" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$NOTARY_RESPONSE"; then
    cat "$NOTARY_RESPONSE" >&2 || true
    exit 1
  fi
  if ! /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$NOTARY_RESPONSE"; then
    cat "$NOTARY_RESPONSE" >&2
    echo "Apple notarization did not return Accepted." >&2
    exit 1
  fi

  /usr/bin/xcrun stapler staple "$APP_PATH"
  /usr/bin/xcrun stapler validate "$APP_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
else
  echo "Warning: NOTARIZE=0; the output is signed but not notarized or stapled." >&2
fi

FINAL_ZIP="$ASSET_DIR/${APP_NAME// /-}-$VERSION-$BUILD_NUMBER.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
/usr/bin/ditto -x -k "$FINAL_ZIP" "$RELEASE_ROOT/final-unpacked"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$RELEASE_ROOT/final-unpacked/$APP_NAME.app"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "asset=$FINAL_ZIP"
    echo "version=$VERSION"
    echo "build_number=$BUILD_NUMBER"
  } >> "$GITHUB_OUTPUT"
fi

echo "Release asset: $FINAL_ZIP"
