# SKSE VR on the AOT runtime: design and status

Date: 11 November 2026 (session clock 10 Nov). Branch `skse` (from `combined`). Subjects are named per claim: **source** (SKSEVR 2.0.12 source, read), **fixture** (owned mingw fixture, run on the Mac under strict AOT), **not run** (real game). Parent documents: [mods plan](../plans/2026-11-10-skyrim-vr-mods.md) (options A to D), [mods research](2026-11-10-skyrim-vr-mods.md), [RECOMP.md](../VXRuntime/RECOMP.md).

## 1. The download

| | |
| --- | --- |
| URL | https://skse.silverlock.org/beta/sksevr_2_00_12.7z (linked from https://skse.silverlock.org/ as "Current VR build 2.0.12 (game version 1.4.15)") |
| size, sha256 | 1,010,226 bytes, `f03df5d8663f2c9a781f830fb0809c63a9a0e3b626d6d1a96e38493f81a3c9ad` (HTTP Last-Modified 2020-08-08) |
| contents | `sksevr_loader.exe`, `sksevr_1_4_15.dll` (sha256 of the DLL `633be638...a973463`), `sksevr_steam_loader.dll`, readme, whatsnew, `Data/Scripts/*.pex`, `bindings/`, and **the full source** (`src/`, 403 files) |
| where | `build/private/skse/` (git-ignored; archive and `x/` extraction; nothing from it was run; listing and reading only, `bsdtar -x`). Work copies and AOT output are in `build/private/skse-work/` |
| Address Library for VR | **Not downloaded.** It is Nexus-only; GitHub `alandtse/vr_address_tools` holds the generator tools, no data and no release assets. HIGGS 1.10.10 and PLANCK 0.8.2 do not import it (mods research section 8). If a later plugin needs it the user downloads "VR Address Library for SKSEVR" from Nexus. |

Licence (`sksevr_readme.txt`, source `common_license.txt`): redistribution and re-hosting are forbidden ("this service is violating copyright"); releasing a modified SKSE is forbidden (extend it by plugins); the software is provided as is. So: private local use only. We never commit SKSE files, and our scheme builds private derived artifacts (patched translation, captured stubs) that are never published. This is a reading of the readme text, not legal advice.

## 2. How SKSE VR starts and what it changes (source)

- `sksevr_loader.exe`: `CreateProcess(CREATE_SUSPENDED)`, `VirtualAllocEx` + `WriteProcessMemory` of the DLL path, `CreateRemoteThread(LoadLibraryA)`, `ResumeThread` (`skse64_loader_common/Inject.cpp`). The steam variant injects `sksevr_steam_loader.dll`, which IAT-hooks `VCRUNTIME140!__telemetry_main_invoke_trigger` and then `LoadLibrary`s the main DLL.
- `DllMain` → `SKSE64_Initialize` (`skse64/skse64.cpp`): log `Documents\My Games\Skyrim VR\SKSE\sksevr.log`; `g_branchTrampoline.Create(64K)` (VirtualQuery backwards from the exe base, `VirtualAlloc` RWX within 2 GB); `g_localTrampoline.Create(64K, dll)` (code buffer); `Hooks_*_Init`; `PluginManager.Init` (`LoadLibrary` of `Data\SKSE\Plugins\*.dll`, `SKSEPlugin_Query`, `SKSEPlugin_Load`); `Hooks_*_Commit`; "init complete".
- Patch set, counted from source: 38 `Write5Branch/Call` + 2 `Write6` (each an `E8/E9/FF15/FF25` at a fixed RVA of the exe pointing into a 14-byte `FF 25 00000000 <abs64>` stub in the trampoline), 11 Xbyak stubs (Gameplay, Camera, NetImmerse, Papyrus, Scaleform) in the code buffer, about 25 `SafeWrite` (NOPs, vtable and IAT data), IAT hooks (`openvr_api!VR_GetGenericInterface` and three more, `dinput8!DirectInput8Create`, `SetUnhandledExceptionFilter`). All sites are `RelocAddr` (exe base + constant); eight `skse.ini` switches only toggle small items.
- Under our runtime: x86 code pages are plain RW memory (`VX_PROT_CODE`), so every write succeeds and nothing runs differently: AOT blocks hold direct branches decided at translation time (`RECOMP.md`: "writes to code pages are not watched"). SKSE would initialise and do nothing.

## 3. Designs

| | Design | Verdict |
| --- | --- | --- |
| **A** | Capture the writes on the Mac, bake them into the AOT translation of the exe, translate the stubs as a module, verify at start-up | **Chosen. Mechanism proven on a fixture (section 4).** |
| B | Trap guest writes to translated pages and redirect | Rejected: every call site would need an indirection (1.3 M blocks in the exe), or a handler per write plus a module entry for the new target; costs on every call for a rare event. |
| C | Hybrid: patchable-site table emitted only at known hook RVAs | Kept as a later refinement: it would let a plugin change avoid recompiling the exe. Not needed now: `vxrt-aot gen` of the exe takes 6 s, clang is the cost and is cached per module. |

Why A is sound here: the patch set is finite and fixed-RVA; the stubs embed only addresses that are fixed in our scheme (DLL globals at the DLL's fixed arena base, exe RVAs at the rebased exe, region addresses); the one thing that could differ, a run-time-chosen address, is caught by **verify**.

## 4. What was built (all verified on the fixture only)

| Piece | File | Behaviour |
| --- | --- | --- |
| Preload | `VXRuntime/src/codehooks.c`, hook in `run_program` (`loader.c`) | `VXRT_PRELOAD=a.dll;b.dll` is loaded after the exe image and TLS callbacks, before its entry point: the place the injected thread's `LoadLibrary` ran. No suspended process, no remote thread. |
| Executable region | `codehooks.c`, `kernel32.c` (`VirtualAlloc`, `VirtualQuery`) | `VXRT_EXEC_REGION=<dll>`: executable commits are served from that image's section in 64 KB slices, zeroed, in request order; `VirtualQuery` shows the unserved part as free so SKSE's own search for room near the exe finds it. Addresses are reproducible. |
| Capture | `codehooks.c` | `VXRT_CODE_CAPTURE=<file>`: snapshot of every executable section before the preload list, diff after; writes `P <image> <rva> <hex>` (two bytes of context for the opcode) and `R <image> <offset> <hex>` (region). Development path (translator), labelled as such. |
| Verify | `codehooks.c` | `VXRT_CODE_VERIFY=<file>`: after the preload list the live bytes must equal the capture, else exit 3. This is the determinism acceptance test. |
| Patch the translation | `tools/vxrt_aot.c` | `VXRT_AOT_PATCHES=<file>`: applies the `P` lines to the image before decoding. The module keeps the file's own hash; the runtime maps the unpatched file and SKSE writes the same bytes at start-up. |
| Hooks module | `tools/skse_hooks_pe.py` | Wraps the `R` bytes as a minimal PE DLL at a fixed base and lists the stubs' entry points (targets of the captured E8/E9) as roots. |
| Pipeline | `tools/skyrim_aot_pipeline.py` | module entries accept `patches` (exe or DLL) and `roots` (DLL); part of the cache key; 20 existing pipeline tests pass. |
| Fixture | `VXRuntime/tests/skse/`, `tests/skse_fixture_check.py`, `make skse-fixture-check` | A host exe with two hook sites and an extension DLL that patches them from `DllMain` (a `call` to a `jmp [rip]` trampoline stub; a `jmp` to a generated stub), at arena bases `0x306/7/8000000`. |

Fixture results (subject: owned fixture, Mac, `make -C VXRuntime skse-fixture-check`, exit 0):
1. Plain run, no preload: `not hooked (work=11 work2=5)`, exit 1.
2. Dev capture (translator): `hooks fired (work=110 work2=1005)`; capture has 2 code runs (13 bytes) and 64 KB of region.
3. **Strict AOT, patched modules, preload, region, verify**: hooks fire, `3858 entries into recompiled code ... 0 fallbacks to the translator`, `verify: 3 entries, 0 differ`, exit 0.
4. Control: same, host module built without the patches: `not hooked`, exit 1 (this is the problem the scheme solves).
5. Control: tampered capture: `differs from the capture`, exit 3.

## 5. State of M1 on the real game

Done: SKSE VR 2.0.12 downloaded and recorded; **its core DLL translates**: `vxrt-aot gen` at base `0x306000000`: 59,672 blocks, 8 blocks refused (decode or instruction; not yet examined), 0.25 s, module `sksevr_1_4_15.dll-232ac6d605c44f2a.dylib` (14 MB) built in `build/private/skse-work/aot/`. All 136 kernel32/user32/shell32 imports of the DLL are exported by the runtime (name match; not run).

**Not done (subject: not run).** No real-game capture, no `sksevr.log`, no version in the console. Reason: a game process of another session (`fov-abc`, and a queued `mods` smoke that waits on `vxrt-arm64`) was running for the whole session; the rules forbid starting a game over it, and a capture run uses the game's exe. Nothing was overridden.

Steps to finish M1 (each small; first needs a free machine):
1. Pipeline config for the SKSE set: `sksevr_1_4_15.dll` at `0x306000000`, blank `vxrt_hooks.dll` at `0x307000000` (`skse_hooks_pe.py` without `--capture`), the current exe set otherwise. Put `sksevr_1_4_15.dll` where `VXRT_PRELOAD` can name it (a private path; no `Data/SKSE` needed for the core). `skse.ini` absent.
2. Capture run: `VXRT_AOT_DIR=<modules> VXRT_PRELOAD=<blank hooks>;<sksevr dll> VXRT_EXEC_REGION=vxrt_hooks.dll VXRT_CODE_CAPTURE=<file> VXRT_PRELOAD_EXIT=1` (the exe never starts; the dev engine is allowed to run SKSE's init). Expect about 40 branch sites + 11 stubs; check the count against section 2 and read `sksevr.log` in the run's Documents overlay for "init complete".
3. Build `real/vxrt_hooks.dll` with `--capture --image SkyrimVR.exe=0x308000000 --roots`; add `patches` to the exe entry and `roots` to the hooks entry; rebuild (patched exe module: seconds in gen plus clang).
4. Strict run with `VXRT_CODE_VERIFY`; look for `sksevr.log` "init complete", the SKSE version in the main menu (the `ShowVersion` hook), zero fallbacks.

Known risks for step 2 to 4: SKSE's `DllMain` runs before the exe's CRT initialisation (as on Windows, where the remote thread runs before the entry point); `Hooks_VR` wraps the game's OpenVR interfaces with proxies inside the SKSE DLL (guest code calling our OpenVR exports: needs a guest-ABI check with xrizer, per `AGENTS.md`); the 8 refused blocks; arena room for plugin DLLs above the exe (`0x308000000` + image size, arena ends `0x320000000`).

## 6. Milestones

| | State |
| --- | --- |
| M1 SKSE core loads, `sksevr.log` "init complete", version shown | mechanism proven on fixture; core DLL translates; **real run pending** (section 5) |
| M2 plugin without hooks loads | needs `Data/SKSE/Plugins` visible through the asset overlay, plugin DLL in the pipeline at its own base; `LoadLibrary` by hash already finds its module |
| M3 HIGGS then PLANCK | same capture with their stubs (they allocate through SKSE's trampoline managers, so they land in the region); HIGGS needs its ESP active (mods plan M0) |
