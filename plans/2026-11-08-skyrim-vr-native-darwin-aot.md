# Skyrim VR native Darwin AOT implementation plan

Date: 8 November 2026 (Europe/London)
Status: probe 044 (a game run on the dev host; not a headset) lives past the old crash. Skyrim's `.ini` files were never read: `GetPrivateProfileString*`/`Int*` were stubs returning the default, so the game used its built-in archive list, never opened `Skyrim - Meshes0/1.bsa` or any `Textures*`, and crashed at `SkyrimVR.exe+0x27c743` calling a null 3D node on a `TESObjectREFR`. Reading `.\Skyrim.INI` now opens all 19 archives, and the 60-second run (1,858 `offscreen fresh pair` lines, 1024×1024 per eye, no `unhandled exception`, the last AOT summary 0 fallbacks) no longer crashes. Eye pixels are the Bethesda logo for about 150 frames and then fully transparent black while the game loads its data. In probe 048 (200 s, dev host only, `--experimental-xrizer` allows up to 300 s) the eyes first change about 90 s after launch and from frame about 4200 show Skyrim's own loading screen (a `Level 1` bar, the Black Sacrament quote and a fog background, 46% non-black) unchanged to the end of the run, about 70 s. No world scene, menu or tracking has been shown and playability is unproven. The previous crash is gone but one run is a small sample, and start-up still fails intermittently (a refused `CoCreateInstance` `{5A508685-…}` null call, or a strict-AOT miss at `+0x138afb8`; about one run in two). Earlier: probe 032 delivered Skyrim's eye pairs to the dev host (the opt-in `--dev-synthetic-stage` floor fixed Standing → STAGE with `stage_valid` 0).

## Current continuation checkpoint

Candidate 14 was built and validated against owned null snapshot check (25 AOT entries, 0 fallback) and joined guest stereo fixture (107 AOT entries, 0 fallback). Actual game probe 012 verified that the single-part table sentinel fix resolved the false null-call exception from probe 011; Skyrim advanced through OpenVR Compositor acquisition, event polling, and complete D3D11 rendering initialization with 3.49M entries before stopping strictly on an un-translated MMX block in Bink video playback (`binkw64.dll+0xe1de`). The 12-row ledger validates with head `ff959c89b6395fcf266ea1590a119d3e9b1ea2c1992a0560ffa917ee6036f2b9`. The reached Bink block's MMX subset now translates. Owned guest `xrizer_guest_mmx` matches Rosetta's data results; on Candidate 14 strict AOT it also checks x87 tags, the destination exponent, and preserved control/MXCSR/flags/XMM (3 entries, 0 fallback). Rosetta's FXSAVE image does not show the MMX alias and that reference exits 2. Private Bink regenerated to 9800 blocks and 53 refusals; `0xf0000e1de` and `0xf0000e1f0` are absent. The previous EMMS module `23787be6…` is unchanged. New module SHA `1681bdabe14785f141f563d0ed8393db34a1e69ae65d386a80a76324f639e2ec`. Probe 014, with `--trace-null-target`, stopped at `SkyrimVR.exe+0x137ff67` calling `UuidCreateSequential` after 7,726,663 entries and zero fallback. Ledger head `0200073cc723f6383cc080c7f41b09ad9288af8437cc802b4fe35c85f4436af8` (14 rows). `UuidCreateSequential` now returns a version-1 UUID: RPC_S_OK when a unicast adapter address is available, otherwise RPC_S_UUID_LOCAL_ONLY (1824) with a multicast node. A null pointer returns RPC_S_INVALID_ARG (87). Owned guest `aot_uuid_sequential` on Candidate 14 exits 3 and names `RPCRT4.dll!UuidCreateSequential`. The same guest on the new host `VXRuntime/build/terra-uuid/vxrt-arm64` (`15230a71…`, helper `1a0555fa…`) prints the success verdict: 7 AOT entries, 0 fallback. Probe 015 used that host, the unchanged `aot-mmx` modules, the same xrizer dylib, and `--trace-null-target`. `UuidCreateSequential(0x136103e70)` from `0x14137ff67` returned 0. The harness killed the process at 40 seconds (return -9) during a repeating `SetupDiGetClassDevsW` / `SetupDiEnumDeviceInterfaces` loop (enum returns 0, last error 259). Ticks at 4,194,304 and 8,388,608 entries both report zero fallback. No exit summary was written. Ledger head `bfe000cd…` (15 rows). This probe does not explain the untraced probe 013 fault at address 0. The 21 ordinary misses on those already-loaded DLLs (`SkyrimVR.exe` 20, `binkw64.dll` 1) are now implemented and covered by `aot_loaded_imports`. On host `VXRuntime/build/terra-imports/vxrt-arm64` (`722807714c44a44df22683b39aa063bb898b8209fddf7ba33d3c92eb4be1fe00`, helper `1a0555fa…`) that guest exits 0: 116 AOT entries, 0 fallback. Probe 016 used that host, the unchanged `aot-mmx` modules, the same xrizer dylib, and `--trace-null-target`. No loaded module logged a missing-import summary. The harness killed the process at 40 seconds (return -9). The traced thread was still in `SetupDiGetClassDevsW` / `SetupDiEnumDeviceInterfaces` from `SkyrimVR.exe+0xc67518` (enum returns 0, last error 259) and a second thread was calling `VirtualFree`. Ticks at 4,194,304 and 8,388,608 entries both report zero fallback. No exit summary was written. Ledger head `3d692e0a0e2e9c2114c6e5cdc652612985b2013ee31240ee517dc9c9617572c9` (16 rows). Filling those imports did not move the process out of that enumeration loop. `WSAAsyncSelect` makes the socket nonblocking and returns 0; it does not post `FD_*` window messages. `WritePrivateProfileStringA` returns 1 and does not store the ini. `waveOutSetVolume` returns `MMSYSERR_NODRIVER` for a null handle and `MMSYSERR_INVALHANDLE` otherwise. The `_p` printf forms do not reorder a positional `%1$` specification. Probe 017 rebuilt the import host with the ARM64 call ring (`VXRuntime/build/terra-imports/vxrt-arm64`, `77a8e034a5606c1d26e5992ab2a051e55f9548ad43e9268d0cfd0d22d82f4dab`) and dumped each thread's last runtime calls at 35 seconds. Render thread `68615031` was still inside `ctx_draw_indexed(0xa05288500, 6, 0, 0)` from `SkyrimVR.exe+0xdbde0f` and had not returned since about 26 seconds earlier. The main thread was spinning in `Sleep(0)` from `+0x5b68f8`. Bink thread `68615035` was inside `WaitForSingleObject` from `binkw64.dll+0x169d5`. Worker threads were parked on infinite waits from `+0xc79b76` and `+0xc80783`. The SetupDi thread was mid-poll and returned after the dump. Thread `68615034` was still copying and calling `VirtualFree`. The harness killed the process at 40 seconds (return -9). Ticks at 4,194,304 and 12,582,912 entries both report zero fallback. No exit summary was written. Log `build/xrizer-game-017/startup.log` SHA `1ed29f31d4eb07765eb670ee296551a0d4c3f30f5acf17c0e1db0864b83a91d6`. Ledger head `398c149f1dc0e57af724d8cecac8b9925369a09add47bc4af825140e49ab85d6` (17 rows). The recorded worktree patch hash `3fab2eae…` is the temporary harness copy that added `--trace-call-ring`; that checkout was restored to `b4a0d02` afterward, and both ends of the run saw that same copy, so `source_unchanged` is true. Probe 018, the same host without the call ring, returned from that `DrawIndexed` in the same millisecond and aborted in `IVRSystem_019` slot 2 (`GetProjectionRaw`) from `SkyrimVR.exe+0x8ffb3e`. Return -6. Exit summary 3,702,901 entries, zero fallback. Ledger head `379fb7f1…` (18 rows). The 26-second draw wait was on the ring-enabled host. `GetProjectionRaw` and `CanRenderScene` now forward to the native xrizer methods. Host test `xrizer_projection_raw` checks both, plus the FnTable raw slot, against a fake native table. Probe 019 on host `3859c989…` got past `projection_raw` for both eyes and aborted in `IVRCompositor_022` slot 24. Return -6. Exit summary 3,947,781 entries, zero fallback. Ledger head `bfef4667…` (19 rows). Probe 020 on host `46fd1e96…` gets `can_render_scene` = 1, `WaitGetPoses` = 0, and `Submit` for both eyes. Every observed `Submit` returns 102. The dev host then logs `cancelled frame`. The process exits 5. The main thread raises `0xc0000005` at `SkyrimVR.exe+0x27c743`, reading address 0 (`rax` 0, `rcx` 0). Exit summary 71,303,169 entries, zero fallback. Ledger head `cf45eb92…` (20 rows). Worktree patch hash is the empty-tree hash. Probe 021 on host `48687c2e…` and the previous dylib `71aed917…` logged the texture and `acquire accepted`, then `Submit` still returned 102. Probe 022 uses host `0e592296…` and dylib `082c3906…` (`gamma-unorm-70`, the pinned snapshot plus the Gamma/UNORM check). Both eyes copy and `Submit` returns 0, then `WaitGetPoses` returns 1 and the following `Submit` returns 108. Exit summary 67,108,866 entries, zero fallback. Immediate next focus: why that completed pair does not finish the frame. Terra B's simulator execution check remains open.

## Overview

Recompile the user's Windows x86-64 Skyrim VR code ahead of time into ARM64 code for a native Darwin host. Reuse VXRuntime's existing static recompiler and its D3D11-to-Metal implementation. Develop and investigate macOS execution and fully standalone Vision Pro execution in parallel, then integrate the same test program and runtime contracts across both platforms.

This is a fresh plan. No completed stage, source fix, baseline or game result from `SKYRIM_VR_TEST_PLAN.md` is credited toward acceptance here. Preserve that document and its existing worktree; use inspected source as reusable infrastructure, with new verification on the selected implementation revision.

## Active Priority: Prepared-input Skyrim Feasibility

The user selected the Android-style preparation/discovery/translation workflow and explicitly authorized unpacking private working copies of their owned game. Follow [the focused feasibility plan](2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md) for the game/compiler lane. The user subsequently requested supervised XR work in parallel, and now requests a researched Klepton-based plan and confirmed the existing Apple host with Sony PS VR2 Sense controllers as the first input target. It defines input validation, dependency closure, artifact identity, semantic tests, strict startup and iteration gates. The original Steam installation remains read-only. AGENTS.md now records this authorization; the prior DRM-removal exclusion is removed. Steamworks responses and anti-cheat are not to be fabricated or bypassed.

Pinned Steamless successfully prepared a private image: unexplained executable-section bytes fell from 78.98% to 0.86%. The old Valve error110 initialization stop has been superseded by real native xrizer initialization, D3D11 device creation, WaitGetPoses and event polling. Probe008 stopped strictly at a Bink EMMS block discovered but refused during translation; an owned semantic proof and narrow emitter fix now cover it. Latest probe009 reproduces the separate native crash with SP below its recorded stack bound. The active round below records counters and current investigation. The earlier no-image address was classified as a missing import stub. Original inputs remain unchanged. A game stereo image, menu, scene and complete game-code semantics remain unproven. See the focused plan for evidence and the systematic build/probe workflow.

The confirmed XR revision reuses selected Klepton OpenXR and visionOS host code behind native xrizer, adding the missing Metal binding while retaining D3D11→Metal. See [the xrizer/Klepton workstream](2026-11-08-xrizer-klepton-native-openxr.md). The user confirmed this boundary; the experimental frontend/provider now passes owned guest integration, while connected input and the physical host remain incomplete.

## Source control and active checkout

The source-only checkpoint is published in `gseddon/Skyrim-VR-Vision-Pro`, branch
`codex/standalone-import`, initial commit `a17ccd6`. The new checkout is
`/Users/gseddon/git/Skyrim-VR-Vision-Pro`. The approved round now uses three Terra worktrees inside this new repository;
see `MIGRATION.md`. The previous VeRantyx implementation checkout is a read-only
reference for private artifacts and immutable evidence. Private game inputs, translated game code,
toolchains and raw run evidence remain local. One source repository is sufficient.

## Approved next implementation round

This section is the current work order; later phase descriptions retain the
longer project scope and historical evidence. The user approved this round and instructed implementation to begin. All implementation roles use
`gpt-6.1-terra`; the parent coordinates, reviews and integrates. Completed
historical workers on other models remain idle.

### Active assignments

- Terra A `/root/terra_guest_stereo_round2`: `build/worktrees/terra-guest-stereo`.
- Terra B `/root/terra_pose_input_round2`: `build/worktrees/terra-pose-input`.
- Terra C `/root/terra_skyrim_aot_round2`: `build/worktrees/terra-skyrim-aot`.

All three launched from approved plan commit `8eb61b4`. A and B continue as
Terra implementation workers. C completed six bounded game probes and then
stopped after automatic content review twice rejected its turn, citing possible
cybersecurity risk. The parent now performs ordinary local build/probe
orchestration in C's checkout; that worker remains stopped. No review bypass or
non-Terra implementation worker was introduced.

### Verified round progress

- Guest graphics/ABI: the exact game-facing six-export Windows guest, real
  xrizer/provider, normal 1024 recommendation and normal consumer pass two
  changing 4x3 pixel/crop pairs, nonzero Seated poses, pre-frame optics with
  zero tickets, Standing-invalid cancellation and balanced GPU/resource
  lifecycle. Property, unavailable DXGI adapter and empty hidden-mesh wrappers
  pass guarded MSVC ABI tests. These are owned offscreen Mac results.
- PollNextEvent: the actual game passes a 48-byte event structure, unlike the
  latest pinned Windows header's 64 bytes or Darwin's 60-byte layout. The
  candidate12 owned guest passes real HMD activation event conversion, short/
  null controls and canaries, plus the earlier stereo/lifecycle checks:
  **107 AOT entries, zero fallback**. Its source checkpoint and evidence are integrated; actual probe008 now passes
  event polling and exposes the next Bink code-discovery gap.
- Pose/input and Apple host: raw Sony Sense observation/mapping controls and
  unsigned device/simulator app builds pass. The static host adapter now passes
  an actual native xrizer/Metal fixture with two stereo pairs, held/repeated
  reader leases, two no-render zero-layer frames and clean drain (`xFA4vt`).
  Real host clock/tracking, connected input and physical presentation remain
  unproven; isolated simulator static archives/link probe passes. Existing-app simulator
  integration now executes an explicitly injected offscreen guest: 43 AOT
  entries, zero fallback, two source-pair pixel/ID checks and clean lifecycle.
  The actual simulator drawable supplies one view/texture; real stereo optics
  readiness refuses, and stereo presentation remains unproven. Review and
  corrected optional packaging-target verification are in progress.
- Native-fault diagnostics: an owned real-SIGBUS control verifies raw fault
  registers plus cached native stack bounds/thread ID before logging/unwind.
  Shallow/deep callback controls pass. This is observability, not a fix for the
  intermittent actual-game crash.
- Required regressions remain **red**. AOT semantic suite passes (8167 entries,
  zero fallback, unsplit and split); broader checks stop at fiber-pool,
  presentation snapshot or intermittent kernel memory assertions. Old/new
  paired presentation controls reproduce the 14 snapshot failures on both
  runners. Later tests, including D3D12, were skipped when earlier checks failed.
  No baseline failure is waived by these fixture successes.

### Actual game follow-up in this round

Ten bounded native-backend probes are sealed in C's local ledger. They have
advanced through real xrizer initialization, both pre-Wait eye transforms,
the documented unavailable DXGI index -1, successful D3D11 device/swapchain
creation, real Compositor022 acquisition and **WaitGetPoses returning 0**.
Probe `xrizer-game-007` stopped intentionally at the then-unsupported method,
System019 slot30 PollNextEvent. It reports **3,539,503 AOT entries, zero fallback
requests and zero missing addresses up to that stop** (`o5`, `o8`, `o9`, `o12`).
Probe008 passes the owned-tested event wrapper (actual size48 true then false),
then strict dispatch stops at **binkw64.dll+0x1d48** in a loaded, hash/base-matched
AOT image. It reports **3,351,147 entries, one fallback request and one missing
address** (`o5`, `o6`, `o9=false`), with no translator execution. This fails
zero-fallback acceptance. Terra A proved this was legacy EMMS translation refusal, not discovery. The
strengthened owned state fixture passes with zero fallback on unchanged C12;
the affected Bink module alone was regenerated (9752→9753 blocks, 95→94
refusals). The other refusals remain unsupported/unclassified.
These are synthetic-head/disconnected-controller Mac diagnostics, not physical
tracking or rendered game scenes.

Probe009 loaded the changed Bink module but reproduced the native SIGBUS at
pthread_once before establishing passage through the EMMS leaf. Its raw fault
record gives SP 240 bytes below cached native stack_low and fault address 224
bytes below it. This strongly supports native stack/guard exhaustion as the
immediate mechanism; the stack-consuming call path and root cause remain
under investigation. Do not fix this by guessing a larger stack.
Probes001/002/004/006/009 lack AOT summaries; their entry/fallback totals remain
unknown. Probe010, with explicit depth limit4 after a managed-worker control,
stops at depth5 and exposes repeated null-target callback entry after an
original vtable call. It reports 3,053,700 entries and zero fallback up to the
diagnostic stop. Source triage identifies an uninitialized AOT-cache hit at
RIP0; an owned null-vtable/Windows execute-AV fix is in progress. Why the
original object supplied a null target remains separate and unknown. Probe005 used an explicit callback-depth
diagnostic and is not normal-depth acceptance. No compositor Submit, game
stereo frame, menu, scene or physical headset playability has been established.
See `research/2026-11-08-skyrim-native-bootstrap-round2.md` for exact identities,
run scope and validation. Continue with one changed probe after the affected
compiler/module change passes its owned control and the candidate/source inputs
are pinned. Inspect any new fault's raw context before proposing a stack or
renderer change.

The no-JIT requirement concerns CPU/game code. The existing selected
D3D11-to-Metal renderer retains supported Metal GPU shader compilation; no
new offline-shader packaging prerequisite is introduced here.

### Outcome

Connect the real prepared Skyrim executable to the same native XR stack that
passes the owned fixture, then measure the next actual game checkpoint or
precisely diagnosed blocker. First prove guest D3D11 stereo and repeatable pose
calls so the game does not become the test harness for an unverified bridge.
This round does not promise a menu, scene, physical controller or playable game.

### Three Terra roles and exclusive ownership

| Role | First assignment | Exit evidence | Ownership |
| --- | --- | --- | --- |
| A — Guest stereo and reusable ABI bridge | Extend the verified MSVC guest to create actual D3D11 eye textures and call real xrizer Submit through static Windows wrappers. Resolve guest resources through the validated D3D11 registry; use the actual device/queue, producer completion and destination completion. Extract reusable wrappers needed by the game. | At least two changing stereo pairs with independently checked pixels/crops, frame/pose IDs, matched leases and drained cleanup; positive strict-AOT counters and zero fallback. Invalid handles/device mismatch and a meaningful failure/retry control must fail honestly. | `VXRuntime/tests/xrizer_guest_*`, new reusable `VXRuntime/src/xrizer_guest_*` bridge files, component `tests/xrizer_guest_host.*`/shared fixture helpers, and Apple Metal resource adapter `src/metal_host.m`/`include/apple_metal_host.h`. No loader or Rust/provider-core edits. |
| B — Repeatable poses and input semantics | Continue real xrizer/Klepton action/space work. Make remaining initialization, legacy action/binding and frame-update failures fallible. Implement the actually required action/binding/state subset using explicit host snapshots; unconnected controllers remain inactive. Preserve real sample time, origin and tracking validity. | Repeated nonzero pose calls through actual xrizer, including changing valid/invalid head samples, disconnected controllers, unsupported-feature refusal, frame cancellation and cleanup without panic or stale input. Remove guards only for paths covered by these tests. | `third_party/xrizer/**` and `third_party/klepton_openxr/**`, excluding A's helper/resource files. Provider host contracts are owned here; A/C request changes through this owner. Sony Sense host wiring follows the agreed contract; physical tracking remains a separate gate. |
| C — Actual Skyrim startup and AOT feasibility | Audit the exact game bootstrap exports/interfaces; wire loader exports to A's reusable bridge, preserving real factory/init/errors. Prepare pinned private inputs/configuration in the new source checkout. While A/B progress, test that routing with owned callers and investigate the recorded callback fault or broad regression only through bounded, relevant reproducers. | After the relevant A/B gates, an actual bounded strict-AOT Skyrim run with sealed input/compiler/runtime/module identities, actual exports/interfaces, earliest reached checkpoint and first blocker. Reduce each new code/API/ABI defect to an owned reproducer, fix it, then remeasure. Missing counters remain unknown. | `VXRuntime/src/loader.c`, new game-facing OpenVR export routing, compiler/dispatch and observed Windows compatibility fixes, `tools/skyrim_aot_pipeline.py`, `tools/vxrt_native_startup.py`, their tests and game investigation reports. No second OpenVR implementation or direct native pointers in guest tables. |

The parent owns Makefile/build/scanner integration, shared test scheduling,
plans and root provenance/notices. Delegate specific build edits to one Terra
owner at a time. Cross-owner changes are requested and integrated explicitly;
no two agents edit the same file. Keep a maintained bootstrap method list:
System019/Compositor022 are established starting versions, not full coverage;
other version strings become implementation work only when actually required.

### How the lanes join

1. **Agree the integration contract first.** A/C agree how the reusable static
   guest objects/export routing compose; A/B agree device/queue identity,
   texture lease/completion and frame/pose snapshots. Freeze a small versioned
   boundary before independent implementation. Preserve default fail-closed
   behavior; any development provider is explicitly selected and labelled.
2. **A and B execute independent owned proofs.** A may initially use zero-count
   pose arrays and an injected Mac host to isolate actual guest texture/Submit
   behavior. B proves real nonzero pose semantics separately. Neither proves
   physical tracking or Skyrim compatibility.
3. **Join A+B at one reviewed revision.** Repeat the owned Windows D3D11 stereo
   fixture using actual nonzero pose arrays across multiple frames, supported
   inactive-controller behavior and teardown. Run applicable owned regressions
   and required runtime checks; preserve unresolved broad failures explicitly.
4. **C advances the game immediately once its needed calls pass.** Run the
   original game code from the private prepared image through the proven
   native backend on Mac. Record actual initialization, first eye submission,
   menu/scene or exact first failure. Fix demonstrated causes and repeat; no
   unchanged error110 retries, fabricated success or patched game null checks.
   Reuse unchanged hash/base-matched AOT modules; do not regenerate the whole
   game for an unrelated host fix.
5. **Continue toward standalone in parallel with game fixes.** After Mac
   integration, A carries the same owned fixture into visionOS simulator while
   B connects real Apple-host clock/tracking/input and C continues game
   feasibility. Simulator success is separately labelled. Stage a concrete
   integrated device fixture before requesting physical install/launch approval.

Actual game progress does not wait for full Sony Sense hardware acceptance or
a complete OpenXR implementation. A development run may use explicitly
injected head state and genuinely disconnected controllers, once its reachable
calls are safe; this establishes only that development checkpoint. If the game
requires an unsupported method, stop at that call and implement/test its real
semantics. Standalone physical acceptance still requires actual local tracking,
controllers, lifecycle and target-device resource measurements.

### Workspaces, cost and continued supervision

- Start new work from the published standalone repository, current checkpoint
  `fc17152`, plus this approved plan. Use dedicated `codex/` branches/worktrees
  with isolated outputs and integrate stable commits into the source repo.
  Preserve the old checkout and immutable evidence as read-only references.
  Copy only required pinned private inputs; reuse existing local toolchains
  and immutable artifacts via explicit paths where supported. Do not relocate
  credentials, originals or old evidence, or rebuild large subjects needlessly.
- Launch at most three Terra workers, with the parent as the fourth active
  slot. If the prior session thread limit still prevents new Terra agents,
  reuse the existing Terra worker and queue the roles; report the constraint
  rather than silently using another model. Never restart the old non-Terra
  workers for implementation without the user's agreement.
- Require a first checkpoint within three minutes, then inspect progress at
  least every three minutes. A checkpoint identifies a result or concrete
  progress, next test and blocker; a long compiler run reports progress instead
  of starting duplicate builds. Parent progress updates remain concise.
- Serialize GPU/runtime/simulator tests and fixed AOT scratch; parallel source
  work and isolated builds only where they do not conflict. Run one integrated
  regression batch per meaningful candidate rather than repeating full builds
  in every lane. Record source-to-binary provenance as the candidate is built.
- After approval, workers continue through the next dependency-ready assignment
  instead of stopping after each small fix. The parent reviews/checks/publishes
  verified checkpoints and assigns the next bounded task. After two failed
  approaches, narrow or redirect; after three no-progress attempts, document
  and stop that loop while independent work continues. Architecture changes,
  new out-of-scope downloads or physical-device actions come back to the user.

### Review points

The first meaningful review is the joined guest D3D11/pose fixture; the next is
Skyrim's first measured result with native XR. Neither has a reliable time
estimate yet. New compiler/code-discovery limitations, unavoidable runtime code
generation or a launch requirement conflicting with standalone execution are
make-or-break findings and should be surfaced immediately. Existing callback
and broad D3D12 failures remain visible until reproduced/classified and fixed;
fixture progress does not waive them. Only the later physical human playtest
can establish playable.

## Current Position and Next Acceptance Gates

Updated after the xrizer decision and Apple cross-builds on 8 November 2026. The active-priority subplan above now determines immediate work order; this section and the phase sections retain the full XR integration scope and evidence. Earlier diagnostic results remain useful but are not xrizer acceptance.

| Area | Established | Still to prove |
| --- | --- | --- |
| AOT / Windows compatibility | Owned CPU/D3D11 suite passes strict AOT on Mac and in visionOS simulator; actual MSVC guest scalar/float/matrix static-wrapper tests pass with zero fallback | Complete observed interface coverage, guest/provider stereo and clean broad runtime baseline |
| D3D11 / Metal / native frame exchange | Owned Windows guest stereo passes pixels, poses, ownership and normal development-host consumption; static Apple adapter passes native Metal/no-render lifecycle | Integrated simulator/physical presentation and input; unsupported formats/origins |
| xrizer Apple port | Owned guest path initializes, queries nonzero poses and submits stereo through the provider; ordinary initialization remains disabled | Real Apple-host integration, connected input, broader interface coverage and recoverable session replacement |
| Skyrim VR | Private prepared code/modules; actual native xrizer init, D3D11 device creation and WaitGetPoses; event polling; prior 3.54M-entry zero-fallback checkpoint | EMMS gap has owned fix; latest game SIGBUS has SP below native stack bound; game stereo/menu/scene, input and performance |
| Physical Vision Pro | Unsigned device/simulator apps and raw spatial-controller collector compile | Integrated xrizer execution, signing/install/launch, resource budgets, local stereo/tracking/input/audio and sustained operation |

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

- Prepared-image analysis now leaves 0.86% of executable-section bytes unexplained; the earlier 78.98% figure describes the wrapped original. Neither number establishes executable-path completeness. Metadata gaps, refused blocks, callback discovery and instruction/ABI semantics still require measured investigation. The earlier no-image stop was classified as a missing Windows import. Current startup passes native event polling; the Bink EMMS translation gap has an owned fix, while the latest actual probe captures SP below the native stack bound at SIGBUS. Its root cause remains unresolved. Actual scene execution remains the game feasibility gate.
- Broad checks remain unresolved: the latest Rosetta and ARM64 candidate runs fail in D3D12 native object release; baseline/regression classification requires an equivalent control. Earlier released-memory and thread/SMC failures were also observed. Isolate and fix with reproducers. These block declaring the broad baseline accepted, but do not require stopping independent source work. A JIT-specific failure and strict-AOT correctness must be measured separately.
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


### Planning checkpoint: real guest/provider join

The owned MSVC guest → static AOT wrappers → real xrizer → native provider
Stage1 fixture now passes: actual initialization, System019 member/FnTable
matrices, honest nonzero-pose/input refusals, empty-frame cancellation and
cleanup, with 33 AOT entries and zero fallback. It performs no source texture
submission or drawing. See `research/2026-11-08-xrizer-guest-abi.md` and the
source checkpoint provenance. The next joined proof is actual guest-created
D3D11 textures, real producer completion and verified stereo pixels. Nonzero
poses/controllers, visionOS integration, broad runtime failures and actual
Skyrim remain open. Agents paused safely for the user's planning session;
new implementation work should prioritize Terra for cost.
