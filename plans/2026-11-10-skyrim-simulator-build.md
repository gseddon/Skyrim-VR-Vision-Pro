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

The app build step (superseded by the final command list at the end of this file, which uses `XROS_XRIZER_GAME=1`) links `game_fw` into the build dir and runs `xros-app`; `embed_aot_frameworks.sh` signs each framework (ad hoc with `XROS_CODE_SIGNING=NO`).

- **Disk** *(estimate)*: cache 370 MB (the Mac set is 369 MB; same code size), `game_fw` hard links 0 MB extra, app bundle +370 MB, simulator install another copy. The pipeline's per-module `.s` text for the exe (32,163,430 ARM64 words, from the Mac log) is transient and deleted per module; I did not measure its size (expect on the order of 1 GB or more of free space during the exe module).
- **Time** *(estimate)*: the Mac run (aot-pipeline5, jobs 10, all 7 modules) took about 17 s end to end from log and cache timestamps (exe: `vxrt-aot gen` 5.43 s, module done after ~11 s). Expect 20 to 60 s for xrsimulator (same assembler work through `xcrun`); the signing of ~17 frameworks and `xcodebuild` time are not estimated. A concurrent measurement will slow it, which is why it waits.

## What remains after the modules

- [x] Re-pin the stale runtime in `tools/skyrim_aot_skyrimvr.json` (done 2026-11-10, see "Runtime pin"). Not yet used by a build.
- [ ] Run the first xrsimulator build (commands at the end of this file); record the dry-run and build `result.json`, the framework list, `bases.txt`, sizes, and compile/link time.
- [ ] Owned test first: `make -C VXRuntime XROS_SDK=xrsimulator xros-aot-tests` run of `arena_hello`/`fwarena_suite` on the simulator, to confirm the simulator honours the arena at `0x7000000000` (proven on the headset in `VISIONOS_PORT.md`; on the simulator the notes only record `0xf00000000`; unverified).
- [x] (drafted, uncompiled, unrun) `-game skyrimvr` in `main.m` `game_start` -> `skyrimvr_start`: only with that argument; `VXRT_SKYRIM_DIR` (default `<root>/SkyrimVR`), `VXRT_SKYRIM_EXE` (default `<dir>/SkyrimVR.exe`; must be the prepared exe, sha `8daf0519...`, because module names carry a hash of the file), cwd the game folder, Steam variables cleared, `VXRT_NO_WINE=1`, `VXRT_OVERLAY=<dir>:<root>/overlay_skyrimvr`, `VXRT_DLL_PATH=bundle/redist` when present (msvcp140, d3dx9_42, X3DAudio1_7 must be in the game folder or there).
- [x] (drafted, uncompiled, unrun) Configurable root: `VXRT_GAME_ROOT` overrides `<Documents>/root` for every game; unset = unchanged. Info.plist/launch-argument forms are left for AVP Play Prerequisite 3.
- [ ] Review the draft with a compile (the first build): `main.m` and `d3d11.m` have never been compiled.
- [x] (drafted, uncompiled, unrun) xrizer for `-game skyrimvr`, reusing the fixture's path, about 30 changed lines and no xrizer source change. The fixture was already runtime-selected by env (`VXRT_XRIZER_XROS_FIXTURE=1`, `_OFFSCREEN=1`, `_PRESENT=1`: `loader.c` registers xrizer's OpenVR exports as `openvr_api.dll` and waits for the compositor, `VXImmersive.swift` offers head/optics and shows the acquired pair side by side in the simulator's one view), so only two pieces were needed: (a) `XROS_XRIZER_GAME=1` in the Makefile: implies the fixture build (same `libxrizer.a`/`libklepton.a` link, same sources, dir `build/xrsimulator-xrizer-fixture`, bundle id `...XrizerGame`), builds no fixture guest, and `xros-aot-tests` only makes the registry (arena) and an empty `libaot.a`; the game's frameworks come from `$(XROS_DIR)/game_fw`; (b) `main.m`: with `-game skyrimvr -xrizer` it sets those three variables before Swift starts. Without `-xrizer`, or in any other build, they are not set (and are inert without the fixture build). The default app, `-game cyberpunk` and the existing fixture build (`XROS_XRIZER_FIXTURE=1`) are unchanged (`make -n` shows the same recipes). No Mac file was edited: `loader.c`, `native_vr_present.m` and `VXImmersive.swift` are untouched, and the Mac build never sets `VXRT_XRIZER_XROS_FIXTURE`.
  - Not verified (nothing compiled or run): that the fixture's host takes a real game's `Submit` through `xrizer_guest_d3d.m` (the fixture guest is a tiny D3D11 program); that `wait_ready` (30 s, needs ARKit tracking or 45 frames) is met before Skyrim's `VR_Init`; that the pinned `owned-apple-test` xrizer build supports Skyrim's OpenVR interface versions as on the Mac dev host; head only, hands reported disconnected (no controllers: Skyrim may sit at "Press Any Button"); the side-by-side view is an inspection layout, not stereo.
  - This is the simulator only (the Makefile errors on any other SDK). A device build of this path is a separate task.
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
# 2. xrizer static libs for xrsimulator (once; xros-lib runs this too). Output: $M/build/xros-host-static/latest/{libxrizer.a,libklepton.a}
#    in THIS checkout's build/ (the app's link line reads ../build/xros-host-static/latest). Needs the repository-local Rust toolchain
#    with the aarch64-apple-visionos-sim target (unverified that it is installed there); offline, locked.
# (optional: XRIZER_RUST_ROOT defaults to build/toolchains/xrizer-rust; it was VeRantyx/build/toolchains/xrizer-rust before 2026-11-10)
:
make -C VXRuntime XROS_SDK=xrsimulator XROS_XRIZER_GAME=1 xros-xrizer-static-probe
# 3. app (embeds game_fw; ad-hoc signed; unsigned simulator build only). Build dir: VXRuntime/build/xrsimulator-xrizer-fixture
mkdir -p VXRuntime/build/xrsimulator-xrizer-fixture && ln -sfn $OUT/game_fw VXRuntime/build/xrsimulator-xrizer-fixture/game_fw
make -C VXRuntime XROS_SDK=xrsimulator XROS_XRIZER_GAME=1 XROS_CODE_SIGNING=NO xros-app
#    (the plain default app stays: make -C VXRuntime XROS_SDK=xrsimulator xros-app, unchanged)
# 4. the game folder in the simulator container (private copy; prepared exe, never the Steam install in place)
xcrun simctl boot <udid>; xcrun simctl install <udid> VXRuntime/build/xrsimulator-xrizer-fixture/derived/Build/Products/Debug-xrsimulator/VXRuntimeHost.app
D=$(xcrun simctl get_app_container <udid> marimokodai.VXRuntimeHost.XrizerGame data)/Documents/root/SkyrimVR
mkdir -p "$D"   # then copy: Data/ (or only what start-up reads), *.ini, the six DLLs, prepared/SkyrimVR.exe (sha 8daf0519...)
# 5. run, start-up only
SIMCTL_CHILD_VXRT_AOT_STRICT=1 xcrun simctl launch --console-pty <udid> marimokodai.VXRuntimeHost.XrizerGame -game skyrimvr -xrizer
grep -E 'reserved|aot:.*(opened|image at)|fallbacks to the translator|BC_REFUSED|Direct3D|VR_Init' $D/../../vxrt.log
```
The app target, bundle id and simulator app path above come from the Makefile and `project.yml` as read, and the `xros-app` target also runs `xros-aot-tests` (the test programs' modules); both are unverified until run. Criterion 6 depends on the `XROS_XRIZER_GAME=1` build below (drafted, unverified).

## Result of the first start-up run (2026-11-10) -- simulator, start-up only

Subject: visionOS 26.1 simulator (Apple Vision Pro device 82807DF6, existing, not reset), actual SkyrimVR.exe (prepared, sha `8daf0519...`), `-game skyrimvr -xrizer`, app `marimokodai.VXRuntimeHost.XrizerGame` built with `XROS_XRIZER_GAME=1 XROS_CODE_SIGNING=NO`. One launch, about 2 s of runtime. Not a headset, not rendering, not playability. Evidence (not committed): `/tmp/claude/sim/` (`mods.log`, `app.log`, `install.log`, `run1/vxrt.log`, `run1/host_log.jsonl`).

Builds: modules `--target xrsimulator` (out `aot-xrsimulator2`, first try `aot-xrsimulator1` died with `No space left on device`, removed): 15 s, 17 frameworks, 368 MB (exe 11 parts + 6 DLLs); the pipeline deletes its transient assembly. xrizer static libs for xrsimulator: 36 s. App (`xros-app`): 76 s, 17 frameworks embedded, app 410 MB. Game folder: `Data` (14 GB) APFS-cloned (no extra disk) plus ini, DLLs and the prepared exe.

Against the six points:
1. App launches with the Skyrim frameworks embedded: **observed** (17 `VXA_*.framework`; all opened by `dlopen`, 0.2 to 11.3 ms each).
2. Arena reserves at `0x7000000000`: **observed** (`host_log`: `"event":"arena","addr":"0x7000000000","size_mb":1024,"reserved":1`; the game's own VirtualAlloc then took `0x7040000000` and `0x70e0000000`, in the app's range).
3. AOT registry loads all 7 modules: **observed** (11 exe parts at `0x7000000000`, binkw64 `0x7003930000`, steam_api64 `0x7003a40000`, msvcp140 `0x7003a80000`, d3dx9_42 `0x7003b10000`, X3DAudio1_7 `0x7003d90000`; `openvr_api.dll` is replaced by xrizer's export module, so its framework was not opened).
4. Strict AOT entries > 0, fallback 0: **observed**: `aot: 3492196 entries into recompiled code, 0 C function calls, 3480636 native calls ... 0 fallbacks to the translator (0 addresses)`. One `aot: missing import stub 0x10a9bc0c0 from SkyrimVR.exe+0xc53384` at the stop.
5. D3D11 device creation: **not reached** (no `Direct3D` log line).
6. xrizer / OpenVR init: **observed**: `Initializing XRizer version 0.5.0`, `Creating OpenXR session with graphics API xrizer::metal_graphics::Metal`, session READY, `xrizer OpenVR: InitInternal2 ... error 0`, `GetGenericInterface IVRSystem_019 ... error 0`. The fixture host started (`xrizer_offscreen_start started:true`, head tracked, hands disconnected).

Stop reason (not BC_REFUSED, which was not reached): `SkyrimVR.exe: DLL DINPUT8.dll not found` at load, then `called an unimplemented function: DINPUT8.dll!DirectInput8Create` and the program stopped (about 2 s). On visionOS `directinput.m` is left out (`xros_stubs.c`: `vx_directinput_init` is empty), so neither `dinput8.dll` nor `setupapi.dll` (which `directinput.m` also registers; Skyrim's controller enumeration uses it on the Mac) exists. Also logged: 7 imports not implemented, `GetFileInformationByHandleExW` and `SetFileInformationByHandleW` missing from kernel32, `SteamAPI_Init` failed (expected without Steam).

Not fixed here, deliberately: a `dinput8.dll` / `setupapi.dll` stand-in in `xros_stubs.c` needs generated ABI thunks (`xros_stubs.c` is not in the thunk scan) and an input decision (fail the call, or route GCKeyboard / controller state), so it is a design change.

- [x] Modules for xrsimulator built (17 frameworks, arena `0x7000000000`).
- [x] xrizer static libs for xrsimulator built; `XROS_XRIZER_GAME=1` app built; frameworks embedded; installed in the simulator.
- [x] Criteria 1, 2, 3, 4, 6 observed as above (start-up only).
- [ ] Criterion 5 (D3D11 device creation) and the BC_REFUSED stop: not reached; blocked by the missing `dinput8.dll`/`setupapi.dll`.

## DirectInput for visionOS (2026-11-10) -- simulator, start-up only

`src/directinput.m` (which also holds `setupapi.dll`'s `SetupDi*`) is now built for visionOS (removed from `XROS_OUT`; the empty `vx_directinput_init` in `xros_stubs.c` is gone). Under `VX_XROS` the IOKit HID parts (`IOHIDManager` enumeration, element tables, device open/close, value reads) are replaced: one `hid_device` per extended gamepad from `GCController.controllers` (vendor/product as the Mac's `framework_pad` matching: DualShock 4, Switch Pro, Xbox One), a synthetic element table (sticks and triggers 0..255, hat 0..7, 10 or 14 buttons) and values from the existing `framework_value()`. The system keyboard and mouse were already user32's (`vx_dinput_key_down`, `vx_dinput_mouse_take`), fed on visionOS by `xros_ui.m`'s GCKeyboard/GCMouse. `directinput_buffer.c`, `directinput_format.c` and the generated thunks are unchanged. `setupapi.dll` lives in `directinput.m` on the Mac and now comes with it; on visionOS it lists what GameController reports (no pad attached: none). The two kernel32 log lines (`GetProcAddress(kernel32.dll, GetFileInformationByHandleExW / SetFileInformationByHandleW) failed`) are the same on the Mac (`build/play-012202/startup.log`): the real exports have no `W`; both are implemented without it (`system.c`, `filestate.c`). Nothing to change.

Verified:
- [x] Mac, `make -C VXRuntime check`: exit 0 in 4m22s (1833 "ok" lines), including `dinput8: DirectInput8 factory and HID game-controller enumeration: ok (0 attached)` and the buffer/format tests. (No `present_check` or `kernelx` failure appeared in this run.) The Mac code paths are the same source behind `#if !VX_XROS`; no pad was attached, so the Mac HID value path was not exercised by this run.
- [x] visionOS: `xros-app` with `XROS_XRIZER_GAME=1 XROS_CODE_SIGNING=NO` builds (78 s), `directinput.m` compiled for xrsimulator.
- [x] Simulator relaunch (same device, app reinstalled, game data kept): start-up got past `DINPUT8.dll` and reached the BC stop: `Direct3D: BC_REFUSED: DXGI format 77 ...` (so the D3D11 path creates textures; no separate "device created" log line exists). Right after it the game wrote through the failed texture (`unhandled exception 0xc0000005 at SkyrimVR.exe+0xdbfbca`, writing 0x20, rax 0) and the process ended: the expected consequence of the refusal, not a rendering result. The run's AOT summary line was not printed (crash path), so strict-AOT entries and fallbacks for run 2 are unknown; run 1 (before this change) had 3492196 entries and 0 fallbacks. Evidence: `/tmp/claude/sim/run2/`.
- [ ] Unverified: DirectInput devices on the simulator with a pad or keyboard attached (nothing was connected; no `VXRT_TRACE_INPUT` run), the Mac HID path with a real pad, an owned DirectInput test in the xros bundle (none exists).
- Other log lines to look at next: `CoCreateInstance` class `{6A93130E-1D53-41D1-A9CF-E758800BB179}` not available; 6 imports not implemented; `IXAudio2Voice::SetEffectChain` not implemented.
