#!/bin/sh
# aot_compare.sh <exe> [args]: compare Rosetta, the ARM64 translator and strict route-B AOT.
# AOT_EXPECTED_VERDICT, when set, must occur as a complete output line in each run.
cd "$(dirname "$0")/.." || exit 1
export VXRT_ROOT="${VXRT_ROOT:-build/root}" VXRT_NO_ACTIVATE=1
O=${AOT_COMPARE_OUT:-build/recomp/out}
mkdir -p "$O" || exit 1
if [ "$#" -eq 0 ]; then echo "usage: $0 <exe> [args...]" >&2; exit 2; fi
exe=$1; shift
n=$(basename "$exe" .exe)
rosetta=${AOT_COMPARE_ROSETTA:-build/vxrt}
arm64=${AOT_COMPARE_ARM64:-build/vxrt-arm64}
case ${AOT_DIR:-build/aot} in
    /*) aot_dir=${AOT_DIR} ;;
    *) aot_dir=$PWD/${AOT_DIR:-build/aot} ;;
esac
status=0
unset VXRT_AOT_STRICT VXRT_AOT_DIR
ROSETTA_ADVERTISE_AVX=1 "$rosetta" "$exe" "$@" > "$O/$n.rosetta" 2>&1 || { echo "$n rosetta: child failed" >&2; status=1; }
"$arm64" "$exe" "$@" > "$O/$n.jit" 2>&1 || { echo "$n jit: child failed" >&2; status=1; }
VXRT_AOT_STRICT=1 VXRT_AOT_DIR="$aot_dir" "$arm64" "$exe" "$@" > "$O/$n.aotb" 2>&1 || { echo "$n aotb: child failed" >&2; status=1; }
for k in rosetta jit aotb; do
    grep -v -E '^(info:|time:|\[vxrt\])' "$O/$n.$k" > "$O/$n.$k.cmp" || [ "$?" -eq 1 ] || status=1
    if [ "${AOT_EXPECTED_VERDICT+x}" = x ] && ! grep -F -x -- "$AOT_EXPECTED_VERDICT" "$O/$n.$k.cmp" >/dev/null; then
        echo "$n $k: expected verdict missing" >&2; status=1
    fi
done
for k in jit aotb; do
    if cmp -s "$O/$n.rosetta.cmp" "$O/$n.$k.cmp"; then echo "$n $k: identical to Rosetta"; else
        echo "$n $k: DIFFERS"; diff "$O/$n.rosetta.cmp" "$O/$n.$k.cmp" | head -10; status=1
    fi
done
# Require one complete runtime summary, with actual AOT entries and no translator fallbacks.
if ! awk '
    /aot: .*entries into recompiled code/ {
        line = $0
        sub(/^\[vxrt\] /, "", line)
        if (line ~ /^aot: [0-9]+ entries into recompiled code, [0-9]+ C function calls, [0-9]+ native calls, [0-9]+ built-in export stubs followed, 0 fallbacks to the translator \(0 addresses\), [0-9]+ ordered accesses across 16 bytes$/ && line !~ /^aot: 0 entries/) valid++
        count++
        print
    }
    END { exit !(count == 1 && valid == 1) }
' "$O/$n.aotb"; then echo "$n aotb: missing or invalid zero-fallback AOT summary" >&2; status=1; fi
exit "$status"
