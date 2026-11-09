#!/bin/sh
# probe.sh <out-number> <seconds> <trigger-at-seconds|-> [harness flags...]
W=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot
R=/Users/gseddon/git/Skyrim-VR-Vision-Pro
B=build/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
cd $W
n=$1; secs=$2; trig=$3; shift 3
# Refuse only for the user's session or a runtime using this run's directory; owned isolated runs may overlap
# (the harness checks again and records them under diagnostic.concurrent_runtime).
python3 $R/tools/vxrt_runtime_sessions.py --own $W/build/xrizer-game-$n || { echo BUSY; exit 1; }
cp $R/tools/vxrt_native_startup.py $R/tools/vxrt_runtime_sessions.py tools/
rm -rf build/xrizer-game-$n /tmp/draws$n.trigger
python3 tools/vxrt_native_startup.py --exe $B/prepared/SkyrimVR.exe --runtime $R/VXRuntime/build/${STAGE:-terra-stage}/vxrt-arm64 --aot-dir $B/${AOTD:-aot-splits4a} --asset-root /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR --dll-dir $B/redist --dll-dir /Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SteamVR/bin/vrwebhelper/win64 --appid 611670 --out build/xrizer-game-$n --seconds $secs --trace-null-target --experimental-xrizer --dev-synthetic-stage --xrizer-dylib $R/build/xrizer-submit-diag-dylib/aarch64-apple-darwin/debug/libxrizer.dylib "$@" > /tmp/p$n.out 2>&1 &
if [ "$trig" != "-" ]; then sleep $trig; touch /tmp/draws$n.trigger; fi
wait
git checkout tools/vxrt_native_startup.py
git ls-files --error-unmatch tools/vxrt_runtime_sessions.py >/dev/null 2>&1 && git checkout tools/vxrt_runtime_sessions.py || rm -f tools/vxrt_runtime_sessions.py
head -3 build/xrizer-game-$n/process.json | tr -d '\n'; echo
