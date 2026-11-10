#!/bin/sh
# shadercache_fill.sh [CACHE_DIR [SDK]]: compile the shaders a game run left in <CACHE_DIR>/pending
# (VXRuntime/src/shader_cache.m: the MSL source of every library the run had to compile, <key>.metal, with its options in
# <key>.flags) into <CACHE_DIR>/<key>.metallib, one per CPU core at a time, and delete each pending file it compiles.
# The key is the one the runtime computes (source + language version + math mode), so the next start loads the library.
# SDK: macosx (default, the Mac dev host) or xros / xrsimulator (the headset set; not run yet). Run after the game,
# before the next one; safe to interrupt and rerun. Default folder: build/private/shadercache of this checkout
# (or VXRT_SHADER_CACHE). Needs the Metal toolchain (xcrun metal).
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
D=${1:-${VXRT_SHADER_CACHE:-$R/build/private/shadercache}}
SDK=${2:-macosx}
[ -d "$D/pending" ] || { echo "nothing pending in $D"; exit 0; }
n=$(find "$D/pending" -name '*.metal' | wc -l | tr -d ' ')
[ "$n" -gt 0 ] || { echo "nothing pending in $D"; exit 0; }
J=$(sysctl -n hw.ncpu)
echo "== compiling $n shaders from $D/pending for -sdk $SDK, $J at a time"
# The compiler is resolved once and called directly with SDKROOT: `xcrun -sdk .. metal` per file costs about as much
# again as the compile itself (2.2 s against 1.2 s per 10 shaders, measured), 10807 files long.
MB=$(xcrun -sdk "$SDK" -f metal)
SDKROOT=$(xcrun -sdk "$SDK" --show-sdk-path)
export D SDK MB SDKROOT
find "$D/pending" -name '*.metal' -print0 | xargs -0 -P "$J" -n 1 sh -c '
  m=$1; b=${m%.metal}; k=$(basename "$b")
  read std32 min_lod safe < "$b.flags" || { echo "no flags: $k" >&2; exit 0; }
  [ -f "$D/$k.metallib" ] && { rm -f "$m" "$b.flags"; exit 0; }
  set --; if [ "$std32" = 1 ]; then set -- "$@" -std=metal3.2; else set -- "$@" -std=metal3.1; fi
  [ "$min_lod" = 1 ] && set -- "$@" -DVXRT_HAS_MIN_LOD_CLAMP=1
  [ "$safe" = 1 ] && set -- "$@" -fno-fast-math
  # The library records its output file name: a fixed name inside a private folder keeps the bytes the same from run to run
  # (a pid in the name made every library differ in the name, the function UUID and hash, and sometimes in size).
  td=$(mktemp -d "$D/.fill.XXXXXX"); t="$td/$k.metallib"
  if "$MB" "$@" -w -o "$t" "$m" 2>/dev/null; then mv "$t" "$D/$k.metallib"; rm -rf "$td"; rm -f "$m" "$b.flags"
  else rm -rf "$td"; echo "failed: $k" >&2; fi' sh
echo "== cache now: $(find "$D" -maxdepth 1 -name '*.metallib' | wc -l | tr -d ' ') libraries, $(du -sh "$D" | cut -f1); $(find "$D/pending" -name '*.metal' | wc -l | tr -d ' ') still pending"
