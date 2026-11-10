#!/bin/sh
# Run one headset test per invocation. The app and its container are never removed.
# DEV is required; OUT defaults to repository-local evidence, WAIT is 0..300 seconds.
# Exactly one test is accepted. An unknown devicectl process JSON schema fails closed.
# The installed host must record -lognonce in its launch event (main.m).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P) || exit 1
APP=gseddon.dev.vxrt.VXRuntimeHost
OUT=${OUT:-"$ROOT/runs/xros-device"}
WAIT=${WAIT:-40}
[ -n "${DEV:-}" ] || { echo 'DEV is required' >&2; exit 2; }
case "$WAIT" in ''|*[!0-9]*) echo 'WAIT must be an integer from 0 to 300' >&2; exit 2;; esac
[ ${#WAIT} -le 3 ] && [ "$WAIT" -le 300 ] || { echo 'WAIT must be an integer from 0 to 300' >&2; exit 2; }
[ "$#" -eq 1 ] || { echo "Specify exactly one test" >&2; exit 2; }
for arg do
    case "$arg" in *@*) t=${arg%@*}; pres=${arg##*@};; *) t=$arg; pres=vr;; esac
    case "$t" in ''|*[!a-zA-Z0-9_]*) echo "invalid test: $arg" >&2; exit 2;; esac
    case "$pres" in vr|flat) ;; *) echo "invalid presentation: $arg" >&2; exit 2;; esac
done
# Resolve OUT without creating it, reject symlinks and paths outside the repository.
OUT=$(python3 - "$ROOT" "$OUT" <<'PY'
import os, sys
root, out = sys.argv[1:]
out = os.path.realpath(out)
if os.path.commonpath([root, out]) != root or out == root:
    sys.exit('OUT must be inside the repository')
print(out)
PY
) || exit 2
mkdir -p "$OUT" || exit 1
run=$(mktemp -d "$OUT/run.XXXXXXXX") || exit 1
for arg do
    case "$arg" in *@*) t=${arg%@*}; pres=${arg##*@};; *) t=$arg; pres=vr;; esac
    # A session may have appeared after the previous test; check before every launch.
    if ! xcrun devicectl --timeout 30 device info processes --device "$DEV" --json-output - > "$run/processes.json" 2> "$run/processes.err"; then
        echo 'Cannot inspect device processes; refusing launch' >&2; exit 1
    fi
    if ! python3 - "$run/processes.json" "$APP" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    processes = data['result']['runningProcesses']
    if not isinstance(processes, list): raise ValueError('invalid process list')
    for p in processes:
        if not isinstance(p, dict): raise ValueError('invalid process')
        path = p.get('executable')
        if isinstance(path, dict): path = path.get('path')
        if not isinstance(path, str) or not path: raise ValueError('unknown executable')
        if sys.argv[2] in path or '/VXRuntimeHost.app/' in path or path.endswith('/VXRuntimeHost'):
            raise ValueError('target session is active')
except (OSError, ValueError, KeyError, TypeError) as e:
    sys.exit('Cannot prove target is idle: ' + str(e))
PY
    then exit 1; fi
    case_dir=$(mktemp -d "$run/$t.$pres.XXXXXXXX") || exit 1
    # A random marker distinguishes this launch from the append-only host log's old records.
    nonce=$(python3 -c 'import secrets; print(secrets.token_hex(16))') || exit 1
    echo "== $t ($pres): $case_dir"
    if xcrun devicectl --timeout 120 device process launch --device "$DEV" "$APP" -- -test "$t" -present "$pres" -lognonce "$nonce" > "$case_dir/launch.txt" 2>&1; then
        echo 0 > "$case_dir/launch.status"
    else
        rc=$?; echo "$rc" > "$case_dir/launch.status"; echo "Launch failed: $case_dir" >&2; exit 1
    fi
    sleep "$WAIT"
    # host_log: one file per launch (host_log-<ts>.jsonl); the newest is pulled by tools/pull_host_log.sh and stored as host_log.jsonl
    "$(dirname "$0")/../../tools/pull_host_log.sh" "$case_dir/host_log.jsonl" "$DEV" "$APP" > "$case_dir/host_log.copy.txt" 2>&1 \
        && echo 0 > "$case_dir/host_log.jsonl.copy.status" || { echo "Copy failed: host_log" >&2; exit 1; }
    for log in vxrt.log; do
        if xcrun devicectl --timeout 60 device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$APP" --source "Documents/$log" --destination "$case_dir/$log" > "$case_dir/$log.copy.txt" 2>&1; then
            echo 0 > "$case_dir/$log.copy.status"
        else
            rc=$?; echo "$rc" > "$case_dir/$log.copy.status"; echo "Copy failed: $log" >&2; exit 1
        fi
        [ -f "$case_dir/$log" ] || { echo "Copy produced no file: $log" >&2; exit 1; }
    done
    if ! python3 - "$case_dir/host_log.jsonl" "$t" "$nonce" <<'PYLOG'
import json, sys
try:
    with open(sys.argv[1], 'rb') as log:
        records = [json.loads(line) for line in log if line.strip()]
    if not any(r.get('event') == 'launch' and r.get('test') == sys.argv[2]
               and r.get('nonce') == sys.argv[3] for r in records):
        raise ValueError('no matching launch nonce and test')
except (OSError, ValueError, TypeError, AttributeError) as e:
    sys.exit('Unverified evidence: ' + str(e))
PYLOG
    then exit 1; fi
    echo "Logs captured: $case_dir"
done
