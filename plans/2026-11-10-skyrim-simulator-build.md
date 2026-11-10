# Plan: Skyrim AOT modules for the visionOS simulator, and what follows

Date: 10 November 2026. Status: pipeline code written and dry-run only; **nothing here has been built, installed or run** (a performance measurement was using the Mac, so no compile, AOT generation, xcodebuild or simulator was started). Every number marked *(estimate)* or *(unverified)* is not a measurement of the xros build. Parent: [AVP Play backend plan](2026-11-09-avp-play-backend.md), Prerequisites 1 to 3 (milestone 2 needs them).

Subject of the evidence below: static analysis of the repository, the Mac pipeline's recorded output, and one `--dry-run` (reads and hashes inputs, writes nothing).

## Goal: start-up only on the simulator (user decision, 2026-11-10)

The simulator test is for **start-up only**. Rendering waits for the headset. A BC texture decoder is **out of scope** by this decision; so is any claim about image correctness, tracking or playability.

Success (all observed in `Documents/host_log.jsonl` and `Documents/vxrt.log` of the simulator run; subject: simulator, actual game, start-up only):
1. The app launches with the Skyrim frameworks embedded (`embed_aot_frameworks: N frameworks signed`).
2. The arena reserves at `0x7000000000` (`reserved:1` in the host log).
3. The AOT registry loads all 7 modules (a `aot: ... framework VXA_...: opened` line per part and an `aot: <name>: ... for the image at 0x70...` line per module; the exe at `0x7000000000`).
4. Strict AOT reports `entries > 0` and `0 fallbacks to the translator` in the `aot:` summary line (a missing summary is a failure, not zero).
5. Skyrim reaches D3D11 device creation (`Direct3D` device log lines).
6. Skyrim reaches xrizer / OpenVR initialization. **This needs the xrizer plumbing below, which is not written.** Until then, 6 reads "reaches `VR_Init` in the translated `openvr_api.dll` and fails there", recorded as that, not as a pass.

Expected and acceptable stop: the first BC texture creation or another simulator Metal limit (no Metal 3, no argument-buffer tier 2, no dynamic vertex strides, linear-texture rule). The BC case is now a logged refusal: `d3d11.m` `make_mtl_texture`, under `VX_XROS_SIM`, logs `Direct3D: BC_REFUSED: DXGI format N is block-compressed ...` once and returns `E_INVALIDARG` (written, not compiled or run). That stop is **recorded as "stopped at BC_REFUSED", never as a rendering pass**. Any other Metal-limit stop is logged as its own finding.

## Approach

`tools/skyrim_aot_pipeline.py` gets `--target {macos-arm64 (default), xrsimulator, xros}`, `--arena` (default `0x7000000000`), `--arena-mb` (default 1024) and `--dry-run`.

- **The pipeline does the work; it does not call `VXRuntime/tools/xros_aot.sh`.** The script is wrong for this job in four ways: it deletes fixed scratch directories (`build/$SDK/aot`, `aot_fw` or `game_fw`) on every run, so it cannot honour "never touch the existing sets" or run once per module; it uses `build/vxrt-aot`, not the pinned compiler the pipeline records; it has no hashes, cache or manifest; and it cannot pass per-module `VXRT_AOT_PART_MB` / `SPLITS` (they work only as inherited environment for every image). The pipeline instead copies the script's conventions exactly: `xcrun -sdk <sdk> clang -target arm64-apple-xros26.0[-simulator]` (the Makefile's `XROS_TARGET`), `-dynamiclib -install_name @rpath/<fw>.framework/<fw>`, framework name `VXA_` + module file name lowercased with other characters `_` (what `translator/aot.c` `fw_path` opens), the same `Info.plist` byte for byte (`CFBundleSupportedPlatforms` `XRSimulator` or `XROS`), `bases.txt`, and "@auto" packing (SizeOfImage rounded up to 64 KB, in order, from the arena base). A smoke test with a stub compiler and stub `xcrun` produced the expected framework names and plists. It does not show that real clang accepts the command lines (unverified until the first build).
- **Output**: `<out>/game_fw/VXA_*.framework` plus `bases.txt`, hard-linked from a per-target cache `build/private/skyrim-aot-cache-<target>` (never the Mac cache; the pipeline refuses that). `<out>` must be a new directory under the private root, as before. That is exactly the layout `xros/app/embed_aot_frameworks.sh` globs (`$VXRT_LIBDIR/game_fw/VXA_*.framework`). `make xros-aot-tests` only deletes `aot` and `aot_fw`, so `game_fw` survives app builds (from reading the script, unverified).
- **The Mac set is untouched and its behaviour unchanged**: I loaded the old and new pipeline and compared `prepare()` output and every module's cache key for the repo config; both are identical. The Mac key's dictionary has no new entries; the visionOS keys add target, triple, arena and the SDK version.
- **The split profile still applies.** `shifted()` moves every address by (new base minus the image's preferred ImageBase), and `vxrt_aot.c` `split_at(rip)` compares against loaded-base addresses (`im->base + rva`). So the profile keyed at `0x140000000` is correct for any base. The dry-run shows 1006 addresses used by the exe and 16 left out (they belong to binkw64 at the old arena). Caveat: the profile was collected from Mac runs; an ordered access that crosses 16 bytes only on the simulator would not be in it (unverified, and the same ARM64 core family makes it unlikely).
- Because bases are recomputed, the Mac config's `base` values are ignored for visionOS targets (they are still validated).

## Arena fit (dry-run, real inputs)

The Skyrim set is 7 images (exe + 6 DLLs), not the 57 images / 433 MB of the Cyberpunk plan in `VISIONOS_PORT.md`.

| image | size MB | base |
| --- | --- | --- |
| SkyrimVR.exe | 57.2 | 0x7000000000 |
| binkw64.dll | 0.4 | 0x7003930000 |
| openvr_api.dll | 0.6 | 0x70039a0000 |
| steam_api64.dll | 0.2 | 0x7003a40000 |
| msvcp140.dll | 0.5 | 0x7003a80000 |
| d3dx9_42.dll | 2.5 | 0x7003b10000 |
| X3DAudio1_7.dll | 0.0 | 0x7003d90000 |

Total 61.6 MB of the Makefile's 1024 MB arena (962 MB free). The ~370 MB of code is not in the arena; it lives in the frameworks. Any further PE image the game loads (system DLLs the runtime does not provide natively) would be added to the config and packed after these.

## Commands for the first xrsimulator build (do not run while the Mac is being measured)

The runtime pin in the config was stale and has been replaced (see "Runtime pin"); the final command list is at the end of this file and supersedes the sketch here.

```sh
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xrsimulator --dry-run --out $OUT
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xrsimulator --build --out $OUT --cache $CACHE
```

(Pass `--cache` explicitly: the default is under the current checkout's own `build/private`, which for a worktree is deleted with it.) Success looks like `status: built` in `$OUT/result.json` and `$OUT/game_fw/VXA_skyrimvr_exe_<hash>_p0.framework` ... `_p10`, plus six DLL frameworks, about 17 in all *(estimate: the Mac set has 11 exe parts + 6 DLL dylibs from the same compiler and `part_mb: 16`; the code is the same ARM64 but rebased, so the count should match)*.

Then link the result into the app's library directory and build (also not now):

```sh
ln -sfn $OUT/game_fw $M/VXRuntime/build/xrsimulator/game_fw
make -C VXRuntime XROS_SDK=xrsimulator XROS_CODE_SIGNING=NO xros-app      # embeds and ad-hoc signs every VXA_*.framework
```

- **Disk** *(estimate)*: cache 370 MB (the Mac set is 369 MB; same code size), `game_fw` hard links 0 MB extra, app bundle +370 MB, simulator install another copy. The pipeline's per-module `.s` text for the exe (32,163,430 ARM64 words, from the Mac log) is transient and deleted per module; I did not measure its size (expect on the order of 1 GB or more of free space during the exe module).
- **Time** *(estimate)*: the Mac run (aot-pipeline5, jobs 10, all 7 modules) took about 17 s end to end from log and cache timestamps (exe: `vxrt-aot gen` 5.43 s, module done after ~11 s). Expect 20 to 60 s for xrsimulator (same assembler work through `xcrun`); the signing of ~17 frameworks and `xcodebuild` time are not estimated. A concurrent measurement will slow it, which is why it waits.

## What remains after the modules

- [x] Re-pin the stale runtime in `tools/skyrim_aot_skyrimvr.json` (done 2026-11-10, see "Runtime pin"). Not yet used by a build.
- [ ] Run the first xrsimulator build (commands at the end of this file); record the dry-run and build `result.json`, the framework list, `bases.txt`, sizes, and compile/link time.
- [ ] Owned test first: `make -C VXRuntime XROS_SDK=xrsimulator xros-aot-tests` run of `arena_hello`/`fwarena_suite` on the simulator, to confirm the simulator honours the arena at `0x7000000000` (proven on the headset in `VISIONOS_PORT.md`; on the simulator the notes only record `0xf00000000`; unverified).
- [x] (drafted, uncompiled, unrun) `-game skyrimvr` in `main.m` `game_start` -> `skyrimvr_start`: only with that argument; `VXRT_SKYRIM_DIR` (default `<root>/SkyrimVR`), `VXRT_SKYRIM_EXE` (default `<dir>/SkyrimVR.exe`; must be the prepared exe, sha `8daf0519...`, because module names carry a hash of the file), cwd the game folder, Steam variables cleared, `VXRT_NO_WINE=1`, `VXRT_OVERLAY=<dir>:<root>/overlay_skyrimvr`, `VXRT_DLL_PATH=bundle/redist` when present (msvcp140, d3dx9_42, X3DAudio1_7 must be in the game folder or there).
- [x] (drafted, uncompiled, unrun) Configurable root: `VXRT_GAME_ROOT` overrides `<Documents>/root` for every game; unset = unchanged. Info.plist/launch-argument forms are left for AVP Play Prerequisite 3.
- [ ] Review the draft with a compile (the first build): `main.m` and `d3d11.m` have never been compiled.
- [ ] xrizer outside fixture mode (**not started; larger than a minimal change, so only described**). The path is compile-time `XRIZER_XROS_FIXTURE` / `VXRT_XRIZER_XROS_FIXTURE` in four places: `loader.c` (~24-28 includes, ~1663-1688 registers xrizer's OpenVR exports as `openvr_api.dll` only for the fixture, after `vx_xros_fixture_wait_ready()`), `native_vr_present.m` (4 `#ifdef` blocks), `VXImmersive.swift` (7 `#if`, lines 27-335) and the Makefile (fixture flags: bundle id, `-force_load` of `libvxrt.a`, `libaot.a`, `libklepton.a`, `libxrizer.a`, only for `XROS_SDK=xrsimulator` and `XROS_CODE_SIGNING=NO`, with `XROS_AOT_OUTPUT_ROOT` scratch). Needed: (a) a runtime opt-in (an env/launch flag, e.g. `VXRT_XRIZER_XROS=1`) instead of the compile-time fixture switch in `loader.c`, still failing closed when compositor geometry is unavailable; (b) the fixture-only audit exports stay fixture-only; (c) the Swift side feeds the real compositor surface/pose for a non-fixture game; (d) a Makefile variable that adds the xrizer/klepton static libs and `-licucore -lz` to the normal app without the fixture bundle and without replacing `xros-aot-tests`' bundle, so `libaot.a` plus `game_fw` both link. Decide whether the fixture and the game share one app build before writing it.
- [ ] BC texture decoder: **removed from scope** (user decision 2026-11-10). The simulator refuses BC textures explicitly (`BC_REFUSED`); the headset has native BC.
- [ ] GCKeyboard to input host v3: `xros_ui.m` already turns GCKeyboard keys into WM_KEYDOWN/WM_CHAR; Skyrim VR reads controllers through OpenVR, so route keyboard/pad state into the input host v3 as scripted controller input for the simulator (the Mac used `VXRT_XINPUT_SCRIPT`; it needs a simulator-side equivalent to get past "Press Any Button").
- [ ] Copy game data into the simulator container (`xcrun simctl get_app_container <udid> <bundle id> data`, `Documents/root/...`): `Data/`, `.ini` files, media. Never from the Steam install in place; use a private copy, keep it out of git.
- [ ] Start-up-only simulator run to the success list above: zero fallback and AOT entry counters present (a missing counter is a failure, not zero). Label it simulator, actual game, start-up only; no world/eye claim (rendering waits for the headset).

## Open risks

- **Simulator Metal limits (known from `VISIONOS_PORT.md`, lines 60 to 80)**: the simulator GPU reports no Metal 3, no BC textures, no argument-buffer tier 2; D3D11 stopped on "linear textures need private buffers" and the d3d12 PSO on "no dynamic vertex strides". With the scope now start-up only, hitting one of these is an expected stop, recorded as such, not a failure of the start-up goal once criteria 1 to 5 are met. Skyrim's first BC texture is refused explicitly (`BC_REFUSED`). Which limit comes first is unknown (unverified).
- **Framework count and size**: ~17 frameworks, the biggest ~35 MB; the scale test in `VISIONOS_PORT.md` (two parts, 147 + 145 MB, `dlopen` 15.6 ms) suggests this is well inside limits, on the headset. Simulator and App Store/TestFlight/AVP Play install limits unmeasured. The device build must also fit the paid-team provisioning.
- **Signing**: `embed_aot_frameworks.sh` signs each with the app's identity (ad hoc with `XROS_CODE_SIGNING=NO`); the device needs the team identity and the Info.plist `CFBundleSupportedPlatforms` of `XROS` (the pipeline writes it for `--target xros`; nothing for `xros` was built or installed).
- **Arena reservation on the simulator**: reservation happens in the app's first constructor; whether `0x7000000000` is free in a simulator process was not checked.
- **Device build is a second build**: `--target xros` shares the code path but has a different triple, SDK and cache key; it needs its own run and a device size/signing measurement (AVP Play Prerequisite 2).
- **Pin drift**: the pinned `play-host` runtime is rebuilt by `tools/play_skyrim_dev.sh`; it will go stale again.

## Runtime pin (2026-11-10)

`tools/skyrim_aot_skyrimvr.json` pinned `VXRuntime/build/terra-stage2/vxrt-arm64` at `6cec0bf8...fdb`. The file at that path is now `8516552e...` (rebuilt 2026-11-09 23:16); the last recorded run with that hash was `xrizer-game-98c` (2026-11-09 19:57). The newest run records (`xrizer-game-1600`, 2026-11-10 01:07) used a third binary, `VXRuntime/build/capture-host/vxrt-arm64` (`c9792064...`), and ended with returncode -9 (the harness's timeout kill, not a pass). `tools/play_skyrim_dev.sh`, the command the user runs, builds and runs `VXRuntime/build/play-host/vxrt-arm64`. So the pinned path was not what the game runs with. Re-pinned to the path the play script uses: `VXRuntime/build/play-host/vxrt-arm64`, sha256 `2d94c0135c0bcde822aece3ea536691d2b2b7b760b9cbc6b9a8f2ea129910fc4` (built 2026-11-10 01:21). Note: the play script rebuilds that binary from the current sources, so the pin goes stale again after a runtime change; module generation does not use the runtime, it is checked only so a probe names the binary it ran. There is no `xrizer-game-1110` result directory.

## Commands to run once the machine is free (not run)

```sh
M=/Users/gseddon/git/Skyrim-VR-Vision-Pro
SHA=6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
OUT=$M/build/worktrees/terra-skyrim-aot/build/private/skyrimvr/$SHA/aot-xrsimulator1
CACHE=$M/build/private/skyrim-aot-cache-xrsimulator
cd <this worktree>
# 1. modules (about a minute, estimate)
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xrsimulator --dry-run --out $OUT
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xrsimulator --build --out $OUT --cache $CACHE
# 2. app (embeds game_fw; ad-hoc signed)
mkdir -p VXRuntime/build/xrsimulator && ln -sfn $OUT/game_fw VXRuntime/build/xrsimulator/game_fw
make -C VXRuntime XROS_SDK=xrsimulator xros-lib
make -C VXRuntime XROS_SDK=xrsimulator XROS_CODE_SIGNING=NO xros-app
# 3. the game folder in the simulator container (private copy; prepared exe, never the Steam install in place)
xcrun simctl boot <udid>; xcrun simctl install <udid> VXRuntime/build/xrsimulator/derived/Build/Products/Debug-xrsimulator/VXRuntimeHost.app
D=$(xcrun simctl get_app_container <udid> marimokodai.VXRuntimeHost data)/Documents/root/SkyrimVR
mkdir -p "$D"   # then copy: Data/ (or only what start-up reads), *.ini, the six DLLs, prepared/SkyrimVR.exe (sha 8daf0519...)
# 4. run, start-up only
SIMCTL_CHILD_VXRT_AOT_STRICT=1 xcrun simctl launch --console-pty <udid> marimokodai.VXRuntimeHost -game skyrimvr
grep -E 'reserved|aot:.*(opened|image at)|fallbacks to the translator|BC_REFUSED|Direct3D|VR_Init' $D/../../vxrt.log
```
The app target, bundle id and simulator app path above come from the Makefile and `project.yml` as read, and the `xros-app` target also runs `xros-aot-tests` (the test programs' modules); both are unverified until run. Until the xrizer plumbing exists, criterion 6 cannot be met.
