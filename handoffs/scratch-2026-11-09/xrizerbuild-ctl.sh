#!/bin/sh
# xrizerbuild-ctl.sh: the owned-apple-test xrizer dylib from THIS worktree's third_party/xrizer/upstream into
# build/xrizer-ctl-dylib (offline, with the existing repository-local toolchain of the reference checkout).
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
T=${XRIZER_RUST_ROOT:-/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/toolchains/xrizer-rust}
export CARGO_HOME="$T/cargo" RUSTUP_HOME="$T/rustup" CARGO_TARGET_DIR="$R/build/xrizer-ctl-dylib"
export XDG_STATE_HOME="$R/build/xrizer-ctl-dylib/state" XDG_CONFIG_HOME="$R/build/xrizer-ctl-dylib/config"
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
export PATH="$CARGO_HOME/bin:$PATH"
cd "$R/third_party/xrizer/upstream"
XRIZER_VERSION=${XRIZER_VERSION:-ctl-controllers-1} cargo build --lib --no-default-features --features owned-apple-test --target aarch64-apple-darwin --locked --offline
shasum -a 256 "$CARGO_TARGET_DIR/aarch64-apple-darwin/debug/libxrizer.dylib"
