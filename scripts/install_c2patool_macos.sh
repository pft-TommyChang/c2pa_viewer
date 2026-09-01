#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <app-path>" >&2
  exit 1
fi

APP_PATH="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly C2PATOOL_VERSION="0.27.6"
readonly C2PATOOL_ARCHIVE_SHA256="9af980fa45b980cb932434876481aec497e4c1804310af2af34cf8f8a1897d1e"
readonly C2PA_TRUST_LIST_METADATA_URL="https://raw.githubusercontent.com/c2pa-org/conformance-public/refs/heads/main/trust-list/C2PA-TRUST-LIST.json"
readonly CAI_TRUST_ANCHORS_URL="https://verify.contentauthenticity.org/trust/anchors.pem"
readonly CAI_ALLOWED_LIST_URL="https://verify.contentauthenticity.org/trust/allowed.sha256.txt"
readonly CAI_TRUST_CONFIG_URL="https://verify.contentauthenticity.org/trust/store.cfg"
C2PATOOL_ARCHIVE="c2patool-v${C2PATOOL_VERSION}-universal-apple-darwin.zip"
C2PATOOL_URL="https://github.com/contentauth/c2pa-rs/releases/download/c2patool-v${C2PATOOL_VERSION}/${C2PATOOL_ARCHIVE}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SOURCE_BINARY="${C2PATOOL_PATH:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ -z "$SOURCE_BINARY" ]]; then
  curl --fail --location --silent --show-error \
    "$C2PATOOL_URL" \
    --output "$WORK_DIR/$C2PATOOL_ARCHIVE"

  ACTUAL_SHA256="$(shasum -a 256 "$WORK_DIR/$C2PATOOL_ARCHIVE" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$C2PATOOL_ARCHIVE_SHA256" ]]; then
    echo "c2patool checksum mismatch: $ACTUAL_SHA256" >&2
    exit 1
  fi

  ditto -x -k "$WORK_DIR/$C2PATOOL_ARCHIVE" "$WORK_DIR/extracted"
  SOURCE_BINARY="$WORK_DIR/extracted/c2patool/c2patool"
elif [[ ! -x "$SOURCE_BINARY" ]]; then
  echo "C2PATOOL_PATH is not executable: $SOURCE_BINARY" >&2
  exit 1
fi

TARGET_BINARY="$APP_PATH/Contents/Resources/c2patool"
mkdir -p "$(dirname "$TARGET_BINARY")"

if [[ -n "${C2PATOOL_PATH:-}" ]]; then
  cp "$SOURCE_BINARY" "$TARGET_BINARY"
else
  PACKAGE_ARCH="${PACKAGE_ARCH:-$(uname -m)}"
  case "$PACKAGE_ARCH" in
    arm64|aarch64)
      lipo "$SOURCE_BINARY" -thin arm64 -output "$TARGET_BINARY"
      ;;
    x86_64|amd64|x64)
      lipo "$SOURCE_BINARY" -thin x86_64 -output "$TARGET_BINARY"
      ;;
    *)
      cp "$SOURCE_BINARY" "$TARGET_BINARY"
      ;;
  esac
fi
chmod 755 "$TARGET_BINARY"

"$TARGET_BINARY" \
  --settings "$APP_PATH/Contents/Resources/c2pa.toml" \
  init trust
curl --fail --location --silent --show-error \
  "$CAI_TRUST_ANCHORS_URL" \
  --output "$APP_PATH/Contents/Resources/c2pa-trust-list-legacy.pem"
curl --fail --location --silent --show-error \
  "$CAI_ALLOWED_LIST_URL" \
  --output "$APP_PATH/Contents/Resources/c2pa-trust-allowed.sha256.txt"
curl --fail --location --silent --show-error \
  "$CAI_TRUST_CONFIG_URL" \
  --output "$APP_PATH/Contents/Resources/c2pa-trust-store.cfg"
curl --fail --location --silent --show-error \
  "$C2PA_TRUST_LIST_METADATA_URL" \
  --output "$APP_PATH/Contents/Resources/c2pa-trust-list.json"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$ROOT_DIR/macos/Runner/Release.entitlements}"
HELPER_ENTITLEMENTS="$ROOT_DIR/macos/Runner/C2paTool.entitlements"
codesign \
  --force \
  --entitlements "$HELPER_ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$TARGET_BINARY"
codesign \
  --force \
  --entitlements "$APP_ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

echo "Installed c2patool ${C2PATOOL_VERSION} and the C2PA trust list at $TARGET_BINARY"
