# xrizer → Klepton-derived native OpenXR → visionOS


Current source checkpoint: `gseddon/Skyrim-VR-Vision-Pro`, `codex/standalone-import` (`a17ccd6`). Active agents/private builds remain in the original integration checkout during migration; see `MIGRATION.md`. Joined real Windows guest → xrizer → native provider proof is in progress; native Metal fixtures and separate guest ABI controls already pass. No game scene or physical controller acceptance is claimed.

8 November 2026. Implementation plan after source research. **User confirmed existing Apple host + adapted Klepton core; Sony PS VR2 Sense controllers first. Phase A started.** Existing AOT/compiler work continues independently.

## Outcome and architecture

Run Skyrim's OpenVR calls through native Darwin xrizer into an Apple-compatible OpenXR implementation adapted from Klepton, then local Metal/Compositor Services/ARKit. Keep the current Windows compatibility host, strict x64→ARM64 AOT and D3D11→Metal renderer. All headset execution remains standalone.

```text
Windows x64 guest, strict ARM64 AOT
        ├─ D3D11 → VXRuntime Metal textures ──────────┐
        └─ versioned OpenVR guest ABI → xrizer       │
                                      │            │
                                 OpenXR + Metal ←──┘
                                      │
                       Klepton-derived native provider
                         lifecycle / spaces / actions
                         Metal swapchains / frame clock
                                      │
                    local Apple host and frame ownership
                     Metal + Compositor Services + ARKit
```

“Apple-compatible” here means the OpenXR implementation and graphics path are compiled for Darwin and connected to Apple's APIs. xrizer still translates OpenVR to OpenXR; removing that boundary would replace a substantial part of xrizer and is not proposed. No Linux/Android guest loader, Vulkan renderer, streaming or SteamVR is required by this design.

## Research and current work

See [the source investigation](../research/2026-11-08-klepton-openxr.md). Candidate upstream Klepton is pinned to `1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32`, MIT, Max Thomas. Its actual [OpenXR runtime](https://github.com/shinyquagsire23/Klepton/blob/1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32/runtime/xr/kl_openxr.c) provides session, spaces, actions, swapchains and frame lifecycle. Its [visionOS compositor](https://github.com/shinyquagsire23/Klepton/blob/1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32/visionos/Sources/KleptonCompositor.swift) connects local tracking and Metal presentation. These are reusable source candidates, not a tested drop-in for this project.

The inspected OpenXR graphics bindings accept GLES and Vulkan; **native `XR_KHR_metal_enable` is missing**. We must implement that connection on the provider side and finish xrizer's Metal backend. The existing Metal binding and typed texture lease/copy bridge pass mock/layout tests and Apple cross-builds, but remain disconnected; initialization still refuses. No xrizer eye frame or physical presentation has been established.

AVP Play demonstrates the related OpenVR→xrizer→Klepton combination for a Linux ARM64 game. Its xrizer revision is known; its exact shipped Klepton fork revision is not established. Start from the inspected upstream pin unless a concrete needed fork patch is identified and attributed. The old local NativeARM Klepton pin is a separate input.

## Confirmed integration boundary

| Option | Benefit | Cost | Proposed choice |
| --- | --- | --- | --- |
| Adapt Klepton's OpenXR core to VXRuntime's existing native frame/tracking host; port selected Apple frontend routines where useful | Preserves the tested frame queue, renderer and AOT app; limits imported guest dependencies | Need a small explicit host interface and careful separation from `kl_ovrp` state | Selected by the user |
| Adopt Klepton's broader visionOS frontend and its frame/tracking state, replacing the equivalent VXRuntime host pieces | Reuses more upstream platform integration together | Larger dependency closure, app/lifecycle migration and repeated validation of frame ownership | Compare only if the bounded extraction spike exposes excessive coupling |

Keep one owner for pacing, tracking snapshots and frame storage. Do not run two compositor loops or maintain competing pose histories. The user selected the first route and tracked VR controllers for the initial physical input proof. The user subsequently specified Sony PS VR2 Sense. Keep unsupported or unavailable tracking explicitly invalid.

## Phase A — pinned source and bounded extraction

- [x] Research upstream code, licenses, graphics seam and host dependency closure with a supervised Terra agent.
- [x] Confirm integration boundary and first input acceptance target: existing Apple host, adapted Klepton OpenXR core, Sony PS VR2 Sense tracked controllers.
- [x] Record the selected upstream file identities, MIT notice, dependencies and local adaptation inventory. Preserve xrizer's separate GPL notices. User-authorized source reuse does not establish third-party provenance for every dependency.
- [ ] Inventory xrizer's actually required core OpenXR calls and optional extensions against implemented Klepton behavior. Mark required/missing/unsupported separately; do not treat a resolvable abort stub as implementation.
- [ ] Extract the lifecycle/space/action/frame core behind an explicit C host interface for device/queue, images, pose/input, clock and completion. Exclude JNI, Android surfaces, EGL/GL and Vulkan dependencies from the selected native build. Reuse source rather than reimplementing an unrelated OpenXR runtime.
- [x] Link a native provider entry through `Entry::from_get_instance_proc_addr`; exercise enumeration, eager Instance dispatch loading and implemented boot lifecycle. Thirty-seven additional core entries are explicitly refusal-only, not implemented semantics. Continue returning an honest error until graphics/session requirements are met.

Acceptance: bounded Mac build/link with an explicit dependency list; owned lifecycle/space/action tests through real dispatch, invalid order/handles rejected, no claimed unimplemented extensions. Stop and compare the alternative host boundary if extraction requires importing the whole guest compatibility runtime. This phase does not prove a VR frame.

## Phase B — direct Metal session and swapchain

- [ ] Add provider-side `XR_KHR_metal_enable`: graphics requirements, matching device/command queue, valid session binding, formats, runtime-owned images and typed image enumeration using Khronos layouts.
- [ ] Implement acquire/wait/release ordering and reader/producer ownership. Cover two-layer stereo arrays, supported eye subrects, sRGB/linear handling and supported sample counts; reject unsupported cases explicitly.
- [ ] Register xrizer's Metal graphics backend, replace its temporary Vulkan session only on Apple, and connect guest D3D11 textures through the existing typed lease bridge.
- [ ] Change compositor/overlay backend-copy error propagation so a failed acquire/copy/completion cannot become a successful submitted frame. Audit all affected call sites before enabling initialization.
- [ ] Use one shared Metal device and defined queue ordering. Start with the simplest correct completion scheme; optimize asynchronously only after equivalent ownership tests pass.

Acceptance: real offscreen Metal two-eye pixel checks through xrizer and the selected provider; bounds/format/device mismatch, delayed completion, cancellation and release tests. No unsignalled-fence bypass. Mock success alone is insufficient.

## Phase C — guest ABI and integrated Apple host

- [ ] Generate Windows guest-callable AOT wrappers and correct per-version vtables/FnTables for the actually needed OpenVR interfaces. Initial fixture: System019 and Compositor022; add observed interfaces separately.
- [ ] Independently verify Windows layouts, float/matrix/aggregate returns, factory/init/shutdown and callbacks. Native xrizer→provider calls use Darwin C ABI; guest→xrizer remains a distinct boundary.
- [ ] Connect the selected host's Compositor Services clock, ARKit predicted views/reference spaces, session events and local input through the provider. Carry render frame/pose IDs to display; distinguish repeats from new frames.
- [ ] Adapt selected Klepton tracking/controller and compositor routines where they fit. Reconcile game-specific offsets, projection/reprojection conventions, session loss and stale state with the actual host contract.
- [ ] Run the same strict Windows AOT/D3D11/xrizer fixture on Mac, then the installed visionOS simulator; validate actual pixels and positive AOT counters with zero fallback. Simulator staging requirements and tracking limits remain explicit.

Acceptance: one owned guest submits a verified stereo pair through real xrizer, real provider and local presentation path. No competing custom production OpenVR adapter, renderer rewrite or fabricated SteamVR connection.

## Phase D — physical proof and Skyrim join

- [ ] Once separately authorized, install/launch the signed integrated owned fixture on physical Vision Pro. Verify metre-scale geometry, eye transforms, head motion, origin/recenter, the selected input mapping, pause/resume and tracking loss without a Mac helper.
- [ ] Measure target-device address reservations, memory and GPU lifetime before large game packaging. Mac DLL bases are not automatically valid device mappings.
- [ ] Join the independently progressing Skyrim AOT path only after both it and the XR fixture reach their relevant gates. Record actual requested interfaces and first game frame/menu/scene separately.
- [ ] Extend to overlays, haptics, additional formats/MSAA, saves/audio/scenes and sustained user playtesting according to observed requirements.

Acceptance: physical standalone fixture first; actual game scene and human playtest remain separate gates. Keep existing broad runtime failures visible until resolved.

## Work ownership and supervision

Use bounded Terra tasks: provider extraction/Metal runtime, xrizer graphics/error handling, and guest ABI/fixture. Assign exclusive files and agree the C boundary first. Checkpoints within three minutes; inspect after two failed approaches and stop the failing loop with evidence after three. Serialize shared AOT scratch, simulator/device launches and GPU checks. Each increment records source/patch identities, commands, actual verdicts/exits and remaining unknowns.

## Confirmed decisions and first input target

The user confirmed adaptation of Klepton's OpenXR core to the existing VXRuntime Apple host and Sony PS VR2 Sense controllers for the first standalone input fixture. No broad host migration is scheduled. Controller-specific bindings and physical validation remain unimplemented; hardware selection does not imply that pairing or tracking has been tested.

A supervised Terra task now owns the isolated provider extraction under `third_party/klepton_openxr/`. The parent owns plans and root notices. No physical-device installation or launch is implied by the implementation decision.

### Sony PS VR2 Sense acceptance

Use GameController for connections, buttons, sticks, triggers and supported haptics, and ARKit accessory tracking for local poses. Apple documents Sense support, aim/grip locations and the custom-renderer tracking route in [Explore spatial accessory input on visionOS](https://developer.apple.com/videos/play/wwdc2025/289/). Add the required accessory tracking usage description and spatial gamepad support to the selected app when implementing that adapter.

Prove independent left/right identity, grip and aim transforms, prediction time, tracking validity/staleness, disconnect/reconnect, stick/trigger/grip/buttons and supported haptic delivery. Use actual local accessory state, never a fixed pose or hand anchor substituted for a tracked controller. The current `VXNativeInput.swift` uses hands plus a gamepad and does not satisfy this gate. Simulator and injected-state tests can check mappings and invalidation, but only physical Sense controllers establish tracking/input behavior.

### Phase A boot checkpoint

`third_party/klepton_openxr/` now contains pinned MIT reference source, selected native adaptations, official Khronos types/notices, source hashes and a small serialized host-availability boundary. The owned native bootstrap/instance/system fixture passes; macOS and both visionOS archives build with warnings treated as errors. Parent review checked all recorded source hashes and simulator/device Mach-O platform tags. See `research/2026-11-08-klepton-extraction.md`.

This is a partial Phase A increment: no session, space, action, frame or Metal implementation, and no complete openxrs Instance dispatch load or xrizer integration. Keep Phase A acceptance unchecked. UBSan-only boot validation passes. ASan remains unresolved: it also stalls on an independent minimal control, with bounded attempts recorded separately. The combined sanitizer check is not accepted. Next extraction must implement real core dispatch/lifecycle behavior and the host boundary needed for Metal, preserving unsupported-feature errors.

### Continuing supervised work

Terra `/root/terra_xrizer_metal_lane` continues provider lifecycle, spaces and frames; AOT `/root/inspect_native_vr` independently resolves observed native startup blockers. AVP Play's packaged fork was identified as `klepton-toolchain-866-e65c433.tar.gz` from v1.10.7, with archive SHA-256 matching its manifest. Its full Git SHA is not established. It provides useful Sense/input/prediction changes, but still lacks Metal and includes timeout/fence bypass paths that violate the accepted completed-frame invariant. The agent found no new key user decision; retain the selected architecture.

The provider now passes native Rust Entry/Instance loading, property/path/action-set tests, injected session event/acknowledgement tests and image acquire/wait/release ownership tests. Test-only Metal session/swapchain resource allocation is connected to actual Apple MTL objects in an owned offscreen fixture: two array layers clear/read back correctly, provider allocation/teardown and errors pass. `src/metal_host.m` also cross-compiles for simulator/device. Production Metal capability remains withheld until frame ordering/completion/publication is implemented. No physical tracking, controller mapping, xrizer eye frame or game scene is credited. Evidence and source snapshots are under `third_party/klepton_openxr/evidence/` and ignored build directories.

### Native frontend join checkpoint

Actual `owned-apple-test` xrizer now initializes successfully through the real native provider/Metal binding in snapshot `xrizer-frontend-bwwk2x`: System019 reports the injected8x8 configuration, Compositor022 is retrieved, and host-acknowledged STOPPING/drain/EXITING cleanup succeeds. This is native ABI and injected lifecycle only, with no texture copies, Windows guest calls or physical headset. Earlier snapshots preserve actual view-metadata and session-readiness refusals. The next active task is a real stereo pair through xrizer; first fixture uses the legitimate zero-count WaitGetPoses form and therefore does not cover caller pose arrays or controllers. Generic/input-driven session restart and error retry remain explicit implementation risks; production Init is still disabled.

The separate AOT lane now directly observes original Valve error110 (missing OpenVR path registry) and subsequent error109, explaining its `BSOpenVR` null member. It is preparing a Windows member/FnTable aggregate-return ABI proof before the real native frontend can be exposed to the game. No more unchanged SteamVR-style startup retries are scheduled.
