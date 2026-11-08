#!/bin/sh
set -eu
: "${XRIZER_RUST_ROOT:?set XRIZER_RUST_ROOT to the repository-local toolchain directory}"
case "$XRIZER_RUST_ROOT" in /*) ;; *) echo 'XRIZER_RUST_ROOT must be absolute' >&2; exit 2;; esac
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/build-macos.sh"
mkdir -p "$XRIZER_RUST_ROOT/test-state" "$XRIZER_RUST_ROOT/test-config"
xcrun clang -arch arm64 -o "$XRIZER_RUST_ROOT/apple-init-test" "$SCRIPT_DIR/tests/apple_init.c"
XDG_STATE_HOME="$XRIZER_RUST_ROOT/test-state" XDG_CONFIG_HOME="$XRIZER_RUST_ROOT/test-config" "$XRIZER_RUST_ROOT/apple-init-test" \
    "$XRIZER_RUST_ROOT/target/aarch64-apple-darwin/debug/libxrizer.dylib"
