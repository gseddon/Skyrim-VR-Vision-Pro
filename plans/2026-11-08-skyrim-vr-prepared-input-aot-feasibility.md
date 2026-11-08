# Skyrim VR prepared-input AOT feasibility plan

Date: 8 November 2026 (Europe/London)
Status: private prepared input and eight bounded new-repository native probes complete; the latest strict run exposes a Bink translation gap; complete AOT feasibility remains open.

## Active work and ownership

The source and active worktrees are now in `gseddon/Skyrim-VR-Vision-Pro`, branch
`codex/standalone-import`; see `MIGRATION.md` and the main plan's approved-round
work order. The earlier VeRantyx implementation checkout is read-only evidence
and private-artifact reference. Historical workers are idle.

Terra A (`terra-guest-stereo`) currently owns a narrow compiler investigation of
actual probe `xrizer-game-008`. Terra B (`terra-pose-input`) continues isolated
standalone xrizer/provider/Apple-host integration. The parent runs pinned game
probes in `terra-skyrim-aot`, updates plans and integrates reviewed source. The
Terra C worker is stopped after automatic content review rejected its turns;
that rejection is recorded in the main plan. Do not infer a running worker from
an old task name.

Current observed gate: actual Skyrim now initializes native xrizer, creates its
D3D11 device, reaches Compositor022/WaitGetPoses and passes real PollNextEvent
calls. Probe007 reported 3,539,503 AOT entries with zero fallback up to its
intentional event-wrapper stop. After the owned event-layout proof passed,
probe008 stopped at **binkw64.dll+0x1d48**, inside its loaded hash/base-matched
module: 3,351,147 entries, one strict fallback request/missing address. The
translator did not execute. No game stereo image, menu or scene is established.

Initial static triage finds that target is a discovered EMMS/RET leaf; the
missing emitted block appears to be an unsupported instruction rather than an
undiscovered function. This remains a hypothesis until the owned instruction
reproducer, emitted-module inspection and differential test prove it. Keep
**discovered**, **emitted**, **loaded** and **executed** code sets separate.
Next: owned red/green semantic proof against Rosetta, narrow compiler fix if
confirmed, required AOT suite, then regenerate only the affected private Bink
module with explicit hash/base/compiler provenance before one changed probe.
Do not enable fallback or rebuild unrelated game modules to hide the gap.

The separate intermittent native SIGBUS remains unresolved. New raw fault
register/stack-bound logging passes its owned real-signal control, but probe007
and008 did not reproduce that game fault. Missing summaries in other probes
remain unknown. Broad runtime checks are still red; current paired controls
and skipped tests are in `research/2026-11-08-runtime-regression-round2.md`.
All game receipts, sealed observations, commands and limitations are indexed
in `research/2026-11-08-skyrim-native-bootstrap-round2.md`. Authentication is not
a fixture gate; no ownership or Steamworks success is fabricated.

## Overview

Follow the Android port's workflow at the process level: prepare a readable executable, discover functions and indirect targets, translate the game and required guest DLLs, test instruction semantics, and iteratively close missing-code gaps from strict execution. Apply it to the user's Windows x86-64 Skyrim VR build and existing VXRuntime ARM64 compiler. Keep D3D11-to-Metal and xrizer; do not replace them with the Android port's x86-32 C lifter or D3D9/Vulkan renderer.

This is the active feasibility subplan of `plans/2026-11-08-skyrim-vr-native-darwin-aot.md`. Work in the new repository worktrees listed in `MIGRATION.md`; the former `build/worktrees/native-darwin-aot` is read-only reference. The user subsequently requested a supervised xrizer lane in parallel. Keep that lane independent of the game/compiler investigation; its revised Klepton reuse direction is now confirmed: adapt the OpenXR core to our existing Apple host, with tracked controllers as the first physical input target. The existing compiler/graphics fixtures remain useful controls.

## Prepared-input baseline and historical evidence

- Checkpoint commits: main plan/guidance `3e5fdf2`; implementation/xrizer Apple build port `b4a205f`. The checkpoint explicitly records incomplete XR and failed broad baseline checks.
- Original Skyrim VR EXE SHA-256: `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971`. It is PE32+ x86-64, with entry RVA `0x392e310` in `.bind`.
- Original main `.text` entropy is 8.0000 bits/byte; all 5,501 complete 4 KiB pages are at least 7.9. Of 118,450 structurally valid exception ranges, 11,475 starts fail the decoder. Control images have ordinary code statistics and much lower unexplained coverage. This is a code-availability concern, not proof of a particular wrapper or transformation.
- Original wrapped-image analysis left 78.98% of executable-section bytes unexplained. Static generation nevertheless emits 335,610 blocks / 12,229,876 ARM64 words in four parts, while recording 209,910 refused block attempts. Generation exits zero; that is not an execution or completeness pass. The original-image generated assembly stays local and will not be used as a trusted prepared-image artifact.
- The first loose-file inventory missed DirectX DLLs inside the game's bundled redistributable cabinets. `x3daudio1_7.dll` and `d3dx9_42.dll` were extracted privately with the existing archive tool; the originals remain unchanged. The local x64 `msvcp140.dll` candidate supplies the requested exports. Bink's delayed `mss64.dll` dependency remains unexercised. DLLs have now initialized in a bounded native probe; that does not prove their complete behavior.
- Pinned Steamless identified Variant 3.1 x64 and prepared a separate PE on native macOS using repository-local .NET. Prepared SHA-256 `8daf05196ecad57963be61614ce4a4cd5c4dc27d222db14e01c262b36b3d46d4`; original hash unchanged. Prepared unexplained executable-section bytes fell to 0.86%, with 659 tables and 118,446/118,450 exception starts accepted by the decoder. This materially reduces the code-availability concern, without proving complete discovery or semantics.
- Private EXE and six guest DLLs compiled into ARM64 modules. Initial probes exposed a DLL mapping conflict, then a `.text` callback-discovery gap. A new owned fixture reproduced the latter and passed strict AOT after the compiler fix; `make -C VXRuntime aot-suite` passes, including split modules and comparison against Rosetta. Broad runtime baseline failures remain separate.
- `probe-skyrim-003` (under `runs/skyrim-feasibility/`) observed 2,537,167 AOT entries and one strict missing-code stop (`o4`), at `0x10740c100` with no image (`o5`), exit 3 (`o1`), no timeout (`o2`), and unchanged read-only inputs (`o3`). Calls originate in the Skyrim EXE's CRT initialization; no menu/scene/VR checkpoint is established. That no-image target was subsequently confirmed as the loader-owned missing-import stub in probe004; see active work above.

Local findings: `research/2026-11-08-skyrim-code-discovery.md`, `research/2026-11-08-skyrim-dependencies.md`; raw private evidence under `runs/skyrim-feasibility/` in the implementation checkout.

## What Android actually does

Its [regeneration script](https://github.com/ttom795/Skyrim_Android/blob/main/tools/regen_gen.sh) requires `TESV_unpacked.exe`, described as TESV with SteamStub removed by Steamless. The script does **not** perform that step; it runs discovery and lifting on the already-prepared file and three DLLs.

Its [discovery](https://github.com/ttom795/Skyrim_Android/blob/main/tools/discover.py) follows entry/export roots, direct calls, code pointers, bounded switch tables and repeated gap passes. [Incremental rediscovery](https://github.com/ttom795/Skyrim_Android/blob/main/tools/rediscover.py) revisits the saved analysis. [Differential tests](https://github.com/ttom795/Skyrim_Android/blob/main/tools/difftest.py) compare selected instruction shapes against Unicorn. [Dispatch](https://github.com/ttom795/Skyrim_Android/blob/main/runtime/dispatch.c) stops with target/caller diagnostics when translated code is missing; it does not provide a silent interpreter fallback. None of these is a universal proof that every possible gameplay path is covered.

The [referenced unpacker](https://github.com/atom0s/Steamless#supported-versions) supports several x64 variants; the pinned tool identified and processed this exact file as Variant 3.1 x64. Its x64 plugin validates the wrapper, processes its header/payload, restores the code section where required, rebuilds the PE with its original entry point and writes a separate output. The [CLI](https://github.com/atom0s/Steamless/blob/master/Steamless.CLI/Program.cs) loads matching plugins and reports processing success/failure. Do not infer unpacking success from entropy alone. Its [documented scope](https://github.com/atom0s/Steamless#what-steamless-wont-do) leaves Steamworks API integration intact.

## Decisions, Assumptions and Options

The user confirms ownership of the Steam game and explicitly authorizes local unpacking/preparation of private working copies. The previous DRM-removal restriction has been removed from `AGENTS.md` in both checkouts and generated instructions synchronized. Original installation files remain read-only; ownership/Steamworks responses and anti-cheat are not to be fabricated or bypassed. No further confirmation of this already-authorized preparation scope is needed.

| Option | Benefit | Cost / limit | Decision |
| --- | --- | --- | --- |
| A. Prepare a private unpacked PE before discovery/AOT | Matches Android's input assumption; gives reproducible static bytes and direct before/after measurements | Exact wrapper/tool/host execution support must be validated; new artifact identity; Steamworks requirements may remain | Selected and recommended for the next feasibility gate |
| B. Keep the original wrapper and observe normal startup before deriving code artifacts | Preserves the original image's startup path for comparison | Requires functioning normal initialization and a reliable way to capture available code; may hit Steam/environment requirements before useful code is available | Optional diagnostic reference, not the primary path |

Use the existing external preparation tool rather than implementing a new unpacker or copying cryptography into VXRuntime. Confirm a practical host execution route first. The upstream project targets .NET Framework and includes a Windows CLI; do not claim its Windows command runs natively on macOS without testing. Keep it a preparation dependency, not a headset runtime requirement. Its separately stated license/notices must be preserved; GPL approval for xrizer is not a blanket license change for other projects. Do not bundle the preparation tool or prepared game artifacts into public deliverables.

## Desired End State

A private, provenance-recorded prepared image exposes code that the existing static compiler can discover and translate. All actually reached guest code for the tested startup/scene checkpoints runs from hash/base-matched ARM64 AOT modules, with no JIT/interpreter fallback. Failures identify the module, address, caller where available and first observed problem. Progress is reported for exercised checkpoints, not as a guarantee of all possible paths.

## Out of Scope

A new recompiler, 32-bit Skyrim, downgrading to the Android renderer, Steamworks emulation/fake ownership, anti-cheat work, modification of original installs, public redistribution of game-derived artifacts, and performance tuning before a correct scene. Supervised XR research may proceed in parallel, as requested.

## Phase 1: Prepare and Verify the Input

### Changes

- [x] Record the user's private-copy preparation authorization and update `AGENTS.md` / generated instructions.
- [x] Pin the preparation tool release/source revision and hashes, identify its actual supported x64 variant for this input, and validate a usable host route. A Mac-local route is preferred; a separate preparation host is an option, with no dependency during headset execution. Do not launch installers or install global tools implicitly. Approval for new tool downloads/host actions follows the recorded session scope.
- [x] Create repository-local `build/private/skyrimvr/<original-sha>/input/` and `prepared/` directories. Copy the executable there; never point a tool that writes beside its input at the Steam install. Keep preparation logs and all auxiliary outputs there.
- [x] Run the pinned tool only on the private input. Preserve its status/logs. Keep the output under the original module basename in a separate prepared directory if the loader/asset layout requires it; record any rename without changing its contents.
- [x] Write a manifest with original and prepared SHA-256, tool/plugin/version/options, commands/status, PE architecture/base/entry/layout, relevant section changes and source install identity. Hash originals before and after and require equality. Preserve originals and prepared output separately.
- [x] Re-run the same audit, decoder/discovery and control measurements on original and prepared images. Compare entry location, valid exception roots, recognizable control flow, jump tables, padding/data and unexplained ranges. High-level tool success plus entropy change is insufficient by itself.

### Automated Verification

- [ ] Manifest validation rejects missing/mismatched hashes, wrong PE class/architecture, truncated or structurally invalid sections/directories, unusable entry points and writes to the source install.
- [ ] Independent PE/disassembly checks establish coherent prepared code at the restored entry and sampled metadata-backed functions. Unwind/TLS/import/relocation tables remain structurally usable; their semantic correctness is tested by execution later.
- [x] The same audit tool and controls produce comparable original/prepared results, with exact commands/statuses recorded.

### Manual Verification

- [x] Review the preparation manifest and section/entry differences before treating the output as compiler input. This is a review of artifacts, not a request to repeat the already-granted unpacking authorization.

**Gate:** prepared, structurally coherent code bytes exist with traceable provenance. If the tool rejects the variant, output validation fails, or the host route is unavailable, report the exact blocker before touching the compiler or expanding XR.

## Phase 2: Discover x64 Code and Close Static Gaps

### Changes

- [x] Run the existing analyzer on the prepared PE. Keep separate counts/maps for metadata roots, heuristic candidates, decoded instructions, recognized tables/data/padding and unexplained bytes; preserve per-section/per-range results.
- [ ] Use x64 metadata first: entry, exports, TLS callbacks, valid `.pdata`/unwind/exception handlers, relocations and function-pointer/vtable references. Retain recursive direct-call/branch discovery. Do not transplant Android's 32-bit pointer or switch assumptions.
- [ ] Inspect remaining referenced gaps and indirect control flow. Add only evidenced patterns, including actual x64 MSVC/RIP-relative switch tables and tail-call/callback targets where needed. Revisit affected ranges incrementally; avoid indiscriminate decoding of every byte as code.
- [ ] Give each refusal a reason/address and originating root. Persist a worklist so later execution misses can seed repeatable rediscovery without hand-editing generated assembly.

### Automated Verification

- [ ] Meaningful owned PE fixtures cover every new discovery pattern, including embedded data, misleading pointer candidates and overlapping/invalid ranges. Demonstrate the previously missed target and reject false roots where the test specifies them.
- [ ] Repeat discovery reaches a stable result; all required static entry/TLS/export roots are accounted for or explicitly refused. Unknown indirect targets and unexplained bytes remain visible.

### Manual Verification

- [ ] Review remaining large/reference-bearing gaps. Do not require a fabricated 100% byte-coverage figure: padding/data can legitimately remain outside generated code.

## Phase 3: Resolve Dependencies and Module Identity

### Changes

- [x] Resolve the ordinary startup closure using original local redistributables/candidates, including missing DirectX utility DLLs. Record hashes, source and x64 architecture; collect only what is needed. Handle a delayed/dynamic dependency when observed, not merely because its name appears in a string.
- [x] Keep native Windows/CRT/D3D implementations native. Generate AOT only for guest x64 modules whose code is required. Do not substitute differently shaped DLLs or alias incompatible imports to make loading appear successful.
- [x] Assign nonconflicting bases and build descriptors for actual target mappings. OpenVR, Bink and the available MSVCP candidate all prefer `0x180000000`; record each selected placement and platform-specific arena constraints.
- [x] Bind every generated module to the exact PE actually loaded. A module generated from the prepared PE cannot be silently accepted for the original encrypted/wrapped PE's hash. The manifest ties both to their provenance, while runtime descriptors validate the prepared hash/base/size.
- [x] Prove an asset/search layout that reads original data without writes to the install while loading the private prepared EXE and selected DLLs. Test it with an owned fixture before game execution. Settings/saves/logs stay in isolated roots/overlays.

### Automated Verification

- [ ] Resolve and report ordinary/delayed/dynamic dependencies separately; wrong-architecture, missing-image, missing-export and base/hash mismatches produce distinct errors.
- [ ] An intentionally wrong PE or module base is rejected; no mismatched-code fallback is accepted as success.

### Manual Verification

- [ ] Inspect the actual dependency and mapping manifest, including any downloaded preparation/redistributable inputs and preserved notices.

## Phase 4: Translate and Validate Semantics

### Changes

- [x] Generate private ARM64 modules from the prepared EXE and required guest DLLs, with generation/refusal logs and controlled build parallelism. Do not reuse original high-entropy-image assembly from the initial audit.
- [ ] Inventory instruction forms in actual discovered prepared code. Use the existing decoder/differential/semantic suites and add minimal behavior-based reproducers for observed missing forms. An optional independent emulator oracle can supplement existing references; adopting a new emulator is not a prerequisite.
- [ ] Exercise callbacks, Windows ABI returns, TLS, exceptions/unwinding, memory ordering/atomics and native-call FPCR preservation as relevant to this game. Isolate known baseline faults separately from title-specific failures.

### Automated Verification

- [ ] Required semantic and strict-AOT suites pass, including deliberately missing-code and mismatched-module tests. Broad baseline failures remain recorded until fixed; do not silently waive them.
- [ ] Generation success is recorded separately from translation refusals and actual execution coverage.

### Manual Verification

- [ ] Review remaining refused reachable blocks and their minimal reproducers; reject zero-filled/no-op replacements as coverage.

## Phase 5: Earliest Reachable Strict-AOT Startup

### Changes

- [x] Add an explicit native-startup mode to the harness/evidence system: selected ARM64 runner, private prepared PE and module manifest, strict AOT, original read-only assets, fresh writable roots/overlays, and a bounded process group. No SteamVR connection, XR scene, FPS or compatibility level is invented.
- [x] Verify actual owned positive overlay and deliberately missing-code fixtures first; both are sealed in the ledger. Six harness unit tests cover refusals, artifact identity, exits and owned process-group timeout. These establish startup capture behavior, not the complete game acceptance gate.
- [x] Run a bounded prepared-image startup, recording DLL/TLS initialization, entry, first called missing API/code address, AOT counters and exit/dialog/exception. Record the earliest checkpoint actually observed, even if no main-game code has executed.
- [ ] If a normal Steamworks requirement remains, record it as its own outcome. Unpacking does not remove Steamworks API integration. Do not manufacture an ownership result or quietly turn this into Steam-client development.

### Automated Verification

- [ ] Evidence includes source/patch, original/prepared PE and module hashes, actual mapped bases, commands/environment, timeout/exit and hashed logs, sealed in the ledger with observed IDs. Missing AOT counters or an unexercised module is unknown, not zero fallback or covered code.
- [ ] Each reached guest address has matching AOT code or stops with a diagnostic. Attempted fallback is a failed strict run even if its summary reports it before translation occurs.
- [ ] Failures identify loader/API/ABI/translation/code-availability/environment categories only when evidence distinguishes them; preserve unknowns otherwise.

### Manual Verification

- [x] Review the earliest actual checkpoint before expanding scenarios or claiming that Skyrim starts/runs.

## Phase 6: Iterative Coverage and Decision

For each real missing target or unsupported instruction: preserve target/caller and module identity -> explain the gap -> add a meaningful reproducer/discovery root -> regenerate matching modules -> repeat strict execution. Use Android's iterative discipline; do not add an interpreter/JIT fallback to hide gaps. Keep each attempt bounded and follow the supervision/three-attempt blocker rule.

Advance through actual initialization, menu/scene preparation and one fixed loaded scene where available. XR-specific progress resumes through the real xrizer backend once code feasibility supports it; the exact game integration still requires that separate work.

| Decision | Required evidence | Next action |
| --- | --- | --- |
| Continue | Prepared bytes are coherent; required guests load; actual original game logic reaches a meaningful strict-AOT checkpoint | Continue bounded compatibility fixes and xrizer integration |
| Narrow the remaining work | Code is available, but an identified compiler/API/ABI/dependency gap blocks a specific observed path | Fix that demonstrated gap; avoid broad speculative reimplementation |
| Reassess | Required code remains unavailable, runtime-generated behavior is incompatible with the no-JIT target, or a remaining launch requirement conflicts with the intended standalone path | Record the precise blocker and options before further XR investment |

No result establishes all possible gameplay paths. Later physical headset scenarios, controller/audio/save/load coverage and sustained playtesting remain in the parent plan.

## Repeatable Investigation Process

Use `tools/skyrim_aot_pipeline.py` with a private JSON configuration. It pins original/prepared/DLL/runtime hashes and DLL bases, records the compiler and source patch identity, caches separately keyed module builds, serializes cooperating builds, and delegates bounded startup capture to `tools/vxrt_native_startup.py`. Default invocation plans only; `--build` builds, and `--probe` requires an explicit successful owned-gate command. Six mocked pipeline tests pass. `pipeline-owned-001` also exercised the real build → owned-gate → bounded-probe workflow: exit 0, 31 AOT entries, zero fallback, unchanged inputs; this is an owned callback fixture, not Skyrim. The build script must not be run concurrently outside that lock.

The orchestrator is an incremental implementation, not a completed validator: prepared PE/provenance validation, full base-range overlap checking, instruction/refusal attribution, caller-to-module mapping and broader semantic gates still need adding. A compiler binary hash identifies what ran but does not prove that binary was built from the recorded source. Preserve earlier artifacts and use a new run directory for every probe.

For every stop, persist: input/compiler/runtime/module identities, caller and target if available, mapped image/base, first evidence, category, reproducer, owner, next action and acceptance check. Categories are input/layout, module mapping, undiscovered/refused code, missing API, ABI/semantic fault, environment requirement, or unresolved. Do not automatically interpret a no-image address as static missing game code. Fix only a demonstrated cause, then rerun the owned reproducer and strict checkpoint. Missing counters and unexercised modules remain unknown.

Progress is a sequence of gates: (1) coherent prepared input; (2) valid module mapping and dependency initialization; (3) EXE initialization and entry; (4) menu/scene; (5) required XR interfaces; (6) physical standalone scene. Byte percentages and generation counts do not substitute for these gates.

## Immediate Next Task

The no-image target from `probe-skyrim-003` is now classified. Observed ordinal aliases now pass. The actual OpenVR error110 now explains the `BSOpenVR` null member. Prove the native guest-ABI bridge next; do not retry unchanged missing-runtime startup or invent a successful interface. The initial reusable orchestration and xrizer/Klepton draft plan are in place; the revised XR provider extraction has begun under supervised Terra ownership. Full semantic, scene and device gates remain open.

## Latest automated checks

`runs/skyrim-feasibility/systematic-checks/aot-suite.log`: exit 0, callback regression plus unsplit/split owned suite, positive AOT entries and zero fallback. Fourteen Python audit/dependency/pipeline/startup tests pass. Ledger validation passes with nine records including the actual orchestration control run.

Fresh broad checks are still red: `check.log` exits 2 after a native `d3d_release` crash during `d3d12.exe`; this differs from the earlier intermittent kernelx assertion and requires isolation before attributing it to a baseline or change. `check-arm64.log` exits 2 at the known `threads.exe+0x83f2` exception. The compiler fix is not a clean broad runtime acceptance result.


### Systematic pipeline: PE and mapping preflight

The pipeline now validates each prepared/guest module as AMD64 PE32+ before
planning, building or cache reuse: complete headers/section table, bounded
image/header/directory data, file-backed section bounds, nonoverlapping virtual
sections and an executable entry point when nonzero. Mapping checks use full
64K-rounded image ranges, so distinct selected bases can no longer conceal an
overlap or 64-bit overflow. The manifest records the inspected layout.

Twenty root Python tests pass, including wrong-ISA/truncated/unbacked-entry
controls and an overlapping-module rejection with an adjacent-range positive
control. Read-only checks also accept the actual prepared Skyrim image
(59,957,248-byte image, nine sections), private d3dx9_42 and X3DAudio1_7 inputs.
This is basic structural validation, not a claim that every instruction can
execute, that imports close, or that the prepared image's provenance has been
independently established. Compiler-binary-to-source build provenance remains
an explicit follow-up.


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
