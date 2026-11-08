#!/bin/sh
set -eu
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$component/../.." && pwd)
case "${1:-}" in ''|--build-only) ;; *) echo 'usage: test-metal-frame.sh [--build-only]' >&2; exit 2 ;; esac
mkdir -p "$component/build"
build=$(mktemp -d "$component/build/metal-frame-XXXXXX")
python3 - "$component" "$repo" "$build" <<'PY'
import hashlib,json,sys
from pathlib import Path
component,repo,build=map(Path,sys.argv[1:])
files=sorted([p for folder in ('src','include') for p in (component/folder).rglob('*')
              if p.is_file() and p.suffix in ('.c','.m','.h','.inc')]
             +[component/'tests/frame_metal.m',component/'tests/metal_frame_host.inc',component/'test-metal-frame.sh',
               repo/'VXRuntime/src/native_vr.c',repo/'VXRuntime/src/native_vr.h'])
hashes={}
for p in files:
    name=str(p.relative_to(repo)); data=p.read_bytes()
    target=build/'source'/name; target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(data)
    hashes[name]=hashlib.sha256(data).hexdigest()
if any(hashlib.sha256((repo/name).read_bytes()).hexdigest()!=sha for name,sha in hashes.items()):
    raise SystemExit('source changed during snapshot; rerun before compiling')
(build/'source-manifest.json').write_text(json.dumps(hashes,indent=2,sort_keys=True)+'\n')
PY
source="$build/source/third_party/klepton_openxr"
native="$build/source/VXRuntime/src"
sdk=$(xcrun --sdk macosx --show-sdk-path)
{
    xcrun --sdk macosx clang --version
    printf 'target: arm64-apple-macos; SDK: %s\n' "$sdk"
    printf 'subject: owned offscreen native fixture; KL_NATIVE_TEST_METAL_PARTIAL\n'
} > "$build/environment.txt"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -DKL_NATIVE_TEST_METAL_PARTIAL -I"$source/include" -c "$source/src/core.c" -o "$build/core.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -I"$source/include" -c "$source/src/pose_math.c" -o "$build/pose-math.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -I"$native" -c "$native/native_vr.c" -o "$build/native-vr.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc \
    -I"$source/include" -I"$source/src" -I"$native" "$source/src/metal_host.m" "$source/tests/frame_metal.m" \
    "$build/core.o" "$build/pose-math.o" "$build/native-vr.o" -framework Foundation -framework Metal -o "$build/metal-frame"
shasum -a 256 "$build/metal-frame" > "$build/artifact.sha256"
printf 'artifact: %s\nsource manifest: %s\n' "$build/metal-frame" "$build/source-manifest.json"
if [ "${1:-}" = --build-only ]; then
    printf 'GPU execution deferred; execute this exact artifact after clearance.\n'
    exit 0
fi
set +e
"$build/metal-frame" > "$build/run.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$build/run.status"
cat "$build/run.log"
exit "$status"
