#!/bin/bash
# Build-only, default-off static-link probe (visionOS simulator by default; XROS_PROBE_SDK=xros for the device). Never launches an app.
set -euo pipefail
sdk=${XROS_PROBE_SDK:-xrsimulator}
case "$sdk" in
 xrsimulator) rust_target=aarch64-apple-visionos-sim; clang_target=arm64-apple-xros26.0-simulator; suffix="" ;;
 xros) rust_target=aarch64-apple-visionos; clang_target=arm64-apple-xros26.0; suffix="-device" ;;
 *) echo "XROS_PROBE_SDK must be xrsimulator or xros" >&2; exit 2 ;;
esac
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../third_party/xrizer" && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cache="$repo/build/xros-host-static$suffix"
mkdir -p "$cache/target"
build=$(mktemp -d "$cache/probe-XXXXXX")
mkdir -p "$build/state" "$build/config"
python3 - "$repo" "$build" <<'PYMANIFEST'
from pathlib import Path
import hashlib,json,sys
repo,build=map(Path,sys.argv[1:])
files=[p for p in (repo/'third_party/xrizer/upstream').rglob('*') if p.is_file() and not any(part in ('.git','target') for part in p.relative_to(repo/'third_party/xrizer/upstream').parts)]
files += [p for d in ('include','src') for p in (repo/'third_party/klepton_openxr'/d).rglob('*') if p.is_file()]
files += [repo/p for p in ('VXRuntime/Makefile','VXRuntime/src/xrizer_xros_host.m','VXRuntime/src/xrizer_xros_host.h','VXRuntime/src/xrizer_xros_mailbox.c','VXRuntime/src/xrizer_xros_mailbox.h','VXRuntime/src/native_vr.c','VXRuntime/src/native_vr.h','VXRuntime/tests/xrizer_xros_static_link.c','VXRuntime/tests/test_xrizer_xros_static_link.sh','third_party/xrizer/include/metal_host_bridge.h')]
manifest={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
(build/'source-manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
PYMANIFEST
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo" RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export CARGO_TARGET_DIR="$cache/target" XDG_STATE_HOME="$build/state" XDG_CONFIG_HOME="$build/config"
export PATH="$CARGO_HOME/bin:$PATH" SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)"
export BINDGEN_EXTRA_CLANG_ARGS="--target=$clang_target"
cargo build --manifest-path "$repo/third_party/xrizer/upstream/Cargo.toml" --lib --no-default-features --features owned-apple-test --target "$rust_target" --offline --locked > "$build/rust-build.log" 2>&1
incs=(-I "$repo/VXRuntime/src" -I "$repo/third_party/klepton_openxr/include" -I "$repo/third_party/klepton_openxr/src" -I "$repo/third_party/xrizer/include")
flags=(-target "$clang_target" -isysroot "$SDKROOT" -std=c11 -fobjc-arc -Wall -Wextra -Werror -DKL_NATIVE_TEST_METAL_PARTIAL)
sources=(VXRuntime/src/xrizer_xros_host.m VXRuntime/src/xrizer_xros_mailbox.c VXRuntime/src/native_vr.c third_party/klepton_openxr/src/core.c third_party/klepton_openxr/src/pose_math.c third_party/klepton_openxr/src/metal_host.m)
objects=()
for i in "${!sources[@]}"; do
 obj="$build/host-$i.o"; xcrun --sdk "$sdk" clang "${flags[@]}" "${incs[@]}" -c "$repo/${sources[$i]}" -o "$obj"; objects+=("$obj")
done
xcrun --sdk "$sdk" clang "${flags[@]}" "${incs[@]}" -c "$repo/VXRuntime/tests/xrizer_xros_static_link.c" -o "$build/probe.o"
xcrun --sdk "$sdk" libtool -static -o "$build/libklepton.a" "${objects[3]}" "${objects[4]}" "${objects[5]}"
mfx=(); [ "$sdk" = xros ] && mfx=(-framework MetalFX)
archive="$build/libxrizer.a"
cp "$cache/target/$rust_target/debug/libxrizer.a" "$archive"
xcrun --sdk "$sdk" clang -target "$clang_target" -isysroot "$SDKROOT" "$build/probe.o" "${objects[@]}" "$archive" -framework Foundation -framework Metal ${mfx[@]+"${mfx[@]}"} -framework Security -framework SystemConfiguration -licucore -lz -o "$build/link-probe"
nm -gU "$build/link-probe" > "$build/symbols.txt"
for symbol in VRClientCoreFactory xrizer_configure_openxr_provider xrizer_configure_metal_host vx_xros_xrizer_register kl_native_get_instance_proc_addr; do
 if ! grep -Eq "[[:space:]]_${symbol}$" "$build/symbols.txt"; then echo "missing static symbol: $symbol" >&2; exit 1; fi
done
otool -l "$build/link-probe" > "$build/load-commands.txt"
python3 - "$repo" "$build/source-manifest.json" <<'PYCHECK'
from pathlib import Path
import hashlib,json,sys
repo=Path(sys.argv[1]); manifest=json.loads(Path(sys.argv[2]).read_text())
if any(hashlib.sha256((repo/name).read_bytes()).hexdigest()!=digest for name,digest in manifest.items()):
    raise SystemExit('source changed during static-link build')
PYCHECK
shasum -a 256 "$build/link-probe" "$archive" "$build/source-manifest.json" > "$build/hashes.txt"
ln -sfn "$(basename "$build")" "$cache/latest"
printf 'visionOS %s static-link probe: build only, exact symbols pass; %s\n' "$sdk" "$build"
