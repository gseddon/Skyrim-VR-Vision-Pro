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

## 4a. Late code writes (plugins that hook after DllMain)

HIGGS, PLANCK and others install hooks in their messaging handlers (kPostLoad, kPostPostLoad, kDataLoaded, after the main menu), on first use or on a config reload. A capture that ends before the exe's entry point misses them. The design handles this in four parts (implemented in `VXRuntime/src/codehooks.c`; fixture-verified, section 4):

1. **The capture can be taken late.** `VXRT_CODE_CAPTURE_AT=<seconds>` writes the capture that many seconds after the preload list, from the development run that goes on to the main menu and past kDataLoaded (`VXRT_CODE_CAPTURE_EXIT=1` ends it). The snapshot is taken before the preload, so every executable-section diff, region byte and data pointer into the region written up to then is in it. For a plugin set the capture run must reach the code that writes (load a save, open the config menu); `--helgen` style scripted input can drive it. Writes triggered only by rare events stay unknown until the watcher below catches them.
2. **Verify is time-aware.** With `VXRT_CODE_WATCH=<ms>` the preload-time check says: what the preload wrote must equal the capture, and a site not yet written must still hold the original. Then a thread compares every executable section of the images loaded before the preload, and the region, with the post-preload state every `<ms>`. A byte that is neither the baseline nor the capture's is a **late code write outside the capture**: it is logged with image, RVA and the three bytes ("LATE CODE WRITE not in the capture ..."), and under `VXRT_AOT_STRICT` the run stops with exit 3. A new executable allocation beyond the captured region stops it too. A missing capture is therefore loud, never silent (what is not watched: executable memory outside the images and the region, e.g. an allocation that the region service refused and the ordinary allocator served; and writes that are made and undone between two ticks).
3. **Why this is enough for correctness.** The AOT module is made from the capture's final state, so the translated code already contains every captured hook from the first instruction; a hook that the plugin installs "late" only changes the bytes in memory later, which the AOT code never reads. The one semantic difference is a hook that exists in the module before the plugin installs it (the module jumps to the hook early). In the fixture this window is harmless; for a plugin whose hook depends on state set up in its handler it could matter and is a risk to test per plugin, not assumed away.
4. **What the watcher cannot do.** It detects, it does not install: the fix for a reported write is to capture again with a longer or different run and rebuild. Hooks written by self-modifying plugin code into pages the plugin allocates itself (not through SKSE's trampolines) would also need that allocation in the region; the region service serves every executable `VirtualAlloc` in order, so the capture sees them.

Fixture evidence (`make -C VXRuntime skse-fixture-check`): the extension DLL installs its second hook from an exported function the host calls 2.5 s after start (a stand-in for a kDataLoaded handler). Capture at preload holds one site; capture `AT=3` holds both. Strict AOT with the full capture and the watcher: both hooks fire, 0 fallbacks, no LATE message. Strict AOT with the early capture: the late write is reported with its address (`skse_fixture_host.exe +0x1055`) and the run stops, exit 3. Real game, SKSE core only (subject: actual game, Mac, dev host; not a playability claim): a capture 100 s into the run is byte-identical in its code and region lines to the preload-time capture, so the core has no late patches up to the main menu in that run.

## 5. M1 on the real game: PASS for the load, the patch set and the game-driven hooks (subject: actual Skyrim VR 1.4.15 prepared exe, Mac, strict AOT, dev-keyboard harness; not a playability claim)

Inputs: `SkyrimVR.exe` prepared sha256 `8daf0519...46d4`; `sksevr_1_4_15.dll` sha256 `633be638...3463`, AOT base `0x306000000`; hooks module `vxrt_hooks.dll` at `0x305800000` (it must lie **below** the SKSE DLL: SKSE's second trampoline searches downward from its own DLL, the first from the exe); exe rebased to `0x308000000`. Runtime and compiler from this branch (`play-host` build); no `skse.ini`, no plugins.

1. **Capture** (dev run, AOT modules for everything else, no game started, `VXRT_PRELOAD_EXIT=1`): `sksevr.log` reaches "init complete" with version 2.0.12, image base `0x308000000`; 39 code runs (410 bytes with context) in the exe, 131,072 bytes of region (two 64 KB allocations: branch trampoline, local code buffer), 3 pointers into the region held in SKSE's data. `capture-late.txt` taken 100 s into a running game is byte-identical in its code and region lines.
2. **Modules**: the exe rebuilt with the 39 patches (new cache key), the hooks module with 48 stub roots from branch targets, trampoline slots, data pointers and region-internal pointers, and 12 roots in the exe for the places stubs return to (the bytes after a replaced instruction, which nothing else reaches: the first full run stopped on one, `0x308dc7987`, with "no recompiled code"; the rest were the unrooted stub of a pointer held in SKSE data).
3. **Strict AOT game run, `play-002122`** (120 s, `VXRT_AOT_STRICT=1`, `VXRT_CODE_VERIFY`, `VXRT_CODE_WATCH=1000`): `verify`, then "watching 12 executable sections and the region"; no LATE CODE WRITE; `176,160,769 entries into recompiled code ... 0 fallbacks to the translator`; ended by the harness at its 120 s limit. `sksevr.log`: `init complete`, `hooked dinput` (the DirectInput IAT hook ran when the game created its input), `dispatch message (6)` (kMessage_InputLoaded) and `(8)` (kMessage_DataLoaded). Messages 6 and 8 are sent from SKSE's hooks in the exe, so patched sites in translated code fired in the real game. An earlier run, `play-001051` (150 s), had the same result.
4. **The 8 refused blocks** of the SKSE core DLL: all eight are 16-byte-aligned "roots" the generator guessed, landing inside instructions or on data (`0x80800` is the constant `3FFFFFFFFFFFFFFF`, `0xb7400` and `0x7070` are inside code or padding); none is a function entry. Harmless; no run reached them.

**Not verified:** the SKSE version string drawn in the main menu (`ShowVersion` hook; needs a screenshot of the headset-less window, which I could not take); that Papyrus natives work (no script ran); the guest ABI of `Hooks_VR`'s wrapper around the game's OpenVR interfaces (`VR_GetGenericInterface` was not observed being called in the log; the IAT hook is installed only if `bActionBindings` is set, which it is not); any plugin; the 40 sites against the source's own count (source reading: 38 branches + 2 six-byte forms + 11 stubs; the capture has 39 code runs, consistent but not site-by-site compared); visionOS/simulator/headset.

## 6. Milestones

| | State |
| --- | --- |
| M1 SKSE core loads, `sksevr.log` "init complete", version shown | **load, patch capture, patched strict AOT run and game-driven hooks verified on the real game (section 5)**; menu version string not yet observed |
| M2 plugin without hooks loads | needs `Data/SKSE/Plugins` visible through the asset overlay, plugin DLL in the pipeline at its own base; `LoadLibrary` by hash already finds its module |
| M3 HIGGS then PLANCK | same capture with their stubs (they allocate through SKSE's trampoline managers, so they land in the region); HIGGS needs its ESP active (mods plan M0) |
