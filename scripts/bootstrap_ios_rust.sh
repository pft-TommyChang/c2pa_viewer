#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rustup_home="$project_root/.dart_tool/rustup"
cargo_home="$project_root/.dart_tool/cargo"
rustup_bin="$cargo_home/bin/rustup"

if [[ ! -x "$rustup_bin" ]]; then
  installer_path="$(mktemp)"
  trap 'rm -f "$installer_path"' EXIT
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    -o "$installer_path"
  RUSTUP_INIT_SKIP_PATH_CHECK=yes \
    RUSTUP_HOME="$rustup_home" \
    CARGO_HOME="$cargo_home" \
    sh "$installer_path" \
      -y \
      --no-modify-path \
      --profile minimal \
      --default-toolchain stable
fi

RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$rustup_bin" toolchain install stable --profile minimal
RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$rustup_bin" target add aarch64-apple-ios aarch64-apple-ios-sim

echo "Project-local iOS Rust toolchain is ready."
