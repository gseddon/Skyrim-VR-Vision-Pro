#!/usr/bin/env python3 -I
"""skyui_nojit.py SKYUI_DATA OUT (SKYUI_DATA: the SkyUI VR mod's Data folder): a mod folder (OUT/Data/...) that turns LuaJIT's JIT off in SkyUI VR.

SkyUI-VR.dll embeds LuaJIT 2.1.0-beta3. Under strict AOT nothing may generate code at run time: when a Lua loop gets hot, LuaJIT writes machine
code into a VirtualAlloc'd area, makes it executable and jumps to it, and that address (a heap address, 0x70432ffe54 in a run) has no recompiled
code, so the run stops. Which runs stop depends on whether LuaJIT finds room for its code area within 1 GB of the DLL, so it depends on where
the modules sit (research/2026-11-11-skyui-luajit.md). LuaJIT's own interpreter needs nothing generated, and `jit.off()` (luaJIT_setmode with
LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF) keeps it in the interpreter; mcode_protfail is not a fallback (it calls the panic handler and returns).

This writes OUT/Data/SKSE/Plugins/SkyUI-VR/MainEntry.lua: the mod's own MainEntry.lua with one line in front. List OUT as a mod after
SkyUI VR in the mods list (a higher priority wins the clash in the merged tree). The user's SkyUI files are only read."""
import hashlib, sys
from pathlib import Path
REL = Path('Data/SKSE/Plugins/SkyUI-VR/MainEntry.lua')
PRELUDE = ('-- vxrt: strict AOT cannot run LuaJIT-compiled code (tools/skyui_nojit.py); the original MainEntry.lua follows unchanged\n'
           'if jit and jit.off then jit.off() end\n')
def main(src, out):
    orig = (Path(src) / REL.relative_to('Data')).read_bytes()
    dst = Path(out) / REL; dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(PRELUDE.encode() + orig)
    print('%s: original sha256 %s, %d bytes + prelude' % (dst, hashlib.sha256(orig).hexdigest(), len(orig)))
if __name__ == '__main__':
    if len(sys.argv) != 3: sys.exit(__doc__)
    main(*sys.argv[1:])
