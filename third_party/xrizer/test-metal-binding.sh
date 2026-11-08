#!/bin/sh
set -eu
: "${XRIZER_RUST_ROOT:?set XRIZER_RUST_ROOT to the repository-local toolchain directory}"
case "$XRIZER_RUST_ROOT" in /*) ;; *) echo 'XRIZER_RUST_ROOT must be absolute' >&2; exit 2;; esac
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo"
export RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$XRIZER_RUST_ROOT/target"
export PATH="$CARGO_HOME/bin:$PATH"
cd "$SCRIPT_DIR/upstream"
xcrun clang -arch arm64 -std=c11 -Wall -Wextra -Werror -o "$XRIZER_RUST_ROOT/metal-host-layout" "$SCRIPT_DIR/tests/metal_host_layout.c"
"$XRIZER_RUST_ROOT/metal-host-layout"
cargo test --lib --no-default-features --target aarch64-apple-darwin --locked metal_
cargo test --lib --no-default-features --target aarch64-apple-darwin --locked graphics_backends::metal::tests
exec cargo test --lib --no-default-features --target aarch64-apple-darwin --locked apple_provider::tests
