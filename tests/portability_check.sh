#!/bin/sh
# Portability regression check (make -C VXRuntime portability-check): no personal identity or machine path in the
# committed live files, the stage manifest matches the dispatcher, and the helper tools' own tests pass.
# History (history/, handoffs/, plans/, research/) and
# vendored upstream sources are not live Skyrim-path files and are not scanned. Run from anywhere.
set -u
R=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); cd "$R"
fail=0
hits=$(git grep -nIE 'MA9VLPU826|marimokodai|gseddon\.dev|/Users/gseddon|Verantyx_VR_Drive|717AC0D2-|52B8333F-|7YNW843VY6' -- . \
  ':!history' ':!handoffs' ':!plans' ':!research' ':!third_party/xrizer/upstream' ':!tests/portability_check.sh' ':!VXRuntime/tests/xrizer_xros_fixture.md' \
  ':!docs/VERANTYX_UPSTREAM_README.md' ':!provenance' || true)
if [ -n "$hits" ]; then echo "portability-check: personal identity or machine path in committed files:"; echo "$hits"; fail=1; fi
keys=$(git grep -nIE 'NEXUS_API_KEY=["'"'"']?[A-Za-z0-9+/_=-]{16,}' -- . ':!tests/portability_check.sh' || true)
if [ -n "$keys" ]; then echo "portability-check: a Nexus API key in committed files (lines not shown)"; fail=1; fi
python3 -I - <<'PY' || fail=1
import json, re, sys
spec = json.load(open('tools/vxrt_stages.json'))
src = open('tools/vxrt_build.py').read()
names = [s['name'] for s in spec['stages']]
m = re.search(r"STAGES = \{(.*?)\}", src, re.S).group(1)
have = re.findall(r"'([a-z-]+)':", m)
if sorted(names) != sorted(have):
    print('portability-check: tools/vxrt_stages.json stages %s differ from tools/vxrt_build.py %s' % (names, have)); sys.exit(1)
PY
for t in tests/skyrim_aot_pipeline_test.py tests/skyrim_device_stage_test.py tests/shader_manifest_build_test.py tests/nexus_test.py; do env -u VXRT_PRIVATE_ROOT -u VXRT_LOCAL_ENV python3 "$t" >/dev/null 2>&1 || { echo "portability-check: $t failed"; fail=1; }; done
sh -n tools/setup_rust.sh tools/play_skyrim_dev.sh || fail=1
[ $fail = 0 ] && echo "portability-check: ok"
exit $fail
