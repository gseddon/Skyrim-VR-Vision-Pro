# Plan: device readiness for Skyrim VR on the physical Vision Pro, starting with a controller fixture

Date: 10 November 2026. Branch `codex/standalone-import` at `d4ac931`. Parent: [native Darwin AOT](2026-11-08-skyrim-vr-native-darwin-aot.md) (physical-headset gates) and [AVP Play backend](2026-11-09-avp-play-backend.md) (Prerequisites 2 and 4).

**Subject of every claim below: static reading of the repository, plus read-only queries on this Mac** (`xcrun devicectl list devices`, `defaults read com.apple.dt.Xcode`, `security find-identity`, provisioning-profile headers, `devicectl ... --help`, file listings of the Skyrim install). Nothing was built, installed, launched, copied or run. No device was touched. Everything marked *(unverified)* is inference from code or docs.

## 1. Current state of the device path

### What is real on the device today

| Piece | State | Evidence |
| --- | --- | --- |
| Default app (`exampleprefix.VXRuntimeHost`), `-test <name>` and `-game cyberpunk`, D3D12 swap chain warped into the immersive space | Ran on the headset (2026-10-30, visionOS 27.0), 90 Hz, own tests and Cyberpunk start | `VXRuntime/VISIONOS_PORT.md:85-117` (headset runs), `:119-165` (immersive), `:244-297` (Cyberpunk) |
| AOT modules as signed frameworks, arena `0x7000000000`, EVA/memory entitlements | Ran on the headset | `VISIONOS_PORT.md:166-191`; `xros/app/Sources/VXRuntimeHost.entitlements:5-8` |
| Shader cache from the Mac (`xcrun -sdk xros metal`) for D3D12 | Ran on the headset (70 loaded, 0 compiled) | `VISIONOS_PORT.md:210-221` |
| Device scripts | `tools/xros_device_run.sh`, `xros_shadercache.sh`, `xros_copy_plan.sh` exist; the first was only tested against a mock `devicectl` | `VXRuntime/tests/test_xros_device_run.py`; native plan line 502 |

### What exists only for the simulator

| Piece | State | Evidence |
| --- | --- | --- |
| xrizer + Klepton provider hosted in the app (the "fixture") | Simulator only, by construction: `$(error XROS_XRIZER_FIXTURE requires XROS_SDK=xrsimulator)`, `#error "xrizer xros fixture is simulator-only"`, app built with `-destination 'generic/platform=visionOS Simulator'` and `CODE_SIGNING_ALLOWED=NO` | `VXRuntime/Makefile:65-66`, `:338`, `:344`; `src/xrizer_xros_fixture.m:3-5` |
| `-game skyrimvr -xrizer` (`XROS_XRIZER_GAME=1`) | Simulator start-up only. It sets `VXRT_XRIZER_XROS_OFFSCREEN=1` and `_PRESENT=1`, which show the pair side by side in the simulator's single view | `xros/app/Sources/main.m:197-203`; `plans/2026-11-10-skyrim-simulator-build.md` ("Result of the first start-up run") |
| Skyrim modules | Built for `xrsimulator` (17 frameworks, 368 MB, app 410 MB, 15 s). `--target xros` has only ever been planned | simulator-build plan; `tools/skyrim_aot_pipeline.py:61` |
| Provider `INJECTED_TEST` mode | The fixture uses it. The `PLATFORM` mode exists, and no code in `xrizer_xros_host.m` branches on the mode (grep: only the validation at `:275` and the store at `:285`) | `src/xrizer_xros_host.h`, `.m` |
| Two-view stereo presentation (`fixture && !offscreen`) | **Never executed anywhere.** The simulator drawable has one view and fails its gate (`dedicated && views.count == 2`) | `xros/app/Sources/VXImmersive.swift:262-293`; `tests/xrizer_xros_fixture.md` ("A later two-view fixture has to observe...") |

### Is the ARKit accessory session started on the device? Not in any build that has xrizer

- The code is real: `VXNativeXRTracking.start()` → `refresh()` loads `Accessory(device:)` for each `GCProductCategorySpatialController`, runs `AccessoryTrackingProvider` on the shared `ARKitSession`, and `snapshot(at:)` predicts anchors and captures GameController input (`VXNativeXRTracking.swift:61-123`, `:125-185`). Under `XRIZER_XROS_FIXTURE`, `collect(at:)` publishes to input host v3 and haptics go out through `VXHapticRouter` (`:187-236`, `VXSenseHaptics.swift`).
- **It is started only if `vx_xros_native_enabled() != 0`** (`VXImmersive.swift:62-68`), which is `VXRT_NATIVE_VR=1` (`src/native_openvr.m:39-42`). The loader **refuses to start** when the xrizer fixture and `VXRT_NATIVE_VR` are both set (`src/loader.c:1670-1673`). So in the xrizer build (`-xrizer`) the adapter never starts, nothing is published, and the provider reports both hands disconnected. In the `native_vr_d3d11` build the adapter starts but `collect` does not publish and there is no v3 host.
- What has run: the Mac mock tests (`tests/xrizer_xros_controllers_test.c`, `xrizer_xros_sense_test.c`, `metal_mock.c`) and the **synthetic** `VXRT_XROS_TEST_HANDS` script on the simulator (guest checks trigger 1.0, A, stick values, two pulses logged "no actuator: not felt"; `tests/xrizer_xros_guest.cpp:49-70`). No accessory anchor, no Sense controller, no CoreHaptics engine has ever run on any device. `NSAccessoryTrackingUsageDescription` is in `Info.plist`; the code never calls `requestAuthorization` for accessory tracking *(unverified whether `session.run` prompts by itself)*. Re-running one `ARKitSession` with a changed provider list is Klepton's pattern *(unverified on this OS)*.
- The `native_vr_d3d11` path reads hand anchors and `GCController` extended gamepads (`VXNativeInput.swift`), not Sense accessories, and is not what the plan's Sense proof needs.

### The physical device, as seen now (read-only)

| Fact | Value |
| --- | --- |
| Headset | "Gareth's Apple Vision Pro", `RealityDevice14,1`, visionOS 27.0, **Developer Mode enabled, paired, DDI services available**, transport `localNetwork` (Wi-Fi, not the wired strap), state `connected` |
| Identifiers | CoreDevice `HEADSET-ID-PLACEHOLDER`, UDID `<headset-udid>` |
| Scripts' default `DEV` | `HEADSET-ID-...` in `tools/xros_copy_plan.sh:19` and `tools/xros_shadercache.sh:9`. It is not this device's current id. `xros_device_run.sh:11` requires `DEV` explicitly. |
| Mac | Xcode 26.1.1, `xcodegen` present, one valid code-signing identity, `Apple Development: <name> (<signing-id>)` |
| Xcode teams on this Mac | `<personal-team-id>` Gareth Seddon (Personal Team, **free**). |
| Team in `project.yml` | `DEVELOPMENT_TEAM: EXAMPLETEAM` (`xros/app/project.yml:11`), bundle prefix `exampleprefix`. **That team does not appear in this Mac's Xcode account list or keychain.** Whether it can be added is unknown. |
| **User-reported** (from the user's Xcode Devices window; not verified by me) | Name "Gareth's Apple Vision Pro", visionOS 27.0 (24M362), 256 GB, identifier `<headset-udid>`, paired and connected, Xcode was copying shared symbols. Installed apps use the bundle prefix `gseddon.dev.klepton.target.*` (Beat Saber, Portal, SUPERHOT), so the user's signing team already installs apps under a `gseddon.dev.*` prefix. Which team signs those is not stated and I could not read it. |
| Device support for OS 27.0 | **Observed:** `~/Library/Developer/Xcode/visionOS DeviceSupport/RealityDevice14,1 27.0 (24M362)` exists (created 2026-11-10 12:58, matching the user's "copying shared symbols"), and `devicectl` reports DDI services available. **Does 26.1 SDK vs 27.0 device matter?** Deployment target 26.0 is fine for a 27.0 device. Xcode 26.1.1 builds against `XROS26.1.sdk` (`xcrun --sdk xros --show-sdk-version` = 26.1) and has the matching device support, so install and launch should work; the 2026-10-30 headset runs were also on 27.0 with this toolchain (`VISIONOS_PORT.md:85`). What is *unverified*: whether 27.0 changed behaviour the app relies on (the arena, `mach_vm_range_create` was already refused on 27: `main.m:143`; ARKit accessory tracking, CompositorServices, CoreHaptics for Sense). The 27.0 behaviour of those has to be learned in Stage 1; a Stage 1 failure that names an API or entitlement is the thing to look for first. |
| Mac disk | 25 GB free of 460 GB (94% used). The first simulator module build already died with `No space left on device` (simulator-build plan). |

## 2. Gaps to close

Sizes are agent-work estimates *(estimate, not measured)*. "Before the device" lists the test that can run without it.

| # | Gap | Size | Files | Test before the device |
| --- | --- | --- | --- | --- |
| **G0** | **Signing team and bundle id.** (User-reported: the user's team already signs `gseddon.dev.klepton.target.*` apps.) The only team that grants `extended-virtual-addressing` and `increased-memory-limit` is a paid one; the AVP Play plan says the same ("Paid Apple team only"). This Mac has a free team, not `EXAMPLETEAM`. Every new bundle id also creates an App ID on the portal. | User decision | `xros/app/project.yml:11`, `VXRuntimeHost.entitlements` | None without the account. After it: unsigned build proves nothing about provisioning; the first signed `xcodebuild -destination generic/platform=visionOS` (no install) with `-allowProvisioningUpdates` needs approval (it registers App IDs). |
| **G1** | **Device build of the xrizer host.** Remove the simulator-only guards, build `libxrizer.a`/`libklepton.a` for `aarch64-apple-visionos` (toolchain target present at `/Users/gseddon/git/VeRantyx/build/toolchains/xrizer-rust/rustup/.../aarch64-apple-visionos`; `third_party/xrizer/build-visionos.sh device`), add a device mode to the static-link probe, a device destination and signing in the `xros-app` fixture branch. Choose a device bundle id (see Q3). | M (4-6 h) | `Makefile:57-67`, `:334-345`; `src/xrizer_xros_fixture.m:3-5`; `tests/test_xrizer_xros_static_link.sh`; `third_party/xrizer/build-visionos.sh` | Unsigned build `XROS_SDK=xros ... XROS_CODE_SIGNING=NO` (background, never while a game runs); `vtool -show-build` platform XROS; `nm` for the five static symbols the probe checks; `make -n` diff proves the simulator and default recipes unchanged. |
| **G2** | **Start the tracking adapter and publish in the xrizer build.** Gate `VXImmersive.start` on `vx_xros_native_enabled() \|\| vx_xros_fixture_enabled()` (hands stay off: they are for the native path). Decide authorization handling for accessory tracking. Log `xr_controllers` outcomes (supported, session run result, per-hand connect). | S-M (1-2 h) | `VXImmersive.swift:44-80`, `VXNativeXRTracking.swift` | Swift CPU controls (`tests/xros_spatial_*.swift`), `test_xrizer_xros_controllers.sh`, `..._sense.sh`, `..._publish.sh`; simulator run proving the code path logs "AccessoryTrackingProvider unsupported" and nothing crashes *(simulator support unverified)*. |
| **G3 (a)** | **Present xrizer's eye frames into the immersive space.** Today `-xrizer` forces the OFFSCREEN mono inspection. On a two-view device drawable that path draws nothing and falls through to the old D3D12 warp (`native` is false), so a Skyrim build would show the clear colour. Fix: on a device do not set OFFSCREEN/PRESENT; the existing `fixture && !offscreen` branch then offers real eye transforms and tangents, acquires the pair and draws it with `vx_xros_native_draw_eye` (rotation-only reprojection, no scene depth, depth cleared). Add per-frame stats (fresh pairs, repeats, source age, completion), because the only fresh/repeat counters live in the inspection path. | M (4-8 h) | `main.m:197-203`, `VXImmersive.swift:262-308`, `src/native_vr_present.m:50-135`, `src/xrizer_xros_fixture.m` (stats), `xros_vr.m` `vx_xros_vr_stats` | Existing Mac Metal checks (`make native-vr-gpu-check`) cover `vx_xros_native_draw_eye`; add a Mac test of the two-view branch's tangent/eye maths against the optics golden (`test_xrizer_xros_optics_golden.sh`). A true two-view run needs the device. |
| | *Reusable for G3:* `native_vr_present.m` (lease, completion, reprojection shader), the compositor loop with `deviceAnchor`/`depthRange`, `xrizer_xros_optics.m`. *Not reusable as is:* `xros_vr.m` warp core (needs scene depth; Skyrim's stereo pair has none). *Klepton's own presenter is not in this repo*: only its OpenXR core is vendored (`third_party/klepton_openxr/SOURCE.md`); the AVP Play fork needs a download that is not authorised. `VisionOSProto/Sources/ProtoRenderer.swift` and `VisionProClient/.../VRCompositorRenderer.swift` are streaming-era references. | | | |
| **G4 (g)** | **Sense controller wiring, end to end.** G2 above, plus a **device-capable controller guest** (see Stage 1). Unverified items: grip/aim convention (Klepton offsets deliberately not applied; levers `VXRT_SENSE_PITCH_DEG`/`_POS`), prediction cap 50 ms, left/right identity via `heldChirality`, CoreHaptics engine per hand (amplitude/duration only), whether pulses are felt. | M (3-5 h guest + checker) | new `tests/xrizer_xros_sense_guest.cpp` + checker; `xrizer_xros_controllers.c`; `VXSenseHaptics.swift` | The new guest runs on the simulator with `VXRT_XROS_TEST_HANDS`; the checker validates the log schema. Nothing is felt or tracked there. |
| **G5 (b)** | **Skyrim game-file copy plan.** `xros_copy_plan.sh` is Cyberpunk-only (paths, 62 GB, stale `DEV`, no Skyrim). Needs a Skyrim stage script. See section 2a. | M (2-3 h) | new `tools/skyrim_device_stage.sh` or `.py` (dry run by default, `--run` only after approval) | Dry run against the real install; a fake-tree test of the file selection and resume logic. |
| **G6 (c)** | **Device module build and embedding.** `python3 tools/skyrim_aot_pipeline.py --target xros` (never run; same code path as `xrsimulator`, different triple/SDK/cache key, `Info.plist` platform `XROS`). `embed_aot_frameworks.sh` signs each framework with the app identity. | S (1 h) + build time | `tools/skyrim_aot_pipeline.py`, `xros/app/embed_aot_frameworks.sh` | `--dry-run`, then `--build` on the Mac (15 s for the simulator set); `vtool` platform check; `codesign -v` of one framework after the signed app build. Free disk: at least 5 GB before starting. |
| **G7 (d)** | **visionOS shader cache.** See section 2b. | M (2-3 h) | `tools/shadercache_fill.sh`, `main.m` (`skyrimvr_start`), bundle layout | Key/flag equality test; compile one pending file with `-sdk xros`; `metal` accepts `-std=metal3.1`. |
| **G8 (e)** | **Memory.** See section 2c. | S to find out, unknown to fix | `main.m` `jlog` mem ticker; `d3d11*.m` | Compare against the Stage 2 `mem` log lines. |
| **G9 (f)** | **BC textures on the device GPU.** | S to log, unknown to fix | `src/d3d11.m:320-331`, `main.m:236-255` | Device probe already logs `"bc":1`; the creation path under `VX_XROS_SIM` is the only guard. See section 2d. |
| **G10 (h)** | **Console and mirror flow.** See section 2e. | S (1 h) | `main.m:189`, `tools/xros_device_run.sh` | Mac pipe test of the tee thread; mock `devicectl` for the new launch arguments. |
| **G11** | **Device run script for the xrizer bundle ids.** `xros_device_run.sh` launches only `APP=exampleprefix.VXRuntimeHost` with `-test <name> -present` (`:9`, `:41`), no `-game`, no environment, no `--console`, and it checks "idle" by the default bundle id. | S (1-2 h) | `tools/xros_device_run.sh`, `tests/test_xros_device_run.py` | The mock-`devicectl` unit test (exists; extend it). |

### 2a. Game files (G5)

- The install is 14 GB, 319 files. Measured from the listing: `Data/` 6 `.esm` + 19 `.bsa` (about 13.9 GB, largest Meshes0 2.0 GB, Voices_en0 1.7 GB), `Data/Strings` 105 files (59 MB), `Data/Interface` 9, `Data/Video` 1 (13 MB), the 4 `.ini` files, `SkyrimVR.exe`, and the DLLs. `_CommonRedist` (164 files) and `steamapps` (3) are Steam's, not read by the runtime *(unverified: no open-trace of a run is stored)*.
- **Which files the runtime reads:** the `.ini` support reads `Skyrim.ini` and the archive list opens all 19 archives (`handoffs/2026-11-08_22-58-00-skyrim-ini-archives.md`: "all 19 archives open"). So the set is `Data/` whole. A real trace needs `VXRT_TRACE_FILES=2` on a Mac run (`src/files.c:216`), which is a game run and is not done here. Do not drop archives (voices, sounds) before a trace shows they are unread.
- **The code is not game data:** the prepared exe (`build/private/skyrimvr/6961.../prepared/SkyrimVR.exe`, 33.7 MB, sha must stay `8daf0519...` because module names carry its hash), `binkw64.dll`, `steam_api64.dll`, `msvcp140.dll`, `d3dx9_42.dll`, `X3DAudio1_7.dll` (`.../redist/`). `openvr_api.dll` is replaced by xrizer's exports and is not needed.
- **Layout the runtime expects:** `VXRT_SKYRIM_DIR` default `<Documents>/root/SkyrimVR`, overlay `<dir>:<root>/overlay_skyrimvr` so game writes never touch the copy (`main.m:282-306`). The device file system is case-sensitive; `vx_ci_path` matches case-insensitively one component at a time (`VISIONOS_PORT.md:266-269`). **The simulator shares the Mac's case-insensitive file system, so it did not test this** (unverified for Skyrim's `Data\Strings\...` and `Skyrim.INI` opens).
- **Per-file cost on devicectl:** one `devicectl device copy` call per file is the measured worst case: 39 shader files took 22 minutes (`VISIONOS_PORT.md:216-219`), about 34 s per call. 150 calls would be about 85 minutes of pure overhead. **Copy by directory in one call** (`copy to --source <dir> --destination <dir>`), not per file. The sustained rate is not measured: `xros_copy_plan.sh` assumes 40 MB/s (`:17`, labelled "measure with a 1 GB file first"), which would be 6 minutes for 14 GB; the link is Wi-Fi (`localNetwork`) and "stalls when it is not worn" (`VISIONOS_PORT.md:217-219`). Treat 6 min as a floor and plan on a measured value. Measure first with one 1 GB file.
- **Hard-link mirror:** the install and the repo are on the same APFS volume (`/System/Volumes/Data`), so a hard-link tree (`ln`) of exactly the needed files costs no disk (25 GB free) and leaves the Steam install untouched. Its value is a clean, immutable, reviewable source tree for one directory copy and a manifest of sizes and hashes; it does not make the transfer incremental. `devicectl` has no rsync-style diff. For resume use `xcrun devicectl device info files --domain-type appDataContainer --domain-identifier <id> --subdirectory ... --recurse` (read-only) to compare sizes and re-copy the missing files only. Never use `copy to --remove-existing-content` (it deletes device data).
- The hard-link mirror and the staging manifest stay private, git-ignored (`build/private/...`), as in `AGENTS.md`.

### 2b. Shader cache (G7)

- **The Mac's 10,807 libraries cannot be reused.** `build/private/shadercache` holds `10807 .metallib` and no `.metal` and no `pending/` (checked): `shadercache_fill.sh` deletes each source after compiling it (`tools/shadercache_fill.sh:27`). They are macOS (`-sdk macosx`) libraries. A `-sdk xros` set needs the 10.8k MSL sources again, which means one Mac dev-host Skyrim boot with an empty cache folder and `VXRT_SHADER_CACHE` pointing at it (about 80 s to compile 10.8k, per the performance handoff line 76), then `tools/shadercache_fill.sh <dir> xros`. That boot is a game run: do it only when the Mac is free and no user session is active.
- **Key and options match by reading the code.** Key = FNV-1a of the MSL text, then flags `{2, std32, min_lod, safe}` (`src/shader_cache.m:76-84`). D3D11 libraries are fixed at Metal 3.1 (`src/d3d11_draw.m:38-46`) and safe math, and the fill script maps the flags to `-std=metal3.1`, `-fno-fast-math` (`shadercache_fill.sh:22-25`). `xros_shadercache.sh` does the same for the headset (`:14-18`). The SDK is not part of the key, so the same MSL and flags give the same key on the device. Open questions, all *(unverified)*: (1) the `min_lod` flag is decided at run time from the GPU (`VXRT_HAS_MIN_LOD_CLAMP`); the device may differ from the Mac, so the pending set must come from the device or from a Mac boot with the same flag; (2) `-fno-fast-math` versus `MTLMathModeSafe` produce equal code; (3) whether the MSL emitter has any `VX_XROS` branch that changes text. **Test:** first device boot with an empty cache logs `shader cache: MISS` lines and queues the true device keys in `Documents/shadercache/pending/`; diff those keys against the Mac set.
- **Delivery:** not by `devicectl` per file. Put the 10.8k files (about 150 MB for macOS; the xros size is unmeasured) in the app's `bundle/shadercache` and set `VXRT_D3D12_SHADER_CACHE_RO` to it, as the Cyberpunk path does (`main.m:326`). **`skyrimvr_start` does not set it today** (no `VXRT_D3D12_SHADER_CACHE_RO` between `main.m:282` and `:306`; the Cyberpunk path sets it at `:326`). Code-signing 10.8k resource files may slow the build *(unverified)*. The writable `Documents/shadercache` still collects misses. Keep the translated shaders private, as the AVP Play plan says.
- Without the cache, every first-seen shader compiles in-process on the device. The cost per cold compile on the device is not measured; the performance handoff says the Mac's warm Metal cache hides it.

### 2c. Memory (G8)

- Budget: `os_proc_available_memory()` was 8189 MB at launch; a Metal buffer fill reached 7424 MB with 760 MB left, so the app has about 8.1 GB including Metal (`VISIONOS_PORT.md:228-234`).
- **Skyrim's footprint on the Mac is not recorded anywhere I can read.** The Skyrim logs under `build/play-*`, `build/xrizer-game-1600` and the result JSONs hold no footprint, RSS or memory field (searched), the two crash reports in `~/Library/Logs/DiagnosticReports` are early crashes, and the handoffs have none. I did not run the game. So there is no Mac number to compare. Closest: the Cyberpunk numbers in `VISIONOS_PORT.md` are a different game.
- The Cyberpunk memory mechanisms (`VXRT_GPU_BUDGET_MB`, `VXRT_D3D12_TEX_DOWNSCALE`, `VXRT_MEM_LIMITS`, file-backed buffers) are **D3D12 code** (`src/d3d12.m:14247`); I found no D3D11 equivalent, so the Skyrim path has no texture downscale or budget guard. `VXRT_PAGEFILE` and `VXRT_IMAGE_CACHE` are in `kernel32.c`/`loader.c` and apply to any game, but `skyrimvr_start` does not set them.
- **Plan:** Stage 2 measures it on the device. `main.m` already logs `available_mb` and `footprint_mb` every 2 s into `host_log.jsonl` (`:46-52`, `:255-257`); jetsam leaves no crash report, so that log is the evidence. For a Mac figure, take it from the next Mac dev-host session with `footprint <pid>` read in the same run as a Stage 3 comparison; that is a separate game run.

### 2d. BC textures (G9)

- Observed on the device (2026-10-30): `bc:1`, Apple8, Metal 3, argument buffers **tier 1** (the Mac is tier 2), working set 10,922 MB, max buffer 8192 MB (`VISIONOS_PORT.md:108`). The probe is `main.m:236-255`.
- The BC refusal is `#if VX_XROS_SIM` only (`src/d3d11.m:320-331`), so on the device BC textures are created natively. Skyrim uses BC (DXGI 77 hit first in the simulator run). **Unverified on the device:** mip chains with sizes below 4x4, sRGB BC views, upload by `replaceRegion` with block rows, and the D3D11 renderer's own use of argument buffers on tier 1 (Cyberpunk's D3D12 note says "has to be checked against tier-1 limits"). Expect the first real failures to come from here and from Metal API validation, not from BC support itself.

### 2e. Console and mirror (G10)

- `devicectl device process launch --console` "bridges the app's stdout to devicectl's stdout" and cannot be combined with `--json-output -` (help text). **But `main.m:189` does `dup2(fd, 2); dup2(fd, 1)` into `Documents/vxrt.log` in the first constructor**, so the runtime's log never reaches the console. Options: (1) a `VXRT_CONSOLE_TEE=1` thread in `main.m` that keeps the original fd 1 and copies new `vxrt.log` bytes to it (about 25 lines, no behaviour change when unset); (2) poll `devicectl device copy from --source Documents/vxrt.log` (works while the app runs; slow link). Use (1) for live viewing and (2) for the evidence copy. Whether the app dies when the console detaches is *(unverified)*; `xros_device_run.sh` today waits `WAIT` seconds and copies the logs.
- Environment variables go in with `--environment-variables` (supported in the help), which is how the simulator variables are meant to be passed on the device.
- Mirror My View (Control Center on the headset, AirPlay Receiver on the Mac) is a visionOS system feature. Nothing in this repository touches it. **Unverified:** that Compositor Services immersive content appears in the mirror, its delay, and its cost on the headset. Treat mirroring as a development aid only: the Stage 3 frame-rate measurement is done with the mirror off, and a second pass with it on records its cost.

## 3. Staged sequence

Rules for every stage: one user approval per physical-device action (`AGENTS.md`); `DEV` is always the id from `devicectl list devices` (currently `HEADSET-ID-PLACEHOLDER`); no uninstall, no `--remove-existing-content`, no erasing app data; check for an active session first (`xros_device_run.sh` does); builds are unsigned until the team question is answered, in the background, and never while a `vxrt-arm64` game is running; the first physical run of each stage is a single launch, then evidence is read.

Commands marked **[device]** touch the headset and need approval. Everything else is Mac-only.

### Stage 0: one-off setup (about 0.5 h agent, 15-30 min user)

| Step | Who | Touches device |
| --- | --- | --- |
| **Change the team and bundle id.** Today `project.yml:11` says team `EXAMPLETEAM` and `:30` says `exampleprefix.VXRuntimeHost`, and the Makefile's `XROS_FIXTURE_BUNDLE_ID` defaults to `exampleprefix.VXRuntimeHost.XrizerOffscreen` / `.XrizerGame` (`Makefile:334`). The user's working team installs apps as `gseddon.dev.*`. Pass `XROS_FIXTURE_BUNDLE_ID=gseddon.dev.vxruntime.<name>` (it is `?=`, overridable) and a `DEVELOPMENT_TEAM=<id>` build setting for the fixture and game builds; the default app's `project.yml` is a separate edit that also needs both changed (the default bundle id is also hard-coded in `tools/xros_device_run.sh:9`, `xros_copy_plan.sh:21`, `xros_shadercache.sh:10`, so those take an `APP` override). Then confirm the chosen team grants the two entitlements in `VXRuntimeHost.entitlements` (Q1). Record which team, which bundle ids. Check `xcodebuild -showBuildSettings` resolves it. | user, then agent | no |
| Developer Mode, pairing, DDI: already true (`developerModeStatus: enabled`, `pairingState: paired`, `ddiServicesAvailable: true`). Re-check on the day with `xcrun devicectl list devices`. | agent | read-only listing |
| Wear the headset, keep it awake and unlocked, on the same network. Pair the two Sense controllers in the headset's Bluetooth settings, charged. | user | yes (human) |
| Free space on the headset for 14 GB plus 1 GB: read from Settings, or ask `devicectl device info details` *(read-only; not run here)*. | user / agent | read-only |
| Measure transfer rate: one 1 GB scratch file via `copy to` into a throwaway folder in the app container | agent | **[device]** |

Exit: team and `gseddon.dev.*` bundle ids chosen and the build settings pass them; device id recorded in the evidence folder; free space and transfer rate recorded (rate is currently unknown).
Approval needed: Q1, Q2.

### Stage 1: controller fixture on the device (agent 10-16 h in parallel pieces; user 30 min on the day)

Build the pieces G0, G1, G2, G3, G4, G10, G11. No Skyrim, no game data, no 14 GB.

The guest (`xrizer_xros_sense_guest.exe`, owned, built like `xrizer_xros_guest.exe`) runs about 60 s: init xrizer, `WaitGetPoses` each frame, submit a pair whose colour encodes trigger and grip values per hand (so the user sees the response in the headset), log changes of pose validity, position, buttons and axes per hand to stdout (which lands in `vxrt.log`), call `TriggerHapticPulse` once per hand at fixed times (5 s left, 8 s right), and on every rising trigger edge. Exit 0 if its own acceptance holds.

Mac and simulator checks before the device:
1. `make -C VXRuntime check`, `native-vr-unit-check native-vr-gpu-check native-vr-check`, the controller/sense/publish scripts.
2. Simulator run with `VXRT_XROS_TEST_HANDS` to validate the guest and its log schema (label: simulator, synthetic hands).
3. Unsigned device build: `make -C VXRuntime XROS_SDK=xros XROS_XRIZER_FIXTURE=1 XROS_CODE_SIGNING=NO xros-lib xros-aot-tests` then the app target once G1 lands; platform check with `vtool`.

On the device **[device]**, after approval:
```sh
DEV=HEADSET-ID-PLACEHOLDER
# build and install the fixture app (signed; needs Q1)
make -C VXRuntime XROS_SDK=xros XROS_XRIZER_FIXTURE=1 XROS_ALLOW_PROVISIONING=1 XROS_CODE_SIGNING=YES xros-app        # after G1
xcrun devicectl device install app --device $DEV <derived>/Debug-xros/VXRuntimeHost.app                                # [device]
DEV=$DEV WAIT=75 VXRT_... tools/xros_device_run.sh xrizer_xros_sense_guest                                              # [device], after G11
```
The user holds both controllers, accepts any permission prompt, moves both hands, presses trigger, grip, A, B (X, Y), stick direction and click, and says whether each haptic pulse was felt.

| Exit criterion (all from `host_log.jsonl`, `vxrt.log`, and the user) | Source |
| --- | --- |
| Launch nonce matches; `arena reserved:1`; strict AOT summary with entries > 0 and 0 fallbacks (missing summary = fail) | host log, runtime log |
| `xr_controllers` shows accessory tracking supported and running; both hands logged "connected as oculus/touch_controller, position tracked" | `xrizer_xros_controllers.c:log_hand` |
| Poses: left and right distinct, valid, positions change by at least a set distance while the user moves (agree the number before the run) | guest log |
| Each of trigger, grip, A, B, stick axes and click seen changing at least once per hand | guest log |
| One pulse forwarded per hand "to the controller" in the log, **and the user reports felt or not** | log + human; "felt" is recorded as user-reported |
| Fresh pairs presented in the immersive space with completion, repeats counted separately | new per-frame stats (G3) |
| Process exits 0 and the app container is intact | `loader_returned`, `exit` events |

Stage 1 also gives the first execution of the two-view stereo path and the first measurement of `computeProjection`/eye transforms on a real drawable. A failure in the controller half does not invalidate the presenter result, or the other way round; record each separately.

Approval needed: device install and launch (Q2), the permission prompts (user, on device).

### Stage 2: Skyrim start-up on the device, to the first frame in the immersive space (agent 6-10 h; wall-clock dominated by the copy)

Pieces: G5, G6, G7, plus the device defaults in `main.m`, and Stage 1 working.

Mac-only preparation:
```sh
M=/Users/gseddon/git/Skyrim-VR-Vision-Pro; SHA=6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971
OUT=$M/build/private/skyrimvr/$SHA/aot-xros1; CACHE=$M/build/private/skyrim-aot-cache-xros
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xros --dry-run --out $OUT
python3 tools/skyrim_aot_pipeline.py --config tools/skyrim_aot_skyrimvr.json --target xros --build --out $OUT --cache $CACHE   # about a minute (estimate)
ln -sfn $OUT/game_fw VXRuntime/build/xros-xrizer-fixture/game_fw
python3 tools/skyrim_device_stage.py --dry-run          # new (G5): manifest, sizes, hashes, hard-link mirror under build/private
```
Shader set: one Mac boot into an empty cache folder, `tools/shadercache_fill.sh <dir> xros`, copy the libraries into `VXRuntime/build/xros-xrizer-fixture/bundle/shadercache` (G7). Run only when the Mac is free.

On the device **[device]**, after approval, in this order:
1. Install the signed `XROS_XRIZER_GAME=1` app (own bundle id; 17 frameworks, about 410 MB plus the cache).
2. Copy the game tree into `Documents/root/SkyrimVR` with one directory `copy to` call and the stage script's resume check (14 GB; time to be measured in Stage 0).
3. Launch once:
```sh
xcrun devicectl device process launch --device $DEV --console --terminate-existing \
  -e '{"VXRT_AOT_STRICT":"1","VXRT_CONSOLE_TEE":"1"}' exampleprefix.<GameBundleId> -game skyrimvr -xrizer -lognonce <hex>     # [device]
```
4. Copy back the logs: `tools/xros_shadercache.sh device`-style single-call copies of `Documents/vxrt.log`, `host_log.jsonl`, `aot.misses`, `shadercache/pending`.

| Exit criterion | Source |
| --- | --- |
| App launches with 17 frameworks opened by `dlopen`; arena `0x7000000000` reserved; 7 modules at their bases | `aot:` lines, `arena` event |
| Strict AOT summary present, entries > 0, **0 fallbacks** | `aot:` summary line |
| Skyrim reaches D3D11 device creation, xrizer init, `VR_Init` returns 0, `WaitGetPoses` progressing | `vxrt.log` |
| **First frame:** at least one fresh Skyrim eye pair presented in the immersive space with GPU completion (the logo or loading screen counts). The user confirms something is visible and in the correct eye | new stats + user |
| Memory: `footprint_mb` and `available_mb` series for the whole run; no jetsam | `host_log.jsonl` `mem` events |
| BC: first BC texture creation logged without error | `vxrt.log` |
| Shader cache: hit, miss and queued counts from the `shader cache summary` line | `vxrt.log` |

Expected stops and what each would mean: a jetsam kill (memory: Section 2c), a Metal validation failure on the first BC or argument-buffer use (2d), a case-sensitive path miss, a missing import. Each is recorded as its own finding. Not a pass: process still running with a black view, or a stop at the first frame.
Approval needed: install and launch (Q2), the 14 GB copy onto the headset (Q4), whether a game copy may sit in the app container.

### Stage 3: Helgen cart with a frame-rate measurement (agent 3-6 h plus whatever Stage 2 exposes)

Prerequisite: Stage 2 reached the loading screen and past it. Reference on the Mac dev host: Helgen cart 85 fresh pairs/s with non-blocking submit (A B B A, dev host; commit `3dca360`). That number is a different GPU and a different presenter; it is context, not a target.

- Input: the Mac's scripted "A every 2 s from 6 s to 140 s" and an empty `sIntroSequence` in a per-run `Skyrim.ini` copy in the overlay (`cfb7427`, `tools/play_skyrim_dev.sh --helgen`) have a device equivalent already in the code: `VXRT_XROS_TEST_HANDS` (`xrizer_xros_controllers.c:90-112`, `:163-175`) gives scripted controller input without a human and takes precedence over real tracking. The human run with the Sense controllers is a separate, later pass.
- Measure on the device: fresh pairs per second (not compositor frames), repeats, source-frame age, GPU time of the draw, missed deadlines, `footprint_mb`, and thermal state if exposed. Measurement runs with the Mac mirror **off** and nothing else on the headset; no Xcode builds or signing activity on the Mac during the run. Alternate A B B A if comparing two settings (the vxrt harness rule).
- Exit: a run log with the stats above for at least the first 140 s of the cart, strict AOT 0 fallbacks, no jetsam, and a stated fresh-pairs-per-second figure with the run id; the harness cannot record it (it assumes a Mac SteamVR path), so the evidence is `host_log.jsonl` + `vxrt.log` copied by the device run script with the nonce. "Playable" is not claimed; only a human headset playtest of at least ten minutes establishes it (native plan).

## 4. Questions for the user

| # | Question | Why it is theirs |
| --- | --- | --- |
| Q1 | Which team signs the device build, and which bundle id prefix? You report that `gseddon.dev.klepton.target.*` apps install, so a `gseddon.dev.*` prefix works for your team. Is that team paid? Our entitlements (`extended-virtual-addressing`, `increased-memory-limit`) need a paid team, `project.yml` names `EXAMPLETEAM` (not in this Mac's Xcode, which lists only a free Personal Team), and I could not tell which team signs the Klepton apps. Do you want to add the paid team here, or use another route? Also approve `-allowProvisioningUpdates`, which registers App IDs and the device on that team's portal. | Account and cost, and a portal action outside the repository |
| Q2 | Approve physical-device actions stage by stage: Stage 0 scratch copy, Stage 1 install and launch, Stage 2 install, copy and launch, Stage 3 launch. Will the Sense controllers be paired and in hand on the day of Stage 1? | `AGENTS.md`: device install and launch need their own authorization |
| Q3 | One device bundle id for all stages or two? One keeps the 14 GB container but needs a merged fixture and game build (the `XROS_XRIZER_GAME=1` branch drops the fixture guest). Two (fixture, game) is less work and the game copy happens once, in the game app. Each id is a new App ID on the team. | Naming and portal footprint |
| Q4 | May a 14 GB private copy of your owned Skyrim files, and the translated modules, be placed on the headset? Is there room (free space unread)? | `xros_copy_plan.sh` requires an explicit yes for game data on the device |
| Q5 | Is the wired Developer Strap available? The device is on `localNetwork`; transfer speed and the link stalling when not worn are the main schedule risks. | Hardware you own |
| Q6 | Is the Mac free for the Mac-side jobs (the module build and the shader-source boot, which is a game run)? | The Mac is also your play machine |

## 6. Klepton host adoption and boot-straight-into-Skyrim (2026-11-10, branch `worktree-agent-af19bef3afdccd68f`)

Source: Klepton fork `https://github.com/myMartek/Klepton` at `a7bad301c10b03e7d615ae8d51033146c373bcb5` (the fork AVP Play builds the user's apps from), read from a shallow clone in the git-ignored `build/private/klepton-src/`. Record: `third_party/klepton_host/SOURCE.md`. Scope set by the user: the minimum for a first headset test, no extra Klepton settings.

| Row | State after this change | Evidence / subject |
| --- | --- | --- |
| Presenter (immersive space, CompositorLayer loop, two-view drawing, device anchor, prediction) | **Kept ours** (`VXImmersive.swift`, `native_vr_present.m`). Klepton's `KleptonCompositor.swift` is 6.7k lines bound to its own runtime (ANGLE eye textures, `kl_app_*` seam, guest fence); the loop structure is the same as ours; ours has the non-blocking submit (3dca360) and fresh/repeat/stale counters that Klepton lacks. Foveation not adopted (our composite does not draw through the rate map). | static reading; sim run below |
| Sense controllers started in the xrizer build (G2) | **Done**: the accessory session starts whenever the immersive space is open (`fixture` or `VXRT_NATIVE_VR`); hands stay native-only. Logs `xr_controllers` once per change of the paired set, "no spatial controller connected" when none, and `xr_controller_state` per hand once a second | simulator: adapter starts, logs "AccessoryTrackingProvider unsupported" and carries on. **No Sense controller has run on any device** |
| Poses/buttons into input host v3, Touch profile, haptics | Unchanged code (`VXNativeXRTracking`, `xrizer_xros_controllers.c`, `VXSenseHaptics`), now reachable. Synthetic script on the simulator: xrizer shows both hands, trigger, A, stick; trigger pulses forwarded ("no actuator: not felt") | simulator, synthetic hands |
| Boot straight into Skyrim | `XROS_XRIZER_GAME=1` builds set Info.plist `VXDefaultLaunch` = `-game skyrimvr -xrizer -immersive` (`XROS_DEFAULT_LAUNCH`); an explicit `-test`/`-game` wins. Bundle id `gseddon.dev.vxrt.SkyrimVR`. Scene: persistent overlays hidden (`VXRT_OVERLAYS=1` undoes), backgrounding/crown press exits (`VXRT_EXIT_ON_BACKGROUND=0` keeps) | build + sim |
| Owned guest controller mode `-test xrizer_xros_guest -immersive -controllers` | Logs each hand's pose, trigger, stick and buttons each second (console and `vxrt.log`; the host also writes `xr_controller_state` to `host_log.jsonl`), pulses on trigger rising edge, tints each eye red by its trigger | simulator, synthetic hands |

Shared with the user's other Klepton apps now: the controller stack (tuning, prediction cap, haptics engine), accessory-session pattern, privacy strings, GCSupportedGameControllers, hidden overlays, exit-on-background, launch straight into the immersive space. Different: our own compositor and runtime; `.full` immersion (Klepton default `.mixed` with black backdrop); no foveation; no launcher window; no settings.

Follow-ups, none wired (pointers into the fork `visionos/Sources/`): launcher/start window `KleptonLauncher.swift`, `KleptonShell.swift`; settings and tuning `KleptonTuning.swift`; play area and recentre `KleptonBoundary.swift`, `KleptonRoomSpace.swift`, Sense-options-hold recentre in `KleptonControllers.swift` (`pendingRecenter`); controller prompt/recovery after interruption `KleptonControllerRecovery.swift`; hand matting (`upperLimbVisibility`, `KleptonChroma.swift`); mixed immersion + black backdrop and 100 Hz (`Immersive.mixed`); foveation (`KleptonStageConfiguration`, `encodeComposite`); device-anchor walk-back/hold (`displayAnchor`, `originFromDevice`); gamepad fallback (`pollGamepad`); game-quit handshake in `Lifecycle.leave()`.

## 7. Physical-headset findings, runs 1 to 9 (2026-11-10, bundle `gseddon.dev.vxrt.SkyrimVR`, team YOURTEAMID, visionOS 27.0 device)

Subject: the actual game (`SkyrimVR.exe` from the user's own copy, 15.12 GB staged in the app container) on the physical Vision Pro, AOT modules (17 frameworks, strict AOT, 0 fallbacks), xrizer as OpenVR, the Klepton provider, the D3D11-to-Metal renderer, the signed app. Logs and crash reports: `/tmp/claude/perf/kleptonhost/device{1..10}*`, `device2/crash/`, `device6/crash/`. Each row is a failure observed on the headset, its measured cause, and the change that fixed it.

| Run | Observed | Cause (evidence) | Fix |
| --- | --- | --- | --- |
| 1 | exit 1 after 30 s, "compositor geometry unavailable" | `VXImmersive.start` awaited the Sense accessory `ARKitSession.run` before creating the compositor loop thread; the run did not return, so no frame ever produced geometry (`host_log`: immersive space opened, Sense controllers loaded, no `vr_start`) | compositor loop thread first; ARKit beside it (Klepton `startRenderLoop`/`runARKit`) |
| 2 | SIGKILL at 2.7 s, no app fault | the old frame code called `startSubmission` before `queryDrawables` and abandoned the submission when none came; Klepton's order (`queryDrawables`, command buffer, then `startSubmission`) adopted. The kill's `0x28` namespace is unidentified; not seen again after the change | Klepton frame order (`third_party/klepton_host/SOURCE.md`) |
| 3 | exit 5 at 16 s, 606 of 10,807 shader libraries "Too many open files" | `newLibraryWithURL` keeps the file open; the game asked for all 10,807 libraries at start and the cap was 10,240 (`OPEN_MAX`). Whether the game's own file opens failed at the cap was not shown; exit 5 was a guest `ExitProcess`/`TerminateProcess` (all runtime exit codes are 0, 1, 3, 9, 128+sig) | libraries mapped and loaded from `dispatch_data` with the descriptor closed (visionOS only; a 12,000-library Mac test held 3 descriptors); soft limit raised to the hard limit; synchronous `guest_exit` record with the caller and the last 20 file opens |
| 4 | game submitted pairs, none shown; every `WaitGetPoses` after the first failed with `ERROR_CALL_ORDER_INVALID` | (a) the combined ARKit run (head plus accessories) never returned until the user accepted the system's "allow motion input" prompt (run 5: "session running" 35 s after begin, when the prompt was accepted), so the head was never tracked; (b) the provider's `xrWaitFrame` refused while a waited frame had not been ended (the spec allows it to be discarded) | head and Sense accessories in separate `ARKitSession`s; `xrWaitFrame` discards a waited-never-ended frame (`third_party/klepton_openxr/src/core.c`, mock test updated). **The first launch needs the motion-input permission granted** |
| 5 | "HMD tracking 201 valid 0", `end_frame: views not presentable (flags=0)` | xrizer's standing space is STAGE; the provider sample carried no stage (`stage_valid`), so nothing was located in it (the Mac dev host sets `VXRT_XRIZER_DEV_STAGE`) | STAGE calibrated once from the first tracked head: origin = head position dropped by an assumed 1.6 m (`VXRT_STAGE_EYE_HEIGHT`), forward = head yaw. A development calibration, not a measured floor (ARKit's origin differed per launch: head y = -1.31 m and +0.73 m) |
| 5 | a flat one-eye Skyrim picture in a window | the runtime's flat display of the game's window (the desktop back buffer) beside the immersive space | the window is kept (the swap chain presents into it) but 160x90, opacity 0, plain window style; Klepton calls `dismissWindow()` instead (option recorded in the Klepton record) |
| 6 | SIGABRT at 71 s | the system invalidated the compositor layer; the fixture's one-way surface loss made the provider answer `ERROR_FORM_FACTOR_UNAVAILABLE`, and xrizer's `GetRecommendedRenderTargetSize` unwrapped it | xrizer local patch (last known size, `third_party/xrizer/render-target-size-fallback.patch`); a paused layer is waited out, an invalidated one reopened and rebound (five tries); not yet exercised on the device |
| 7 to 8 | the wearer saw only a faint window on a black background while the log said frames were presented; in-app capture of the drawable showed Skyrim's "Press Any Button" title | **reverse-Z depth.** visionOS reprojects with the depth buffer; our eye pass cleared depth to 0 (infinitely far) and wrote none, so the system composited "nothing at any finite distance" and showed none of our colour, including the placeholder (Klepton, measured on device: `KleptonCompositor.swift` ~1182-1196 and ~3896). devicectl cannot screenshot a visionOS device ("capability not supported"), so the app captures its own output | the eye quad writes reverse-Z 0.05 (about 2 m); the placeholder clears depth to 0.05 |
| 9 | **the user saw pink squares on a blue background (the placeholder), then Skyrim rendered in the immersive space; in-app captures show the title, then the opening cart ride** | | |

Facts from the runs that stay true: bc=1 and `argbuf_tier` 1 on the M2 GPU; shader cache 10,807 hits, 0 misses, 0 damaged with the bundle set; footprint about 4.8 GB with about 3.3 GB free in the loaded game; the compositor ran about 39 to 41 frames/s while the game rendered (about 100/s before it), one fresh pair per compositor frame, pair age about 79 ms (cause not found; `presentation_interval_ms` and `frame_total_ms_max` added to the `vr` event); the Sense controllers were connected at launch in runs 1, 2, 4, 5; in runs 3 and 6 none was connected at launch and they were picked up by the reconnect path ("controller connected" in `host_log`), the left hand pose with position untracked. The user heard in-game sound after pressing a button (runs 7 and 8); in run 9 the in-app capture shows the opening cart ride, so the title screen was passed.

Not verified: stereo comfort and scale (the stage height is assumed), whether controllers drive the game (poses, buttons, haptics felt), the reopen/rebind path after a layer invalidation, performance (about 40 compositor frames/s), a full play session, and whether `Press Any Button` was passed by the Sense controller or another input. A human playtest on the headset is the only evidence of playability.

**Next step (user request, 2026-11-10):** expose the render scale (`VXRT_RENDER_SCALE`, now 0.7 by the user's choice, was 0.8) as a user setting in the Klepton frontend settings when the Klepton settings UI is ported (default 0.7).
