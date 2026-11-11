# SkyUI VR under strict AOT at the device layout: the stop at `0x...fe54` is LuaJIT's JIT

Date: 11 November 2026. Branch `skyui` (from `skse`). Subjects: **static analysis** of `SkyUI-VR.dll` (read-only disassembly), **actual game on the Mac** (strict AOT at the device module layout, `VXRT_AOT_ARENA=0x7000000000`; not a headset run, not a playability claim) and **owned fixtures**. Parent: [SKSE VR on the AOT runtime](2026-11-11-skse-vr-on-aot.md) sections 5b and 5c.

## Root cause

`SkyUI-VR.dll` embeds **LuaJIT 2.1.0-beta3** (string `LuaJIT 2.1.0-beta3`, `jit.profile`/`jit.util`/`jit.opt`; its string table is `lj_str_new`, hash at `+0x24660`..`+0x243b0`), not the PUC Lua the earlier notes assumed. When a Lua loop gets hot LuaJIT compiles a trace:

1. `mcode_alloc` (`+0x4cba0`): up to 31 times `VirtualAlloc(hint, size, MEM_RESERVE|MEM_COMMIT|MEM_TOP_DOWN, PAGE_READWRITE)` with `hint = DLL base - 0x3fe00000 + (random & 0x7fff0000)`; the area must lie within `0x3fe00000` of the DLL (the call at `+0x4cc0a`, window checks at `+0x4cc21`, `+0x4cc30`).
2. Machine code is written into that area, then `mcode_setprot` (`+0x4c8c2`: `VirtualProtect(area, size, 0x20 = PAGE_EXECUTE_READ)`), then the trace is entered by a jump to an address in the area.
3. Under strict AOT that address is "no image" and the run stops. Every stop had a target `0x70xxxxfe54` (`0x7043b6fe54`, `0x70432ffe54`, `0x7041aefe54`, `0x704041fe54`, and in my run `0x704210fe54` from the area `0x7042100000`): the trace entry near the end of a 64 KB code area, about 1.06 GB above the DLL (`0x7004270000`), inside the allowed window. The register values, the ring `+0x4cc10`, `+0x5fc36`, `+0x4c8c8`, ... and `rax` = the target are the trace entry sequence; `r13 = r14` is the Lua state.

**Why it depends on the module layout.** `tests/mcode_window_a.c` repeats the `mcode_alloc` hint loop (400 attempts of 31 hints) against this runtime (`make -C VXRuntime mcode-window-probe`, owned fixture, Mac):

| Layout | target | attempts that got an area |
| --- | --- | --- |
| old Mac layout, arena `0x300000000` (SkyUI at `0x30f000000`) | `0x30f024729` | **0 of 400** |
| device layout, arena `0x7000000000` (SkyUI at `0x7004270000`) | `0x7004294729` | **236 of 400** |

At the old layout the allocation fails, LuaJIT gives up the trace (`LJ_TRERR_MCODEAL`), the interpreter goes on and nothing generated is ever run: 0 of 6 runs stopped. At the device layout there is free address space within 1 GB of the DLL, the area is allocated, and the compiled trace is jumped to. Nothing is wrong with the runtime's address lookup (the hypotheses of a truncated pointer or a table sized for the arena are not the cause); the target is not guest code that is merely unrooted: it is code the program generates at run time, which strict AOT can never run (and visionOS does not allow).

## Why refusing the executable request is not the fix

With `VXRT_AOT_STRICT`, `VirtualProtect(..., PAGE_EXECUTE_READ)` outside an image now fails with 1655 (`ERROR_DYNAMIC_CODE_BLOCKED`, what Windows returns under a ProhibitDynamicCode policy; `kernel32.c`, fixture `tests/dynamic_code_a.c`, `make -C VXRuntime dynamic-code-check`). LuaJIT beta3 handles the failure in `mcode_protfail` (`+0x4cd40`): it pushes the message `runtime code generation failed, restricted kernel?`, calls the Lua panic handler and **returns** (checked in the disassembly and in the run: `PANIC: unprotected error in call to Lua API (runtime code generation failed, restricted kernel?)`, then the jump to `0x704210fe54`, run `play-082014`). So the refusal is a clear diagnostic (the log line names the call and its caller) but not a fallback: the trace is still entered. It stays as a strict-mode guard; `VXRT_AOT_DYNAMIC_CODE=1` turns it off.

## Fix

The JIT engine has to be off: `jit.off()` is `luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE|LUAJIT_MODE_OFF)`, and LuaJIT's interpreter generates nothing. SkyUI VR has no setting for it (`SkyUI-VR.settings.lua` holds `showInputReadout` and `VRInput.logDetails`). `tools/skyui_nojit.py` writes a mod folder with `Data/SKSE/Plugins/SkyUI-VR/MainEntry.lua` = the mod's own file with one line in front (`if jit and jit.off then jit.off() end`); listed after SkyUI VR in the mods list (priority 51) it wins the clash in the merged tree. `tools/mods.py` now records the winning file once in `skse_plugins` (before, both hashes were listed and the harness refused the run: "differs from the pack's recorded hash"). The DLL, the AOT modules and the capture are unchanged by this; the Lua VM's instruction sweep (`VXRT_AOT_SWEEP`, section 5b) is still needed for the interpreter.

## Capture note

The capture depends on the plugin load order; `FindFirstFile` has returned sorted names since 03:30 (section 5d), so the captures of the 01:xx SkyUI runs (host order) fail `VXRT_CODE_VERIFY` with the current runtime (60 entries differ). All runs here use a new capture (`cap-dev5`, 104 code runs, taken at the device bases with the four plugins in sorted order).

## Validation (subject: actual game on the Mac, strict AOT, device module layout `VXRT_AOT_ARENA=0x7000000000`, 1 GB; not a headset run, not a playability claim)

Modules: the SKSE set with SkyrimVRTools, HIGGS, PLANCK and SkyUI VR (SkyUI sweep `1000-5200`), made from `cap-dev5` (taken on the Mac at the device bases, sorted plugin order), hooks module hash as in `pipe-d5`; pack = the earlier mods-set plus `skyui-vr-nojit`. `VXRT_CODE_VERIFY` + `VXRT_CODE_WATCH=1000`, input A every 2 s (Helgen path), 200 s limit (the harness ends the run: `timed_out`, returncode -9 is the limit, not a crash).

| Run | Pack | Result |
| --- | --- | --- |
| `play-081138` | old capture `cap-dev-early` (host-order) | `VXRT_CODE_VERIFY` stops at start-up: 60 of 105 entries differ (capture invalid with sorted listings) |
| `play-082014` | with `cap-dev5`, no `jit.off()` | guard log, `PANIC ... runtime code generation failed`, strict stop at `0x704210fe54` after 37 s: the original failure reproduced |
| `play-082505`, `play-082829`, `play-083153` | with `cap-dev5`, `skyui-vr-nojit` | 200 s, 1.41 G / 0.98 G / 1.25 G entries into recompiled code, **0 fallbacks**, no LATE CODE WRITE, verify passed, no 1655 refusal (LuaJIT never tries to compile), no PANIC |

Three runs, not five: the series was cancelled by the user after run 3. `make -C VXRuntime check` was not run after this change; `make dynamic-code-check` (new) and `python3 -I tests/mods_override_test.py` pass. Not observed: SkyUI's inventory/MCM menus (Helgen cart), the device (the SKSE agent owns it).
