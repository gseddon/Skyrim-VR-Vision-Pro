#!/bin/sh
set -eu
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../xrizer" && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo"
export RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$component/build/rust-target"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
exec cargo run --offline --locked --target aarch64-apple-darwin --manifest-path "$component/tests/rust_boot/Cargo.toml"
