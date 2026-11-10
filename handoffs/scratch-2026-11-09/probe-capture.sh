#!/bin/sh
# probe-capture.sh <out-number> <seconds> [harness flags...]: probe-ctl.sh for this worktree with the capture dev host
# (VXRuntime/build/capture-host, hostbuild-capture.sh) and the private copies of private-capture.sh. The xrizer dylib
# is the main checkout's submit-diag build (as probe 1110). Output in this worktree's build/xrizer-game-<n>.
R=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
M=/Users/gseddon/git/Skyrim-VR-Vision-Pro
B=$R/build/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
n=$1; secs=$2; shift 2
out=$R/build/xrizer-game-$n
[ -e "$out" ] && { echo "EXISTS $out"; exit 1; }
python3 $R/tools/vxrt_runtime_sessions.py --own $out || { echo BUSY; exit 1; }
mkdir -p /tmp/claude/ctl
python3 $R/tools/vxrt_native_startup.py --exe $B/prepared/SkyrimVR.exe --runtime $R/VXRuntime/build/capture-host/vxrt-arm64 \
  --aot-dir $B/${AOTD:-aot-splits4a} --asset-root /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR \
  --dll-dir $B/redist --dll-dir /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SteamVR/bin/vrwebhelper/win64 \
  --appid 611670 --out $out --seconds $secs --trace-null-target --experimental-xrizer --dev-synthetic-stage \
  --xrizer-dylib $M/build/xrizer-submit-diag-dylib/aarch64-apple-darwin/debug/libxrizer.dylib "$@" > /tmp/claude/ctl/p$n.out 2>&1
echo "exit $?"
head -3 $out/process.json | tr -d '\n'; echo
