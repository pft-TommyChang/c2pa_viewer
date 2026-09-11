#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_LINE="$(awk '/^version:/ {print $2}' "$ROOT_DIR/pubspec.yaml")"
BUILD_NAME="${VERSION_LINE%%+*}"
BUILD_NUMBER="${VERSION_LINE#*+}"

if [[ "$BUILD_NAME" == "$VERSION_LINE" ]]; then
  BUILD_NUMBER="1"
fi

cd "$ROOT_DIR"
flutter pub get
flutter build appbundle \
  --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER"

mkdir -p "$ROOT_DIR/dist"
OUTPUT="$ROOT_DIR/dist/PerfectC2PA-$BUILD_NAME-android.aab"
cp build/app/outputs/bundle/release/app-release.aab "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
printf 'Created %s\nCreated %s.sha256\n' "$OUTPUT" "$OUTPUT"
