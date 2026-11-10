#!/bin/sh
# private-capture.sh: this worktree's build/private copies for the harness (it runs only repository-local images):
# the prepared exe and redist as byte-identical copies of the terra-skyrim-aot worktree's, the aot-splits4a modules
# as symlinks to their resolved files there. Private, never committed (build/ is ignored).
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
H=6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
S=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build/private/skyrimvr/$H
D=$R/build/private/skyrimvr/$H
mkdir -p "$D/aot-splits4a"
[ -d "$D/prepared" ] || cp -Rp "$S/prepared" "$D/prepared"
[ -d "$D/redist" ] || cp -Rp "$S/redist" "$D/redist"
for f in "$S"/aot-splits4a/*; do ln -sf "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$f")" "$D/aot-splits4a/$(basename "$f")"; done
shasum -a 256 "$S/prepared/SkyrimVR.exe" "$D/prepared/SkyrimVR.exe"
ls "$D/aot-splits4a" | wc -l
