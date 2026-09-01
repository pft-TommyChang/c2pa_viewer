#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <app-path> <sign-identity>" >&2
  exit 1
fi

APP_PATH="$1"
SIGN_IDENTITY="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_BINARY="${C2PATOOL_PATH:-}"
readonly C2PATOOL_VERSION="0.27.6"
readonly C2PATOOL_ARCHIVE_SHA256="9af980fa45b980cb932434876481aec497e4c1804310af2af34cf8f8a1897d1e"
C2PATOOL_ARCHIVE="c2patool-v${C2PATOOL_VERSION}-universal-apple-darwin.zip"
C2PATOOL_URL="https://github.com/contentauth/c2pa-rs/releases/download/c2patool-v${C2PATOOL_VERSION}/${C2PATOOL_ARCHIVE}"
CACHE_DIR="$ROOT_DIR/macos/Flutter/ephemeral/c2patool-$C2PATOOL_VERSION"
CACHE_BINARY="$CACHE_DIR/c2patool"

if [[ -z "$SOURCE_BINARY" ]]; then
  SOURCE_BINARY="$CACHE_BINARY"
fi

if [[ ! -x "$SOURCE_BINARY" ]]; then
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  curl --fail --location --silent --show-error \
    "$C2PATOOL_URL" \
    --output "$WORK_DIR/$C2PATOOL_ARCHIVE"

  ACTUAL_SHA256="$(shasum -a 256 "$WORK_DIR/$C2PATOOL_ARCHIVE" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$C2PATOOL_ARCHIVE_SHA256" ]]; then
    echo "c2patool checksum mismatch: $ACTUAL_SHA256" >&2
    exit 1
  fi

  ditto -x -k "$WORK_DIR/$C2PATOOL_ARCHIVE" "$WORK_DIR/extracted"
  mkdir -p "$CACHE_DIR"
  case "$(uname -m)" in
    arm64|aarch64)
      lipo "$WORK_DIR/extracted/c2patool/c2patool" -thin arm64 -output "$CACHE_BINARY"
      ;;
    x86_64|amd64|x64)
      lipo "$WORK_DIR/extracted/c2patool/c2patool" -thin x86_64 -output "$CACHE_BINARY"
      ;;
    *)
      cp "$WORK_DIR/extracted/c2patool/c2patool" "$CACHE_BINARY"
      ;;
  esac
  chmod 755 "$CACHE_BINARY"
  SOURCE_BINARY="$CACHE_BINARY"
fi

TARGET_BINARY="$APP_PATH/Contents/Resources/c2patool"
mkdir -p "$(dirname "$TARGET_BINARY")"
cp -L "$SOURCE_BINARY" "$TARGET_BINARY"
chmod 755 "$TARGET_BINARY"
/usr/bin/xattr -cr "$TARGET_BINARY" || true

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

/usr/bin/codesign \
  --force \
  --entitlements "$ROOT_DIR/macos/Runner/C2paTool.entitlements" \
  --sign "$SIGN_IDENTITY" \
  "$TARGET_BINARY"

echo "Embedded c2patool at $TARGET_BINARY"
