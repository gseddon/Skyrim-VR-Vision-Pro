#!/bin/bash
# Pull the newest host log from the headset: the app writes one Documents/host_log-<launch unix s>.jsonl per launch (main.m session_host_log), so
# the name changes every session and devicectl cannot hand back a cached prefix of a file that is still growing.
# usage: tools/pull_host_log.sh <destination file> [device] [bundle id]      (never while another devicectl copy is running)
set -u
DEST=${1:?destination file}
DEV=${2:-${DEV:-${VXRT_DEVICE_ID:-}}}
[ -n "$DEV" ] || { echo 'pull_host_log: set DEV or VXRT_DEVICE_ID (xcrun devicectl list devices)' >&2; exit 2; }
BID=${3:-${BID:-${XROS_BUNDLE_PREFIX:-dev.example.vxrt}.SkyrimVR}}
LIST=$(mktemp -t hostloglist).json
xcrun devicectl --timeout 60 device info files --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
  --subdirectory Documents --no-recurse --search host_log --json-output "$LIST" >/dev/null 2>&1 || { echo "pull_host_log: file listing failed" >&2; exit 2; }
NAME=$(python3 -I - "$LIST" <<'PY'
import json, re, sys
names = []
def walk(o):
    if isinstance(o, dict):
        for v in o.values(): walk(v)
        n = o.get("name") or o.get("path")
        if isinstance(n, str): names.append(n)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(json.load(open(sys.argv[1])))
best = None
for n in names:
    m = re.search(r"host_log-(\d+)\.jsonl$", n)
    if m and (best is None or int(m[1]) > best[0]): best = (int(m[1]), n.split("/")[-1])
print(best[1] if best else ("host_log.jsonl" if any(n.endswith("host_log.jsonl") for n in names) else ""))
PY
)
rm -f "$LIST"
[ -n "$NAME" ] || { echo "pull_host_log: no host_log file listed" >&2; exit 3; }
echo "pull_host_log: newest is $NAME" >&2
xcrun devicectl --timeout 150 device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
  --source "Documents/$NAME" --destination "$DEST" >/dev/null 2>&1 || { echo "pull_host_log: copy failed" >&2; exit 4; }
echo "pull_host_log: $NAME -> $DEST ($(wc -c < "$DEST") bytes)" >&2
