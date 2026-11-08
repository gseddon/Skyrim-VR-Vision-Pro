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

- [x] New integrated app/guest/AOT/provider/toolchain/SDK/source/patch hashes and exact commands/statuses are recorded.
- [x] Guest initializes real static xrizer/provider; two spatially varying cropped eye pairs pass independent pixel/ID audit, four GPU copies complete, source leases balance12/12 and lifecycle1/1/1 drains; ExitProcess0.
- [x] Present positive AOT entries and zero fallback; 46 is the historical branch observation, not a number to manufacture or require if code legitimately changes.
- [x] Injected surface loss consumes STOPPING, drains outstanding work and refuses restart. Initial paused state is distinguished from active→paused loss.
- [x] Ordinary build resources remain unchanged; default Apple initialization remains fail-closed outside tested explicit modes.

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

- [x] Trace actual `queryDrawables`, predicted presentation-time ARKit anchor, per-eye transforms/FOV, texture layout and GPU completion in the existing renderer; retain one compositor/pacing owner. Census `c3d4e5f6`: dedicated layout, one 3840×2160 color texture, one depth texture, one view. The non-offscreen present path still requires two views and two equal color textures.
- [ ] Prepare metre-scale world geometry and independently specified eye/projection goldens, origin/recenter, fresh/repeated frame/pose IDs, color/crop and reader lifetime checks. Preserve real tracking validity and stale-sample invalidation. Mac golden now covers the injected 64 mm eyes, ±π/4 fields, near 0.1 / far 100 projection, a 1 m origin shift, and rejection of a pose older than 1 s, newer than 0.1 s, or marked untracked. Fresh/repeated IDs, color/crop, reader lifetime, and a real tracked head remain open.
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
- 19:09 UTC: Terra B integrated `e86df82` then `896c7d2` onto `a1522f3` in `codex/terra-b-sim` and ran one offscreen simulator fixture, nonce `b1a7c0de`. Exit 0, frame/pose 1/1 and 2/2, four copies, leases 12/12, lifecycle 1/1/1, 46 AOT entries, zero fallback. Census `c3d4e5f6` measured one dedicated-layout drawable: one view, one 3840×2160 color texture, one depth texture. Receipts are in `VXRuntime/tests/xrizer_xros_fixture.md`.
- 19:20 UTC: Mac optics golden passed. Injected eyes are 64 mm apart with ±π/4 fields. The game projection for near 0.1 m and far 100 m is recorded in `VXRuntime/tests/xrizer_xros_optics_golden.m`. Drawable far 10000 m stays separate.
- 19:25 UTC: The same golden now checks a 1 m origin translation and the presenter age window: current from 0.1 s ahead through 1 s behind, rejected when older, further ahead, untracked, or non-finite. `native_vr_present.m` and the host pose matrix call that shared predicate. This is an injected control, not ARKit tracking. Exit 0. Output dir `VXRuntime/build/xros-optics-golden.l2Fxzz`.
