# Skyrim VR native Darwin AOT implementation plan

Date: 8 November 2026 (Europe/London)
Status: prepared input available; native AOT startup investigation active; Klepton native provider bootstrap implemented; full xrizer integration pending; functional XR and game scene unproven

## Overview

Recompile the user's Windows x86-64 Skyrim VR code ahead of time into ARM64 code for a native Darwin host. Reuse VXRuntime's existing static recompiler and its D3D11-to-Metal implementation. Develop and investigate macOS execution and fully standalone Vision Pro execution in parallel, then integrate the same test program and runtime contracts across both platforms.

This is a fresh plan. No completed stage, source fix, baseline or game result from `SKYRIM_VR_TEST_PLAN.md` is credited toward acceptance here. Preserve that document and its existing worktree; use inspected source as reusable infrastructure, with new verification on the selected implementation revision.

## Active Priority: Prepared-input Skyrim Feasibility

The user selected the Android-style preparation/discovery/translation workflow and explicitly authorized unpacking private working copies of their owned game. Follow [the focused feasibility plan](2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md) for the game/compiler lane. The user subsequently requested supervised XR work in parallel, and now requests a researched Klepton-based plan and confirmed the existing Apple host with Sony PS VR2 Sense controllers as the first input target. It defines input validation, dependency closure, artifact identity, semantic tests, strict startup and iteration gates. The original Steam installation remains read-only. AGENTS.md now records this authorization; the prior DRM-removal exclusion is removed. Steamworks responses and anti-cheat are not to be fabricated or bypassed.

Pinned Steamless successfully prepared a private image: unexplained executable-section bytes fell from 78.98% to 0.86%. Actual strict native probes now reach EXE CRT initialization; the latest (`probe-skyrim-003`) records 2,537,167 AOT entries and a strict stop at an unclassified no-image address, with original inputs unchanged. A menu, scene and complete game-code semantics remain unproven. See the focused plan for evidence and the systematic build/probe workflow.

The confirmed XR revision reuses selected Klepton OpenXR and visionOS host code behind native xrizer, adding the missing Metal binding while retaining D3D11→Metal. See [the xrizer/Klepton workstream](2026-11-08-xrizer-klepton-native-openxr.md). The user confirmed this boundary; Phase A provider extraction has begun under supervised Terra ownership.

## Current Position and Next Acceptance Gates

Updated after the xrizer decision and Apple cross-builds on 8 November 2026. The active-priority subplan above now determines immediate work order; this section and the phase sections retain the full XR integration scope and evidence. Earlier diagnostic results remain useful but are not xrizer acceptance.

| Area | Established | Still to prove |
| --- | --- | --- |
| AOT / Windows compatibility | Owned CPU/D3D11 suite passes strict AOT on Mac and in visionOS simulator; simulated stereo fixture passes on Mac with zero fallback | Skyrim's reachable code/dependency coverage, Windows-to-xrizer ABI, and a clean broad runtime baseline |
| D3D11 / Metal / native frame exchange | Actual pixel checks and offscreen stereo presenter/queue tests pass; local tracking/input wiring and the visionOS host build | xrizer's Metal swapchain path, full frame/session lifecycle and physical presentation/input |
| xrizer Apple port | Frontend builds on three Apple targets; high-level Metal binding and typed texture-lease bridge pass host mock/layout tests | Bridge is disconnected; real provider/backend/compositor error propagation and GPU/session integration remain absent; init still refuses |
| Skyrim VR | Private prepared code and guest modules built; actual native AOT probes reach EXE CRT initialization | Current no-image target needs classification; no menu, stereo frame, scene, controller or performance result |
| Physical Vision Pro | Unsigned owned-fixture device app built | Signing/install/launch, available address space/memory, local stereo/tracking/input/audio and sustained operation |

Do not report a completion percentage: these are risk-reduction milestones, and the largest game-specific uncertainty is still untested.

### Architecture after adopting xrizer

```text
Windows x64 PE + private hash-matched ARM64 AOT modules
                         |
             native Windows compatibility host
                  /                       \
        D3D11 -> existing Metal       OpenVR guest ABI stubs
             eye textures                     |
                  |                         xrizer
                  |                   OpenVR -> OpenXR logic
                  |                           |
                  +---- Metal backend / native OpenXR provider
                                              |
                              local frame queue + platform host
                                              |
                           Compositor Services / ARKit / local input
```

xrizer owns the OpenVR compatibility behavior. It does not supply Apple's OpenXR runtime or translate D3D11 rendering into Metal. Keep its interface/input/compositor logic, port its graphics boundary, and implement the required native OpenXR provider over the existing local host. No Linux runtime, Vulkan graphics detour or expanding replacement OpenVR implementation is scheduled.

### Work order from here

1. **Prepared-input availability is established; now agree and freeze the Apple XR provider boundary using the confirmed existing-host boundary.** Inventory the actual OpenXR calls/extensions xrizer needs to initialize, submit a stereo pair and read one input mapping. Define which component owns Metal devices/queues/swapchain images, frame pacing, pose times, session events and resource completion. Establish a small tested subset with honest errors; do not begin a general OpenXR implementation.
2. **Run three bounded implementation lanes in parallel:** xrizer Metal plus native OpenXR provider; Windows guest ABI plus a fixture using Skyrim's versioned interfaces; and Skyrim AOT/dependency feasibility plus the two baseline failures. Coordinate the shared C boundary and fixture; serialize conflicting runs.
3. **Join on an end-to-end owned fixture.** Real Windows AOT guest calls -> real xrizer interfaces -> native OpenXR provider -> D3D11/Metal eye pixels. Prove this on Mac, then the same integrated fixture in visionOS simulator. A mock provider can isolate ABI tests but does not satisfy this acceptance gate.
4. **Prove the integrated fixture on physical Vision Pro early.** Use metre-based world geometry and independently specified eye transforms/projections, not just the current clip-space triangle. Verify tracking, one actual controller mapping, lifecycle, frame age and GPU ownership without streaming or a helper. Probe address space/memory before attempting large game packaging.
5. **Advance Skyrim through measured checkpoints where reachable.** Run its code-coverage investigation now, in parallel with XR work; do not wait until the entire XR stack is finished to discover whether its original executable can execute under strict AOT. Join the game to the proven XR path only after the relevant code and fixture gates are satisfied.
6. **Expand correctness and performance coverage.** Scene transitions, saves, audio, additional input/overlay paths, required sample counts/formats and sustained thermals follow an actual working scene. Do not tune pixels before correctness and fresh-frame measurements exist.

### Immediate uncertainties and stop conditions

- Prepared-image analysis now leaves 0.86% of executable-section bytes unexplained; the earlier 78.98% figure describes the wrapped original. Neither number establishes executable-path completeness. Metadata gaps, refused blocks, callback discovery and instruction/ABI semantics still require measured investigation. The latest no-image strict stop must be classified before assuming another static-code gap. Actual scene execution remains the game feasibility gate.
- `check` has an intermittent released-memory assertion reproduced in the source-unmodified Rosetta baseline; `check-arm64` has a thread/SMC-area failure also seen in the clean bootstrap. Isolate and fix with reproducers. These block declaring the broad baseline accepted, but do not require stopping independent source work. A JIT-specific failure and strict-AOT correctness must be measured separately.
- The existing custom OpenVR adapter uses System021/Compositor026 and test-only readback/expiry exports. Its fixture is a reference, not the production ABI contract. Add a fixture for the pinned xrizer's System019/Compositor022 (plus other interfaces as actually needed), and move diagnostics to host-side evidence rather than making xrizer implement test-only OpenVR exports.
- The current host provides rotation-only image reprojection and no reconstructed scene depth. Physical translation, world scale/origin and comfort need explicit tests; the old clip-space marker cannot prove them. Haptics, overlays, audio and unsupported MSAA/format paths remain separate coverage items.

## Current State

The following are source capabilities and implementation gaps, not claims that Skyrim runs:

| Component | Existing source | Planning consequence |
| --- | --- | --- |
| x86-64 AOT compiler | `VXRuntime/tools/vxrt_aot.c`, `translator/xlat.c`, `tools/aot_build.sh` | Generates ARM64 assembly and Mach-O modules; reuse rather than build a new C lifter |
| AOT execution and provenance | `VXRuntime/translator/aot.h`, `aot.c` | Modules bind to PE image hashes/bases, support split modules and report missing-code fallback; strict mode fails on a missing address |
| Native compatibility runtime | `VXRuntime/src/loader.c`, `kernel32.c`, `files.c`, `sync.c`, generated thunks | Retains Windows API/ABI, TLS and exception semantics while executing native ARM64 code |
| D3D11 graphics | `VXRuntime/src/d3d11.m`, `d3d11_draw.m`, `dxbc.c`, `dxgi.m` | Resources are Metal-backed; DXBC shaders become MSL. Reuse this path on both platforms |
| Owned CPU/graphics fixture | `VXRuntime/tests/recomp/suite.cpp`, `suite_d3d.c` | Starting point for independent x64 AOT, exceptions, threads and D3D11 correctness checks |
| visionOS host and initial native stereo adapter | `VXRuntime/xros/`, `src/native_vr*`, `src/native_openvr.*`, `translator/engine_nojit.c`, `tools/xros_aot.sh` | Host and local stereo diagnostic path build; offscreen presenter passes. xrizer is not yet linked to this host and physical presentation remains unverified |
| OpenVR semantics | xrizer at AVP Play's pinned revision; `NativeARM/vrruntime/` as an existing local reference | Port xrizer itself to native Darwin; retain versioned interface/input/compositor logic. Add Apple platform, Metal and Windows guest ABI integration |
| Local headset presentation/input | `VisionOSProto/Sources/ProtoRenderer.swift`, `VisionProClient/VisionSpatialTools/VisionTrackingManager.swift`, `VRGameControllerInput.swift` | Reuse completed-frame publication, actual eye geometry, local tracking and controller mappings; remove transport dependencies from adapted code |
| Measurement | `tools/vxrt_run.py`, `vxrt_ledger.py`, port `tools/xros_device_run.sh` | Existing game harness assumes Mac SteamVR; native backend/mode evidence must be added explicitly |

Sources inspected in the main checkout were at `86e179f`; the separate port worktree was at `138b173` and contained unrelated uncommitted work. These identify research inputs, not the revision to execute blindly. Implementation selected clean port base `138b173` in the isolated integration checkout; patch and evidence records appear below. Do not import the old worktree's dirty state implicitly.

## Desired End State

- A native ARM64 macOS host executes AOT modules with no Rosetta or JIT dependency in the accepted configuration. Rosetta/JIT may serve as labelled development references only.
- A signed visionOS app executes those translated paths locally, through the same compatibility and D3D11-to-Metal layers, with local stereo presentation, tracking, input and audio.
- The Mac can translate, sign and transfer files during preparation. No Mac/PC helper, streaming connection or external SteamVR process is required at launch or during headset execution.
- Every acceptance result names its subject: an owned fixture, a Skyrim module analysis, a measured Skyrim run, or a human playtest. Success in one category does not imply success in another.
- Authentication is not a prerequisite for compiler, graphics, VR or platform investigation and is not a research acceptance criterion. Actual Skyrim execution is established only by the paths it demonstrably reaches.

“Darwin directly” means native ARM64 machine code in a native app process with required Windows compatibility functions linked in. It does not mean that recompilation automatically converts Windows imports, C++ objects, TLS or exceptions into Apple equivalents, or that the original PE data images can be discarded.

## Out of Scope

- A new x86-64-to-C compiler, DXVK/Vulkan graphics replacement, Wine/ReactOS code, or a Linux/Android guest environment. GPL/LGPL licensing alone is no longer excluded; the user explicitly approved xrizer reuse and the repository policy now reflects that.
- Streaming, Mac-assisted authentication, Windows Steam/CEF development, and authentication emulation as prerequisites for this investigation.
- Manufactured ownership/account responses, anti-cheat work, changes to original game/Valve/Microsoft installations, and distribution of translated game code. Private-copy unpacking/preparation for the owned game is explicitly authorized; preserve original and prepared identities, settings/saves in overlays, and generated artifacts locally.
- Original 2011 Skyrim, an older flat-game VR conversion, SKSE/mods, frame generation, flat-frame stereo synthesis and broad performance tuning during the first proof.
- Implementing the entire OpenVR SDK before identifying and testing the required interface subset.

## Clarifying Questions and Decisions

The user selected the existing AOT compiler and the existing D3D11-to-Metal implementation. During implementation they approved GPL/LGPL reuse, selected xrizer as the OpenVR implementation to port to Darwin, authorized repository-local Rust/Cargo/crate downloads, and authorized use of the installed Vision Pro simulator. The user subsequently selected a shorter, plan-centered AGENTS.md, which is now applied; the earlier detailed proposal is retained as history only. Both Mac-native execution and physical-headset investigation are needed, and the investigations may proceed in parallel. Fully standalone Vision Pro remains the final target. Authentication must not hold up independent work.

Consequently, no Steam client work is scheduled as an initial gate. Repository-owned programs provide executable CPU, graphics and VR workloads without Steam dependencies. Read-only Skyrim inventory and static analysis proceed alongside them. If an actual game launch stops on a client/licensing requirement, record that limitation and continue the independent tracks; do not assume the requirement has vanished or change responses to claim progress.

The Android reference demonstrates a related static-recompilation approach, but targets a different x86-32/D3D9 executable. Its public runtime includes offline Steam stand-ins in shared code, and its releases describe processing the executable's protection locally. Those are not evidence of authenticated Steam integration and are not adopted here. Source references: [lifter](https://github.com/ttom795/Skyrim_Android/blob/main/tools/lift.py), [shared Steam code](https://github.com/ttom795/Skyrim_Android/blob/main/runtime/marvel_shims.c), [release notes](https://github.com/ttom795/Skyrim_Android/releases). Exact Skyrim APK paths were not independently verified.

## Options and Tradeoffs

The compiler and graphics choices are fixed. The user has now selected private prepared-image discovery/AOT as the immediate feasibility path; this does not replace the compiler or renderer. Two host-integration options remain viable:

| Option | Benefit | Cost | Decision |
| --- | --- | --- | --- |
| A: extend the existing ARM64 runner and platform adapters, sharing a native VR backend | Preserves loader/ABI/exception behaviour and gives rapid deterministic Mac tests; reuses the xros embedding path | Some general runtime functionality remains linked initially | Recommended for the first proof |
| B: build a narrowly scoped game-specific Darwin host around the compiler, compatibility functions and renderer | Explicit lifecycle and potentially smaller packaging surface | Earlier loader/initialization refactoring and more duplicated platform integration risk | Reassess after the common fixture passes; not a second compiler |

Use Option A initially, with xrizer ported as the OpenVR implementation. The hand-written minimal OpenVR fixture adapter is a diagnostic reference and must not grow into the production compatibility layer. Trim and package only after behaviour and cross-platform boundaries are verified. There is no need to delay the headset track until the complete game works on the Mac.

## Approach and Parallel Schedule

```text
Established foundations: AOT + Windows compatibility + D3D11/Metal + local host
                                   |
         +-------------------------+-------------------------+
         |                         |                         |
XR platform lane            Guest ABI/fixture lane     Game/runtime lane
xrizer Metal backend        Windows -> xrizer stubs    Skyrim code discovery
native OpenXR provider      System019/Compositor022    DLLs / reachable AOT
local tracking/input        independent ABI goldens    baseline reproducers
         |                         |                         |
         +-------------+-----------+                         |
                       |                                     |
          Integrated xrizer fixture: Mac -> simulator        |
                       |                                     |
          Physical standalone fixture + resource probes     |
                       +-------------------+-----------------+
                                           |
                    Measured Skyrim checkpoints -> wider scene/playtest coverage
```

The tracks can share fixes and findings throughout. The diagram is a dependency graph, not a requirement to finish one entire track before integrating a useful increment of the other.

### Parallel-work boundaries

- Give each track a separate repository-local worktree, build directory, runtime root, overlay, logs, module directory and shader cache. Preserve the existing Skyrim worktree.
- Assign one owner per shared source file/change. The compiler/loader owner and headset/platform owner agree interface changes before editing them independently.
- Separate worktrees matter: `tools/aot_build.sh` writes/removes `build/aot_s` regardless of its output argument, and comparison scripts use fixed `build/recomp/out` paths. Output-directory flags alone do not isolate two builds.
- Source work, static analysis and independent CPU-only tests can overlap. Serialize runtime suites on the same Mac because roots/named objects can collide. Cap concurrent compiler jobs to the machine's available RAM/cores.
- Mac and physical-headset functional tests can overlap when resources are independent. Schedule performance measurements separately from compilation and other GPU work, including signing/deployment activity that loads the shared host.
- Serialize device installation/launch and all game/SteamVR measurements. Check for an active user session before launching, never rebuild a binary during its run, never start competing SteamVR instances, and honor harness refusals.
- Use one exact merged source revision and regenerated matching artifacts for integration acceptance. Passing results from two divergent branches are not a combined pass.

## Phase 0: Establish a Fresh Base and Shared Test Contract

### Changes

- [x] Select and document the integration base and the minimal port components needed from the inspected revision. Preserve all existing dirty edits; do not reset, merge or apply them implicitly.
- [x] Create the separate workspaces/output roots proposed above and record toolchains, source patches and build commands. Workspaces and initial build/evidence roots are now established.
- [x] Freeze a versioned C contract for native VR state and submission. Keep Objective-C/Swift resource objects behind the host boundary; Windows OpenVR callers continue to use the exact Windows interface layouts and existing thunk mechanisms.
- [x] Define one minimal repository-owned PE32+ test program and a shared golden-result description. Implemented source: `VXRuntime/tests/native_vr_d3d11.cpp`. It renders distinct eye markers and known geometry, obtains poses and reads scripted controller state. It has no Steam dependency.
- [x] Define fixture OpenVR interface versions from reviewed headers and a separate Skyrim version inventory. Do not assume NativeARM's current System_026/Compositor_029/Input_011 versions match Skyrim's requests; never alias an incompatible vtable.
- [x] Make AOT verification check each child's exit status, explicit expected verdicts and a present zero-fallback report. The comparison script now rejects child failures, missing expected verdicts and absent/invalid AOT summaries; equal failures must fail verification.

Contract fields and invariants:

| Boundary | Required data/invariant |
| --- | --- |
| Module identity | Original PE SHA-256, internal AOT file hash, module descriptor version, image base/size, part list, generator version and target SDK; Mac and headset artifacts are built for their respective platform targets |
| Pose | Immutable snapshot ID, monotonic sample/prediction times, coordinate convention, metres, floor/seated origin, eye transforms/projections and tracking validity |
| Frame | Monotonic frame ID, source pose ID, left/right resource identities, sizes/formats/sample counts, bounds/color space, GPU readiness and retained ownership |
| Pairing/lifetime | Publish only a complete matching eye pair; reject duplicates/mismatches; retain resources until producer GPU work and all presentation readers finish; cancel/release exactly once |
| Depth | Use actual associated depth only when supplied and validated; do not fabricate game depth or infer a native stereo pair from a mirror window |
| Input | Coherent head/left/right state, sequence/time, connection/tracking validity, button/axis transitions, events and bounded haptic requests where supported |

### Automated Verification

- [ ] Fresh `make -C VXRuntime check`, `check-arm64` and `aot-suite` pass on the selected code. Capture actual statuses and expected test verdicts, not just make's final output.
- [x] Mocked verifier tests reject identical failing verdicts, failed children, missing AOT summaries and nonzero fallback reports.
- [ ] A controlled omitted-code test in a real owned AOT execution demonstrates strict missing-address failure and captures the missing image/address; mock log rejection alone does not prove that path.
- [x] Diagnostic Windows ABI/layout and native queue ownership checks establish the initial fixture contract without a headset or game. xrizer guest ABI and OpenXR resource lifecycle remain separate acceptance work.

### Manual Verification

- [ ] Review scope and contract against both track owners; identify the attached headset/controller capabilities before promising a physical input mapping.

## Phase 1A: Mac Native ARM64 and Game Analysis Track

Runs in parallel with the XR platform and xrizer ABI work. Initial diagnostic acceptance below does not cover xrizer or Skyrim.

### Changes

- [x] Build and exercise the owned fixture under the Rosetta reference, ARM64 diagnostic translator and strict AOT. Accepted native execution must use the ARM64 runner with generated modules and zero JIT fallback.
- [ ] Reuse and extend `tests/recomp/suite.cpp` / `suite_d3d.c` for native-call ABI, callbacks, TLS, SEH/C++ unwinding, threading/atomics, SIMD and D3D11 readback. Add only behaviour-driven reproducers for observed gaps.
- [x] Implement the Mac side of the native VR contract with deterministic poses/inputs and offscreen eye-texture checks. Use the actual D3D11-to-Metal renderer, not a synthetic Metal-only replacement for the acceptance fixture.
- [x] Initial read-only inventory records original image hashes, PE/import metadata, sections and OpenVR version strings.
- [ ] Complete the required dependency closure, export/relocation/layout review and classification of unexplained executable ranges. Do not fill static import gaps merely because they are listed.
- [x] Run `vxrt-aot analyze` on the original Skyrim exe and OpenVR DLL and record discovery statistics separately from execution results.
- [ ] Establish generation/refusal statistics and earliest reachable strict-AOT execution for the relevant original code/dependencies. Generate private modules only where meaningful. Native built-in Windows/D3D11 functions are already ARM64 and should not be retranslated; required guest x64 DLLs need appropriate modules.
- [ ] Keep executable-code discovery limitations explicit: analysis covers visible static bytes, not arbitrary runtime-generated or protected code. Missing paths must be diagnosed without changing protected game files or claiming coverage from fixture results.

Existing commands, after the selected checkout has the required targets:

```sh
make -C VXRuntime check
make -C VXRuntime check-arm64
make -C VXRuntime aot-suite
VXRuntime/build/vxrt-aot analyze "<owned-PE-path>"
VXRuntime/tools/aot_build.sh "<owned-or-fixture-PE-path>" "<private-module-directory>"
```

For fixture execution, explicitly select `build/vxrt-arm64`, `VXRT_AOT_DIR`, `VXRT_AOT_STRICT=1` and isolated roots. Capture the command/environment and output hashes. `native-vr-unit-check`, `native-vr-gpu-check`, `native-vr-check` and `tools/native_vr_run.py` now implement the initial diagnostic fixture checks; xrizer acceptance is still pending.

### Automated Verification

- [x] Correct child exits and semantic output across reference/ARM64/AOT; strict execution reports zero fallback.
- [ ] Known eye pixel checks, projections, frame/pose identity, scripted input transitions and lifecycle checks pass.
- [ ] Full required runtime checks pass after source changes; targeted new tests fail against the corresponding broken behaviour.
- [ ] Static analysis reports original module identities, discovery limits and required dependencies without converting those findings into a game compatibility level.

### Manual Verification

- [ ] Inspect fixture output and collected diagnostics. Any actual Skyrim run is a separate harness measurement with its own observed checkpoint and remaining unknowns.

## Phase 1B: Standalone Vision Pro Track

This track does not wait for Skyrim to reach a menu on the Mac.

### Changes

- [x] Integrate the minimal xros host/platform changes into the selected base. Retain `engine_nojit.c`, signed static/framework module loading and `tools/xros_x86calls.py`: Mac-style instruction-fetch faults into x86 guest addresses cannot be the headset dispatch mechanism.
- [x] Build/package owned tests and run the generic recomp suite in visionOS simulator, including native calls, exceptions, threading/TLS/SIMD and D3D11 pixel checks, with strict AOT and tiled staging.
- [ ] Package and execute the xrizer-integrated Windows stereo fixture on the simulator and physical headset. Generic suite results are not xrizer acceptance.
- [ ] Add native D3D11 eye submission to the shared backend. Map supported Windows texture handles to existing Metal-backed resources, with bounds, color space, MSAA resolve, lifetime and GPU completion handled explicitly.
- [x] Adapt the existing immersive host and VisionOSProto's completed-frame pattern for actual left/right images. Preserve the render-pose identity through display/reprojection and do not label old imagery as newly rendered.
- [ ] Provide local ARKit/GameController state rather than shared-frame/UDP inputs. Begin with deterministic state for automated tests, then verify one real local controller mapping appropriate to the connected hardware. Include legacy OpenVR controller APIs before assuming action-based input.
- [ ] Probe target-device address reservations, available memory, Metal features and supported formats. Choose module placement from current device evidence rather than hard-coding a prior machine's layout.
- [ ] Exercise pause/resume, cancelled frames, tracking loss, input staleness, resize/format transitions and teardown with explicit ownership of pending frames.

Existing port targets to preserve or migrate before use:

```sh
make -C VXRuntime xros-lib
make -C VXRuntime xros-aot-tests
make -C VXRuntime xros-app
make -C VXRuntime XROS_SDK=xrsimulator xros-lib
```

Device launches must select the actual device ID and repository-local output path. `tools/xros_device_run.sh` now requires an explicit device, repository-local evidence, one named test, an idle-session check and a matching launch nonce. Its actual devicectl JSON schema and operation remain unverified on a physical device. Do not uninstall or remove existing app data. Device installation/transfer follows AGENTS.md; no such action is authorized merely by a build succeeding.

### Automated Verification

- [ ] Signed ARM64 fixtures load with no runtime code generation; missing-code/ABI errors fail explicitly and are captured.
- [ ] D3D11 fixture readbacks match expectations; frame-pair, completion and reader-lifetime invariants hold under asymmetric submissions and cancellation.
- [ ] Device logs distinguish fresh fixture pairs, compositor frames/repeats, source-frame age, GPU duration, missed deadlines and memory footprint.

### Manual Verification

- [ ] Physical headset launch works with no Mac helper, debugger/JIT activation or streamed frames.
- [ ] Left/right eye markers, geometry scale/projection, head motion, floor origin and recentering are correct.
- [ ] One real controller mapping, tracking loss and resume are verified; haptics are claimed only for hardware actually tested. Simulator success does not replace these checks.

## Phase 1C: Port xrizer to Native Darwin

User decision during implementation: use xrizer instead of extending the custom OpenVR adapter. Port xrizer itself; do not replace its semantics with another hand-written implementation. Keep the existing native AOT and D3D11-to-Metal paths.

AVP Play pins upstream xrizer `0989a7fac2d1efb7ea82f5fe1a8ed30c3eeb9596` and supplies patches for measured frame timing, loading-screen messages and dominant-hand reporting. Its build produces a Linux ARM64 `vrclient.so`; local headset execution is supplied by Klepton and an OpenXR runtime, not by native Apple support inside xrizer. Reuse the source and relevant patches with attribution, rather than treating that binary as a Darwin library. Sources: [pinned integration](https://github.com/myMartek/avp-play/tree/1a196074151faf40d5f598678e3f26a1cf220c05/third-party/xrizer), [Alyx recipe](https://github.com/myMartek/avp-play/blob/1a196074151faf40d5f598678e3f26a1cf220c05/recipes/alyx.json).

### Changes

- [x] Authorize GPL/LGPL reuse in `AGENTS.md` and synchronize generated agent instructions. Keep the separate Wine/ReactOS restriction.
- [x] Have a Terra agent investigate upstream/fork boundaries, interface versions, graphics backends and native port requirements with bounded check-ins.
- [x] Vendor pinned xrizer source, preserve its license/notices, dependency lock and original provenance. Root third-party notices record its separate licensing. AVP Play patches are deliberately not applied; evaluate them individually below. Its Debian package-install script was not executed.
- [x] Add partial native Darwin build targets and gate incompatible Linux/GLX/UI/shader paths. ARM64 macOS, visionOS simulator and device libraries build; the host factory smoke test verifies an explicit unavailable-backend error.
- [ ] Replace `AppleBackendUnavailable` with functioning, tested initialization only once a real provider and Metal session path are available; a compiled frontend is not functional XR.
- [ ] Connect the OpenVR interfaces to Windows guest callers using generated AOT stubs and correct per-version layouts, hidden return pointers, structures, floating-point and callback ABI. A native Rust function pointer is not a Windows guest callable address.
- [ ] Add a Metal graphics backend and the Windows DirectX texture-to-existing-Metal-resource adapter. Remove the unconditional temporary Vulkan requirement on the Apple path, preserving readiness, bounds, color and ownership.
- [ ] Adapt selected MIT Klepton OpenXR lifecycle, spaces/actions and visionOS host code into the native provider described in the XR subplan, using the user-confirmed existing-host boundary. Add actual `XR_KHR_metal_enable` support; Klepton upstream currently exposes GLES/Vulkan bindings. Retain xrizer's session/frame/input logic and existing D3D11→Metal above this boundary. No loader-only substitute or whole Android/Linux compatibility runtime is needed.
- [ ] Evaluate each AVP Play patch against the native timing/loading/input contract before applying it; none is automatically a Skyrim fix.

### Implementation boundaries and increment order

- **Provider owner:** selected Klepton-derived implementation with native `xrGetInstanceProcAddr` dispatch; instance/system/extension enumeration; actual session events; reference/action spaces; view poses/FOV and frame prediction; wait/begin/end; Metal swapchain image lifetime and GPU synchronization. Adapt existing local tracking/input/presentation; add no successful capability response without an implemented behavior. macOS may use a labelled deterministic test provider; visionOS uses actual local platform state.
- **xrizer graphics owner:** implement the missing high-level Metal `Graphics` binding using available raw extension definitions; add a `GraphicsBackend` Metal variant; resolve supported guest DirectX handles through the existing D3D11 resource bridge; preserve eye bounds/color/sample/ownership semantics and replace the temporary Vulkan session on Apple. Track overlays and resolves explicitly; first proof may honestly reject unsupported configurations.
- **Guest ABI owner:** generate static Windows guest-callable wrappers and per-version vtable/FnTable dispatch, including factory/init/shutdown lifecycle. Define the minimum System019/Compositor022 fixture against the matching versioned headers, not the current newer SDK fixture types. Verify float/matrix/aggregate returns, invalid versions, callbacks and lifetimes against independent Windows ABI goldens.
- Join the owners at real initialization and the first completed two-eye D3D11 frame. Preserve xrizer's frontend/compositor logic. Avoid simultaneously inventing a second general VR abstraction or replacing existing D3D11 rendering.
- After the first frame, extend to pose-driven metre-scale scene geometry, actual input changes, pause/resume/tracking loss, format/resize transitions, pending-GPU cancellation and repeated-session teardown. Use host evidence for diagnostics rather than the old custom adapter's test-only exports.

### Automated Verification

- [ ] First bounded port spike: native library loads and `IVRSystem_019` / `FnTable:IVRSystem_019` calls through actual Windows AOT stubs produce independently specified ABI results; invalid versions fail honestly.
- [ ] Second bounded spike: `IVRCompositor_022` receives the owned D3D11 fixture's two Metal-backed eyes and passes existing queue/GPU lifetime and pixel checks. Do not claim a full xrizer port from a stubbed interface fixture.
- [ ] Exercise application startup, missing-module handling and compositor lifecycle in the installed visionOS simulator. Simulator tracking limitations stay explicit.
- [ ] Strict AOT integration still reports actual entries and zero fallbacks; full required regressions pass, or each unresolved baseline failure stays recorded as blocking acceptance.

### Manual Verification

- [ ] Physical headset execution and actual controller/tracking behavior pass after the xrizer integration. No streaming/helper at runtime.

## Phase 2: Join the Tracks on the Same Native VR Fixture

### Changes

- [ ] Merge the shared backend and both platform adapters into one reviewed revision; regenerate artifacts and preserve platform-specific image-base manifests.
- [ ] Execute the exact same versioned PE fixture through strict AOT on Mac and headset. Match semantic results and geometry; compare pixel checks only where render targets and formats are deliberately equivalent.
- [ ] Extend the harness with an explicit runtime mode/backend, ARM64 runner/module provenance and on-device observations. Retain existing SteamVR behaviour and baselines; a local native runtime must not report a fictitious SteamVR connection.
- [x] Isolate Mac diagnostic fixture evidence from game profiles with explicit command/environment, artifact hashes, verdicts and statuses.
- [ ] Extend the same evidence discipline to the xrizer-integrated Mac/simulator/device fixture and native game harness, including source/build provenance, device/SDK identity, fresh frame/pose IDs, GPU completion, repeats, input and session events. Reject missing provenance or a missing AOT summary as unknown/failure, not zero fallback.

### Automated Verification

- [ ] Combined runtime suites and both fixture backends pass at the same revision, including mismatch/duplicate-eye, stale-input, cancellation and resource-release cases.
- [ ] Evidence validation rejects matching failing executions, JIT fallback, missing eye pairs, stale/mismatched poses and compositor-only activity presented as fresh frames.

### Manual Verification

- [ ] Repeat the physical headset check after integration; do not infer an integrated pass from separate branch results.

## Phase 3: Skyrim Integration Where Reachable

### Changes

- [ ] Use original read-only data, provenance-recorded private prepared code images and matching AOT modules with isolated settings/saves. Match only actual requested Windows/OpenVR interfaces and fix the first observed compatibility gap.
- [ ] Measure the earliest reachable checkpoint on native Mac ARM64 and headset: startup, API initialization, first native stereo frame, menu, then a fixed loaded scene. Compare at each checkpoint instead of finishing a large Mac gameplay matrix before headset work.
- [ ] If actual Skyrim startup stops before the measured checkpoint, record the exact observation and remaining unknowns. Continue compiler/graphics/VR fixture milestones independently; do not make authentication a project gate or turn a synthetic pass into Skyrim success.
- [ ] When execution reaches representative scenes, expand to interiors, outdoors, combat, inventory, save/load and location transitions. Recheck AOT coverage and resource budgets on every scenario.
- [ ] Measure fresh frame timing, GPU/CPU cost, memory/virtual reservations and sustained thermal behaviour on the headset. Set a comfort target from real target-device capabilities and user observation before selecting a tuning goal.

### Automated Verification

- [ ] Game claims come from the extended harness with run IDs and observed/derived IDs, sealed artifacts and ledger validation. Static analysis and fixture runs retain their separate status.
- [ ] Strict AOT, correct native eye submissions, input observations and scenario completion are established for each claimed checkpoint. Record what could not be exercised.
- [ ] Required runtime regressions and applicable existing game baselines pass after changes; honor refused runs and the repository's three-attempt issue-draft rule.

### Manual Verification

- [ ] Only after measured prerequisites pass, request a human headset playtest covering picture, head, hands, controls, movement, audio and recovery over at least ten minutes. Only this establishes playable.

## Testing Strategy and Decision Checkpoints

The gate sequence is now: xrizer build (achieved) -> real initialization/guest ABI -> actual two-eye GPU output on Mac -> integrated simulator execution -> physical standalone fixture -> actual Skyrim scene -> sustained user playtest. Skyrim code feasibility and broad baseline repair proceed alongside the XR gates, not after them.

| Checkpoint | Required evidence | If it fails |
| --- | --- | --- |
| Fresh compiler/runtime baseline | Real exits, expected verdicts and strict synthetic AOT report | Isolate baseline faults with minimal reproducers; do not credit prior-plan results |
| xrizer integration proof | Actual Windows AOT guest ABI and completed D3D11/Metal stereo pair through real xrizer/provider on Mac, then simulator | Isolate ABI, provider or graphics boundary; a mock or build-only pass does not advance the gate |
| Physical standalone fixture | Signed integrated AOT/xrizer/D3D11 app; local world geometry, tracking/input and resource budgets | Fix platform/submission/input boundary while Skyrim discovery continues independently |
| Combined proof | Same fixture and runtime revision, validated frame/pose/resource contract | Resolve integration mismatch before widening features or making game claims |
| Skyrim checkpoint | Actual game harness observations at the reached level | Record the title-specific blocker; independent research remains useful and may continue |

Keep the next work bounded to a vertical slice through real xrizer: one owned Windows AOT/D3D11 fixture, System019/Compositor022 initially, one actual native provider/Metal path, then one local input mapping and explicit evidence. After three attempts without progress, or when a missing feature becomes a larger project, prepare/update a repository-local issue draft and reassess. Never post it automatically.

## Implementation evidence — 8 November 2026

Implementation is isolated in `build/worktrees/native-darwin-aot`, branch `codex/native-darwin-aot`, from clean port base `138b1731ac998c88ea911f7742b5921a2489fd4c`. Three Terra implementation agents used separate `native-darwin-mac`, `native-darwin-headset` and `native-darwin-contract` worktrees. Reviews found and corrected frame-cancellation scope, duplicate submission, texture/device lifetime and stale tracking/input issues. At initial evidence capture there had been no commits, game launch or physical device deployment. A subsequent user-requested checkpoint preserves this partial implementation with the failures and limitations recorded; no game or physical-device execution is credited to it. `SKYRIM_VR_TEST_PLAN.md` and its dirty worktree are preserved.

Evidence lives under the integration checkout's `runs/native-darwin-integration/`:

| Check | Result / scope |
| --- | --- |
| `build-final` | Both Mac runtime architectures, AOT tool and owned D3D11 fixture built |
| `unit-gpu-final` | Native queue, FPCR native-call regression, comparison/evidence/device-runner mocked tests, and actual offscreen Metal presentation passed |
| `aot-suite-final` | Semantic suite passed under Rosetta/JIT/strict AOT, including split modules, with zero fallback |
| `native-vr-final` | Owned stereo D3D11/OpenVR diagnostic fixture passed all three modes; strict AOT reported 95 entries and zero fallbacks |
| `fixture-rosetta`, `fixture-jit`, `fixture-aot` | Isolated fixture records contain artifact/source hashes, exact environment, verdict and exit status. Source snapshots alone do not establish binary build provenance |
| `xros-app-final` | Full unsigned visionOS device app built with the owned fixture; no signed/device execution claim |
| `xrsimulator-build` / `xrsimulator-app` | Simulator runtime/AOT libraries and isolated fixture app built successfully |
| `simulator-suite` | Default staging texture path aborted under Metal simulator: linear textures require private buffers |
| `simulator-suite-tiled` | Existing `VXRT_TILED_STAGING=1` path passed the full owned AOT recomp suite in visionOS simulator: threads, TLS, SEH/C++ exceptions, SIMD and actual D3D11 pixel checks; 8167 AOT entries, zero fallback. No xrizer or physical-tracking claim |
| `check-final` | Failed `kernelx.exe` memory assertion at line 135 (`ws[1].attributes == 0`); source-unmodified Rosetta baseline reproduced the same assertion in `baseline-recheck/kernelx-1.log` (one pass, one failure) |
| `check-arm64-final` | Failed `threads.exe` at +0x83f2; clean bootstrap had already failed the same area. Investigation suggests SMC/page interaction but cause is unresolved; no speculative fix applied |
| `skyrim-static` | Original images inventoried read-only and exe/OpenVR DLL statically analyzed. Skyrim has System019/Compositor022/Overlay018/RenderModels005/Settings002 strings; these are not observed dynamic requests. 78.98% of exe code-section bytes remain unexplained by analysis. No game compatibility level follows |

The native-call FPCR fix has an owned reproducer with failure on the clean implementation and success after preserving guest FPCR and clearing AH only across native calls. Existing tests and the new fixture passed, but the two broad suite failures above keep the overall baseline gate unchecked. The new compiler/graphics fixture result does not establish Skyrim execution, physical presentation, scale/floor correctness, action input, haptics or gameplay.

The current native submission adapter explicitly rejects MSAA and unsupported methods; the headset triangle is clip-space geometry. Local hand/gamepad wiring is built but unverified on hardware. Production OpenVR coverage now belongs to the xrizer port in Phase 1C. The existing fixture app remains a diagnostic artifact, not the finished xrizer-backed app.


### xrizer build-port increment

The pinned upstream source is now under the integration checkout's `third_party/xrizer/upstream/`, with Apple build adaptations and unchanged upstream OpenVR implementations. Repository-local Rust 1.99.1 was installed from the official stable manifest (2026-10-15), with Cargo/target caches under `build/toolchains/xrizer-rust/` in the main checkout. No global tool or shell configuration was changed.

A native ARM64 macOS build of the static library/dylib passed, and a native host C smoke test called the real ClientCore factory and observed explicit initialization refusal while the Apple backend is absent. This proves compilation/loading and the fail-closed boundary only. It does not yet prove the Windows guest ABI, Metal backend, OpenXR provider or any VR frame. Further target-build results are recorded in `research/2026-11-08-avp-play-xrizer.md` and `third_party/xrizer/README.md` as verified. AGENTS.md is now a concise guide to this plan, the native architecture, evidence requirements and supervised workflow, as subsequently requested.

The pinned xrizer frontend also built for `aarch64-apple-visionos-sim` and `aarch64-apple-visionos`; Mach-O platform checks confirmed simulator/device separation. The simulator bindgen target needed an explicit Apple clang triple. These are partial build-port results with initialization intentionally unavailable, not a Metal/OpenXR/Windows-ABI integration pass.

The focused prepared-input plan was added after explicit user authorization. Read-only audit/dependency reports and tools are new work after the checkpoint commits; they do not establish a game compatibility level.

### Prepared-image and systematic investigation follow-up

See `research/2026-11-08-skyrim-preparation.md` and the focused feasibility plan for pinned input identities, dependency extraction and native run observations. The `.text` relocation-callback discovery fix has an owned red/green reproducer and `aot-suite` passes. `tools/skyrim_aot_pipeline.py` adds pinned configuration, keyed build caching, build serialization and bounded evidence capture with six mocked tests; the real owned-fixture orchestration also passes (31 entries, zero fallback), while broader structural/semantic gates remain open. None of these establish a Skyrim scene or remove the outstanding broad baseline failures.

The xrizer Metal binding and typed host bridge are verified only through mocks/layout checks and cross-builds; see `research/2026-11-08-xrizer-metal-increment.md`. No runtime or compositor integration is credited. The subsequent Klepton revision is a planning change with existing-host implementation now authorized, described in its own linked subplan.

### Confirmed Klepton integration and controller target

The user selected the existing Apple host with a selectively adapted Klepton OpenXR core, and Sony PS VR2 Sense controllers for the first physical input proof. The supervised Terra boot increment is in `third_party/klepton_openxr/`: native dispatch/instance/system tests and visionOS cross-builds pass, including parent platform/hash review. UBSan-only passes; ASan also stalls on an independent minimal control and remains unresolved. The boot core has no sessions/spaces/actions/Metal, complete Rust Instance loading or xrizer frame integration. The linked XR subplan and extraction report retain these unchecked gates; no physical tracking or game capability is credited.
