#!/bin/sh
# play_skyrim_dev.sh: boot Skyrim VR on this Mac with the keyboard dev controllers, one command.
#
# Builds (incrementally; nothing to do when up to date) from THIS checkout the dev-host runtime and the xrizer dylib
# with the dev features, refuses when another Skyrim/vxrt session is running, prints the key map, then starts the
# harness (strict AOT, xrizer + Klepton dev host, seeded right-handed prefs, safe-math shaders, sound on).
#
#   tools/play_skyrim_dev.sh                 play (up to 3600 s)
#   tools/play_skyrim_dev.sh --no-build      skip the builds
#   tools/play_skyrim_dev.sh --build-only    build, do not start
#   tools/play_skyrim_dev.sh --seconds N     time limit (default 3600; max 3600)
#   tools/play_skyrim_dev.sh --mute          no sound
#   tools/play_skyrim_dev.sh --hud           Apple's Metal Performance HUD (MTL_HUD_ENABLED=1)
#   tools/play_skyrim_dev.sh --helgen        to the Helgen cart intro with no keys: pad A every 2 s from 6 s to 140 s
#                                            (--xinput-repeat A@6-140/2:0.3) and an empty sIntroSequence (--overlay-ini
#                                            Skyrim.ini:General:sIntroSequence=: a per-run copy in the overlay skips the logo video)
#   tools/play_skyrim_dev.sh --mods-dir DIR  link DIR/Data's top-level entries (loose mod files, e.g. from tools/skyland_flatten.py) into the run's overlay
#   tools/play_skyrim_dev.sh --mods-config P/mods.json  the same from a pack built by tools/mods.py (priority-merged tree, Plugins.txt, the list recorded)
#   tools/play_skyrim_dev.sh --xrizer-debug  build and use xrizer unoptimised (default: release; debug cost ~0.6 ms a frame)
#   tools/play_skyrim_dev.sh --trace-calls N log the first N calls per runtime function (default 0: off; tracing
#                                            costs ~20% process CPU, measured 2026-11-10)
#   tools/play_skyrim_dev.sh -- ARGS...      pass ARGS on to tools/vxrt_native_startup.py
#   tools/play_skyrim_dev.sh --key-script S  extra: VXRT_XRIZER_DEV_KEY_SCRIPT (START:KEYS:HOLD,...), for checks
# Saves: build/private/saves/611670 (SKYRIM_SAVES_DIR overrides) is linked in as My Games/Skyrim VR/Saves, so saves persist across runs.
# Shader cache: build/private/shadercache (VXRT_SHADER_CACHE overrides, 0 = off). A boot queues the shaders it had to
# compile; run tools/shadercache_fill.sh after it (parallel, a few minutes) and the next boot loads them.
# Diagnostic development host, not a SteamVR session and not a physical-headset claim.
# Private inputs (override with the environment variables): SKYRIM_AOT_BASE = directory holding prepared/SkyrimVR.exe,
# aot-splits4a/ and redist/ (read-only); SKYRIM_AOT_DIR = a module directory (default aot-fpcr-d5b2320/modules, built 2026-11-10 by
# tools/skyrim_aot_pipeline.py with the lazy-FPCR stubs; the previous set is $B/aot-splits4a); SKYRIM_ASSET_ROOT; STEAMVR_WIN64_DLLS; XRIZER_RUST_ROOT.
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
B=${SKYRIM_AOT_BASE:-/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971}
ASSETS=${SKYRIM_ASSET_ROOT:-/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR}
VRWEB=${STEAMVR_WIN64_DLLS:-/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SteamVR/bin/vrwebhelper/win64}
XRIZER_ENV_DIR=$R/third_party/xrizer; . "$XRIZER_ENV_DIR/rust-env.sh"; T=$XRIZER_RUST_ROOT
SECONDS_LIMIT=3600; BUILD=1; RUN=1; MUTE=0; HUD=0; KEYSCRIPT=; TRACE_CALLS=0; HELGEN=0; XRIZER_PROFILE=release; MODS=; MODSCFG=
while [ $# -gt 0 ]; do
  case $1 in
    --no-build) BUILD=0;; --build-only) RUN=0;; --mute) MUTE=1;; --hud) HUD=1;;
    --seconds) SECONDS_LIMIT=$2; shift;; --key-script) KEYSCRIPT=$2; shift;;
    --trace-calls) TRACE_CALLS=$2; shift;; --helgen) HELGEN=1;; --mods-dir) MODS=$2; shift;; --mods-config) MODSCFG=$2; shift;; --xrizer-debug) XRIZER_PROFILE=debug;;
    --) shift; break;;
    -h|--help) sed -n 2,23p "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
XRIZER_CARGO_PROFILE=; [ "$XRIZER_PROFILE" = release ] && XRIZER_CARGO_PROFILE=--release
# anything after -- goes to tools/vxrt_native_startup.py as is (e.g. -- --diag-env VXRT_STATS=1)
AOT=${SKYRIM_AOT_DIR:-$B/aot-fpcr-d5b2320/modules}
for f in "$B/prepared/SkyrimVR.exe" "$AOT" "$B/redist" "$ASSETS" "$VRWEB"; do
  [ -e "$f" ] || { echo "missing private input: $f (see SKYRIM_AOT_BASE etc. at the top of $0)" >&2; exit 2; }
done

# The harness only executes a private image inside the checkout it runs from: make an APFS clone (copy-on-write, no
# extra disk, gitignored build/) of the prepared image and AOT modules when this checkout is not the one that holds them.
case $B in
  "$R"/*) ;;
  *) P=$R/build/private/skyrimvr/$(basename "$B")
     if [ ! -e "$P/prepared/SkyrimVR.exe" ]; then
       echo "== cloning the private image into $P"; mkdir -p "$R/build/private/skyrimvr"
       cp -cR "$B" "$P.tmp.$$" && mv "$P.tmp.$$" "$P"
     fi
     B=$P;;
esac
AOT=${SKYRIM_AOT_DIR:-$B/aot-fpcr-d5b2320/modules}   # (again: B may now be the clone)

O=$R/VXRuntime/build/play-host           # dev host runtime
D=$R/build/xrizer-play-dylib             # xrizer dylib
if [ $BUILD = 1 ]; then
  echo "== building the dev-host runtime ($O)"
  mkdir -p "$O"
  K=$R/third_party/klepton_openxr
  sdk=$(xcrun --sdk macosx --show-sdk-path); cc=$(xcrun --find clang)
  "$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -DKL_NATIVE_TEST_METAL_PARTIAL -I"$K/include" -c "$K/src/core.c" -o "$O/core.o"
  "$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$K/include" -c "$K/src/pose_math.c" -o "$O/pose.o"
  "$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc -I"$K/include" -c "$K/src/metal_host.m" -o "$O/metal.o"
  make -C "$R/VXRuntime" VXRT_ARM64_TARGET=build/play-host/vxrt-arm64 VXRT_ARM64_THUNKS_ROOT=build/play-host \
    "VXRT_ARM64_EXTRA_CFLAGS=-DVXRT_XRIZER_DEV_HOST -DVXRT_XRIZER_DEV_AUDIT -I../third_party/klepton_openxr/include -I../third_party/klepton_openxr/src -I../third_party/xrizer/include" \
    "VXRT_ARM64_EXTRA_SRC=src/xrizer_guest_bridge.c src/xrizer_guest_d3d.m src/xrizer_openvr_exports.c src/xrizer_dev_host.m tests/xrizer_openvr_exports_audit.m tests/xrizer_guest_nativefatal_host.c" \
    "VXRT_ARM64_EXTRA_OBJS=$O/core.o $O/pose.o $O/metal.o" build/play-host/vxrt-arm64 build/libvxrt_vm.dylib
  cp "$R/VXRuntime/build/libvxrt_vm.dylib" "$O/"
  echo "== building the xrizer dylib ($D)"
  mkdir -p "$D/state" "$D/config"
  ( export CARGO_HOME="$T/cargo" RUSTUP_HOME="$T/rustup" CARGO_TARGET_DIR="$D" XDG_STATE_HOME="$D/state" XDG_CONFIG_HOME="$D/config"
    export PATH="$CARGO_HOME/bin:$PATH"
    cd "$R/third_party/xrizer/upstream"
    XRIZER_VERSION=${XRIZER_VERSION:-play-dev-1} cargo build --lib --no-default-features --features owned-apple-test --target aarch64-apple-darwin --locked --offline $XRIZER_CARGO_PROFILE )
fi
RUNTIME=$O/vxrt-arm64; DYLIB=$D/aarch64-apple-darwin/$XRIZER_PROFILE/libxrizer.dylib
[ -x "$RUNTIME" ] && [ -f "$DYLIB" ] || { echo "not built yet: run without --no-build" >&2; exit 2; }
[ $RUN = 1 ] || { echo "built: $RUNTIME $DYLIB"; exit 0; }

OUT=$R/build/play-$(date +%H%M%S)
SESS=/tmp/play_skyrim_dev.sessions.$$
if ! python3 "$R/tools/vxrt_runtime_sessions.py" --own "$OUT" --json > "$SESS" 2>&1; then
  echo "Another Skyrim / VXRuntime / SteamVR session is running, so this will not start. Details:" >&2
  cat "$SESS" >&2; rm -f "$SESS"
  echo "Quit it first: close its game window or press Ctrl-C in the terminal that runs it (ps -axww | grep -i vxrt finds it)." >&2
  exit 3
fi
rm -f "$SESS"

cat <<'HEAD'
==============================================================================================================
Skyrim VR, keyboard dev controllers.  Two windows open: "VXRuntime dev keyboard" (both eyes side by side, live
rates in its title) and "Skyrim VR" (the game's own desktop window; it takes no keys).
CLICK THE 'VXRuntime dev keyboard' WINDOW: only it receives the keys.  The game takes a minute or two to reach
the main menu.  F1 or ? in that window shows/hides a help panel with these keys.
HEAD
awk -F'|' '/^\| / && !/^\| (Key|---)/ && NF > 4 { gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $4); gsub(/^ +| +$/, "", $5); gsub(/`/, "", $4); printf "  %-12s %-17s %s\n", $2, $4, $5 }' "$R/docs/dev-keyboard.md"
cat <<'TAIL'
Mouse: drag = turn head, right-button drag = aim hands.  Menus: aim the pointer (, . ; /) then Space or E.
Sound plays on the Mac's default output device (--mute for none).
Quit: Ctrl-C in this terminal, or close the Skyrim VR window.
This table and the notes: docs/dev-keyboard.md
==============================================================================================================
TAIL
EXTRA="--trace-calls $TRACE_CALLS"
[ -n "$KEYSCRIPT" ] && EXTRA="$EXTRA --dev-key-script $KEYSCRIPT"
[ $MUTE = 1 ] || EXTRA="$EXTRA --audio"
[ $HUD = 1 ] && EXTRA="$EXTRA --hud"
[ -n "$MODS" ] && EXTRA="$EXTRA --mods-dir $MODS"
[ -n "$MODSCFG" ] && EXTRA="$EXTRA --mods-config $MODSCFG"
[ $HELGEN = 1 ] && EXTRA="$EXTRA --xinput-repeat A@6-140/2:0.3 --overlay-ini Skyrim.ini:General:sIntroSequence="
echo "output and evidence: $OUT"
# shellcheck disable=SC2086
exec python3 "$R/tools/vxrt_native_startup.py" --exe "$B/prepared/SkyrimVR.exe" --runtime "$RUNTIME" \
  --aot-dir "$AOT" --asset-root "$ASSETS" --dll-dir "$B/redist" --dll-dir "$VRWEB" --appid 611670 \
  --out "$OUT" --seconds "$SECONDS_LIMIT" --experimental-xrizer --dev-synthetic-stage --xrizer-dylib "$DYLIB" \
  --dev-keyboard 1 --stay-active --saves-dir "${SKYRIM_SAVES_DIR:-$R/build/private/saves/611670}" $EXTRA "$@"
