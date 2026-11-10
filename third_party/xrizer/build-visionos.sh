#!/bin/sh
set -eu
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/." && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
case "${1:-}" in
    sim) target=aarch64-apple-visionos-sim; sdk=xrsimulator; clang_target=arm64-apple-xros26.0-simulator ;;
    device) target=aarch64-apple-visionos; sdk=xros; clang_target=arm64-apple-xros26.0 ;;
    *) echo "usage: $0 sim|device" >&2; exit 2 ;;
esac
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo"
export RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$XRIZER_RUST_ROOT/target-$1"
export XDG_STATE_HOME="$XRIZER_RUST_ROOT/test-state"
export XDG_CONFIG_HOME="$XRIZER_RUST_ROOT/test-config"
export SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
export BINDGEN_EXTRA_CLANG_ARGS="--target=$clang_target"
export PATH="$CARGO_HOME/bin:$PATH"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
cd "$SCRIPT_DIR/upstream"
exec cargo build --lib --no-default-features --target "$target" --locked
