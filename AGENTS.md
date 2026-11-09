# Working on the native Darwin / standalone Vision Pro plan

## Start here

Read [the current implementation plan](plans/2026-11-08-skyrim-vr-native-darwin-aot.md) before changing code. It is the source of truth for scope, decisions, phase dependencies, progress, test evidence and remaining blockers. Update it as work is verified; leave physical/manual checks unchecked until confirmed.

Read [the xrizer port investigation](research/2026-11-08-avp-play-xrizer.md) and the implementation checkout's `third_party/xrizer/README.md` and `SOURCE.md` when working on VR integration. In that checkout, the research report is under `research/` directly. Verify the actual source and target before relying on a document's capability claims.

This is the standalone source repository. Read `MIGRATION.md` for active checkouts. New Terra implementation runs in this repository’s dedicated worktrees; the previous VeRantyx checkout is a read-only reference for pinned private artifacts, toolchains and immutable evidence. Keep builds and evidence isolated, and preserve original identities when reusing artifacts.

## Direction and useful context

- Final target: fully standalone Vision Pro execution. A Mac may prepare AOT artifacts and install the app; the headset session must not require streaming, a Mac/PC helper or external SteamVR.
- Reuse VXRuntime's existing x86-64-to-ARM64 AOT compiler and Windows API/ABI compatibility. “Native Darwin” still requires Windows imports, layouts, TLS, exceptions and callbacks to be handled correctly. See `VXRuntime/RECOMP.md`, `TRANSLATOR.md` and, where present, `VISIONOS_PORT.md`.
- Keep the existing D3D11-to-Metal renderer (`VXRuntime/src/d3d11*.m`, `dxbc.c`, `dxgi.m`). Port xrizer itself as the OpenVR implementation, retaining its versioned interfaces and behavior. Add the Apple platform, Metal backend, native OpenXR provider and Windows guest ABI bridge. The OpenXR loader alone is not a runtime.
- GPL/LGPL reuse, including xrizer and relevant AVP Play changes, is authorized. Preserve source/license notices and record pinned revisions and local modifications in `THIRD_PARTY_NOTICES.md` and the component's source record. Wine (LGPL-2.1-or-later) reuse is authorized for a named purpose at a time (2026-11-09: how Wine reserves address ranges before the system loader runs): fetch only the files needed, keep Wine's copyright headers, put ported code in files of its own marked as derived from Wine with the pinned Wine commit, and list them in `THIRD_PARTY_NOTICES.md` as LGPL, not MIT. Anything ported from Wine for a new purpose needs the user's say-so first. FFmpeg (LGPL-2.1-or-later parts only) is authorized on the same terms for one purpose (2026-11-09: decoding xWMA/WMA v2 audio in the XAudio2 runtime); no GPL-only FFmpeg code. Do not copy or translate ReactOS code.
- The shared native frame contract, Metal presenter, owned fixtures and platform host are described in the plan. Treat the small custom OpenVR adapter as a diagnostic reference; do not expand it into a competing production implementation.
- Compiler, graphics and VR investigation use repository-owned fixtures without a Steam dependency. Authentication is not an initial gate. The user authorizes local unpacking and preparation of private working copies of their owned Skyrim files for this AOT investigation. Keep the original Steam install and other original game/Valve/Microsoft files read-only, generated artifacts private, and runtime writes in isolated overlays. Do not fake ownership or Steamworks responses, bypass anti-cheat, or redistribute game files or translated game code. Stop title-specific anti-cheat work if encountered.

## How to work

- Follow the next incomplete plan milestone. Make bounded, reviewable changes and test the actual behavior. Do not mistake an archive that compiles, an unavailable-backend stub or a successful asynchronous submission for working VR.
- Use Terra subagents when requested. Give each a narrow task, exclusive file ownership and a checkpoint within three minutes. Inspect missed checkpoints or repeated failures; after two failed approaches, narrow or redirect the task. After three attempts without progress, record the blocker and evidence in a local issue/handoff and stop that loop. Continue useful independent work.
- Isolate parallel worktrees, builds, module/cache directories, roots, overlays and evidence. Some build scripts have fixed scratch paths; different output flags alone may not isolate them. Serialize conflicting runtime/GPU/device work, and keep performance measurements separate from compilation and other GPU load.
- No JIT, debugger-assisted execution or runtime CPU code generation on the accepted standalone path. Build modules and ABI stubs ahead of time for the correct Apple target. Mac translation/Rosetta are labelled development references; strict native acceptance requires real AOT entries and zero fallback. Standard Metal GPU shader compilation remains part of the selected D3D11-to-Metal renderer; this CPU AOT rule does not require replacing that renderer.
- Native C/Rust function pointers are not automatically Windows guest-callable functions. Verify per-version vtables/FnTables, structures, floats, aggregate returns, callbacks and resource lifetime through actual generated guest ABI stubs.
- Do not start a game while the user is playing; check active runtime sessions first. Never run competing SteamVR instances, override a refused harness precondition, erase app data, or terminate another session to make a test pass.
- Obtain approval for new downloads, posting or actions outside the repository. Authorization persists within its stated scope: xrizer source reuse, repository-local Rust/Cargo/target/crate downloads and simulator testing are already authorized for this work. Do not change global tools or shell configuration. Physical-device installation/launch needs its own authorization.

## Verification and reporting

Use the selected checkout's supported targets. Relevant current commands include:

```sh
make -C VXRuntime check
make -C VXRuntime check-arm64
make -C VXRuntime aot-suite
make -C VXRuntime native-vr-unit-check native-vr-gpu-check native-vr-check
make -C VXRuntime xros-app XROS_CODE_SIGNING=NO
make -C VXRuntime XROS_SDK=xrsimulator xros-lib xros-aot-tests
```

Use the xrizer component's documented scripts for its Rust targets and local toolchain. The plan records known baseline failures and simulator configuration requirements. Capture real statuses and semantic verdicts; do not silently waive a failure or call an incomplete baseline green. Run required runtime checks after runtime changes, and add meaningful reproducers for nontrivial observed defects.

Every result must identify its subject: static analysis, owned fixture, simulator, physical headset or actual game. Record source/patch and artifact identities, execution mode, target SDK, commands/settings, logs, exits and expected results. Missing AOT counters are unknown/failure, not zero. Preserve producer frame/pose identity and distinguish fresh pairs from compositor repeats; validate eye pairing, bounds/color, GPU completion and ownership.

Fixture or simulator success does not establish Skyrim compatibility, physical tracking/controllers or playability. Use the existing game harness for supported game claims; extending it for a native backend must record actual native observations, never invent a SteamVR connection or reuse streaming baselines. Only a human physical-headset playtest establishes playable. Cite evidence and state what remains unverified.

Commit only verified work; do not describe unverified or blocked functionality as complete. Keep requested changes scoped and preserve unrelated edits.

`AGENTS.md` is the instruction source. After editing it, run `python3 tools/vxrt_agents.py sync` and `python3 tools/vxrt_agents.py check`; do not hand-edit generated agent rules. Legacy product/setup/tuning context remains in the relevant README files and `.agents/skills/` and should be consulted when the task actually touches it.
