# Standalone Skyrim VR / Vision Pro handover

Updated 8 November 2026, Europe/London. User requested handover to another agent. All workers are at completed/idle checkpoints; no further game or simulator run is pending. Verify process state before starting anything.

## Objective and working agreement

Run the user's Windows x86-64 Skyrim VR **fully standalone on Vision Pro**, using strict ARM64 AOT, VXRuntime Windows compatibility and its existing D3D11→Metal renderer, native xrizer, and a Klepton-derived OpenXR provider adapted to the existing Apple host. Mac execution is a development/reference track, not the final streaming architecture.

- Implementation should predominantly use **gpt-6.1-terra** subagents for cost; parent supervises, reviews and integrates. Assign exclusive files and check progress within three minutes. Serialize runtime/GPU/simulator tests and conflicting AOT scratch. After two failed approaches narrow; after three without progress record the blocker and stop that loop.
- Sony **PS VR2 Sense** is the selected physical controller target. No physical tracking/input acceptance yet.
- No CPU JIT/runtime machine-code generation on accepted standalone path. Normal Metal GPU shader compilation remains authorized.
- GPL/LGPL reuse including xrizer/AVP Play is authorized; preserve licenses/source pins. Do not copy Wine/ReactOS code.
- Original game/Valve/Microsoft files remain read-only; user authorized private preparation/unpacking and local investigation. Do not fake ownership/Steamworks success or bypass anti-cheat. Private files/translated game code/raw evidence must not be committed.
- Existing local Rust/Cargo/target/crate downloads and simulator testing are authorized. Do not change global tools. **Physical-device install/launch needs separate approval**, after preparing a concrete reviewable fixture.
- Earlier automatic content review interrupted the startup worker/coordinator, citing possible cybersecurity risk. Work was preserved; no approval bypass was attempted. This was separate from the technical failures. Do not restart an errored worker or assume an old task name is active.

## Repository and branches

Everything committed below is pushed to <https://github.com/gseddon/Skyrim-VR-Vision-Pro>. One source repo is sufficient. Main working branch is `codex/standalone-import`, **source checkpoint before this handoff: `5c07f69`**.

| Absolute location | Branch / current HEAD | State |
| --- | --- | --- |
| `/Users/gseddon/git/Skyrim-VR-Vision-Pro` | `codex/standalone-import`, `5c07f69` | Integration checkout; clean before this handoff |
| `/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-guest-stereo` | `codex/terra-guest-stereo`, `1a3a733` | AOT/ABI worker; **dirty unverified diagnostic and older unrelated optics experiments—preserve** |
| `/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-pose-input` | `codex/terra-pose-input`, `896c7d2` | Clean; reviewed simulator implementation awaits main integration |
| `/Users/gseddon/git/Skyrim-VR-Vision-Pro/build/worktrees/terra-skyrim-aot` | `codex/terra-skyrim-aot`, `e1d0f5b` | Clean; parent game orchestration, private inputs, sealed runs |
| `/Users/gseddon/git/VeRantyx/build/worktrees/native-darwin-aot` | Previous implementation | **Read-only reference** for immutable modules/evidence |
| `/Users/gseddon/git/VeRantyx/build/toolchains/xrizer-rust` | Existing local toolchain | Reuse with separate Cargo target/XDG outputs |

Repo-only GH authentication is under `/Users/gseddon/git/Skyrim-VR-Vision-Pro/.git/gh-auth`; local Git HTTPS helper already uses it. CLI account is personal `gseddon`. Do not expose/move credentials or change global GH auth. If invoking `gh`, use that directory as `GH_CONFIG_DIR`. Pushes to this repo are already authorized.

Worker names in this session: `/root/terra_guest_stereo_round2` (AOT/ABI), `/root/terra_pose_input_round2` (XR), `/root/terra_xros_review` (review and narrow harness implementation). All are Terra and currently completed. Check availability in the new agent/session; names alone do not establish running work.

## Read first

Paths below are relative to the new repository unless explicitly qualified.

1. `AGENTS.md`, `MIGRATION.md`.
2. `plans/2026-11-08-skyrim-vr-native-darwin-aot.md` — architecture/approved work order.
3. `plans/2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md` and `plans/2026-11-08-xrizer-klepton-native-openxr.md`.
4. `research/2026-11-08-skyrim-native-bootstrap-round2.md` — detailed actual-game probes through **011**, candidate identities, observations and limitations.
5. `research/2026-11-08-bink-emms-aot.md`, `research/2026-11-08-bink-refusal-detail.md`, `research/2026-11-08-aot-null-vtable.md`, `research/2026-11-08-runtime-regression-round2.md`.
6. **On XR branch/worktree:** `VXRuntime/tests/xrizer_xros_fixture.md` — simulator build/run recipe, all successes/failures and hashes, including latest `UjBVTn`.

The plan's scope remains valid, but some status rollups predate the latest 46-entry simulator proof and failed snapshot5. This handoff and the linked evidence reports are the current checkpoint; update rollups after integration.

## What is established

### Actual Skyrim and AOT

- Private preparation reduced unexplained executable-section bytes from **78.98% to 0.86%**. Neither number proves complete discovery or translation.
- Across actual probes, original game code has initialized native xrizer, acquired System019/Compositor022, created a D3D11 device/swapchain, reached WaitGetPoses and event polling. **No game stereo Submit/image, menu, scene or playability has been established.**
- Probe007 recorded **3,539,503 AOT entries, zero fallback** up to an intentional unsupported event-method stop. Missing summaries on other probes remain unknown, not zero.
- System019 wrappers now cover tested string properties, truthful DXGI adapter unavailable (`-1`), empty hidden-area mesh aggregate ABI, and event layout conversion. Actual game passes a **48-byte** event buffer; pinned Windows header is64 bytes/native Darwin60. Do not blindly copy native event structures.
- Exact Mac development-host owned guest passes pre-frame optics without fake frame tickets, Standing-invalid cancellation, Seated poses, two changing D3D11 pixel/crop pairs, normal1024 recommendation/consumer, event controls and balanced lifecycle: **107 AOT entries, zero fallback**. Head/input are injected/disconnected.

### Two concrete compiler/runtime fixes

1. **Bink EMMS:** probe008 stopped at `binkw64.dll+0x1d48`. The block was **discovered but refused during translation**, not absent discovery. Legacy EMMS support has a strengthened owned x87-state/VZERO control. Intel/AMD specify TOP0; Rosetta preserves TOP in the reference test, so its divergent mode is explicitly labelled. New Bink alone has9753 blocks/94 refusals versus9752/95; only the observed EMMS refusal was removed.
2. **Null AOT cache hit:** probe010's depth-limit diagnostic caught repeated callbacks to zero. Empty TLS cache entry at RIP0 was treated as a native thunk, leading to null native call → guest callback → recursion/stack exhaustion. `334b8da` (main equivalent `fb09aae`) faults before cache lookup and delivers Windows execute AV type8 through existing SEH. Managed-worker static-vtable red/green control validates execute/read/write AV and continuation: fixed **10 entries, zero fallback**. Existing AOT suite passes. This fixes the observed runtime mechanism, not the original object's null target.

### VisionOS simulator XR

XR branch `896c7d2`, reviewed by another Terra agent, passes an actual Windows guest through **static xrizer + provider + existing Apple app**, not Mac dlopen or a second compositor.

- Latest `UjBVTn`: **46 AOT entries, zero fallback**, two spatially varying cropped stereo pairs, independently checked provider pixels/IDs1/1 and2/2, four completed GPU copies, 12/12 source leases and lifecycle1/1/1; ExitProcess0.
- Explicit offscreen mode injects stereo calibration, identity head and disconnected input. Actual Metal device/queue and prediction cadence come from existing compositor. The actual simulator reports **one drawable view/one color texture**; its mono output stays on the clear path. **This proves offscreen XR/AOT, not physical stereo presentation.**
- Injected surface loss consumes STOPPING, drains outstanding work and refuses restart. This is not an observed OS pause after activation.
- Review fixed shared scratch/resource clobbering, uniform-color crop tests and missing loss notification. Initial paused state is now distinguished from active→paused loss. Corrected real-worktree optional target passed;72 default scratch/resource files remained unchanged. Re-review found no remaining actionable finding in that scope.
- Latest Rust archive crosscompiled for device SDK (build only). Simulator fixture C guard excludes physical devices. No headset was installed/launched.

## Immediate blocker: actual game null-vtable object

Latest normal-depth **`xrizer-game-011`**, integrated candidate13, now exits5 at a **guest unhandled AV at address0**, with no native signal/recursive crash. It has **no AOT summary**, so entry/fallback totals are unknown. Source/read-only inputs remained unchanged; sealed result/ledger validation pass.

Observed registers: RAX=`0x3a034aca8`, RCX=`0x3a034ad20`, RDX=`0x424b27dd0`, RSI=`0x1430c1d50`, RDI2, R8=0. Legacy logger says “writing0” because it labels any nonzero access type as writing; known null-fetch path emits execute8. Truthful label correction is still part of A's unverified diagnostic work.

Read-only callsite analysis: original caller `0x140c2e345` follows virtual slot6 (`+0x30`); `this` comes from global `0x1430c1d38`. One initialization path obtains a value from game keyed lookup `0x140c32160`, calls its virtual slot1 and stores the returned object. Other paths temporarily replace/restore the global. **No concrete class/provenance identified.** Do not assume game corruption, missing D3D COM slot, or object lifetime issue without evidence. No game patch/null-success stub.

### Failed diagnostic work — important

A has uncommitted edits to `VXRuntime/{translator/aot.c,src/arm64.c,src/seh.c}` and new tests `aot_null_snapshot.c`, `aot_null_snapshot_check.py`, `aot_fault_label.c`.

- First snapshot at `xa_run(RIP0)` captured overwritten nested callback state, not original callsite.
- Corrected snapshot5 moved capture to `vx_x86_call(fn0)` before overwriting its outer context. **It also failed its first owned assertion.** It recovered known test RCX/object and safely read the vtable pointer, but RAX was0 and caller an internal return sentinel. Guest exited0 with10 AOT entries/zero fallback; **that is not a diagnostic pass**.
- Unreadable-pointer, four-record/eight-entry output-cap and SEH-label checks were skipped after that assertion. No game012 ran. Native slot is released.
- Evidence under A `build/terra-callback-worker/snapshot5-controls/snapshot/runtime.log`, `snapshot5-inputs.sha256`, `snapshot5-build.log`; prior snapshots/failures retained. Do not commit or use this candidate as proven.
- Two placements failed: **narrow before another attempt**. Investigate where original translated register/stack state remains available at an invalid indirect control transfer (emitted branch/dispatch exit, ARM64 signal mcontext/register mapping, callback redirection). Prove exact known object/vtable/caller on owned fixture before a game snapshot. Do not merely relax assertions to accept the internal sentinel or assume cached `x86_ctx` equals live guest state.
- Existing built/pushed harness `--trace-null-target` explicitly sets `VXRT_AOT_NULL_DIAGNOSTIC=1`, records diagnostic scope and preserves bounded `aot-null-target:` lines. Inherited runtime env is stripped. **Harness exists; native snapshot is not verified.**

A also has older unrelated uncommitted provider/Rust asymmetric-optics experiments (`view_host.h`, `core.c`, guest helper, `apple_provider.rs`, `compositor.rs`, `openxr_data.rs`, `system.rs`). They are not part of the tested null fix or latest simulator proof. Do not reset them or stage them with another change.

## Remaining risks / honest acceptance limits

- Broad runtime baseline remains **red**: different batches stopped in fiber migration assertions, kernel released-memory assertion, presentation snapshot checks or `threads.exe+0x83b2/+0x83f2`. Later checks were skipped. Similar old failures are not proof of equivalence/cause. Do not waive these.
- AOT suite-equivalent text callbacks, missing-import/interior control, main and11-part split pass; main/split each8167 entries/zero fallback. This does not establish game completeness.
- Earlier owned stack-local-vtable fixture intermittently SIGSEGVs in AOT module entry; final null control uses static storage. Old/local failure is unresolved, not fixed. Source reconstruction and hashes are in null-vtable report and A `build/terra-callback-worker/aot_null_vtable_stack_local.c`.
-94 Bink refused blocks remain: diagnostic tool found87 instruction refusals/7 decode refusals,73 unique actual failure PCs;52 differ from block starts.73 block refusals classify as MMX MOVQ/MOVD/PXOR; the remaining21 have unresolved decoder/other/overlap issues. No extra MMX implementation or claim all are reachable.
- Real stereo Apple drawable presentation, tracking, connected Sense provider input, audio, scene execution and sustained target-device budgets remain unproven. Default Apple init remains fail-closed outside explicit test modes.

## Artifacts and resuming game orchestration

Use C worktree as cwd for game tools. Its `runs/ledger.jsonl` has **11 rows**, head `40ae4aafbdc127a65ec51ef58d4000eb3dc682129aadd3dc7d39a946a39186fd`.

- `build/xrizer-candidate-13/`: build/source manifests, receipt, adjacent VM helper, `null-001`, `joined-001`, exact `game011-command.json`. Runtime SHA `024621453feb08c37c8a8478ffe8814afc7f8a49e258514f745ad380fbe2db41`; helper SHA `1a0555faa605c026b36371c4bf714fe29552e7e51d7a70cff9c28587aa4edce3`.
- Actual frozen Mac xrizer library is B `third_party/klepton_openxr/build/xrizer-frontend-dkziw5/libxrizer.dylib`, SHA `71aed9176b0f201072385a5f7bb43672fe23f27cd140cb6e0660d35a5df4211e`. Do not silently substitute the newer simulator Rust archive.
- Original game: `/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR`. Original EXE SHA `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971`; private prepared SHA `8daf05196ecad57963be61614ce4a4cd5c4dc27d222db14e01c262b36b3d46d4`.
- C `build/private/skyrimvr/<original-sha>/aot-reference-emms/manifest.json` selects18 modules:17 unchanged plus fresh Bink. Do not overwrite immutable original modules. Bink SHA `23787be6b0d6325b236e4ade0aa6534ba01fb9c8a0342ab4580eba42b0818607`; base `0xf00000000`, file hash `f16f5c321585bf24`.
- Game writes isolated overlays/root/XDG, Steam bridge0, no Wine. Harness refusals must be honored. Normal vs depth-limited/trace diagnostics must be labelled separately.
- A fresh runtime needs **adjacent `libvxrt_vm.dylib`**; absence fails before guest code. Build candidate recipes preserve source/tool/compiler/module identities; do not rebuild the whole game for an unrelated host fix.

Useful read-only checks:

```sh
# C worktree
python3 tools/vxrt_native_startup.py --validate build/xrizer-game-011/result.json
python3 tools/vxrt_ledger.py verify
# Integration root: last run passed15 startup tests +11 pipeline tests
python3 -m unittest discover -s tests -p 'vxrt_native_startup_test.py'
python3 -m unittest discover -s tests -p 'skyrim_aot_pipeline_test.py'
python3 tools/vxrt_agents.py check
```

## Recommended next work

1. **Integrate reviewed XR delta:** main already includes558bb27 as156c4d9 and the A/C source baseline. Cherry-pick **`e86df82`, then `896c7d2`**; do not merge the whole branch or reapply baseline sync `a726aef`. Inspect conflicts/default paths, update main plan/README and verify the integrated revision with the corrected isolated fixture recipe. Existing branch proof is not automatically proof of the merged revision.
2. **Narrow original-context capture:** Terra A has two failed placements. Review compiled indirect-call/state-spill and signal/callback flow, using a small owned fixture. Only after snapshot assertions pass may a pinned bounded game012 use `--trace-null-target`. Identify the object/interface and first real missing behavior; implement it with an owned reproducer, not a game workaround.
3. **Continue real Apple-host design from the proven boundary:** preserve one compositor loop. Separate simulator offscreen acceptance from physical stereo/tracking/Sense. Prepare a concrete platform-backed fixture and required device resource evidence before requesting physical install/launch approval. No current approval is outstanding.
4. Preserve red baseline/stack-local failure and remaining opcode coverage as explicit parallel risks. Avoid unchanged game retries or repeated broad batches without a changed candidate/new question.

Last user-facing summary: two substantive wins (simulator XR/AOT and concrete compiler/runtime fixes), but no Skyrim scene; immediate blocker is the unidentified null-vtable object and truthful context capture. User now wants another agent to continue from this handover.
