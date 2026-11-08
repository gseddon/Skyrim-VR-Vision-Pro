#!/bin/sh
# Isolated macOS owned fixture; --run requires the coordinated GPU slot.
set -eu
case "${1:-}" in --build-only|--run) ;; *) echo 'usage: test_xrizer_xros_native.sh --build-only|--run' >&2; exit 2;; esac
: "${XRIZER_TEST_DYLIB:?set XRIZER_TEST_DYLIB to the tested owned-apple-test dylib}"
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$repo/build/xros-host-optics"
build=$(mktemp -d "$repo/build/xros-host-optics/snapshot-XXXXXX")
python3 - "$repo" "$build" "$XRIZER_TEST_DYLIB" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
repo,build,dylib=map(Path,sys.argv[1:])
files=[repo/p for p in ('VXRuntime/src/xrizer_xros_host.m','VXRuntime/src/xrizer_xros_host.h','VXRuntime/src/xrizer_xros_mailbox.c','VXRuntime/src/xrizer_xros_mailbox.h','VXRuntime/src/native_vr.c','VXRuntime/src/native_vr.h','VXRuntime/tests/xrizer_xros_native_fixture.mm','VXRuntime/tests/test_xrizer_xros_native.sh','third_party/klepton_openxr/src/core.c','third_party/klepton_openxr/src/pose_math.c','third_party/klepton_openxr/src/pose_math.h','third_party/klepton_openxr/src/metal_host.m','third_party/xrizer/include/metal_host_bridge.h','third_party/xrizer/upstream/openvr/headers/openvr-1.0.17.h')]
files += [p for d in ('include','src') for p in (repo/'third_party/klepton_openxr'/d).rglob('*') if p.is_file() and p not in files]
hashes={}
for p in files:
 name=str(p.relative_to(repo));data=p.read_bytes();dst=build/'source'/name;dst.parent.mkdir(parents=True,exist_ok=True);dst.write_bytes(data);hashes[name]=hashlib.sha256(data).hexdigest()
if any(hashlib.sha256((repo/name).read_bytes()).hexdigest()!=h for name,h in hashes.items()):raise SystemExit('source changed while snapshotting')
shutil.copyfile(dylib,build/'libxrizer.dylib');hashes['external-tested-libxrizer.dylib']=hashlib.sha256(dylib.read_bytes()).hexdigest()
(build/'manifest.json').write_text(json.dumps(hashes,indent=2,sort_keys=True)+'\n')
PY
src="$build/source"; sdk=$(xcrun --sdk macosx --show-sdk-path)
incs="-I$src/VXRuntime/src -I$src/third_party/klepton_openxr/include -I$src/third_party/klepton_openxr/src -I$src/third_party/xrizer/include"
# Snapshot path is under this repository, whose path contains no whitespace.
for file in VXRuntime/src/xrizer_xros_host.m VXRuntime/src/xrizer_xros_mailbox.c VXRuntime/src/native_vr.c third_party/klepton_openxr/src/core.c third_party/klepton_openxr/src/pose_math.c third_party/klepton_openxr/src/metal_host.m; do
 obj="$build/$(basename "$file").o"
 xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -fobjc-arc -Wall -Wextra -Werror -DKL_NATIVE_TEST_METAL_PARTIAL $incs -c "$src/$file" -o "$obj"
done
xcrun --sdk macosx clang++ -arch arm64 -isysroot "$sdk" -std=gnu++20 -fobjc-arc -Wall -Wextra -Werror -Wno-c99-designator $incs -I"$src/third_party/xrizer/upstream/openvr/headers" -c "$src/VXRuntime/tests/xrizer_xros_native_fixture.mm" -o "$build/fixture.o"
xcrun --sdk macosx clang++ -arch arm64 -isysroot "$sdk" "$build/fixture.o" "$build/xrizer_xros_host.m.o" "$build/xrizer_xros_mailbox.c.o" "$build/native_vr.c.o" "$build/core.c.o" "$build/pose_math.c.o" "$build/metal_host.m.o" -framework Foundation -framework Metal -o "$build/fixture"
shasum -a 256 "$build/fixture" "$build/libxrizer.dylib" "$build/manifest.json" > "$build/hashes.txt"
printf 'snapshot: %s\n' "$build"
if [ "$1" = --run ]; then
 mkdir -p "$build/state" "$build/config"
 set +e
 XDG_STATE_HOME="$build/state" XDG_CONFIG_HOME="$build/config" "$build/fixture" "$build/libxrizer.dylib" > "$build/run.log" 2>&1
 status=$?
 set -e
 printf '%s\n' "$status" > "$build/run.status"
 cat "$build/run.log"
 exit "$status"
fi
