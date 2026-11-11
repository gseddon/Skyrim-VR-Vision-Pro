#!/bin/sh
# setup_rust.sh: install the Rust toolchain the xrizer / Klepton static libraries are built with, into
# $XRIZER_RUST_ROOT (default build/toolchains/xrizer-rust, git-ignored), and fetch the locked crates so the later
# builds (cargo --offline --locked) work.
#
#   tools/setup_rust.sh            install rustup + Rust 1.99.1 + the three Apple targets, then cargo fetch --locked
#   tools/setup_rust.sh --check    only report what is installed (no network)
#
# This DOWNLOADS (only when you run it), nothing global is touched (no PATH or shell-profile changes):
#   - rustup-init  https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init
#   - rustc/cargo 1.99.1 (minimal profile) and the targets aarch64-apple-darwin, aarch64-apple-visionos,
#     aarch64-apple-visionos-sim from static.rust-lang.org
#   - the crates of third_party/xrizer/upstream/Cargo.lock from crates.io
# Licences: rustup and Rust MIT OR Apache-2.0; each crate its own (xrizer is GPL-3.0-or-later, third_party/xrizer/SOURCE.md).
# Re-running is safe: what is already installed is kept. Steps: toolchain (this script), see docs/SETUP_SKYRIM.md.
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "${VXRT_LOCAL_ENV:-$R/local/env.sh}" ] && . "${VXRT_LOCAL_ENV:-$R/local/env.sh}"
RUST_VERSION=${XRIZER_RUST_VERSION:-1.99.1}
TARGETS="aarch64-apple-darwin aarch64-apple-visionos aarch64-apple-visionos-sim"
ROOT=${XRIZER_RUST_ROOT:-$R/build/toolchains/xrizer-rust}
case $ROOT in /*) ;; *) echo "setup_rust: XRIZER_RUST_ROOT must be absolute" >&2; exit 2;; esac
export RUSTUP_HOME="$ROOT/rustup" CARGO_HOME="$ROOT/cargo" RUSTUP_INIT_SKIP_PATH_CHECK=yes
export PATH="$CARGO_HOME/bin:$PATH"

if [ "${1:-}" = "--check" ]; then
  [ -x "$CARGO_HOME/bin/rustc" ] || { echo "setup_rust: no Rust at $ROOT (run tools/setup_rust.sh)" >&2; exit 1; }
  have=$(rustc --version | awk '{print $2}')
  [ "$have" = "$RUST_VERSION" ] || { echo "setup_rust: rustc $have at $ROOT, expected $RUST_VERSION" >&2; exit 1; }
  for t in $TARGETS; do
    [ -d "$RUSTUP_HOME/toolchains/$RUST_VERSION-aarch64-apple-darwin/lib/rustlib/$t" ] || { echo "setup_rust: target $t missing" >&2; exit 1; }
  done
  echo "setup_rust: rustc $have with $TARGETS at $ROOT"; exit 0
fi

[ "$(uname -sm)" = "Darwin arm64" ] || { echo "setup_rust: needs an Apple-silicon Mac" >&2; exit 2; }
mkdir -p "$ROOT"
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
  tmp=$(mktemp -d "$ROOT/.init.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  echo "== downloading rustup-init (static.rust-lang.org)"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/rustup-init" https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init
  chmod +x "$tmp/rustup-init"
  "$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
fi
rustup toolchain install "$RUST_VERSION" --profile minimal $(for t in $TARGETS; do printf -- '-t %s ' "$t"; done)
rustup default "$RUST_VERSION"
echo "== cargo fetch --locked (third_party/xrizer/upstream)"
( cd "$R/third_party/xrizer/upstream" && cargo fetch --locked )
"$0" --check
