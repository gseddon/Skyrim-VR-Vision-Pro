#!/bin/bash
# fast.sh <tag> <runs> <runtime> : direct boots of the game (own process only), stop at the window creation result
W=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build
B=$W/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
tag=$1; runs=$2; rt=${3:-/Users/gseddon/git/Skyrim-VR-Vision-Pro/VXRuntime/build/terra-stage2/vxrt-arm64}
R=/Users/gseddon/git/Skyrim-VR-Vision-Pro
# Refuse only for the user's session or a runtime using this run's directory; VXRT_HARNESS_RUN marks these boots as owned.
python3 $R/tools/vxrt_runtime_sessions.py --own /tmp/fast_$tag --tmp /tmp/fast_$tag/temp || { echo BUSY; exit 1; }
bad=0
for i in $(seq 1 $runs); do
  d=/tmp/fast_$tag; rm -rf $d; mkdir -p $d/temp $d/overlay $d/root $d/xdg/cache $d/xdg/config $d/xdg/data $d/xdg/state
  cd /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR && env -i HOME=$HOME PATH=$PATH TMPDIR=$d/temp VXRT_HARNESS_RUN=$d VERANTYX_AUDIO=0 VXRT_AOT_DIR=$B/${AOTD:-aot-splits2} VXRT_AOT_NULL_DIAGNOSTIC=1 VXRT_AOT_STRICT=1 $EXTRA \
    VXRT_DLL_PATH=$B/redist:/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SteamVR/bin/vrwebhelper/win64 VXRT_LOG_TIME=1 VXRT_MESSAGEBOX=auto VXRT_MUTE=1 VXRT_NO_ACTIVATE=1 VXRT_NO_WINE=1 \
    VXRT_OVERLAY=/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common:$d/overlay VXRT_ROOT=$d/root VXRT_STEAM_BRIDGE=0 VXRT_TRACE_CALLS=3 VXRT_XRIZER_DEV_STAGE=1 \
    VXRT_XRIZER_DYLIB=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/xrizer-submit-diag-dylib/aarch64-apple-darwin/debug/libxrizer.dylib \
    XDG_CACHE_HOME=$d/xdg/cache XDG_CONFIG_HOME=$d/xdg/config XDG_DATA_HOME=$d/xdg/data XDG_STATE_HOME=$d/xdg/state \
    /usr/bin/arch -arm64 $rt $B/prepared/SkyrimVR.exe > $d/log 2>&1 &
  pid=$!
  for t in $(seq 1 ${WAIT:-40}); do sleep 0.1; grep -q "SetFocus = \|unhandled exception" $d/log 2>/dev/null && break; done
  pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; sleep 0.3; pkill -9 -f "$d/root" 2>/dev/null; wait $pid 2>/dev/null
  grep -q "arena at .* is taken" $d/log && cp $d/log /tmp/fast_${tag}_taken.log && echo "lines: $(grep -c "arena at" $d/log)" && echo "run $i: arena taken: $(grep -m1 -A1 'arena at' $d/log | tail -1 | cut -c20-90)"
  grep -q "preferred range" $d/log && cp $d/log /tmp/fast_${tag}_exetaken.log && echo "run $i: exe range taken"
  grep -q "fallback" $d/log && echo "run $i: fallback"
  grep -q "base 0x.* is taken" $d/log && echo "run $i: module base taken"
  if grep -q "unhandled exception" $d/log || ! grep -q "SetFocus = " $d/log; then bad=$((bad+1)); cp $d/log /tmp/fast_${tag}_crash$bad.log; echo "run $i CRASH"; [ -n "$STOP" ] && break; fi
done
echo "$tag: $bad crashes in $runs"
