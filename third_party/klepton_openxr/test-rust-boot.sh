#!/bin/sh
set -eu
: "${XRIZER_RUST_ROOT:?set XRIZER_RUST_ROOT to the repository-local toolchain}"
case "$XRIZER_RUST_ROOT" in /*) ;; *) echo 'XRIZER_RUST_ROOT must be absolute' >&2; exit 2;; esac
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo"
export RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$component/build/rust-target"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
exec cargo run --offline --locked --target aarch64-apple-darwin --manifest-path "$component/tests/rust_boot/Cargo.toml"
