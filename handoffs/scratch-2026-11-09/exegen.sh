#!/bin/bash
# exegen.sh <outdir> <base-hex|-> : Skyrim exe modules from HEAD's vxrt-aot, 16 MB parts, the aot-fix split profile (rebased with the image)
set -e
out=$1; base=$2
G=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build/aot-fix
B=/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot/build/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
C=/Users/gseddon/git/Skyrim-VR-Vision-Pro/VXRuntime/build/vxrt-aot
stem=skyrimvr.exe-c48518d5fe0b9c54
rm -rf $out; mkdir -p $out/s $out/dylibs; cd $out
if [ "$base" = "-" ]; then cp $G/splits.txt splits.txt; unset VXRT_AOT_BASE
else python3 - $G/splits.txt splits.txt $((base)) <<'PY'
import sys
d=int(sys.argv[3])-0x140000000
open(sys.argv[2],'w').write(''.join('0x%x\n'%(int(l,16)+d) for l in open(sys.argv[1]) if l.strip()))
PY
export VXRT_AOT_BASE=$base; fi
: > roots.txt
t0=$(date +%s)
VXRT_AOT_PART_MB=16 VXRT_AOT_SPLITS=$PWD/splits.txt VXRT_AOT_ROOTS=$PWD/roots.txt $C gen $B/prepared/SkyrimVR.exe $PWD/s/S.s > S.list 2> gen.log
t1=$(date +%s)
tail -2 gen.log | cut -c1-220
seq 0 $(( $(wc -l < S.list) - 1 )) | xargs -P 10 -I{} sh -c "clang -arch arm64 -c -o s/S.p{}.o s/S.p{}.s && clang -arch arm64 -dynamiclib -o dylibs/$stem.p{}.dylib s/S.p{}.o"
t2=$(date +%s)
rm -rf s
echo "gen $((t1-t0))s, assemble+link $((t2-t1))s, parts $(ls dylibs | wc -l)"
