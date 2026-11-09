# Standalone Skyrim VR: Terra investigation continuation plan

Date: 8 November 2026, Europe/London. Status: user approved execution; supervised Terra continuation started at 16:18 UTC on 8 November 2026.

## Overview

Continue toward fully standalone Vision Pro execution using VXRuntime strict ARM64 AOT, Windows compatibility, the existing D3D11→Metal renderer, native xrizer and the Klepton-derived provider over the existing Apple host. A Mac may prepare/install artifacts; headset execution must not require a helper, streaming or external SteamVR.

This is the next bounded work order under [the architecture plan](2026-11-08-skyrim-vr-native-darwin-aot.md), informed by [the handoff](../handoffs/2026-11-08_16-07-15-standalone-skyrim-vr.md). It supersedes older immediate-task/status rollups, not architecture decisions or unfulfilled acceptance gates. Keep the [feasibility plan](2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md) and [XR subplan](2026-11-08-xrizer-klepton-native-openxr.md) as supporting scope.

## Current state and evidence

Read-only verification by three `gpt-6.1-terra` agents and parent source inspection established:

| Subject | Current checkpoint | Limit |
| --- | --- | --- |
| Source | Integration checkout `/Users/gseddon/git/Skyrim-VR-Vision-Pro`, branch `codex/standalone-import`, HEAD `67aea57`, clean before this plan | Handoff's `5c07f69` is the source checkpoint before its own commit |
| Actual Skyrim | `terra-skyrim-aot` at `e1d0f5b`; game011 result validation passes; ledger verifies 11 rows, head `40ae4aafbdc127a65ec51ef58d4000eb3dc682129aadd3dc7d39a946a39186fd` | Game011 exits5 at guest AV address0; no AOT summary, so totals unknown; no game stereo Submit, menu or scene |
| Runtime fix | Null TLS-cache hit is fixed; candidate13 passes owned execute/read/write exception continuation and prior joined stereo controls | Does not explain why the game's object has a null virtual target or resolve every historical crash |
| Diagnostics | A checkout `1a3a733` retains failed snapshot5 plus unrelated optics edits | Two capture placements failed; exit0/10 entries/zero fallback did not satisfy snapshot assertions; no game012 |
| XR | B checkout `896c7d2`; reviewed commits `e86df82`, then `896c7d2` await integration | Branch-specific simulator proof is not proof of merged source |
| Simulator owned fixture | B's `UjBVTn`: 46 entries/zero fallback, two independently audited offscreen cropped pairs, four completed copies, 12/12 source leases, lifecycle1/1/1 | Injected calibration/head, disconnected input; mono drawable stayed clear; no physical stereo/tracking, OS-driven pause or Skyrim proof |
| Baseline | AOT suite main/split proofs exist; broad checks remain red | Fiber migration, released-memory, presentation snapshot and thread-area failures remain unresolved; skipped tests are not passes |

Evidence sources: [bootstrap through game011](../research/2026-11-08-skyrim-native-bootstrap-round2.md), [null-vtable report](../research/2026-11-08-aot-null-vtable.md), [regression evidence](../research/2026-11-08-runtime-regression-round2.md), [Bink refusal detail](../research/2026-11-08-bink-refusal-detail.md), and B worktree `VXRuntime/tests/xrizer_xros_fixture.md`. These are prior results, not new execution claims. This planning round ran only read-only game-result/ledger validation and source inspection; no build, game, simulator or device launch.

## Desired end state of this round

1. Capture trustworthy original null-transfer context on an owned guest, then use one changed, pinned game diagnostic to identify the blocked object/interface or a precisely bounded remaining unknown.
2. Integrate the reviewed XR changes and produce new simulator offscreen evidence at the integrated revision.
3. Prepare the next real-platform fixture and physical test protocol, including Sony PS VR2 Sense, without claiming hardware acceptance.
4. Preserve broad regression and stack-local-worker failures as explicit blockers, with one bounded repro investigation when a worker becomes available.

No scene or completion date is promised. This round is complete when these investigations reach evidence-backed checkpoints or documented blockers; full project acceptance remains open.

## Assumptions and options

No blocking clarification is needed. Retain Sony PS VR2 Sense, existing Apple host, native xrizer, strict CPU AOT and current private-input authorization. The user approved execution of this plan, including supervised Terra work with check-ins approximately every three minutes. Physical installation/launch still requires separate authorization after preparing a reviewable fixture.

| Option | Tradeoff | Recommendation |
| --- | --- | --- |
| Parallel diagnostics and XR integration, with an evidence/preflight lane | Advances independent risks; requires exclusive ownership and serialized execution | Recommended |
| Concentrate all workers on null-transfer/compiler investigation, queue XR work | More immediate review attention on game blocker; delays standalone platform progress and risks redundant investigation | Viable if diagnostic scope expands or available slots shrink |

Within diagnostics, test generated dispatch first. Callback/signal-context capture remains a fallback only if the active path demonstrably bypasses a reliable generated exit; do not repeat either failed placement unchanged.

## Terra ownership and supervision

Use at most three `gpt-6.1-terra` workers plus parent. Start fresh tasks; historical task names do not establish live workers. Reuse worktrees only after inventorying all modifications, or create isolated `codex/` worktrees from a pinned integration revision. Never reset the dirty A checkout.

| Role | Exclusive files | First deliverable |
| --- | --- | --- |
| A — compiler/context | `VXRuntime/tools/vxrt_aot.c`, `translator/{aot.c,xlat.c}`, `src/{arm64.c,seh.c}`, owned `aot_null_*`/new dispatch controls | Generated-path explanation and exact assembly-fixture assertions before another capture implementation |
| B — XR platform | `third_party/xrizer/**`, `third_party/klepton_openxr/**`, `VXRuntime/xros/**`, XR-specific fixtures and presenter files explicitly assigned by parent | Reviewed integration reconciliation, then one integrated simulator candidate |
| C — evidence and reproducer preparation | Startup/pipeline tools and their tests, investigation reports; later one explicitly assigned baseline reproducer | Candidate/run readiness checklist, validated prior receipts and an independently specified diagnostic oracle |
| Parent — integration | Plans, `VXRuntime/Makefile`, shared loader/build/scanner hooks, root notices/provenance | Resolve shared-file changes, inspect diffs, schedule all runtime tests and retain source-to-binary identity |

Parent may delegate a specific shared file to one owner at a time; announce reassignment before edits. A requests loader changes from parent; B does not absorb A's unrelated optics experiments. C does not edit compiler files while A owns them. Parent remains the game orchestrator unless a new worker is explicitly assigned ordinary permitted orchestration; do not restart the historical rejected worker or route around an automatic review rejection.

Require first checkpoint within three minutes, then inspect progress at least every three minutes. Each checkpoint states changed evidence, next test and blocker. After two failed approaches narrow/review before another attempt; after three without progress write a local issue/handoff with exact failures and stop that loop. Independent lanes may continue. No automatic posting.

## Phase 0: freeze starting state and execution schedule

- [x] Record main/worktree HEADs and tracked source patch hashes in ignored `build/terra-continuation-supervision/initial-inventory.json`; A additionally hashes/preserves untracked diagnostics and failed snapshot/optics inputs separately.
- [ ] Read `AGENTS.md`, `MIGRATION.md`, this plan and relevant component source records in each implementation checkout.
- [ ] Freeze owner boundaries and module/runtime/toolchain manifests. Keep the old VeRantyx implementation read-only.
- [ ] Allocate unique builds, AOT scratch, Cargo targets, roots, overlays, XDG, shader caches and evidence paths. `aot_build.sh` has fixed `build/aot_s`; output flags alone do not isolate it.
- [x] Establish a parent-managed exclusive runtime/GPU/simulator/game slot. All workers must request a grant before execution. Initial process inventory showed the simulator UI and MCP servers, no observed game/compositor process; recheck immediately before each launch and honor harness refusal.

Read-only checks, with cwd `build/worktrees/terra-skyrim-aot`:

```sh
python3 tools/vxrt_native_startup.py --validate build/xrizer-game-011/result.json
python3 tools/vxrt_ledger.py verify
```

## Phase 1A: prove the original-context boundary

Parent inspected `VXRuntime/tools/vxrt_aot.c:write_part` and `translator/xlat.c:control_linked`. The emitted lookup compares a table key to target before checking its empty sentinel. For a zero target in single-part output, an empty key may match and branch to offset0 at `Lcode/Lenter`. Multi-part output first range-dispatches; zero below a nonzero image base should exit instead. This is a **static hypothesis**, not a verified new defect or an explanation of Skyrim's split-module call.

### Changes and investigation

1. Trace actual generated indirect CALL, lookup, exit/spill, signal redirect and callback flow. Identify whether the owned snapshot5 failure originates in single-part lookup, and identify the original game's active module/part path from pinned descriptors/disassembly. Do not infer the path solely from the module containing the reported return address.
2. Build an owned assembly-controlled virtual slot6 null call with explicit RAX=vtable, RCX=object and an exported/known next-instruction label. A C virtual-call expression alone does not guarantee those register values. Independently verify PE symbols/disassembly and the expected guest return stack word.
3. Compare unchanged and corrected single/split output. If the sentinel hypothesis reproduces, implement the smallest correct zero/empty handling and prove live state survives generated exit. Prefer capturing after the epilogue spills live guest registers, before another callback overwrites them. If not reproduced, record the disproving evidence and inspect the actual path; no speculative compiler fix.
4. Adapt the existing opt-in bounded snapshot only at the proven boundary. Preserve null execute-AV semantics; guarded self-memory reads report unreadable data explicitly. Correct SEH labels for execute8/read0/write1 without changing exception behavior.

### Automated verification

- [ ] Exact caller label, RAX, RCX, object word, vtable address and slot6=0 match independent fixture expectations; internal return sentinel is rejected.
- [ ] Default-off diagnostics are silent; unreadable pointers do not cause a second fault; four-record/eight-slot caps and execute/read/write labels pass.
- [ ] Managed-worker execute/read/write AV and continuation pass; valid nonzero indirect calls/returns and single/split/cross-module controls remain correct.
- [ ] Positive AOT counters and zero fallback are present for accepted owned runs; compare intended negative controls by their specified failure verdict.
- [ ] Required runtime checks and AOT suite run for the actual change; failures/skips remain explicit. Review source and artifact provenance before committing verified work.

**Game gate:** no new game probe until exact-context controls pass on the exact candidate. Generator changes affect already generated modules; identify the minimal affected module/parts and regenerate only those when needed. If Skyrim's existing split output already exits correctly, a runtime/context-only change may suffice. Do not rebuild all game code merely because the owned single-module control changed.

## Phase 1B: integrate and reverify simulator XR

Runs independently of 1A, with serialized runtime execution.

1. Reconcile/cherry-pick `e86df82`, then `896c7d2`; do not merge the whole branch or reapply baseline sync `a726aef`. Integration inspection identifies shared-history conflict risk in `VXRuntime/Makefile`, `src/loader.c` and `xros/app/Sources/VXImmersive.swift`. Resolve against actual cherry-pick results, preserving later main runtime fixes and fixture isolation/lifecycle changes.
2. Review xrizer SOURCE/patch records, provider contracts, loader defaults and static guest ABI/thunk generation even when Git reports no conflict. Verify pins/notices and generated patch/hash consistency.
3. Follow the corrected B fixture recipe. Preserve ordinary scratch/resources: unique optional AOT/project/bundle/guest outputs, correct `bundle/exe` guest placement, unique app identifier/container and launch nonce. Inventory ordinary resources before/after, including the documented 72-file check where applicable.

Build recipe, with existing repository-local toolchain selected in `XRIZER_RUST_ROOT`:

```sh
make -C VXRuntime XROS_SDK=xrsimulator XROS_XRIZER_FIXTURE=1 XROS_CODE_SIGNING=NO xros-app
```

The existing recipe selects `SIMCTL_CHILD_VXRT_XRIZER_XROS_FIXTURE=1` and `SIMCTL_CHILD_VXRT_XRIZER_XROS_OFFSCREEN=1`, then launches the prepared owned simulator app with `-test xrizer_xros_guest -lognonce <unique>`. Resolve actual device/app identities from inventory; do not paste placeholders into a launch. Retain required simulator tiled-staging configuration from supported scripts.

### Automated verification

- [ ] New integrated app/guest/AOT/provider/toolchain/SDK/source/patch hashes and exact commands/statuses are recorded.
- [ ] Guest initializes real static xrizer/provider; two spatially varying cropped eye pairs pass independent pixel/ID audit, four GPU copies complete, source leases balance12/12 and lifecycle1/1/1 drains; ExitProcess0.
- [ ] Present positive AOT entries and zero fallback; 46 is the historical branch observation, not a number to manufacture or require if code legitimately changes.
- [ ] Injected surface loss consumes STOPPING, drains outstanding work and refuses restart. Initial paused state is distinguished from active→paused loss.
- [ ] Ordinary build resources remain unchanged; default Apple initialization remains fail-closed outside tested explicit modes.

Record mono drawable/offscreen output separately. Do not call injected loss an observed OS pause or provider pixel audit physical/drawable stereo.

## Phase 2: one changed actual-game diagnostic

Depends on 1A; does not require physical Sense or full XR implementation. Parent orchestrates in C's isolated checkout.

1. Pin new runtime plus adjacent `libvxrt_vm.dylib`, compiler/source patch identity and any changed modules. Reuse unchanged prepared inputs and 17 unaffected modules unless an evidenced change requires otherwise. Freeze the tested Mac xrizer (`71aed9176b0f201072385a5f7bb43672fe23f27cd140cb6e0660d35a5df4211e`); do not substitute simulator artifacts.
2. Run exact-candidate null/context controls and the existing joined optics/property/DXGI/mesh/event/stereo/lifecycle fixture first. Maintain the game's observed 48-byte event layout and actual per-version ABI.
3. Prepare candidate14/new unique run paths from the recorded `game011-command.json`. Use harness `--trace-null-target`, which explicitly sets the diagnostic variable; inherited environment alone is stripped. Keep normal depth unless a separately justified diagnostic requires otherwise. Label diagnostic versus normal acceptance.
4. After idle precondition passes, perform one bounded probe (existing recipe20s), seal logs/result and verify ledger plus unchanged input hashes. Inspect capture before proposing a semantic fix.
5. Map actual object/vtable/slot/caller and initialization provenance. Classify a concrete Windows API/ABI/compiler/lifetime problem only with supporting evidence, then add an owned reproducer and fix the demonstrated cause. If provenance remains unknown, record what data would distinguish hypotheses rather than retry unchanged.

### Acceptance

- [ ] New evidence links source→runtime/helper/compiler→module manifest→owned gates→game run; counts missing at abnormal exit remain unknown.
- [ ] Snapshot identifies original context or explicitly fails acceptance. No game null-success stub, patched game call, fabricated interface/ownership response or stack-size guess.
- [ ] Report actual earliest checkpoint; stereo Submit, menu and scene each require their own observed evidence.

Private receipts remain under C `build/xrizer-candidate-13/` and `build/xrizer-game-011/`. C13 runtime SHA `024621453feb08c37c8a8478ffe8814afc7f8a49e258514f745ad380fbe2db41`; helper SHA `1a0555faa605c026b36371c4bf714fe29552e7e51d7a70cff9c28587aa4edce3`. Validate full prepared/module identities from manifests; do not rely on shortened hashes in prose.

## Phase 3: prepare real Apple-platform proof

B proceeds after integrated simulator verification while A/game work continues.

- [ ] Trace actual `queryDrawables`, predicted presentation-time ARKit anchor, per-eye transforms/FOV, texture layout and GPU completion in the existing renderer; retain one compositor/pacing owner.
- [ ] Prepare metre-scale world geometry and independently specified eye/projection goldens, origin/recenter, fresh/repeated frame/pose IDs, color/crop and reader lifetime checks. Preserve real tracking validity and stale-sample invalidation.
- [ ] Connect actual host clock/tracking/session/input semantics through the provider. Owned injected controls precede hardware; no identity-head success substitutes for ARKit tracking.
- [ ] Design Sense left/right identity, GameController controls and supported haptics plus ARKit accessory grip/aim tracking, timing, disconnect/reconnect and permissions. Verify current source/SDK capabilities before implementing; no hand anchor substituted for tracked controller pose.
- [ ] Prepare target-device signed fixture, correct device AOT/static ABI artifacts, address-space/memory/resource probes, exact install/launch protocol and rollback preserving app data. Build-only results stay labelled.

### Manual verification — requires separate physical install/launch authorization

- [ ] Standalone launch without streaming/helper/debugger/JIT.
- [ ] Physical stereo, scale, head motion, floor/recenter, tracking loss and lifecycle recovery.
- [ ] Actual Sense left/right grip/aim, controls, invalidation/reconnect and supported haptics.
- [ ] Real device memory/address/GPU budgets before large game packaging.

Request authorization only after the concrete fixture and protocol are reviewable. Human physical playtest is a later gate; no fixture establishes Skyrim playability.

## Baseline and deferred risks

C may prepare a bounded baseline control while A/B work, then execute only with the runtime slot. Prefer the unexplained stack-local-worker/module-entry failure because it may affect confidence in context capture. Preserve reconstructed-source limitations and old PE/module hashes; compare the same binary on pinned old/new runners with separate roots. Three inconclusive attempts stop with a local report; broad repeated batches are not a reproducer.

Keep fiber/kernel/presentation/thread-area failures and unexecuted D3D12 tests visible. Similar offsets or old failures do not prove unchanged cause. The remaining94 Bink refused blocks are static coverage risk, not observed execution. Implement additional MMX/decoder semantics only when a reached target or deliberate bounded semantic investigation justifies them; no blanket opcode expansion in this round.

## Testing strategy and final reporting

Run applicable owned controls first, then one scheduled regression batch per meaningful runtime candidate using supported `make -C VXRuntime check`, `check-arm64`, `aot-suite` and native-VR targets where touched. Use xrsimulator-specific targets for simulator output and device SDK for device output. Record every command exit, semantic verdict, skip and source/artifact identity. A red broad baseline blocks broad acceptance but does not erase a separately valid owned result.

Planning-document validation: inspect links and diff; no runtime regression rerun is needed solely for this document. Implementation reports must separate static hypothesis, owned Mac fixture, simulator offscreen, drawable presentation, actual game and physical human observations. Update this work order and the architecture-plan checkpoint as results are verified; leave physical checks unchecked until confirmed. Commit only verified, scoped work; keep private inputs/translated code/raw game evidence out of source control.

## Execution log

- 16:18 UTC: user approved continuation. Fresh Terra workers `terra_context_execution`, `terra_xr_execution`, `terra_evidence_execution` started. Parent delegated shared Makefile/loader/build hooks exclusively to B in its new integration worktree until handback. A preserves its dirty checkout. Parent inventory is under ignored `build/terra-continuation-supervision/`.
- Parent tool checks: 15 startup and 11 pipeline Python tests passed; generated agent-file check reports 20 files current. These are tool/unit checks, not runtime/game acceptance.
- 18:02 UTC: Candidate 14 built (`8af027a...`). Control 1 (owned null snapshot check) passed exit 0 (25 AOT entries, 0 fallback). Control 2 (joined guest stereo fixture) passed exit 0 (107 AOT entries, 0 fallback).
- 18:03 UTC: Skyrim Probe 012 executed with `--trace-null-target` under parent orchestration. The previous null-vtable crash from probe 011 did not recur (demonstrating that single-part table sentinel lookup was the false crash trigger). Skyrim advanced through Compositor022, event polling, controller queries, and complete D3D11 render setup, reaching 3,493,721 AOT entries before strict stop at `binkw64.dll+0xe1de` (`0xf0000e1de`), an MMX decoder block (`pxor %mm5, %mm5`). 12-row ledger verified (`ff959c8...`). No exceptions or native signals.
- 19:16 UTC: Probe 013 used the regenerated Bink module without `--trace-null-target`. It loaded 9800 Bink blocks, then exited 5 at a guest access violation at address 0 after `CoCreateInstance` returned `0x80040154`. No AOT summary.
- 19:17 UTC: Probe 014 repeated that module with `--trace-null-target`. It passed `binkw64.dll+0xe1de`, reported 7,726,663 AOT entries and zero fallback, and stopped on unimplemented `RPCRT4.dll!UuidCreateSequential` from `SkyrimVR.exe+0x137ff67`. Exit 3. Ledger 14 rows, head `0200073c…`.
- 19:38 UTC: Owned `aot_uuid_sequential` fails by name on Candidate 14 (exit 3) and passes on host `15230a71…` (7 entries, 0 fallback). Probe 015, same trace flag and `aot-mmx` modules, got status 0 from that call, then was killed at 40 seconds in a `SetupDiEnumDeviceInterfaces` loop (last error 259). Last tick 8,388,608 entries, 0 fallback; no exit summary. Ledger 15 rows, head `bfe000cd…`.
- 20:05 UTC: The 21 ordinary misses on DLLs already loaded by probe 015 are implemented. Owned `aot_loaded_imports` on host `72280771…` exits 0 (116 entries, 0 fallback). Probe 016, same modules and trace flag, logged no missing-import summary and was killed at 40 seconds in the same SetupDi loop. Last tick 8,388,608 entries, 0 fallback; no exit summary. Ledger 16 rows, head `3d692e0a…`.
- 20:25 UTC: Probe 017 used host `77a8e034…` (the import host plus the ARM64 call ring) and dumped each thread's last runtime calls at 35 seconds. Render thread `68615031` was still inside `ctx_draw_indexed` of 6 indices from `SkyrimVR.exe+0xdbde0f`, entered about 26 seconds earlier. The main thread was spinning `Sleep(0)` from `+0x5b68f8`. Bink was waiting from `binkw64.dll+0x169d5`. SetupDi was a side thread and returned after the dump. Killed at 40 seconds, return -9. Tick 12,582,912 entries, 0 fallback; no exit summary. Ledger 17 rows, head `398c149f…`. The recorded patch hash is the temporary `--trace-call-ring` harness copy; the worktree was restored to `b4a0d02`.
- 20:31 UTC: Probe 018, same host without the ring, returned from that draw and aborted in `GetProjectionRaw` (`IVRSystem_019` slot 2) from `SkyrimVR.exe+0x8ffb3e`. Return -6. Exit summary 3,702,901 entries, 0 fallback. Ledger 18 rows, head `379fb7f1…`.
- 20:38 UTC: `GetProjectionRaw` forwards to native xrizer. Probe 019 on host `3859c989…` passed both eyes and aborted in `IVRCompositor_022` slot 24. Return -6. Exit summary 3,947,781 entries, 0 fallback. Ledger 19 rows, head `bfef4667…`.
- 20:42 UTC: `CanRenderScene` forwards and returns 1. Probe 020 on host `46fd1e96…` reaches `WaitGetPoses` (0) and `Submit` for both eyes. Each observed `Submit` returns 102. The process then exits 5: main thread `0xc0000005` at `SkyrimVR.exe+0x27c743`, reading address 0. Exit summary 71,303,169 entries, 0 fallback. Ledger 20 rows, head `cf45eb92…`.
- 21:03 UTC: Probe 021 on host `48687c2e…` records the submitted texture: DirectX, Gamma, flags 0, one live `R8G8B8A8_UNORM` 2422×1211 texture, bounds `0–0.5` and `0.5–1`. `acquire` accepts it. `Submit` still returns 102. Exit 5 at the same `+0x27c743` read. Exit summary 75,497,472 entries, 0 fallback.
- 21:10 UTC: The Metal backend accepts Gamma or Auto with an UNORM texture and copies the texels as stored. Probe 022 on host `0e592296…` and dylib `082c3906…` (`gamma-unorm-70`) gets `Submit` 0 for both eyes, GPU copies complete, then `PostPresentHandoff`. The next `WaitGetPoses` returns 1 and the next `Submit` returns 108. No fresh pair is logged. Exit 5 at the same site. Exit summary 67,108,866 entries, 0 fallback.
- 21:22 UTC: Probe 025 (dylib `d09cc94c…`, version `submit-diag-2`: this checkout's xrizer source with `--features owned-apple-test`, plus warnings on every silent frame-failure return) logs the cause of probe 022's stuck frame. Each `PostPresentHandoff` logs `end_frame: views not presentable (flags=ViewStateFlags(0), views=2)` and `end_frame returned false - frame stays Begun`. The next `WaitGetPoses` logs `xrWaitFrame failed: ERROR_CALL_ORDER_INVALID` and returns 1; the next `Submit` returns 108. Skyrim never calls `SetExplicitTimingMode`, so xrizer runs Implicit. Cause: Skyrim uses the Standing origin, which xrizer maps to the STAGE reference space. The provider's `klxr_LocateViews` returns zero flags for STAGE when `KlNativeFrameSample.stage_valid` is 0, and the dev host never set it. This is the provider's designed fail-closed behaviour, not a regression.
- 21:26 UTC: The dev host gains an opt-in `VXRT_XRIZER_DEV_STAGE=1` (harness flag `--dev-synthetic-stage`) that declares the synthetic local origin the floor (`stage_valid` 1, `local_from_stage` identity; the synthetic head is already at 1.6 m). Default behaviour is unchanged: the owned `xrizer_openvr_exports_joined_check.py` on the new host and dylib passes every check (107 AOT entries, 0 fallback), including `standing_cancel`. New host `VXRuntime/build/terra-stage/vxrt-arm64` `4ad351d1…` (helper unchanged `1a0555fa…`).
- 21:36 UTC: Probe 032 (host `4ad351d1…`, dylib `d09cc94c…`, `--dev-synthetic-stage --trace-files`, same `aot-mmx` modules) logs 871 `offscreen fresh pair` lines from the dev host (frame N, pose N, two 1211×1211 images, "no display"), about 37 frames per second, with no xrizer warnings. Exit 5 at the same `SkyrimVR.exe+0x27c743` read of address 0, about 28 seconds after launch. Three AOT summaries, 83.9M entries, 0 fallback; harness `validate` passes. Probe 031 (same settings, no `result.json` because its harness was backgrounded) logged 899 pairs and the same crash 29.7 seconds after launch. This is the first time Skyrim's own frames have reached the dev host. Pixel content was not read back: the pairs are published and completed, not shown to be non-blank. Not a scene, not a display, not tracking.
- Crash `+0x27c743`: at `+0x27c730` the function calls `[[rdx]+0x380](rdx)` and then dereferences the returned `rax` (0). It crashes at about the same wall-clock offset (28–30 s) with and without frames, always about 270–290 ms after a main-thread `FindFirstFileA` from `+0x14137de31` returns error 2 (a worker thread made the same call 12 s earlier; its argument is the static string `Saves/`). The relation is unproven. The `CreateFile` failures for `…\data\DATA\<plugin>.esm` are the game's loose-file lookup and are probably benign. Not investigated further.
- Flaky start: probes 024, 028 and 029 died in the first 20 ms to 2 s (null call after the refused `CoCreateInstance` class `{5A508685-…}`, or a strict-AOT miss at `+0x138afb8` while loading `d3dx9_42`). A 6-and-6 paired run with `--seconds 12` (no stage flag) failed 0 of 6 with the old dylib `082c3906…` and 2 of 6 with the new one. Too few runs to attribute it to the dylib; it matches the earlier untraced probe 013 fault. The `0xf00000000` arena message appears in surviving runs too. Open.
- 22:10 UTC: Pixel readback (dev host `--dump-eyes`, probes 033/037): frame 1 gray with a black rectangle, frames about 2–150 the Bethesda logo (Bink video, about 30% of pixels non-black), from about frame 180 fully transparent black until the exit.
- 22:30 UTC: New `VXRT_FAULT_OBJECTS=1` (harness `--fault-objects`) logs, at an unhandled fault, what each register points at (qword 0 as an image offset, `[[0]+0x380]`, the TESForm header, the `+0x68` chain), reading through `mach_vm_read_overwrite`. Probes 039/040: the faulting `rbx` is a `TESObjectREFR` (vtable `SkyrimVR.exe+0x15e17f8`, RTTI `.?AVTESObjectREFR@@`); `[[0]+0x380]` is `+0x2a2ec0`, a 3D-node getter that returned null (REFR `0x0200158e`, a Dawnguard placed reference to a static whose mesh was never loaded). The game dereferences the result unchecked.
- 22:40 UTC: `VXRT_TRACE_FILES` now logs failed `GetFileAttributesEx` paths (all with `=2`). Probe 041: the game probes `Skyrim - Textures.bsa`, `Skyrim - Meshes.bsa`, `Skyrim - Voices.bsa` and `Skyrim - VoicesExtra.bsa`, the built-in default list, and opens only `Misc`, `Shaders`, `Animations`, `Interface`, `Sounds` and `Skyrim_VR - Main.bsa`. `Skyrim.ini` sits in the game directory with a full `[Archive]` list, but `GetPrivateProfileStringA/W` and `GetPrivateProfileInt*` in `client.c`/`services.c` were stubs that returned the default.
- 22:50 UTC: `client.c` now reads `.ini` files (read only; writes are still not kept): section/key without case, `;` comments, CRLF, a UTF-8 BOM, quoted values, `GetPrivateProfileString/Int/Section` in A and W form including the enumeration forms. Owned fixture `tests/ini.c` (`build/ini.exe`, added to `make check`) passes on the arm64 host (`terra-stage/vxrt-arm64` `22b189b1…`, non-strict); `tests/files.c` still passes there. The broad `check`, `check-arm64`, `aot-suite` and `native-vr-*` targets were not run for this change.
- 22:56 UTC: Probe 043 and 044 (same dylib `d09cc94c…`, `aot-mmx` modules, `--trace-null-target --fault-objects --experimental-xrizer --dev-synthetic-stage`): `.\Skyrim.INI` is read about 6,900 times; all 19 archives open; no crash. Probe 044: 1,858 fresh pairs in 60 s, zero fallback, eyes transparent black from frame about 330. Two earlier attempts in the loop died in the flaky start (the retry condition was wrong, so there are no counts of survivors for this loop). The process is still running at the 60 s harness limit: whether the scene appears later is unknown.
- 23:05 UTC: Sampling probe 045 near 45 s: about two dozen game worker threads idle in `WaitForSingleObject`, the game's main thread blocked in it for about 84% of the samples, almost no CPU use. `VXRT_WAIT_DUMP` (harness `--wait-dump 40,55`, probe 046) lists the long waits: the worker pool at `SkyrimVR.exe+0x3168ea0` and neighbours, a `LibpadOutput` thread at `+0xc65fe0`. In 60 s the game requests only `IVRSystem_019` and `IVRCompositor_022`: never `IVROverlay` or `IVRInput`, so the overlay hypothesis is untested, not refuted.
- 23:10 UTC: The harness allows `--seconds` up to 300 with `--experimental-xrizer` (60 otherwise). Probe 047 (180 s) and 048 (200 s, host `eedb93ac…` with the dev host keeping a raw pair every 600th frame): no crash, no unhandled exception. The eyes stay transparent black until about 90 s after launch; frames 4200–6600 show Skyrim's loading screen (`Level 1` bar, the Black Sacrament lore quote, fog; 45.7–46% non-black). The screen is unchanged for about 70 s. Whether it is slow loading or stuck is unknown.
- 23:25 UTC: Probes 049 (call ring at 130 s, `--wait-dump 120`) and 050 (`--trace-files --trace-all-opens`, new `fopen` trace in `ucrt.c`) on the loading screen. The game's first thread is not deadlocked: it signals event `0x3a4` (`SkyrimVR.exe+0xd71fb6`) and waits on semaphore `0x39c` (`+0xd71fc3`), which a loader thread releases from `+0xd75bde`; that loader is in `ReadFile` (512 KB) plus `memcpy` when the ring is dumped, and the first thread was in the wait for about 20 s. It later reads `Skyrim.esm`/plugins through the C runtime in 2 KB `fread` chunks with `fseek`/`ftell` (the 32-bit `long` handling in `ucrt.c` is correct). The plugins are opened with `fopen` (`DATA/*.esm`); `C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt` is not found (5 times; unknown effect).
- 23:35 UTC: Probe 051 (300 s, the harness maximum): no crash and no world scene. The eyes are black until about 90–100 s, then the game's loading screen cycles through different quotes (frame 9600: 'There are nine Holds in Skyrim…') with a rotating 3D model drawn as a flat black silhouette; 40–92% of pixels differ from pixel 0 between samples. The two translated shaders `7d305c67` and `96d61b6b` (1D `sample`) still fail to compile and may explain the black model.
- 23:45 UTC: Probe 052 sampled at 140 s (host `eedb93ac…`-based build, `fopen` trace added): process CPU about 118% (`ps`), and the largest active leaf is `_sigtramp` (about 5,300 of 8,000 samples on one game thread, called from AOT code near `skyrimvr.exe…p9.dylib+0x645108…0x646c7c`); that region includes a qword copy loop using `ldapr`/`stlr` per 8 bytes (ordered accesses). Whether the signals are real, why they are frequent, and whether they make the load slow are not established. A rendering thread (`WaitGetPoses` paced by the dev host's `nanosleep`) is idle. Not yet compared against any other execution mode.
- 23:55 UTC: ROOT CAUSE of the slow load (actual Skyrim, dev host): the runtime's own counter, in every `startup.log` since the first long run, reads 32.7 M, 44.1 M and 54.9 M "ordered accesses across 16 bytes" at 23:33, 23:35 and 23:36 in probe 051. Each one is a SIGBUS handled by `xa_fix_split` (`translator/aot.c`), so the earlier `_sigtramp` samples and the `ldapr`/`stlr` qword copy loops are this. `VXRuntime/RECOMP.md` records the same effect on another title (58 M signals, fixed by feeding `VXRT_AOT_SPLITS` back to `vxrt-aot`, leaving 0.27 M). Probe 053 (125 s, new harness flag `--aot-splits`) collected `build/worktrees/terra-skyrim-aot/build/xrizer-game-053-splits.txt`: 297 distinct x86 instructions, 0 fallbacks. The modules have NOT been regenerated with this profile; that is the next fix and needs a decision (private artifact regeneration).
- 23:50 UTC: `dxbc.c` now translates `sample_l/b/d` on `Texture1D`/`Texture1DArray` without `level()`/`bias()`/gradient (Metal `texture1d::sample` has none); offsets move the coordinate. Subject: hand-assembled owned fixtures, `VXRuntime/tests/dxbc_tex1d_check.py` (20 variants: 18 failed before, 0 failed after) and the 17 `tests/shaders/*.dxbc` still compile through `dxbcscan`. The game's two shaders (`96d61b6b`, `7d305c67`) have not been re-run with a rebuilt host.
- 00:25 UTC: Regenerated the Skyrim exe modules with the split profile (user-approved), into a NEW private directory; the existing modules are untouched. Recipe and identities (actual-game inputs, no headset):
  - Compiler: the VeRantyx `native-darwin-aot` `VXRuntime/build/vxrt-aot` (SHA `b24bce5268f1a057006a5bb3c375249a9872604a0f37daca7e666103aedda62f`), `VXRT_AOT_PART_MB=16`. Control: with no splits and no roots this reproduces all 11 original `SkyrimVR.exe.p0..p10.s` byte for byte (`cmp`), so the profile is the only change. The repo's own `VXRuntime/build/vxrt-aot` (`e135aa76…`) was NOT used (different build).
  - Inputs: prepared exe SHA `8daf0519…46d4`; splits `build/worktrees/terra-skyrim-aot/build/aot-splits-gen/splits.txt` (996 instructions, collected from probes 053/054/056, SHA `0b1b00d4…0f37`, merged by `sort -u`); roots `roots.txt` (8 addresses, SHA `0be458b5…ed89`, all from strict misses at jump tables, see below). Output `aot-splits-gen/dylibs/` (SHAs in `dylibs.sha256`), assembled with `clang -arch arm64` as `VXRuntime/tools/aot_build.sh` does; module set `build/private/skyrimvr/<original-sha>/aot-splits/` = `aot-mmx` with the 11 exe parts replaced. Scripts `aot-splits-gen/regen.sh`, `iterate.sh` (scratch, not committed). Generation 5.3 s, assembly about 5 s.
  - Result (probes 055, 056-x, 057-1, actual Skyrim on the dev host, strict AOT): ordered-access signals fall from 55 M in 300 s to 0.63 M by the point the game reaches the same loading stage (66 M entries, about 25 s instead of more than 300 s). Strict AOT stopped on blocks the generator did not find: `0x1412a3732`, `371d`, `36a6`, `3745`, `b775d` (and then `370d`, `3758`, `37e3` added by reading the table). Cause: `jump_table()` in `vxrt_aot.c` takes bound 2 for the switch at `0x1412a3690` (`cmpl $7, %ebx; ja` is right before it, but the index register is `rax` copied by `movslq %ebx, %rax`, and the bound search matches an earlier unrelated `cmpl $1, %eax`). The same happens with the repo's compiler. Not fixed in the generator (that changes every module); the roots feed the missing targets instead. Other tables may have the same fault.
  - Then abort `vxt_unsupported_compositor_8`: the game called IVRCompositor_022 slot 8 (`GetFrameTiming`), which the guest bridge had as an unsupported stub. Added the slot to `xrizer_guest_bridge.c` (pass-through; `Compositor_FrameTiming` is `pack(4)` in the header on all platforms, size field first; xrizer implements it). Evidence is the game's own call not aborting; no fixture checks the returned values. Host rebuilt (SHA `52d3b26f…e2c2`, includes the dxbc 1D fix and the `fopen` trace); `make -C VXRuntime native-vr-unit-check` passes (the other `check`/`native-vr-*` targets not run).
  - Probe 057-1 (300 s, 0 fallbacks, no crash, no shader-compile errors in the log, 1.86 M ordered-access signals over 226 M entries): the game loads in about 30 s and then shows a STATIC image: frames 1200 to 11400 are identical (diff 0) and almost black with one white bar, no scene, no text. The game is running (226 M entries) but waiting for something or drawing only that. Not yet explained. `IVROverlay`/`IVRInput` still never requested.

