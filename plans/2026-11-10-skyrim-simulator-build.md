# Plan: Skyrim AOT modules for the visionOS simulator, and what follows

Date: 10 November 2026. Status: pipeline code written and dry-run only; **nothing here has been built, installed or run** (a performance measurement was using the Mac, so no compile, AOT generation, xcodebuild or simulator was started). Every number marked *(estimate)* or *(unverified)* is not a measurement of the xros build. Parent: [AVP Play backend plan](2026-11-09-avp-play-backend.md), Prerequisites 1 to 3 (milestone 2 needs them).

Subject of the evidence below: static analysis of the repository, the Mac pipeline's recorded output, and one `--dry-run` (reads and hashes inputs, writes nothing).

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

The config pins the runtime `VXRuntime/build/terra-stage2/vxrt-arm64` at a hash that no longer matches the file (the dry-run failed with `SHA-256 mismatch` until I used a copy with the current hash). The runtime is not used by module generation. Re-pin deliberately, in a private copy first:

```sh
M=/Users/gseddon/git/Skyrim-VR-Vision-Pro            # main checkout (private inputs live there)
SHA=6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
RT=$(shasum -a 256 $M/VXRuntime/build/terra-stage2/vxrt-arm64 | cut -d' ' -f1)
sed "s/6cec0bf88b0110d0b78fa1ffd9adffe6e444d0071ffadd5087e646256c1bdfb0/$RT/" tools/skyrim_aot_skyrimvr.json \
  > $M/build/private/skyrim-aot-skyrimvr-xros.json     # git-ignored copy; commit a re-pin only after review
OUT=$M/build/worktrees/terra-skyrim-aot/build/private/skyrimvr/$SHA/aot-xrsimulator1
CACHE=$M/build/private/skyrim-aot-cache-xrsimulator

python3 tools/skyrim_aot_pipeline.py --config $M/build/private/skyrim-aot-skyrimvr-xros.json \
  --target xrsimulator --dry-run --out $OUT                                   # prints the plan, writes nothing
python3 tools/skyrim_aot_pipeline.py --config $M/build/private/skyrim-aot-skyrimvr-xros.json \
  --target xrsimulator --build --out $OUT --cache $CACHE
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

- [ ] Run the first xrsimulator build above; record the dry-run and build `result.json`, the framework list, `bases.txt`, sizes, and compile/link time.
- [ ] Re-pin or replace the stale runtime hash in `tools/skyrim_aot_skyrimvr.json` (reviewed change).
- [ ] Owned test first: `make -C VXRuntime XROS_SDK=xrsimulator xros-aot-tests` run of `arena_hello`/`fwarena_suite` on the simulator, to confirm the simulator honours the arena at `0x7000000000` (proven on the headset in `VISIONOS_PORT.md`; on the simulator the notes only record `0xf00000000`; unverified).
- [ ] `-game skyrimvr` in `VXRuntime/xros/app/Sources/main.m` `game_start` (today only `cyberpunk`; `main.m:263`): exe `SkyrimVR.exe` (the prepared one, sha `8daf0519...`: module names carry a hash of the file, so the container needs byte-identical content), cwd the game folder, no Steam variables, `VXRT_OVERLAY`, `VXRT_DLL_PATH` for the redist DLLs (msvcp140, d3dx9_42, X3DAudio1_7).
- [ ] Configurable root: `runtime_thread` fixes `root = <Documents>/root` (main.m ~line 313); take it, and the save/overlay location, from launch arguments, an environment variable or Info.plist (AVP Play Prerequisite 3).
- [ ] xrizer outside fixture mode: the real xrizer path in the app is behind `XRIZER_XROS_FIXTURE` (`VXImmersive.swift`; Makefile lines ~60 to 62, 304) and the fixture build refuses anything but `XROS_SDK=xrsimulator` with `XROS_CODE_SIGNING=NO` and links only the fixture guest. Needs a normal (non-fixture) app configuration that links `libxrizer.a` / `libklepton.a` and loads the Skyrim modules.
- [ ] GCKeyboard to input host v3: `xros_ui.m` already turns GCKeyboard keys into WM_KEYDOWN/WM_CHAR; Skyrim VR reads controllers through OpenVR, so route keyboard/pad state into the input host v3 as scripted controller input for the simulator (the Mac used `VXRT_XINPUT_SCRIPT`; it needs a simulator-side equivalent to get past "Press Any Button").
- [ ] Copy game data into the simulator container (`xcrun simctl get_app_container <udid> <bundle id> data`, `Documents/root/...`): `Data/`, `.ini` files, media. Never from the Steam install in place; use a private copy, keep it out of git.
- [ ] Strict-AOT run in the simulator: zero fallback and real AOT entries counters present (a missing counter is a failure, not zero), world in both eyes. Label it simulator, not headset.

## Open risks

- **Simulator Metal limits (known from `VISIONOS_PORT.md`, lines 60 to 80)**: the simulator GPU reports no Metal 3, no BC textures, no argument-buffer tier 2; D3D11 stopped on "linear textures need private buffers" and the d3d12 PSO on "no dynamic vertex strides". Skyrim uses BC-compressed textures through D3D11, so the renderer may stop or look wrong in the simulator even with correct modules. That would block "the world in both eyes" there and force the device. Unverified for Skyrim.
- **Framework count and size**: ~17 frameworks, the biggest ~35 MB; the scale test in `VISIONOS_PORT.md` (two parts, 147 + 145 MB, `dlopen` 15.6 ms) suggests this is well inside limits, on the headset. Simulator and App Store/TestFlight/AVP Play install limits unmeasured. The device build must also fit the paid-team provisioning.
- **Signing**: `embed_aot_frameworks.sh` signs each with the app's identity (ad hoc with `XROS_CODE_SIGNING=NO`); the device needs the team identity and the Info.plist `CFBundleSupportedPlatforms` of `XROS` (the pipeline writes it for `--target xros`; nothing for `xros` was built or installed).
- **Arena reservation on the simulator**: reservation happens in the app's first constructor; whether `0x7000000000` is free in a simulator process was not checked.
- **Device build is a second build**: `--target xros` shares the code path but has a different triple, SDK and cache key; it needs its own run and a device size/signing measurement (AVP Play Prerequisite 2).
- **Stale pin**: the runtime hash in the committed config is already wrong; any other tool using that config will also refuse.
