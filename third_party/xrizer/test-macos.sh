#!/bin/sh
set -eu
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/." && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/build-macos.sh"
mkdir -p "$XRIZER_RUST_ROOT/test-state" "$XRIZER_RUST_ROOT/test-config"
xcrun clang -arch arm64 -o "$XRIZER_RUST_ROOT/apple-init-test" "$SCRIPT_DIR/tests/apple_init.c"
XDG_STATE_HOME="$XRIZER_RUST_ROOT/test-state" XDG_CONFIG_HOME="$XRIZER_RUST_ROOT/test-config" "$XRIZER_RUST_ROOT/apple-init-test" \
    "$XRIZER_RUST_ROOT/target/aarch64-apple-darwin/debug/libxrizer.dylib"
