# Sourced (not executed) by the xrizer/Klepton build and test scripts, after XRIZER_ENV_DIR is set to this directory.
# Selects the repository-local Rust toolchain and the cargo settings that keep build output small.
#
# XRIZER_RUST_ROOT (absolute, holds cargo/ and rustup/) overrides the default:
#   <this checkout>/build/toolchains/xrizer-rust if it exists, else the same path in the main checkout (git worktrees
#   under build/worktrees/ share the main checkout's toolchain). The toolchain is git-ignored (/build/); rustc 1.99.1
#   with targets aarch64-apple-darwin, aarch64-apple-visionos, aarch64-apple-visionos-sim (third_party/xrizer/SOURCE.md).
: "${XRIZER_ENV_DIR:?set XRIZER_ENV_DIR to third_party/xrizer before sourcing rust-env.sh}"
if [ -z "${XRIZER_RUST_ROOT:-}" ]; then
    _xr_root=$(CDPATH= cd -- "$XRIZER_ENV_DIR/../.." && pwd)
    if [ -d "$_xr_root/build/toolchains/xrizer-rust/rustup" ]; then
        XRIZER_RUST_ROOT="$_xr_root/build/toolchains/xrizer-rust"
    elif _xr_common=$(git -C "$_xr_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        XRIZER_RUST_ROOT="$(dirname -- "$_xr_common")/build/toolchains/xrizer-rust"
    else
        XRIZER_RUST_ROOT="$_xr_root/build/toolchains/xrizer-rust"
    fi
    unset _xr_root _xr_common
fi
case "$XRIZER_RUST_ROOT" in /*) ;; *) echo 'XRIZER_RUST_ROOT must be absolute' >&2; exit 2;; esac
[ -d "$XRIZER_RUST_ROOT/rustup" ] || { echo "no Rust toolchain at $XRIZER_RUST_ROOT (run tools/setup_rust.sh, or set XRIZER_RUST_ROOT; see third_party/xrizer/SOURCE.md)" >&2; exit 2; }
export XRIZER_RUST_ROOT
# Debug info: line tables only in dev builds (backtraces keep file:line), none in release (symbols stay, so panic
# backtraces still name functions), no incremental cache for one-off builds. Each can be overridden by the caller.
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-line-tables-only}"
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-0}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
