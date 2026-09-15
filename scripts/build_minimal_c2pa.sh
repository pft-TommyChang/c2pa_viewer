#!/usr/bin/env bash

set -euo pipefail

# Builds the C2PA C FFI used by both mobile bindings with only local file I/O
# and native Rust crypto. The output is intentionally kept outside the repo;
# Android consumes the archives through c2paArchiveDir and iOS copies the
# generated XCFramework into ios/Frameworks for the app target to link.
#
# The default C ABI supports the legacy C entry points used by the C2PA Swift
# bridge that is vendored in ios/Runner. c2pa-c-ffi 0.90 removed
# c2pa_read_file, c2pa_read_ingredient_file, and c2pa_sign_file.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${C2PA_BUILD_DIR:-$ROOT_DIR/.c2pa-minimal-build}"
C2PA_REF="${C2PA_REF:-c2pa-c-ffi-v0.85.2}"

command -v xcodebuild >/dev/null || { echo "xcodebuild is required" >&2; exit 1; }

# Keep cargo, rustc, and iOS targets in the same Rust sysroot. This prevents a
# Homebrew cargo from invoking a different rustc than the rustup targets.
if command -v rustup >/dev/null; then
  RUSTUP_TOOLCHAIN="${C2PA_RUSTUP_TOOLCHAIN:-stable}"
  CARGO=(rustup run "$RUSTUP_TOOLCHAIN" cargo)
  RUSTC="$(rustup which --toolchain "$RUSTUP_TOOLCHAIN" rustc)"
  RUSTDOC="$(rustup which --toolchain "$RUSTUP_TOOLCHAIN" rustdoc)"
else
  command -v cargo >/dev/null || { echo "cargo is required" >&2; exit 1; }
  command -v rustc >/dev/null || { echo "rustc is required" >&2; exit 1; }
  CARGO=(cargo)
  RUSTC="$(command -v rustc)"
  RUSTDOC="$(command -v rustdoc)"
fi

RUST_MAJOR="$("$RUSTC" --version | awk '{print $2}' | cut -d. -f1)"
RUST_MINOR="$("$RUSTC" --version | awk '{print $2}' | cut -d. -f2)"
if (( RUST_MAJOR < 1 || (RUST_MAJOR == 1 && RUST_MINOR < 88) )); then
  echo "C2PA 0.85.2 requires Rust 1.88 or newer" >&2
  exit 1
fi

SRC_DIR="$WORK_DIR/c2pa-rs"
TARGET_DIR="$WORK_DIR/target"
ARCHIVE_DIR="$WORK_DIR/android-archives"
IOS_DIR="$WORK_DIR/ios"

mkdir -p "$WORK_DIR" "$ARCHIVE_DIR" "$IOS_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --filter=blob:none https://github.com/contentauth/c2pa-rs.git "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --depth 1 origin "$C2PA_REF"
git -C "$SRC_DIR" checkout --detach FETCH_HEAD

# c2pa-c-ffi 0.85.2 hard-codes optional PDF and remote-manifest features in its
# dependency declaration. Remove those defaults for this mobile-only build.
perl -0pi -e 's/features = \[\n    "fetch_remote_manifests",\n    "file_io",\n    "pdf",\n\]/features = ["file_io"]/s' "$SRC_DIR/c2pa_c_ffi/Cargo.toml"

FEATURES="rust_native_crypto,file_io"
build_target() {
  local target="$1"
  local out="$TARGET_DIR/$target/release"
  RUSTC="$RUSTC" RUSTDOC="$RUSTDOC" "${CARGO[@]}" build --manifest-path "$SRC_DIR/Cargo.toml" --target-dir "$TARGET_DIR" \
    --release -p c2pa-c-ffi --no-default-features --features "$FEATURES" --target "$target"
  mkdir -p "$out/include" "$out/lib"
  cp "$out/c2pa.h" "$out/include/c2pa.h"
}

if [[ "${SKIP_IOS:-0}" != 1 ]]; then
  if command -v rustup >/dev/null; then
    rustup target add --toolchain "$RUSTUP_TOOLCHAIN" \
      aarch64-apple-ios aarch64-apple-ios-sim
  fi
  build_target aarch64-apple-ios
  build_target aarch64-apple-ios-sim
  xcodebuild -create-xcframework \
    -library "$TARGET_DIR/aarch64-apple-ios/release/libc2pa_c.a" \
    -headers "$TARGET_DIR/aarch64-apple-ios/release/include" \
    -library "$TARGET_DIR/aarch64-apple-ios-sim/release/libc2pa_c.a" \
    -headers "$TARGET_DIR/aarch64-apple-ios-sim/release/include" \
    -output "$IOS_DIR/C2PAC.xcframework"
  for headers in "$IOS_DIR/C2PAC.xcframework"/*/Headers; do
    cp "$ROOT_DIR/scripts/C2PAC.module.modulemap" "$headers/module.modulemap"
  done
fi

if [[ "${SKIP_ANDROID:-0}" != 1 ]]; then
  NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [[ -z "$NDK_ROOT" ]]; then
    NDK_ROOT="$(find "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
  fi
  NDK_BIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"
  [[ -x "$NDK_BIN/aarch64-linux-android34-clang" ]] || {
    echo "Android NDK clang toolchain is required; set ANDROID_NDK_HOME or SKIP_ANDROID=1" >&2
    exit 1
  }
  for target in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
    case "$target" in
      aarch64-linux-android) linker="$NDK_BIN/aarch64-linux-android34-clang";;
      armv7-linux-androideabi) linker="$NDK_BIN/armv7a-linux-androideabi27-clang";;
      i686-linux-android) linker="$NDK_BIN/i686-linux-android35-clang";;
      x86_64-linux-android) linker="$NDK_BIN/x86_64-linux-android29-clang";;
    esac
    target_env="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')"
    env "CARGO_TARGET_${target_env}_LINKER=$linker" \
      "CC_${target_env}=$linker" \
      RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" \
      RUSTC="$RUSTC" RUSTDOC="$RUSTDOC" "${CARGO[@]}" build --manifest-path "$SRC_DIR/Cargo.toml" --target-dir "$TARGET_DIR" \
      --release -p c2pa-c-ffi --no-default-features --features "$FEATURES" --target "$target"
    out="$TARGET_DIR/$target/release"
    mkdir -p "$out/include" "$out/lib"
    cp "$out/c2pa.h" "$out/include/c2pa.h"
    cp "$out/libc2pa_c.so" "$out/lib/libc2pa_c.so"
    (cd "$out" && zip -9 -qr "$ARCHIVE_DIR/c2pa-minimal-$target.zip" include lib)
  done
fi

echo "Minimal C2PA artifacts written to $WORK_DIR"
