#!/bin/sh
set -eu
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/." && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo"
export RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$XRIZER_RUST_ROOT/target"
export XDG_STATE_HOME="$XRIZER_RUST_ROOT/test-state"
export XDG_CONFIG_HOME="$XRIZER_RUST_ROOT/test-config"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
export PATH="$CARGO_HOME/bin:$PATH"
cd "$SCRIPT_DIR/upstream"
exec cargo build --lib --no-default-features --target aarch64-apple-darwin --locked
