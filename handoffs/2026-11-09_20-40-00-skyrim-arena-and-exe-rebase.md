# Handoff: AOT arena below the GPU carveouts, exe rebased into the arena (2026-11-09)

Branch `codex/standalone-import`, HEAD `24b5e23` (pushed). Evidence level throughout: **actual Skyrim, offscreen dev host
(`--dev-synthetic-stage`), strict AOT, zero fallback, macOS arm64**. Nothing here is headset, tracking or playability
evidence, and nothing was built or run for visionOS.

## Task status

| Item | State |
|---|---|
| Start-up collisions (arena, exe range) | **Fixed on the Mac**: 0 arena collisions in 180 boots, 0 exe-range collisions in 300 starts (control: 12/300), 0 crashes in 410 boots |
| Module sets for the new layout | Built, private, not in git (`aot-splits4a` is the one to use) |
| Game after the changes | Boots to the SKYRIM title and past it (probe 202); same picture as before: title goes at ~270 s, **3D scene still hidden** |
| visionOS | **Unverified**: no restart exists there; a collision-free address has to be measured on device/simulator (needs separate authorization) |
| Exe module regeneration | Works as a scratch script; not in the pipeline yet (next steps) |

## Read first

- Plan and execution log: `plans/2026-11-08-standalone-skyrim-terra-continuation.md` (entries 15:55, 17:25, 20:20 UTC are this work).
- `AGENTS.md` (policy changed this session, see below), `VXRuntime/RECOMP.md` (arena note updated), `THIRD_PARTY_NOTICES.md`.
- Earlier handoffs: `handoffs/2026-11-08_22-58-00-skyrim-ini-archives.md` and the ones before it.
- Transcript of this session: agent `3f687668-8798-478a-8a33-6be552b93493`.

## What was done, in order (commits)

1. `043ac07`, `e8b5690` (earlier): reserve the exe's preferred range at the start of `main`; hold the arena and the exe range from process start with a restart (`execv`, up to 5, `VXRT_AOT_RESTARTS`) as the fallback.
2. `44f7a0f`: Rosetta build compiles again (`vx_low` identity inlines in `src/vx.h`); D3D12 queues no longer put on the native texture list (kind overlap: `K12_QUEUE` == `K_TEXTURE` == 2; `d3d_object.native_listed`, `d3d_alloc_plain`).
3. Reserved Mach-O zero-fill segments (`__VXIMG`/`__VXARN`, `-segaddr`) were tried and **reverted** in `d048e78`: 5 crashes in 450 boots (NULL call inside AppKit first-window setup) against 0 in 540 without. `d048e78` also adds the diagnostic that reports a NULL call from the runtime (`arm64.c` `on_fault`: x0..x3 and the frames' library+offset) instead of the old "executing 0".
4. `d558660`: **arena moved `0xf00000000` -> `0x300000000`** (512 MB; `translator/aot.c` `xa_arena_base`, macOS only; the `VX_XROS` branch is unchanged). `VXRT_AOT_ARENA=f00000000` makes old module sets work. `libvxrt_vm.dylib`'s 16 GB heap `mmap` (`src/vm_hooks.c` `heap_init`) is hinted to `0x320000000` so the kernel does not put it in the arena. `xa_reserve` now logs what holds the range (prot, user_tag, share mode, file).
5. `55902c4`: `AGENTS.md` authorizes Wine (LGPL-2.1+) reuse for a named purpose, ported code in its own marked files with notices; ReactOS stays off limits. **Nothing from Wine is in the tree.** I read `loader/preloader_mac.c`, `loader/Makefile.in`, `configure.ac` at Wine `78e52205d9b9` (fetched to `/tmp` only).
6. `3643618`: **exe rebased into the arena at `0x308000000`**: `reserve_main_image` (`src/loader.c`) skips reserving the preferred range when `xa_module_base` finds a module for the program made for another base inside the arena (`load_pe` already mapped such an image at the module's base and relocated it).
7. `24b5e23`: plan entry for probe 202.

## Key learnings

- **Why `0xf00000000` was taken (~1/3 of starts):** macOS arm64 gives every process two ~12 GB "GPU Carveout (reserved)" ranges plus 1 GB at `0xfc0000000` at exec, before dyld runs. Over 4000 samples of a plain C program they start at or above `0x400000000` and end at or below `0xfbe000000` (12.7% of starts cover `0xf00000000`; none cover `0x140000000`). `vmmap` names them. Below `0x400000000` and past the shared cache (`0x180000000-0x1ea000000`, `0x1fc000000-0x294000000`) nothing is placed.
- **Second cause found by testing the new address:** `libvxrt_vm`'s unhinted 16 GB `mmap` lands in the lowest hole that fits, which is `0x300000000` about every other start (arena taken in 14 of 30 boots with only the address changed). Fixed by the hint.
- **Why `0x140000000` was taken (~4%):** libSystem's `__malloc_init` puts one 16 KB `MALLOC metadata` page (user_tag 1) at a random address in about `0x118600000-0x15fe00000`, before any constructor. A plain 10-line C program (nothing of ours linked) had it inside the exe's 60 MB range in 9 of 200 runs. Independent of our code; a constructor cannot beat it. Argon (`gemini-4-argon-medium`, agent `fcc13bbb-6284-4c79-a396-0e69332171ef`) reached the same conclusion; I re-verified it.
- **Wine's reservation trick does not port to arm64:** it is a zero-fill segment with `-no_pie -image_base 0x200000000`, x86_64-only (`wine_use_preloader=no` for other hosts). This arm64 linker (`ld-1230.1`) prints "`-no_pie` ignored" and "`-image_base` will be ignored": segments always slide. Wine's `configure.ac` also says the loader "needs to be an `LC_UNIXTHREAD` binary to avoid AppKit/Core Animation problems" when the preloader is used, an unconfirmed hint at what my segments crashed on. For arm64 the answer is relocation (what Windows does), i.e. rebasing the exe.
- **What rebasing means here:** the PE has a `.reloc` table; loading at another base adds the delta to each absolute address. The AOT modules are compiled for a specific base, so the exe modules were regenerated with `VXRT_AOT_BASE` (`tools/vxrt_aot.c` relocates the image copy it translates). No machine code is generated or patched at run time, so no JIT issue.
- **Split profile addresses are absolute** (`VXRT_AOT_SPLITS`, one hex address per line, written by the runtime and read by `vxrt-aot`). A rebased generation needs them shifted by `newbase - 0x140000000`. Same for `VXRT_AOT_ROOTS` (empty today).
- **The loader's restart cannot be used on visionOS** (`!VX_XROS` in `main`; `execv`/`posix_spawn` are not available), and the system maps `0x2e4000000-0xfc0000000` in every visionOS app (`VISIONOS_PORT.md`). The Mac numbers do not carry over; visionOS keeps its own arena registry (`XROS_ARENA`, default still `0xf00000000`, built per app).
- **Harness quirks:** `--seconds` is capped at 300. The game reads the scripted pad only after it has started polling: presses at 45/60/75 s (probe 201) were never seen; repeated presses from 20 s (probe 202) were (64 "XInput script: pressed" lines). The script holds at most 64 entries. Eye dumps are every 600 frames by default (`VXRT_XRIZER_DEV_DUMP_EVERY`, minimum 30; not on the `--diag-env` allowlist). No PIL; the PNG converter used for the sheet is ~10 lines of `zlib`/`struct` (in the session transcript, search `frame600`).
- `make -C VXRuntime aot-suite` is green (exit 0, 0 fallbacks), run after the arena move and after the loader change. `check-arm64` was not run in full. Known failures unchanged: `build/d3d12.exe` timestamp check, `tests/present_check.py`.

## Artifacts (private, git-ignored, under `build/worktrees/terra-skyrim-aot/build/private/skyrimvr/6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971/`)

| Directory | Contents |
|---|---|
| `aot-splits2` | the old set (links); exe at `0x140000000`, DLLs at `0xf0…`; needs `VXRT_AOT_ARENA=f00000000`; untouched |
| `aot-arena3` | six regenerated DLL modules for the new arena: binkw64 `0x300000000`, openvr_api `0x301000000`, steam_api64 `0x302000000`, msvcp140 `0x303000000`, d3dx9_42 `0x304000000`, X3DAudio1_7 `0x305000000` |
| `exe-arena`, `exe-ctl` | 11 exe parts at `0x308000000` and at `0x140000000` (control); same compiler (HEAD `vxrt-aot`), 16 MB parts, 1022 splits |
| `aot-splits4a` | **use this**: `aot-arena3` + `exe-arena` (links); exe at `0x308000000` |
| `aot-splits4c` | control: `aot-arena3` + `exe-ctl` |
| `aot-splits3` | `aot-arena3` + the old `aot-splits2` exe parts (exe at `0x140000000`) |

Regeneration times (10 performance cores, `tools/aot_build.sh`, one at a time): binkw64 0.6 s, openvr_api 0.8 s, steam_api64 0.3 s, msvcp140 0.7 s, d3dx9_42 3.8 s, X3DAudio1_7 0.2 s; the exe 6 s to generate plus 5 s to assemble and link.

Probe output: `build/worktrees/terra-skyrim-aot/build/xrizer-game-202` (the 300 s run to the title, `eyes/frame*_eye*.rgba` 1024x1024 RGBA), `-201`, `-96c/-96a/-97c/-97a/-98c/-98a` (60 s control vs rebased), `-950`. The eye-0 contact sheet and last frame are in `/tmp/skyrim_now/` (volatile).

Scratch scripts (hard-coded paths, not product code) are copied to `handoffs/scratch-2026-11-09/`; originals were in `/tmp`:
- `hostbuild2.sh`: builds `VXRuntime/build/terra-stage2/vxrt-arm64` (the dev host with xrizer). After a change to `src/vm_hooks.c`: `make -C VXRuntime build/libvxrt_vm.dylib && cp VXRuntime/build/libvxrt_vm.dylib VXRuntime/build/terra-stage2/`.
- `fast.sh <tag> <runs>`: direct boots from the same environment as the harness, working directory the game dir, stops at `SetFocus`. Env: `AOTD` (module dir name), `WAIT` (boot timeout in 0.1 s steps, 40 default, use 150 for the 11-part exe), `EXTRA` (extra `NAME=VALUE` words), `STOP=1`. Prints `exe range taken`, `arena taken`, `CRASH`, saves those logs to `/tmp/fast_<tag>_*.log`. Refuses with BUSY when any `vxrt-arm64` runs.
- `early.sh <n>`: starts the game, kills it after 0.6 s, counts what `main` decided about the exe's range (the cheap collision counter: 300 starts in ~3 min).
- `probe.sh <n> <secs> <trigger|-> [harness flags]`: the harness (`tools/vxrt_native_startup.py`) with the dev host; `STAGE=terra-stage2 AOTD=aot-splits4a`. Probe 202 was `sh probe.sh 202 300 - --xinput-repeat A@20-272/4:0.3 --dump-eyes`. Start it detached (it blocks on `wait`).
- `exegen.sh <outdir> <base-hex|->`: **the exe module regeneration** (below).

## The exe regeneration script (`exegen.sh`), and how to grow it

What it does: HEAD's `VXRuntime/build/vxrt-aot gen prepared/SkyrimVR.exe` with `VXRT_AOT_PART_MB=16`, `VXRT_AOT_SPLITS=<profile>`, `VXRT_AOT_ROOTS=<empty>` and, for a rebase, `VXRT_AOT_BASE=<hex>`; the split profile (`build/worktrees/terra-skyrim-aot/build/aot-fix/splits.txt`, 1022 addresses) is shifted by the base delta; the 11 parts are assembled and linked in parallel into `<outdir>/dylibs/skyrimvr.exe-c48518d5fe0b9c54.p<k>.dylib`. The module name is `<stem>-<hash of the file bytes>`, so two bases cannot share a directory.

Why it is worth keeping: it is the only recipe for the exe set the game actually runs, and it is cheap (11 s). `tools/skyrim_aot_pipeline.py` cannot build this set today: it has `exe_base` and per-DLL `base`, but no split profile, part size or roots, so it would produce different modules. Suggested expansion: an `exe` block in the pipeline config (`base`, `part_mb`, `splits`, `roots`) with the shift done by the pipeline and the cache key including them; then the profile loop that `build/worktrees/terra-skyrim-aot/build/aot-fix/iterate.sh` does by hand (run, take the strict-AOT miss addresses into roots and the runtime's new ordered-access addresses into splits, regenerate, run again).

Caveats before relying on a rebuilt set:
- HEAD's compiler is not byte-identical to the one that built `aot-splits2` (`aot-fix/vxrt-aot-fix`; plan 08:20 entry: 1 block and 1 refused block differ) and `splits.txt` grew from 996 (`gen.log`) to 1022 addresses afterwards. The control `exe-ctl` (same compiler and profile at the old base) is the baseline for A/B, not `aot-splits2`.
- The pipeline's config for Skyrim does not exist in the repo or the worktree; `aot-splits2` was assembled by hand from symlinks to builds in other checkouts. Pin the compiler SHA and the splits file before calling any set reproducible.

## Next steps

1. Fold `exegen.sh` into the pipeline (config block above), pin compiler and profile, and write the Skyrim config. Update the `base` values of any config to the new arena (`0x300000000`...; exe `0x308000000`).
2. Make `aot-splits4a` the default module set for the harness and probes (`probe.sh` and the harness still default to `aot-splits2`, which needs `VXRT_AOT_ARENA=f00000000`).
3. The open game defects, unchanged by this work: why the title card lasts ~215-270 s and what covers the 3D scene afterwards (plan entries 08:30 and later: the last UI pass blends an opaque black layer over a correct Helgen scene); real xWMA decoding.
4. Run `make -C VXRuntime check-arm64` in full; fix or record the `d3d12.exe` timestamp check and `present_check.py` failures.
5. visionOS (needs the user's authorization for device or simulator work): measure a collision-free arena address for the exe and DLLs (`XROS_ARENA`, `vxrt_aot_arena_base`), since the restart is unavailable there; rebuild `aot.c`/`loader.c` for `VX_XROS` (not built this session); only then consider the physical-headset step.

## Risks and open questions

- Rebasing changes the exe's image base as the guest sees it (`GetModuleHandle(NULL)`, PEB). Nothing hardcodes `0x140000000` that was found, but only 3 x 60 s harness runs per set and 410 boots were compared, no long-run or scene comparison.
- One control harness run (`96c`) submitted no frames in 60 s; not reproduced in two later runs, unexplained (the machine had just run 300 short starts).
- The first 100-boot batch on the rebased set saw 3 exe-range collisions; the build had not yet got its final form and later batches saw none. Treat the 300-start count (0 vs 12) as the evidence.
- The AppKit crash mechanism with the reserved segments is still unknown (irrelevant while they stay reverted).
- The exe's range is no longer reserved when a rebased module exists, so the 4% restart no longer applies there; the arena itself can still be taken by a library ASLR places at `0x300000000` (not seen in 180 boots; the restart still covers it).
- Licence: `AGENTS.md` now permits Wine reuse for a named purpose; any future port needs notices in `THIRD_PARTY_NOTICES.md` and a fresh say-so for a new purpose.
