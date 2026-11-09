#!/bin/bash
# early.sh <n>: start the game n times, stop after 0.6 s, count what main() decided about the exe's range
W=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build
B=$W/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
rt=/Users/gseddon/git/Skyrim-VR-Vision-Pro/VXRuntime/build/terra-stage2/vxrt-arm64
R=/Users/gseddon/git/Skyrim-VR-Vision-Pro
# Refuse only for the user's session or a runtime using this run's directory; VXRT_HARNESS_RUN marks these boots as owned.
python3 $R/tools/vxrt_runtime_sessions.py --own /tmp/early --tmp /tmp/early/temp || { echo BUSY; exit 1; }
cd /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR
d=/tmp/early; rm -rf $d; mkdir -p $d/temp $d/overlay $d/root
tk=0; ok=0; nomod=0
for i in $(seq 1 $1); do
  env -i HOME=$HOME PATH=$PATH TMPDIR=$d/temp VXRT_HARNESS_RUN=$d VXRT_AOT_DIR=$B/${AOTD:-aot-splits4a} VXRT_AOT_MAPDUMP=1 VXRT_AOT_STRICT=1 VXRT_MUTE=1 VXRT_NO_ACTIVATE=1 VXRT_NO_WINE=1 VXRT_OVERLAY=/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common:$d/overlay VXRT_ROOT=$d/root VXRT_STEAM_BRIDGE=0 VXRT_DLL_PATH=$B/redist /usr/bin/arch -arm64 $rt $B/prepared/SkyrimVR.exe > $d/log 2>&1 &
  pid=$!; sleep 0.6; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  if grep -q "preferred range" $d/log; then tk=$((tk+1)); cp $d/log /tmp/early_taken_$tk.log
  elif grep -q "module base for the program: 0x308000000 (arena 1)" $d/log; then ok=$((ok+1))
  else nomod=$((nomod+1)); cp $d/log /tmp/early_other.log; fi
done
echo "n=$1 skip-ok=$ok exe-range-taken=$tk other=$nomod"
