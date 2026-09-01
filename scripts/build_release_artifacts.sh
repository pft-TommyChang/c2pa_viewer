#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_LINE="$(awk '/^version:/ {print $2}' "$ROOT_DIR/pubspec.yaml")"
BUILD_NAME="${VERSION_LINE%%+*}"
BUILD_NUMBER="${VERSION_LINE#*+}"
APP_PATH="$ROOT_DIR/build/macos/Build/Products/Release/Perfect C2PA.app"

if [[ "$BUILD_NAME" == "$VERSION_LINE" ]]; then
  BUILD_NUMBER="1"
fi

cd "$ROOT_DIR"
flutter pub get
flutter build macos \
  --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER"

"$ROOT_DIR/scripts/install_c2patool_macos.sh" "$APP_PATH"
"$ROOT_DIR/scripts/package_macos_dmg.sh" \
  "$APP_PATH" \
  "$BUILD_NAME" \
  "$ROOT_DIR/dist"
