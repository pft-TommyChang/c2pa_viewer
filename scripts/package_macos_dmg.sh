#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-path> <version> [output-dir]" >&2
  exit 1
fi

APP_PATH="$1"
VERSION="$2"
OUTPUT_DIR="${3:-dist}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
RAW_ARCH="${PACKAGE_ARCH:-$(uname -m)}"

case "$RAW_ARCH" in
  arm64|aarch64)
    PACKAGE_ARCH_NAME="arm64"
    ;;
  x86_64|amd64)
    PACKAGE_ARCH_NAME="x64"
    ;;
  *)
    PACKAGE_ARCH_NAME="$RAW_ARCH"
    ;;
esac

FILE_BASENAME="PerfectC2PA-${VERSION}-macos-${PACKAGE_ARCH_NAME}"
DMG_PATH="${OUTPUT_DIR}/${FILE_BASENAME}.dmg"
SHA_PATH="${OUTPUT_DIR}/${FILE_BASENAME}.sha256"
VOLUME_NAME="${APP_NAME} ${VERSION}"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$SHA_PATH"

echo "Created:"
echo "  $DMG_PATH"
echo "  $SHA_PATH"
