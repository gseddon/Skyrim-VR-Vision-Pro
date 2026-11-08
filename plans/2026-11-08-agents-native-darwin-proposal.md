# Proposed AGENTS.md updates for native Darwin and standalone visionOS

8 November 2026. Historical proposal; superseded by the user-requested concise plan-centered AGENTS.md. The separately requested GPL/LGPL policy change is already applied; the changes below are not active instructions yet. Preserve the existing SteamVR workflow for its users.

## 1. Describe the actual execution modes

Replace the single Rosetta-only architecture description with this text:

> VXRuntime implements Windows API/ABI compatibility and graphics on Apple platforms. There are distinct execution modes: an x86-64 macOS runtime under Rosetta as a development reference; an ARM64 macOS runtime with diagnostic translation; strict ARM64 AOT execution on macOS; and an embedded visionOS host that accepts precompiled ARM64 modules without JIT. Record the exact checkout, mode, PE/module identity and target SDK for every result. The standalone work currently lives in the native-Darwin integration worktree; do not assume all host components exist on every branch.
>
> The existing SteamVR/HEVC Mac-to-headset product remains supported. Fully standalone visionOS is a separate path: game code, Windows compatibility, graphics, VR, tracking, input and audio execute on the headset. A Mac may prepare and install artifacts, but the accepted headset session requires no Mac/PC helper, streaming connection or external SteamVR process.

Add links to `VXRuntime/RECOMP.md`, `VXRuntime/VISIONOS_PORT.md` where present, and the current repo-local plan. Describe xrizer as the selected OpenVR compatibility implementation being ported, not as a completed native backend.

## 2. Separate game evidence from compiler, fixture and simulator evidence

Add this rule before the existing harness levels:

> Every claim names its subject and mode. Source inspection, static PE analysis, native unit tests, owned Windows fixtures, simulator sessions, physical-headset sessions and measured game runs are different evidence. Fixture success never establishes a game's compatibility level. Simulator success never establishes physical tracking, controller behavior, visual comfort or playable status.
>
> Preserve the SteamVR harness and its existing levels. A native OpenVR/OpenXR backend must record its actual session, eye-pair, pose/input, GPU completion and scenario observations; it must not manufacture a SteamVR connection or inherit streaming baselines. Extend and validate native game evidence before using it to award a game level.
>
> Native frame evidence distinguishes producer frame IDs and source pose IDs from compositor refreshes/repeats. Record freshness, eye identities, bounds, color, GPU readiness and lifetimes. Missing counters or an absent AOT summary are unknown/failure, not zero. A successful asynchronous Submit alone does not establish presentation.

Keep the user-only ten-minute physical playtest requirement and the DRM, ownership and immutable game-file rules unchanged.

## 3. Make the no-JIT requirement precise

Replace the runtime-code rule with:

> On accepted standalone visionOS paths, all guest executable code and ABI stubs are built before launch and packaged for the target SDK. No JIT, executable-memory workaround, debugger-assisted activation or missing-code fallback is allowed. On macOS, the existing translator emitter is permitted for explicitly labelled development/diagnostic runs; strict native acceptance requires actual AOT entries and zero fallbacks. Do not regenerate binaries or modules during a run.

Add this ABI guidance:

> Native ARM64 pointers and C/Rust signatures do not establish the Windows x64 ABI. Generate guest-callable stubs and verify per-version vtables/FnTables, aggregate returns, floats, structures, callbacks and lifetime rules with independently specified Windows fixtures. Do not alias unsupported OpenVR versions to a differently shaped interface.

## 4. Give native work its own build and test lane

Retain `make check`, `check-arm64` and the SteamVR commands, adding the targets available on the selected branch:

```sh
make -C VXRuntime aot-suite
make -C VXRuntime native-vr-unit-check native-vr-gpu-check native-vr-check
make -C VXRuntime xros-lib xros-aot-tests
make -C VXRuntime XROS_SDK=xrsimulator xros-lib xros-aot-tests
make -C VXRuntime xros-app XROS_CODE_SIGNING=NO
```

> Tests must check child exits, semantic verdicts and required counters. Establish a fresh baseline and record pre-existing failures separately from regressions; neither can be silently waived or reported as green. Add a reproducer before fixing an observed nontrivial compiler/runtime defect. Device/simulator builds alone do not establish execution. Record signing, installation and launch separately. Honor failures and session refusals without bypassing them.

For xrizer, add verified Rust build commands and target/toolchain versions after the initial port spike establishes them. Do not document an untested command as a working build lane.

## 5. Support supervised parallel work and persistent authorization

Add these operational rules:

> Use isolated worktrees/builds, module caches, runtime roots, overlays and evidence directories for parallel agents. Assign a single owner to shared files. Shared generator scratch paths mean output-directory flags alone may be insufficient. Serialize runtime suites that share named objects, the host GPU or a device; separate functional tests from performance measurements.
>
> When parallel agents are requested, give each a bounded task, expected evidence and a checkpoint within three minutes. After two failed approaches or a missed checkpoint, inspect the blocker and narrow or redirect the work. Stop unproductive loops; record a local issue or handoff after three attempts without progress, while allowing genuinely independent work to continue. Never post it automatically.
>
> Ask before new downloads, posting, installation/deployment or other actions outside the repository. Authorization persists for its stated scope: do not repeatedly ask for already approved source/toolchain/crate downloads. Prefer approved repository-local tools and caches, and do not change global tools or shell configuration without authorization. Simulator use can be explicitly authorized independently of physical-device deployment. Do not replace or terminate an existing session or erase app data to make a test pass.

## 6. Replace stale blanket capability claims

The final paragraph currently says “no Vulkan”, although the inspected checkout contains `vk_*.m`, SPIR-V translation and documented limited Vulkan paths. Replace this undated feature list with a requirement to check the current source, test results and design documents, naming the exact unsupported feature that blocks the current workload. Partial support is not general API conformance.

Continue treating large new features as separately scoped projects. The user has now explicitly scoped xrizer's Darwin/Metal/OpenXR integration, so agents should not stop merely because it is substantial; keep its milestones bounded and tested.

## Applying the proposal

Review and apply only the accepted sections to `AGENTS.md`, then run `python3 tools/vxrt_agents.py sync` and `python3 tools/vxrt_agents.py check`. Change the source instructions, not generated agent files by hand. Keep branch-specific capability/status details in the plan and evidence records so AGENTS.md remains stable.
