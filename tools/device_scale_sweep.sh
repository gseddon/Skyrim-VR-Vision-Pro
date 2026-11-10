#!/bin/bash
# Render-scale sweep on the physical Vision Pro: is Skyrim VR limited by pixel count?
# Subject: the actual game (Helgen cart ride) in the signed app gseddon.dev.vxrt.SkyrimVR on the device.
# The headset MUST be worn and unlocked for the whole sweep: when it comes off the system invalidates the
# compositor layer and all frames stop (plans/2026-11-10-skyrim-device-readiness.md, runs A, "off-head").
#
# usage: tools/device_scale_sweep.sh [out-dir]
#   env: DEV          device UUID (default: the paired Vision Pro)
#        ORDER        scales in run order (default "0.5 0.7 1.0")
#        PROFILE=1    also set VXRT_GPU_PROFILE=1 (per-pass GPU time) for every arm; use ORDER="0.7 0.5" in a separate sweep
#                     (the profile counters may perturb timing, so do not mix profiled and unprofiled arms)
#        RUN_SECS     seconds each launch runs before it is stopped (default 100)
#        INSTALL_APP  path of a signed VXRuntimeHost.app to install first (default: use what is installed)
#        EXTRA_ENV    more "K=V" pairs for every arm (space separated)
# Every arm gets VXRT_RENDER_SCALE=<s>, VXRT_STATS=1 (the game's "GPU: busy N%" lines) and VXRT_LOG_TEE=1 (the runtime
# log streams to the launch console; console.txt has the Mac receive time of every line, so no file copy is needed for it).
# Scene: the Skyrim main menu (static pose). Per arm the user presses one button at the title (the script posts
# "ASK USER: press any button now" to $STATUS ~20 s after launch and takes a headset screenshot via $SHOT).
# Arms run back to back; the device file service (wireless) stalls while copying, so host_log.jsonl is pulled ONCE at
# the end with the app not running (retries); its per-arm part is found by the launch pid.
# Then: tools/device_scale_analyze.py <out-dir>
set -u
DEV=${DEV:-52B8333F-A6DD-5405-B626-CDE9C2C16CC5}
BID=gseddon.dev.vxrt.SkyrimVR
ORDER=${ORDER:-"0.5 0.7 1.0"}
RUN_SECS=${RUN_SECS:-100}
OUT=${1:-/tmp/claude/perf/pixeltest/sweep-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/sweep.log"; }

running_pid() {  # pid of our app on the device, or empty
  xcrun devicectl --timeout 40 device info processes --device "$DEV" --json-output "$OUT/procs.json" >/dev/null 2>&1 || return 1
  python3 -I - "$OUT/procs.json" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
for p in d.get("result", {}).get("runningProcesses", []):
    if "VXRuntimeHost" in str(p.get("executable", "")): print(p.get("processIdentifier", "")); break
PY
}

if [ -n "${INSTALL_APP:-}" ]; then
  say "installing $INSTALL_APP (data container kept)"
  xcrun devicectl --timeout 600 device install app --device "$DEV" "$INSTALL_APP" 2>&1 | tail -3 | tee -a "$OUT/sweep.log"
fi
xcrun devicectl --timeout 40 device info apps --device "$DEV" --bundle-id $BID 2>&1 | tail -2 | tee -a "$OUT/sweep.log"

STATUS=${STATUS:-/tmp/claude/perf/pixeltest/STATUS.md}
SHOT=${SHOT:-/tmp/claude/perf/pixeltest/shot.sh}
post() { echo "$(date +%H:%M:%S) $*" >> "$STATUS"; say "$*"; }
if ! xcrun devicectl --timeout 15 device info details --device "$DEV" >/dev/null 2>&1; then
  post "ASK USER: device link stalled (info details > 15 s): please check Wi-Fi / Mac-headset connection"; exit 6
fi
n=0
for s in $ORDER; do
  n=$((n+1)); A="$OUT/arm_${n}_${s}"
  if [ -s "$A/pid.txt" ]; then say "arm $n scale $s already run, skipping"; continue; fi
  mkdir -p "$A"
  cur=$(running_pid || true)
  if [ -n "$cur" ]; then say "APP ALREADY RUNNING (pid $cur): not launching, not touching it"; exit 3; fi
  env_json="{\"VXRT_RENDER_SCALE\":\"$s\",\"VXRT_STATS\":\"1\",\"VXRT_LOG_TEE\":\"1\""
  [ -n "${PROFILE:-}" ] && env_json="$env_json,\"VXRT_GPU_PROFILE\":\"1\""
  for kv in ${EXTRA_ENV:-}; do env_json="$env_json,\"${kv%%=*}\":\"${kv#*=}\""; done
  env_json="$env_json}"
  echo "$env_json" > "$A/env.json"
  say "arm $n: launching scale $s env $env_json"
  ( xcrun devicectl --timeout 400 device process launch --device "$DEV" --console \
      --environment-variables "$env_json" $BID 2>&1 \
    | python3 -I -u -c 'import sys,time
for l in sys.stdin: sys.stdout.write("%.3f|%s" % (time.time(), l)); sys.stdout.flush()' > "$A/console.txt" ) &
  CP=$!
  pid=""
  for i in $(seq 1 30); do sleep 2; pid=$(running_pid || true); [ -n "$pid" ] && break; kill -0 $CP 2>/dev/null || break; done
  if [ -z "$pid" ]; then
    post "ASK USER: launch of arm $n failed or the app is not running (headset not unlocked?). See $A/console.txt"
    kill $CP 2>/dev/null; exit 4
  fi
  echo "$pid" > "$A/pid.txt"; date +%s > "$A/mac_launch_epoch.txt"
  say "arm $n: pid $pid running; ${RUN_SECS}s"
  sleep 20
  post "arm $n (scale $s) launched pid $pid. ASK USER: press any button now (Skyrim title), then leave it at the main menu"
  [ -x "$SHOT" ] && "$SHOT" > "$A/shot_title.txt" 2>&1; cp "$(awk '{print $1}' "$A/shot_title.txt" 2>/dev/null)" "$A/shot_title.png" 2>/dev/null
  sleep $((RUN_SECS - 70))
  [ -x "$SHOT" ] && "$SHOT" > "$A/shot_mid.txt" 2>&1; cp "$(awk '{print $1}' "$A/shot_mid.txt" 2>/dev/null)" "$A/shot_mid.png" 2>/dev/null
  sleep 40
  xcrun devicectl --timeout 60 device process terminate --device "$DEV" --pid "$pid" 2>&1 | tail -1 | tee -a "$OUT/sweep.log"
  sleep 4; kill $CP 2>/dev/null
  post "arm $n done (scale $s); GPU lines in console: $(grep -c 'GPU: busy' "$A/console.txt")"
  sleep 5
done
post "all arms run; pulling host_log.jsonl once (app not running)"
for try in 1 2 3 4 5 6; do
  xcrun devicectl --timeout 150 device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier $BID \
    --source Documents/host_log.jsonl --destination "$OUT/host_log.jsonl" >/dev/null 2>&1 && break
  say "host_log copy try $try failed"; sleep 10
done
[ -s "$OUT/host_log.jsonl" ] || { post "ASK USER: host_log.jsonl could not be copied (file service stalled)"; exit 5; }
python3 -I - "$OUT" <<'PY'
import json, sys, os, glob
out = sys.argv[1]
runs = {}
cur = None
for l in open(out + "/host_log.jsonl", errors="replace"):
    try: e = json.loads(l)
    except Exception: continue
    if e.get("event") == "launch": cur = e.get("pid"); runs[cur] = []
    if cur is not None: runs[cur].append(l if l.endswith("\n") else l + "\n")
for a in glob.glob(out + "/arm_*"):
    pid = int(open(a + "/pid.txt").read().strip())
    open(a + "/last_run.jsonl", "w").writelines(runs.get(pid, []))
    print(os.path.basename(a), "pid", pid, len(runs.get(pid, [])), "lines")
PY
post "sweep complete: $OUT"
python3 -I "$(dirname "$0")/device_scale_analyze.py" "$OUT" | tee "$OUT/summary.txt"
