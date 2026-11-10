#!/bin/sh
set -eu
XRIZER_ENV_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../xrizer" && pwd); . "$XRIZER_ENV_DIR/rust-env.sh"
mode=${XRIZER_FRONTEND_MODE:-missing-views}
case "$mode" in missing-views|views-no-ready|ready-bootstrap|missing-geometry|invalid-geometry|geometry-error) ;; *) echo 'unsupported XRIZER_FRONTEND_MODE' >&2;exit 2;;esac
fixture=${XRIZER_NATIVE_FIXTURE:-frontend}
case "$fixture" in frontend|stereo) ;; *) echo 'unsupported XRIZER_NATIVE_FIXTURE' >&2;exit 2;;esac
if [ "$fixture" = stereo ];then
    mode=${XRIZER_STEREO_MODE:-positive}
    case "$mode" in positive|failure-retries|nonzero-pose-probe) ;; *) echo 'unsupported XRIZER_STEREO_MODE' >&2;exit 2;;esac
fi
case "${1:-}" in ''|--build-only) ;; *) echo 'usage: test-xrizer-frontend.sh [--build-only]' >&2;exit 2;;esac
case "$XRIZER_RUST_ROOT" in /*) ;; *) echo 'XRIZER_RUST_ROOT must be absolute' >&2;exit 2;;esac
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$component/../.." && pwd)
mkdir -p "$component/build"
cache="$component/build/xrizer-frontend-cache"
mkdir -p "$cache"
if ! mkdir "$cache/lock" 2>/dev/null;then echo 'frontend worker cache is busy; serialize this runner' >&2;exit 2;fi
build=""
trap 'status=$?; if [ -n "$build" ];then printf "%s\n" "$status" > "$build/runner.status"; if [ "$status" != 0 ] && [ -f "$build/native-build.log" ];then tail -50 "$build/native-build.log" >&2;fi;fi; rmdir "$cache/lock"' EXIT
build=$(mktemp -d "$component/build/xrizer-frontend-XXXXXX")
native_build() { "$@" >> "$build/native-build.log" 2>&1; }
python3 - "$component" "$repo" "$build" <<'PY'
from pathlib import Path
import hashlib,json,sys
component,repo,build=map(Path,sys.argv[1:])
files=[p for d in ('src','include') for p in (component/d).rglob('*') if p.is_file()]
files += [p for p in (repo/'third_party/xrizer/upstream').rglob('*') if p.is_file() and not any(x in ('target','.git') for x in p.relative_to(repo/'third_party/xrizer/upstream').parts)]
files += [component/'tests/xrizer_frontend.m',component/'tests/xrizer_stereo.m',component/'tests/metal_frame_host.inc',
          component/'test-xrizer-frontend.sh',component/'test-xrizer-stereo.sh',repo/'third_party/xrizer/include/metal_host_bridge.h',
          repo/'VXRuntime/src/native_vr.c',repo/'VXRuntime/src/native_vr.h']
hashes={}
for p in sorted(files):
    name=str(p.relative_to(repo));data=p.read_bytes();target=build/'source'/name
    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    target.chmod(p.stat().st_mode&0o777);hashes[name]=hashlib.sha256(data).hexdigest()
if any(hashlib.sha256((repo/name).read_bytes()).hexdigest()!=sha for name,sha in hashes.items()):raise SystemExit('source changed during snapshot; rerun')
(build/'source-manifest.json').write_text(json.dumps(hashes,indent=2,sort_keys=True)+'\n')
PY
python3 - "$build" "$cache" <<'PY'
from pathlib import Path
import hashlib,json,sys
build,cache=map(Path,sys.argv[1:]);manifest=json.loads((build/'source-manifest.json').read_text())
stage=cache/'source'
for p in stage.rglob('*') if stage.exists() else []:
    if p.is_file() and str(p.relative_to(stage)) not in manifest:p.unlink()
for name,sha in manifest.items():
    original=build/'source'/name;target=stage/name;data=original.read_bytes()
    if hashlib.sha256(data).hexdigest()!=sha:raise SystemExit('snapshot hash mismatch')
    if not target.exists() or target.read_bytes()!=data:
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        target.chmod(original.stat().st_mode&0o777)
if any(hashlib.sha256((stage/name).read_bytes()).hexdigest()!=sha for name,sha in manifest.items()):raise SystemExit('staging source mismatch')
PY
export CARGO_HOME="$XRIZER_RUST_ROOT/cargo" RUSTUP_HOME="$XRIZER_RUST_ROOT/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_TARGET_DIR="$cache/target" XDG_STATE_HOME="$build/state" XDG_CONFIG_HOME="$build/config"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" XRIZER_VERSION=owned-apple-test-snapshot
mkdir -p "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
source="$build/source/third_party/klepton_openxr"
xrizer="$build/source/third_party/xrizer"
rust_source="$cache/source/third_party/xrizer/upstream"
sdk=$(xcrun --sdk macosx --show-sdk-path)
{
    rustc -Vv
    cargo -V
    xcrun --sdk macosx clang --version
    printf 'features: --no-default-features --features owned-apple-test; target: aarch64-apple-darwin; provider: KL_NATIVE_TEST_METAL_PARTIAL\n'
    printf 'frontend mode: %s\n' "$mode"
    printf 'fixture: %s\n' "$fixture"
} > "$build/environment.txt"
printf 'snapshot: %s\n' "$build"
set +e
cargo build --manifest-path "$rust_source/Cargo.toml" --lib --no-default-features --features owned-apple-test --target aarch64-apple-darwin --offline --locked > "$build/rust-build.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$build/rust-build.status"
if [ "$status" != 0 ];then tail -70 "$build/rust-build.log";exit "$status";fi
cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/debug/libxrizer.dylib" "$build/libxrizer.dylib"
native_build xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -DKL_NATIVE_TEST_METAL_PARTIAL -I"$source/include" -c "$source/src/core.c" -o "$build/core.o"
native_build xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -I"$source/include" -c "$source/src/pose_math.c" -o "$build/pose-math.o"
native_build xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc \
    -I"$source/include" -c "$source/src/metal_host.m" -o "$build/metal-host.o"
if [ "$fixture" = stereo ];then
    native="$build/source/VXRuntime/src"
    native_build xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
        -I"$native" -c "$native/native_vr.c" -o "$build/native-vr.o"
    native_build xcrun --sdk macosx clang++ -arch arm64 -isysroot "$sdk" -x objective-c++ -std=gnu++20 -Wall -Wextra -Werror \
        -Wno-c99-designator -fobjc-arc -I"$source/include" -I"$source/src" -I"$xrizer/include" -I"$xrizer/upstream/openvr/headers" -I"$native" \
        -c "$source/tests/xrizer_stereo.m" -o "$build/fixture.o"
else
    native_build xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc \
        -I"$source/include" -I"$xrizer/include" -c "$source/tests/xrizer_frontend.m" -o "$build/fixture.o"
fi
if [ "$fixture" = stereo ];then extra="$build/native-vr.o";else extra="";fi
native_build xcrun --sdk macosx clang++ -arch arm64 -isysroot "$sdk" "$build/fixture.o" "$build/metal-host.o" \
    "$build/core.o" "$build/pose-math.o" $extra -framework Foundation -framework Metal -o "$build/xrizer-frontend"
shasum -a 256 "$build/xrizer-frontend" "$build/libxrizer.dylib" > "$build/artifact.sha256"
if [ "${1:-}" = --build-only ];then
    printf 'build-only: %s/xrizer-frontend %s/libxrizer.dylib %s\n' "$build" "$build" "$mode"
    exit 0
fi
python3 - "$build" "$mode" <<'PY'
import json,os,subprocess,sys
from pathlib import Path
p=Path(sys.argv[1])
execution={key:os.environ.get(key) for key in ['XDG_STATE_HOME','XDG_CONFIG_HOME','XRIZER_NATIVE_FIXTURE','XRIZER_STEREO_MODE']}
execution['mode']=sys.argv[2]
for key in ['XDG_STATE_HOME','XDG_CONFIG_HOME']:
    if not execution[key] or not Path(execution[key]).resolve().is_relative_to(p.resolve()):
        raise SystemExit('xrizer log/config state must remain inside this execution snapshot')
(p/'execution-environment.json').write_text(json.dumps(execution,indent=2,sort_keys=True)+'\n')
try:
    r=subprocess.run([str(p/'xrizer-frontend'),str(p/'libxrizer.dylib'),sys.argv[2]],capture_output=True,text=True,timeout=30)
    (p/'run.log').write_text(r.stdout+r.stderr);(p/'run.status').write_text(str(r.returncode)+'\n')
    print(r.stdout+r.stderr);print('exit:',r.returncode);raise SystemExit(r.returncode if r.returncode>=0 else 1)
except subprocess.TimeoutExpired as e:
    (p/'run.log').write_bytes((e.stdout or b'')+(e.stderr or b''));(p/'run.status').write_text('timeout\n');print('timeout after 30s');raise SystemExit(124)
PY
printf 'artifact and manifest: %s\n' "$build"
